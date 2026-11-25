import Combine
import Foundation

/// 公开热状态的通知订阅者。该枚举描述系统散热压力，不推算摄氏温度；
/// 通知没有心跳，活跃订阅下长时间不变仍是当前状态，不能按数值采样间隔判陈旧。
/// numericTemperature 是独立 demand 模块，Overview 订阅本模块不会启动传感器轮询。
@MainActor
final class ThermalViewModel: ObservableObject, DemandDrivenModule {
    @Published private(set) var snapshot = ThermalSnapshot()
    @Published private(set) var isPublicObservationActive = false
    let numericTemperature: NumericTemperatureViewModel

    private let notificationCenter: NotificationCenter
    private let stateSampler: @MainActor () -> SystemThermalState
    private var stateObservation: AnyCancellable?
    private var numericObservation: AnyCancellable?
    private var observationGeneration: UInt64 = 0

    init(
        settings: Settings,
        notificationCenter: NotificationCenter = .default,
        stateSampler: @escaping @MainActor () -> SystemThermalState = {
            ThermalProvider.currentState()
        },
        temperatureAdapter: any TemperatureSensorAdapter =
            UnavailableTemperatureSensorAdapter(),
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.notificationCenter = notificationCenter
        self.stateSampler = stateSampler
        numericTemperature = NumericTemperatureViewModel(
            settings: settings,
            adapter: temperatureAdapter,
            sleeper: sleeper
        )
        numericObservation = numericTemperature.$snapshot.sink { [weak self] next in
            self?.snapshot.temperatures = next
        }
    }

    func startSampling() {
        guard !isPublicObservationActive else { return }
        observationGeneration &+= 1
        let generation = observationGeneration
        stateObservation = notificationCenter.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self, isPublicObservationActive,
                  observationGeneration == generation else { return }
            samplePublicState(at: Date())
        }
        isPublicObservationActive = true
        samplePublicState(at: Date())
    }

    func stopSampling() {
        observationGeneration &+= 1
        isPublicObservationActive = false
        stateObservation?.cancel()
        stateObservation = nil
    }

    private func samplePublicState(at now: Date) {
        snapshot.publicState = stateSampler()
        snapshot.publicStateObservedAt = now
    }
}
