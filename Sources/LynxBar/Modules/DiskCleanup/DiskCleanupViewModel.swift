import AppKit
import Combine
import Foundation

enum DiskCleanupPhase: Sendable, Equatable {
    case idle
    case scanning
    case review
    case awaitingConfirmation
    case executing
    case result
    case cancelled
    case failed
}

enum DiskCleanupCancellationContext: Sendable, Equatable {
    case scan(observedEntries: Int)
    case execution
}

@MainActor
final class DiskCleanupViewModel: ObservableObject {
    @Published private(set) var phase: DiskCleanupPhase = .idle
    @Published private(set) var rootURL: URL?
    @Published private(set) var progress = DiskScanProgress(
        observedEntries: 0,
        candidateCount: 0,
        excludedEntries: 0,
        estimatedCandidateBytes: 0
    )
    @Published private(set) var scanResult: DiskScanResult?
    @Published private(set) var selectedCandidateIDs = Set<UUID>()
    @Published private(set) var preparedPlan: PreparedCleanupPlan?
    @Published private(set) var batchResult: DiskCleanupBatchResult?
    @Published private(set) var capacityVerification: DiskCapacityVerification?
    @Published private(set) var errorMessage: String?
    @Published private(set) var cancellationContext:
        DiskCleanupCancellationContext?

    private let scanner: any DiskCleanupScanning
    private let reader: any DiskDirectoryReading
    private let executor: DiskCleanupExecutor
    private let coordinator: RemediationCoordinator
    private let directoryPicker: any DiskCleanupDirectoryPicking
    private let fileRevealer: any DiskCleanupFileRevealing
    private let now: @Sendable () -> Date
    private var scanTask: Task<Void, Never>?
    private var executionTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    private var scanCancellation: DiskScanCancellation?

    init(
        scanner: any DiskCleanupScanning,
        reader: any DiskDirectoryReading,
        executor: DiskCleanupExecutor,
        coordinator: RemediationCoordinator,
        directoryPicker: any DiskCleanupDirectoryPicking,
        fileRevealer: any DiskCleanupFileRevealing,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scanner = scanner
        self.reader = reader
        self.executor = executor
        self.coordinator = coordinator
        self.directoryPicker = directoryPicker
        self.fileRevealer = fileRevealer
        self.now = now
    }

    var candidates: [DiskCleanupCandidate] {
        scanResult?.candidates ?? []
    }

    var selectedCandidates: [DiskCleanupCandidate] {
        candidates.filter { selectedCandidateIDs.contains($0.id) }
    }

    var selectedEstimatedBytes: UInt64 {
        saturatingSum(selectedCandidates.map(\.allocatedBytesEstimate))
    }

    var isConfirmationPresented: Bool {
        phase == .awaitingConfirmation && preparedPlan != nil
    }

    var isBusy: Bool {
        phase == .scanning || phase == .executing
    }

    var canReturnToStart: Bool {
        switch phase {
        case .scanning, .review, .awaitingConfirmation,
                .result, .cancelled, .failed:
            return true
        case .idle, .executing:
            return false
        }
    }

    func chooseFolderAndScan() {
        guard !isBusy else { return }
        Task { [weak self] in
            guard let self,
                  let url = await self.directoryPicker.chooseDirectory() else {
                return
            }
            self.startScan(at: url)
        }
    }

    func scanDownloads() {
        guard !isBusy,
              let downloads = FileManager.default.urls(
                  for: .downloadsDirectory,
                  in: .userDomainMask
              ).first else {
            return
        }
        startScan(at: downloads)
    }

