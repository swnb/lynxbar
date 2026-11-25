import Foundation

enum DiskCleanupPolicyEvaluator {
    static func evaluate(
        _ observation: DiskFileObservation,
        root: DiskScanRoot,
        policy: DiskScanPolicy,
        now: Date
    ) -> Result<DiskCleanupCandidate, DiskExclusionReason> {
        guard isDescendant(
            observation.canonicalURL,
            of: root.canonicalURL
        ) else {
            return .failure(.outsideRoot)
        }

        switch observation.kind {
        case .directory:
            return .failure(.directory)
        case .symbolicLink:
            return .failure(.symbolicLink)
        case .package:
            return .failure(.package)
        case .application:
            return .failure(.application)
        case .other:
            return .failure(.notRegular)
        case .regularFile:
            break
        }

        guard !observation.isHidden else { return .failure(.hidden) }
        guard observation.isLocal else { return .failure(.nonLocal) }
        guard observation.isReadable else { return .failure(.inaccessible) }
        guard !observation.isUbiquitous || observation.isDownloaded else {
            return .failure(.cloudPlaceholder)
        }
        guard let fingerprint = observation.fingerprint else {
            return .failure(.metadataUnavailable)
        }
        guard fingerprint.hardLinkCount == 1 else {
            return .failure(.hardLinked)
        }

        let estimate = observation.allocatedBytes ?? fingerprint.logicalBytes
        let modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(
                fingerprint.modifiedAt.seconds
            ) + TimeInterval(fingerprint.modifiedAt.nanoseconds) / 1_000_000_000
        )
        let age = max(0, now.timeIntervalSince(modifiedAt))
        let rule: DiskCleanupRule
        if estimate >= policy.largeFileBytes {
            rule = .large
        } else if estimate >= policy.oldFileMinimumBytes,
                  age >= policy.oldFileMinimumAge {
            rule = .oldAndLarge
        } else {
            return .failure(.belowThreshold)
        }

        return .success(DiskCleanupCandidate(
            id: UUID(),
            rootID: root.id,
            sourceURL: observation.sourceURL,
            canonicalURL: observation.canonicalURL,
            fingerprint: fingerprint,
            allocatedBytesEstimate: estimate,
            observedAt: now,
            rule: rule
        ))
    }

    static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count else {
            return false
        }
        return candidateComponents.prefix(rootComponents.count)
            .elementsEqual(rootComponents)
    }

    static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else {
            return false
        }
        return candidateComponents.prefix(rootComponents.count)
            .elementsEqual(rootComponents)
    }
}

