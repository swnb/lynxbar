import XCTest
@testable import LynxBar

/// `NetworkProvider.swift`/`NetworkProviderTests.swift` 之外新增的第三个文件：
/// Important 1 的问题横跨 `NetworkProvider`（产出 nil）与 `NetworkViewModel`
/// （消费 nil 时是否会悄悄拿 0 顶替）两层，只在 `NetworkProviderTests.swift`
/// 里测无法覆盖 `NetworkViewModel.startSampling()` 的 tick-over-tick 状态机。
/// `DiskCleanupViewModelTests.swift` 是同一种"通过依赖注入直接跑 ViewModel
/// 采样循环"的既有先例，这里的写法（`waitUntil` 轮询 + actor 承载的脚本化
/// sampler/sleeper）与其保持一致。
@MainActor
final class NetworkViewModelTests: XCTestCase {
    /// 回归锁：某一 tick 计数不可用（sysctl 整体失败，或恰好没读到主接口）时，
    /// ViewModel 不能把它当成基线存起来——否则下一 tick 计数恢复正常后，会拿
    /// 这个假基线（相当于「上次是 0」）算出一个虚假的巨量速率尖峰。
    func testUnavailableTickDoesNotFabricateBaselineForNextTick() async {
        let suiteName = "LynxBarTests.NetworkUnavailableBaseline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        settings.showPublicIP = false // 避免测试触发真实的公网 IP 查询

        let available = makeInterface(name: "en0", inBytes: 1_000, outBytes: 1_000)
        let unavailable = makeInterface(name: "en0", inBytes: nil, outBytes: nil)
        let recovered = makeInterface(name: "en0", inBytes: 5_000_000_000, outBytes: 5_000_000_000)

        let probe = NetworkSnapshotSequenceProbe([
            NetworkProvider.RawCounters(
                totalIn: 1_000,
                totalOut: 1_000,
                interfaces: [available],
                primaryInterface: available
            ),
            NetworkProvider.RawCounters(
                totalIn: nil,
                totalOut: nil,
                interfaces: [unavailable],
                primaryInterface: unavailable
            ),
            NetworkProvider.RawCounters(
                totalIn: 5_000_000_000,
                totalOut: 5_000_000_000,
                interfaces: [recovered],
                primaryInterface: recovered
            ),
        ])

        let viewModel = NetworkViewModel(
            settings: settings,
            historyStore: MetricHistoryStore(fileURL: nil),
            networkSampler: { await probe.sample() },
            sleeper: { interval in try await probe.sleep(for: interval) }
        )

        viewModel.startSampling()
        await waitUntil("应该已经采到第三个 tick（计数恢复）") {
            await probe.hasSampled(atLeast: 3)
        }
        await waitUntil("snapshot 应该已经反映第三个 tick 的计数") {
            viewModel.snapshot.totalDownloaded == 5_000_000_000
        }
        viewModel.stopSampling()

        XCTAssertEqual(
            viewModel.snapshot.downloadBytesPerSecond, 0,
            "计数从不可用恢复后不该凭空算出下载速率尖峰"
        )
        XCTAssertEqual(
            viewModel.snapshot.uploadBytesPerSecond, 0,
            "计数从不可用恢复后不该凭空算出上传速率尖峰"
        )
    }

