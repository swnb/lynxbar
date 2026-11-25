import AppKit
import Foundation

/// nil 的 libproc 读数不能证明退出：无权限/短暂失败也可能返回 nil。
/// exited 只在只读存在性检查明确返回 ESRCH 时成立。
enum ProcessIdentityStatus: Equatable, Sendable {
    case identified(ProcessKernelIdentity)
    case exited
    case unavailable
}
protocol ProcessIdentityReading: Sendable {
    func identity(for pid: Int32) async -> ProcessKernelIdentity?
    func status(for pid: Int32) async -> ProcessIdentityStatus
}
extension ProcessIdentityReading {
    func status(for pid: Int32) async -> ProcessIdentityStatus {
        if let identity = await identity(for: pid) { return .identified(identity) }
        return .unavailable
    }
}
struct LibprocProcessIdentityReader: ProcessIdentityReading {
    func identity(for pid: Int32) async -> ProcessKernelIdentity? { ProcessProvider.identity(for: pid) }
    func status(for pid: Int32) async -> ProcessIdentityStatus {
        if let identity = ProcessProvider.identity(for: pid) { return .identified(identity) }
        guard pid > 0 else { return .unavailable }
        return kill(pid, 0) == -1 && errno == ESRCH ? .exited : .unavailable
    }
}

/// 同步句柄边界。lookup 返回的对象在最终检查和请求之间一直保留，不再按 PID
/// 解析第二个对象。MainActor 排除 Swift 挂起/重入，但不是内核检查与请求的原子性承诺。
@MainActor
protocol RunningApplicationHandle: AnyObject {
    var snapshot: RunningApplicationSnapshot { get }
    func requestQuit(force: Bool) -> Bool
}
@MainActor
private final class NativeRunningApplicationHandle: RunningApplicationHandle {
    let application: NSRunningApplication
    init(_ application: NSRunningApplication) { self.application = application }
    var snapshot: RunningApplicationSnapshot { RunningApplicationSnapshot(application) }
    func requestQuit(force: Bool) -> Bool {
        force ? application.forceTerminate() : application.terminate()
    }
}
enum ProcessQuitRequestResult: Equatable, Sendable {
    case accepted(Bool)
    case stale
    case ineligible(ProcessActionIneligibilityReason)
}
@MainActor
protocol RunningApplicationControlling: Sendable {
    func snapshot(for pid: Int32) -> RunningApplicationSnapshot?
    func requestQuit(target: ProcessActionTarget, kind: ProcessActionKind,
                     policy: ProcessActionEligibilityPolicy) -> ProcessQuitRequestResult
    func requestQuit(target: ProcessActionTarget, kind: ProcessActionKind,
                     policy: ProcessActionEligibilityPolicy,
                     evidenceIsCurrent: @MainActor @Sendable () -> Bool) -> ProcessQuitRequestResult
}
extension RunningApplicationControlling {
    /// fake/第三方 adapter 的保守默认；同步 MainActor 方法之间无挂起点。
    func requestQuit(target: ProcessActionTarget, kind: ProcessActionKind,
                     policy: ProcessActionEligibilityPolicy,
                     evidenceIsCurrent: @MainActor @Sendable () -> Bool) -> ProcessQuitRequestResult {
        guard evidenceIsCurrent() else { return .stale }
        return requestQuit(target: target, kind: kind, policy: policy)
    }
}

@MainActor
struct SystemRunningApplicationController: RunningApplicationControlling {
    private let applicationLookup: @MainActor (Int32) -> (any RunningApplicationHandle)?
    private let identityLookup: @MainActor (Int32) -> ProcessKernelIdentity?
    init(applicationLookup: (@MainActor (Int32) -> (any RunningApplicationHandle)?)? = nil,
         identityLookup: (@MainActor (Int32) -> ProcessKernelIdentity?)? = nil) {
        self.applicationLookup = applicationLookup ?? { pid in
            NSRunningApplication(processIdentifier: pid).map(NativeRunningApplicationHandle.init)
        }
        self.identityLookup = identityLookup ?? { ProcessProvider.identity(for: $0) }
    }
    func snapshot(for pid: Int32) -> RunningApplicationSnapshot? { applicationLookup(pid)?.snapshot }
    func requestQuit(target: ProcessActionTarget, kind: ProcessActionKind,
                     policy: ProcessActionEligibilityPolicy) -> ProcessQuitRequestResult {
        requestQuit(target: target, kind: kind, policy: policy, evidenceIsCurrent: { true })
    }
    func requestQuit(target: ProcessActionTarget, kind: ProcessActionKind,
                     policy: ProcessActionEligibilityPolicy,
                     evidenceIsCurrent: @MainActor @Sendable () -> Bool) -> ProcessQuitRequestResult {
        // 顺序是合同：先捕获 app 对象，再读内核字段，再对该对象直接请求。
        guard let application = applicationLookup(target.process.pid),
              let identity = identityLookup(target.process.pid) else { return .stale }
        let current = ProcessActionTarget(process: identity, application: application.snapshot)
        guard target.matchesActionIdentity(current) else { return .stale }
        if case let .ineligible(reason) = policy.evaluate(current) { return .ineligible(reason) }
        // executor 的 actor hop 也可能让健康证据变化；在同一不可挂起段的最终
        // 请求前重读证据，闭包只能读状态，不得挂起或执行副作用。
        guard evidenceIsCurrent() else { return .stale }
        return .accepted(application.requestQuit(force: kind == .forceQuit))
    }
}

