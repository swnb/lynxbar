import XCTest
@testable import LynxBar

/// tasks.md 4.6 要求的 demand 探针测试：panel + menu bar 共享、view 重建、
/// token 释放、低频 Disk 不提速；外加 4.8 在当前代码范围内的等价证明
/// （GPU / Battery / Process / networkProcessAttribution 无消费者时无 demand）。
@MainActor
final class MonitoringDemandProbeTests: XCTestCase {
    private final class Owner: MonitoringDemandOwner {}

    func testPanelAndMenuBarShareOneSamplerLoop() {
        var starts: [MonitoringModule] = []
        var stops: [MonitoringModule] = []
        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { module, isDemanded in
            isDemanded ? starts.append(module) : stops.append(module)
        }
        let panel = Owner()
        let menuBar = Owner()

        let menuBarToken = coordinator.acquire(module: .cpu, reason: .menuBar, owner: menuBar)
        let panelToken = coordinator.acquire(module: .cpu, reason: .panel(.cpu), owner: panel)

        XCTAssertEqual(starts, [.cpu], "CPU 已被菜单栏需求时，打开面板不得启动第二个 loop")

        panelToken.cancel()
        XCTAssertEqual(stops, [], "关闭面板后菜单栏仍需要 CPU，不得停止")

        menuBarToken.cancel()
        XCTAssertEqual(stops, [.cpu])
    }

    func testRepeatedSectionReportDoesNotAccumulateDemand() {
        let coordinator = MonitoringDemandCoordinator()
        let host = Owner()

        // 模拟 SwiftUI 为同一可见 section 反复重建 view 并重复上报。
        var tokens: [DemandToken] = []
        for _ in 0..<20 {
            for module in MonitoringDemandBinding.modules(for: .network) {
                tokens.append(
                    coordinator.acquire(module: module, reason: .panel(.network), owner: host)
                )
            }
        }

        XCTAssertEqual(coordinator.demandCount(for: .network), 1)
        XCTAssertEqual(coordinator.demandCount(for: .networkProcessAttribution), 1)
        withExtendedLifetime(tokens) {}
    }

    func testReleasingPanelTokenStopsOnlyUnsharedModules() {
        var stops: [MonitoringModule] = []
        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { module, isDemanded in
            if !isDemanded { stops.append(module) }
        }
        let health = Owner()
        let panel = Owner()

        // 常驻健康 demand。
        var healthTokens: [DemandToken] = []
        for module in MonitoringDemandBinding.overviewHealthModules {
            healthTokens.append(
                coordinator.acquire(module: module, reason: .overviewHealth, owner: health)
            )
        }
        // 打开 Network 面板。
        var panelTokens: [DemandToken] = []
        for module in MonitoringDemandBinding.modules(for: .network) {
            panelTokens.append(
                coordinator.acquire(module: module, reason: .panel(.network), owner: panel)
            )
        }

        panelTokens.forEach { $0.cancel() }

        XCTAssertEqual(
            stops, [.networkProcessAttribution],
            "关闭 Network 面板应只停 nettop 归因；network 本身仍被 overviewHealth 需求"
        )
        withExtendedLifetime(healthTokens) {}
    }

    func testMultipleConsumersDoNotAccelerateDiskCadence() async {
        let settings = Settings(defaults: isolatedDefaults())
        settings.diskCapacityCadence = .oneHour
        let expected = SamplingPolicy.diskCapacityInterval(settings.diskCapacityCadence)

        // 真实 DiskViewModel，经同一个 coordinator 的 onDemandChange 驱动启停——
        // 必须在 acquire 之前接好回调，否则 0→1 的边沿会在回调注册前就已发生，
        // viewModel 永远收不到 start 信号（这个坑在写测试时真的踩过一次）。
        let probe = DiskIntervalProbe()
        let viewModel = DiskViewModel(
            settings: settings,
            historyStore: MetricHistoryStore(fileURL: nil),
            sampler: { DiskSnapshot() },
            sleeper: { interval in await probe.record(interval) }
        )
        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { module, isDemanded in
            guard module == .disk else { return }
            isDemanded ? viewModel.startSampling() : viewModel.stopSampling()
        }

        // 三个消费者同时需求 Disk：Overview 健康、Disk 面板、菜单栏。
        let a = Owner()
        let b = Owner()
        let c = Owner()
        let tokenA = coordinator.acquire(module: .disk, reason: .overviewHealth, owner: a)
        let tokenB = coordinator.acquire(module: .disk, reason: .panel(.disk), owner: b)
        let tokenC = coordinator.acquire(module: .disk, reason: .menuBar, owner: c)

        XCTAssertEqual(coordinator.demandCount(for: .disk), 3)
        XCTAssertEqual(
            SamplingPolicy.diskCapacityInterval(settings.diskCapacityCadence), expected,
            "多个消费者不得让 Disk 采样提速 —— cadence 由设置决定，与 demand 数无关"
        )

        // 以上两条断言分别只锁住了 coordinator 的计数、和「同一个纯函数调用两次结果相同」——
        // 后者与 demand 数量无关联，是重言式，锁不住「多消费者不提速」本身：coordinator
        // 从未把 demandCount 传给 SamplingPolicy，任何实现（包括错的）都会通过。真正的证据
        // 是下面这条：3 个消费者同时 acquire 之后，真实驱动起来的采样间隔仍必须等于
        // cadence 映射值，而不是被消费者数量影响的其它值。
        let observed = await eventually { await probe.hasRecorded([expected]) }
        XCTAssertTrue(
            observed,
            "3 个消费者同时需求 Disk 时，真实驱动的采样间隔必须仍是 cadence 映射值 \(expected)，不得被消费者数量加速"
        )

        tokenA.cancel()
        tokenB.cancel()
        tokenC.cancel()
    }

    func testExpensiveModulesAreDormantWithoutDemand() {
        var started: Set<MonitoringModule> = []
        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { module, isDemanded in
            if isDemanded { started.insert(module) }
        }
        let health = Owner()

        // 仅建立常驻健康 demand，不打开任何面板。
        var tokens: [DemandToken] = []
        for module in MonitoringDemandBinding.overviewHealthModules {
            tokens.append(
                coordinator.acquire(module: module, reason: .overviewHealth, owner: health)
            )
        }

        for expensive in [MonitoringModule.gpu, .battery, .process, .networkProcessAttribution] {
            XCTAssertEqual(
                coordinator.demandCount(for: expensive), 0,
                "\(expensive) 在无消费者时必须完全无 demand"
            )
            XCTAssertFalse(started.contains(expensive))
        }
        withExtendedLifetime(tokens) {}
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "MonitoringDemandProbeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}

/// 记录 `DiskViewModel` 实际使用的采样间隔；停在一个足够长的睡眠里，
/// 避免测试断言窗口内跑出第二次采样导致 `intervals` 多出一个元素。
private actor DiskIntervalProbe {
    private var intervals: [TimeInterval] = []

    func record(_ interval: TimeInterval) async {
        intervals.append(interval)
        try? await Task.sleep(for: .seconds(60))
    }

    func hasRecorded(_ expected: [TimeInterval]) -> Bool {
        intervals == expected
    }
}

private func eventually(
    timeout: Duration = .seconds(2),
    predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}
