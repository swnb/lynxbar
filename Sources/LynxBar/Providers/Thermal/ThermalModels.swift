import Foundation

/// ProcessInfo 公开热压力等级，不含温度单位；unknown 不等价于 nominal，禁止推算摄氏温度。
enum SystemThermalState: String, Codable, CaseIterable, Sendable {
    case unknown
    case nominal
    case fair
    case serious
    case critical

    var localizedLabel: String {
        switch self {
        case .unknown:
            return NSLocalizedString("Thermal state unknown", comment: "")
        case .nominal:
            return NSLocalizedString("Thermal state nominal", comment: "")
        case .fair:
            return NSLocalizedString("Thermal state fair", comment: "")
        case .serious:
            return NSLocalizedString("Thermal state serious", comment: "")
        case .critical:
            return NSLocalizedString("Thermal state critical", comment: "")
        }
    }
}

/// 数值来源声明。本版默认 unavailable，没有启用 SMC/HID/IOReport 读取或私有 framework。
enum TemperatureSensorSource: String, Codable, Sendable {
    case smc
    case hid
    case ioReport
    case unavailable
}

/// stale/无权限/不支持时 aggregates 为空，禁止伪造 0°C。
enum TemperatureSensorAvailability: String, Codable, Sendable {
    case available
    case stale
    case unavailable
    case permissionDenied
    case unsupported
}

enum TemperatureSensorGroup: String, Codable, CaseIterable, Sendable {
    case cpu
    case gpu
}

/// 由来源拥有的稳定 sensor identity，未知注册表 key 不会自动获得展示资格。
struct TemperatureSensorIdentity: Hashable, Codable, Sendable {
    let source: TemperatureSensorSource
    /// 必须在适配器 allowlist 中；不记录或展示未批准 registry key。
    let stableID: String
}

struct TemperatureSensorSample: Equatable, Sendable {
    let identity: TemperatureSensorIdentity
    /// 摄氏度，必须有限并在政策允许范围，默认 0...125。
    let celsius: Double
    /// 实际观察时刻；未来或过期读数不进入当前聚合。
    let observedAt: Date
}

struct TemperatureSensorAggregate: Equatable, Sendable {
    /// allowlist 指定的 CPU/GPU 分组，不由名称推断。
    let group: TemperatureSensorGroup
    /// 组内新鲜有效读数的最高摄氏温度，不是平均温度。
    let hottestCelsius: Double
    /// 该聚合包含的新鲜有效传感器数量，必须大于 0。
    let sensorCount: Int
    /// 实际观察时刻；未来或过期读数不进入当前聚合。
    let observedAt: Date
    let source: TemperatureSensorSource
}

struct TemperatureSensorSnapshot: Equatable, Sendable {
    /// 默认 unavailable，来源缺失不会自动切换到其他来源。
    var source: TemperatureSensorSource = .unavailable
    var availability: TemperatureSensorAvailability = .unavailable
    /// 每组至多一个 hottest 聚合，不可用时为空。
    var aggregates: [TemperatureSensorAggregate] = []
    /// 数值来源最近时刻，默认 nil；陈旧时可保留时间但不能保留温度。
    var observedAt: Date?

    func aggregate(for group: TemperatureSensorGroup) -> TemperatureSensorAggregate? {
        aggregates.first { $0.group == group }
    }

    static let unavailable = TemperatureSensorSnapshot()
}

struct ThermalSnapshot: Equatable, Sendable {
    /// 健康严重性只使用公开状态；numeric 温度不参与健康阈值。
    var publicState: SystemThermalState = .unknown
    /// 初始查询/变更通知时刻。通知没有周期，活跃订阅不能按 TTL 判陈旧。
    var publicStateObservedAt: Date?
    /// 独立 numeric demand 模块的结果，默认无值。
    var temperatures: TemperatureSensorSnapshot = .unavailable
}
