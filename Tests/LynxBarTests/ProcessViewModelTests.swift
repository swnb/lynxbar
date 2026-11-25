import XCTest
@testable import LynxBar

/// `ProcessSamplingTests.swift` 只测纯函数 `ProcessProvider.cpuUsage`/
/// `ProcessIdentity`，无法覆盖 `ProcessViewModel.startSampling()` 里
/// `lastSampledAt` 这个跨帧状态机。这里用依赖注入直接跑采样循环，写法与
/// `NetworkProcessProviderTests.swift` 里
/// `testRestartingAttributionAfterLongGapDoesNotProduceDilutedFirstFrameRate`
/// 保持一致（同一类问题：demand 重启后，旧的时间锚点不能跨越停机间隔当分母）。
@MainActor
final class ProcessViewModelTests: XCTestCase {
    /// 回归锁：长命进程在面板关闭期间没有退出（pid/startTime 不变，B.3 的
    /// 身份修复不会让它变成“陌生进程”），面板重开后第一帧不得用跨越停机
    /// 间隔的 elapsed 当分母算出一个“看起来正常”但被严重稀释的占用——必须
    /// 如实报告未知，第二帧起才恢复真实占用。
    func testRestartAfterLongGapDoesNotProduceDilutedFirstFrameRate() async {
        let suiteName = "LynxBarTests.ProcessRestart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        settings.updateInterval = 1

        let identity = ProcessProvider.ProcessIdentity(pid: 4242, startTime: 1_785_000_000)
        let clock = LockedTestClock(Date(timeIntervalSince1970: 60_000))
        let probe = ProcessRestartProbe(identity: identity, cpuTimeNsFrames: [
            1_000_000_000, // frame 1：首次采样，无基线，必为 nil
            5_000_000_000, // frame 2：正常 1s 间隔，建立真实基线
            5_200_000_000, // restart frame 1：elapsed 必须被强制视为 0
            9_000_000_000, // restart frame 2：正常 1s 间隔，验证恢复真值
        ])

        let viewModel = ProcessViewModel(
            settings: settings,
            sampler: { previous in await probe.sample(previous: previous) },
            sleeper: { interval in
                clock.advance(by: interval)
                try await probe.sleep()
            },
            now: { clock.now() }
        )

        // 阶段一：建立真实基线（2 帧）。sleepLimit 卡在 2，避免继续跑到为
        // “重启”阶段准备的脚本帧。
        await probe.setSleepLimit(2)
        viewModel.startSampling()
        let baselineReached = await eventuallyOnMainActor {
            viewModel.byCpu.first?.cpuUsage != nil
        }
        viewModel.stopSampling()
        XCTAssertTrue(
            baselineReached,
            "前置条件：必须先建立一个真实基线，否则后面「重启后第一帧必须是未知」的断言没有意义"
        )

        // 阶段二：停止后时间跳跃 3 小时（模拟面板关闭很久）。此时没有 Task
        // 在跑，直接推进注入的时钟是安全的，不会有并发读取。
        clock.advance(by: 3 * 60 * 60)

        // 阶段三 + 四：重启，在“restart frame 1”发布之后、“restart frame 2”
        // 覆盖之前原地挂起（`pause`），稳定检查中间状态——不依赖真实时间
        // polling 去赌能不能抢在下一帧覆盖之前查到只存在一帧的状态。
        await probe.setSleepLimit(2)
        await probe.pause(atSleepCount: 1)
        viewModel.startSampling()
        let restartFrameOneIsUnknown = await eventuallyOnMainActor {
            viewModel.byCpu.first?.cpuUsage == nil
        }
        XCTAssertTrue(
            restartFrameOneIsUnknown,
            "等到超时，重启后第一帧的 cpuUsage 一直不是 nil——elapsed 很可能没有被清零，" +
                "跨停机间隔的旧时间锚点仍在被当作分母"
        )
        XCTAssertNil(
            viewModel.byCpu.first?.cpuUsage,
            "重启后第一帧不得用跨越停机间隔的 elapsed 算出一个「看起来正常」的占用，必须是未知"
        )

        await probe.resume()
        let recovered = await eventuallyOnMainActor {
            viewModel.byCpu.first?.cpuUsage != nil
        }
        viewModel.stopSampling()
        XCTAssertTrue(recovered, "重启后第二帧应该恢复出真实占用，而不是一直卡在未知")
    }

