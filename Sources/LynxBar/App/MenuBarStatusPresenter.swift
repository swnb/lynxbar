import AppKit
import Combine
import Foundation

/// 唯一菜单项的展示与消费需求控制面。AppDelegate 拥有 status item 和点击动作；
/// Presenter 只改标题、宽度与辅助标签。初始化仅订阅，history load 完成后由宿主
/// 显式 startDemand()，避免把默认空快照当作采样或提前启动历史写入。
@MainActor
final class MenuBarStatusPresenter {
    private let demandLeases: MenuBarDemandLeaseStore
    private let snapshotProvider: (Date, TimeInterval, TimeInterval) -> MenuBarStatusSnapshot
    private let render: (MenuBarStatusPresentation) -> Void
    private let now: () -> Date
    private let locale: Locale
    private var configuration: MenuBarConfiguration
    private var liveInterval: TimeInterval
    private var diskCadence: TimeInterval
    private var demandStarted = false
    private var invalidated = false
    private var cancellables = Set<AnyCancellable>()

    /// 注入展示与时钟的无 AppKit 测试路径；不会创建真实菜单项或启动采样。
    init(
        settings: Settings,
        demandCoordinator: MonitoringDemandCoordinator,
        now: @escaping () -> Date = { Date() },
        locale: Locale = .current,
        snapshotProvider: @escaping (Date, TimeInterval, TimeInterval) -> MenuBarStatusSnapshot,
        render: @escaping (MenuBarStatusPresentation) -> Void
    ) {
        demandLeases = MenuBarDemandLeaseStore(coordinator: demandCoordinator)
        self.now = now
        self.locale = locale
        self.snapshotProvider = snapshotProvider
        self.render = render
        configuration = MenuBarConfiguration(
            mode: settings.menuBarDisplayMode,
            slots: settings.menuBarSlots
        )
        liveInterval = settings.updateInterval
        diskCadence = settings.diskCapacityCadence.rawValue

        settings.$menuBarDisplayMode
            .combineLatest(settings.$menuBarSlots)
            .map { MenuBarConfiguration(mode: $0, slots: $1) }
            .removeDuplicates()
            .sink { [weak self] configuration in
                guard let self else { return }
                // @Published 在存储属性写入前发出新值。需求与展示共同读取
                // 发布快照；这里不能重读 settings.menuBarDisplayMode/Slots。
                self.configuration = configuration
                self.updateDemand()
                self.refreshPresentation()
            }
            .store(in: &cancellables)
        settings.$updateInterval
            .sink { [weak self] interval in
                self?.liveInterval = interval
                self?.refreshPresentation()
            }
            .store(in: &cancellables)
        settings.$diskCapacityCadence
            .sink { [weak self] cadence in
                self?.diskCadence = cadence.rawValue
                self?.refreshPresentation()
            }
            .store(in: &cancellables)
    }