    /// 回归锁：Task D.4 撕裂读修复。`refreshHistoryViews` 曾经跨三次历史
    /// 查询（down/up/totals）反复读取 `selectedRange`，而 `selectRange(_:)`
    /// 会在 MainActor 的挂起点之间改写它——用户在这几次查询之间切换时间
    /// 范围，会让 down/up/totals 拿到不同的 range，导致上下行图表的时间轴
    /// 不一致。
    ///
    /// `MetricHistoryStore` 两次 actor 调用之间的挂起窗口极窄，靠真实调度
    /// 竞争去命中这个窗口不可靠（flaky）；改用
    /// `downloadQueryInterleavedRangeForTesting` 这个 `#if DEBUG` 专供测试的
    /// 注入点：在下行查询完成、上行查询发起之前，确定性地把 `selectedRange`
    /// 改写成 `.hour`，直接复现"查询期间被重入"这个前提条件，不依赖真实的
    /// 调度竞争。
    ///
    /// 断言依据：`MetricHistoryStore.query`/`queryNetworkTransfers` 总是把
    /// 调用时传入的 `range` 参数原样写回结果的 `range` 字段（见
    /// `MetricHistory.swift`），所以 down/up/totals 三个结果的 `range` 是否
    /// 一致，直接反映这几次查询是否用了同一个 range 参数——如果实现坏了
    /// （退回成重复读 `selectedRange`）：down 在改写前完成查询，
    /// `range == .minute`；up/totals 在改写后发起查询，`range == .hour`；
    /// 断言三者相等会失败，测试变红。修复后（锁定一次局部变量）三者应
    /// 始终等于进入函数时的 `.minute`，不受期间改写影响。
    ///
    /// **覆盖范围的诚实说明（复核后补充）**：`refreshHistoryViews` 一共有
    /// 4 处读 `selectedRange` 的点——down/up/totals 三次查询，加上
    /// `if range == .minute` 这个分支条件。这个测试**只覆盖 down/up/totals
    /// 三个查询点，不覆盖分支条件本身**。原因：这个方向下（锁定
    /// `.minute`、撕裂到 `.hour`），无论分支条件读到锁定值 `.minute`（走
    /// if，`downRecentHistory = down`，down 本身是 `.minute`）还是撕裂后的
    /// `selectedRange` 值 `.hour`（走 else，硬编码查询 `.minute`），
    /// `downRecentHistory`/`upRecentHistory` 最终都恰好是 `.minute`——两条
    /// 路径的可观察结果在这个方向下重合，这个测试对分支条件的撕裂是
    /// **盲的**（已用单点变异实测证实：单独把分支条件改回
    /// `if selectedRange == .minute`，只跑这个测试仍然全绿）。分支条件这
    /// 一个点由下面反方向的
    /// `testRefreshHistoryViewsLocksRangeAgainstMidFlightSelectRangeReverseDirection`
    /// 覆盖；4 个读取点各自被哪个测试覆盖、以及为什么 down 点两个方向都
    /// 测不到（不是盲点，是等价变异），完整对照表见 `task-D.4-report.md`。
    @MainActor
    func testRefreshHistoryViewsLocksRangeAgainstMidFlightSelectRange() async {
        let suiteName = "LynxBarTests.NetworkRangeTear.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        settings.showPublicIP = false

        let interface = makeInterface(name: "en0", inBytes: 1_000, outBytes: 1_000)
        // 两条相同的响应：第一条驱动"被观测"的采样周期（含撕裂读探针）；
        // 第二条只是让 sleeper 在探针消费完之后才让循环结束，避免依赖
        // probe 提前耗尽抛错的时序，同时不影响断言——探针只在第一轮消费
        // 一次就清空，第二轮不会再改写 selectedRange。
        let probe = NetworkSnapshotSequenceProbe([
            NetworkProvider.RawCounters(
                totalIn: 1_000,
                totalOut: 1_000,
                interfaces: [interface],
                primaryInterface: interface
            ),
        ])

        let viewModel = NetworkViewModel(
            settings: settings,
            historyStore: MetricHistoryStore(fileURL: nil),
            networkSampler: { await probe.sample() },
            sleeper: { interval in try await probe.sleep(for: interval) }
        )
        viewModel.downloadQueryInterleavedRangeForTesting = .hour

        viewModel.startSampling()
        // 只有 1 条探针响应：`sleeper` 会在第一轮采样完全结束（含
        // refreshHistoryViews 的全部 5 次查询与最终赋值）之后才抛
        // CancellationError，循环随即彻底退出，不会有第二轮覆盖这里要
        // 断言的发布值。用 "up 已经拿到数据" 作为"第一轮已完整发布"的信号，
        // 与文件里另一个测试的写法一致。
        await waitUntil("应该已经完成第一轮采样并发布历史查询结果") {
            !viewModel.upHistoryResult.points.isEmpty
        }
        viewModel.stopSampling()

        XCTAssertEqual(
            viewModel.downHistoryResult.range, .minute,
            "下行查询发生在测试探针改写 selectedRange 之前，应该拿到进入函数时的 range"
        )
        XCTAssertEqual(
            viewModel.upHistoryResult.range, viewModel.downHistoryResult.range,
            "上行查询不应该被期间发生的 selectRange 改写撕裂成另一个 range"
        )
        XCTAssertEqual(
            viewModel.selectedTransferTotals.range, viewModel.downHistoryResult.range,
            "totals 查询同理，必须与 down/up 用同一个锁定的 range"
        )
    }

