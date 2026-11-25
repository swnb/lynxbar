import XCTest

final class DiskCleanupSourceBoundaryTests: XCTestCase {
    func testCleanupProductionSourcesHaveOneMutationBoundary() throws {
        let root = projectRoot()
        let scopedDirectories = [
            "Sources/LynxBar/Kit/Remediation",
            "Sources/LynxBar/Providers/DiskCleanup",
            "Sources/LynxBar/Modules/DiskCleanup",
        ]
        let sourceFiles = try scopedDirectories.flatMap {
            try swiftFiles(beneath: root.appendingPathComponent($0))
        }
        let forbiddenTokens = [
            ".removeItem(",
            ".moveItem(",
            ".replaceItem(",
            ".copyItem(",
            "createFile(",
            "recycleURLs",
            "emptyTrash",
            "/bin/rm",
            "/usr/bin/rm",
            "Process(",
            "posix_spawn",
            "execve(",
            "Darwin.system(",
            "Glibc.system(",
        ]
        let mutationProtocolAllowlist = Set([
            "DiskCleanupProtocols.swift",
            "DiskCleanupExecutor.swift",
            "LocalDiskTrashAdapter.swift",
        ])
        var directTrashCallFiles: [String] = []
        var directFinderRevealFiles: [String] = []

        for file in sourceFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(
                    contents.contains(token),
                    "\(file.lastPathComponent) contains forbidden cleanup token \(token)"
                )
            }
            if contents.contains(".trashItem(") {
                directTrashCallFiles.append(file.lastPathComponent)
            }
            if contents.contains(".activateFileViewerSelecting(") {
                directFinderRevealFiles.append(file.lastPathComponent)
            }
            if contents.contains("DiskTrashMoving") {
                XCTAssertTrue(
                    mutationProtocolAllowlist.contains(file.lastPathComponent),
                    "\(file.lastPathComponent) bypasses the executor mutation boundary"
                )
            }
        }

        XCTAssertEqual(
            directTrashCallFiles,
            ["LocalDiskTrashAdapter.swift"]
        )
        XCTAssertEqual(
            directFinderRevealFiles,
            ["DiskCleanupFileRevealer.swift"]
        )
    }

    func testSessionLedgerHasNoPersistenceOrPathLoggingExit() throws {
        let ledger = projectRoot()
            .appendingPathComponent(
                "Sources/LynxBar/Providers/DiskCleanup/SessionActionLedger.swift"
            )
        let contents = try String(contentsOf: ledger, encoding: .utf8)
        for token in [
            "UserDefaults",
            "FileHandle",
            "write(to:",
            "os_log",
            "Logger(",
            "SQLite",
        ] {
            XCTAssertFalse(
                contents.contains(token),
                "Session ledger must remain in memory; found \(token)"
            )
        }
    }

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftFiles(beneath directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension == "swift" else {
                return nil
            }
            return url
        }
        .sorted { $0.path < $1.path }
    }
}
