import Combine
import Foundation

/// Explicit UI state machine for AI subscription quota monitoring ("never show 0 when unknown").
enum AIUsageState: Equatable, Sendable {
    case disabled
    case loading
    case loaded(AIProviderQuotaSnapshot)
    case stale(snapshot: AIProviderQuotaSnapshot, lastError: AIUsageFetchError)
    case error(AIUsageFetchError)
}

/// Demand-driven view model coordinating privacy-gated Claude subscription quota polling,
/// single-flight deduplication, cooldown/throttling, 429 exponential backoff, and stale-while-error retention.
@MainActor
final class AIUsageViewModel: ObservableObject, DemandDrivenModule {
    static let normalPollInterval: TimeInterval = 300
    static let cooldownInterval: TimeInterval = 60
    static let manualRefreshThrottle: TimeInterval = 5
    static let backoffSchedule: [TimeInterval] = [300, 600, 1_200, 1_800]
    static let menuBarTTL: TimeInterval = 900

    @Published private(set) var state: AIUsageState
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastSuccessfulFetchAt: Date?
    @Published private(set) var lastError: AIUsageFetchError?
    @Published private(set) var displayStyle: AIQuotaDisplayStyle

    /// Returns the most recent valid quota snapshot when loaded or retained in stale-while-error state.
    var currentSnapshot: AIProviderQuotaSnapshot? {
        switch state {
        case .loaded(let snapshot), .stale(let snapshot, _):
            return snapshot
        case .disabled, .loading, .error:
            return nil
        }
    }

    /// Indicates whether AI quota monitoring is currently opted in by the user.
    var isEnabled: Bool { settings.aiUsageEnabled }

    private let settings: Settings
    private let provider: any AIUsageProvider
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    private var isRunning = false
    private var pollingTask: Task<Void, Never>?
    private var inFlightFetchTask: Task<Result<AIProviderQuotaSnapshot, AIUsageFetchError>, Never>?
    private var samplingGeneration: UInt64 = 0
    private var consecutiveFailureCount = 0
    private var lastManualRefreshAt: Date?
    private var lastCachedSnapshot: AIProviderQuotaSnapshot?
    private var cancellables = Set<AnyCancellable>()

    /// Creates an `AIUsageViewModel` with injectable provider, sleeper, and clock for deterministic testing.
    init(
        settings: Settings = .shared,
        provider: any AIUsageProvider = ClaudeUsageProvider(),
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.provider = provider
        self.sleeper = sleeper
        self.now = now
        self.displayStyle = settings.aiQuotaDisplayStyle
        self.state = settings.aiUsageEnabled ? .loading : .disabled

        settings.$aiUsageEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                // `@Published` emits in `willSet`; always consume `enabled` directly rather than re-reading `settings`.
                self?.handleEnabledChange(enabled)
            }
            .store(in: &cancellables)

