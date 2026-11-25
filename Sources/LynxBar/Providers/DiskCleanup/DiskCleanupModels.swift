import Foundation

struct DiskFileIdentity: Sendable, Hashable {
    let deviceID: UInt64
    let inode: UInt64
}

struct DiskFileTimestamp: Sendable, Hashable {
    let seconds: Int64
    let nanoseconds: Int32
}

struct DiskFileFingerprint: Sendable, Hashable {
    let identity: DiskFileIdentity
    let logicalBytes: UInt64
    let modifiedAt: DiskFileTimestamp
    let changedAt: DiskFileTimestamp
    let hardLinkCount: UInt64
}

enum DiskEntryKind: Sendable, Equatable {
    case regularFile
    case directory
    case symbolicLink
    case package
    case application
    case other
}

struct DiskEntry: Sendable, Hashable {
    let url: URL
}

struct DiskFileObservation: Sendable, Equatable {
    let sourceURL: URL
    let canonicalURL: URL
    let kind: DiskEntryKind
    let fingerprint: DiskFileFingerprint?
    let allocatedBytes: UInt64?
    let isHidden: Bool
    let isLocal: Bool
    let isUbiquitous: Bool
    let isDownloaded: Bool
    let isReadable: Bool
}

struct DiskScanRoot: Sendable, Equatable, Identifiable {
    let id: UUID
    let canonicalURL: URL
    let identity: DiskFileIdentity
    let volumeID: UInt64
    let observedAt: Date
}

enum DiskCleanupRule: String, Sendable, Equatable {
    case large
    case oldAndLarge
}

enum DiskExclusionReason: String, Error, Sendable, Hashable, CaseIterable {
    case directory
    case symbolicLink
    case package
    case application
    case hidden
    case cloudPlaceholder
    case inaccessible
    case hardLinked
    case nonLocal
    case notRegular
    case outsideRoot
    case belowThreshold
    case metadataUnavailable
}

struct DiskCleanupCandidate: Sendable, Equatable, Identifiable {
    let id: UUID
    let rootID: UUID
    let sourceURL: URL
    let canonicalURL: URL
    let fingerprint: DiskFileFingerprint
    let allocatedBytesEstimate: UInt64
    let observedAt: Date
    let rule: DiskCleanupRule

    var logicalBytes: UInt64 { fingerprint.logicalBytes }
    var modifiedAt: Date {
        Date(
            timeIntervalSince1970: TimeInterval(fingerprint.modifiedAt.seconds)
                + TimeInterval(fingerprint.modifiedAt.nanoseconds) / 1_000_000_000
        )
    }
}

struct DiskScanPolicy: Sendable, Equatable {
    static let v1 = DiskScanPolicy(
        version: 1,
        largeFileBytes: 1_073_741_824,
        oldFileMinimumBytes: 104_857_600,
        oldFileMinimumAge: 90 * 24 * 60 * 60,
        maximumEntries: 100_000,
        maximumDuration: 60,
        maximumConcurrentMetadataReads: 4,
        progressEntryInterval: 100,
        progressTimeInterval: 0.1
    )

    let version: Int
    let largeFileBytes: UInt64
    let oldFileMinimumBytes: UInt64
    let oldFileMinimumAge: TimeInterval
    let maximumEntries: Int
    let maximumDuration: TimeInterval
    let maximumConcurrentMetadataReads: Int
    let progressEntryInterval: Int
    let progressTimeInterval: TimeInterval

    var normalized: DiskScanPolicy {
        DiskScanPolicy(
            version: version,
            largeFileBytes: largeFileBytes,
            oldFileMinimumBytes: oldFileMinimumBytes,
            oldFileMinimumAge: max(0, oldFileMinimumAge),
            maximumEntries: max(1, maximumEntries),
            maximumDuration: max(0.1, maximumDuration),
            maximumConcurrentMetadataReads: max(
                1,
                maximumConcurrentMetadataReads
            ),
            progressEntryInterval: max(1, progressEntryInterval),
            progressTimeInterval: max(0.01, progressTimeInterval)
        )
    }
}

final class DiskScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

struct DiskScanRequest: Sendable, Equatable {
    let rootURL: URL
    let policy: DiskScanPolicy
    let requestedAt: Date
    let cancellation: DiskScanCancellation?

    init(
        rootURL: URL,
        policy: DiskScanPolicy = .v1,
        requestedAt: Date = Date(),
        cancellation: DiskScanCancellation? = nil
    ) {
        self.rootURL = rootURL
        self.policy = policy.normalized
        self.requestedAt = requestedAt
        self.cancellation = cancellation
    }

    static func == (lhs: DiskScanRequest, rhs: DiskScanRequest) -> Bool {
        lhs.rootURL == rhs.rootURL
            && lhs.policy == rhs.policy
            && lhs.requestedAt == rhs.requestedAt
            && lhs.cancellation === rhs.cancellation
    }
}

struct DiskScanProgress: Sendable, Equatable {
    let observedEntries: Int
    let candidateCount: Int
    let excludedEntries: Int
    let estimatedCandidateBytes: UInt64
}

