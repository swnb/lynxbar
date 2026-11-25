import XCTest
@testable import LynxBar

@MainActor
final class DiskCleanupViewModelTests: XCTestCase {
    func testJourneyRequiresSelectionAndConfirmationBeforeTrashCall()
        async throws {
        let fixture = makeFixture()

        fixture.viewModel.startScan(at: fixture.root.canonicalURL)
        await waitUntil("scan should reach review") {
            fixture.viewModel.phase == .review
        }

        XCTAssertEqual(fixture.viewModel.candidates.count, 1)
        XCTAssertTrue(fixture.viewModel.selectedCandidateIDs.isEmpty)
        let callsBeforeSelection = await fixture.trash.calls()
        XCTAssertEqual(callsBeforeSelection, [])

        fixture.viewModel.prepareConfirmation()
        await Task.yield()
        XCTAssertEqual(fixture.viewModel.phase, .review)
        XCTAssertNil(fixture.viewModel.preparedPlan)
        let callsBeforePreparation = await fixture.trash.calls()
        XCTAssertEqual(callsBeforePreparation, [])

        let candidate = try XCTUnwrap(fixture.viewModel.candidates.first)
        fixture.viewModel.toggleSelection(candidate.id)
        fixture.viewModel.prepareConfirmation()
        await waitUntil("confirmation should bind an immutable plan") {
            fixture.viewModel.isConfirmationPresented
        }

        let plan = try XCTUnwrap(fixture.viewModel.preparedPlan)
        XCTAssertEqual(plan.selectedCandidates.map(\.id), [candidate.id])
        XCTAssertEqual(plan.estimatedBytes, candidate.allocatedBytesEstimate)
        let callsBeforeConfirmation = await fixture.trash.calls()
        XCTAssertEqual(callsBeforeConfirmation, [])

        fixture.viewModel.confirmAndExecute()
        await waitUntil("confirmed action should publish exact result") {
            fixture.viewModel.phase == .result
        }

        let callsAfterConfirmation = await fixture.trash.calls()
        XCTAssertEqual(callsAfterConfirmation, [candidate.sourceURL])
        XCTAssertEqual(
            fixture.viewModel.batchResult?.items.map(\.status),
            [.staged]
        )
        XCTAssertEqual(
            fixture.viewModel.batchResult?.stagedBytes,
            candidate.allocatedBytesEstimate
        )
        let stagedURL = try XCTUnwrap(
            fixture.viewModel.batchResult?.items.first?.trashURL
        )
        fixture.viewModel.revealFirstStagedItem()
        XCTAssertEqual(
            fixture.fileRevealer.revealedURLs,
            [stagedURL]
        )
        // 移入废纸篓不等于释放空间；容量未变化仍是可信完成结果。
        XCTAssertEqual(
            fixture.viewModel.capacityVerification,
            DiskCapacityVerification(
                beforeBytes: 100_000_000_000,
                afterBytes: 100_000_000_000
            )
        )
        let finalState = await fixture.coordinator.snapshot(for: plan.id)?.state
        XCTAssertEqual(finalState, .succeeded)
    }

    func testCancellingPreparedConfirmationHasNoTrashSideEffect()
        async throws {
        let fixture = makeFixture()

        fixture.viewModel.startScan(at: fixture.root.canonicalURL)
        await waitUntil("scan should reach review") {
            fixture.viewModel.phase == .review
        }
        let candidate = try XCTUnwrap(fixture.viewModel.candidates.first)
        fixture.viewModel.toggleSelection(candidate.id)
        fixture.viewModel.prepareConfirmation()
        await waitUntil("confirmation should be available") {
            fixture.viewModel.isConfirmationPresented
        }
        let planID = try XCTUnwrap(fixture.viewModel.preparedPlan?.id)

        fixture.viewModel.cancelConfirmation()
        await waitUntil("coordinator should record cancellation") {
            await fixture.coordinator.snapshot(for: planID)?.state
                == .cancelled
        }

        XCTAssertEqual(fixture.viewModel.phase, .review)
        XCTAssertNil(fixture.viewModel.preparedPlan)
        let calls = await fixture.trash.calls()
        XCTAssertEqual(calls, [])
    }

