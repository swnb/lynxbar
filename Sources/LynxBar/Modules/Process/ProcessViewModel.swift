import Foundation

/// 面板展示用的进程（已计算使用率/内存）。
struct DisplayProcess: Sendable, Identifiable {
    let pid: Int32
    let name: String
    let cpuUsage: Double?
    let memoryBytes: UInt64
    /// 采样时刻的完整身份（pid + start time）。`ProcessIconCache` 按身份缓存
    /// 图标，避免 pid 复用把旧进程的图标沿用给新进程。Network 面板的进程流量
    /// 数据来自 nettop，没有 start time，构造不出 identity，这里允许为
    /// nil——图标视图会退化到按裸 pid 每次重新解析身份的入口
    /// （`ProcessIconCache.icon(forPID:)`）。
    let identity: ProcessProvider.ProcessIdentity?
    /// nil 表示没有精确动作身份/GUI 映射，仅能检查。
    let actionTarget: ProcessActionTarget?
    /// 仅代表两个 Top N 榜单观察集的聚合与连续性，不能当作全应用总量。
    let contribution: ApplicationContribution?
    var id: Int32 { pid }

    // `identity` 是 `let` 且需要可省略的默认值——存量属性上直接写
    // `= nil` 只对 `var` 才会保留在编译器合成的 memberwise init 里，
    // 对 `let` 反而会把它整个从 init 参数列表里剔除（该属性从此永远是
    // nil，无法在构造时覆盖）。所以这里手写 init。
    init(
        pid: Int32,
        name: String,
        cpuUsage: Double?,
        memoryBytes: UInt64,
        identity: ProcessProvider.ProcessIdentity? = nil,
        actionTarget: ProcessActionTarget? = nil,
        contribution: ApplicationContribution? = nil
    ) {
        self.pid = pid
        self.name = name
        self.cpuUsage = cpuUsage
        self.memoryBytes = memoryBytes
        self.identity = identity
        self.actionTarget = actionTarget
        self.contribution = contribution
    }

    func replacingName(with displayName: String) -> Self {
        Self(pid: pid, name: displayName, cpuUsage: cpuUsage, memoryBytes: memoryBytes, identity: identity, actionTarget: actionTarget, contribution: contribution)
    }
}

/// 共享的进程监控视图模型，CPU 与 Memory 面板共用同一份采样。
@MainActor
final class ProcessViewModel: ObservableObject, DemandDrivenModule {
    @Published private(set) var byCpu: [DisplayProcess] = []
    @Published private(set) var byMemory: [DisplayProcess] = []

    private let settings: Settings
    private let sampler: @Sendable (
        [ProcessProvider.ProcessIdentity: UInt64]
    ) async -> (raw: [ProcessProvider.RawProcess], cpuTimes: [ProcessProvider.ProcessIdentity: UInt64])
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date
    private let nameCache: ProcessDisplayNameCache
    private let iconCache: ProcessIconCache
    private var cpuTimes: [ProcessProvider.ProcessIdentity: UInt64] = [:]
    private var lastSampledAt: Date?
    private var contributionTracker = ProcessContributionTracker()
    private let applicationResolver: @MainActor (Int32) -> RunningApplicationSnapshot?
    private var task: Task<Void, Never>?

    init(
        settings: Settings,
        sampler: (@Sendable (
            [ProcessProvider.ProcessIdentity: UInt64]
        ) async -> (raw: [ProcessProvider.RawProcess], cpuTimes: [ProcessProvider.ProcessIdentity: UInt64]))? = nil,
        sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil,
        now: (@Sendable () -> Date)? = nil,
        nameCache: ProcessDisplayNameCache = .shared,
        iconCache: ProcessIconCache = .shared,
        applicationResolver: (@MainActor (Int32) -> RunningApplicationSnapshot?)? = nil
    ) {
        self.settings = settings
        self.sampler = sampler ?? { previous in
            await Task.detached { ProcessProvider.sample(previous: previous) }.value
        }
        self.sleeper = sleeper ?? { interval in
            try await Task.sleep(for: .seconds(interval))
        }
        self.now = now ?? { Date() }
        self.nameCache = nameCache
        self.iconCache = iconCache
        self.applicationResolver = applicationResolver ?? { SystemRunningApplicationController().snapshot(for: $0) }
    }