    /// 回归锁（相反方向）：`.process` 同时挂在 `.overview`/`.cpu`/`.memory`
    /// 三个 section 上，`PanelHost.acquireSectionTokens(for:)` 在切换 section
    /// 时于同一个 runloop turn 内同步释放再重新获取全部 token——这种
    /// stop/start 只有毫秒级间隔。如果 `startSampling()` 无条件丢弃
    /// `lastSampledAt`（本任务上一版实现），整个进程列表会在每次切换
    /// section（App 最常见的交互）时空白成「—」一整个采样周期，这是审查
    /// 发现的真实回归。
    func testRestartAfterShortGapStillProducesRealFirstFrameRate() async {
        let suiteName = "LynxBarTests.ProcessShortRestart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        settings.updateInterval = 1 // liveInterval(1) == 1，陈旧阈值 = 3 秒

        let identity = ProcessProvider.ProcessIdentity(pid: 4242, startTime: 1_785_000_000)
        let clock = LockedTestClock(Date(timeIntervalSince1970: 90_000))
        let probe = ProcessRestartProbe(identity: identity, cpuTimeNsFrames: [
            1_000_000_000, // frame 1：首次采样，无基线，必为 nil
            5_000_000_000, // frame 2：正常 1s 间隔，建立真实基线
            5_100_000_000, // restart frame 1（毫秒级间隔重启）：应立刻恢复真值
        ])

        let viewModel = ProcessViewModel(
            settings: settings,
            sampler: { previous in await probe.sample(previous: previous) },
            sleeper: { interval in
                clock.advance(by: interval)
                try await probe.sleep()
            },
            now: { clock.now() }
        )

        // 阶段一：建立真实基线（2 帧）。
        await probe.setSleepLimit(2)
        viewModel.startSampling()
        let baselineReached = await eventuallyOnMainActor {
            viewModel.byCpu.first?.cpuUsage != nil
        }
        viewModel.stopSampling()
        XCTAssertTrue(
            baselineReached,
            "前置条件：必须先建立一个真实基线，否则后面「短间隔重启后第一帧应该恢复真值」的断言没有意义"
        )

        // 阶段二：停止后只推进 50ms（模拟 section 切换那种同一个 runloop
        // turn 内的 stop/start），远低于陈旧阈值（3 秒）。
        clock.advance(by: 0.05)

        // 阶段三：重启，只放一帧的 sleepLimit。注意：不能像上面那样直接轮询
        // `byCpu.first?.cpuUsage != nil` 来判断“这一帧恢复了真值”——阶段一
        // 遗留的 byCpu 本来就是非 nil（`stopSampling()` 不清空），如果直接
        // 轮询“非 nil”，测试在 restart frame 1 真正发布之前就会立刻通过，
        // 测不出任何东西（曾经踩过这个坑：写成 `!= nil` 时，即使把下面的
        // 陈旧判断整个删掉、退回无条件重置，这条断言依然「通过」，因为它
        // 从头到尾检查的都是阶段一的旧值）。改用探针自己的调用计数——它与
        // ViewModel 是否发布了新一帧的因果顺序确定（`byCpu` 的赋值发生在
        // `sleeper` 被调用之前，见 `startSampling()` 循环体），不依赖对
        // `byCpu` 具体取值的巧合式解读。
        await probe.setSleepLimit(1)
        viewModel.startSampling()
        let restartFrameOnePublished = await eventuallyOnMainActor {
            await probe.currentSleepCount() >= 1
        }
        viewModel.stopSampling()
        XCTAssertTrue(
            restartFrameOnePublished,
            "重启后第一帧应该已经发布（探针没有等到 sleep() 被调用，说明循环卡住或从未采样）"
        )
        XCTAssertNotNil(
            viewModel.byCpu.first?.cpuUsage,
            "短间隔（section 切换级别）重启后第一帧应该立刻产出真实占用；如果锚点被无条件" +
                "丢弃，这一帧会是未知——那会让整个进程列表在每次切换 section 时空白一个采样周期"
        )
    }

