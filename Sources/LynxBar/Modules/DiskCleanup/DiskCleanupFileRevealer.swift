import AppKit

@MainActor
protocol DiskCleanupFileRevealing: AnyObject {
    func reveal(_ url: URL)
}

@MainActor
final class LocalDiskCleanupFileRevealer: DiskCleanupFileRevealing {
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
