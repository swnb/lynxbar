import Foundation

/// 公开 ProcessInfo 边界，仅映射系统枚举，不轮询硬件或请求权限。
enum ThermalProvider {
    static func currentState(
        processInfo: ProcessInfo = .processInfo
    ) -> SystemThermalState {
        state(from: processInfo.thermalState)
    }

    static func state(
        from state: ProcessInfo.ThermalState
    ) -> SystemThermalState {
        switch state {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .unknown
        }
    }
}