    /// Task D.1 核心承诺的回归锁：两个榜单最终只展示 Top N，显示名解析
    /// （`NSRunningApplication`）必须只发生在排序 + 截断之后。这里构造
    /// 30 个存活进程（远大于 topN=5），每个 identity 互不相同（缓存全冷），
    /// 用记录调用次数的 resolver 顶替真实 LaunchServices 查询。
    ///
    /// 如果有人把解析挪回全量 map 里（先对 `result.raw` 逐个解析名字、再排序
    /// 截断——这正是本任务要修的旧写法），resolveCount 会变成 30；只要解析
    /// 真的发生在排序 + 截断之后，无论两个榜单具体选中哪些进程（byCpu 在
    /// cpuUsage 全为 nil 时的具体排序结果依赖 Swift 排序实现，不保证稳定），
    /// 解析次数都不会超过两个榜单 Top N 之和。
    func testResolvesNamesOnlyForTopNAcrossBothRankings() async {
        let suiteName = "LynxBarTests.ProcessNameResolutionBound.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        settings.updateInterval = 1
        settings.processTopN = 5

        let totalProcesses = 30
        var builtRaws: [ProcessProvider.RawProcess] = []
        builtRaws.reserveCapacity(totalProcesses)
        for index in 0..<totalProcesses {
            let pid = Int32(1_000 + index)
            let startTime = UInt64(5_000 + index)
            let memoryBytes = UInt64(totalProcesses - index) * 1_024
            builtRaws.append(
                ProcessProvider.RawProcess(
                    identity: ProcessProvider.ProcessIdentity(
                        pid: pid,
                        startTime: startTime
                    ),
                    name: "proc\(index)",
                    cpuTimeNs: UInt64(index),
                    prevCpuTimeNs: nil,
                    memoryBytes: memoryBytes
                )
            )
        }
        let raws = builtRaws

        var resolveCount = 0
        let nameCache = ProcessDisplayNameCache(resolve: { _ in
            resolveCount += 1
            return nil
        })

        let viewModel = ProcessViewModel(
            settings: settings,
            sampler: { _ in (raw: raws, cpuTimes: [:]) },
            sleeper: { _ in throw ProcessRestartProbeStop.finished },
            nameCache: nameCache
        )

        viewModel.startSampling()
        let published = await eventuallyOnMainActor {
            viewModel.byCpu.count == 5 && viewModel.byMemory.count == 5
        }
        viewModel.stopSampling()

        XCTAssertTrue(published, "前置条件：两个榜单都应该发布出 Top N 条记录，否则下面的断言没有意义")
        XCTAssertGreaterThan(resolveCount, 0, "至少应该解析到一些名字，否则下面的上界断言是空判断")
        XCTAssertLessThanOrEqual(
            resolveCount,
            2 * settings.processTopN,
            "一轮采样最多只应该解析两个榜单各自 Top N 的名字（至多 \(2 * settings.processTopN) 次），" +
                "不能对全部 \(totalProcesses) 个存活进程都解析——这正是「解析挪回全量 map」的回退"
        )
    }

    /// Task D.2 核心承诺的回归锁：`ProcessIconCache` 按 `ProcessIdentity`
    /// 缓存图标，前提是 `ProcessViewModel` 发布的 `DisplayProcess` 真的带着
    /// 完整 identity——包括经过 `resolveTopN`/`replacingName` 改名之后的
    /// 最终发布值（View 渲染的是 `byCpu`/`byMemory`，不是中间态的
    /// `displays`）。如果 identity 在这条链路的任何一步被漏传（比如
    /// `replacingName` 重新构造 `DisplayProcess` 时忘记带上 identity），
    /// 图标缓存会静默退化回每次重新解析 identity 的裸 pid 入口——不是错误，
    /// 但会悄悄丢掉这次任务要做的优化，且没有其他测试会发现。这里直接断言
    /// 最终发布值的 identity 字段。
    func testPublishedProcessesCarryFullIdentityForIconCaching() async {
        let suiteName = "LynxBarTests.ProcessIconIdentity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        settings.updateInterval = 1
        settings.processTopN = 5

        let identity = ProcessProvider.ProcessIdentity(pid: 4242, startTime: 1_785_000_000)
        let raw = ProcessProvider.RawProcess(
            identity: identity,
            name: "probe",
            cpuTimeNs: 1_000,
            prevCpuTimeNs: nil,
            memoryBytes: 2_048
        )

        let viewModel = ProcessViewModel(
            settings: settings,
            sampler: { _ in (raw: [raw], cpuTimes: [:]) },
            sleeper: { _ in throw ProcessRestartProbeStop.finished }
        )

        viewModel.startSampling()
        let published = await eventuallyOnMainActor {
            !viewModel.byCpu.isEmpty && !viewModel.byMemory.isEmpty
        }
        viewModel.stopSampling()

        XCTAssertTrue(published, "前置条件：两个榜单都应该发布出结果，否则下面的断言没有意义")
        XCTAssertEqual(
            viewModel.byCpu.first?.identity, identity,
            "byCpu 发布的进程必须带着完整 identity，供图标缓存按身份查询"
        )
        XCTAssertEqual(
            viewModel.byMemory.first?.identity, identity,
            "byMemory 发布的进程必须带着完整 identity，供图标缓存按身份查询"
        )
    }