    func testCandidateCanBeRevealedWithoutSelectionOrTrashSideEffect()
        async throws {
        let fixture = makeFixture()

        fixture.viewModel.startScan(at: fixture.root.canonicalURL)
        await waitUntil("scan should reach review") {
            fixture.viewModel.phase == .review
        }
        let candidate = try XCTUnwrap(fixture.viewModel.candidates.first)

        fixture.viewModel.revealCandidate(candidate.id)

        XCTAssertEqual(
            fixture.fileRevealer.revealedURLs,
            [candidate.sourceURL]
        )
        XCTAssertTrue(fixture.viewModel.selectedCandidateIDs.isEmpty)
        XCTAssertNil(fixture.viewModel.preparedPlan)
        let calls = await fixture.trash.calls()
        XCTAssertEqual(calls, [])

        fixture.viewModel.revealCandidate(UUID())
        XCTAssertEqual(
            fixture.fileRevealer.revealedURLs,
            [candidate.sourceURL]
        )
    }

    func testBackFromReviewClearsPreviewWithoutTrashSideEffect()
        async throws {
        let fixture = makeFixture()

        fixture.viewModel.startScan(at: fixture.root.canonicalURL)
        await waitUntil("scan should reach review") {
            fixture.viewModel.phase == .review
        }
        let candidate = try XCTUnwrap(fixture.viewModel.candidates.first)
        fixture.viewModel.toggleSelection(candidate.id)
        XCTAssertTrue(fixture.viewModel.canReturnToStart)

        fixture.viewModel.startOver()

        XCTAssertEqual(fixture.viewModel.phase, .idle)
        XCTAssertFalse(fixture.viewModel.canReturnToStart)
        XCTAssertNil(fixture.viewModel.rootURL)
        XCTAssertTrue(fixture.viewModel.candidates.isEmpty)
        XCTAssertTrue(fixture.viewModel.selectedCandidateIDs.isEmpty)
        XCTAssertNil(fixture.viewModel.preparedPlan)
        let calls = await fixture.trash.calls()
        XCTAssertEqual(calls, [])
    }

    func testBackCancelsAnUnconfirmedPreparedPlan() async throws {
        let fixture = makeFixture()

        fixture.viewModel.startScan(at: fixture.root.canonicalURL)
        await waitUntil("scan should reach review") {
            fixture.viewModel.phase == .review
        }
        let candidate = try XCTUnwrap(fixture.viewModel.candidates.first)
        fixture.viewModel.toggleSelection(candidate.id)
        fixture.viewModel.prepareConfirmation()
        await waitUntil("confirmation should be available") {
            fixture.viewModel.isConfirmationPresented
        }
        let planID = try XCTUnwrap(fixture.viewModel.preparedPlan?.id)

        fixture.viewModel.startOver()
        await waitUntil("return should cancel the prepared plan") {
            await fixture.coordinator.snapshot(for: planID)?.state
                == .cancelled
        }

        XCTAssertEqual(fixture.viewModel.phase, .idle)
        XCTAssertNil(fixture.viewModel.preparedPlan)
        let calls = await fixture.trash.calls()
        XCTAssertEqual(calls, [])
    }

    private func makeFixture() -> (
        viewModel: DiskCleanupViewModel,
        root: DiskScanRoot,
        trash: FakeDiskTrashMover,
        coordinator: RemediationCoordinator,
        fileRevealer: FakeDiskCleanupFileRevealer
    ) {
        let root = TestDiskFactory.root()
        let observation = TestDiskFactory.observation(
            root: root,
            name: "review-me.bin",
            inode: 900,
            bytes: 2_000_000_000
        )
        let reader = FakeDiskReader(
            root: root,
            observations: [observation]
        )
        let trash = FakeDiskTrashMover()
        let coordinator = RemediationCoordinator()
        let fileRevealer = FakeDiskCleanupFileRevealer()
        let executor = DiskCleanupExecutor(
            reader: reader,
            trash: trash,
            ledger: SessionActionLedger(),
            now: { TestDiskFactory.now.addingTimeInterval(1) }
        )
        let viewModel = DiskCleanupViewModel(
            scanner: DiskCleanupScanner(reader: reader),
            reader: reader,
            executor: executor,
            coordinator: coordinator,
            directoryPicker: NilDiskCleanupDirectoryPicker(),
            fileRevealer: fileRevealer,
            now: { TestDiskFactory.now }
        )
        return (viewModel, root, trash, coordinator, fileRevealer)
    }

    private func waitUntil(
        _ message: String,
        condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<300 {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }
}

@MainActor
private final class NilDiskCleanupDirectoryPicker:
    DiskCleanupDirectoryPicking {
    func chooseDirectory() async -> URL? {
        nil
    }
}
