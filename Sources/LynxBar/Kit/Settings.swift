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
        static let aiQuotaDisplayStyle = "aiUsage.displayStyle"
        static let aiUsageSectionVisible = "module.aiUsage.visible"
    }

    private let defaults: UserDefaults

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
    /// Consumers observing `$aiUsageEnabled` must consume the published value directly rather than re-reading this property during `willSet`.
    @Published var aiUsageEnabled: Bool {
        didSet { defaults.set(aiUsageEnabled, forKey: Key.aiUsageEnabled) }
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
        self.aiUsageEnabled = (defaults.object(forKey: Key.aiUsageEnabled) as? Bool) ?? false
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

}