    /// `predicate` 是 `async`（而不是 `NetworkProcessProviderTests.swift`
    /// 里那个同步版本），因为这里有的调用点需要 `await probe.xxx()` 才能
    /// 拿到判断依据（见 `testRestartAfterShortGapStillProducesRealFirstFrameRate`
    /// 的注释）；纯同步闭包依然可以照常传进来，不需要改调用点。
    private func eventuallyOnMainActor(
        timeout: Duration = .seconds(2),
        predicate: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }
}

/// 按顺序回放脚本化的绝对 CPU 时间读数（纳秒）。`previous` 由调用方
/// （`ProcessViewModel` 自己的 `cpuTimes`）传入，与真实 `ProcessProvider.sample`
/// 的职责划分保持一致：探针只负责提供“这一帧的绝对计数器读数”，
/// 差值/未知判断仍然走 `ProcessViewModel`/`ProcessProvider.cpuUsage` 的生产代码路径。
private actor ProcessRestartProbe {
    private let identity: ProcessProvider.ProcessIdentity
    private let cpuTimeNsFrames: [UInt64]
    private var sampleCount = 0
    private var sleeps = 0
    private var sleepLimit = Int.max
    private var pauseAtSleep: Int?

    init(identity: ProcessProvider.ProcessIdentity, cpuTimeNsFrames: [UInt64]) {
        self.identity = identity
        self.cpuTimeNsFrames = cpuTimeNsFrames
    }

    /// 第几次 `sleep()` 调用后终止采样循环（模拟 `stopSampling()` 之前
    /// 只让循环走够需要的帧数，不多跑，不少跑）。每次调用都会把 `sleeps`
    /// 计数重置为 0——与 `NetworkProcessProviderTests.swift` 里
    /// `RestartableAttributionProbe.setSleepLimit` 的语义一致。
    func setSleepLimit(_ limit: Int) {
        sleepLimit = limit
        sleeps = 0
    }

    /// 自 `setSleepLimit` 起累计的 `sleep()` 调用次数。`sleep()` 总是在
    /// `ProcessViewModel` 发布完这一帧的 `byCpu`/`byMemory` 之后才被调用，
    /// 所以「这个数到了 N」是「第 N 帧已经发布」的充要信号，可以用来在不
    /// 依赖 `byCpu` 具体取值的前提下判断某一帧是否已经跑到。
    func currentSleepCount() -> Int {
        sleeps
    }

    /// 在第 `count` 次 `sleep()` 调用处原地挂起，直到测试调用 `resume()`。
    /// 用于在同一次连续采样循环内部，稳定卡住某一帧发布之后、下一帧覆盖
    /// 之前的窗口——不依赖真实时间 polling 去赌有没有抢在下一帧覆盖之前
    /// 查到只存在一帧的状态（`Task.yield()` 是挂起点，actor 重入让
    /// `resume()` 能在这段时间插进来修改 `pauseAtSleep`）。
    func pause(atSleepCount count: Int) {
        pauseAtSleep = count
    }

    func resume() {
        pauseAtSleep = nil
    }

    func sample(
        previous: [ProcessProvider.ProcessIdentity: UInt64]
    ) -> (raw: [ProcessProvider.RawProcess], cpuTimes: [ProcessProvider.ProcessIdentity: UInt64]) {
        let current = cpuTimeNsFrames[min(sampleCount, cpuTimeNsFrames.count - 1)]
        sampleCount += 1
        let raw = ProcessProvider.RawProcess(
            identity: identity,
            name: "probe",
            cpuTimeNs: current,
            prevCpuTimeNs: previous[identity],
            memoryBytes: 1_024
        )
        return (raw: [raw], cpuTimes: [identity: current])
    }

    func sleep() async throws {
        sleeps += 1
        while pauseAtSleep == sleeps {
            await Task.yield()
        }
        if sleeps >= sleepLimit { throw ProcessRestartProbeStop.finished }
    }
}

private enum ProcessRestartProbeStop: Error {
    case finished
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}
