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

/// Per-provider UI state snapshot exposed by `AIUsageViewModel` for multi-provider views.
struct AIUsageProviderState: Equatable, Sendable {
    let providerID: AIUsageProviderID
    var state: AIUsageState
    var isRefreshing: Bool
    var lastSuccessfulFetchAt: Date?
    var lastError: AIUsageFetchError?

    /// Returns the most recent valid quota snapshot when loaded or retained in stale-while-error state.
    var currentSnapshot: AIProviderQuotaSnapshot? {
        switch state {
        case .loaded(let snapshot), .stale(let snapshot, _):
            return snapshot
        case .disabled, .loading, .error:
            return nil
        }
    }

    /// Creates a clean disabled state snapshot for `providerID`.
    static func disabled(for providerID: AIUsageProviderID) -> Self {
        AIUsageProviderState(
            providerID: providerID,
            state: .disabled,
            isRefreshing: false,
            lastSuccessfulFetchAt: nil,
            lastError: nil
        )
    }
}

/// Demand-driven view model coordinating privacy-gated multi-provider AI subscription quota polling,
/// per-provider single-flight deduplication, cooldown/throttling, 429 exponential backoff, and stale-while-error retention.
@MainActor
final class AIUsageViewModel: ObservableObject, DemandDrivenModule {
    static let normalPollInterval: TimeInterval = 300
    static let cooldownInterval: TimeInterval = 60
    static let manualRefreshThrottle: TimeInterval = 5
    static let backoffSchedule: [TimeInterval] = [300, 600, 1_200, 1_800]
    static let maxRetryAfterDelay: TimeInterval = 3_600
    static let menuBarTTL: TimeInterval = 900

    /// Isolated per-provider background task and backoff/cache runtime state.
    private struct ProviderRuntime: Sendable {
        var pollingTask: Task<Void, Never>?
        var inFlightFetchTask: Task<Result<AIProviderQuotaSnapshot, AIUsageFetchError>, Never>?
        var samplingGeneration: UInt64 = 0
        var consecutiveFailureCount: Int = 0
        var lastManualRefreshAt: Date?
        var lastCachedSnapshot: AIProviderQuotaSnapshot?
    }

    @Published private(set) var providerStates: [AIUsageProviderID: AIUsageProviderState]
    @Published private(set) var displayStyle: AIQuotaDisplayStyle

    // MARK: - Temporary Single-Provider Compatibility Shims

    @Published private(set) var state: AIUsageState
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastSuccessfulFetchAt: Date?
    @Published private(set) var lastError: AIUsageFetchError?

    /// Returns the representative quota snapshot when loaded or retained in stale-while-error state.
    var currentSnapshot: AIProviderQuotaSnapshot? {
        switch state {
        case .loaded(let snapshot), .stale(let snapshot, _):
            return snapshot
        case .disabled, .loading, .error:
            return nil
        }
    }

    /// Indicates whether at least one AI quota provider is currently opted in by the user.
    var isEnabled: Bool { !enabledProviders.isEmpty }

    private let settings: Settings
    private let providers: [AIUsageProviderID: any AIUsageProvider]
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    private var isRunning = false
    private var enabledProviders: Set<AIUsageProviderID>
    private var runtimeStates: [AIUsageProviderID: ProviderRuntime]
    private var cancellables = Set<AnyCancellable>()

