import XCTest
@testable import LynxBar

final class DiskCleanupExecutorTests: XCTestCase {
    func testExecutorMovesOnlyPreparedSelectedCandidates() async throws {
        let root = TestDiskFactory.root()
        let first = TestDiskFactory.candidate(
            root: root,
            name: "first.bin",
            inode: 600,
            bytes: 2_000_000_000
        )
        let second = TestDiskFactory.candidate(
            root: root,
            name: "second.bin",
            inode: 601,
            bytes: 3_000_000_000
        )
        let unselected = TestDiskFactory.candidate(
            root: root,
            name: "unselected.bin",
            inode: 602,
            bytes: 4_000_000_000
        )
        let reader = FakeDiskReader(
            root: root,
            observations: [
                observation(for: first),
                observation(for: second),
                observation(for: unselected),
            ]
        )
        let trash = FakeDiskTrashMover()
        let ledger = SessionActionLedger()
        let prepared = try await TestDiskFactory.preparedPlan(
            root: root,
            candidates: [first, second]
        )
        let executor = DiskCleanupExecutor(
            reader: reader,
            trash: trash,
            ledger: ledger,
            now: { TestDiskFactory.now.addingTimeInterval(2) }
        )

        let result = try await executor.execute(
            plan: prepared.plan,
            permit: prepared.permit
        )

        let calls = await trash.calls()
        XCTAssertEqual(calls, [first.sourceURL, second.sourceURL])
        XCTAssertFalse(calls.contains(unselected.sourceURL))
        XCTAssertEqual(result.items.map(\.status), [.staged, .staged])
        XCTAssertEqual(
            result.items.compactMap(\.trashURL),
            [
                URL(fileURLWithPath: "/Users/test/.Trash/first.bin"),
                URL(fileURLWithPath: "/Users/test/.Trash/second.bin"),
            ]
        )
        XCTAssertEqual(
            result.stagedBytes,
            first.allocatedBytesEstimate + second.allocatedBytesEstimate
        )
        let ledgerEntries = await ledger.entries(for: prepared.plan.id)
        XCTAssertEqual(ledgerEntries, result.items)
    }

    func testFingerprintChangeIsStaleAndNeverReachesTrashAdapter()
        async throws {
        let root = TestDiskFactory.root()
        let candidate = TestDiskFactory.candidate(
            root: root,
            name: "changed.bin",
            inode: 610,
            bytes: 2_000_000_000
        )
        let changed = DiskFileObservation(
            sourceURL: candidate.sourceURL,
            canonicalURL: candidate.canonicalURL,
            kind: .regularFile,
            fingerprint: TestDiskFactory.fingerprint(
                inode: 610,
                bytes: 2_000_000_001
            ),
            allocatedBytes: 2_000_000_001,
            isHidden: false,
            isLocal: true,
            isUbiquitous: false,
            isDownloaded: true,
            isReadable: true
        )
        let reader = FakeDiskReader(
            root: root,
            observations: [changed]
        )
        let trash = FakeDiskTrashMover()
        let prepared = try await TestDiskFactory.preparedPlan(
            root: root,
            candidates: [candidate]
        )
        let executor = DiskCleanupExecutor(
            reader: reader,
            trash: trash,
            ledger: SessionActionLedger(),
            now: { TestDiskFactory.now.addingTimeInterval(2) }
        )

        let result = try await executor.execute(
            plan: prepared.plan,
            permit: prepared.permit
        )

        XCTAssertEqual(result.items.first?.status, .stale)
        let calls = await trash.calls()
        XCTAssertEqual(calls, [])
    }

    func testBatchPreservesPartialTruthAfterPermissionFailure() async throws {
        let root = TestDiskFactory.root()
        let first = TestDiskFactory.candidate(
            root: root,
            name: "first.bin",
            inode: 620,
            bytes: 2_000_000_000
        )
        let denied = TestDiskFactory.candidate(
            root: root,
            name: "denied.bin",
            inode: 621,
            bytes: 3_000_000_000
        )
        let last = TestDiskFactory.candidate(
            root: root,
            name: "last.bin",
            inode: 622,
            bytes: 4_000_000_000
        )
        let reader = FakeDiskReader(
            root: root,
            observations: [
                observation(for: first),
                observation(for: denied),
                observation(for: last),
            ]
        )
        let trash = FakeDiskTrashMover(
            failingURLs: [denied.sourceURL]
        )
        let prepared = try await TestDiskFactory.preparedPlan(
            root: root,
            candidates: [first, denied, last]
        )
        let executor = DiskCleanupExecutor(
            reader: reader,
            trash: trash,
            ledger: SessionActionLedger(),
            now: { TestDiskFactory.now.addingTimeInterval(2) }
        )

        let result = try await executor.execute(
            plan: prepared.plan,
            permit: prepared.permit
        )

        XCTAssertEqual(
            result.items.map(\.status),
            [.staged, .failed, .staged]
        )
        XCTAssertEqual(
            result.items[1].errorCategory,
            .permissionDenied
        )
        XCTAssertEqual(result.completion, .partial)
    }

