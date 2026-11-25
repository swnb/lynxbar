import Foundation

/// 只管理一次性确认与状态转换，不拥有 URL、文件系统或任何系统副作用。
actor RemediationCoordinator {
    private struct Record: Sendable {
        let prepared: PreparedRemediation
        var state: RemediationState
        var permitID: UUID?
    }

    private var records: [UUID: Record] = [:]

    /// `.remediation(issue)` demand 的 acquire/release 钩子（Task A.3）。
    ///
    /// 这个 actor 不是 `@MainActor`，而 `DemandToken`/`MonitoringDemandCoordinator`
    /// 只能安全地在 MainActor 上持有和调用；因此这里不直接持有 token，而是通过
    /// `@Sendable async` 闭包把 begin/end 信号转发给 MainActor 上的
    /// `RemediationDemandBridge`（由长生命周期宿主在构造时注入）。闭包用
    /// `await` 直接调用而非 fire-and-forget，保证 `beginVerification`/`finish`
    /// 返回时 acquire/release 已经真正发生。测试不传时默认 nil，行为等价于
    /// 没有接入 demand（不影响既有状态机测试）。
    private let onBeginVerification: (@Sendable (UUID, RemediationKind) async -> Void)?
    private let onEndVerification: (@Sendable (UUID) async -> Void)?

    init(
        onBeginVerification: (@Sendable (UUID, RemediationKind) async -> Void)? = nil,
        onEndVerification: (@Sendable (UUID) async -> Void)? = nil
    ) {
        self.onBeginVerification = onBeginVerification
        self.onEndVerification = onEndVerification
    }

    func prepare(
        kind: RemediationKind,
        evidenceVersion: UUID,
        selectionID: UUID,
        risk: RemediationRisk,
        now: Date = Date(),
        lifetime: TimeInterval = 10 * 60
    ) -> PreparedRemediation {
        let prepared = PreparedRemediation(
            id: UUID(),
            kind: kind,
            evidenceVersion: evidenceVersion,
            selectionID: selectionID,
            risk: risk,
            preparedAt: now,
            expiresAt: now.addingTimeInterval(max(0, lifetime))
        )
        records[prepared.id] = Record(
            prepared: prepared,
            state: .awaitingConfirmation,
            permitID: nil
        )
        return prepared
    }

    func confirm(
        preparedID: UUID,
        evidenceVersion: UUID,
        selectionID: UUID,
        risk: RemediationRisk,
        now: Date = Date()
    ) throws -> RemediationExecutionPermit {
        guard var record = records[preparedID] else {
            throw RemediationCoordinatorError.unknownPreparedAction
        }
        guard record.state == .awaitingConfirmation else {
            throw RemediationCoordinatorError.invalidState(
                expected: .awaitingConfirmation,
                actual: record.state
            )
        }
        guard now < record.prepared.expiresAt else {
            record.state = .expired
            records[preparedID] = record
            throw RemediationCoordinatorError.expired
        }
        guard evidenceVersion == record.prepared.evidenceVersion else {
            record.state = .stale
            records[preparedID] = record
            throw RemediationCoordinatorError.staleEvidence
        }
        guard selectionID == record.prepared.selectionID else {
            record.state = .stale
            records[preparedID] = record
            throw RemediationCoordinatorError.selectionChanged
        }
        guard risk == record.prepared.risk else {
            throw RemediationCoordinatorError.riskMismatch
        }

        let permit = RemediationExecutionPermit(
            id: UUID(),
            preparedID: preparedID,
            evidenceVersion: evidenceVersion,
            selectionID: selectionID,
            issuedAt: now
        )
        record.state = .executing
        record.permitID = permit.id
        records[preparedID] = record
        return permit
    }

    func beginVerification(_ permit: RemediationExecutionPermit) async throws {
        var record = try validatedRecord(for: permit, expected: .executing)
        record.state = .verifying
        records[permit.preparedID] = record
        await onBeginVerification?(permit.preparedID, record.prepared.kind)
    }

    func finish(
        _ permit: RemediationExecutionPermit,
        completion: RemediationCompletion
    ) async throws {
        var record = try validatedRecord(for: permit, expected: .verifying)
        switch completion {
        case .succeeded:
            record.state = .succeeded
        case .partial:
            record.state = .partial
        case .failed:
            record.state = .failed
        case .cancelled:
            record.state = .cancelled
        }
        records[permit.preparedID] = record
        // .verifying 只能通过这里离开（cancel(preparedID:) 的 guard 要求
        // state == .awaitingConfirmation，结构上不可能在 verifying 期间触发），
        // 所以 finish 是 beginVerification 之后唯一的 demand 释放路径。
        await onEndVerification?(permit.preparedID)
    }

    func cancel(preparedID: UUID) throws {
        guard var record = records[preparedID] else {
            throw RemediationCoordinatorError.unknownPreparedAction
        }
        guard record.state == .awaitingConfirmation else {
            throw RemediationCoordinatorError.invalidState(
                expected: .awaitingConfirmation,
                actual: record.state
            )
        }
        record.state = .cancelled
        records[preparedID] = record
    }

    func snapshot(for preparedID: UUID) -> RemediationRecordSnapshot? {
        guard let record = records[preparedID] else { return nil }
        return RemediationRecordSnapshot(
            prepared: record.prepared,
            state: record.state,
            permitID: record.permitID
        )
    }

    private func validatedRecord(
        for permit: RemediationExecutionPermit,
        expected: RemediationState
    ) throws -> Record {
        guard let record = records[permit.preparedID] else {
            throw RemediationCoordinatorError.unknownPreparedAction
        }
        guard record.state == expected else {
            throw RemediationCoordinatorError.invalidState(
                expected: expected,
                actual: record.state
            )
        }
        guard record.permitID == permit.id,
              record.prepared.evidenceVersion == permit.evidenceVersion,
              record.prepared.selectionID == permit.selectionID else {
            throw RemediationCoordinatorError.invalidPermit
        }
        return record
    }
}

