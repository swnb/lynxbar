import Foundation

struct NetworkSnapshot: Sendable {
    var downloadBytesPerSecond: Double = 0
    var uploadBytesPerSecond: Double = 0
    /// nil 表示这一 tick 主接口不存在，或字节计数不可用；不得显示成 0。
    var totalDownloaded: UInt64?
    var totalUploaded: UInt64?
    var interfaces: [NetworkProvider.Interface] = []
    var primaryInterface: NetworkProvider.Interface?
    var publicIP: String?
    var publicIPIsCached = false
}

@MainActor
final class NetworkViewModel: ObservableObject, DemandDrivenModule {
    static let allowedRanges: [HistoryRange] = [.minute, .hour, .fiveHours, .day]

    @Published private(set) var snapshot = NetworkSnapshot()
    /// 最近一次数值采样提交的来源时间（UTC Date）；nil 为尚未采样。
    /// 仅真实采样路径更新，未知快照也提交以隐藏旧值。历史、范围、压力或
    /// 展示元数据的发布不能延长 freshness；写入前必须先安装对应 snapshot。
    @Published private(set) var lastNumericSampleAt: Date?
    @Published private(set) var selectedRange: HistoryRange = .minute
    @Published private(set) var downHistoryResult = MetricHistoryResult.empty(.minute)
    @Published private(set) var upHistoryResult = MetricHistoryResult.empty(.minute)
    @Published private(set) var downRecentHistory = MetricHistoryResult.empty(.minute)
    @Published private(set) var upRecentHistory = MetricHistoryResult.empty(.minute)
    @Published private(set) var selectedTransferTotals =
        NetworkRangeTransferTotals.empty(.minute)
    @Published private(set) var processTraffic: [NetworkProcessProvider.Usage] = []
    @Published private(set) var processAttributionAvailability:
        NetworkProcessAttributionAvailability = .collecting

    var downHistory: [Double] { downHistoryResult.points.map(\.value) }
    var upHistory: [Double] { upHistoryResult.points.map(\.value) }

    private let settings: Settings
    private let historyStore: MetricHistoryStore
    private let networkSampler: @Sendable () async -> NetworkProvider.RawCounters
    private let processSampler: @Sendable () async -> NetworkProcessProvider.Snapshot
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date
    private let nameCache: ProcessDisplayNameCache
    private var previousIn: UInt64 = 0
    private var previousOut: UInt64 = 0
    private var previousInterfaceName: String?
    private var previousCounterAt: Date?
    private var lastPublicIPFetch = Date.distantPast
    private var processAttributionTracker = NetworkProcessAttributionTracker()
    private var task: Task<Void, Never>?
    /// networkProcessAttribution 是独立于 network 本身的 demand（只有 Network
    /// 面板打开才 acquire）；network 常驻于 overviewHealth，因此 nettop 归因
    /// 不能只靠 `startSampling()`/`stopSampling()` 控制，否则面板关闭后
    /// nettop 仍会随基础网络采样每 3 秒 fork 一次。
    private var attributionDemanded = false
    #if DEBUG
    /// 仅供测试注入（Task D.4 撕裂读回归测试）：非 nil 时，`refreshHistoryViews`
    /// 会在下行历史查询完成、发起上行历史查询之前，把这个值直接写入
    /// `selectedRange`（绕开 `selectRange(_:)` 的异步重查询逻辑，避免引入
    /// 与本次验证无关的竞态），随后立即清空，保证每轮采样最多生效一次。
    ///
    /// 用于确定性地重现"历史查询期间 `selectedRange` 被重入改写"这个前提
    /// 条件——`MetricHistoryStore` 两次 actor 调用之间的挂起窗口极窄，真实
    /// 调度竞争去命中这个窗口不可靠（flaky），因此用这个显式注入点代替。
    /// 生产路径永远不设置它。见 `NetworkViewModelTests.swift`。
    var downloadQueryInterleavedRangeForTesting: HistoryRange?
    #endif

    private static let publicIPRefreshInterval: TimeInterval = 600
    private static let publicIPCacheKey = "network.publicIP.cache"
    static let processAttributionRefreshInterval: TimeInterval = 3

