import Foundation
import XCTest
@testable import LynxBar

final class LocalDiskTrashIntegrationTests: XCTestCase {
    func testDisposableFileCanBeTrashedAndRestored() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[
                "STATS_RUN_LIVE_TRASH_TEST"
            ] == "1",
            "Set STATS_RUN_LIVE_TRASH_TEST=1 for the recoverable native integration."
        )

        let manager = FileManager()
        let fixtureRoot = manager.temporaryDirectory.appendingPathComponent(
            "lynxbar-live-trash-\(UUID().uuidString)",
            isDirectory: true
        )
        let fakeHome = fixtureRoot.appendingPathComponent(
            "home",
            isDirectory: true
        )
        let scanRootURL = fakeHome.appendingPathComponent(
            "Downloads",
            isDirectory: true
        )
        let sourceURL = scanRootURL.appendingPathComponent(
            "disposable-\(UUID().uuidString).txt"
        )
        try manager.createDirectory(
            at: scanRootURL,
            withIntermediateDirectories: true
        )
        let payload = Data("LynxBar disposable Trash integration\n".utf8)
        try payload.write(to: sourceURL, options: .atomic)

        var stagedURL: URL?
        defer {
            // 若断言中途失败，尽力先把本测试创建的文件从废纸篓恢复。
            if let stagedURL,
               manager.fileExists(atPath: stagedURL.path),
               !manager.fileExists(atPath: sourceURL.path) {
                try? manager.moveItem(at: stagedURL, to: sourceURL)
            }
            try? manager.removeItem(at: fixtureRoot)
        }

        let reader = LocalDiskReadAdapter(homeURL: fakeHome)
        let root = try await reader.validateRoot(
            DiskScanRequest(rootURL: scanRootURL)
        )
        let observation = try await reader.observe(
            DiskEntry(url: sourceURL)
        )
        let permissiveTestPolicy = DiskScanPolicy(
            version: DiskScanPolicy.v1.version,
            largeFileBytes: 1,
            oldFileMinimumBytes: 1,
            oldFileMinimumAge: 0,
            maximumEntries: 10,
            maximumDuration: 5,
            maximumConcurrentMetadataReads: 1,
            progressEntryInterval: 1,
            progressTimeInterval: 0.01
        )
        let candidate: DiskCleanupCandidate
        switch DiskCleanupPolicyEvaluator.evaluate(
            observation,
            root: root,
            policy: permissiveTestPolicy,
            now: Date()
        ) {
        case .success(let value):
            candidate = value
        case .failure(let reason):
            XCTFail("Disposable fixture was unexpectedly excluded: \(reason)")
            return
        }

        let coordinator = RemediationCoordinator()
        let sessionID = UUID()
        let selectionID = UUID()
        let remediation = await coordinator.prepare(
            kind: .diskReclamation,
            evidenceVersion: sessionID,
            selectionID: selectionID,
            risk: .recoverable
        )
        let plan = PreparedCleanupPlan(
            remediation: remediation,
            scanSessionID: sessionID,
            policyVersion: DiskScanPolicy.v1.version,
            root: root,
            selectedCandidates: [candidate],
            estimatedBytes: candidate.allocatedBytesEstimate
        )
        let permit = try await coordinator.confirm(
            preparedID: remediation.id,
            evidenceVersion: sessionID,
            selectionID: selectionID,
            risk: .recoverable
        )
        let executor = DiskCleanupExecutor(
            reader: reader,
            trash: LocalDiskTrashAdapter(),
            ledger: SessionActionLedger()
        )

        let result = try await executor.execute(
            plan: plan,
            permit: permit
        )
        let returnedURL = try XCTUnwrap(result.items.first?.trashURL)
        stagedURL = returnedURL
        XCTAssertEqual(result.items.first?.status, .staged)
        XCTAssertFalse(manager.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(manager.fileExists(atPath: returnedURL.path))

        try manager.moveItem(at: returnedURL, to: sourceURL)
        stagedURL = nil
        XCTAssertEqual(try Data(contentsOf: sourceURL), payload)
    }
}