    /// Creates a multi-provider `AIUsageViewModel` with injectable provider map, sleeper, and clock.
    init(
        settings: Settings = .shared,
        providers: [AIUsageProviderID: any AIUsageProvider] = [
            .claude: CodexBarUsageProvider(providerID: .claude),
            .codex: CodexBarUsageProvider(providerID: .codex),
            .antigravity: CodexBarUsageProvider(providerID: .antigravity),
        ],
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.providers = providers
        self.sleeper = sleeper
        self.now = now
        self.displayStyle = settings.aiQuotaDisplayStyle

        let initialEnabled = Set(settings.enabledAIUsageProviders)
        self.enabledProviders = initialEnabled

        var initialStates: [AIUsageProviderID: AIUsageProviderState] = [:]
        var initialRuntimes: [AIUsageProviderID: ProviderRuntime] = [:]
        for providerID in AIUsageProviderID.allCases {
            initialRuntimes[providerID] = ProviderRuntime()
            if initialEnabled.contains(providerID), providers[providerID] != nil {
                initialStates[providerID] = AIUsageProviderState(
                    providerID: providerID,
                    state: .loading,
                    isRefreshing: false,
                    lastSuccessfulFetchAt: nil,
                    lastError: nil
                )
            } else {
                initialStates[providerID] = .disabled(for: providerID)
            }
        }
        self.providerStates = initialStates
        self.runtimeStates = initialRuntimes

        let initialRep = AIUsageProviderID.allCases
            .first { initialEnabled.contains($0) && providers[$0] != nil }
            .flatMap { initialStates[$0] }
        self.state = initialRep?.state ?? .disabled
        self.lastSuccessfulFetchAt = initialRep?.lastSuccessfulFetchAt
        self.lastError = initialRep?.lastError

        subscribeToSettings()
    }

    /// Creates an `AIUsageViewModel` from an array of provider instances keyed by their `id`.
    convenience init(
        settings: Settings = .shared,
        providers: [any AIUsageProvider],
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let providerMap = Dictionary(
            providers.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        self.init(
            settings: settings,
            providers: providerMap,
            sleeper: sleeper,
            now: now
        )
    }

    /// Creates an `AIUsageViewModel` backed by a single injected provider instance.
    convenience init(
        settings: Settings = .shared,
        provider: any AIUsageProvider,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            settings: settings,
            providers: [provider.id: provider],
            sleeper: sleeper,
            now: now
        )
    }

    /// Cancels all per-provider polling and in-flight fetch tasks on deallocation.
    deinit {
        for runtime in runtimeStates.values {
            runtime.pollingTask?.cancel()
            runtime.inFlightFetchTask?.cancel()
        }
    }

    // MARK: - Per-Provider Query APIs

    /// Returns the current UI state for `providerID`.
    func state(for providerID: AIUsageProviderID) -> AIUsageState {
        providerStates[providerID]?.state ?? .disabled
    }

    /// Returns the latest valid or stale-retained quota snapshot for `providerID`, if available.
    func snapshot(for providerID: AIUsageProviderID) -> AIProviderQuotaSnapshot? {
        providerStates[providerID]?.currentSnapshot
    }

    /// Returns whether `providerID` currently has an upstream fetch in flight.
    func isRefreshing(for providerID: AIUsageProviderID) -> Bool {
        providerStates[providerID]?.isRefreshing ?? false
    }

    /// Returns the timestamp of the most recent successful fetch for `providerID`.
    func lastSuccessfulFetchAt(for providerID: AIUsageProviderID) -> Date? {
        providerStates[providerID]?.lastSuccessfulFetchAt
    }

    /// Returns the most recent fetch error for `providerID`, if any.
    func lastError(for providerID: AIUsageProviderID) -> AIUsageFetchError? {
        providerStates[providerID]?.lastError
    }

    /// Returns whether `providerID` is currently enabled in user preferences.
    func isEnabled(for providerID: AIUsageProviderID) -> Bool {
        enabledProviders.contains(providerID)
    }

    /// Updates the opt-in preference for `providerID` on this view model's injected `Settings`.
    func setEnabled(_ enabled: Bool, for providerID: AIUsageProviderID) {
        settings.setAIProviderEnabled(enabled, for: providerID)
    }

    /// Updates the quota display style (`remaining` vs `used`) on this view model's injected `Settings`.
    func setDisplayStyle(_ style: AIQuotaDisplayStyle) {
        settings.aiQuotaDisplayStyle = style
    }

    /// Returns currently enabled provider identifiers in canonical `AIUsageProviderID.allCases` order.
    var enabledProviderIDs: [AIUsageProviderID] {
        AIUsageProviderID.allCases.filter { enabledProviders.contains($0) }
    }

    /// Returns current or stale-retained snapshots for enabled providers in `enabledProviderIDs` order.
    var activeSnapshots: [AIProviderQuotaSnapshot] {
        enabledProviderIDs.compactMap { snapshot(for: $0) }
    }