protocol ProcessActionWaiting: Sendable { func wait(for interval: Duration) async }
struct SystemProcessActionWaiter: ProcessActionWaiting {
    func wait(for interval: Duration) async { try? await Task.sleep(for: interval) }
}
protocol ProcessActionExecuting: Sendable {
    func currentTarget(pid: Int32) async -> ProcessActionTarget?
    func requestNormalQuit(_ preparedTarget: ProcessActionTarget) async -> ProcessActionResult
    func requestForceQuit(_ preparedTarget: ProcessActionTarget, permit: ProcessForceQuitPermit) async -> ProcessActionResult
    func requestNormalQuit(_ preparedTarget: ProcessActionTarget,
                           evidenceIsCurrent: @escaping @MainActor @Sendable () -> Bool) async -> ProcessActionResult
    func requestForceQuit(_ preparedTarget: ProcessActionTarget, permit: ProcessForceQuitPermit,
                          evidenceIsCurrent: @escaping @MainActor @Sendable () -> Bool) async -> ProcessActionResult
}
extension ProcessActionExecuting {
    func requestNormalQuit(_ target: ProcessActionTarget,
                           evidenceIsCurrent: @escaping @MainActor @Sendable () -> Bool) async -> ProcessActionResult {
        guard await evidenceIsCurrent() else {
            return ProcessActionResult(kind: .normalQuit, outcome: .stale, requestAccepted: nil, forceQuitPermit: nil)
        }
        return await requestNormalQuit(target)
    }
    func requestForceQuit(_ target: ProcessActionTarget, permit: ProcessForceQuitPermit,
                          evidenceIsCurrent: @escaping @MainActor @Sendable () -> Bool) async -> ProcessActionResult {
        guard await evidenceIsCurrent() else {
            return ProcessActionResult(kind: .forceQuit, outcome: .stale, requestAccepted: nil, forceQuitPermit: nil)
        }
        return await requestForceQuit(target, permit: permit)
    }
}

