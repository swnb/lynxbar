import Foundation
import XCTest
@testable import LynxBar

final class NetworkProcessProviderTests: XCTestCase {
    func testParsesNettopCSVIncludingQuotedProcessName() throws {
        let csv = """
        ,bytes_in,bytes_out,
        Safari.101,1024,512,
        "Browser, ""Preview"".202",4096,2048,
        malformed,5,6,
        """

        let counters = try XCTUnwrap(NetworkProcessProvider.parseCSV(csv))

        XCTAssertEqual(
            counters,
            [
                .init(pid: 101, processName: "Safari", receivedBytes: 1_024, sentBytes: 512),
                .init(
                    pid: 202,
                    processName: "Browser, \"Preview\"",
                    receivedBytes: 4_096,
                    sentBytes: 2_048
                ),
            ]
        )
    }

    func testRejectsMissingColumnsAndRowsWithoutValidIdentity() {
        XCTAssertNil(NetworkProcessProvider.parseCSV(",rx,tx,\nSafari.1,1,2,\n"))
        XCTAssertNil(
            NetworkProcessProvider.parseCSV(
                ",bytes_in,bytes_out,\nmissing-pid,1,2,\n"
            )
        )
    }

    func testRatesUseElapsedTimeFilterZeroAndSortByCombinedRate() {
        let previous = NetworkProcessProvider.countersByPID([
            .init(pid: 1, processName: "Alpha", receivedBytes: 100, sentBytes: 100),
            .init(pid: 2, processName: "Beta", receivedBytes: 200, sentBytes: 300),
            .init(pid: 3, processName: "Idle", receivedBytes: 10, sentBytes: 10),
        ])
        let current: [NetworkProcessProvider.Counter] = [
            .init(pid: 1, processName: "Alpha", receivedBytes: 300, sentBytes: 200),
            .init(pid: 2, processName: "Beta", receivedBytes: 300, sentBytes: 700),
            .init(pid: 3, processName: "Idle", receivedBytes: 10, sentBytes: 10),
        ]

        let rates = NetworkProcessProvider.rates(
            current: current,
            previous: previous,
            elapsed: 2
        )

        XCTAssertEqual(rates.map(\.pid), [2, 1])
        XCTAssertEqual(rates[0].downloadBytesPerSecond, 50)
        XCTAssertEqual(rates[0].uploadBytesPerSecond, 200)
        XCTAssertEqual(rates[1].downloadBytesPerSecond, 100)
        XCTAssertEqual(rates[1].uploadBytesPerSecond, 50)
    }

    func testFirstBaselinePIDReuseAndRollbackDoNotCreateSpikes() {
        let previous = NetworkProcessProvider.countersByPID([
            .init(pid: 7, processName: "Old", receivedBytes: 9_000, sentBytes: 9_000),
            .init(pid: 8, processName: "Reset", receivedBytes: 5_000, sentBytes: 5_000),
        ])
        let current: [NetworkProcessProvider.Counter] = [
            .init(pid: 7, processName: "New", receivedBytes: 10, sentBytes: 20),
            .init(pid: 8, processName: "Reset", receivedBytes: 4_000, sentBytes: 5_100),
            .init(pid: 9, processName: "First", receivedBytes: 100, sentBytes: 200),
        ]

        let rates = NetworkProcessProvider.rates(
            current: current,
            previous: previous,
            elapsed: 1
        )

        XCTAssertEqual(rates.count, 1)
        XCTAssertEqual(rates[0].pid, 8)
        XCTAssertEqual(rates[0].downloadBytesPerSecond, 0)
        XCTAssertEqual(rates[0].uploadBytesPerSecond, 100)
    }

