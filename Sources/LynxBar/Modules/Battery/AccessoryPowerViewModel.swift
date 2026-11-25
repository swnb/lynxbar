import Combine
import Foundation

/// 外设电量的进程级聚合所有者。控制器采用当前全局采样间隔；BLE 仅在用户显式
/// opt-in 且本模块有 demand 时启动，以 60 秒标准读取保底。来源身份不跨来源猜测合并。
/// 每个来源三周期后丢弃百分比；停止 demand 保留快照但拒绝所有旧代异步事件。
@MainActor
final class AccessoryPowerViewModel: ObservableObject, DemandDrivenModule {
    @Published private(set) var snapshot = AccessoryPowerSnapshot()

    private let settings: Settings
    private let gameControllerAdapter: any AccessoryPowerAdapter
    private let standardBLEAdapter: any AccessoryPowerAdapter
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private var updates: [AccessoryPowerSource: AccessoryPowerSourceUpdate] = [:]
    private var refreshTask: Task<Void, Never>?
    private var settingsObservation: AnyCancellable?
    private var isRunning = false
    private var isBLERunning = false
    private var samplingGeneration: UInt64 = 0
    private var bleGeneration: UInt64 = 0

    init(
        settings: Settings,
        gameControllerAdapter: (any AccessoryPowerAdapter)? = nil,
        standardBLEAdapter: (any AccessoryPowerAdapter)? = nil,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.settings = settings
        self.gameControllerAdapter = gameControllerAdapter ?? GameControllerAdapter()
        self.standardBLEAdapter = standardBLEAdapter ?? StandardBLEBatteryAdapter()
        self.sleeper = sleeper
        settingsObservation = settings.$standardBLEBatteryEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, isRunning else { return }
                // @Published 在属性赋值前发布；必须使用参数，不能重读旧 settings 值。
                updateBLELifecycle(enabled: enabled)
            }
    }

    func startSampling() {
        guard !isRunning else { return }
        isRunning = true
        samplingGeneration &+= 1
        let generation = samplingGeneration
        gameControllerAdapter.start { [weak self] update in
            guard let self, isRunning, samplingGeneration == generation,
                  update.source == .gameController else { return }
            apply(update)
        }
        updateBLELifecycle(enabled: settings.standardBLEBatteryEnabled)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await sleeper(SamplingPolicy.liveInterval(settings.updateInterval))
                } catch {
                    return
                }
                guard !Task.isCancelled, isRunning,
                      samplingGeneration == generation else { return }
                gameControllerAdapter.refresh()
                // 重新解析 freshness 不会触发 BLE 读取；其低频保底属于 BLE 适配器。
                reconcile(at: Date())
            }
        }
    }

    func stopSampling() {
        guard isRunning else { return }
        isRunning = false
        samplingGeneration &+= 1
        bleGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        gameControllerAdapter.stop()
        standardBLEAdapter.stop()
        isBLERunning = false
    }

    private func apply(_ update: AccessoryPowerSourceUpdate) {
        updates[update.source] = normalized(update)
        // 使用接收时钟而非来源时间作为“现在”，未来时间不能成为当前读数。
        reconcile(at: Date())
    }

    private func updateBLELifecycle(enabled: Bool) {
        if enabled, !isBLERunning {
            isBLERunning = true
            bleGeneration &+= 1
            let generation = bleGeneration
            standardBLEAdapter.start { [weak self] update in
                guard let self, isRunning, isBLERunning, update.source == .standardBLE,
                      bleGeneration == generation else { return }
                apply(update)
            }
        } else if !enabled {
            bleGeneration &+= 1
            if isBLERunning { standardBLEAdapter.stop() }
            isBLERunning = false
            let now = Date()
            updates[.standardBLE] = AccessoryPowerSourceUpdate(
                source: .standardBLE,
                availability: .optedOut,
                records: [],
                observedAt: now
            )
            reconcile(at: now)
        }
    }

    private func reconcile(at now: Date) {
        snapshot = AccessoryPowerMerger.merge(updates: updates, now: now)
    }

    private func normalized(_ update: AccessoryPowerSourceUpdate) -> AccessoryPowerSourceUpdate {
        let sourceInterval: TimeInterval
        switch update.source {
        case .gameController:
            sourceInterval = SamplingPolicy.liveInterval(settings.updateInterval)
        case .standardBLE:
            sourceInterval = StandardBLEBatteryAdapter.refreshInterval
        }
        return AccessoryPowerSourceUpdate(
            source: update.source,
            availability: update.availability,
            records: update.records.map { record in
                AccessoryPowerRecord(
                    identity: record.identity,
                    displayName: record.displayName,
                    availability: record.availability,
                    parts: record.parts,
                    observedAt: record.observedAt,
                    staleAfter: sourceInterval * 3
                )
            },
            observedAt: update.observedAt
        )
    }
}
