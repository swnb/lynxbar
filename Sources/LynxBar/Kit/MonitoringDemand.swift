import Foundation

/// 可被按需驱动的采样模块。
///
/// 与 `DashboardSection` 有意分开：section 是导航目的地，module 是采样单元，
/// 两者不是一一对应（进程列表在 CPU 和 Memory 两个 section 里都有渲染，
/// 网络进程归因则没有自己的 section）。
enum MonitoringModule: String, CaseIterable, Sendable {
    case cpu
    case memory
    case disk
    case network
    case gpu
    case battery
    case process
    case networkProcessAttribution
    /// 通知驱动的公开系统热状态；允许 Overview 常驻，不创建数值轮询。
    case thermal
    /// 兼容数值温度的独立需求；仅显式数值消费者可持有，默认 adapter 不可用。
    case numericTemperature
    /// 控制器/标准 BLE 电量；BLE 还需要用户 opt-in，单独设置不会启动采样。
    case accessoryPower
    /// AI subscription quota polling; requires explicit `Settings.aiUsageEnabled` opt-in.
    case aiUsage
}

/// demand 的来源。参与幂等键，因此必须 Hashable。
enum DemandReason: Hashable, Sendable {
    /// 当前可见的详情页。
    case panel(DashboardSection)
    /// Overview 健康状态所需的常驻信号。
    case overviewHealth
    /// 菜单栏状态槽。长生命周期 lease store 逐槽持有独立 token；相同模块的
    /// 多份 token 仍由 issuedTokens 计数，共享 panel 不会被菜单取消拖停。
    case menuBar
    /// 修复动作的预览与验证期间的临时采样。
    case remediation(HealthIssueKind)
    // 未来：case alert(AlertRuleID) —— 本 change 不实现通知。
}

/// demand 的持有者。用对象身份参与幂等键，因此必须是引用类型。
protocol MonitoringDemandOwner: AnyObject {}

/// demand 凭证。显式 `cancel()` 或析构时释放。
///
/// `deinit` 是 nonisolated，无法直接回调 `@MainActor` 的 coordinator，
/// 因此异步跳回主 actor 释放。spec 对这一点的措辞是 "SHALL **eventually**
/// remove that demand"，异步释放满足该要求。
final class DemandToken {
    private var release: (@Sendable () -> Void)?

    fileprivate init(release: @escaping @Sendable () -> Void) {
        self.release = release
    }

    /// 幂等：重复调用不会产生多次释放。
    func cancel() {
        guard let release else { return }
        self.release = nil
        release()
    }

    deinit {
        guard let release else { return }
        Task { @MainActor in release() }
    }
}

/// 按需采样协调器。
///
/// 唯一职责是引用计数：把「谁还需要这个模块」变成每模块一次的 start / stop 边沿，
/// 不关心模块具体怎么采样。这样生命周期不变量可以脱离 AppKit 与真实 Provider 穷举测试。
@MainActor
final class MonitoringDemandCoordinator {
    /// 模块的 demand 从 0 变 1 时传 true，从 1 变 0 时传 false。
    var onDemandChange: ((MonitoringModule, Bool) -> Void)?

    private struct DemandKey: Hashable {
        let module: MonitoringModule
        let reason: DemandReason
        /// 对象身份，不持有强引用。
        ///
        /// 已知风险：owner 若不显式 `cancel()` 就析构，这个 key 要等到 token
        /// 的 deinit 触发的 `Task { @MainActor in }` 排队执行完才会被移除；这个
        /// 异步窗口内，如果分配器把一个新对象放在同一地址上，新对象的
        /// `ObjectIdentifier` 就会撞上滞留的旧 key（紧凑 alloc/dealloc 场景下
        /// Swift 分配器地址复用概率很高）。当前认为可接受：owner 约定为
        /// AppDelegate / PanelHost / RemediationCoordinator 这类长生命周期对象，
        /// 不用 SwiftUI View 结构体做 owner（`MonitoringDemandOwner: AnyObject`
        /// 已经排除了值类型，但仍需人工保证选的是长生命周期的类实例）；这类对象
        /// 不会在异步释放窗口内被创建 / 销毁到足以撞地址的频率。一旦出现短生命周期
        /// owner，必须重新评估这个设计。
        ///
        /// Task A.3 纪律确认：接入消费者时这条风险被再次确认为硬约束——
        /// SwiftUI 会为同一个可见 section 反复重建 view，是最坏的短生命周期
        /// 场景，绝对不能把 View 结构体当 owner。View 需要上报状态（当前
        /// section、面板可见性）时，一律通过回调把状态传给长生命周期的宿主
        /// （`AppDelegate`、`PanelHost`、`RemediationCoordinator`），由宿主
        /// 持有 token；View 自己永远不直接调用 `acquire`。
        let owner: ObjectIdentifier
    }

    /// 每个 key 已发出、尚未释放的 token 数。
    ///
    /// 幂等 acquire 不再返回不计数的空壳 token —— 空壳会在调用方按最自然的方式使用时
    /// （新 token 覆盖同一个属性，正是 SwiftUI 反复重建 view 的场景）被第一个真 token
    /// 的析构悄悄拖累：属性被覆盖时第一个 token 失去最后一个强引用而 deinit，异步释放
    /// 跑完后 demand 会被错误地清零，而调用方手里还留着一个（其实是空壳的）非 nil token，
    /// 无从察觉。现在每次 acquire 都发一个真 token，key 是否存活看「这个 key 名下发出的
    /// token 是否都已释放」，而不是「某一个特定 token 对象是否还活着」；`counts` 只在某个
    /// key 的 token 数 0→1／1→0 时才增减，幂等性体现为模块级 count 不为同一 key 重复累加。
    private var issuedTokens: [DemandKey: Int] = [:]
    private var counts: [MonitoringModule: Int] = [:]

    init() {}

    func acquire(
        module: MonitoringModule,
        reason: DemandReason,
        owner: MonitoringDemandOwner
    ) -> DemandToken {
        let key = DemandKey(module: module, reason: reason, owner: ObjectIdentifier(owner))

        let updatedKeyCount = (issuedTokens[key] ?? 0) + 1
        issuedTokens[key] = updatedKeyCount
        if updatedKeyCount == 1 {
            let updatedModuleCount = (counts[module] ?? 0) + 1
            counts[module] = updatedModuleCount
            if updatedModuleCount == 1 {
                onDemandChange?(module, true)
            }
        }

        return DemandToken(release: { [weak self] in
            MainActor.assumeIsolated { self?.release(key) }
        })
    }

    /// 仅供测试探针使用。返回的是活跃 key（去重后的消费者）数，不是发出的 token 数。
    func demandCount(for module: MonitoringModule) -> Int {
        counts[module] ?? 0
    }

    private func release(_ key: DemandKey) {
        guard let currentKeyCount = issuedTokens[key], currentKeyCount > 0 else { return }

        guard currentKeyCount > 1 else {
            issuedTokens.removeValue(forKey: key)
            let updatedModuleCount = max(0, (counts[key.module] ?? 0) - 1)
            counts[key.module] = updatedModuleCount
            if updatedModuleCount == 0 {
                onDemandChange?(key.module, false)
            }
            return
        }

        issuedTokens[key] = currentKeyCount - 1
    }
}

/// 可被 demand 驱动启停的采样模块。
///
/// `stopSampling()` 只停止新采样，**不得**清空已积累的有界历史或差值基线；
/// `startSampling()` 必须立即采一次，不能先等一个间隔。
@MainActor
protocol DemandDrivenModule: AnyObject {
    func startSampling()
    func stopSampling()
}
