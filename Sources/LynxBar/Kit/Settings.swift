import AppKit
import Foundation

enum DiskCapacityCadence: TimeInterval, CaseIterable, Identifiable, Sendable {
    case tenMinutes = 600
    case oneHour = 3_600
    case oneDay = 86_400

    var id: TimeInterval { rawValue }

    var shortLabel: String {
        switch self {
        case .tenMinutes: return "10 min"
        case .oneHour: return "1 hour"
        case .oneDay: return "1 day"
        }
    }

    var scheduleLabel: String {
        switch self {
        case .tenMinutes: return "Every 10 minutes"
        case .oneHour: return "Every 1 hour"
        case .oneDay: return "Every 1 day"
        }
    }

    static func validated(_ rawValue: TimeInterval?) -> Self {
        guard let rawValue, let cadence = Self(rawValue: rawValue) else {
            return .tenMinutes
        }
        return cadence
    }
}

/// Application-wide appearance preference persisted in Settings.
enum AppAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case dark
    case light

    var id: Self { self }

    /// Decodes a persisted raw string, falling back to `.system` when missing or unknown.
    static func validated(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .system
    }

    /// Corresponding AppKit `NSAppearance.Name`, or `nil` when following macOS system appearance.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .dark: return .darkAqua
        case .light: return .aqua
        }
    }

    /// Concrete `NSAppearance` for `NSApp.appearance` (`nil` tracks system appearance dynamically).
    var nsAppearance: NSAppearance? {
        appearanceName.flatMap(NSAppearance.init(named:))
    }
}

