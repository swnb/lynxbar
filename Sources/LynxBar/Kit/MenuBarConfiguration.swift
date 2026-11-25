import Foundation

/// 单一 status item 的文字密度。持久化 raw value 保持稳定；未知值回退到
/// 首版推荐 compact。切换模式只改变可见消费者，不覆盖用户保存的槽位。
enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case minimal
    case focus
    case compact

    /// Stable `Identifiable` identifier matching `self`.
    var id: Self { self }

    /// Validates a persisted display mode raw value, defaulting to `.compact`.
    static func validated(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .compact
    }

    /// minimal 只显示健康状态，focus 为首槽，compact 最多三槽。
    var maximumSlotCount: Int {
        switch self {
        case .minimal: return 0
        case .focus: return 1
        case .compact: return 3
        }
    }

    /// 整项宽度上限，单位为 AppKit points；含按钮边距与图标。
    var widthBudget: Double {
        switch self {
        case .minimal: return 28
        case .focus: return 132
        case .compact: return 300
        }
    }
}

/// 有序指标标识；每槽只有一个基础采样消费者。thermal 表示系统公开热状态，
/// 不暗示精确摄氏度；network 不包含昂贵的进程流量归因。
enum MenuBarStatusSlot: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case memory
    case disk
    case network
    case gpu
    case thermal
    case internalBattery
    case accessoryBattery
    case aiUsage

    /// Stable `Identifiable` identifier matching `self`.
    var id: Self { self }

    /// Default recommended menu bar slot ordering for first launch or invalid persisted configs.
    static let recommended: [Self] = [.cpu, .disk, .network]

    /// 保存顺序、去重并限制三槽。空值或全部无效时恢复推荐配置，
    /// 用户隐藏文字使用 minimal，而不使用空槽数组表达隐藏。
    static func validated(_ rawValues: [String]?) -> [Self] {
        guard let rawValues else { return recommended }
        var seen = Set<Self>()
        let slots = rawValues.compactMap(Self.init(rawValue:)).filter {
            seen.insert($0).inserted
        }
        return slots.isEmpty ? recommended : Array(slots.prefix(3))
    }
}

/// Presenter 持有的已验证配置快照。Combine 的 @Published 在属性写入前发布，
/// 因而需求与展示都必须消费此快照，不能在 sink 中重读 Settings 的旧值。
struct MenuBarConfiguration: Equatable, Sendable {
    let mode: MenuBarDisplayMode
    let slots: [MenuBarStatusSlot]

    /// Creates a validated menu bar configuration snapshot.
    init(mode: MenuBarDisplayMode, slots: [MenuBarStatusSlot]) {
        self.mode = mode
        self.slots = MenuBarStatusSlot.validated(slots.map(\.rawValue))
    }

    /// Returns the active subset of `slots` permitted by `mode.maximumSlotCount`.
    var visibleSlots: [MenuBarStatusSlot] {
        Array(slots.prefix(mode.maximumSlotCount))
    }
}
