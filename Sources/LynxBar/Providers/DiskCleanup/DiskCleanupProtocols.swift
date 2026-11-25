import Foundation

protocol DiskDirectoryReading: Sendable {
    func validateRoot(_ request: DiskScanRequest) async throws -> DiskScanRoot
    func entries(
        beneath root: DiskScanRoot
    ) async -> AsyncThrowingStream<DiskEntry, Error>
    func observe(_ entry: DiskEntry) async throws -> DiskFileObservation
    func availableCapacity(for root: DiskScanRoot) async throws -> UInt64?
}

protocol DiskTrashMoving: Sendable {
    func moveToTrash(_ url: URL) async throws -> URL
}

protocol DiskCleanupScanning: Sendable {
    func events(
        for request: DiskScanRequest
    ) -> AsyncThrowingStream<DiskScanEvent, Error>
}

protocol DiskCleanupMonotonicClock: Sendable {
    func now() -> TimeInterval
}

struct SystemDiskCleanupMonotonicClock: DiskCleanupMonotonicClock {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