/// 全局用户设置。线程模型：仅主线程读写（UI 绑定）。
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    /// 可选的刷新间隔（秒）。
    static let intervals: [TimeInterval] = [1, 2, 5, 10]

    private enum Key {
        static let updateInterval = "updateInterval"
        static let cpuEnabled = "module.cpu.enabled"
        static let memoryEnabled = "module.memory.enabled"
        static let diskEnabled = "module.disk.enabled"
        static let networkEnabled = "module.network.enabled"
        static let gpuEnabled = "module.gpu.enabled"
        static let batteryEnabled = "module.battery.enabled"
        static let showPublicIP = "network.showPublicIP"
        static let appearanceMode = "general.appearanceMode"
        static let launchAtLogin = "general.launchAtLogin"
        static let processTopN = "process.topN"
        static let diskCapacityCadence = "disk.capacity.cadence"
        static let menuBarDisplayMode = "menuBar.displayMode"
        static let menuBarSlots = "menuBar.slots"
        static let standardBLEBatteryEnabled = "accessory.standardBLE.enabled"
        static let aiUsageEnabled = "aiUsage.enabled"
        static let claudeUsageEnabled = "aiUsage.claude.enabled"
        static let codexUsageEnabled = "aiUsage.codex.enabled"
        static let antigravityUsageEnabled = "aiUsage.antigravity.enabled"
        static let aiQuotaDisplayStyle = "aiUsage.displayStyle"
        static let aiUsageSectionVisible = "module.aiUsage.visible"
    }

    private enum AIUsageSyncTarget: Equatable {
        case claude
        case codex
        case antigravity
        case aggregate
    }

    private enum AIUsageSyncSource {
        case fromProviders
        case fromAggregate(Bool)
    }

    private let defaults: UserDefaults
    private var applyingAIUsageSyncTarget: AIUsageSyncTarget?
    private var isFlushingAIUsageSync = false
    private var isAggregateSyncHalted = false
    private var pendingAIUsageSync: AIUsageSyncSource?

    @Published var updateInterval: TimeInterval {
        didSet { defaults.set(updateInterval, forKey: Key.updateInterval) }
    }

    @Published var cpuEnabled: Bool {
        didSet { defaults.set(cpuEnabled, forKey: Key.cpuEnabled) }
    }

    @Published var memoryEnabled: Bool {
        didSet { defaults.set(memoryEnabled, forKey: Key.memoryEnabled) }
    }

    @Published var diskEnabled: Bool {
        didSet { defaults.set(diskEnabled, forKey: Key.diskEnabled) }
    }

    @Published var networkEnabled: Bool {
        didSet { defaults.set(networkEnabled, forKey: Key.networkEnabled) }
    }

    @Published var gpuEnabled: Bool {
        didSet { defaults.set(gpuEnabled, forKey: Key.gpuEnabled) }
    }

    @Published var batteryEnabled: Bool {
        didSet { defaults.set(batteryEnabled, forKey: Key.batteryEnabled) }
    }

    @Published var showPublicIP: Bool {
        didSet { defaults.set(showPublicIP, forKey: Key.showPublicIP) }
    }

    /// Application-wide appearance preference (`system` follows macOS dynamically).
    /// Consumers observing `$appearanceMode` must use the published value rather than re-reading this property during `willSet`.
    @Published var appearanceMode: AppAppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Key.appearanceMode) }
    }

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    @Published var processTopN: Int {
        didSet { defaults.set(processTopN, forKey: Key.processTopN) }
    }

    @Published var diskCapacityCadence: DiskCapacityCadence {
        didSet {
            defaults.set(
                diskCapacityCadence.rawValue,
                forKey: Key.diskCapacityCadence
            )
        }
    }

    /// 单一菜单项的显示模式。缺失/未知持久值回退 compact；模式仅改变菜单槽需求，
    /// 不改变面板导航或 Overview 的健康信号所有权。
    @Published var menuBarDisplayMode: MenuBarDisplayMode {
        didSet { defaults.set(menuBarDisplayMode.rawValue, forKey: Key.menuBarDisplayMode) }
    }

    /// 最多三个有序、不重复的指标槽；默认 CPU、Disk、Network。发布消费者必须
    /// 使用 publisher 提供的新值，不能在 willSet 期间重读该属性。
    @Published var menuBarSlots: [MenuBarStatusSlot] {
        didSet {
            let validated = MenuBarStatusSlot.validated(menuBarSlots.map(\.rawValue))
            if validated != menuBarSlots { menuBarSlots = validated }
            defaults.set(validated.map(\.rawValue), forKey: Key.menuBarSlots)
        }
    }

    /// 标准 BLE 电量发现的用户 opt-in，默认 false。该值不是扫描许可：只有
    /// accessoryPower demand 存活时才允许创建 central，关闭后必须停止并断开。
    @Published var standardBLEBatteryEnabled: Bool {
        didSet { defaults.set(standardBLEBatteryEnabled, forKey: Key.standardBLEBatteryEnabled) }
    }

    /// Explicit opt-in controlling read-only local Claude OAuth credential reads and Anthropic usage queries (defaults to `false`).
    /// Consumers observing `$claudeUsageEnabled` must consume the published value directly rather than re-reading this property during `willSet`.
    @Published var claudeUsageEnabled: Bool {
        didSet {
            defaults.set(claudeUsageEnabled, forKey: Key.claudeUsageEnabled)
            guard applyingAIUsageSyncTarget != .claude else { return }
            enqueueAIUsageSync(.fromProviders)
        }
    }

    /// Explicit opt-in controlling read-only local Codex CLI OAuth credential reads and ChatGPT usage queries (defaults to `false`).
    /// Consumers observing `$codexUsageEnabled` must consume the published value directly rather than re-reading this property during `willSet`.
    @Published var codexUsageEnabled: Bool {
        didSet {
            defaults.set(codexUsageEnabled, forKey: Key.codexUsageEnabled)
            persistMigratedClaudeFlagIfNeeded()
            guard applyingAIUsageSyncTarget != .codex else { return }
            enqueueAIUsageSync(.fromProviders)
        }
    }

    /// Explicit opt-in controlling Antigravity subscription quota queries via `CodexBarCore` (defaults to `false`).
    /// Consumers observing `$antigravityUsageEnabled` must consume the published value directly rather than re-reading this property during `willSet`.
    @Published var antigravityUsageEnabled: Bool {
        didSet {
            defaults.set(antigravityUsageEnabled, forKey: Key.antigravityUsageEnabled)
            persistMigratedClaudeFlagIfNeeded()
            guard applyingAIUsageSyncTarget != .antigravity else { return }
            enqueueAIUsageSync(.fromProviders)
        }
    }

    /// Aggregate opt-in indicating whether any AI subscription provider is enabled, kept synchronized with per-provider flags (defaults to `false`).
    /// Consumers observing `$aiUsageEnabled` must consume the published value directly rather than re-reading this property during `willSet`.
    @Published var aiUsageEnabled: Bool {
        didSet {
            defaults.set(aiUsageEnabled, forKey: Key.aiUsageEnabled)
            guard applyingAIUsageSyncTarget != .aggregate else { return }
            enqueueAIUsageSync(.fromAggregate(aiUsageEnabled))
        }
    }

    /// Percentage convention (`remaining` vs `used`) for AI quota bars, Overview row, and menu bar slot (defaults to `.remaining`).
    /// Consumers observing `$aiQuotaDisplayStyle` must consume the published value directly.
    @Published var aiQuotaDisplayStyle: AIQuotaDisplayStyle {
        didSet { defaults.set(aiQuotaDisplayStyle.rawValue, forKey: Key.aiQuotaDisplayStyle) }
    }

    /// Controls visibility of the AI destination tab in `BottomNavigation` (defaults to `true`); does not enable network fetches on its own.
    @Published var aiUsageSectionVisible: Bool {
        didSet { defaults.set(aiUsageSectionVisible, forKey: Key.aiUsageSectionVisible) }
    }

    /// 允许测试使用隔离的 UserDefaults suite；生产单例仍使用 standard。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.menuBarDisplayMode = .validated(defaults.string(forKey: Key.menuBarDisplayMode))
        self.menuBarSlots = MenuBarStatusSlot.validated(defaults.stringArray(forKey: Key.menuBarSlots))
        self.standardBLEBatteryEnabled = defaults.bool(forKey: Key.standardBLEBatteryEnabled)
        let storedLegacyAIUsage = defaults.object(forKey: Key.aiUsageEnabled) as? Bool
        let storedClaude = defaults.object(forKey: Key.claudeUsageEnabled) as? Bool
        let storedCodex = defaults.object(forKey: Key.codexUsageEnabled) as? Bool
        let storedAntigravity = defaults.object(forKey: Key.antigravityUsageEnabled) as? Bool

        let hasAnyPerProviderKey = storedClaude != nil || storedCodex != nil || storedAntigravity != nil

        let resolvedClaude: Bool
        let resolvedCodex: Bool
        let resolvedAntigravity: Bool

        if hasAnyPerProviderKey {
            resolvedClaude = storedClaude ?? false
            resolvedCodex = storedCodex ?? false
            resolvedAntigravity = storedAntigravity ?? false
        } else if let storedLegacyAIUsage {
            // Migrate legacy single-provider `aiUsage.enabled` exclusively to Claude without
            // mutating `UserDefaults` during `init`; persisted once any provider toggle is modified.
            resolvedClaude = storedLegacyAIUsage
            resolvedCodex = false
            resolvedAntigravity = false
        } else {
            resolvedClaude = false
            resolvedCodex = false
            resolvedAntigravity = false
        }
        let resolvedAnyAIUsage = resolvedClaude || resolvedCodex || resolvedAntigravity

        self.claudeUsageEnabled = resolvedClaude
        self.codexUsageEnabled = resolvedCodex
        self.antigravityUsageEnabled = resolvedAntigravity
        self.aiUsageEnabled = resolvedAnyAIUsage
        self.aiQuotaDisplayStyle = .validated(defaults.string(forKey: Key.aiQuotaDisplayStyle))
        self.aiUsageSectionVisible = (defaults.object(forKey: Key.aiUsageSectionVisible) as? Bool) ?? true
        self.updateInterval = (defaults.object(forKey: Key.updateInterval) as? Double) ?? 2.0
        self.cpuEnabled = (defaults.object(forKey: Key.cpuEnabled) as? Bool) ?? true
        self.memoryEnabled = (defaults.object(forKey: Key.memoryEnabled) as? Bool) ?? true
        self.diskEnabled = (defaults.object(forKey: Key.diskEnabled) as? Bool) ?? true
        self.networkEnabled = (defaults.object(forKey: Key.networkEnabled) as? Bool) ?? true
        self.gpuEnabled = (defaults.object(forKey: Key.gpuEnabled) as? Bool) ?? true
        self.batteryEnabled = (defaults.object(forKey: Key.batteryEnabled) as? Bool) ?? true
        self.showPublicIP = (defaults.object(forKey: Key.showPublicIP) as? Bool) ?? false
        self.appearanceMode = .validated(defaults.string(forKey: Key.appearanceMode))
        self.launchAtLogin = (defaults.object(forKey: Key.launchAtLogin) as? Bool) ?? false
        self.processTopN = (defaults.object(forKey: Key.processTopN) as? Int) ?? 10
        self.diskCapacityCadence = .validated(
            (defaults.object(forKey: Key.diskCapacityCadence) as? NSNumber)?.doubleValue
        )
    }

    /// 修改一个槽时交换重复项，保持用户选择的有序三槽，而不是静默丢弃另一槽。
    func setMenuBarSlot(_ slot: MenuBarStatusSlot, at index: Int) {
        guard (0..<3).contains(index) else { return }
        var next = menuBarSlots
        while next.count <= index {
            guard let fallback = MenuBarStatusSlot.allCases.first(where: { !next.contains($0) }) else { break }
            next.append(fallback)
        }
        guard next.indices.contains(index) else { return }
        if let existing = next.firstIndex(of: slot), existing != index {
            next.swapAt(existing, index)
        } else {
            next[index] = slot
        }
        menuBarSlots = next
    }

    /// Returns `true` when any AI subscription quota provider is currently enabled.
    var anyAIUsageEnabled: Bool {
        claudeUsageEnabled || codexUsageEnabled || antigravityUsageEnabled
    }

    /// Returns enabled AI subscription quota provider identifiers in canonical `AIUsageProviderID.allCases` order.
    var enabledAIUsageProviders: [AIUsageProviderID] {
        AIUsageProviderID.allCases.filter { isAIProviderEnabled($0) }
    }

    /// Returns whether quota monitoring is currently enabled for `providerID`.
    func isAIProviderEnabled(_ providerID: AIUsageProviderID) -> Bool {
        switch providerID {
        case .claude:
            return claudeUsageEnabled
        case .codex:
            return codexUsageEnabled
        case .antigravity:
            return antigravityUsageEnabled
        }
    }

    /// Updates the opt-in preference for `providerID` and keeps `aiUsageEnabled` synchronized.
    func setAIProviderEnabled(_ enabled: Bool, for providerID: AIUsageProviderID) {
        switch providerID {
        case .claude:
            claudeUsageEnabled = enabled
        case .codex:
            codexUsageEnabled = enabled
        case .antigravity:
            antigravityUsageEnabled = enabled
        }
    }

    /// Persists an in-memory legacy Claude migration before another provider key creates `hasAnyPerProviderKey` state.
    private func persistMigratedClaudeFlagIfNeeded() {
        if claudeUsageEnabled && defaults.object(forKey: Key.claudeUsageEnabled) == nil {
            defaults.set(true, forKey: Key.claudeUsageEnabled)
        }
    }

    /// Records the latest AI toggle write and reconciles `aiUsageEnabled` with per-provider flags until quiescent,
    /// ensuring re-entrant mutations inside `@Published` `willSet` sinks are never silently dropped.
    private func enqueueAIUsageSync(_ source: AIUsageSyncSource) {
        if isAggregateSyncHalted, case .fromAggregate = source {
            return
        }
        pendingAIUsageSync = source
        guard !isFlushingAIUsageSync else { return }
        isFlushingAIUsageSync = true
        defer {
            isAggregateSyncHalted = false
            applyingAIUsageSyncTarget = nil
            isFlushingAIUsageSync = false
        }

        var iterations = 0
        while let nextSource = pendingAIUsageSync {
            pendingAIUsageSync = nil
            iterations += 1
            if iterations > 16 {
                // Guard against oscillating re-entrant Combine observers: halt aggregate->provider
                // cascades and run up to 4 final reconciliation passes so late per-provider mutations
                // triggered during `$aiUsageEnabled` `willSet` converge with `anyAIUsageEnabled`.
                isAggregateSyncHalted = true
                for _ in 0..<4 {
                    pendingAIUsageSync = nil
                    let anyEnabled = anyAIUsageEnabled
                    if aiUsageEnabled != anyEnabled {
                        applyingAIUsageSyncTarget = .aggregate
                        aiUsageEnabled = anyEnabled
                        applyingAIUsageSyncTarget = nil
                    }
                    if pendingAIUsageSync == nil && aiUsageEnabled == anyAIUsageEnabled {
                        break
                    }
                }
                pendingAIUsageSync = nil
                break
            }

            switch nextSource {
            case .fromProviders:
                let anyEnabled = anyAIUsageEnabled
                if aiUsageEnabled != anyEnabled {
                    applyingAIUsageSyncTarget = .aggregate
                    aiUsageEnabled = anyEnabled
                    applyingAIUsageSyncTarget = nil
                }
            case .fromAggregate(let enabled):
                if enabled {
                    if !anyAIUsageEnabled {
                        applyingAIUsageSyncTarget = .claude
                        claudeUsageEnabled = true
                        applyingAIUsageSyncTarget = nil
                    }
                } else {
                    if claudeUsageEnabled {
                        applyingAIUsageSyncTarget = .claude
                        claudeUsageEnabled = false
                        applyingAIUsageSyncTarget = nil
                    }
                    if codexUsageEnabled {
                        applyingAIUsageSyncTarget = .codex
                        codexUsageEnabled = false
                        applyingAIUsageSyncTarget = nil
                    }
                    if antigravityUsageEnabled {
                        applyingAIUsageSyncTarget = .antigravity
                        antigravityUsageEnabled = false
                        applyingAIUsageSyncTarget = nil
                    }
                }
            }
        }

        // Ensure UserDefaults reflects final in-memory state after any re-entrant `willSet` mutations.
        defaults.set(claudeUsageEnabled, forKey: Key.claudeUsageEnabled)
        defaults.set(codexUsageEnabled, forKey: Key.codexUsageEnabled)
        defaults.set(antigravityUsageEnabled, forKey: Key.antigravityUsageEnabled)
        defaults.set(aiUsageEnabled, forKey: Key.aiUsageEnabled)
    }

}
