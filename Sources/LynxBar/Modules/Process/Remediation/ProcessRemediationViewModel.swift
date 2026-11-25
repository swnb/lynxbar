import Foundation

/// 单个详情会话的状态机。只有显式 confirm 才请求副作用；执行 Task 持有会话直到
/// coordinator.finish，关闭 sheet 不会中断验证或遗漏 demand 释放。
@MainActor
final class ProcessRemediationViewModel: ObservableObject {
    enum Phase: Equatable {
        case evidence, awaitingNormalConfirmation, executingNormalQuit
        case normalQuitFailed, awaitingForceConfirmation, executingForceQuit, verifying, result
    }
    let process: DisplayProcess
    let initialContext: ProcessRemediationContext
    @Published private(set) var phase: Phase = .evidence
    @Published private(set) var pendingConfirmation: ProcessActionKind?
    @Published private(set) var actionResult: ProcessActionResult?
    @Published private(set) var postActionReport: ProcessPostActionReport?
    @Published private(set) var errorMessage: String?
    private let contextProvider: @MainActor () -> ProcessRemediationContext
    private let executor: any ProcessActionExecuting
    private let remeasurer: any ProcessResourceRemeasuring
    private let coordinator: RemediationCoordinator
    private let eligibilityPolicy: ProcessActionEligibilityPolicy
    private let now: @Sendable () -> Date
    private let evidenceVersion = UUID()
    private let selectionID = UUID()
    private var prepared: PreparedRemediation?
    private var forcePermit: ProcessForceQuitPermit?
    /// prepare/currentTarget 会跨 actor；代际拒绝取消/关闭后晚到的异步结果。
    private var preparationGeneration = UUID()
    private var isSheetClosed = false
    typealias Preparation = @Sendable (RemediationRisk, UUID, UUID, Date, TimeInterval) async -> PreparedRemediation
    private let prepareAction: Preparation

