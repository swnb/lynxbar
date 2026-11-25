import AppKit
import Combine
import XCTest
@testable import LynxBar

@MainActor
final class MenuBarStatusPresenterTests: XCTestCase {
    private final class Clock {
        var time = Date(timeIntervalSince1970: 10_000)
    }

    /// Network 的时钟闭包是 Sendable；用锁保护可变测试时钟，避免把
    /// MainActor 的 Clock 捕获到后台采样依赖中。
    private final class SourceClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Date
        init(_ time: Date) { self.time = time }
        func read() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return time
        }
        func set(_ time: Date) {
            lock.lock()
            defer { lock.unlock() }
            self.time = time
        }
    }

    func testSettingsPublicationsImmediatelyDriveTheSameDemandAndPresentation() {
        let settings = makeSettings()
        settings.menuBarDisplayMode = .minimal
        let coordinator = MonitoringDemandCoordinator()
        var presentations: [MenuBarStatusPresentation] = []
        let presenter = makePresenter(settings, coordinator) { presentations.append($0) }
        defer { presenter.invalidate() }

        presenter.startDemand()
        XCTAssertEqual(coordinator.demandCount(for: .cpu), 0)
        settings.menuBarDisplayMode = .compact
        XCTAssertEqual(presentations.last?.mode, .compact)
        XCTAssertEqual(presentations.last?.segments.map(\.slot), [.cpu, .disk, .network])
        XCTAssertEqual(coordinator.demandCount(for: .cpu), 1)
        XCTAssertEqual(coordinator.demandCount(for: .disk), 1)
        XCTAssertEqual(coordinator.demandCount(for: .network), 1)

        settings.setMenuBarSlot(.gpu, at: 0)
        XCTAssertEqual(presentations.last?.segments.first?.slot, .gpu)
        XCTAssertEqual(coordinator.demandCount(for: .gpu), 1)
        XCTAssertEqual(coordinator.demandCount(for: .cpu), 0)

        settings.menuBarDisplayMode = .focus
        XCTAssertEqual(presentations.last?.segments.map(\.slot), [.gpu])
        XCTAssertEqual(coordinator.demandCount(for: .gpu), 1)
        XCTAssertEqual(coordinator.demandCount(for: .disk), 0)
        XCTAssertEqual(coordinator.demandCount(for: .network), 0)
    }

    func testInitializationAndSettingsBeforeHistoryLoadNeverAcquireDemand() {
        let settings = makeSettings()
        let coordinator = MonitoringDemandCoordinator()
        var presentations: [MenuBarStatusPresentation] = []
        let presenter = makePresenter(settings, coordinator) { presentations.append($0) }
        defer { presenter.invalidate() }
        settings.menuBarDisplayMode = .focus
        settings.menuBarSlots = [.gpu]
        XCTAssertEqual(presentations.last?.segments.map(\.slot), [.gpu])
        for module in MonitoringModule.allCases {
            XCTAssertEqual(coordinator.demandCount(for: module), 0)
        }

        presenter.startDemand()
        presenter.startDemand()
        XCTAssertEqual(coordinator.demandCount(for: .gpu), 1)
    }

    func testReorderingAndReplacingAnotherSlotRetainsExistingTokens() {
        let settings = makeSettings()
        let coordinator = MonitoringDemandCoordinator()
        var networkEdges: [Bool] = []
        coordinator.onDemandChange = { module, demanded in
            if module == .network { networkEdges.append(demanded) }
        }
        let presenter = makePresenter(settings, coordinator) { _ in }
        presenter.startDemand()

        settings.menuBarSlots = [.network, .disk, .cpu]
        settings.setMenuBarSlot(.gpu, at: 2)
        XCTAssertEqual(networkEdges, [true], "重排与别槽修改不得重启仍可见的网络")
        XCTAssertEqual(coordinator.demandCount(for: .network), 1)
        XCTAssertEqual(coordinator.demandCount(for: .networkProcessAttribution), 0)
        presenter.invalidate()
        presenter.invalidate()
        XCTAssertEqual(networkEdges, [true, false])
        for module in MonitoringModule.allCases {
            XCTAssertEqual(coordinator.demandCount(for: module), 0)
        }
        settings.menuBarDisplayMode = .compact
        presenter.startDemand()
        XCTAssertEqual(coordinator.demandCount(for: .network), 0)
    }

    func testInitialNumericSnapshotsAreUnavailableAndRealGPUValuesBecomeStale() async {
        let settings = makeSettings()
        settings.menuBarDisplayMode = .focus
        settings.menuBarSlots = [.gpu]
        let clock = Clock()
        let gpu = GPUViewModel(settings: settings)
        var presentations: [MenuBarStatusPresentation] = []
        let presenter = makeRuntimePresenter(settings: settings, gpu: gpu, clock: clock) {
            presentations.append($0)
        }
        defer { presenter.invalidate() }
        XCTAssertEqual(presentations.last?.segments.first?.text, "GPU —")

        gpu.apply(GPUSnapshot(availability: .available, usage: 0.42), at: clock.time)
        XCTAssertEqual(presentations.last?.segments.first?.text, "GPU 42%")
        clock.time = clock.time.addingTimeInterval(20)
        presenter.refreshPresentation()
        XCTAssertEqual(presentations.last?.segments.first?.text, "GPU —")
        XCTAssertTrue(presentations.last?.accessibilityLabel.contains("stale") == true)
        // Non-numeric settings publications may refresh display but not the sample clock.
        settings.showPublicIP.toggle()
        settings.updateInterval = 2
        presenter.refreshPresentation()
        XCTAssertEqual(presentations.last?.segments.first?.text, "GPU —")
        await Task.yield()
    }

    func testGPUUsesOldSourceTimestampInsteadOfFreshPublicationTime() {
        let settings = makeSettings()
        settings.menuBarDisplayMode = .focus
        settings.menuBarSlots = [.gpu]
        let clock = Clock()
        let gpu = GPUViewModel(settings: settings)
        var presentations: [MenuBarStatusPresentation] = []
        let presenter = makeRuntimePresenter(settings: settings, gpu: gpu, clock: clock) {
            presentations.append($0)
        }
        defer { presenter.invalidate() }
        let oldSampleAt = clock.time.addingTimeInterval(-20)
        gpu.apply(GPUSnapshot(availability: .available, usage: 0.42), at: oldSampleAt)
        XCTAssertEqual(gpu.lastNumericSampleAt, oldSampleAt)
        XCTAssertEqual(presentations.last?.segments.first?.text, "GPU —")
        XCTAssertTrue(presentations.last?.accessibilityLabel.contains("stale") == true)
    }

    func testRepeatedPublicIPPublicationDoesNotRefreshExpiredNetworkReading() async {
        let settings = makeSettings()
        settings.showPublicIP = false
        settings.menuBarDisplayMode = .focus
        settings.menuBarSlots = [.network]
        let clock = Clock()
        let sampleAt = clock.time
        let sampleClock = SourceClock(sampleAt)
        let interface = NetworkProvider.Interface(
            name: "en0", ipv4: "192.0.2.10", ipv6: nil, macAddress: nil,
            inBytes: 1_000, outBytes: 1_000,
            isPhysical: true, isUp: true, isRunning: true, isPrimary: true
        )
        let network = NetworkViewModel(
            settings: settings,
            historyStore: MetricHistoryStore(fileURL: nil),
            networkSampler: {
                NetworkProvider.RawCounters(
                    totalIn: 1_000, totalOut: 1_000,
                    interfaces: [interface], primaryInterface: interface
                )
            },
            sleeper: { _ in throw CancellationError() },
            now: { sampleClock.read() }
        )
        var presentations: [MenuBarStatusPresentation] = []
        let presenter = makeRuntimePresenter(settings: settings, network: network, clock: clock) {
            presentations.append($0)
        }
        defer {
            network.stopSampling()
            presenter.invalidate()
        }
        XCTAssertNil(network.lastNumericSampleAt)
        XCTAssertEqual(presentations.last?.segments.first?.text, "NET —")
        network.startSampling()
        await waitUntil { network.lastNumericSampleAt != nil }
        XCTAssertEqual(network.lastNumericSampleAt, sampleAt)
        XCTAssertTrue(presentations.last?.segments.first?.text.contains("↓") == true)
        network.stopSampling()
        clock.time = sampleAt.addingTimeInterval(20)
        presenter.refreshPresentation()
        XCTAssertEqual(presentations.last?.segments.first?.text, "NET —")

        let previousIP = UserDefaults.standard.object(forKey: "network.publicIP.cache")
        defer {
            if let previousIP {
                UserDefaults.standard.set(previousIP, forKey: "network.publicIP.cache")
            } else {
                UserDefaults.standard.removeObject(forKey: "network.publicIP.cache")
            }
        }
        network.applyPublicIP("203.0.113.1")
        var emissionCount = 0
        let observation = network.$snapshot.dropFirst().sink { _ in emissionCount += 1 }
        network.applyPublicIP("203.0.113.1")
        XCTAssertEqual(emissionCount, 2, "相同 IP 和 cache 标记仍触发两次实际 snapshot 发布")
        presenter.refreshPresentation()
        XCTAssertEqual(network.lastNumericSampleAt, sampleAt)
        XCTAssertEqual(presentations.last?.segments.first?.text, "NET —")
        XCTAssertTrue(presentations.last?.accessibilityLabel.contains("stale") == true)
        withExtendedLifetime(observation) {}

        // 数值不变的真实 idle 采样仍应续期；不能把值去重当作来源时间。
        sampleClock.set(clock.time)
        network.startSampling()
        await waitUntil { network.lastNumericSampleAt == clock.time }
        presenter.refreshPresentation()
        XCTAssertTrue(presentations.last?.segments.first?.text.contains("↓") == true)
        XCTAssertFalse(presentations.last?.accessibilityLabel.contains("stale") == true)
    }

    func testPublicThermalStateIsValidAfterFiveMinutesAndStopsImmediately() async {
        let settings = makeSettings()
        settings.menuBarDisplayMode = .focus
        settings.menuBarSlots = [.thermal]
        let clock = Clock()
        let thermal = ThermalViewModel(
            settings: settings,
            notificationCenter: NotificationCenter(),
            stateSampler: { .nominal }
        )
        var presentations: [MenuBarStatusPresentation] = []
        let presenter = makeRuntimePresenter(settings: settings, thermal: thermal, clock: clock) {
            presentations.append($0)
        }
        defer {
            presenter.invalidate()
            thermal.stopSampling()
        }
        thermal.startSampling()
        clock.time = (thermal.snapshot.publicStateObservedAt ?? Date()).addingTimeInterval(601)
        presenter.refreshPresentation()
        XCTAssertEqual(presentations.last?.segments.first?.text, "TMP OK")
        XCTAssertFalse(presentations.last?.accessibilityLabel.contains("stale") == true)
        thermal.stopSampling()
        presenter.refreshPresentation()
        XCTAssertEqual(presentations.last?.segments.first?.text, "TMP —")
        await Task.yield()
    }

    func testActualFontLayoutRespectsBudgetsWithoutClippingDirections() {
        let timestamp = Date()
        for mode in MenuBarDisplayMode.allCases {
            let presentation = MenuBarStatusFormatter.format(
                mode: mode,
                slots: [.network, .thermal, .accessoryBattery],
                snapshot: MenuBarStatusSnapshot(health: .critical, readings: [
                    .network: .numeric(Double.greatestFiniteMagnitude, secondary: 999e12, observedAt: timestamp),
                    .thermal: .observedState("critical", observationActive: true),
                    .accessoryBattery: .numeric(1, observedAt: timestamp),
                ]),
                now: timestamp
            )
            let layout = MenuBarStatusRenderer.layout(for: presentation)
            XCTAssertLessThanOrEqual(layout.width, CGFloat(mode.widthBudget))
            let measured = ceil((layout.title as NSString).size(withAttributes: [.font: layout.font]).width) + 14
            XCTAssertLessThanOrEqual(measured, layout.width)
            if layout.title.count > 1 {
                XCTAssertTrue(layout.title.contains("↓"))
                XCTAssertTrue(layout.title.contains("↑"))
            }
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("采样来源在截止时间内未提交")
    }

    private func makePresenter(
        _ settings: Settings,
        _ coordinator: MonitoringDemandCoordinator,
        render: @escaping (MenuBarStatusPresentation) -> Void
    ) -> MenuBarStatusPresenter {
        MenuBarStatusPresenter(
            settings: settings,
            demandCoordinator: coordinator,
            locale: Locale(identifier: "en_US"),
            snapshotProvider: { _, _, _ in MenuBarStatusSnapshot(health: .collecting, readings: [:]) },
            render: render
        )
    }

    private func makeRuntimePresenter(
        settings: Settings,
        gpu: GPUViewModel? = nil,
        network: NetworkViewModel? = nil,
        thermal: ThermalViewModel? = nil,
        clock: Clock,
        render: @escaping (MenuBarStatusPresentation) -> Void
    ) -> MenuBarStatusPresenter {
        let store = MetricHistoryStore(fileURL: nil)
        return MenuBarStatusPresenter(
            statusItem: nil,
            settings: settings,
            cpu: CPUViewModel(settings: settings, historyStore: store),
            memory: MemoryViewModel(settings: settings, historyStore: store),
            disk: DiskViewModel(settings: settings, historyStore: store),
            network: network ?? NetworkViewModel(settings: settings, historyStore: store),
            gpu: gpu ?? GPUViewModel(settings: settings),
            battery: BatteryViewModel(settings: settings),
            thermal: thermal ?? ThermalViewModel(settings: settings),
            accessoryPower: AccessoryPowerViewModel(settings: settings),
            demandCoordinator: MonitoringDemandCoordinator(),
            locale: Locale(identifier: "en_US"),
            now: { clock.time },
            render: render
        )
    }

    private func makeSettings() -> Settings {
        let suiteName = "MenuBarStatusPresenterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return Settings(defaults: defaults)
    }
}