/// 仅响应显式确认后的动作；持有失败后短期 force permit，独立验证实例消失。
/// 正常请求默认最多等待 3 秒（15×200ms）；拒绝不会自动升级为 force。
actor ProcessActionProvider: ProcessActionExecuting {
    private let identityReader: any ProcessIdentityReading
    private let applicationController: any RunningApplicationControlling
    private let waiter: any ProcessActionWaiting
    private let eligibilityPolicy: ProcessActionEligibilityPolicy
    private let pollInterval: Duration
    private let maximumPollCount: Int
    private let now: @Sendable () -> Date
    private struct ForceRegistration: Sendable { let target: ProcessActionTarget; let expiresAt: Date }
    private var forcePermits: [UUID: ForceRegistration] = [:]
    init(identityReader: any ProcessIdentityReading = LibprocProcessIdentityReader(),
         applicationController: (any RunningApplicationControlling)? = nil,
         waiter: any ProcessActionWaiting = SystemProcessActionWaiter(),
         eligibilityPolicy: ProcessActionEligibilityPolicy = ProcessActionEligibilityPolicy(),
         pollInterval: Duration = .milliseconds(200), maximumPollCount: Int = 15,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.identityReader = identityReader
        // Construction is actor-safe: the native controller is resolved once on MainActor below.
        self.applicationController = applicationController ?? LazySystemRunningApplicationController()
        self.waiter = waiter
        self.eligibilityPolicy = eligibilityPolicy
        self.pollInterval = pollInterval
        self.maximumPollCount = max(1, maximumPollCount)
        self.now = now
    }
    func currentTarget(pid: Int32) async -> ProcessActionTarget? {
        guard let process = await identityReader.identity(for: pid),
              let application = await applicationController.snapshot(for: pid) else { return nil }
        return ProcessActionTarget(process: process, application: application)
    }
    func requestNormalQuit(_ target: ProcessActionTarget) async -> ProcessActionResult {
        await requestNormalQuit(target, evidenceIsCurrent: { true })
    }
    func requestNormalQuit(_ target: ProcessActionTarget,
                           evidenceIsCurrent: @escaping @MainActor @Sendable () -> Bool) async -> ProcessActionResult {
        let request = await applicationController.requestQuit(target: target, kind: .normalQuit,
            policy: eligibilityPolicy, evidenceIsCurrent: evidenceIsCurrent)
        switch request {
        case .stale: return result(.normalQuit, .stale)
        case let .ineligible(reason): return result(.normalQuit, .ineligible(reason))
        case .accepted(false): return failedNormal(.refused, target: target, accepted: false)
        case .accepted(true):
            let outcome = await waitForExit(target)
            if outcome == .timedOut { return failedNormal(.timedOut, target: target, accepted: true) }
            return result(.normalQuit, outcome, accepted: true)
        }
    }
    func requestForceQuit(_ target: ProcessActionTarget, permit: ProcessForceQuitPermit) async -> ProcessActionResult {
        await requestForceQuit(target, permit: permit, evidenceIsCurrent: { true })
    }
    func requestForceQuit(_ target: ProcessActionTarget, permit: ProcessForceQuitPermit,
                          evidenceIsCurrent: @escaping @MainActor @Sendable () -> Bool) async -> ProcessActionResult {
        guard let registration = forcePermits.removeValue(forKey: permit.id),
              registration.target == target, permit.targetKey == target.process.sampleKey,
              registration.expiresAt == permit.expiresAt, now() < permit.expiresAt else {
            return result(.forceQuit, .forceNotAuthorized)
        }
        switch await applicationController.requestQuit(target: target, kind: .forceQuit,
            policy: eligibilityPolicy, evidenceIsCurrent: evidenceIsCurrent) {
        case .stale: return result(.forceQuit, .stale)
        case let .ineligible(reason): return result(.forceQuit, .ineligible(reason))
        case .accepted(false): return result(.forceQuit, .refused, accepted: false)
        case .accepted(true): return result(.forceQuit, await waitForExit(target), accepted: true)
        }
    }
    private func waitForExit(_ target: ProcessActionTarget) async -> ProcessActionOutcome {
        var sawUnavailable = false
        for index in 0...maximumPollCount {
            switch await identityReader.status(for: target.process.pid) {
            case .exited: return .exited
            case let .identified(identity):
                if identity.sampleKey != target.process.sampleKey { return .exited }
            case .unavailable: sawUnavailable = true
            }
            if index < maximumPollCount { await waiter.wait(for: pollInterval) }
        }
        return sawUnavailable ? .unknown : .timedOut
    }
    private func failedNormal(_ outcome: ProcessActionOutcome, target: ProcessActionTarget, accepted: Bool) -> ProcessActionResult {
        let timestamp = now()
        forcePermits = forcePermits.filter { $0.value.expiresAt > timestamp }
        let permit = ProcessForceQuitPermit(id: UUID(), targetKey: target.process.sampleKey,
                                            expiresAt: timestamp.addingTimeInterval(30))
        forcePermits[permit.id] = ForceRegistration(target: target, expiresAt: permit.expiresAt)
        return ProcessActionResult(kind: .normalQuit, outcome: outcome, requestAccepted: accepted, forceQuitPermit: permit)
    }
    private func result(_ kind: ProcessActionKind, _ outcome: ProcessActionOutcome, accepted: Bool? = nil) -> ProcessActionResult {
        ProcessActionResult(kind: kind, outcome: outcome, requestAccepted: accepted, forceQuitPermit: nil)
    }
}

/// 无状态 facade 允许默认值在非 MainActor 的 provider init 构造；实际 AppKit
/// lookup/check/request 仍全部由 MainActor 的同步 controller 方法完成。
private struct LazySystemRunningApplicationController: RunningApplicationControlling {
    @MainActor func snapshot(for pid: Int32) -> RunningApplicationSnapshot? {
        SystemRunningApplicationController().snapshot(for: pid)
    }
    @MainActor func requestQuit(target: ProcessActionTarget, kind: ProcessActionKind,
                               policy: ProcessActionEligibilityPolicy) -> ProcessQuitRequestResult {
        SystemRunningApplicationController().requestQuit(target: target, kind: kind, policy: policy)
    }
    @MainActor func requestQuit(target: ProcessActionTarget, kind: ProcessActionKind,
                               policy: ProcessActionEligibilityPolicy,
                               evidenceIsCurrent: @MainActor @Sendable () -> Bool) -> ProcessQuitRequestResult {
        SystemRunningApplicationController().requestQuit(target: target, kind: kind,
            policy: policy, evidenceIsCurrent: evidenceIsCurrent)
    }
}
extension RunningApplicationSnapshot {
    @MainActor init(_ application: NSRunningApplication) {
        pid = application.processIdentifier
        bundleIdentifier = application.bundleIdentifier
        localizedName = application.localizedName
        bundleURL = application.bundleURL
        executableURL = application.executableURL
        switch application.activationPolicy {
        case .regular: activationPolicy = .regular
        case .accessory: activationPolicy = .accessory
        case .prohibited: activationPolicy = .prohibited
        @unknown default: activationPolicy = .unknown
        }
        isTerminated = application.isTerminated
    }
}
