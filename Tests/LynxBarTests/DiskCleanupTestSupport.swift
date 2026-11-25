import Foundation
@testable import LynxBar

actor FakeDiskReader: DiskDirectoryReading {
    private let root: DiskScanRoot
    private let listedEntries: [DiskEntry]
    private var observations: [URL: DiskFileObservation]
    private let observationDelayNanoseconds: UInt64
    private var capacity: UInt64?
    private var activeObservations = 0
    private var peakObservations = 0
    private var totalObservations = 0

    init(
        root: DiskScanRoot,
        observations: [DiskFileObservation],
        observationDelayNanoseconds: UInt64 = 0,
        capacity: UInt64? = 100_000_000_000
    ) {
        self.root = root
        self.listedEntries = observations.map {
            DiskEntry(url: $0.sourceURL)
        }
        self.observations = Dictionary(
            uniqueKeysWithValues: observations.map { ($0.sourceURL, $0) }
        )
        self.observationDelayNanoseconds = observationDelayNanoseconds
        self.capacity = capacity
    }

    func validateRoot(_ request: DiskScanRequest) throws -> DiskScanRoot {
        root
    }

    func entries(
        beneath root: DiskScanRoot
    ) async -> AsyncThrowingStream<DiskEntry, Error> {
        let entries = listedEntries
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                for entry in entries {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    continuation.yield(entry)
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func observe(_ entry: DiskEntry) async throws -> DiskFileObservation {
        activeObservations += 1
        peakObservations = max(peakObservations, activeObservations)
        totalObservations += 1
        defer { activeObservations -= 1 }
        if observationDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: observationDelayNanoseconds)
        }
        try Task.checkCancellation()
        guard let observation = observations[entry.url] else {
            throw DiskCleanupError.sourceUnavailable
        }
        return observation
    }

    func availableCapacity(for root: DiskScanRoot) -> UInt64? {
        capacity
    }

    func replaceObservation(_ observation: DiskFileObservation) {
        observations[observation.sourceURL] = observation
    }

    func setCapacity(_ next: UInt64?) {
        capacity = next
    }

    func peakObservationCount() -> Int {
        peakObservations
    }

    func observationCount() -> Int {
        totalObservations
    }
}

actor FakeDiskTrashMover: DiskTrashMoving {
    private let failingURLs: Set<URL>
    private var recordedCalls: [URL] = []

    init(failingURLs: Set<URL> = []) {
        self.failingURLs = failingURLs
    }

    func moveToTrash(_ url: URL) throws -> URL {
        recordedCalls.append(url)
        if failingURLs.contains(url) {
            throw POSIXError(.EACCES)
        }
        return URL(fileURLWithPath: "/Users/test/.Trash")
            .appendingPathComponent(url.lastPathComponent)
    }

    func calls() -> [URL] {
        recordedCalls
    }
}

@MainActor
final class FakeDiskCleanupFileRevealer: DiskCleanupFileRevealing {
    private(set) var revealedURLs: [URL] = []

    func reveal(_ url: URL) {
        revealedURLs.append(url)
    }
}

final class IncrementingDiskClock: DiskCleanupMonotonicClock,
    @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval
    private let step: TimeInterval

    init(start: TimeInterval = 0, step: TimeInterval) {
        self.value = start
        self.step = step
    }

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += step
        return current
    }
}

enum TestDiskFactory {
    static let now = Date(timeIntervalSince1970: 2_000_000_000)

    static func root(
        url: URL = URL(fileURLWithPath: "/Users/test/Downloads")
    ) -> DiskScanRoot {
        DiskScanRoot(
            id: UUID(),
            canonicalURL: url,
            identity: DiskFileIdentity(deviceID: 1, inode: 10),
            volumeID: 1,
            observedAt: now
        )
    }

    static func fingerprint(
        inode: UInt64,
        bytes: UInt64,
        ageDays: Int = 1,
        links: UInt64 = 1
    ) -> DiskFileFingerprint {
        let modified = now.addingTimeInterval(
            -TimeInterval(ageDays * 24 * 60 * 60)
        )
        return DiskFileFingerprint(
            identity: DiskFileIdentity(deviceID: 1, inode: inode),
            logicalBytes: bytes,
            modifiedAt: timestamp(modified),
            changedAt: timestamp(modified),
            hardLinkCount: links
        )
    }

    static func observation(
        root: DiskScanRoot,
        name: String,
        inode: UInt64,
        bytes: UInt64,
        allocatedBytes: UInt64? = nil,
        ageDays: Int = 1,
        links: UInt64 = 1,
        kind: DiskEntryKind = .regularFile,
        isHidden: Bool = false,
        isLocal: Bool = true,
        isUbiquitous: Bool = false,
        isDownloaded: Bool = true,
        isReadable: Bool = true
    ) -> DiskFileObservation {
        let url = root.canonicalURL.appendingPathComponent(name)
        return DiskFileObservation(
            sourceURL: url,
            canonicalURL: url,
            kind: kind,
            fingerprint: kind == .symbolicLink
                ? nil
                : fingerprint(
                    inode: inode,
                    bytes: bytes,
                    ageDays: ageDays,
                    links: links
                ),
            allocatedBytes: allocatedBytes ?? bytes,
            isHidden: isHidden,
            isLocal: isLocal,
            isUbiquitous: isUbiquitous,
            isDownloaded: isDownloaded,
            isReadable: isReadable
        )
    }

    static func candidate(
        root: DiskScanRoot,
        name: String,
        inode: UInt64,
        bytes: UInt64
    ) -> DiskCleanupCandidate {
        let observation = observation(
            root: root,
            name: name,
            inode: inode,
            bytes: bytes
        )
        return DiskCleanupCandidate(
            id: UUID(),
            rootID: root.id,
            sourceURL: observation.sourceURL,
            canonicalURL: observation.canonicalURL,
            fingerprint: observation.fingerprint!,
            allocatedBytesEstimate: observation.allocatedBytes!,
            observedAt: now,
            rule: .large
        )
    }

    static func preparedPlan(
        root: DiskScanRoot,
        candidates: [DiskCleanupCandidate]
    ) async throws -> (
        plan: PreparedCleanupPlan,
        permit: RemediationExecutionPermit,
        coordinator: RemediationCoordinator
    ) {
        let coordinator = RemediationCoordinator()
        let evidence = UUID()
        let selection = UUID()
        let remediation = await coordinator.prepare(
            kind: .diskReclamation,
            evidenceVersion: evidence,
            selectionID: selection,
            risk: .recoverable,
            now: now
        )
        let plan = PreparedCleanupPlan(
            remediation: remediation,
            scanSessionID: evidence,
            policyVersion: DiskScanPolicy.v1.version,
            root: root,
            selectedCandidates: candidates,
            estimatedBytes: candidates.reduce(0) {
                $0 + $1.allocatedBytesEstimate
            }
        )
        let permit = try await coordinator.confirm(
            preparedID: remediation.id,
            evidenceVersion: evidence,
            selectionID: selection,
            risk: .recoverable,
            now: now.addingTimeInterval(1)
        )
        return (plan, permit, coordinator)
    }

    private static func timestamp(_ date: Date) -> DiskFileTimestamp {
        let seconds = floor(date.timeIntervalSince1970)
        let fractional = date.timeIntervalSince1970 - seconds
        return DiskFileTimestamp(
            seconds: Int64(seconds),
            nanoseconds: Int32(fractional * 1_000_000_000)
        )
    }
}