    /// 反方向场景，补齐上面 `testRefreshHistoryViewsLocksRangeAgainstMidFlightSelectRange`
    /// 测不到的盲点——`if range == .minute` 这个分支条件本身的撕裂。
    ///
    /// 正向测试锁定 `.minute`、撕裂到 `.hour`：无论分支条件读到哪个值，
    /// `downRecentHistory`/`upRecentHistory` 最终都恰好是 `.minute`（if 分支
    /// 复用的 `down`/`up` 本身是 `.minute`，else 分支硬编码查询的也是
    /// `.minute`），两条路径的可观察结果重合，测不出分支条件被撕裂。
    ///
    /// 这里反过来：锁定 `range = .hour`（应该走 else 分支），期间把
    /// `selectedRange` 撕裂改写成 `.minute`。如果分支条件被撕裂读改写成
    /// 重复读 `selectedRange`：撕裂后 `selectedRange == .minute` 为真，会
    /// 误判走 if 分支——把 `downRecentHistory`/`upRecentHistory` 错误地
    /// 赋成 `down`/`up` 的查询结果（`range == .hour`），而不是 else 分支
    /// 应该产出的、硬编码查询的 `.minute`。`.hour` 与 `.minute` 可以区分，
    /// 断言就有了着力点；如果实现是对的（分支条件也用锁定的 `range`），
    /// 应该始终走 else 分支，得到硬编码查询的 `.minute`。
    ///
    /// 初始 range 用真实的 `selectRange(.hour)` 切换，不扩展
    /// `#if DEBUG` 注入点——`selectRange(_:)` 已经是公开 API，足够表达
    /// "测试开始前 selectedRange 已经是 .hour" 这个前置状态，不需要新增
    /// 生产代码。它自身会异步重查询并写 `downHistoryResult`/
    /// `upHistoryResult`/`selectedTransferTotals`（最后一条语句是写
    /// `selectedTransferTotals`），这里先等它落地（poll
    /// `selectedTransferTotals.range == .hour`）再调用 `startSampling()`，
    /// 避免这个独立 Task 与随后第一轮采样对同一批已发布属性的写入产生
    /// 无关的竞态——这与撕裂读本身无关，纯粹是测试时序编排。
    ///
    /// 等待信号用 `upRecentHistory`（而不是像正向测试那样用
    /// `upHistoryResult`）：`upRecentHistory` 是 `refreshHistoryViews`
    /// 里**最后**一条被赋值的属性（无论走 if 还是 else 分支），down/up/
    /// totals/downRecentHistory 全部在它之前完成——等它非空，能确定性地
    /// 保证整个函数（含 else 分支两次额外的 `await`）已经跑完，不会读到
    /// 「down/up/totals 已发布，但 downRecentHistory/upRecentHistory 还在
    /// else 分支的 await 里」这个中间态。
    ///
    /// 断言依据同正向测试：`MetricHistoryStore.query`/`queryNetworkTransfers`
    /// 总是把调用时传入的 `range` 参数原样写回结果的 `range` 字段。
    @MainActor
    func testRefreshHistoryViewsLocksRangeAgainstMidFlightSelectRangeReverseDirection() async {
        let suiteName = "LynxBarTests.NetworkRangeTearReverse.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        settings.showPublicIP = false

        let interface = makeInterface(name: "en0", inBytes: 1_000, outBytes: 1_000)
        let probe = NetworkSnapshotSequenceProbe([
            NetworkProvider.RawCounters(
                totalIn: 1_000,
                totalOut: 1_000,
                interfaces: [interface],
                primaryInterface: interface
            ),
        ])

        let viewModel = NetworkViewModel(
            settings: settings,
            historyStore: MetricHistoryStore(fileURL: nil),
            networkSampler: { await probe.sample() },
            sleeper: { interval in try await probe.sleep(for: interval) }
        )

        viewModel.selectRange(.hour)
        await waitUntil("selectRange(.hour) 的异步重查询应该已经落地，避免与第一轮采样竞态") {
            viewModel.selectedTransferTotals.range == .hour
        }
        viewModel.downloadQueryInterleavedRangeForTesting = .minute

        viewModel.startSampling()
        await waitUntil("应该已经完成第一轮采样并发布全部历史查询结果（含 downRecentHistory/upRecentHistory）") {
            !viewModel.upRecentHistory.points.isEmpty
        }
        viewModel.stopSampling()

        XCTAssertEqual(
            viewModel.downHistoryResult.range, .hour,
            "下行查询发生在测试探针改写 selectedRange 之前，应该拿到进入函数时锁定的 range"
        )
        XCTAssertEqual(
            viewModel.upHistoryResult.range, viewModel.downHistoryResult.range,
            "上行查询不应该被期间发生的 selectRange 改写撕裂成另一个 range"
        )
        XCTAssertEqual(
            viewModel.selectedTransferTotals.range, viewModel.downHistoryResult.range,
            "totals 查询同理，必须与 down/up 用同一个锁定的 range"
        )
        XCTAssertEqual(
            viewModel.downRecentHistory.range, .minute,
            "range 锁定为 .hour 时应该走 else 分支，downRecentHistory 用硬编码的 .minute 查询——" +
                "如果分支条件被撕裂读改写成重复读 selectedRange，会在这里误判走 if 分支，把" +
                "downRecentHistory 错误地赋成 down 的查询结果（range == .hour）"
        )
        XCTAssertEqual(
            viewModel.upRecentHistory.range, .minute,
            "同上，upRecentHistory 同理必须是 else 分支硬编码的 .minute"
        )
    }