    // MARK: - DemandDrivenModule Lifecycle

    /// Begins demand-driven quota sampling for all enabled providers, honoring each provider's 60s cooldown window.
    func startSampling() {
        guard !isRunning else { return }
        isRunning = true
        for providerID in AIUsageProviderID.allCases {
            if isEnabled(for: providerID), providers[providerID] != nil {
                schedulePolling(for: providerID, respectCooldown: true, initialWait: nil)
            } else {
                resetToDisabled(for: providerID)
            }
        }
        syncCompatibilityShims()
    }

    /// Stops periodic and in-flight sampling across all providers without clearing cached snapshots or accumulated state.
    func stopSampling() {
        guard isRunning else { return }
        isRunning = false
        for providerID in AIUsageProviderID.allCases {
            var runtime = runtimeStates[providerID] ?? ProviderRuntime()
            runtime.samplingGeneration &+= 1
            runtime.pollingTask?.cancel()
            runtime.pollingTask = nil
            runtime.inFlightFetchTask?.cancel()
            runtime.inFlightFetchTask = nil
            runtimeStates[providerID] = runtime

            if var current = providerStates[providerID], current.isRefreshing {
                current.isRefreshing = false
                providerStates[providerID] = current
            }
        }
        syncCompatibilityShims()
    }

    // MARK: - Manual Refresh

    /// Result of synchronously preparing a single-provider manual refresh on `@MainActor`.
    private enum ManualRefreshPreparation {
        case fetch(
            providerID: AIUsageProviderID,
            task: Task<Result<AIProviderQuotaSnapshot, AIUsageFetchError>, Never>,
            generation: UInt64,
            didStartNewFetch: Bool
        )
        case immediate(Result<AIProviderQuotaSnapshot, AIUsageFetchError>?)
    }

    /// Triggers an explicit user refresh across all currently enabled providers.
    func refreshNow() {
        refreshNow(for: nil)
    }

    /// Triggers an explicit user refresh for `providerID`, or across all enabled providers when `providerID` is `nil`.
    func refreshNow(for providerID: AIUsageProviderID?) {
        let targets: [AIUsageProviderID]
        if let providerID {
            targets = [providerID]
        } else {
            targets = enabledProviderIDs.filter { providers[$0] != nil }
            if targets.isEmpty {
                syncCompatibilityShims()
                return
            }
        }

        let preparations = targets.map { prepareManualRefresh(for: $0) }
        for preparation in preparations {
            guard case let .fetch(targetID, fetchTask, generation, didStartNewFetch) = preparation else {
                continue
            }
            // Scope strong `self` strictly after `await fetchTask.value` so manual refreshes never retain `self` across `await`.
            Task { @MainActor [weak self] in
                let result = await fetchTask.value
                _ = self?.finishManualRefresh(
                    result,
                    for: targetID,
                    task: fetchTask,
                    generation: generation,
                    didStartNewFetch: didStartNewFetch
                )
            }
        }
    }

    /// Awaits an explicit user refresh across all currently enabled providers.
    @discardableResult
    func performManualRefresh() async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError>? {
        await performManualRefresh(for: nil)
    }

