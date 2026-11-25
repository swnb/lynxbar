import XCTest
@testable import LynxBar

final class RemediationCoordinatorTests: XCTestCase {
    func testConfirmationBindsEvidenceSelectionAndRisk() async throws {
        let coordinator = RemediationCoordinator()
        let evidence = UUID()
        let selection = UUID()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let prepared = await coordinator.prepare(
            kind: .diskReclamation,
            evidenceVersion: evidence,
            selectionID: selection,
            risk: .recoverable,
            now: now
        )

        let permit = try await coordinator.confirm(
            preparedID: prepared.id,
            evidenceVersion: evidence,
            selectionID: selection,
            risk: .recoverable,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(permit.preparedID, prepared.id)
        let executing = await coordinator.snapshot(for: prepared.id)
        XCTAssertEqual(executing?.state, .executing)
    }

    func testExpiredPlanCannotProducePermit() async {
        let coordinator = RemediationCoordinator()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let prepared = await coordinator.prepare(
            kind: .diskReclamation,
            evidenceVersion: UUID(),
            selectionID: UUID(),
            risk: .recoverable,
            now: now,
            lifetime: 10
        )

        do {
            _ = try await coordinator.confirm(
                preparedID: prepared.id,
                evidenceVersion: prepared.evidenceVersion,
                selectionID: prepared.selectionID,
                risk: prepared.risk,
                now: now.addingTimeInterval(10)
            )
            XCTFail("Expired plans must not produce an execution permit")
        } catch {
            XCTAssertEqual(error as? RemediationCoordinatorError, .expired)
        }
        let expired = await coordinator.snapshot(for: prepared.id)
        XCTAssertEqual(expired?.state, .expired)
    }

    func testChangedSelectionBecomesStale() async {
        let coordinator = RemediationCoordinator()
        let prepared = await coordinator.prepare(
            kind: .diskReclamation,
            evidenceVersion: UUID(),
            selectionID: UUID(),
            risk: .recoverable
        )

        do {
            _ = try await coordinator.confirm(
                preparedID: prepared.id,
                evidenceVersion: prepared.evidenceVersion,
                selectionID: UUID(),
                risk: prepared.risk
            )
            XCTFail("A changed selection must not inherit confirmation")
        } catch {
            XCTAssertEqual(
                error as? RemediationCoordinatorError,
                .selectionChanged
            )
        }
        let stale = await coordinator.snapshot(for: prepared.id)
        XCTAssertEqual(stale?.state, .stale)
    }

    func testPermitIsOneShotAndCompletionRequiresVerification() async throws {
        let coordinator = RemediationCoordinator()
        let prepared = await coordinator.prepare(
            kind: .diskReclamation,
            evidenceVersion: UUID(),
            selectionID: UUID(),
            risk: .recoverable
        )
        let permit = try await coordinator.confirm(
            preparedID: prepared.id,
            evidenceVersion: prepared.evidenceVersion,
            selectionID: prepared.selectionID,
            risk: prepared.risk
        )

        do {
            _ = try await coordinator.confirm(
                preparedID: prepared.id,
                evidenceVersion: prepared.evidenceVersion,
                selectionID: prepared.selectionID,
                risk: prepared.risk
            )
            XCTFail("The same prepared action must not be confirmed twice")
        } catch let error as RemediationCoordinatorError {
            XCTAssertEqual(
                error,
                .invalidState(
                    expected: .awaitingConfirmation,
                    actual: .executing
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try await coordinator.beginVerification(permit)
        try await coordinator.finish(permit, completion: .partial)
        let partial = await coordinator.snapshot(for: prepared.id)
        XCTAssertEqual(partial?.state, .partial)
    }

    // MARK: - remediation(issue) demand（Task A.3）

    func testRemediationKindMapsToDiskModuleAndRepresentativeHealthIssueKind() {
        XCTAssertEqual(RemediationKind.diskReclamation.demandedModule, .disk)
        XCTAssertEqual(
            RemediationKind.diskReclamation.representativeHealthIssueKind,
            .lowDisk
        )
    }

    func testRemediationKindMapsToProcessModuleAndRepresentativeHealthIssueKind() {
        XCTAssertEqual(RemediationKind.processTermination.demandedModule, .process)
        XCTAssertEqual(
            RemediationKind.processTermination.representativeHealthIssueKind,
            .sustainedCPU
        )
    }

    @MainActor
    func testDemandBridgeAcquiresOnBeginAndReleasesOnEnd() {
        let demandCoordinator = MonitoringDemandCoordinator()
        let bridge = RemediationDemandBridge(demandCoordinator: demandCoordinator)
        let preparedID = UUID()

        XCTAssertEqual(demandCoordinator.demandCount(for: .disk), 0)

        bridge.begin(preparedID: preparedID, kind: .diskReclamation)
        XCTAssertEqual(demandCoordinator.demandCount(for: .disk), 1)

        // 幂等：同一 preparedID 重复 begin 不应重复 acquire。
        bridge.begin(preparedID: preparedID, kind: .diskReclamation)
        XCTAssertEqual(demandCoordinator.demandCount(for: .disk), 1)

        bridge.end(preparedID: preparedID)
        XCTAssertEqual(demandCoordinator.demandCount(for: .disk), 0)

        // 幂等：重复 end 不应下溢或崩溃。
        bridge.end(preparedID: preparedID)
        XCTAssertEqual(demandCoordinator.demandCount(for: .disk), 0)
    }

    @MainActor
    func testBeginVerificationAcquiresDemandAndFinishReleasesIt() async throws {
        let demandCoordinator = MonitoringDemandCoordinator()
        let bridge = RemediationDemandBridge(demandCoordinator: demandCoordinator)
        let coordinator = RemediationCoordinator(
            onBeginVerification: { [weak bridge] preparedID, kind in
                await bridge?.begin(preparedID: preparedID, kind: kind)
            },
            onEndVerification: { [weak bridge] preparedID in
                await bridge?.end(preparedID: preparedID)
            }
        )
        let prepared = await coordinator.prepare(
            kind: .diskReclamation,
            evidenceVersion: UUID(),
            selectionID: UUID(),
            risk: .recoverable
        )
        let permit = try await coordinator.confirm(
            preparedID: prepared.id,
            evidenceVersion: prepared.evidenceVersion,
            selectionID: prepared.selectionID,
            risk: prepared.risk
        )

        XCTAssertEqual(demandCoordinator.demandCount(for: .disk), 0)

        try await coordinator.beginVerification(permit)
        XCTAssertEqual(
            demandCoordinator.demandCount(for: .disk), 1,
            "beginVerification 必须立即 acquire .remediation demand"
        )

        try await coordinator.finish(permit, completion: .succeeded)
        XCTAssertEqual(
            demandCoordinator.demandCount(for: .disk), 0,
            "finish 必须释放 beginVerification 期间 acquire 的 demand"
        )
    }

    /// `confirmAndExecute` 的失败分支在 `executor.execute` 抛错后仍会依次调用
    /// `beginVerification` 再 `finish(completion: .failed)`（见
    /// `DiskCleanupViewModel.confirmAndExecute` 的 catch 分支）；确认失败路径
    /// 同样会释放 demand，不会泄漏。
    @MainActor
    func testFinishReleasesDemandEvenWhenCompletionIsFailed() async throws {
        let demandCoordinator = MonitoringDemandCoordinator()
        let bridge = RemediationDemandBridge(demandCoordinator: demandCoordinator)
        let coordinator = RemediationCoordinator(
            onBeginVerification: { [weak bridge] preparedID, kind in
                await bridge?.begin(preparedID: preparedID, kind: kind)
            },
            onEndVerification: { [weak bridge] preparedID in
                await bridge?.end(preparedID: preparedID)
            }
        )
        let prepared = await coordinator.prepare(
            kind: .diskReclamation,
            evidenceVersion: UUID(),
            selectionID: UUID(),
            risk: .recoverable
        )
        let permit = try await coordinator.confirm(
            preparedID: prepared.id,
            evidenceVersion: prepared.evidenceVersion,
            selectionID: prepared.selectionID,
            risk: prepared.risk
        )

        try await coordinator.beginVerification(permit)
        XCTAssertEqual(demandCoordinator.demandCount(for: .disk), 1)

        try await coordinator.finish(permit, completion: .failed)
        XCTAssertEqual(demandCoordinator.demandCount(for: .disk), 0)
    }
}