    /// Production convenience initializer wiring live module view models, sample freshness cache, and `NSStatusItem` rendering.
    convenience init(
        statusItem: NSStatusItem?,
        settings: Settings,
        cpu: CPUViewModel,
        memory: MemoryViewModel,
        disk: DiskViewModel,
        network: NetworkViewModel,
        gpu: GPUViewModel,
        battery: BatteryViewModel,
        thermal: ThermalViewModel,
        accessoryPower: AccessoryPowerViewModel,
        aiUsage: AIUsageViewModel? = nil,
        demandCoordinator: MonitoringDemandCoordinator,
        locale: Locale = .current,
        now: @escaping () -> Date = { Date() },
        render: ((MenuBarStatusPresentation) -> Void)? = nil
    ) {
        let samples = MenuBarSampleCache()
        let aiSettingsMirror = AIUsageMenuBarSettingsMirror(
            claudeEnabled: settings.claudeUsageEnabled,
            codexEnabled: settings.codexUsageEnabled,
            antigravityEnabled: settings.antigravityUsageEnabled,
            displayStyle: settings.aiQuotaDisplayStyle
        )
        self.init(
            settings: settings,
            demandCoordinator: demandCoordinator,
            now: now,
            locale: locale,
            snapshotProvider: { timestamp, liveTTL, diskTTL in
                var readings = samples.readings(staleAfter: liveTTL)
                if !disk.lastSampleFailed,
                   let observedAt = disk.lastSuccessfulSampleAt {
                    readings[.disk] = .numeric(
                        disk.snapshot.primaryVolume?.usage,
                        observedAt: observedAt,
                        staleAfter: diskTTL
                    )
                } else {
                    readings[.disk] = .unavailable
                }
                readings[.thermal] = .observedState(
                    thermal.snapshot.publicStateObservedAt == nil
                        ? nil : thermal.snapshot.publicState.rawValue,
                    observationActive: thermal.isPublicObservationActive
                )
                if let level = accessoryPower.snapshot.preferredMenuBarLevel,
                   let observedAt = accessoryPower.snapshot.preferredMenuBarObservedAt {
                    readings[.accessoryBattery] = .numeric(
                        level,
                        observedAt: observedAt,
                        staleAfter: StandardBLEBatteryAdapter.refreshInterval * 3
                    )
                } else {
                    readings[.accessoryBattery] = .unavailable
                }
                if aiSettingsMirror.anyEnabled, let aiUsage {
                    let entries: [MenuBarAIQuotaEntry] = aiSettingsMirror.enabledProviderIDs.compactMap { providerID in
                        guard let snapshot = aiUsage.snapshot(for: providerID),
                              let window = snapshot.primaryWindow
                                  ?? snapshot.secondaryWindow
                                  ?? snapshot.additionalWindows.first else {
                            return nil
                        }
                        return MenuBarAIQuotaEntry(
                            providerID: providerID,
                            usedRatio: window.usedRatio,
                            resetsAt: window.resetsAt,
                            observedAt: snapshot.fetchedAt
                        )
                    }
                    readings[.aiUsage] = entries.isEmpty
                        ? .unavailable
                        : .aiQuotas(
                            entries,
                            displayStyle: aiSettingsMirror.displayStyle,
                            staleAfter: AIUsageViewModel.menuBarTTL
                        )
                } else {
                    readings[.aiUsage] = .unavailable
                }
                let primary = disk.snapshot.primaryVolume
                let health = SystemHealthEvaluator.evaluate(SystemHealthInput(
                    cpuHistory: cpu.recentHistory.points,
                    memoryPressure: memory.pressure,
                    diskFreeBytes: primary?.freeBytes,
                    diskTotalBytes: primary?.totalBytes,
                    hasPrimaryNetwork: network.snapshot.interfaces.isEmpty
                        ? nil : network.snapshot.primaryInterface != nil,
                    now: timestamp,
                    thermalState: thermal.snapshot.publicState
                ))
                return MenuBarStatusSnapshot(health: health.severity, readings: readings)
            },
            render: { presentation in
                if let render {
                    render(presentation)
                } else if let statusItem {
                    MenuBarStatusRenderer.render(presentation, into: statusItem)
                }
            }
        )

        // 来源在安装 snapshot 后发布真实采样时间。这里直接消费新 Date，
        // 不以展示发布时钟猜 freshness；history/range/IP 等更新无法续命。
        observe(cpu.$lastNumericSampleAt) { timestamp in
            samples.record(.cpu, value: cpu.snapshot.perCoreUsage.isEmpty ? nil : cpu.snapshot.usage, at: timestamp)
        }
        observe(memory.$lastNumericSampleAt) { timestamp in
            samples.record(.memory, value: memory.snapshot.total > 0 ? memory.snapshot.usage : nil, at: timestamp)
        }
        observe(gpu.$lastNumericSampleAt) { timestamp in
            samples.record(.gpu, value: gpu.snapshot.usage, at: timestamp)
        }
        observe(battery.$lastNumericSampleAt) { timestamp in
            samples.record(.internalBattery, value: battery.snapshot.level, at: timestamp)
        }
        observe(network.$lastNumericSampleAt) { timestamp in
            let snapshot = network.snapshot
            let available = snapshot.primaryInterface != nil
                && snapshot.totalDownloaded != nil && snapshot.totalUploaded != nil
            samples.record(
                .network,
                value: available ? snapshot.downloadBytesPerSecond : nil,
                secondary: available ? snapshot.uploadBytesPerSecond : nil,
                at: timestamp
            )
        }
        observe(settings.$claudeUsageEnabled.removeDuplicates()) { enabled in
            aiSettingsMirror.claudeEnabled = enabled
        }
        observe(settings.$codexUsageEnabled.removeDuplicates()) { enabled in
            aiSettingsMirror.codexEnabled = enabled
        }
        observe(settings.$antigravityUsageEnabled.removeDuplicates()) { enabled in
            aiSettingsMirror.antigravityEnabled = enabled
        }
        observe(settings.$aiQuotaDisplayStyle.removeDuplicates()) { style in
            aiSettingsMirror.displayStyle = style
        }
        observeAfterPublication(disk.$lastSuccessfulSampleAt)
        observeAfterPublication(disk.$lastSampleFailed)
        observeAfterPublication(cpu.$recentHistory)
        observeAfterPublication(memory.$pressure)
        observeAfterPublication(thermal.$snapshot)
        observeAfterPublication(thermal.$isPublicObservationActive)
        observeAfterPublication(accessoryPower.$snapshot)
        if let aiUsage {
            observeAfterPublication(aiUsage.$providerStates)
            observeAfterPublication(aiUsage.$state)
            observeAfterPublication(aiUsage.$lastSuccessfulFetchAt)
        }
    }