    /// Starts scanning `url` for cleanup candidates while cancelling any prior active scan or execution.
    func startScan(
        at url: URL,
        policy: DiskScanPolicy = .v1
    ) {
        cancelTasks(markCancelled: false)
        let generation = UUID()
        scanGeneration = generation
        rootURL = url
        progress = DiskScanProgress(
            observedEntries: 0,
            candidateCount: 0,
            excludedEntries: 0,
            estimatedCandidateBytes: 0
        )
        scanResult = nil
        selectedCandidateIDs = []
        preparedPlan = nil
        batchResult = nil
        capacityVerification = nil
        errorMessage = nil
        cancellationContext = nil
        phase = .scanning

        let cancellation = DiskScanCancellation()
        scanCancellation = cancellation
        let request = DiskScanRequest(
            rootURL: url,
            policy: policy,
            requestedAt: now(),
            cancellation: cancellation
        )
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in scanner.events(for: request) {
                    guard !Task.isCancelled,
                          generation == scanGeneration else {
                        return
                    }
                    switch event {
                    case .progress(let next):
                        progress = next
                    case .completed(let result):
                        scanCancellation = nil
                        scanResult = result
                        progress = DiskScanProgress(
                            observedEntries: result.observedEntries,
                            candidateCount: result.candidates.count,
                            excludedEntries: result.exclusionCounts
                                .values.reduce(0, +),
                            estimatedCandidateBytes:
                                result.estimatedCandidateBytes
                        )
                        phase = result.status == .cancelled
                            ? .cancelled
                            : .review
                    }
                }
            } catch is CancellationError {
                guard generation == scanGeneration else { return }
                scanCancellation = nil
                phase = .cancelled
            } catch {
                guard generation == scanGeneration else { return }
                Log.app.error(
                    "Disk cleanup scan failed: \(error.localizedDescription, privacy: .private)"
                )
                scanCancellation = nil
                errorMessage = error.localizedDescription
                phase = .failed
            }
        }
    }

    func toggleSelection(_ candidateID: UUID) {
        guard phase == .review else { return }
        if selectedCandidateIDs.contains(candidateID) {
            selectedCandidateIDs.remove(candidateID)
        } else if candidates.contains(where: { $0.id == candidateID }) {
            selectedCandidateIDs.insert(candidateID)
        }
    }

    /// Prepares a remediation confirmation token for the currently selected cleanup candidates.
    func prepareConfirmation() {
        guard phase == .review,
              let result = scanResult,
              !selectedCandidates.isEmpty else {
            return
        }
        let selected = selectedCandidates
        let selectionID = UUID()
        let expectedSession = result.sessionID
        phase = .awaitingConfirmation
        Task { [weak self] in
            guard let self else { return }
            let remediation = await coordinator.prepare(
                kind: .diskReclamation,
                evidenceVersion: expectedSession,
                selectionID: selectionID,
                risk: .recoverable,
                now: now()
            )
            guard scanResult?.sessionID == expectedSession,
                  phase == .awaitingConfirmation else {
                await cancelPreparedCleanup(
                    remediation.id,
                    context: "stale cleanup preparation"
                )
                return
            }
            preparedPlan = PreparedCleanupPlan(
                remediation: remediation,
                scanSessionID: expectedSession,
                policyVersion: result.policyVersion,
                root: result.root,
                selectedCandidates: selected,
                estimatedBytes: saturatingSum(
                    selected.map(\.allocatedBytesEstimate)
                )
            )
        }
    }

    /// Cancels an unconfirmed cleanup confirmation and returns to candidate review.
    func cancelConfirmation() {
        guard phase == .awaitingConfirmation else { return }
        let preparedID = preparedPlan?.id
        preparedPlan = nil
        phase = .review
        if let preparedID {
            Task { [self] in
                await cancelPreparedCleanup(
                    preparedID,
                    context: "cleanup confirmation"
                )
            }
        }
    }

    /// Confirms the prepared cleanup plan, moves selected items to Trash, and records before/after capacity.
    func confirmAndExecute() {
        guard phase == .awaitingConfirmation,
              let plan = preparedPlan else {
            return
        }
        phase = .executing
        errorMessage = nil
        executionTask = Task { [weak self] in
            guard let self else { return }
            var permit: RemediationExecutionPermit?
            do {
                let issuedPermit = try await coordinator.confirm(
                    preparedID: plan.id,
                    evidenceVersion: plan.remediation.evidenceVersion,
                    selectionID: plan.selectionID,
                    risk: .recoverable,
                    now: now()
                )
                permit = issuedPermit
                var before: UInt64?
                do {
                    before = try await reader.availableCapacity(for: plan.root)
                } catch {
                    Log.app.warning(
                        "Failed to read pre-cleanup disk capacity: \(error.localizedDescription, privacy: .private)"
                    )
                }
                let result = try await executor.execute(
                    plan: plan,
                    permit: issuedPermit
                )
                try await coordinator.beginVerification(issuedPermit)
                var after: UInt64?
                do {
                    after = try await reader.availableCapacity(for: plan.root)
                } catch {
                    Log.app.warning(
                        "Failed to read post-cleanup disk capacity: \(error.localizedDescription, privacy: .private)"
                    )
                }
                try await coordinator.finish(
                    issuedPermit,
                    completion: result.completion
                )
                batchResult = result
                capacityVerification = DiskCapacityVerification(
                    beforeBytes: before,
                    afterBytes: after
                )
                phase = .result
            } catch {
                Log.app.error(
                    "Disk cleanup execution failed: \(error.localizedDescription, privacy: .private)"
                )
                if let permit {
                    do {
                        try await coordinator.beginVerification(permit)
                    } catch {
                        Log.app.debug(
                            "Skipped verification transition after cleanup failure: \(error.localizedDescription, privacy: .private)"
                        )
                    }
                    do {
                        try await coordinator.finish(
                            permit,
                            completion: .failed
                        )
                    } catch {
                        Log.app.error(
                            "Failed to release cleanup remediation permit: \(error.localizedDescription, privacy: .private)"
                        )
                    }
                }
                errorMessage = error.localizedDescription
                phase = .failed
            }
        }
    }

    func cancelActiveWork() {
        cancelTasks(markCancelled: true)
    }

    /// Resets cleanup state to idle and cancels any unconfirmed remediation token.
    func startOver() {
        guard phase != .executing else { return }
        let unconfirmedPreparedID = phase == .awaitingConfirmation
            ? preparedPlan?.id
            : nil
        cancelTasks(markCancelled: false)
        rootURL = nil
        scanResult = nil
        selectedCandidateIDs = []
        preparedPlan = nil
        batchResult = nil
        capacityVerification = nil
        errorMessage = nil
        cancellationContext = nil
        phase = .idle
        if let unconfirmedPreparedID {
            Task { [self] in
                await cancelPreparedCleanup(
                    unconfirmedPreparedID,
                    context: "cleanup reset"
                )
            }
        }
    }

    /// Re-queries available volume capacity for the current scan root after cleanup completes.
    func recheckCapacity() {
        guard let root = scanResult?.root else { return }
        let baseline = capacityVerification?.beforeBytes
        Task { [weak self] in
            guard let self else { return }
            var after: UInt64?
            do {
                after = try await reader.availableCapacity(for: root)
            } catch {
                Log.app.warning(
                    "Failed to recheck disk capacity: \(error.localizedDescription, privacy: .private)"
                )
            }
            capacityVerification = DiskCapacityVerification(
                beforeBytes: baseline,
                afterBytes: after
            )
        }
    }

    /// Cancels an unconfirmed cleanup remediation preparation and logs coordinator errors.
    private func cancelPreparedCleanup(_ preparedID: UUID, context: String) async {
        do {
            try await coordinator.cancel(preparedID: preparedID)
        } catch {
            Log.app.warning(
                "Failed to cancel \(context, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func revealCandidate(_ candidateID: UUID) {
        guard phase == .review || phase == .awaitingConfirmation,
              let candidate = candidates.first(where: {
                  $0.id == candidateID
              }) else {
            return
        }
        fileRevealer.reveal(candidate.sourceURL)
    }

    func revealFirstStagedItem() {
        guard let url = batchResult?.items
            .first(where: { $0.status == .staged })?
            .trashURL else {
            return
        }
        fileRevealer.reveal(url)
    }

    func openSystemSettings() {
        guard let settingsURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences"
        ) else {
            return
        }
        NSWorkspace.shared.openApplication(
            at: settingsURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func cancelTasks(markCancelled: Bool) {
        let phaseBeforeCancellation = phase
        scanCancellation?.cancel()
        scanCancellation = nil
        if !markCancelled || phaseBeforeCancellation != .scanning {
            scanGeneration = UUID()
            scanTask?.cancel()
        }
        executionTask?.cancel()
        if !markCancelled || phaseBeforeCancellation != .scanning {
            scanTask = nil
        }
        executionTask = nil
        if markCancelled, phaseBeforeCancellation == .scanning {
            cancellationContext = .scan(
                observedEntries: progress.observedEntries
            )
            phase = .cancelled
        } else if markCancelled, phaseBeforeCancellation == .executing {
            cancellationContext = .execution
            phase = .cancelled
        }
    }

    private func saturatingSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? UInt64.max : sum
        }
    }
}
