import Foundation

struct DiskCleanupScanner: DiskCleanupScanning {
    private enum InspectionOutcome: Sendable {
        case candidate(DiskCleanupCandidate)
        case excluded(DiskExclusionReason)
        case cancelled
    }

    private struct Accumulator {
        var candidates: [DiskCleanupCandidate] = []
        var exclusions: [DiskExclusionReason: Int] = [:]
        var observedEntries = 0
        var completedEntries = 0
        var estimatedBytes: UInt64 = 0
        var lastProgressEntryCount = 0
        var lastProgressTime: TimeInterval
    }

    private let reader: any DiskDirectoryReading
    private let clock: any DiskCleanupMonotonicClock

    init(
        reader: any DiskDirectoryReading,
        clock: any DiskCleanupMonotonicClock =
            SystemDiskCleanupMonotonicClock()
    ) {
        self.reader = reader
        self.clock = clock
    }

    func events(
        for request: DiskScanRequest
    ) -> AsyncThrowingStream<DiskScanEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(16)) {
            continuation in
            let producer = Task.detached(priority: .utility) {
                do {
                    let result = try await scan(
                        request: request,
                        continuation: continuation
                    )
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    private func scan(
        request: DiskScanRequest,
        continuation: AsyncThrowingStream<DiskScanEvent, Error>.Continuation
    ) async throws -> DiskScanResult {
        let policy = request.policy.normalized
        let root = try await reader.validateRoot(request)
        let sessionID = UUID()
        let startedAt = clock.now()
        var status: DiskScanStatus?
        var iterator = await reader.entries(beneath: root).makeAsyncIterator()
        var accumulator = Accumulator(lastProgressTime: startedAt)

        try await withThrowingTaskGroup(of: InspectionOutcome.self) { group in
            var inFlight = 0
            var enumerationFinished = false

            while !enumerationFinished || inFlight > 0 {
                while !enumerationFinished,
                      status == nil,
                      inFlight < policy.maximumConcurrentMetadataReads {
                    if cancellationRequested(for: request) {
                        status = .cancelled
                        group.cancelAll()
                        break
                    }
                    if clock.now() - startedAt >= policy.maximumDuration {
                        status = .partialDeadline
                        break
                    }
                    if accumulator.observedEntries >= policy.maximumEntries {
                        status = .partialEntryLimit
                        break
                    }

                    guard let entry = try await iterator.next() else {
                        enumerationFinished = true
                        break
                    }
                    let wasAdded = group.addTaskUnlessCancelled {
                        do {
                            guard !cancellationRequested(for: request) else {
                                return .cancelled
                            }
                            let observation = try await reader.observe(entry)
                            guard !cancellationRequested(for: request) else {
                                return .cancelled
                            }
                            switch DiskCleanupPolicyEvaluator.evaluate(
                                observation,
                                root: root,
                                policy: policy,
                                now: request.requestedAt
                            ) {
                            case .success(let candidate):
                                return .candidate(candidate)
                            case .failure(let reason):
                                return .excluded(reason)
                            }
                        } catch is CancellationError {
                            return .cancelled
                        } catch {
                            return .excluded(.metadataUnavailable)
                        }
                    }
                    guard wasAdded else {
                        status = .cancelled
                        group.cancelAll()
                        break
                    }
                    accumulator.observedEntries += 1
                    inFlight += 1
                }

                if inFlight == 0 {
                    break
                }
                guard let outcome = try await group.next() else {
                    inFlight = 0
                    break
                }
                inFlight -= 1
                accumulator.completedEntries += 1
                reduce(outcome, into: &accumulator)
                emitProgressIfNeeded(
                    accumulator: &accumulator,
                    policy: policy,
                    continuation: continuation
                )

                if status == .cancelled {
                    group.cancelAll()
                }
            }
        }

        if cancellationRequested(for: request) {
            status = .cancelled
        }
        let finalStatus = status ?? .completed
        accumulator.candidates.sort {
            if $0.allocatedBytesEstimate != $1.allocatedBytesEstimate {
                return $0.allocatedBytesEstimate > $1.allocatedBytesEstimate
            }
            return $0.canonicalURL.path < $1.canonicalURL.path
        }
        continuation.yield(.progress(progress(from: accumulator)))
        return DiskScanResult(
            sessionID: sessionID,
            root: root,
            policyVersion: policy.version,
            candidates: accumulator.candidates,
            exclusionCounts: accumulator.exclusions,
            observedEntries: accumulator.observedEntries,
            estimatedCandidateBytes: accumulator.estimatedBytes,
            status: finalStatus
        )
    }

    private func reduce(
        _ outcome: InspectionOutcome,
        into accumulator: inout Accumulator
    ) {
        switch outcome {
        case .candidate(let candidate):
            accumulator.candidates.append(candidate)
            let (sum, overflow) = accumulator.estimatedBytes
                .addingReportingOverflow(candidate.allocatedBytesEstimate)
            accumulator.estimatedBytes = overflow ? UInt64.max : sum
        case .excluded(let reason):
            accumulator.exclusions[reason, default: 0] += 1
        case .cancelled:
            break
        }
    }

    private func emitProgressIfNeeded(
        accumulator: inout Accumulator,
        policy: DiskScanPolicy,
        continuation: AsyncThrowingStream<DiskScanEvent, Error>.Continuation
    ) {
        let currentTime = clock.now()
        let enoughEntries = accumulator.completedEntries
            - accumulator.lastProgressEntryCount
            >= policy.progressEntryInterval
        let enoughTime = currentTime - accumulator.lastProgressTime
            >= policy.progressTimeInterval
        guard enoughEntries || enoughTime else { return }
        continuation.yield(.progress(progress(from: accumulator)))
        accumulator.lastProgressEntryCount = accumulator.completedEntries
        accumulator.lastProgressTime = currentTime
    }

    private func progress(from accumulator: Accumulator) -> DiskScanProgress {
        DiskScanProgress(
            observedEntries: accumulator.observedEntries,
            candidateCount: accumulator.candidates.count,
            excludedEntries: accumulator.exclusions.values.reduce(0, +),
            estimatedCandidateBytes: accumulator.estimatedBytes
        )
    }

    private func cancellationRequested(
        for request: DiskScanRequest
    ) -> Bool {
        Task.isCancelled || request.cancellation?.isCancelled == true
    }
}