extension RemediationKind {
    /// remediation 验证期间需要保持采样的模块。
    var demandedModule: MonitoringModule {
        switch self {
        case .diskReclamation: return .disk
        case .processTermination: return .process
        }
    }

    /// `DemandReason.remediation` 需要一个 `HealthIssueKind` 作为 demand key 的
    /// 一部分；`RemediationCoordinator` 本身只知道 `RemediationKind`（不知道
    /// 触发本次 remediation 的具体 HealthIssue 严重度，比如低磁盘还是极低磁盘），
    /// 这里选每个 remediation kind 最具代表性的一种，仅用于标识 demand 来源，
    /// 不代表当次触发的确切严重度——不影响功能正确性（token 引用计数按
    /// owner+module+reason 走，这里的具体取值只影响调试可读性）。
    var representativeHealthIssueKind: HealthIssueKind {
        switch self {
        case .diskReclamation: return .lowDisk
        case .processTermination: return .sustainedCPU
        }
    }
}

/// `.remediation(issue)` demand 的 MainActor 侧持有者。
///
/// `RemediationCoordinator` 是普通 actor，`DemandToken` 只能安全地在 MainActor
/// 上持有和释放；这个类型是两者之间的桥。owner 是这个桥自身（长生命周期，
/// 随构造它的宿主（`DiskCleanupFeature` 或 `AppDelegate`）存续到 app 退出），不是
/// `RemediationCoordinator`，也不是任何 SwiftUI View。
@MainActor
final class RemediationDemandBridge: MonitoringDemandOwner {
    private let demandCoordinator: MonitoringDemandCoordinator
    private var tokens: [UUID: DemandToken] = [:]

    init(demandCoordinator: MonitoringDemandCoordinator) {
        self.demandCoordinator = demandCoordinator
    }

    /// 幂等：同一 preparedID 重复 begin 不会重复 acquire。
    func begin(preparedID: UUID, kind: RemediationKind) {
        guard tokens[preparedID] == nil else { return }
        tokens[preparedID] = demandCoordinator.acquire(
            module: kind.demandedModule,
            reason: .remediation(kind.representativeHealthIssueKind),
            owner: self
        )
    }

    /// 幂等：preparedID 不存在（未 begin 过，或已经 end 过）时是空操作。
    func end(preparedID: UUID) {
        tokens.removeValue(forKey: preparedID)?.cancel()
    }
}

