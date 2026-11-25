import XCTest
@testable import LynxBar

@MainActor
final class ProcessRemediationViewModelTests: XCTestCase {
    private let policy = ProcessActionEligibilityPolicy(currentUID: 501, lynxBarPID: 12, lynxBarBundleIdentifier: "test.stats")
    private let context = ProcessRemediationContext(memoryPressure: .warning, swapUsedBytes: 100,
        hasSustainedCPUIssue: false, physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024)

    func testBeginVerificationChangingEvidenceRejectsExecutorAndReleasesDemand() async {
        let target = processTestTarget()
        let executor = ProcessTestExecutor(target: target, normalOutcome: .exited)
        let demand = MonitoringDemandCoordinator()
        let state = ProcessRemediationDemandTestState(context: context)
        let coordinator = RemediationCoordinator(onBeginVerification: { _, _ in
            await MainActor.run {
                state.context = .inspectionOnly
                state.token = demand.acquire(module: .process, reason: .remediation(.memoryPressureWarning), owner: state)
                state.began = true
            }
        }, onEndVerification: { _ in
            await MainActor.run {
                state.token?.cancel()
                state.token = nil
                state.ended = true
            }
        })
        let model = makeModel(target: target, executor: executor, contextProvider: { state.context }, coordinator: coordinator)
        model.requestNormalQuitConfirmation()
        await waitUntil { model.pendingConfirmation == .normalQuit }
        model.confirmPendingAction()
        await waitUntil { model.phase == .result && state.ended }
        let count = await executor.normalCount()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(state.began)
        XCTAssertEqual(model.actionResult?.outcome, .stale)
        XCTAssertEqual(demand.demandCount(for: .process), 0)
    }
    func testClosingConfirmedSheetStillFinishesVerificationAndReleasesDemand() async {
        let target = processTestTarget()
        let executor = ProcessTestExecutor(target: target, normalOutcome: .exited)
        let demand = MonitoringDemandCoordinator()
        let state = ProcessRemediationDemandTestState(context: context)
        let gate = ProcessVerificationTestGate()
        let coordinator = RemediationCoordinator(onBeginVerification: { _, _ in
            await MainActor.run {
                state.token = demand.acquire(module: .process, reason: .remediation(.memoryPressureWarning), owner: state)
                state.began = true
            }
            await gate.pause()
        }, onEndVerification: { _ in
            await MainActor.run { state.token?.cancel(); state.token = nil; state.ended = true }
        })
        let model = makeModel(target: target, executor: executor, contextProvider: { state.context }, coordinator: coordinator)
        model.requestNormalQuitConfirmation()
        await waitUntil { model.pendingConfirmation == .normalQuit }
        model.confirmPendingAction()
        await waitUntil { state.began }
        model.sheetClosed()
        await gate.resume()
        await waitUntil { model.phase == .result && state.ended }
        let count = await executor.normalCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(demand.demandCount(for: .process), 0)
    }
    func testCancelledPreparationArrivingLateCannotRestoreConfirmationOrAcquireDemand() async {
        await checkLatePreparation(closeSheet: false)
    }
    func testClosedSheetPreparationArrivingLateCannotRestoreConfirmationOrAcquireDemand() async {
        await checkLatePreparation(closeSheet: true)
    }
    private func checkLatePreparation(closeSheet: Bool) async {
        let target = processTestTarget()
        let executor = ProcessTestExecutor(target: target, normalOutcome: .exited)
        let demand = MonitoringDemandCoordinator()
        let state = ProcessRemediationDemandTestState(context: context)
        let coordinator = RemediationCoordinator(onBeginVerification: { _, _ in
            await MainActor.run {
                state.token = demand.acquire(module: .process, reason: .remediation(.memoryPressureWarning), owner: state)
                state.began = true
            }
        }, onEndVerification: { _ in
            await MainActor.run { state.token?.cancel(); state.token = nil; state.ended = true }
        })
        let preparation = ControlledProcessPreparation(coordinator: coordinator)
        let process = DisplayProcess(pid: target.process.pid, name: "Helper", cpuUsage: 0.1, memoryBytes: 1_024,
            actionTarget: target, contribution: processTestContribution(target: target))
        let model = ProcessRemediationViewModel(process: process, initialContext: context,
            contextProvider: { state.context }, executor: executor, coordinator: coordinator, eligibilityPolicy: policy,
            prepareAction: { risk, evidence, selection, now, lifetime in
                await preparation.prepare(risk: risk, evidence: evidence, selection: selection, now: now, lifetime: lifetime)
            })
        model.requestNormalQuitConfirmation()
        let preparedID = await preparation.waitForPreparedID()
        if closeSheet { model.sheetClosed() } else { model.cancelConfirmation() }
        await preparation.resume()
        // 等待状态机把晚到的实际prepared record取消，证明并非只是Task尚未调度。
        var snapshot: RemediationRecordSnapshot?
        for _ in 0..<200 {
            snapshot = await coordinator.snapshot(for: preparedID)
            if snapshot?.state == .cancelled { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(snapshot?.state, .cancelled)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(model.phase, .evidence)
        XCTAssertFalse(state.began)
        XCTAssertEqual(demand.demandCount(for: .process), 0)
        let count = await executor.normalCount()
        XCTAssertEqual(count, 0)
    }
    func testNormalConfirmationIsExplicitAndDoubleConfirmExecutesOnce() async {
        let target = processTestTarget()
        let executor = ProcessTestExecutor(target: target, normalOutcome: .exited)
        let model = makeModel(target: target, executor: executor)
        XCTAssertTrue(model.canOfferNormalQuit)
        model.requestNormalQuitConfirmation()
        await waitUntil { model.pendingConfirmation == .normalQuit }
        do { let count = await executor.normalCount(); XCTAssertEqual(count, 0) }
        model.confirmPendingAction()
        model.confirmPendingAction()
        await waitUntil { model.phase == .result }
        do { let count = await executor.normalCount(); XCTAssertEqual(count, 1) }
        XCTAssertTrue(model.postActionReport?.applicationExited == true)
        XCTAssertFalse(model.postActionReport?.systemIssueResolved == true)
    }
    func testCancellationNeverCallsExecutor() async {
        let target = processTestTarget()
        let executor = ProcessTestExecutor(target: target, normalOutcome: .exited)
        let model = makeModel(target: target, executor: executor)
        model.requestNormalQuitConfirmation()
        await waitUntil { model.pendingConfirmation != nil }
        model.cancelConfirmation()
        XCTAssertEqual(model.phase, .evidence)
        do { let count = await executor.normalCount(); XCTAssertEqual(count, 0) }
    }
    func testChangedSystemEvidenceBeforeConfirmRejectsWithoutAction() async {
        let target = processTestTarget()
        let executor = ProcessTestExecutor(target: target, normalOutcome: .exited)
        let state = ProcessRemediationDemandTestState(context: context)
        let model = makeModel(target: target, executor: executor, contextProvider: { state.context })
        model.requestNormalQuitConfirmation()
        await waitUntil { model.pendingConfirmation != nil }
        state.context = .inspectionOnly
        model.confirmPendingAction()
        await waitUntil { model.phase == .result }
        XCTAssertEqual(model.actionResult?.outcome, .stale)
        do { let count = await executor.normalCount(); XCTAssertEqual(count, 0) }
    }
    func testForceRequiresNormalFailureFreshPreviewAndSecondConfirmation() async {
        let target = processTestTarget()
        let executor = ProcessTestExecutor(target: target, normalOutcome: .timedOut)
        let model = makeModel(target: target, executor: executor, targetStatus: .stillRunning)
        XCTAssertFalse(model.canOfferForceQuit)
        model.requestForceQuitConfirmation()
        XCTAssertNil(model.pendingConfirmation)
        model.requestNormalQuitConfirmation()
        await waitUntil { model.pendingConfirmation != nil }
        model.confirmPendingAction()
        await waitUntil { model.phase == .normalQuitFailed }
        do { let count = await executor.forceCount(); XCTAssertEqual(count, 0) }
        XCTAssertTrue(model.canOfferForceQuit)
        model.requestForceQuitConfirmation()
        await waitUntil { model.pendingConfirmation == .forceQuit }
        do { let count = await executor.forceCount(); XCTAssertEqual(count, 0) }
        model.confirmPendingAction()
        await waitUntil { model.phase == .result }
        do { let count = await executor.forceCount(); XCTAssertEqual(count, 1) }
    }
    func testForcePreviewRejectsChangedIdentity() async {
        let target = processTestTarget()
        let executor = ProcessTestExecutor(target: target, normalOutcome: .refused)
        let model = makeModel(target: target, executor: executor, targetStatus: .stillRunning)
        model.requestNormalQuitConfirmation()
        await waitUntil { model.pendingConfirmation != nil }
        model.confirmPendingAction()
        await waitUntil { model.phase == .normalQuitFailed }
        await executor.setTarget(processTestTarget(microseconds: 2))
        model.requestForceQuitConfirmation()
        await waitUntil { model.phase == .result }
        XCTAssertEqual(model.actionResult?.outcome, .stale)
        do { let count = await executor.forceCount(); XCTAssertEqual(count, 0) }
    }
    func testStaleObservationAndIncompleteIdentityRemainInspectionOnly() {
        let target = processTestTarget()
        let executor = ProcessTestExecutor(target: target, normalOutcome: .exited)
        let clock = ProcessTestClock(Date())
        let old = DisplayProcess(pid: target.process.pid, name: "Helper", cpuUsage: 0.1, memoryBytes: 1_024,
            actionTarget: target, contribution: processTestContribution(target: target, observedAt: clock.value().addingTimeInterval(-31)))
        let model = ProcessRemediationViewModel(process: old, initialContext: context, contextProvider: { self.context },
            executor: executor, eligibilityPolicy: policy, now: { clock.value() })
        XCTAssertFalse(model.canOfferNormalQuit)
        XCTAssertEqual(ProcessRemediationViewModel(process: DisplayProcess(pid: 1, name: "CLI", cpuUsage: nil, memoryBytes: 1),
            initialContext: context, contextProvider: { self.context }).eligibility, .ineligible(.identityIncomplete))
    }
    private func makeModel(target: ProcessActionTarget, executor: any ProcessActionExecuting,
                           targetStatus: ProcessTargetPostActionStatus = .exited,
                           contextProvider: (@MainActor () -> ProcessRemediationContext)? = nil,
                           coordinator: RemediationCoordinator = RemediationCoordinator()) -> ProcessRemediationViewModel {
        let process = DisplayProcess(pid: target.process.pid, name: "Helper", cpuUsage: 0.1, memoryBytes: 1_024,
            actionTarget: target, contribution: processTestContribution(target: target))
        return ProcessRemediationViewModel(process: process, initialContext: context,
            contextProvider: contextProvider ?? { self.context }, executor: executor,
            remeasurer: ProcessTestRemeasurer(status: targetStatus), coordinator: coordinator, eligibilityPolicy: policy)
    }
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Process remediation state did not reach expected phase")
    }
}
private actor ProcessTestExecutor: ProcessActionExecuting {
    private var target: ProcessActionTarget
    private let normalOutcome: ProcessActionOutcome
    private var normal = 0
    private var force = 0
    init(target: ProcessActionTarget, normalOutcome: ProcessActionOutcome) {
        self.target = target
        self.normalOutcome = normalOutcome
    }
    func currentTarget(pid: Int32) async -> ProcessActionTarget? { target }
    func requestNormalQuit(_ preparedTarget: ProcessActionTarget) async -> ProcessActionResult {
        normal += 1
        return ProcessActionResult(kind: .normalQuit, outcome: normalOutcome, requestAccepted: true,
            forceQuitPermit: normalOutcome == .exited ? nil : ProcessForceQuitPermit(id: UUID(),
                targetKey: preparedTarget.process.sampleKey, expiresAt: Date().addingTimeInterval(30)))
    }
    func requestForceQuit(_ preparedTarget: ProcessActionTarget, permit: ProcessForceQuitPermit) async -> ProcessActionResult {
        force += 1
        return ProcessActionResult(kind: .forceQuit, outcome: .exited, requestAccepted: true, forceQuitPermit: nil)
    }
    func normalCount() -> Int { normal }
    func forceCount() -> Int { force }
    func setTarget(_ target: ProcessActionTarget) { self.target = target }
}
private struct ProcessTestRemeasurer: ProcessResourceRemeasuring {
    let status: ProcessTargetPostActionStatus
    func measure(preparedTarget: ProcessActionTarget) async -> ProcessResourceRemeasurement {
        ProcessResourceRemeasurement(targetStatus: status, memoryUsage: 0.9, swapUsedBytes: 100, cpuUsage: 0.5)
    }
}

@MainActor
private final class ProcessRemediationDemandTestState: MonitoringDemandOwner {
    var context: ProcessRemediationContext
    var token: DemandToken?
    var began = false
    var ended = false
    init(context: ProcessRemediationContext) { self.context = context }
}
private actor ControlledProcessPreparation {
    private let coordinator: RemediationCoordinator
    private var preparedID: UUID?
    private var waitingForID: CheckedContinuation<UUID, Never>?
    private var pause: CheckedContinuation<Void, Never>?
    init(coordinator: RemediationCoordinator) { self.coordinator = coordinator }
    func prepare(risk: RemediationRisk, evidence: UUID, selection: UUID, now: Date, lifetime: TimeInterval) async -> PreparedRemediation {
        let action = await coordinator.prepare(kind: .processTermination, evidenceVersion: evidence,
            selectionID: selection, risk: risk, now: now, lifetime: lifetime)
        preparedID = action.id
        await withCheckedContinuation { continuation in
            pause = continuation
            waitingForID?.resume(returning: action.id)
            waitingForID = nil
        }
        return action
    }
    func waitForPreparedID() async -> UUID {
        if let preparedID { return preparedID }
        return await withCheckedContinuation { waitingForID = $0 }
    }
    func resume() { pause?.resume(); pause = nil }
}

private actor ProcessVerificationTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false
    func pause() async {
        guard !resumed else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}