enum DiskScanStatus: Sendable, Equatable {
    case completed
    case partialEntryLimit
    case partialDeadline
    case cancelled
}

struct DiskScanResult: Sendable, Equatable {
    let sessionID: UUID
    let root: DiskScanRoot
    let policyVersion: Int
    let candidates: [DiskCleanupCandidate]
    let exclusionCounts: [DiskExclusionReason: Int]
    let observedEntries: Int
    let estimatedCandidateBytes: UInt64
    let status: DiskScanStatus
}

enum DiskScanEvent: Sendable, Equatable {
    case progress(DiskScanProgress)
    case completed(DiskScanResult)
}

enum DiskRootRejectionReason: String, Sendable, Equatable {
    case unavailable
    case notDirectory
    case symbolicLink
    case packageOrApplication
    case notLocal
    case volumeRoot
    case homeRoot
    case userLibrary
    case outsideAllowedScope
}

enum DiskCleanupError: Error, Sendable, Equatable {
    case unsafeRoot(DiskRootRejectionReason)
    case enumerationFailed
    case sourceUnavailable
    case invalidPreparedPlan
    case invalidExecutionPermit
    case alreadyExecuted
}

extension DiskCleanupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsafeRoot(let reason):
            return String(
                format: NSLocalizedString(
                    "The selected folder is not available for safe scanning (%@).",
                    comment: ""
                ),
                reason.localizedDescription
            )
        case .enumerationFailed:
            return NSLocalizedString(
                "The selected folder could not be enumerated.",
                comment: ""
            )
        case .sourceUnavailable:
            return NSLocalizedString(
                "The file system metadata is unavailable.",
                comment: ""
            )
        case .invalidPreparedPlan:
            return NSLocalizedString(
                "The cleanup preview is no longer valid.",
                comment: ""
            )
        case .invalidExecutionPermit:
            return NSLocalizedString(
                "The cleanup confirmation is no longer valid.",
                comment: ""
            )
        case .alreadyExecuted:
            return NSLocalizedString(
                "This cleanup preview has already been executed.",
                comment: ""
            )
        }
    }
}

private extension DiskRootRejectionReason {
    var localizedDescription: String {
        switch self {
        case .unavailable:
            return NSLocalizedString("unavailable", comment: "")
        case .notDirectory:
            return NSLocalizedString("not a directory", comment: "")
        case .symbolicLink:
            return NSLocalizedString("symbolic link", comment: "")
        case .packageOrApplication:
            return NSLocalizedString("application or package", comment: "")
        case .notLocal:
            return NSLocalizedString("not a local volume", comment: "")
        case .volumeRoot:
            return NSLocalizedString("volume root", comment: "")
        case .homeRoot:
            return NSLocalizedString("home folder", comment: "")
        case .userLibrary:
            return NSLocalizedString("user Library", comment: "")
        case .outsideAllowedScope:
            return NSLocalizedString("outside the allowed scope", comment: "")
        }
    }
}

struct PreparedCleanupPlan: Sendable, Equatable, Identifiable {
    let remediation: PreparedRemediation
    let scanSessionID: UUID
    let policyVersion: Int
    let root: DiskScanRoot
    let selectedCandidates: [DiskCleanupCandidate]
    let estimatedBytes: UInt64

    var id: UUID { remediation.id }
    var selectionID: UUID { remediation.selectionID }
}

enum DiskCleanupItemStatus: String, Sendable, Equatable {
    case staged
    case failed
    case stale
    case cancelled
}

enum DiskActionErrorCategory: String, Sendable, Equatable {
    case notFound
    case permissionDenied
    case readOnlyVolume
    case busy
    case unavailable
    case unknown
}

struct DiskCleanupItemResult: Sendable, Equatable, Identifiable {
    let candidateID: UUID
    let displayName: String
    let status: DiskCleanupItemStatus
    let stagedBytes: UInt64
    let trashURL: URL?
    let errorCategory: DiskActionErrorCategory?

    var id: UUID { candidateID }
}

struct DiskCleanupBatchResult: Sendable, Equatable {
    let planID: UUID
    let items: [DiskCleanupItemResult]
    let stagedBytes: UInt64

    var completion: RemediationCompletion {
        let staged = items.filter { $0.status == .staged }.count
        let cancelled = items.filter { $0.status == .cancelled }.count
        if !items.isEmpty, staged == items.count {
            return .succeeded
        }
        if staged > 0 {
            return .partial
        }
        if cancelled == items.count, !items.isEmpty {
            return .cancelled
        }
        return .failed
    }
}

struct DiskCapacityVerification: Sendable, Equatable {
    let beforeBytes: UInt64?
    let afterBytes: UInt64?

    var observedDelta: Int64? {
        guard let beforeBytes, let afterBytes else { return nil }
        if afterBytes >= beforeBytes {
            let delta = afterBytes - beforeBytes
            return delta > UInt64(Int64.max) ? Int64.max : Int64(delta)
        }
        let delta = beforeBytes - afterBytes
        // 保持返回值可安全取绝对值；Int64.min 的 abs 会触发运行时陷阱。
        return delta > UInt64(Int64.max) ? -Int64.max : -Int64(delta)
    }
}