    init(
        settings: Settings,
        historyStore: MetricHistoryStore = .shared,
        networkSampler: (@Sendable () async -> NetworkProvider.RawCounters)? = nil,
        processSampler: (@Sendable () async -> NetworkProcessProvider.Snapshot)? = nil,
        sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil,
        now: (@Sendable () -> Date)? = nil,
        nameCache: ProcessDisplayNameCache = .shared
    ) {
        self.settings = settings
        self.historyStore = historyStore
        self.nameCache = nameCache
        self.networkSampler = networkSampler ?? {
            await Task.detached { NetworkProvider.readCounters() }.value
        }
        self.processSampler = processSampler ?? {
            await Task.detached { NetworkProcessProvider.sample() }.value
        }
        self.sleeper = sleeper ?? { interval in
            try await Task.sleep(for: .seconds(interval))
        }
        self.now = now ?? { Date() }
        snapshot.publicIP = UserDefaults.standard.string(forKey: Self.publicIPCacheKey)
        snapshot.publicIPIsCached = snapshot.publicIP != nil
    }

    func startSampling() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = SamplingPolicy.liveInterval(self.settings.updateInterval)
                guard await self.sampleOnce() else { return }
                do {
                    try await self.sleeper(interval)
                } catch {
                    return
                }
            }
        }
    }

    /// 单次采样的编排入口。返回 `false` 表示归因等待期间外层任务已被取消，
    /// 调用方须立即终止整个采样循环（不再刷新公网 IP、不再进入下一轮
    /// sleep）——与原先内联在 `while` 循环里的 `return` 语义一致。
    private func sampleOnce() async -> Bool {
        let attribution = beginProcessAttributionIfNeeded()
        let (snapshot, transfer, timestamp) = await sampleInterfaceCounters()
        await recordHistory(snapshot: snapshot, transfer: transfer, at: timestamp)
        await refreshHistoryViews(at: timestamp)
        guard await finishProcessAttribution(attribution) else { return false }
        refreshPublicIPIfDue()
        return true
    }

    private func beginProcessAttributionIfNeeded() -> Task<
        (NetworkProcessProvider.Snapshot, Date),
        Never
    >? {
        let attemptTimestamp = now()
        let shouldSampleProcesses = attributionDemanded
            && processAttributionTracker.beginAttempt(
                at: attemptTimestamp,
                minimumInterval: Self.processAttributionRefreshInterval
            )
        return shouldSampleProcesses
            ? Task {
                let processSnapshot = await self.processSampler()
                // 速率分母必须截止到 nettop 快照真正完成的时刻，不能包含后续
                // 历史查询与磁盘 actor 等待，否则系统繁忙时会低估进程流量。
                return (processSnapshot, self.now())
            }
            : nil
    }

    private func sampleInterfaceCounters() async -> (
        snapshot: NetworkSnapshot,
        transfer: NetworkTransferDelta?,
        timestamp: Date
    ) {
        let prevIn = self.previousIn
        let prevOut = self.previousOut
        let previousName = self.previousInterfaceName
        let previousCounterAt = self.previousCounterAt

        let raw = await networkSampler()
        let timestamp = now()

        var next = NetworkSnapshot()
        next.totalDownloaded = raw.totalIn
        next.totalUploaded = raw.totalOut
        next.interfaces = raw.interfaces
        next.primaryInterface = raw.primaryInterface
        next.publicIP = snapshot.publicIP
        next.publicIPIsCached = snapshot.publicIPIsCached

        let interfaceName = raw.primaryInterface?.name
        // 计数不可用（sysctl 整体失败，或这一 tick 恰好没读到主接口）时
        // raw.totalIn/totalOut 是 nil，拿不到真实的 currentIn/currentOut，
        // 绝不能拿 0 顶替去调用 between()——那会把「不知道」误算成
        // 「掉到了 0」，下一 tick 再算出虚假的巨量 delta。
        var transfer: NetworkTransferDelta?
        if let currentIn = raw.totalIn, let currentOut = raw.totalOut {
            transfer = NetworkTransferDelta.between(
                currentInterfaceName: interfaceName,
                currentIn: currentIn,
                currentOut: currentOut,
                currentAt: timestamp,
                previousInterfaceName: previousName,
                previousIn: prevIn,
                previousOut: prevOut,
                previousAt: previousCounterAt
            )
        }
        if let transfer {
            if let downloadBytes = transfer.downloadBytes {
                next.downloadBytesPerSecond = Double(downloadBytes) / transfer.duration
            }
            if let uploadBytes = transfer.uploadBytes {
                next.uploadBytesPerSecond = Double(uploadBytes) / transfer.duration
            }
        }
        // 同样的原因：这一 tick 计数不可用时不能把它悄悄存成基线，否则
        // 下一 tick 恢复正常读数后会拿这个假基线算出虚假尖峰。让基线
        // 整体作废（previousInterfaceName/previousCounterAt 一起置
        // nil），与「主接口不存在」复用同一条降级路径。
        if let currentIn = raw.totalIn, let currentOut = raw.totalOut, let interfaceName {
            self.previousIn = currentIn
            self.previousOut = currentOut
            self.previousInterfaceName = interfaceName
            self.previousCounterAt = timestamp
        } else {
            self.previousInterfaceName = nil
            self.previousCounterAt = nil
        }
        snapshot = next
        lastNumericSampleAt = timestamp

        return (next, transfer, timestamp)
    }

    private func recordHistory(
        snapshot: NetworkSnapshot,
        transfer: NetworkTransferDelta?,
        at timestamp: Date
    ) async {
        if let transfer {
            await historyStore.recordNetworkTransfer(transfer)
        }
        await historyStore.record(
            .networkDownload,
            value: snapshot.downloadBytesPerSecond,
            at: timestamp
        )
        await historyStore.record(
            .networkUpload,
            value: snapshot.uploadBytesPerSecond,
            at: timestamp
        )
    }

    /// 三次查询（down/up/totals）保持串行 await，不改成 `async let` 并发——
    /// D.3 判断过这个改动会顺带消除下面这个撕裂读，属于行为变化而非纯
    /// 重构，因此没有夹带（详见 Task D.3 报告）。
    ///
    /// 撕裂读修复（Task D.4）：`selectedRange` 在这里只读一次并锁进局部
    /// 变量 `range`，后续所有查询与 `.minute` 判断都用这个局部值，不再
    /// 逐次重读 `selectedRange`。原因：`selectRange(_:)` 会在 MainActor 的
    /// 挂起点之间改写 `selectedRange`；如果这里跨多个 await 点反复读取，
    /// 用户在这几次查询之间切换时间范围，会让 down/up/totals 拿到不同的
    /// range，导致上下行图表的时间轴不一致。回归测试见
    /// `NetworkViewModelTests.testRefreshHistoryViewsLocksRangeAgainstMidFlightSelectRange`。
    private func refreshHistoryViews(at timestamp: Date) async {
        let range = selectedRange
        let down = await historyStore.query(
            .networkDownload,
            range: range,
            now: timestamp
        )
        #if DEBUG
        if let interleavedRange = downloadQueryInterleavedRangeForTesting {
            downloadQueryInterleavedRangeForTesting = nil
            selectedRange = interleavedRange
        }
        #endif
        let up = await historyStore.query(
            .networkUpload,
            range: range,
            now: timestamp
        )
        let transferTotals = await historyStore.queryNetworkTransfers(
            range: range,
            now: timestamp
        )
        downHistoryResult = down
        upHistoryResult = up
        selectedTransferTotals = presentableTransferTotals(transferTotals)
        if range == .minute {
            downRecentHistory = down
            upRecentHistory = up
        } else {
            downRecentHistory = await historyStore.query(
                .networkDownload,
                range: .minute,
                now: timestamp
            )
            upRecentHistory = await historyStore.query(
                .networkUpload,
                range: .minute,
                now: timestamp
            )
        }
    }

    /// 返回 `false` 表示归因等待期间外层采样任务已被取消。
    private func finishProcessAttribution(
        _ attributionTask: Task<(NetworkProcessProvider.Snapshot, Date), Never>?
    ) async -> Bool {
        guard let attributionTask else { return true }
        let (processSnapshot, sampledAt) = await attributionTask.value
        guard !Task.isCancelled else {
            processAttributionTracker.cancelAttempt()
            return false
        }
        processAttributionTracker.finish(processSnapshot, at: sampledAt)
        publishProcessAttribution()
        return true
    }

    private func refreshPublicIPIfDue() {
        if settings.showPublicIP,
           now().timeIntervalSince(lastPublicIPFetch)
            > Self.publicIPRefreshInterval {
            lastPublicIPFetch = now()
            Task { @MainActor [weak self] in
                let ip = await NetworkProvider.fetchPublicIP()
                guard let self, let ip else { return }
                self.applyPublicIP(ip)
            }
        }
    }

    /// HTTPS 完成后的展示/缓存提交。公网 IP 不属于网卡数值采样，即使
    /// 同一个值重复发布，也不得更新 lastNumericSampleAt。
    func applyPublicIP(_ ip: String) {
        snapshot.publicIP = ip
        snapshot.publicIPIsCached = false
        UserDefaults.standard.set(ip, forKey: Self.publicIPCacheKey)
    }

    func selectRange(_ range: HistoryRange) {
        guard Self.allowedRanges.contains(range) else { return }
        selectedRange = range
        Task { [weak self] in
            guard let self else { return }
            let timestamp = self.now()
            async let down = self.historyStore.query(
                .networkDownload,
                range: range,
                now: timestamp
            )
            async let up = self.historyStore.query(
                .networkUpload,
                range: range,
                now: timestamp
            )
            async let totals = self.historyStore.queryNetworkTransfers(
                range: range,
                now: timestamp
            )
            self.downHistoryResult = await down
            self.upHistoryResult = await up
            self.selectedTransferTotals = self.presentableTransferTotals(await totals)
        }
    }

    func stopSampling() {
        task?.cancel()
        task = nil
        processAttributionTracker.cancelAttempt()
    }

    /// 由 `.networkProcessAttribution` demand 驱动，与 `startSampling()`/
    /// `stopSampling()` 相互独立：network 常驻时也可能没有归因 demand。
    ///
    /// 必须重置 tracker：`finish()` 算速率用 `bytesDelta / (now -
    /// lastSuccessAt)`，分母没有上限。面板关闭期间 network 因 overviewHealth
    /// 继续跑，但归因不跑，`lastSuccessAt` 会停留在关闭前最后一次成功采样的
    /// 时间戳；重开面板后如果不重置，第一次成功采样会用「关闭时长」做分母，
    /// 把这段时间累积的字节数稀释成一个错误的速率值显示出来。重置后
    /// `lastSuccessAt` 为 nil，第一次成功采样走 `.collecting` 分支（不产出
    /// 具体数值），第二次才产出真实速率——这是 tracker 本来就有的冷启动
    /// 语义，与 App 首次启动时一致。
    func startAttribution() {
        processAttributionTracker = NetworkProcessAttributionTracker()
        attributionDemanded = true
    }

    /// 只停止后续新的 nettop 尝试；已积累的 `processTraffic`/
    /// `processAttributionAvailability` 不清空（与 `stopSampling()` 的
    /// “不清空历史”原则一致）。
    func stopAttribution() {
        attributionDemanded = false
    }

    /// `usages` 已经按流量降序排好（`NetworkProcessProvider.rates()`），这里
    /// 先 `prefix(topN)` 再解析显示名——与 `ProcessViewModel` 同样的道理：
    /// `NSRunningApplication` 要跨进程查 LaunchServices，只对最终展示的
    /// Top N 付出这个代价。`nameCache` 是与 `ProcessViewModel` 共享的同一个
    /// 缓存实例（`.shared`），但这里没有 start time（nettop 的 CSV 输出只有
    /// pid），走 `name(forPID:fallback:)` 入口，内部会重新解析 identity。
    ///
    /// 故意不调用 `nameCache.retain(identities:)`：`retain(identities:)` 是
    /// 硬性「只保留传入集合里的」，`ProcessViewModel` 每轮传入的是
    /// `ProcessProvider.sample()` 枚举出的全部存活进程（真正的超集，包含
    /// nettop 能报告的一切），如果这里也调用、传入的却是 nettop 报告的、
    /// 有流量的进程子集（通常远小于全量存活进程），会把 `ProcessViewModel`
    /// 缓存的、暂时没有网络流量的 CPU/Memory 榜单条目冲掉，实质性削弱
    /// 那边的缓存效果。让 `ProcessViewModel` 独占驱逐权，`nameCache`
    /// 自身的 `capacity` 硬上限兜底这里可能出现的无界增长（`retain` 只在
    /// `.process` demand 被 acquire——即 Overview/CPU/Memory 面板打开——时
    /// 才会跑；只开 Network 面板、或 `#if DEBUG` 的 visual QA 窗口停在
    /// `.network` 而主面板停在 `.overview` 这种两个 demand 并发的场景下，
    /// `retain` 可能长期不触发这一侧写入的条目）。
    private func publishProcessAttribution() {
        processAttributionAvailability = processAttributionTracker.availability
        processTraffic = processAttributionTracker.usages.prefix(settings.processTopN).map { usage in
            usage.replacingName(with: nameCache.name(forPID: usage.pid, fallback: usage.name))
        }
    }

    private func presentableTransferTotals(
        _ totals: NetworkRangeTransferTotals
    ) -> NetworkRangeTransferTotals {
        snapshot.primaryInterface == nil
            ? totals.markingUnavailableWhenEmpty()
            : totals
    }
}
