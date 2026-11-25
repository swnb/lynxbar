import Foundation

/// 可兼容数值传感器的独立按需循环。默认适配器为 unavailable：没有 timer、sleep
/// 或注册表读取。只有经硬件矩阵批准且声明 available 的适配器才启动循环。
/// stop 撤下当前数值并保留来源/最后观察时刻为 stale；restart 的首采样返回前也
/// 不显示旧温度。取消后的异步返回与旧代循环不得写回或继续安排读取。
@MainActor
final class NumericTemperatureViewModel: ObservableObject, DemandDrivenModule {
    @Published private(set) var snapshot: TemperatureSensorSnapshot
    private(set) var isSamplingActive = false

    private let settings: Settings
    private let adapter: any TemperatureSensorAdapter
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private var task: Task<Void, Never>?
    private var samplingGeneration: UInt64 = 0

    init(
        settings: Settings,
        adapter: any TemperatureSensorAdapter = UnavailableTemperatureSensorAdapter(),
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.settings = settings
        self.adapter = adapter
        self.sleeper = sleeper
        snapshot = TemperatureSensorSnapshot(
            source: adapter.source,
            availability: adapter.declaredAvailability == .available
                ? .unavailable : adapter.declaredAvailability,
            aggregates: [],
            observedAt: nil
        )
    }

    func startSampling() {
        guard !isSamplingActive,
              adapter.declaredAvailability == .available else { return }
        isSamplingActive = true
        samplingGeneration &+= 1
        let generation = samplingGeneration
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, isSamplingActive,
                      samplingGeneration == generation else { return }
                let next = await adapter.sample(at: Date())
                guard !Task.isCancelled, isSamplingActive,
                      samplingGeneration == generation else { return }
                snapshot = next
                do {
                    try await sleeper(SamplingPolicy.liveInterval(settings.updateInterval))
                } catch {
                    return
                }
            }
        }
    }

    func stopSampling() {
        samplingGeneration &+= 1
        isSamplingActive = false
        task?.cancel()
        task = nil
        if snapshot.availability == .available {
            snapshot = TemperatureSensorSnapshot(source: snapshot.source,
                availability: .stale, aggregates: [], observedAt: snapshot.observedAt)
        }
    }
}