    /// Awaits an explicit user refresh for `providerID`, or concurrently for all enabled providers when `providerID` is `nil`.
    @discardableResult
    func performManualRefresh(
        for providerID: AIUsageProviderID?
    ) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError>? {
        if let providerID {
            switch prepareManualRefresh(for: providerID) {
            case .immediate(let outcome):
                return outcome
            case .fetch(let targetID, let fetchTask, let generation, let didStartNewFetch):
                let result = await fetchTask.value
                return finishManualRefresh(
                    result,
                    for: targetID,
                    task: fetchTask,
                    generation: generation,
                    didStartNewFetch: didStartNewFetch
                )
            }
        }

        let targets = enabledProviderIDs.filter { providers[$0] != nil }
        guard !targets.isEmpty else {
            syncCompatibilityShims()
            return .failure(.disabled)
        }

        var preparationsByID: [AIUsageProviderID: ManualRefreshPreparation] = [:]
        var resultsByID: [AIUsageProviderID: Result<AIProviderQuotaSnapshot, AIUsageFetchError>] = [:]
        for targetID in targets {
            let preparation = prepareManualRefresh(for: targetID)
            preparationsByID[targetID] = preparation
            if case .immediate(let outcome?) = preparation {
                resultsByID[targetID] = outcome
            }
        }

        await withTaskGroup(of: (AIUsageProviderID, Result<AIProviderQuotaSnapshot, AIUsageFetchError>).self) { group in
            for targetID in targets {
                if case let .fetch(_, fetchTask, _, _) = preparationsByID[targetID] {
                    group.addTask {
                        let result = await fetchTask.value
                        return (targetID, result)
                    }
                }
            }
            for await (targetID, result) in group {
                if case let .fetch(_, fetchTask, generation, didStartNewFetch) = preparationsByID[targetID],
                   let outcome = finishManualRefresh(
                       result,
                       for: targetID,
                       task: fetchTask,
                       generation: generation,
                       didStartNewFetch: didStartNewFetch
                   ) {
                    resultsByID[targetID] = outcome
                }
            }
        }

        if resultsByID.isEmpty {
            return nil
        }

        for targetID in targets {
            if case .success = resultsByID[targetID] {
                return resultsByID[targetID]
            }
        }
        for targetID in targets {
            if let result = resultsByID[targetID] {
                return result
            }
        }
        return nil
    }

    /// Synchronously validates preconditions, enforces single-flight/5s throttle, and creates/joins `inFlightFetchTask` for `providerID`.
    private func prepareManualRefresh(for providerID: AIUsageProviderID) -> ManualRefreshPreparation {
        guard isEnabled(for: providerID), let provider = providers[providerID] else {
            resetToDisabled(for: providerID)
            syncCompatibilityShims()
            return .immediate(.failure(.disabled))
        }

        if let existing = runtimeStates[providerID]?.inFlightFetchTask {
            let generation = runtimeStates[providerID]?.samplingGeneration ?? 0
            return .fetch(
                providerID: providerID,
                task: existing,
                generation: generation,
                didStartNewFetch: false
            )
        }

        let currentTime = now()
        if let lastManual = runtimeStates[providerID]?.lastManualRefreshAt {
            let elapsed = currentTime.timeIntervalSince(lastManual)
            if elapsed >= 0, elapsed < Self.manualRefreshThrottle {
                return .immediate(nil)
            }
        }

        var runtime = runtimeStates[providerID] ?? ProviderRuntime()
        runtime.lastManualRefreshAt = currentTime
        runtime.samplingGeneration &+= 1
        let generation = runtime.samplingGeneration
        runtime.pollingTask?.cancel()
        runtime.pollingTask = nil
        runtimeStates[providerID] = runtime

        let fetchTask = makeInFlightFetchTask(for: providerID, provider: provider)
        return .fetch(
            providerID: providerID,
            task: fetchTask,
            generation: generation,
            didStartNewFetch: true
        )
    }

    /// Synchronously commits a completed manual refresh fetch outcome on `@MainActor` and reschedules polling if running.
    private func finishManualRefresh(
        _ result: Result<AIProviderQuotaSnapshot, AIUsageFetchError>,
        for providerID: AIUsageProviderID,
        task: Task<Result<AIProviderQuotaSnapshot, AIUsageFetchError>, Never>,
        generation: UInt64,
        didStartNewFetch: Bool
    ) -> Result<AIProviderQuotaSnapshot, AIUsageFetchError>? {
        guard didStartNewFetch else {
            guard isEnabled(for: providerID), providers[providerID] != nil else {
                return .failure(.disabled)
            }
            return result
        }

        clearInFlightFetchIfMatching(task, for: providerID)

        guard isEnabled(for: providerID), providers[providerID] != nil else {
            resetToDisabled(for: providerID)
            syncCompatibilityShims()
            return .failure(.disabled)
        }
        guard generation == runtimeStates[providerID]?.samplingGeneration else {
            syncCompatibilityShims()
            return result
        }

        applyFetchResult(result, for: providerID)
        syncCompatibilityShims()

        if isRunning, let nextDelay = nextPollDelay(for: providerID, after: result) {
            schedulePolling(for: providerID, respectCooldown: false, initialWait: nextDelay)
        }
        return result
    }

