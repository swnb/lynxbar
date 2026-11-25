import AppKit
import UniformTypeIdentifiers

@MainActor
protocol DiskCleanupDirectoryPicking: AnyObject {
    func chooseDirectory() async -> URL?
}

@MainActor
final class LocalDiskCleanupDirectoryPicker: DiskCleanupDirectoryPicking {
    func chooseDirectory() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString(
            "Choose a folder to scan",
            comment: ""
        )
        panel.message = NSLocalizedString(
            "LynxBar scans only this folder. Nothing is moved until you review and confirm individual files.",
            comment: ""
        )
        panel.prompt = NSLocalizedString("Choose Folder", comment: "")
        panel.allowedContentTypes = [.folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(
                    returning: response == .OK ? panel.url : nil
                )
            }
        }
    }
}