    func testTrackerThrottlesPreventsOverlapAndRecoversFromFailure() {
        let origin = Date(timeIntervalSince1970: 10_000)
        var tracker = NetworkProcessAttributionTracker()

        XCTAssertTrue(tracker.beginAttempt(at: origin, minimumInterval: 3))
        XCTAssertFalse(
            tracker.beginAttempt(
                at: origin.addingTimeInterval(3),
                minimumInterval: 3
            )
        )

        tracker.finish(
            .success([
                .init(pid: 42, processName: "Browser", receivedBytes: 100, sentBytes: 100),
            ]),
            at: origin
        )
        XCTAssertEqual(tracker.availability, .collecting)
        XCTAssertFalse(
            tracker.beginAttempt(
                at: origin.addingTimeInterval(2.99),
                minimumInterval: 3
            )
        )
        XCTAssertTrue(
            tracker.beginAttempt(
                at: origin.addingTimeInterval(3),
                minimumInterval: 3
            )
        )
        tracker.finish(.unavailable, at: origin.addingTimeInterval(3))
        XCTAssertEqual(tracker.availability, .unavailable)

        XCTAssertTrue(
            tracker.beginAttempt(
                at: origin.addingTimeInterval(6),
                minimumInterval: 3
            )
        )
        tracker.finish(
            .success([
                .init(pid: 42, processName: "Browser", receivedBytes: 700, sentBytes: 400),
            ]),
            at: origin.addingTimeInterval(6)
        )

        XCTAssertEqual(tracker.availability, .ready)
        XCTAssertEqual(tracker.usages.count, 1)
        // 失败不替换成功基线，因此 600 B / 300 B 按六秒真实间隔计算。
        XCTAssertEqual(tracker.usages[0].downloadBytesPerSecond, 100)
        XCTAssertEqual(tracker.usages[0].uploadBytesPerSecond, 50)
    }

    func testTrackerReadyStateCanRepresentIdleTraffic() {
        let origin = Date(timeIntervalSince1970: 20_000)
        let counter = NetworkProcessProvider.Counter(
            pid: 9,
            processName: "Idle",
            receivedBytes: 100,
            sentBytes: 100
        )
        var tracker = NetworkProcessAttributionTracker()

        XCTAssertTrue(tracker.beginAttempt(at: origin, minimumInterval: 3))
        tracker.finish(.success([counter]), at: origin)
        XCTAssertTrue(
            tracker.beginAttempt(
                at: origin.addingTimeInterval(3),
                minimumInterval: 3
            )
        )
        tracker.finish(.success([counter]), at: origin.addingTimeInterval(3))

        XCTAssertEqual(tracker.availability, .ready)
        XCTAssertTrue(tracker.usages.isEmpty)
    }

    @MainActor
    func testNetworkViewModelThrottlesAttributionAndKeepsAggregateHistoryIndependent() async {
        let suiteName = "LynxBarTests.NetworkProcess.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        settings.updateInterval = 1
        settings.showPublicIP = false

        let clock = LockedTestClock(Date(timeIntervalSince1970: 30_000))
        let probe = NetworkAttributionProbe()
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lynxbar-network-process-\(UUID().uuidString).json")
        let viewModel = NetworkViewModel(
            settings: settings,
            historyStore: MetricHistoryStore(fileURL: historyURL),
            networkSampler: { await probe.sampleNetwork() },
            processSampler: { await probe.sampleProcesses() },
            sleeper: { interval in
                clock.advance(by: interval)
                try await probe.sleep()
            },
            now: { clock.now() }
        )

        viewModel.startSampling()
        viewModel.startAttribution()
        let reachedReady = await eventuallyOnMainActor {
            viewModel.processAttributionAvailability == .ready
        }
        viewModel.stopSampling()
        let processSampleCount = await probe.processSampleCount()
        let networkSampleCount = await probe.networkSampleCount()

        XCTAssertTrue(reachedReady)
        XCTAssertEqual(processSampleCount, 2)
        XCTAssertGreaterThanOrEqual(networkSampleCount, 4)
        XCTAssertEqual(viewModel.processTraffic.map(\.pid), [42])
        XCTAssertEqual(viewModel.processTraffic[0].downloadBytesPerSecond, 100)
        XCTAssertEqual(viewModel.processTraffic[0].uploadBytesPerSecond, 50)
        XCTAssertFalse(viewModel.downHistoryResult.points.isEmpty)
        XCTAssertFalse(viewModel.upHistoryResult.points.isEmpty)
    }