    private func makeInterface(
        name: String,
        inBytes: UInt64?,
        outBytes: UInt64?
    ) -> NetworkProvider.Interface {
        NetworkProvider.Interface(
            name: name,
            ipv4: "192.168.1.4",
            ipv6: nil,
            macAddress: nil,
            inBytes: inBytes,
            outBytes: outBytes,
            isPhysical: true,
            isUp: true,
            isRunning: true,
            isPrimary: true
        )
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

/// 按顺序回放预设的 `RawCounters` 序列；序列耗尽后下一次 `sleep` 直接抛
/// `CancellationError`，让采样循环在处理完最后一条之后干净退出。
///
/// 不能像 `ClipboardAndCadenceTests.swift` 的 `DiskSnapshotSequenceProbe` 那样
/// 让序列耗尽后无限重放最后一条：本测试要抓的虚假尖峰只存在于「计数恢复」
/// 那一个精确的 tick——如果循环在测试断言之前又跑了几轮重复的"已恢复"数据，
/// 相邻两次相同的读数会让 delta 自然变回 0，把只存在一个 tick 的 bug 悄悄
/// "自愈"掉，polling 窗口一旦没卡准这个 tick 就测不出来（已实测踩过这个坑）。
private actor NetworkSnapshotSequenceProbe {
    private let responses: [NetworkProvider.RawCounters]
    private var sampleCount = 0

    init(_ responses: [NetworkProvider.RawCounters]) {
        self.responses = responses
    }

    func sample() -> NetworkProvider.RawCounters {
        let response = responses[min(sampleCount, responses.count - 1)]
        sampleCount += 1
        return response
    }

    func sleep(for interval: TimeInterval) async throws {
        if sampleCount >= responses.count {
            throw CancellationError()
        }
    }

    func hasSampled(atLeast count: Int) -> Bool {
        sampleCount >= count
    }
}
