import Foundation

/// 将公开热状态与兼容数值来源分开表达。该类型只格式化已有证据，永不从
/// utilization/thermal state 推算摄氏度；无数值来源时明确使用 unavailable。
enum ThermalContextText {
    static func summary(_ snapshot: ThermalSnapshot, group: TemperatureSensorGroup) -> String {
        if let aggregate = snapshot.temperatures.aggregates.first(where: { $0.group == group }) {
            return String(format: NSLocalizedString("%@ · hottest %.1f°C", comment: ""),
                          snapshot.publicState.localizedLabel, aggregate.hottestCelsius)
        }
        return String(format: NSLocalizedString("%@ · temperature unavailable", comment: ""),
                      snapshot.publicState.localizedLabel)
    }

    static func sourceDescription(_ snapshot: ThermalSnapshot) -> String {
        snapshot.temperatures.aggregates.isEmpty
            ? NSLocalizedString("Public macOS thermal state; exact CPU/GPU temperature unavailable.", comment: "")
            : NSLocalizedString("Hottest approved sensor; public thermal state determines health.", comment: "")
    }
}
