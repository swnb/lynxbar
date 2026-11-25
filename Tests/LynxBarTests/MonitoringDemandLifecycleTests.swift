import XCTest
@testable import LynxBar

@MainActor
final class MonitoringDemandLifecycleTests: XCTestCase {
    private final class Owner: MonitoringDemandOwner {}

    private final class SpyModule: DemandDrivenModule {
        private(set) var startCount = 0
        private(set) var stopCount = 0
        func startSampling() { startCount += 1 }
        func stopSampling() { stopCount += 1 }
    }

    func testCoordinatorDrivesModuleStartAndStopExactlyOnce() {
        let coordinator = MonitoringDemandCoordinator()
        let module = SpyModule()
        coordinator.onDemandChange = { changed, isDemanded in
            guard changed == .gpu else { return }
            isDemanded ? module.startSampling() : module.stopSampling()
        }
        let ownerA = Owner()
        let ownerB = Owner()

        let a = coordinator.acquire(module: .gpu, reason: .panel(.gpu), owner: ownerA)
        let b = coordinator.acquire(module: .gpu, reason: .menuBar, owner: ownerB)
        XCTAssertEqual(module.startCount, 1)
        XCTAssertEqual(module.stopCount, 0)

        a.cancel()
        XCTAssertEqual(module.stopCount, 0, "还有消费者时不得停止")

        b.cancel()
        XCTAssertEqual(module.stopCount, 1)

        _ = coordinator.acquire(module: .gpu, reason: .panel(.gpu), owner: ownerA)
        XCTAssertEqual(module.startCount, 2, "重新被需求必须重新启动")
    }

    func testStoppingDoesNotClearAccumulatedHistory() async {
        let settings = Settings(defaults: isolatedDefaults())
        let store = MetricHistoryStore(fileURL: nil)
        let viewModel = CPUViewModel(settings: settings, historyStore: store)

        viewModel.startSampling()
        // startSampling() 之后若没有 await，MainActor 协作式调度下 spawn 出的采样
        // Task 可能一次都没轮到执行就被下面的 stopSampling() cancel 掉——那样后面
        // 的断言就锁不住「停止不清空」这条不变量，只是在检查一个从没被写过的状态。
        try? await Task.sleep(for: .milliseconds(400))

        let historyBeforeStop = viewModel.historyResult
        let snapshotBeforeStop = viewModel.snapshot
        XCTAssertFalse(
            historyBeforeStop.points.isEmpty,
            "前置条件：必须先发生至少一次真实采样，否则后面「停止后状态不变」的断言没有意义"
        )

        viewModel.stopSampling()

        XCTAssertEqual(
            viewModel.historyResult, historyBeforeStop,
            "停止采样不得清空 ViewModel 自己持有的 historyResult"
        )
        XCTAssertEqual(
            viewModel.snapshot.usage, snapshotBeforeStop.usage,
            "停止采样不得清空 ViewModel 自己持有的 snapshot"
        )

        let history = await store.query(.cpuUsage, range: .minute, now: Date())
        XCTAssertFalse(
            history.points.isEmpty,
            "停止采样不得清空 MetricHistoryStore 里已落盘的历史"
        )
    }

    func testRestartTakesAnImmediateSampleRatherThanWaitingAnInterval() async {
        let settings = Settings(defaults: isolatedDefaults())
        settings.updateInterval = 10
        let store = MetricHistoryStore(fileURL: nil)
        let viewModel = CPUViewModel(settings: settings, historyStore: store)

        viewModel.startSampling()
        // 若实现是「先睡后采」，10 秒间隔下这里一定拿不到点。
        try? await Task.sleep(for: .milliseconds(400))
        viewModel.stopSampling()

        let history = await store.query(.cpuUsage, range: .minute, now: Date())
        XCTAssertFalse(
            history.points.isEmpty,
            "重新被需求后必须立即采样，不能先等一个间隔"
        )
    }

    func testRestartThroughCoordinatorTakesImmediateSampleAndKeepsHistory() async {
        // 上面两个既有测试都只直接调用 viewModel.startSampling()/stopSampling()，
        // 且都只经历「单次 start」或「start 后紧接 stop」，从未真正走一次
        // stop → 经 coordinator 的 onDemandChange 回调重新 acquire → start 的
        // 完整重新需求循环——这正是生产环境（AppDelegate/PanelHost 持 token）
        // 实际触发 start/stop 的方式，不是测试里的直接调用。这里补上这条路径，
        // 同时覆盖 spec "Restart preserves valid history" 的两个子条款：立即
        // 首采样、且不得把已积累的历史用 0 覆盖。
        let settings = Settings(defaults: isolatedDefaults())
        settings.updateInterval = 10
        let store = MetricHistoryStore(fileURL: nil)
        let viewModel = CPUViewModel(settings: settings, historyStore: store)

        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { module, isDemanded in
            guard module == .cpu else { return }
            isDemanded ? viewModel.startSampling() : viewModel.stopSampling()
        }
        let owner = Owner()

        let firstToken = coordinator.acquire(module: .cpu, reason: .panel(.cpu), owner: owner)
        try? await Task.sleep(for: .milliseconds(400))

        let historyBeforeStop = viewModel.historyResult
        XCTAssertFalse(
            historyBeforeStop.points.isEmpty,
            "前置条件：停止前必须已经发生真实采样，否则后面的断言锁不住任何东西"
        )

        firstToken.cancel()

        // 重新需求：经 coordinator 回调触发 restart，而不是直接调用 startSampling()。
        // 10 秒间隔下，如果 restart 没有立即采样，400ms 内不会出现新点。
        let secondToken = coordinator.acquire(module: .cpu, reason: .panel(.cpu), owner: owner)
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertGreaterThan(
            viewModel.historyResult.points.count,
            historyBeforeStop.points.count,
            "经 coordinator 重新需求后必须立即采到新样本，不能等 10 秒间隔"
        )
        XCTAssertEqual(
            Array(viewModel.historyResult.points.prefix(historyBeforeStop.points.count)),
            historyBeforeStop.points,
            "restart 不得丢弃 stop 之前已积累的历史"
        )

        secondToken.cancel()
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "MonitoringDemandLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
