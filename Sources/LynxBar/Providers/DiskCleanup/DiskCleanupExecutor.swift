import Darwin
import Foundation

actor DiskCleanupExecutor {
    private let reader: any DiskDirectoryReading
    private let trash: any DiskTrashMoving
    private let ledger: SessionActionLedger
    private let now: @Sendable () -> Date
    private var consumedPlanIDs = Set<UUID>()

    init(
        reader: any DiskDirectoryReading,
        trash: any DiskTrashMoving,
        ledger: SessionActionLedger,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reader = reader
        self.trash = trash
        self.ledger = ledger
        self.now = now
    }

    func execute(
        plan: PreparedCleanupPlan,
        permit: RemediationExecutionPermit
    ) async throws -> DiskCleanupBatchResult {
        try validate(plan: plan, permit: permit)
        guard consumedPlanIDs.insert(plan.id).inserted else {
            throw DiskCleanupError.alreadyExecuted
        }

        var results: [DiskCleanupItemResult] = []
        for (index, candidate) in plan.selectedCandidates.enumerated() {
            if Task.isCancelled {
                let remaining = plan.selectedCandidates[index...].map {
                    cancelledResult(for: $0)
                }
                for result in remaining {
                    await ledger.append(result, planID: plan.id)
                }
                results.append(contentsOf: remaining)
                break
            }

            let result = await executeOne(candidate, plan: plan)
            results.append(result)
            await ledger.append(result, planID: plan.id)
        }

        return DiskCleanupBatchResult(
            planID: plan.id,
            items: results,
            stagedBytes: saturatingSum(
                results.lazy
                    .filter { $0.status == .staged }
                    .map(\.stagedBytes)
            )
        )
    }

    private func validate(
        plan: PreparedCleanupPlan,
        permit: RemediationExecutionPermit
    ) throws {
        guard plan.id == permit.preparedID,
              plan.remediation.evidenceVersion == permit.evidenceVersion,
              plan.scanSessionID == plan.remediation.evidenceVersion,
              plan.selectionID == permit.selectionID,
              plan.remediation.risk == .recoverable,
              plan.policyVersion == DiskScanPolicy.v1.version,
              now() < plan.remediation.expiresAt,
              !plan.selectedCandidates.isEmpty else {
            throw DiskCleanupError.invalidExecutionPermit
        }
        let candidateIDs = plan.selectedCandidates.map(\.id)
        guard Set(candidateIDs).count == candidateIDs.count,
              plan.selectedCandidates.allSatisfy({
                  $0.rootID == plan.root.id
              }),
              saturatingSum(
                  plan.selectedCandidates.lazy.map(
                      \.allocatedBytesEstimate
                  )
              ) == plan.estimatedBytes else {
            throw DiskCleanupError.invalidPreparedPlan
        }
    }

    /// Revalidates a single cleanup candidate against the root and moves it to Trash if unchanged.
    private func executeOne(
        _ candidate: DiskCleanupCandidate,
        plan: PreparedCleanupPlan
    ) async -> DiskCleanupItemResult {
        do {
            let currentRoot = try await reader.validateRoot(DiskScanRequest(
                rootURL: plan.root.canonicalURL,
                policy: .v1,
                requestedAt: now()
            ))
            guard currentRoot.canonicalURL.pathComponents
                    == plan.root.canonicalURL.pathComponents,
                  currentRoot.identity == plan.root.identity,
                  currentRoot.volumeID == plan.root.volumeID else {
                return staleResult(for: candidate)
            }

            let observation = try await reader.observe(
                DiskEntry(url: candidate.sourceURL)
            )
            guard isStillSameCandidate(
                observation,
                candidate: candidate,
                root: plan.root
            ) else {
                return staleResult(for: candidate)
            }

            let trashURL = try await trash.moveToTrash(candidate.sourceURL)
            return DiskCleanupItemResult(
                candidateID: candidate.id,
                displayName: candidate.sourceURL.lastPathComponent,
                status: .staged,
                stagedBytes: candidate.allocatedBytesEstimate,
                trashURL: trashURL,
                errorCategory: nil
            )
        } catch {
            let category = classify(error)
            if category == .notFound {
                Log.app.debug(
                    "Disk cleanup candidate missing during execution at \(candidate.sourceURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
                )
                return staleResult(for: candidate)
            }
            Log.app.error(
                "Disk cleanup failed for \(candidate.sourceURL.path, privacy: .private) (\(String(describing: category), privacy: .public)): \(error.localizedDescription, privacy: .private)"
            )
            return DiskCleanupItemResult(
                candidateID: candidate.id,
                displayName: candidate.sourceURL.lastPathComponent,
                status: .failed,
                stagedBytes: 0,
                trashURL: nil,
                errorCategory: category
            )
        }
    }

    private func isStillSameCandidate(
        _ observation: DiskFileObservation,
        candidate: DiskCleanupCandidate,
        root: DiskScanRoot
    ) -> Bool {
        guard observation.kind == .regularFile,
              observation.isLocal,
              observation.isReadable,
              !observation.isHidden,
              !observation.isUbiquitous || observation.isDownloaded,
              DiskCleanupPolicyEvaluator.isDescendant(
                  observation.canonicalURL,
                  of: root.canonicalURL
              ),
              observation.canonicalURL.pathComponents
                == candidate.canonicalURL.pathComponents,
              observation.fingerprint == candidate.fingerprint,
              observation.fingerprint?.hardLinkCount == 1 else {
            return false
        }
        return true
    }

    private func staleResult(
        for candidate: DiskCleanupCandidate
    ) -> DiskCleanupItemResult {
        DiskCleanupItemResult(
            candidateID: candidate.id,
            displayName: candidate.sourceURL.lastPathComponent,
            status: .stale,
            stagedBytes: 0,
            trashURL: nil,
            errorCategory: nil
        )
    }

    private func cancelledResult(
        for candidate: DiskCleanupCandidate
    ) -> DiskCleanupItemResult {
        DiskCleanupItemResult(
            candidateID: candidate.id,
            displayName: candidate.sourceURL.lastPathComponent,
            status: .cancelled,
            stagedBytes: 0,
            trashURL: nil,
            errorCategory: nil
        )
    }

    private func classify(_ error: Error) -> DiskActionErrorCategory {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(ENOENT):
                return .notFound
            case Int(EACCES), Int(EPERM):
                return .permissionDenied
            case Int(EROFS):
                return .readOnlyVolume
            case Int(EBUSY):
                return .busy
            default:
                return .unknown
            }
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError:
                return .notFound
            case NSFileReadNoPermissionError,
                 NSFileWriteNoPermissionError:
                return .permissionDenied
            case NSFileWriteVolumeReadOnlyError:
                return .readOnlyVolume
            default:
                return .unknown
            }
        }
        if error as? DiskCleanupError == .sourceUnavailable {
            return .unavailable
        }
        return .unknown
    }

    private func saturatingSum<S: Sequence>(
        _ values: S
    ) -> UInt64 where S.Element == UInt64 {
        values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? UInt64.max : sum
        }
    }
}