    /// Task D.1 的第二个调用点：`publishProcessAttribution()` 同样只应该
    /// 对 Top N 解析显示名。这里让 nettop 探针报出 30 个流量互不相同的 pid
    /// （远大于 topN=5），注入记录调用次数的 `resolve`/`identityResolver`。
    ///
    /// `usages` 由 `NetworkProcessProvider.rates()` 按流量降序排好，30 个 pid
    /// 的流量各不相同（`150 + 2*index` 的等差数列），所以 Top 5 是确定的一组。
    /// 如果有人把解析挪回全量 map 里（`usages.map { 解析 }.prefix(topN)`，
    /// 本任务修复之前的写法），resolveCount 会变成 30；只要真的先
    /// `prefix(topN)` 再解析，resolveCount 不会超过 5。
    @MainActor
    func testPublishProcessAttributionOnlyResolvesNamesForTopN() async {
        let suiteName = "LynxBarTests.NetworkAttributionTopN.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        settings.updateInterval = 1
        settings.showPublicIP = false
        settings.processTopN = 5

        let clock = LockedTestClock(Date(timeIntervalSince1970: 50_000))
        let probe = ManyProcessAttributionProbe(pidCount: 30)
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lynxbar-network-topn-\(UUID().uuidString).json")

        var resolveCount = 0
        let nameCache = ProcessDisplayNameCache(
            resolve: { _ in
                resolveCount += 1
                return nil
            },
            identityResolver: { pid in
                ProcessProvider.ProcessIdentity(pid: pid, startTime: UInt64(pid))
            }
        )

        let viewModel = NetworkViewModel(
            settings: settings,
            historyStore: MetricHistoryStore(fileURL: historyURL),
            networkSampler: { await probe.sampleNetwork() },
            processSampler: { await probe.sampleProcesses() },
            sleeper: { interval in
                clock.advance(by: interval)
                try await probe.sleep()
            },
            now: { clock.now() },
            nameCache: nameCache
        )

        viewModel.startSampling()
        viewModel.startAttribution()
        let reachedReady = await eventuallyOnMainActor {
            viewModel.processAttributionAvailability == .ready
        }
        viewModel.stopSampling()

        XCTAssertTrue(reachedReady, "前置条件：必须先采到一次成功的归因快照，否则下面的断言没有意义")
        XCTAssertEqual(viewModel.processTraffic.count, 5)
        XCTAssertGreaterThan(resolveCount, 0, "至少应该解析到一些名字，否则下面的上界断言是空判断")
        XCTAssertLessThanOrEqual(
            resolveCount,
            5,
            "只应该解析 Top N(=5) 个进程的名字，不能对全部 30 个有流量的进程都解析——" +
                "这正是「解析挪回全量 map」的回退"
        )
    }

