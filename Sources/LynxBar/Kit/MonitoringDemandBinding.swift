/// section / 健康状态 与采样模块之间的映射。
///
/// 纯函数，便于穷举测试；特别是「哪个 section 需要 nettop 进程归因」这条 ——
/// 它是最贵的采样源（每次采样 fork 一个 `/usr/bin/nettop`），映射错了代价最大。
enum MonitoringDemandBinding {
    static func modules(for section: DashboardSection) -> [MonitoringModule] {
        switch section {
        case .overview: return [.cpu, .memory, .disk, .network, .process, .aiUsage]
        case .cpu: return [.cpu, .process, .thermal, .numericTemperature]
        case .memory: return [.memory, .process]
        case .disk: return [.disk]
        case .network: return [.network, .networkProcessAttribution]
        case .gpu: return [.gpu, .thermal, .numericTemperature]
        case .battery: return [.battery, .accessoryPower]
        case .aiUsage: return [.aiUsage]
        case .settings: return []
        }
    }

    /// Overview 健康判定所需的常驻信号。不含 process 与任何轮询型昂贵模块；thermal 仅持有系统通知订阅。
    static let overviewHealthModules: [MonitoringModule] = [.cpu, .memory, .disk, .network, .thermal]
}