    /// history load 的完成边界。幂等；测试宿主可一直不调用。
    func startDemand() {
        guard !invalidated, !demandStarted else { return }
        demandStarted = true
        updateDemand()
        refreshPresentation()
    }

    /// Cancels all demand leases and Combine subscriptions when the status item is torn down.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        demandStarted = false
        demandLeases.cancelAll()
        cancellables.removeAll()
    }

    /// Recomputes the menu bar presentation from current readings and pushes it to the renderer.
    func refreshPresentation() {
        guard !invalidated else { return }
        let timestamp = now()
        render(MenuBarStatusFormatter.format(
            mode: configuration.mode,
            slots: configuration.slots,
            snapshot: snapshotProvider(timestamp, max(5, liveInterval * 3), diskCadence * 3),
            locale: locale,
            now: timestamp
        ))
    }

    /// Synchronizes acquired monitoring demand leases with the currently visible menu bar slots.
    private func updateDemand() {
        guard demandStarted else { return }
        demandLeases.update(desiredSlots: Set(configuration.visibleSlots))
    }

    /// Subscribes to a publisher synchronously updating cached state and refreshing the menu bar.
    private func observe<P: Publisher>(
        _ publisher: P,
        receive: @escaping (P.Output) -> Void
    ) where P.Failure == Never {
        publisher.sink { [weak self] output in
            receive(output)
            self?.refreshPresentation()
        }
        .store(in: &cancellables)
    }

    /// 来源拥有 freshness 字段时，只在发布完成后读取；无需人为更新时间。
    private func observeAfterPublication<P: Publisher>(_ publisher: P) where P.Failure == Never {
        publisher.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPresentation() }
        }
        .store(in: &cancellables)
    }
}

/// 每槽持有独立凭证；保留仍可见的 token，布局重排不能重启采样。
/// 生命周期与 Presenter 一致，不由 SwiftUI View 持有 owner 身份。
@MainActor
final class MenuBarDemandLeaseStore: MonitoringDemandOwner {
    private let coordinator: MonitoringDemandCoordinator
    private var tokens: [MenuBarStatusSlot: DemandToken] = [:]

    /// Creates a lease store backed by `coordinator`.
    init(coordinator: MonitoringDemandCoordinator) {
        self.coordinator = coordinator
    }

    /// Releases leases for removed slots and acquires leases for newly visible slots.
    func update(desiredSlots: Set<MenuBarStatusSlot>) {
        for slot in tokens.keys.filter({ !desiredSlots.contains($0) }) {
            tokens.removeValue(forKey: slot)?.cancel()
        }
        for slot in desiredSlots where tokens[slot] == nil {
            tokens[slot] = coordinator.acquire(module: slot.monitoringModule, reason: .menuBar, owner: self)
        }
    }

    /// Cancels every active menu bar demand token.
    func cancelAll() {
        tokens.values.forEach { $0.cancel() }
        tokens.removeAll()
    }
}

private extension MenuBarStatusSlot {
    /// Maps a menu bar status slot to the underlying `MonitoringModule` it demands.
    var monitoringModule: MonitoringModule {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .disk: return .disk
        case .network: return .network
        case .gpu: return .gpu
        case .thermal: return .thermal
        case .internalBattery: return .battery
        case .accessoryBattery: return .accessoryPower
        case .aiUsage: return .aiUsage
        }
    }
}