    /// nettop 是最贵的采样源（每次 fork 一个 `/usr/bin/nettop` 进程）；
    /// networkProcessAttribution 是独立于 network 本身的 demand，因此
    /// `startSampling()`（基础上下行速率）必须能在不触发归因的情况下独立运行——
    /// 否则常驻的 overviewHealth 会让 nettop 在面板关闭时依然每 3 秒 fork 一次。
    @MainActor
    func testNetworkViewModelDoesNotSampleProcessesWithoutAttributionDemand() async {
        let suiteName = "LynxBarTests.NetworkNoAttribution.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        settings.updateInterval = 1
        settings.showPublicIP = false

        let clock = LockedTestClock(Date(timeIntervalSince1970: 31_000))
        let probe = NetworkAttributionProbe()
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lynxbar-network-no-attribution-\(UUID().uuidString).json")
        let viewModel = NetworkViewModel(
            settings: settings,
            historyStore: MetricHistoryStore(fileURL: historyURL),
            networkSampler: { await probe.sampleNetwork() },
            processSampler: { await probe.sampleProcesses() },
            sleeper: { interval in
                clock.advance(by: interval)
                try await probe.sleep()
            },
            now: { clock.now() }
        )

        // 只 acquire .network（overviewHealth 的形态），不 acquire
        // .networkProcessAttribution（只有 Network 面板打开才会 acquire）。
        viewModel.startSampling()
        // probe 在第 5 次 sleep 时抛出错误结束循环；等基础网络采样跑完
        // 几轮，而不是用固定 sleep 赌时序。
        let ranMultipleCycles = await eventuallyOnMainActor {
            !viewModel.downHistoryResult.points.isEmpty
        }
        try? await Task.sleep(for: .milliseconds(200))
        viewModel.stopSampling()

        XCTAssertTrue(ranMultipleCycles)

        let processSampleCount = await probe.processSampleCount()
        let networkSampleCount = await probe.networkSampleCount()

        XCTAssertEqual(
            processSampleCount, 0,
            "没有 .networkProcessAttribution demand 时不得 fork nettop"
        )
        XCTAssertGreaterThan(
            networkSampleCount, 0,
            "基础上下行速率采样不应被 nettop 归因门槛挡住"
        )
        XCTAssertEqual(viewModel.processAttributionAvailability, .collecting)
    }

    /// `NetworkProcessAttributionTracker.finish()` 用
    /// `bytesDelta / (now - lastSuccessAt)` 算速率，分母没有上限。归因现在
    /// 随 `.networkProcessAttribution` demand 独立开关，而 `lastSuccessAt`
    /// 是 tracker 内部状态；如果 `startAttribution()` 不重置 tracker，
    /// 面板关闭很久后重新打开，第一帧会拿停止期间累积的字节数除以停止时长，
    /// 显示一个被严重稀释、但看起来「正常」的速率值——这正好撞上「不知道
    /// 不能显示成具体数值」的项目约定。
    @MainActor
    func testRestartingAttributionAfterLongGapDoesNotProduceDilutedFirstFrameRate() async {
        let suiteName = "LynxBarTests.NetworkAttributionRestart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        settings.updateInterval = 1
        settings.showPublicIP = false

        let clock = LockedTestClock(Date(timeIntervalSince1970: 60_000))
        let probe = RestartableAttributionProbe()
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lynxbar-network-restart-\(UUID().uuidString).json")
        let viewModel = NetworkViewModel(
            settings: settings,
            historyStore: MetricHistoryStore(fileURL: historyURL),
            networkSampler: { await probe.sampleNetwork() },
            processSampler: { await probe.sampleProcesses() },
            sleeper: { interval in
                clock.advance(by: interval)
                try await probe.sleep()
            },
            now: { clock.now() }
        )

        // 阶段一：建立一个真实的 .ready 基线（两次成功采样，elapsed 是
        // 正常的秒级间隔）。
        await probe.setSleepLimit(5)
        viewModel.startSampling()
        viewModel.startAttribution()
        let reachedReady = await eventuallyOnMainActor {
            viewModel.processAttributionAvailability == .ready
        }
        viewModel.stopSampling()
        XCTAssertTrue(
            reachedReady,
            "前置条件：必须先建立一个真实的 .ready 基线，否则后面「重启后第一帧" +
                "不应产出速率」的断言没有意义"
        )
        XCTAssertFalse(viewModel.processTraffic.isEmpty)

        // 阶段二：停止归因，时间跳跃 3 小时（模拟面板关闭很久）。此时
        // viewModel 没有任何 Task 在跑，直接推进注入的时钟是安全的——不会有
        // 并发读取。
        viewModel.stopAttribution()
        clock.advance(by: 3 * 60 * 60)

        // 阶段三：重新 acquire 归因 demand，只需要跑到第一次成功采样。
        // processSamples 计数器不重置（继续累加），这样即使 tracker 没被
        // 重置，probe 也会返回一组比阶段一末次更大的计数器，产出一个真实但
        // 被稀释的非零速率——而不是恰好因为字节数没变而“碰巧”呈现出正确的
        // 空结果，确保断言真的在测「有没有重置」而不是测巧合。
        await probe.setSleepLimit(2)
        viewModel.startSampling()
        viewModel.startAttribution()
        let reachedCollectingAgain = await eventuallyOnMainActor {
            viewModel.processAttributionAvailability == .collecting
        }
        viewModel.stopSampling()

        XCTAssertTrue(
            reachedCollectingAgain,
            "重启归因后的第一帧必须是 .collecting，而不是用 3 小时做分母" +
                "算出来的「看起来正常」的速率"
        )
        XCTAssertEqual(
            viewModel.processAttributionAvailability, .collecting,
            "tracker 没有被重置：重启后第一帧不应该有 lastSuccessAt"
        )
        XCTAssertTrue(
            viewModel.processTraffic.isEmpty,
            "重启后第一帧不得产出任何速率数值（哪怕数值很小），因为分母是" +
                "被人为拉长的停止时长，不是真实的采样间隔"
        )
    }

