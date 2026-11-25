import Dispatch
import Foundation

@MainActor
final class MemoryViewModel: ObservableObject, DemandDrivenModule {
    static let allowedRanges: [HistoryRange] = [.minute, .hour, .fiveHours, .day]

    @Published private(set) var snapshot = MemorySnapshot()
    /// 最近一次数值采样提交的来源时间（UTC Date）；nil 为尚未采样。
    /// 仅真实采样路径更新，未知快照也提交以隐藏旧值。历史、范围、压力或
    /// 展示元数据的发布不能延长 freshness；写入前必须先安装对应 snapshot。
    @Published private(set) var lastNumericSampleAt: Date?
    @Published private(set) var pressure: MemoryPressureLevel = .unknown
    @Published private(set) var selectedRange: HistoryRange = .minute
    @Published private(set) var historyResult = MetricHistoryResult.empty(.minute)
    @Published private(set) var recentHistory = MetricHistoryResult.empty(.minute)

    var history: [Double] { historyResult.points.map(\.value) }

    private let settings: Settings
    private let historyStore: MetricHistoryStore
    private var task: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?

    init(
        settings: Settings,
        historyStore: MetricHistoryStore = .shared
    ) {
        self.settings = settings
        self.historyStore = historyStore
        startPressureMonitor()
    }

    deinit {
        pressureSource?.cancel()
    }

    func startSampling() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let next = await Task.detached { MemoryProvider.sample() }.value
                let timestamp = Date()
                await self.historyStore.record(.memoryUsage, value: next.usage, at: timestamp)
                let history = await self.historyStore.query(
                    .memoryUsage,
                    range: self.selectedRange,
                    now: timestamp
                )
                let recent = self.selectedRange == .minute
                    ? history
                    : await self.historyStore.query(.memoryUsage, range: .minute, now: timestamp)
                self.snapshot = next
                self.lastNumericSampleAt = timestamp
                self.historyResult = history
                self.recentHistory = recent
                try? await Task.sleep(
                    for: .seconds(SamplingPolicy.liveInterval(self.settings.updateInterval))
                )
            }
        }
    }

    func selectRange(_ range: HistoryRange) {
        guard Self.allowedRanges.contains(range) else { return }
        selectedRange = range
        Task { [weak self] in
            guard let self else { return }
            self.historyResult = await self.historyStore.query(.memoryUsage, range: range)
        }
    }

    func stopSampling() {
        task?.cancel()
        task = nil
    }

    private func startPressureMonitor() {
        pressureSource?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let event = source.data
            let level: MemoryPressureLevel
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else if event.contains(.normal) {
                level = .normal
            } else {
                level = .unknown
            }
            Task { @MainActor [weak self] in
                self?.pressure = level
            }
        }
        source.resume()
        pressureSource = source
    }
}