/// Captures published AI quota settings synchronously on `@MainActor` so `snapshotProvider` avoids reading stale `willSet` values.
@MainActor
private final class AIUsageMenuBarSettingsMirror {
    var claudeEnabled: Bool
    var codexEnabled: Bool
    var antigravityEnabled: Bool
    var displayStyle: AIQuotaDisplayStyle

    /// Creates a synchronous snapshot of AI quota settings for the menu bar presenter.
    init(
        claudeEnabled: Bool,
        codexEnabled: Bool,
        antigravityEnabled: Bool,
        displayStyle: AIQuotaDisplayStyle
    ) {
        self.claudeEnabled = claudeEnabled
        self.codexEnabled = codexEnabled
        self.antigravityEnabled = antigravityEnabled
        self.displayStyle = displayStyle
    }

    /// Returns `true` when at least one AI subscription provider is enabled.
    var anyEnabled: Bool {
        claudeEnabled || codexEnabled || antigravityEnabled
    }

    /// Returns enabled provider identifiers in canonical `AIUsageProviderID.allCases` order.
    var enabledProviderIDs: [AIUsageProviderID] {
        var result: [AIUsageProviderID] = []
        if claudeEnabled { result.append(.claude) }
        if codexEnabled { result.append(.codex) }
        if antigravityEnabled { result.append(.antigravity) }
        return result
    }
}

/// 单独保存“真正数值发布”的证据，避免读取 @Published 写入前的旧 snapshot。
@MainActor
private final class MenuBarSampleCache {
    private struct Sample {
        let value: Double?
        let secondary: Double?
        let observedAt: Date
    }
    private var samples: [MenuBarStatusSlot: Sample] = [:]

    /// Stores or clears the latest numeric sample and observation timestamp for `slot`.
    func record(_ slot: MenuBarStatusSlot, value: Double?, secondary: Double? = nil, at time: Date?) {
        guard let time else {
            samples.removeValue(forKey: slot)
            return
        }
        samples[slot] = Sample(value: value, secondary: secondary, observedAt: time)
    }

    /// Converts cached numeric samples into `MenuBarMetricReading` values tagged with `staleAfter`.
    func readings(staleAfter: TimeInterval) -> [MenuBarStatusSlot: MenuBarMetricReading] {
        samples.mapValues { sample in
            .numeric(sample.value, secondary: sample.secondary, observedAt: sample.observedAt, staleAfter: staleAfter)
        }
    }
}

/// AppKit 边界按实际字体测量，而不是把字符数估计当成可用宽度。
/// 超限先移除 focus 网络的重复名称、再缩小字号，最后隐藏文字；完整读数
/// 一直保留在 tooltip/VoiceOver 中，固定预算不裁切半个数值或方向符号。
@MainActor
enum MenuBarStatusRenderer {
    /// Measured AppKit text layout fitting within the active display mode's width budget.
    struct Layout {
        let title: String
        let font: NSFont
        let width: CGFloat
    }

    /// Computes a non-truncating title, monospaced font size, and status item width for `presentation`.
    static func layout(for presentation: MenuBarStatusPresentation) -> Layout {
        let budget = CGFloat(presentation.mode.widthBudget)
        var title = presentation.title
        if presentation.mode == .focus, presentation.segments.first?.slot == .network {
            title = title.replacingOccurrences(of: "NET ", with: "")
        }
        for size in [CGFloat(11), 10, 9] {
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
            let width = ceil((title as NSString).size(withAttributes: [.font: font]).width) + 14
            if width <= budget {
                return Layout(title: title, font: font, width: max(28, width))
            }
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        return Layout(title: String(presentation.title.prefix(1)), font: font, width: 28)
    }

    /// Applies the measured title, font, width, tooltip, and VoiceOver label onto `statusItem`.
    static func render(_ presentation: MenuBarStatusPresentation, into statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }
        let layout = layout(for: presentation)
        button.imagePosition = .noImage
        button.title = layout.title
        button.font = layout.font
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        button.toolTip = presentation.accessibilityLabel
        statusItem.length = layout.width
    }
}
