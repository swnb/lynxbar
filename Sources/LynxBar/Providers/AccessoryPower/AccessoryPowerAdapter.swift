import Foundation

/// 来源拥有发现/读取/断连；聚合所有者拥有需求与 freshness。
/// 主 actor 回调，start/stop 幂等；stop 释放所有扫描、连接与定时器。
@MainActor
protocol AccessoryPowerAdapter: AnyObject {
    var source: AccessoryPowerSource { get }

    func start(
        receive: @escaping @MainActor (AccessoryPowerSourceUpdate) -> Void
    )
    func refresh()
    func stop()
}

