import Foundation
import IOKit.ps

enum BatteryChargeState: Sendable, Equatable {
    case charging
    case charged
    case discharging
    case notCharging
    case unknown
}

enum BatteryPowerSource: Sendable, Equatable {
    case ac
    case battery
    case unknown
}

enum BatteryAvailability: Sendable, Equatable {
    case available
    case noInternalBattery
}

enum BatteryHealthState: Sendable, Equatable {
    case good
    case fair
    case poor
    case unknown
}

struct BatterySnapshot: Sendable, Equatable {
    var availability: BatteryAvailability = .noInternalBattery
    var name: String?
    var level: Double?
    var chargeState: BatteryChargeState = .unknown
    var powerSource: BatteryPowerSource = .unknown
    var timeRemaining: TimeInterval?
    var health: BatteryHealthState = .unknown
    var healthCondition: String?
    var isLowPowerModeEnabled = false
}

/// 使用公开 IOKit Power Sources 描述字典读取内置电池状态。
///
/// 循环次数、温度和 raw capacity 等 AppleSmartBattery 注册表字段不属于本模块
/// 的兼容承诺，避免为了更多字段把公开电源状态与未公开实现细节绑在一起。
enum BatteryProvider {
    static func sample() -> BatterySnapshot {
        let powerSourcesInfo = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(powerSourcesInfo)
            .takeRetainedValue() as NSArray
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(
                powerSourcesInfo,
                source as CFTypeRef
            )?.takeUnretainedValue() as? [String: Any],
                  let snapshot = snapshot(
                    from: description,
                    lowPowerModeEnabled: lowPowerMode
                  ) else {
                continue
            }
            return snapshot
        }

        return BatterySnapshot(isLowPowerModeEnabled: lowPowerMode)
    }

    /// 纯映射入口让无电池、UPS、无效容量与充电时间可以脱离当前硬件测试。
    static func snapshot(
        from description: [String: Any],
        lowPowerModeEnabled: Bool
    ) -> BatterySnapshot? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              bool(description[kIOPSIsPresentKey], default: true) else {
            return nil
        }

        let currentCapacity = number(description[kIOPSCurrentCapacityKey])
        let maxCapacity = number(description[kIOPSMaxCapacityKey])
        let level: Double?
        if let currentCapacity,
           let maxCapacity,
           currentCapacity.isFinite,
           maxCapacity.isFinite,
           maxCapacity > 0,
           (0...maxCapacity).contains(currentCapacity) {
            level = currentCapacity / maxCapacity
        } else {
            level = nil
        }

        let isCharged = bool(description[kIOPSIsChargedKey])
        let isCharging = bool(description[kIOPSIsChargingKey])
        let source = powerSource(description[kIOPSPowerSourceStateKey])
        let state: BatteryChargeState
        if isCharged {
            state = .charged
        } else if isCharging {
            state = .charging
        } else if source == .battery {
            state = .discharging
        } else if source == .ac {
            state = .notCharging
        } else {
            state = .unknown
        }

        let timeKey = state == .charging
            ? kIOPSTimeToFullChargeKey
            : kIOPSTimeToEmptyKey
        let minutes = number(description[timeKey])
        let timeRemaining = minutes.flatMap {
            $0.isFinite && $0 > 0 ? $0 * 60 : nil
        }
        let health: BatteryHealthState
        switch description[kIOPSBatteryHealthKey] as? String {
        case kIOPSGoodValue: health = .good
        case kIOPSFairValue: health = .fair
        case kIOPSPoorValue: health = .poor
        default: health = .unknown
        }
        let healthCondition = (description[kIOPSBatteryHealthConditionKey] as? String)
            .flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

        return BatterySnapshot(
            availability: .available,
            name: description[kIOPSNameKey] as? String,
            level: level,
            chargeState: state,
            powerSource: source,
            timeRemaining: timeRemaining,
            health: health,
            healthCondition: healthCondition,
            isLowPowerModeEnabled: lowPowerModeEnabled
        )
    }

    private static func powerSource(_ value: Any?) -> BatteryPowerSource {
        guard let value = value as? String else { return .unknown }
        if value == kIOPSACPowerValue { return .ac }
        if value == kIOPSBatteryPowerValue { return .battery }
        return .unknown
    }

    private static func bool(_ value: Any?, default defaultValue: Bool = false) -> Bool {
        (value as? NSNumber)?.boolValue ?? defaultValue
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.doubleValue
    }
}