    @MainActor
    func testNetworkViewModelPublishesRealCadenceTotalsAndRangeSelection() async {
        let suiteName = "LynxBarTests.NetworkTotals.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        settings.updateInterval = 2
        settings.showPublicIP = false

        let clock = LockedTestClock(Date(timeIntervalSince1970: 40_000))
        let probe = NetworkTotalsProbe()
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lynxbar-network-totals-\(UUID().uuidString).json")
        let viewModel = NetworkViewModel(
            settings: settings,
            historyStore: MetricHistoryStore(fileURL: historyURL),
            networkSampler: { await probe.sampleNetwork() },
            processSampler: { .unavailable },
            sleeper: { interval in
                clock.advance(by: interval)
                try await probe.sleep()
            },
            now: { clock.now() }
        )

        viewModel.startSampling()
        let receivedThreeSamples = await eventuallyOnMainActor {
            viewModel.selectedTransferTotals.downloadBytes == 500
                && viewModel.selectedTransferTotals.uploadBytes == 200
        }
        viewModel.stopSampling()

        XCTAssertTrue(receivedThreeSamples)
        XCTAssertEqual(viewModel.snapshot.downloadBytesPerSecond, 100)
        XCTAssertEqual(viewModel.snapshot.uploadBytesPerSecond, 50)
        XCTAssertEqual(
            viewModel.selectedTransferTotals.downloadCoveredDuration,
            4,
            accuracy: 0.001
        )
        XCTAssertEqual(viewModel.selectedTransferTotals.status, .partial)

        viewModel.selectRange(.hour)
        let selectedHour = await eventuallyOnMainActor {
            viewModel.selectedTransferTotals.range == .hour
                && viewModel.selectedTransferTotals.downloadBytes == 500
        }

        XCTAssertTrue(selectedHour)
        XCTAssertEqual(viewModel.selectedRange, .hour)
        XCTAssertEqual(viewModel.selectedTransferTotals.uploadBytes, 200)
    }
}

private enum NetworkAttributionProbeStop: Error {
    case finished
}

private actor NetworkAttributionProbe {
    private var networkSamples = 0
    private var processSamples = 0
    private var sleeps = 0

    func sampleNetwork() -> NetworkProvider.RawCounters {
        networkSamples += 1
        return NetworkProvider.RawCounters()
    }

    func sampleProcesses() -> NetworkProcessProvider.Snapshot {
        processSamples += 1
        let multiplier = UInt64(processSamples)
        return .success([
            .init(
                pid: 42,
                processName: "Browser",
                receivedBytes: 100 + ((multiplier - 1) * 300),
                sentBytes: 100 + ((multiplier - 1) * 150)
            ),
        ])
    }

    func sleep() async throws {
        sleeps += 1
        if sleeps >= 5 { throw NetworkAttributionProbeStop.finished }
        await Task.yield()
    }

    func networkSampleCount() -> Int { networkSamples }
    func processSampleCount() -> Int { processSamples }
}

