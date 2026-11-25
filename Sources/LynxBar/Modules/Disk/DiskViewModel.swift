import Combine
import Foundation

@MainActor
final class DiskViewModel: ObservableObject, DemandDrivenModule {
    static let allowedRanges: [HistoryRange] = [.hour, .day, .week]

    @Published private(set) var snapshot = DiskSnapshot()
    @Published private(set) var selectedRange: HistoryRange = .day
    @Published private(set) var historyResult = MetricHistoryResult.empty(.day)
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastSampleFailed = false
    @Published private(set) var lastSuccessfulSampleAt: Date?

    var history: [Double] { historyResult.points.map(\.value) }

    private let historyStore: MetricHistoryStore
    private let settings: Settings
    private let sampler: @Sendable () async -> DiskSnapshot
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private var task: Task<Void, Never>?
    private var cadenceCancellable: AnyCancellable?
    private var isRunning = false
    private var samplingGeneration: UInt64 = 0
    private var activeSampleCount = 0
    private var refreshRequestPending = false

    init(
        settings: Settings,
        historyStore: MetricHistoryStore = .shared,
        sampler: (@Sendable () async -> DiskSnapshot)? = nil,
        sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) {
        self.settings = settings
        self.historyStore = historyStore
        self.sampler = sampler ?? {
            await Task.detached { DiskProvider.sample() }.value
        }
        self.sleeper = sleeper ?? { interval in
            try await Task.sleep(for: .seconds(interval))
        }
        self.cadenceCancellable = settings.$diskCapacityCadence
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.restartForCadenceChange()
                }
            }
    }

    func startSampling() {
        guard !isRunning else { return }
        isRunning = true
        scheduleSampling()
    }

    private func scheduleSampling() {
        samplingGeneration &+= 1
        let generation = samplingGeneration
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.performSample(generation: generation)
                guard !Task.isCancelled,
                      generation == self.samplingGeneration else {
                    return
                }
                let interval = SamplingPolicy.diskCapacityInterval(
                    self.settings.diskCapacityCadence
                )
                do {
                    try await self.sleeper(interval)
                } catch {
                    return
                }
            }
        }
    }

    /// 低频容量采样的显式用户入口。取消当前等待并从本次完成时间重新计时，
    /// 因此不会在手动刷新后立刻叠加一次旧计划中的自动采样。
    ///
    /// 调用点只在 Disk 面板内（DiskPanelView），面板可见即意味着
    /// .panel(.disk) demand 存在、模块在跑，因此 `guard isRunning` 不会
    /// 在真实调用路径上静默拦截。
    func refreshNow() {
        guard isRunning, !isRefreshing else { return }
        refreshRequestPending = true
        updateRefreshingState()
        scheduleSampling()
    }

    private func performSample(generation: UInt64) async {
        activeSampleCount += 1
        refreshRequestPending = false
        updateRefreshingState()
        defer {
            activeSampleCount = max(0, activeSampleCount - 1)
            updateRefreshingState()
        }

        let next = await sampler()
        guard !Task.isCancelled, generation == samplingGeneration else {
            return
        }

        // getmntinfo 失败时 Provider 返回空快照。它不是“0% 已用”，不能污染
        // 历史，也不能清掉最后一次成功的数据。
        guard next.primaryVolume != nil, next.totalCapacity > 0 else {
            lastSampleFailed = true
            return
        }

        let timestamp = Date()
        await historyStore.record(
            .diskCapacityUsage,
            value: next.usage,
            at: timestamp
        )
        guard !Task.isCancelled, generation == samplingGeneration else {
            return
        }
        let history = await historyStore.query(
            .diskCapacityUsage,
            range: selectedRange,
            now: timestamp
        )
        guard !Task.isCancelled, generation == samplingGeneration else {
            return
        }

        snapshot = next
        historyResult = history
        lastSuccessfulSampleAt = timestamp
        lastSampleFailed = false
    }

    private func updateRefreshingState() {
        isRefreshing = refreshRequestPending || activeSampleCount > 0
    }

    private func restartForCadenceChange() {
        guard isRunning else { return }
        scheduleSampling()
    }

    func selectRange(_ range: HistoryRange) {
        guard Self.allowedRanges.contains(range) else { return }
        selectedRange = range
        Task { [weak self] in
            guard let self else { return }
            self.historyResult = await self.historyStore.query(
                .diskCapacityUsage,
                range: range
            )
        }
    }

    func stopSampling() {
        isRunning = false
        samplingGeneration &+= 1
        task?.cancel()
        task = nil
        refreshRequestPending = false
        updateRefreshingState()
    }
}
