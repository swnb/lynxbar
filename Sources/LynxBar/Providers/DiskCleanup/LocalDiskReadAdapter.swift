import Darwin
import Foundation

struct LocalDiskReadAdapter: DiskDirectoryReading {
    private let homeURL: URL
    private let mountedVolumeRoots: [URL]?

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        mountedVolumeRoots: [URL]? = nil
    ) {
        self.homeURL = homeURL.standardizedFileURL.resolvingSymlinksInPath()
        self.mountedVolumeRoots = mountedVolumeRoots?.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    /// Validates that the requested cleanup root is a readable local non-package directory within allowed user/external scope.
    func validateRoot(_ request: DiskScanRequest) async throws -> DiskScanRoot {
        let requested = request.rootURL.standardizedFileURL
        let requestedStat = try Self.readStat(at: requested)
        guard Self.kind(from: requestedStat) != .symbolicLink else {
            throw DiskCleanupError.unsafeRoot(.symbolicLink)
        }

        let canonical = requested.resolvingSymlinksInPath()
        let info = try Self.readStat(at: canonical)
        guard Self.kind(from: info) == .directory else {
            throw DiskCleanupError.unsafeRoot(.notDirectory)
        }

        let values: URLResourceValues
        do {
            values = try canonical.resourceValues(forKeys: [
                .isDirectoryKey,
                .isPackageKey,
                .isReadableKey,
                .volumeIsLocalKey,
            ])
        } catch {
            Log.app.warning(
                "Failed to inspect root resource values at \(canonical.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            throw DiskCleanupError.unsafeRoot(.unavailable)
        }
        guard values.isDirectory == true else {
            throw DiskCleanupError.unsafeRoot(.notDirectory)
        }
        guard values.isPackage != true,
              canonical.pathExtension.lowercased() != "app" else {
            throw DiskCleanupError.unsafeRoot(.packageOrApplication)
        }
        guard values.volumeIsLocal == true else {
            throw DiskCleanupError.unsafeRoot(.notLocal)
        }
        guard values.isReadable != false else {
            throw DiskCleanupError.unsafeRoot(.unavailable)
        }

        let volumeRoot = Self.volumeRoot(
            containing: canonical,
            mountedVolumeRoots: mountedVolumeRoots
        )
        guard canonical.pathComponents != volumeRoot.pathComponents else {
            throw DiskCleanupError.unsafeRoot(.volumeRoot)
        }

        let libraryURL = homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .standardizedFileURL
        if canonical.pathComponents == homeURL.pathComponents {
            throw DiskCleanupError.unsafeRoot(.homeRoot)
        }
        if DiskCleanupPolicyEvaluator.isSameOrDescendant(
            canonical,
            of: libraryURL
        ) {
            throw DiskCleanupError.unsafeRoot(.userLibrary)
        }

        let isHomeDescendant = DiskCleanupPolicyEvaluator.isDescendant(
            canonical,
            of: homeURL
        )
        let isExternalVolumeDescendant =
            volumeRoot.pathComponents != ["/"]
            && DiskCleanupPolicyEvaluator.isDescendant(
                canonical,
                of: volumeRoot
            )
        guard isHomeDescendant || isExternalVolumeDescendant else {
            throw DiskCleanupError.unsafeRoot(.outsideAllowedScope)
        }

        let fingerprint = Self.fingerprint(from: info)
        return DiskScanRoot(
            id: UUID(),
            canonicalURL: canonical,
            identity: fingerprint.identity,
            volumeID: fingerprint.identity.deviceID,
            observedAt: request.requestedAt
        )
    }

    func entries(
        beneath root: DiskScanRoot
    ) async -> AsyncThrowingStream<DiskEntry, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(512)) {
            continuation in
            let producer = Task.detached(priority: .utility) {
                Self.enumerateSynchronously(
                    root: root,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    func observe(_ entry: DiskEntry) async throws -> DiskFileObservation {
        try Task.checkCancellation()
        return try Self.observeSynchronously(entry)
    }

    func availableCapacity(for root: DiskScanRoot) async throws -> UInt64? {
        try await Task.detached(priority: .utility) {
            let values = try root.canonicalURL.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            if let important = values.volumeAvailableCapacityForImportantUsage,
               important >= 0 {
                return UInt64(important)
            }
            if let available = values.volumeAvailableCapacity,
               available >= 0 {
                return UInt64(available)
            }
            return nil
        }.value
    }

    static func observeSynchronously(
        _ entry: DiskEntry
    ) throws -> DiskFileObservation {
        let info = try readStat(at: entry.url)
        let entryKind = kind(from: info)
        let keys: Set<URLResourceKey> = [
            .isPackageKey,
            .isHiddenKey,
            .isReadableKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .volumeIsLocalKey,
        ]
        let values: URLResourceValues
        do {
            values = try entry.url.resourceValues(forKeys: keys)
        } catch {
            throw DiskCleanupError.sourceUnavailable
        }

        let kind: DiskEntryKind
        if entryKind == .directory,
           entry.url.pathExtension.lowercased() == "app" {
            kind = .application
        } else if entryKind == .directory, values.isPackage == true {
            kind = .package
        } else {
            kind = entryKind
        }

        let canonicalURL = kind == .symbolicLink
            ? entry.url.standardizedFileURL
            : entry.url.standardizedFileURL.resolvingSymlinksInPath()
        let allocated = values.totalFileAllocatedSize
            ?? values.fileAllocatedSize
        let allocatedBytes = allocated.flatMap {
            $0 >= 0 ? UInt64($0) : nil
        }
        let ubiquitous = values.isUbiquitousItem == true
        let downloaded = !ubiquitous
            || values.ubiquitousItemDownloadingStatus == .current

        return DiskFileObservation(
            sourceURL: entry.url.standardizedFileURL,
            canonicalURL: canonicalURL,
            kind: kind,
            fingerprint: kind == .symbolicLink
                ? nil
                : fingerprint(from: info),
            allocatedBytes: allocatedBytes,
            isHidden: values.isHidden == true,
            isLocal: values.volumeIsLocal == true,
            isUbiquitous: ubiquitous,
            isDownloaded: downloaded,
            isReadable: values.isReadable != false
        )
    }

    static func readStat(at url: URL) throws -> stat {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &info)
        }
        guard result == 0 else {
            if let code = POSIXErrorCode(rawValue: errno) {
                throw POSIXError(code)
            }
            throw DiskCleanupError.sourceUnavailable
        }
        return info
    }

    static func kind(from info: stat) -> DiskEntryKind {
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            return .regularFile
        case S_IFDIR:
            return .directory
        case S_IFLNK:
            return .symbolicLink
        default:
            return .other
        }
    }

    static func fingerprint(from info: stat) -> DiskFileFingerprint {
        DiskFileFingerprint(
            identity: DiskFileIdentity(
                deviceID: UInt64(truncatingIfNeeded: info.st_dev),
                inode: UInt64(truncatingIfNeeded: info.st_ino)
            ),
            logicalBytes: info.st_size > 0 ? UInt64(info.st_size) : 0,
            modifiedAt: DiskFileTimestamp(
                seconds: Int64(info.st_mtimespec.tv_sec),
                nanoseconds: Int32(info.st_mtimespec.tv_nsec)
            ),
            changedAt: DiskFileTimestamp(
                seconds: Int64(info.st_ctimespec.tv_sec),
                nanoseconds: Int32(info.st_ctimespec.tv_nsec)
            ),
            hardLinkCount: UInt64(info.st_nlink)
        )
    }

    private static func volumeRoot(
        containing url: URL,
        mountedVolumeRoots: [URL]?
    ) -> URL {
        let mounted: [URL]
        if let mountedVolumeRoots {
            mounted = mountedVolumeRoots
        } else {
            mounted = FileManager().mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeIsLocalKey],
                options: [.skipHiddenVolumes]
            ) ?? []
        }
        return mounted
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter {
                DiskCleanupPolicyEvaluator.isSameOrDescendant(url, of: $0)
            }
            .max { $0.pathComponents.count < $1.pathComponents.count }
            ?? URL(fileURLWithPath: "/")
    }

    private static func enumerateSynchronously(
        root: DiskScanRoot,
        continuation: AsyncThrowingStream<DiskEntry, Error>.Continuation
    ) {
        let manager = FileManager()
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .isHiddenKey,
            .isReadableKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .volumeIsLocalKey,
        ]
        guard let enumerator = manager.enumerator(
            at: root.canonicalURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            continuation.finish(
                throwing: DiskCleanupError.enumerationFailed
            )
            return
        }

        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            if case .terminated = continuation.yield(DiskEntry(url: url)) {
                return
            }
        }
        continuation.finish()
    }
}