/// 与 `NetworkAttributionProbe` 的区别：报出 `pidCount` 个互不相同、流量
/// 各不相同的 pid（而不是固定的单个 pid 42），用来验证
/// `publishProcessAttribution()` 是否真的只对 Top N 解析显示名。
private actor ManyProcessAttributionProbe {
    private let pidCount: Int
    private var networkSamples = 0
    private var processSamples = 0
    private var sleeps = 0

    init(pidCount: Int) {
        self.pidCount = pidCount
    }

    func sampleNetwork() -> NetworkProvider.RawCounters {
        networkSamples += 1
        return NetworkProvider.RawCounters()
    }

    func sampleProcesses() -> NetworkProcessProvider.Snapshot {
        processSamples += 1
        let multiplier = UInt64(processSamples)
        let counters = (0..<pidCount).map { index in
            NetworkProcessProvider.Counter(
                pid: Int32(20_000 + index),
                processName: "Proc\(index)",
                receivedBytes: (100 + UInt64(index)) * multiplier,
                sentBytes: (50 + UInt64(index)) * multiplier
            )
        }
        return .success(counters)
    }

    func sleep() async throws {
        sleeps += 1
        if sleeps >= 5 { throw NetworkAttributionProbeStop.finished }
        await Task.yield()
    }
}

/// 与 `NetworkAttributionProbe` 的区别：sleep 上限可以按阶段重新设置
/// （`setSleepLimit`），用来在同一个测试里跑「跑几轮 → 停 → 跳时间 →
/// 再跑几轮」这种分阶段场景，而不是像 `NetworkAttributionProbe` 那样
/// 一次性跑到底。`processSamples` 跨阶段持续累加、返回递增的字节计数器，
/// 确保就算 tracker 没被重置，第二阶段也会产出一个真实但被稀释的非零速率
/// （而不是恰好因为字节数没变而“碰巧”正确）。
private actor RestartableAttributionProbe {
    private var networkSamples = 0
    private var processSamples = 0
    private var sleeps = 0
    private var sleepLimit = Int.max

    func setSleepLimit(_ limit: Int) {
        sleepLimit = limit
        sleeps = 0
    }

    func sampleNetwork() -> NetworkProvider.RawCounters {
        networkSamples += 1
        return NetworkProvider.RawCounters()
    }

    func sampleProcesses() -> NetworkProcessProvider.Snapshot {
        processSamples += 1
        let multiplier = UInt64(processSamples)
        return .success([
            .init(
                pid: 77,
                processName: "Browser",
                receivedBytes: 1_000 * multiplier,
                sentBytes: 500 * multiplier
            ),
        ])
    }

    func sleep() async throws {
        sleeps += 1
        if sleeps >= sleepLimit { throw NetworkAttributionProbeStop.finished }
        await Task.yield()
    }
}

private actor NetworkTotalsProbe {
    private var index = 0
    private var sleeps = 0

    func sampleNetwork() -> NetworkProvider.RawCounters {
        let samples: [(UInt64, UInt64)] = [
            (1_000, 600),
            (1_300, 700),
            (1_500, 800),
        ]
        let sample = samples[min(index, samples.count - 1)]
        index += 1
        let interface = NetworkProvider.Interface(
            name: "en0",
            ipv4: "192.168.1.2",
            ipv6: nil,
            macAddress: nil,
            inBytes: sample.0,
            outBytes: sample.1,
            isPhysical: true,
            isUp: true,
            isRunning: true,
            isPrimary: true
        )
        return NetworkProvider.RawCounters(
            totalIn: sample.0,
            totalOut: sample.1,
            interfaces: [interface],
            primaryInterface: interface
        )
    }

    func sleep() async throws {
        sleeps += 1
        if sleeps >= 3 { throw NetworkAttributionProbeStop.finished }
        await Task.yield()
    }
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

@MainActor
private func eventuallyOnMainActor(
    timeout: Duration = .seconds(2),
    predicate: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}