    func startSampling() {
        task?.cancel()
        // 只丢弃明显跨越了停机间隔的锚点，不能无条件丢弃：`.process` 同时
        // 挂在 .overview/.cpu/.memory 三个 section 上，`PanelHost` 在切换
        // section 时于同一个 runloop turn 内同步释放再重新获取全部
        // token——那种 stop/start 只有毫秒级间隔，锚点仍然完全有效，无条件
        // 丢弃会让整个进程列表在每次切换 section（最常见的交互）时空白一个
        // 采样周期。真正需要丢弃锚点的是「面板关了很久再打开」，此时锚点
        // 跨越了远超一个采样周期的间隔，继续用它算出的是一个被严重稀释、
        // 却「看起来正常」的占用值。阈值取 3 倍存活周期：容忍一次漏采
        // 加调度抖动，但拒绝任何看起来像真实停机的间隔。cpuTimes（差值
        // 基线本身）不受这个判断影响，一直原样保留，与 MonitoringDemand.swift
        // 里“stopSampling 不得清空差值基线”的约定不冲突。
        let staleThreshold = SamplingPolicy.liveInterval(settings.updateInterval) * 3
        if let anchor = lastSampledAt, now().timeIntervalSince(anchor) > staleThreshold {
            lastSampledAt = nil
            // 排行连续性不可跨停机间隔累加；CPU 差值基线仍原样保留。
            contributionTracker = ProcessContributionTracker()
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let previous = self.cpuTimes
                let topN = self.settings.processTopN
                let cores = max(1, ProcessViewModel.logicalCores)

                let result = await self.sampler(previous)
                self.cpuTimes = result.cpuTimes

                // 用实测经过时间而非设定间隔做分母：采样本身要枚举全部进程，
                // 真实耗时明显大于设定间隔。
                let sampledAt = self.now()
                let elapsed = self.lastSampledAt.map { sampledAt.timeIntervalSince($0) } ?? 0
                self.lastSampledAt = sampledAt

                // 显示名解析（NSRunningApplication）要跨进程查 LaunchServices，
                // 对枚举出的全部进程逐个查代价明显——而两个榜单最终只展示
                // Top N。这里先用 raw 名字构造/排序/截断，只对最终进入榜单
                // 的 Top N 才通过 nameCache 解析真实显示名，避免为跌出榜单的
                // 大多数进程白白付出 LaunchServices 的成本。图标同理：
                // DisplayProcess 自带 identity，ApplicationProcessIconView
                // 惰性查 iconCache，这里不需要预取。
                let displays = result.raw.map { raw -> DisplayProcess in
                    let usage = ProcessProvider.cpuUsage(
                        current: raw.cpuTimeNs,
                        previous: raw.prevCpuTimeNs,
                        elapsed: elapsed,
                        cores: cores
                    )
                    return DisplayProcess(
                        pid: raw.identity.pid,
                        name: raw.name,
                        cpuUsage: usage,
                        memoryBytes: raw.memoryBytes,
                        identity: raw.identity
                    )
                }
                // 用本轮全部存活 identity 驱逐缓存里已经消失的进程（名字与
                // 图标各自的缓存）；传入完整存活集合（而不是 Top N）是为了
                // 不让暂时跌出榜单、但仍存活的进程白白丢失已缓存的名字/图标。
                let liveIdentities = Set(result.raw.map(\.identity))
                self.nameCache.retain(identities: liveIdentities)
                self.iconCache.retain(identities: liveIdentities)
                let cpuRanking = Array(ProcessRowFormatter.sortedByCPU(displays).prefix(topN))
                let memoryRanking = Array(displays.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(topN))
                let observedPIDs = Set((cpuRanking + memoryRanking).map(\.pid))
                let actionIdentities = Dictionary(uniqueKeysWithValues: result.raw.compactMap { raw in
                    raw.actionIdentity.map { (raw.identity.pid, $0) }
                })
                // AppKit 身份只对两个 Top N 的并集解析一次，沿用显示名/图标缓存。
                var targets: [Int32: ProcessActionTarget] = [:]
                for pid in observedPIDs {
                    if let identity = actionIdentities[pid], let app = self.applicationResolver(pid) {
                        targets[pid] = ProcessActionTarget(process: identity, application: app)
                    }
                }
                let observations = displays.filter { observedPIDs.contains($0.pid) }.compactMap { process -> ProcessContributionObservation? in
                    guard let identity = actionIdentities[process.pid] else { return nil }
                    return ProcessContributionObservation(target: targets[process.pid], fallbackIdentity: identity,
                                                          cpuUsage: process.cpuUsage, memoryBytes: process.memoryBytes)
                }
                let contributions = self.contributionTracker.update(observations: observations, observedAt: sampledAt)
                var contributionsByPID: [Int32: ApplicationContribution] = [:]
                for observation in observations {
                    let contribution = contributions.first { contribution in
                        if let stableID = observation.target?.application.stableIdentifier {
                            return contribution.id == stableID
                        }
                        return contribution.actionTarget?.process.sampleKey == observation.fallbackIdentity.sampleKey
                    }
                    contributionsByPID[observation.fallbackIdentity.pid] = contribution
                }
                let resolveTopN: ([DisplayProcess]) -> [DisplayProcess] = { ranked in
                    ranked.map { process in
                        let name = process.identity.map { self.nameCache.name(for: $0, fallback: process.name) } ?? process.name
                        return DisplayProcess(pid: process.pid, name: name, cpuUsage: process.cpuUsage,
                                              memoryBytes: process.memoryBytes, identity: process.identity,
                                              actionTarget: targets[process.pid], contribution: contributionsByPID[process.pid])
                    }
                }
                self.byCpu = resolveTopN(cpuRanking)
                self.byMemory = resolveTopN(memoryRanking)

                do {
                    try await self.sleeper(self.settings.updateInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stopSampling() {
        task?.cancel()
        task = nil
    }

    private static var logicalCores: Int {
        var num: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.logicalcpu", &num, &size, nil, 0)
        return max(1, Int(num))
    }
}

#if DEBUG
/// 原生 420×600 QA 宿主的确定性状态。只在显式 `--visual-qa-fixture`
/// 参数下替换展示数据，Release 与普通 Debug 运行仍使用真实 Provider。
enum NetworkInsightsVisualQAFixture {
    static var name: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--visual-qa-fixture") else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return "overflow" }
        return arguments[valueIndex].lowercased()
    }

    static var processRows: [DisplayProcess]? {
        guard let name else { return nil }
        switch name {
        case "idle", "unavailable":
            return []
        default:
            var rows: [DisplayProcess] = []
            for index in 0..<10 {
                let rank = index + 1
                let weight = 10 - index
                rows.append(DisplayProcess(
                    pid: Int32(70_000 + index),
                    name: "QA Process \(rank)",
                    cpuUsage: Double(weight) / 100,
                    memoryBytes: UInt64(weight) * 64 * 1_024 * 1_024
                ))
            }
            return rows
        }
    }

    static var networkUsages: [NetworkProcessProvider.Usage]? {
        guard let processRows else { return nil }
        var usages: [NetworkProcessProvider.Usage] = []
        for (index, process) in processRows.enumerated() {
            usages.append(NetworkProcessProvider.Usage(
                pid: process.pid,
                name: process.name,
                downloadBytesPerSecond: Double(80_000 - index * 4_000),
                uploadBytesPerSecond: Double(18_000 - index * 750)
            ))
        }
        return usages
    }

    static var attributionAvailability: NetworkProcessAttributionAvailability? {
        switch name {
        case "unavailable":
            return .unavailable
        case "idle":
            return .ready
        case .some:
            return .ready
        case nil:
            return nil
        }
    }

    static var transferTotals: NetworkRangeTransferTotals? {
        switch name {
        case "unavailable":
            return .empty(.minute, status: .unavailable)
        case "idle":
            return NetworkRangeTransferTotals(
                range: .minute,
                downloadBytes: 0,
                uploadBytes: 0,
                downloadCoveredDuration: 60,
                uploadCoveredDuration: 60,
                status: .complete
            )
        case .some:
            return NetworkRangeTransferTotals(
                range: .minute,
                downloadBytes: 8_720_384,
                uploadBytes: 1_658_880,
                downloadCoveredDuration: 42,
                uploadCoveredDuration: 38,
                status: .partial
            )
        case nil:
            return nil
        }
    }
}
#endif