    init(process: DisplayProcess, initialContext: ProcessRemediationContext,
         contextProvider: @escaping @MainActor () -> ProcessRemediationContext,
         executor: any ProcessActionExecuting = ProcessActionProvider(),
         remeasurer: any ProcessResourceRemeasuring = SystemProcessResourceRemeasurer(),
         coordinator: RemediationCoordinator = RemediationCoordinator(),
         eligibilityPolicy: ProcessActionEligibilityPolicy = ProcessActionEligibilityPolicy(),
         now: @escaping @Sendable () -> Date = { Date() },
         prepareAction: Preparation? = nil) {
        self.process = process
        self.initialContext = initialContext
        self.contextProvider = contextProvider
        self.executor = executor
        self.remeasurer = remeasurer
        self.coordinator = coordinator
        self.eligibilityPolicy = eligibilityPolicy
        self.now = now
        self.prepareAction = prepareAction ?? { risk, evidence, selection, timestamp, lifetime in
            await coordinator.prepare(kind: .processTermination, evidenceVersion: evidence,
                selectionID: selection, risk: risk, now: timestamp, lifetime: lifetime)
        }
    }
    var eligibility: ProcessActionEligibility {
        guard let target = process.actionTarget else { return .ineligible(.identityIncomplete) }
        return eligibilityPolicy.evaluate(target)
    }
    var canOfferNormalQuit: Bool {
        phase == .evidence && !isSheetClosed && currentEvidenceAllows(.normalQuit)
    }
    var canOfferForceQuit: Bool {
        phase == .normalQuitFailed && !isSheetClosed && currentEvidenceAllows(.forceQuit)
    }
    /// 每个挂起点之后及最终 controller 同步请求前都复用这一读状态检查。
    /// 当前排行接口传入不可变观察快照，因此30秒有效期是其连续性证据的边界，
    /// 不把旧排行无限续期；系统 context 则始终从宿主实时读取。
    private func currentEvidenceAllows(_ kind: ProcessActionKind) -> Bool {
        let currentContext = contextProvider()
        guard eligibility.isEligible, initialContext.matchesIssueEvidence(currentContext) else { return false }
        if kind == .forceQuit {
            // 正常退出尝试会自然消耗观察有效期；force 使用该次失败签发的短期许可，
            // 仍要求原系统问题存在。force许可在provider最终执行时单次消费。
            return forcePermit.map { now() < $0.expiresAt } == true
        }
        guard let contribution = process.contribution, let target = process.actionTarget,
              contribution.actionTarget?.matchesActionIdentity(target) == true else { return false }
        let age = now().timeIntervalSince(contribution.observedAt)
        return age >= 0 && age < 30
            && ProcessRemediationSuggestionPolicy.level(for: contribution, context: currentContext) == .normalQuit
    }
    /// Requests a normal-quit remediation confirmation token after verifying current eligibility.
    func requestNormalQuitConfirmation() {
        guard canOfferNormalQuit else { return }
        let generation = UUID()
        preparationGeneration = generation
        phase = .awaitingNormalConfirmation
        Task { [self] in
            let action = await prepareAction(.disruptive, evidenceVersion, selectionID, now(),
                max(0, (process.contribution?.observedAt.addingTimeInterval(30).timeIntervalSince(now())) ?? 0))
            guard !isSheetClosed, preparationGeneration == generation, phase == .awaitingNormalConfirmation else {
                await cancelPreparedAction(action.id, context: "stale normal-quit preparation")
                return
            }
            prepared = action
            pendingConfirmation = .normalQuit
        }
    }
    /// Re-verifies target identity and requests a force-quit confirmation token after normal quit fails.
    func requestForceQuitConfirmation() {
        guard canOfferForceQuit, let target = process.actionTarget else { return }
        let generation = UUID()
        preparationGeneration = generation
        phase = .awaitingForceConfirmation
        Task { [self] in
            let current = await executor.currentTarget(pid: target.process.pid)
            guard !isSheetClosed, preparationGeneration == generation, phase == .awaitingForceConfirmation else { return }
            guard let current, target.matchesActionIdentity(current), eligibilityPolicy.evaluate(current).isEligible,
                  currentEvidenceAllows(.forceQuit) else {
                recordRejected(kind: .forceQuit, outcome: .stale)
                return
            }
            let action = await prepareAction(.force, evidenceVersion, selectionID, now(),
                max(0, forcePermit?.expiresAt.timeIntervalSince(now()) ?? 0))
            guard !isSheetClosed, preparationGeneration == generation, phase == .awaitingForceConfirmation else {
                await cancelPreparedAction(action.id, context: "stale force-quit preparation")
                return
            }
            prepared = action
            pendingConfirmation = .forceQuit
        }
    }
    /// Cancels an unconfirmed quit confirmation and returns to the previous non-pending phase.
    func cancelConfirmation() {
        guard phase == .awaitingNormalConfirmation || phase == .awaitingForceConfirmation else { return }
        let cancelled = prepared
        let wasForce = phase == .awaitingForceConfirmation
        preparationGeneration = UUID()
        prepared = nil
        pendingConfirmation = nil
        phase = wasForce ? .normalQuitFailed : .evidence
        if let cancelled {
            Task { [self] in
                await cancelPreparedAction(cancelled.id, context: "user confirmation")
            }
        }
    }
    /// 关闭只撤销尚未确认的预览；已明确确认的动作继续复测并完成finish。
    func sheetClosed() {
        isSheetClosed = true
        cancelConfirmation()
        preparationGeneration = UUID()
    }
    /// Confirms the pending process action, executes it under a demand permit, and verifies post-action state.
    func confirmPendingAction() {
        guard let kind = pendingConfirmation, let prepared, let target = process.actionTarget else { return }
        // 同一 actor turn 内消费 UI 的 pending 值；double click 无法再次进入。
        pendingConfirmation = nil
        self.prepared = nil
        phase = kind == .normalQuit ? .executingNormalQuit : .executingForceQuit
        Task { [self] in
            guard currentEvidenceAllows(kind) else {
                await cancelPreparedAction(prepared.id, context: "expired confirmation")
                recordRejected(kind: kind, outcome: .stale)
                return
            }
            let permit: RemediationExecutionPermit
            do {
                permit = try await coordinator.confirm(preparedID: prepared.id, evidenceVersion: evidenceVersion,
                    selectionID: selectionID, risk: kind == .normalQuit ? .disruptive : .force, now: now())
                // begin 在副作用前取得持续采样 demand，保证关闭面板也会完成复测。
                try await coordinator.beginVerification(permit)
            } catch {
                Log.app.warning(
                    "Failed to confirm process remediation: \(error.localizedDescription, privacy: .private)"
                )
                errorMessage = error.localizedDescription
                recordRejected(kind: kind, outcome: .stale)
                return
            }
            // confirm/beginVerification 均可挂起，尤其begin的demand hook会刷新
            // 宿主状态。失效时不得调用executor，但必须finish释放已取得的demand。
            guard currentEvidenceAllows(kind) else {
                recordRejected(kind: kind, outcome: .stale)
                do { try await coordinator.finish(permit, completion: .cancelled) }
                catch {
                    Log.app.error(
                        "Failed to release cancelled process remediation permit: \(error.localizedDescription, privacy: .private)"
                    )
                    errorMessage = error.localizedDescription
                }
                return
            }
            let finalEvidenceCheck: @MainActor @Sendable () -> Bool = { [weak self] in
                self?.currentEvidenceAllows(kind) == true
            }
            let result: ProcessActionResult
            if kind == .normalQuit {
                result = await executor.requestNormalQuit(target, evidenceIsCurrent: finalEvidenceCheck)
            } else if let permit = forcePermit {
                // 不先清空本地许可，最终证据闭包仍需读它；provider自己单次消费。
                result = await executor.requestForceQuit(target, permit: permit, evidenceIsCurrent: finalEvidenceCheck)
                forcePermit = nil
            } else {
                result = ProcessActionResult(kind: kind, outcome: .forceNotAuthorized,
                                             requestAccepted: nil, forceQuitPermit: nil)
            }
            actionResult = result
            phase = .verifying
            let resources = await remeasurer.measure(preparedTarget: target)
            let report = ProcessPostActionReporter.report(resources: resources, initialContext: initialContext,
                                                          currentContext: contextProvider())
            postActionReport = report
            // 退出与系统问题缓解独立判定；read unavailable 不会变成成功。
            let completion: RemediationCompletion = report.applicationExited
                ? (report.systemIssueResolved ? .succeeded : .partial) : .failed
            do { try await coordinator.finish(permit, completion: completion) }
            catch {
                Log.app.error(
                    "Failed to finish process remediation verification: \(error.localizedDescription, privacy: .private)"
                )
                errorMessage = error.localizedDescription
            }
            if !report.applicationExited, (result.outcome == .refused || result.outcome == .timedOut),
               let nextPermit = result.forceQuitPermit {
                forcePermit = nextPermit
                phase = .normalQuitFailed
            } else { phase = .result }
        }
    }
    /// Cancels an unconfirmed process remediation preparation and logs coordinator state errors.
    private func cancelPreparedAction(_ preparedID: UUID, context: String) async {
        do {
            try await coordinator.cancel(preparedID: preparedID)
        } catch {
            Log.app.warning(
                "Failed to cancel \(context, privacy: .public) process remediation: \(error.localizedDescription, privacy: .private)"
            )
        }
    }
    private func recordRejected(kind: ProcessActionKind, outcome: ProcessActionOutcome) {
        actionResult = ProcessActionResult(kind: kind, outcome: outcome, requestAccepted: nil, forceQuitPermit: nil)
        forcePermit = nil
        pendingConfirmation = nil
        phase = .result
    }
}