    func testSamePreparedPlanCannotExecuteTwice() async throws {
        let root = TestDiskFactory.root()
        let candidate = TestDiskFactory.candidate(
            root: root,
            name: "once.bin",
            inode: 630,
            bytes: 2_000_000_000
        )
        let reader = FakeDiskReader(
            root: root,
            observations: [observation(for: candidate)]
        )
        let trash = FakeDiskTrashMover()
        let prepared = try await TestDiskFactory.preparedPlan(
            root: root,
            candidates: [candidate]
        )
        let executor = DiskCleanupExecutor(
            reader: reader,
            trash: trash,
            ledger: SessionActionLedger(),
            now: { TestDiskFactory.now.addingTimeInterval(2) }
        )

        _ = try await executor.execute(
            plan: prepared.plan,
            permit: prepared.permit
        )
        do {
            _ = try await executor.execute(
                plan: prepared.plan,
                permit: prepared.permit
            )
            XCTFail("A consumed cleanup plan must be one-shot")
        } catch {
            XCTAssertEqual(
                error as? DiskCleanupError,
                .alreadyExecuted
            )
        }
        let calls = await trash.calls()
        XCTAssertEqual(calls.count, 1)
    }

    func testWrongPermitHasZeroSideEffects() async throws {
        let root = TestDiskFactory.root()
        let candidate = TestDiskFactory.candidate(
            root: root,
            name: "blocked.bin",
            inode: 640,
            bytes: 2_000_000_000
        )
        let reader = FakeDiskReader(
            root: root,
            observations: [observation(for: candidate)]
        )
        let trash = FakeDiskTrashMover()
        let prepared = try await TestDiskFactory.preparedPlan(
            root: root,
            candidates: [candidate]
        )
        let wrongPermit = RemediationExecutionPermit(
            id: UUID(),
            preparedID: UUID(),
            evidenceVersion: prepared.permit.evidenceVersion,
            selectionID: prepared.permit.selectionID,
            issuedAt: prepared.permit.issuedAt
        )
        let executor = DiskCleanupExecutor(
            reader: reader,
            trash: trash,
            ledger: SessionActionLedger(),
            now: { TestDiskFactory.now.addingTimeInterval(2) }
        )

        do {
            _ = try await executor.execute(
                plan: prepared.plan,
                permit: wrongPermit
            )
            XCTFail("A mismatched permit must not execute")
        } catch {
            XCTAssertEqual(
                error as? DiskCleanupError,
                .invalidExecutionPermit
            )
        }
        let calls = await trash.calls()
        XCTAssertEqual(calls, [])
    }

    func testPlanCannotRebindPermitToAnotherScanSession() async throws {
        let root = TestDiskFactory.root()
        let candidate = TestDiskFactory.candidate(
            root: root,
            name: "rebound.bin",
            inode: 650,
            bytes: 2_000_000_000
        )
        let reader = FakeDiskReader(
            root: root,
            observations: [observation(for: candidate)]
        )
        let trash = FakeDiskTrashMover()
        let prepared = try await TestDiskFactory.preparedPlan(
            root: root,
            candidates: [candidate]
        )
        let rebound = PreparedCleanupPlan(
            remediation: prepared.plan.remediation,
            scanSessionID: UUID(),
            policyVersion: prepared.plan.policyVersion,
            root: prepared.plan.root,
            selectedCandidates: prepared.plan.selectedCandidates,
            estimatedBytes: prepared.plan.estimatedBytes
        )
        let executor = DiskCleanupExecutor(
            reader: reader,
            trash: trash,
            ledger: SessionActionLedger(),
            now: { TestDiskFactory.now.addingTimeInterval(2) }
        )

        do {
            _ = try await executor.execute(
                plan: rebound,
                permit: prepared.permit
            )
            XCTFail("A permit must remain bound to its scan session")
        } catch {
            XCTAssertEqual(
                error as? DiskCleanupError,
                .invalidExecutionPermit
            )
        }
        let calls = await trash.calls()
        XCTAssertEqual(calls, [])
    }

    private func observation(
        for candidate: DiskCleanupCandidate
    ) -> DiskFileObservation {
        DiskFileObservation(
            sourceURL: candidate.sourceURL,
            canonicalURL: candidate.canonicalURL,
            kind: .regularFile,
            fingerprint: candidate.fingerprint,
            allocatedBytes: candidate.allocatedBytesEstimate,
            isHidden: false,
            isLocal: true,
            isUbiquitous: false,
            isDownloaded: true,
            isReadable: true
        )
    }
}