    // MARK: - Settings Observation & Isolation

    /// Subscribes to per-provider opt-in toggles and display style changes using Combine-emitted values directly.
    private func subscribeToSettings() {
        settings.$claudeUsageEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                // `@Published` emits in `willSet`; consume `enabled` directly without re-reading `settings`.
                self?.handleProviderEnabledChange(.claude, enabled: enabled)
            }
            .store(in: &cancellables)

        settings.$codexUsageEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                // `@Published` emits in `willSet`; consume `enabled` directly without re-reading `settings`.
                self?.handleProviderEnabledChange(.codex, enabled: enabled)
            }
            .store(in: &cancellables)

        settings.$antigravityUsageEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                // `@Published` emits in `willSet`; consume `enabled` directly without re-reading `settings`.
                self?.handleProviderEnabledChange(.antigravity, enabled: enabled)
            }
            .store(in: &cancellables)

        settings.$aiQuotaDisplayStyle
            .removeDuplicates()
            .sink { [weak self] style in
                self?.displayStyle = style
            }
            .store(in: &cancellables)
    }

    /// Handles live changes for a single provider toggle without disturbing sibling providers.
    private func handleProviderEnabledChange(_ providerID: AIUsageProviderID, enabled: Bool) {
        if !enabled {
            enabledProviders.remove(providerID)
            resetToDisabled(for: providerID)
            syncCompatibilityShims()
            return
        }

        enabledProviders.insert(providerID)
        guard providers[providerID] != nil else {
            resetToDisabled(for: providerID)
            syncCompatibilityShims()
            return
        }

        var runtime = runtimeStates[providerID] ?? ProviderRuntime()
        runtime.consecutiveFailureCount = 0
        runtimeStates[providerID] = runtime

        if runtime.lastCachedSnapshot == nil && providerStates[providerID]?.lastError == nil {
            var nextState = providerStates[providerID] ?? .disabled(for: providerID)
            nextState.state = .loading
            nextState.isRefreshing = false
            nextState.lastSuccessfulFetchAt = nil
            nextState.lastError = nil
            providerStates[providerID] = nextState
        }
        syncCompatibilityShims()

        if isRunning {
            schedulePolling(for: providerID, respectCooldown: true, initialWait: nil)
        }
    }

    /// Cancels tasks and clears cached/error state for a disabled or absent provider.
    private func resetToDisabled(for providerID: AIUsageProviderID) {
        var runtime = runtimeStates[providerID] ?? ProviderRuntime()
        runtime.samplingGeneration &+= 1
        runtime.pollingTask?.cancel()
        runtime.pollingTask = nil
        runtime.inFlightFetchTask?.cancel()
        runtime.inFlightFetchTask = nil
        runtime.consecutiveFailureCount = 0
        runtime.lastManualRefreshAt = nil
        runtime.lastCachedSnapshot = nil
        runtimeStates[providerID] = runtime

        if providerStates[providerID] != .disabled(for: providerID) {
            providerStates[providerID] = .disabled(for: providerID)
        }
    }

    // MARK: - Polling & Single-Flight Execution

    /// Result of synchronously preparing a single polling fetch iteration on `@MainActor`.
    private enum PollFetchPreparation {
        case fetch(Task<Result<AIProviderQuotaSnapshot, AIUsageFetchError>, Never>)
        case stop
    }

    /// Starts the isolated background polling loop for `providerID`, optionally waiting `initialWait` first.
    private func schedulePolling(
        for providerID: AIUsageProviderID,
        respectCooldown: Bool,
        initialWait: TimeInterval?
    ) {
        guard isEnabled(for: providerID), providers[providerID] != nil else {
            resetToDisabled(for: providerID)
            syncCompatibilityShims()
            return
        }

        var effectiveInitialWait = initialWait
        if effectiveInitialWait == nil,
           respectCooldown,
           providerStates[providerID]?.lastError == nil,
           let lastSuccess = providerStates[providerID]?.lastSuccessfulFetchAt,
           let cached = runtimeStates[providerID]?.lastCachedSnapshot {
            let elapsed = now().timeIntervalSince(lastSuccess)
            if elapsed >= 0, elapsed < Self.cooldownInterval {
                if var current = providerStates[providerID] {
                    current.state = .loaded(cached)
                    current.lastError = nil
                    providerStates[providerID] = current
                }
                syncCompatibilityShims()
                effectiveInitialWait = max(1, Self.normalPollInterval - elapsed)
            }
        }

        var runtime = runtimeStates[providerID] ?? ProviderRuntime()
        runtime.samplingGeneration &+= 1
        let generation = runtime.samplingGeneration
        runtime.pollingTask?.cancel()

        let sleeper = self.sleeper
        let task = Task { [weak self, sleeper] in
            if let effectiveInitialWait {
                guard !Task.isCancelled else { return }
                do {
                    try await sleeper(effectiveInitialWait)
                } catch {
                    return
                }
            }

            while !Task.isCancelled {
                // Scope strong `self` strictly inside synchronous `@MainActor` closures so
                // `self` is never retained across `await` suspension points (`fetchTask` or `sleeper`).
                let preparation: PollFetchPreparation = {
                    guard let self else { return .stop }
                    return self.preparePollFetch(for: providerID, generation: generation)
                }()
                guard case let .fetch(fetchTask) = preparation else {
                    return
                }

                let outcome = await fetchTask.value

                let nextDelay: TimeInterval? = {
                    guard let self else { return nil }
                    self.clearInFlightFetchIfMatching(fetchTask, for: providerID)
                    guard !Task.isCancelled else {
                        self.syncCompatibilityShims()
                        return nil
                    }
                    return self.completePollFetch(
                        outcome,
                        for: providerID,
                        generation: generation
                    )
                }()
                guard let nextDelay else {
                    return
                }

                do {
                    try await sleeper(nextDelay)
                } catch {
                    return
                }
            }
        }

        runtime.pollingTask = task
        runtimeStates[providerID] = runtime
    }

    /// Synchronously validates polling preconditions and joins or starts the single-flight fetch task for `providerID`.
    private func preparePollFetch(
        for providerID: AIUsageProviderID,
        generation: UInt64
    ) -> PollFetchPreparation {
        guard isRunning,
              isEnabled(for: providerID),
              let provider = providers[providerID],
              runtimeStates[providerID]?.samplingGeneration == generation else {
            return .stop
        }

        if let existing = runtimeStates[providerID]?.inFlightFetchTask {
            return .fetch(existing)
        }
        return .fetch(makeInFlightFetchTask(for: providerID, provider: provider))
    }

    /// Commits a completed polling fetch outcome on `@MainActor` and returns the next sleep delay, or `nil` to stop.
    private func completePollFetch(
        _ result: Result<AIProviderQuotaSnapshot, AIUsageFetchError>,
        for providerID: AIUsageProviderID,
        generation: UInt64
    ) -> TimeInterval? {
        guard isEnabled(for: providerID), providers[providerID] != nil else {
            resetToDisabled(for: providerID)
            syncCompatibilityShims()
            return nil
        }
        guard isRunning,
              generation == runtimeStates[providerID]?.samplingGeneration else {
            syncCompatibilityShims()
            return nil
        }

        applyFetchResult(result, for: providerID)
        syncCompatibilityShims()

        guard let delay = nextPollDelay(for: providerID, after: result) else {
            runtimeStates[providerID]?.pollingTask = nil
            return nil
        }
        return delay
    }

    /// Creates and registers an isolated single-flight fetch task capturing only `provider` and `fetchTime` (never `self`).
    private func makeInFlightFetchTask(
        for providerID: AIUsageProviderID,
        provider: any AIUsageProvider
    ) -> Task<Result<AIProviderQuotaSnapshot, AIUsageFetchError>, Never> {
        let fetchTime = now()
        var currentState = providerStates[providerID] ?? .disabled(for: providerID)
        if runtimeStates[providerID]?.lastCachedSnapshot == nil && currentState.lastError == nil {
            currentState.state = .loading
        }
        currentState.isRefreshing = true
        providerStates[providerID] = currentState
        syncCompatibilityShims()

        let task = Task<Result<AIProviderQuotaSnapshot, AIUsageFetchError>, Never> {
            await provider.fetchQuota(now: fetchTime)
        }
        runtimeStates[providerID]?.inFlightFetchTask = task
        return task
    }

    /// Clears `inFlightFetchTask` and resets `isRefreshing` when `task` is still the active fetch for `providerID`.
    private func clearInFlightFetchIfMatching(
        _ task: Task<Result<AIProviderQuotaSnapshot, AIUsageFetchError>, Never>,
        for providerID: AIUsageProviderID
    ) {
        guard runtimeStates[providerID]?.inFlightFetchTask == task else { return }
        runtimeStates[providerID]?.inFlightFetchTask = nil
        if var updated = providerStates[providerID] {
            updated.isRefreshing = false
            providerStates[providerID] = updated
        }
    }

    /// Updates per-provider state, cached snapshot, timestamps, and errors from a fetch result.
    private func applyFetchResult(
        _ result: Result<AIProviderQuotaSnapshot, AIUsageFetchError>,
        for providerID: AIUsageProviderID
    ) {
        var runtime = runtimeStates[providerID] ?? ProviderRuntime()
        var current = providerStates[providerID] ?? .disabled(for: providerID)

        switch result {
        case .success(let snapshot):
            runtime.consecutiveFailureCount = 0
            runtime.lastCachedSnapshot = snapshot
            current.lastSuccessfulFetchAt = snapshot.fetchedAt
            current.lastError = nil
            current.state = .loaded(snapshot)

        case .failure(let error):
            if case .disabled = error {
                resetToDisabled(for: providerID)
                return
            }
            current.lastError = error
            if let cached = runtime.lastCachedSnapshot {
                current.state = .stale(snapshot: cached, lastError: error)
            } else {
                current.state = .error(error)
            }
        }

        runtimeStates[providerID] = runtime
        providerStates[providerID] = current
    }

    /// Computes the next polling delay for `providerID` or returns `nil` when auto-retry should stop.
    private func nextPollDelay(
        for providerID: AIUsageProviderID,
        after result: Result<AIProviderQuotaSnapshot, AIUsageFetchError>
    ) -> TimeInterval? {
        var runtime = runtimeStates[providerID] ?? ProviderRuntime()
        defer { runtimeStates[providerID] = runtime }

        switch result {
        case .success:
            runtime.consecutiveFailureCount = 0
            return Self.normalPollInterval

        case .failure(let error):
            guard !error.stopsAutomaticRetry else {
                return nil
            }
            let index = min(runtime.consecutiveFailureCount, Self.backoffSchedule.count - 1)
            let backoffDelay = Self.backoffSchedule[index]
            runtime.consecutiveFailureCount += 1

            if case .rateLimited(let retryAfter) = error,
               let retryAfter,
               retryAfter.isFinite,
               retryAfter > 0 {
                return min(retryAfter, Self.maxRetryAfterDelay)
            }
            return backoffDelay
        }
    }

    /// Chooses the deterministic representative enabled provider for single-provider compatibility shims.
    private var representativeProviderID: AIUsageProviderID? {
        let active = enabledProviderIDs.filter { providers[$0] != nil }
        if let withSnapshot = active.first(where: { providerStates[$0]?.currentSnapshot != nil }) {
            return withSnapshot
        }
        return active.first
    }

    /// Synchronizes single-provider compatibility properties with `providerStates` for M2 callers.
    private func syncCompatibilityShims() {
        let active = enabledProviderIDs.filter { providers[$0] != nil }
        let anyRefreshing = active.contains { providerStates[$0]?.isRefreshing == true }
        let repState = representativeProviderID.flatMap { providerStates[$0] }

        let nextState = repState?.state ?? .disabled
        let nextLastSuccess = repState?.lastSuccessfulFetchAt
        let nextLastError = repState?.lastError

        if state != nextState { state = nextState }
        if isRefreshing != anyRefreshing { isRefreshing = anyRefreshing }
        if lastSuccessfulFetchAt != nextLastSuccess { lastSuccessfulFetchAt = nextLastSuccess }
        if lastError != nextLastError { lastError = nextLastError }
    }
}
