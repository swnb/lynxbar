import Foundation

@MainActor
final class BatteryViewModel: ObservableObject, DemandDrivenModule {
    @Published private(set) var snapshot = BatterySnapshot()
    /// 最近一次数值采样提交的来源时间（UTC Date）；nil 为尚未采样。
    /// 仅真实采样路径更新，未知快照也提交以隐藏旧值。历史、范围、压力或
    /// 展示元数据的发布不能延长 freshness；写入前必须先安装对应 snapshot。
    @Published private(set) var lastNumericSampleAt: Date?

    private let settings: Settings
    private let sampler: @Sendable () async -> BatterySnapshot
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private var task: Task<Void, Never>?

    init(
        settings: Settings,
        sampler: (@Sendable () async -> BatterySnapshot)? = nil,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.settings = settings
        self.sampler = sampler ?? {
            await Task.detached { BatteryProvider.sample() }.value
        }
        self.sleeper = sleeper
    }

    func startSampling() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                apply(await sampler(), at: Date())
                do {
                    try await sleeper(
                        SamplingPolicy.liveInterval(settings.updateInterval)
                    )
                } catch {
                    return
                }
            }
        }
    }

    func stopSampling() {
        task?.cancel()
        task = nil
    }

    func apply(_ next: BatterySnapshot, at timestamp: Date) {
        snapshot = next
        lastNumericSampleAt = timestamp
    }
}