        settings.$aiQuotaDisplayStyle
            .removeDuplicates()
            .sink { [weak self] style in
                self?.displayStyle = style
            }
            .store(in: &cancellables)
    }

    /// Begins demand-driven quota sampling if `aiUsageEnabled` is true, honoring the 60s cooldown window.
    func startSampling() {
        guard !isRunning else { return }
        isRunning = true
        guard settings.aiUsageEnabled else {
            state = .disabled
            return
        }
        schedulePolling(respectCooldown: true, initialWait: nil)
    }

    /// Stops periodic sampling without clearing the cached snapshot or accumulated UI state.
    func stopSampling() {
        guard isRunning else { return }
        isRunning = false
        samplingGeneration &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        inFlightFetchTask?.cancel()
        inFlightFetchTask = nil
        isRefreshing = false
    }

    /// Triggers an explicit user refresh subject to single-flight deduplication and a 5s manual throttle.
    func refreshNow() {
        Task { @MainActor [weak self] in
            await self?.performManualRefresh()
        }
    }

    /// Awaits an explicit user refresh, deduplicating concurrent calls and honoring the 5s manual throttle.
    @discardableResult
    func performManualRefresh() async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError>? {
        guard settings.aiUsageEnabled else {
            state = .disabled
            return .failure(.disabled)
        }

        if let existing = inFlightFetchTask {
            return await existing.value
        }

        let currentTime = now()
        if let lastManual = lastManualRefreshAt,
           currentTime.timeIntervalSince(lastManual) < Self.manualRefreshThrottle {
            return nil
        }
        lastManualRefreshAt = currentTime

        samplingGeneration &+= 1
        let generation = samplingGeneration
        pollingTask?.cancel()
        pollingTask = nil

        let result = await runSingleFlightFetch(generation: generation)
        guard isRunning, samplingGeneration == generation, settings.aiUsageEnabled else {
            return result
        }
        if let nextDelay = nextPollDelay(after: result) {
            schedulePolling(respectCooldown: false, initialWait: nextDelay)
        }
        return result
    }

    /// Handles live changes to `Settings.aiUsageEnabled`, clearing cached data immediately when disabled.
    private func handleEnabledChange(_ enabled: Bool) {
        if !enabled {
            samplingGeneration &+= 1
            pollingTask?.cancel()
            pollingTask = nil
            inFlightFetchTask?.cancel()
            inFlightFetchTask = nil
            isRefreshing = false
            consecutiveFailureCount = 0
            lastManualRefreshAt = nil
            lastCachedSnapshot = nil
            lastSuccessfulFetchAt = nil
            lastError = nil
            state = .disabled
            return
        }

        consecutiveFailureCount = 0
        if lastCachedSnapshot == nil && lastError == nil {
            state = .loading
        }
        if isRunning {
            schedulePolling(respectCooldown: true, initialWait: nil)
        }
    }

    /// Starts the background polling loop for the current generation, optionally waiting `initialWait` first.
    private func schedulePolling(respectCooldown: Bool, initialWait: TimeInterval?) {
        samplingGeneration &+= 1
        let generation = samplingGeneration
        pollingTask?.cancel()

        pollingTask = Task { [weak self] in
            guard let self else { return }

            if let initialWait {
                do {
                    try await self.sleeper(initialWait)
                } catch {
                    return
                }
            } else if respectCooldown,
                      self.lastError == nil,
                      let lastSuccess = self.lastSuccessfulFetchAt,
                      let cached = self.lastCachedSnapshot {
                let elapsed = self.now().timeIntervalSince(lastSuccess)
                if elapsed >= 0, elapsed < Self.cooldownInterval {
                    self.state = .loaded(cached)
                    self.lastError = nil
                    let waitRemaining = max(1, Self.normalPollInterval - elapsed)
                    do {
                        try await self.sleeper(waitRemaining)
                    } catch {
                        return
                    }
                }
            }

            while !Task.isCancelled {
                guard self.isRunning, self.samplingGeneration == generation else { return }
                let outcome = await self.runSingleFlightFetch(generation: generation)
                guard !Task.isCancelled, self.isRunning, self.samplingGeneration == generation else {
                    return
                }
                guard let delay = self.nextPollDelay(after: outcome) else {
                    self.pollingTask = nil
                    return
                }
                do {
                    try await self.sleeper(delay)
                } catch {
                    return
                }
            }
        }
    }

    /// Executes at most one concurrent upstream fetch and applies the outcome if `generation` is still current.
    private func runSingleFlightFetch(
        generation: UInt64
    ) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        if let existing = inFlightFetchTask {
            return await existing.value
        }

        let fetchTime = now()
        if lastCachedSnapshot == nil && lastError == nil {
            state = .loading
        }
        isRefreshing = true

        let provider = self.provider
        let task = Task<Result<AIProviderQuotaSnapshot, AIUsageFetchError>, Never> {
            await provider.fetchQuota(now: fetchTime)
        }
        inFlightFetchTask = task
        let result = await task.value

        if inFlightFetchTask == task {
            inFlightFetchTask = nil
            isRefreshing = false
        }

        guard settings.aiUsageEnabled else {
            state = .disabled
            return .failure(.disabled)
        }
        guard generation == samplingGeneration else {
            return result
        }

        applyFetchResult(result)
        return result
    }

    /// Updates `state`, `lastCachedSnapshot`, `lastSuccessfulFetchAt`, and `lastError` from a fetch result.
    private func applyFetchResult(_ result: Result<AIProviderQuotaSnapshot, AIUsageFetchError>) {
        switch result {
        case .success(let snapshot):
            consecutiveFailureCount = 0
            lastCachedSnapshot = snapshot
            lastSuccessfulFetchAt = snapshot.fetchedAt
            lastError = nil
            state = .loaded(snapshot)

        case .failure(let error):
            if case .disabled = error {
                state = .disabled
                return
            }
            lastError = error
            if let cached = lastCachedSnapshot {
                state = .stale(snapshot: cached, lastError: error)
            } else {
                state = .error(error)
            }
        }
    }

    /// Computes the next polling delay or returns `nil` when auto-retry should stop.
    private func nextPollDelay(after result: Result<AIProviderQuotaSnapshot, AIUsageFetchError>) -> TimeInterval? {
        switch result {
        case .success:
            consecutiveFailureCount = 0
            return Self.normalPollInterval

        case .failure(let error):
            guard !error.stopsAutomaticRetry else {
                return nil
            }
            let index = min(consecutiveFailureCount, Self.backoffSchedule.count - 1)
            let backoffDelay = Self.backoffSchedule[index]
            consecutiveFailureCount += 1

            if case .rateLimited(let retryAfter) = error,
               let retryAfter,
               retryAfter.isFinite,
               retryAfter > 0 {
                return retryAfter
            }
            return backoffDelay
        }
    }
}
