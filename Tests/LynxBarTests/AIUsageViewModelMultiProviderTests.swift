import Foundation
import XCTest
@testable import LynxBar

private actor SpyAIUsageProvider: AIUsageProvider {
    nonisolated let id: AIUsageProviderID
    private var fetchDates: [Date] = []
    private var handler: @Sendable (Date, Int) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError>

    init(
        id: AIUsageProviderID,
        handler: @escaping @Sendable (Date, Int) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError>
    ) {
        self.id = id
        self.handler = handler
    }

    func setHandler(
        _ newHandler: @escaping @Sendable (Date, Int) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError>
    ) {
        handler = newHandler
    }

    func fetchCount() -> Int {
        fetchDates.count
    }

    func recordedDates() -> [Date] {
        fetchDates
    }

    func fetchQuota(now: Date) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        fetchDates.append(now)
        let callIndex = fetchDates.count
        return await handler(now, callIndex)
    }
}

private actor FetchGate {
    private var continuation: CheckedContinuation<Result<AIProviderQuotaSnapshot, AIUsageFetchError>, Never>?

    func wait() async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        await withCheckedContinuation { cont in
            continuation = cont
        }
    }

    func hasWaiter() -> Bool {
        continuation != nil
    }

    func resolve(_ result: Result<AIProviderQuotaSnapshot, AIUsageFetchError>) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: result)
    }
}

private actor CancellableFetchGate {
    private var continuation: CheckedContinuation<Result<AIProviderQuotaSnapshot, AIUsageFetchError>, Never>?
    private var cancelled = false

    func wait() async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if Task.isCancelled {
                    cancelled = true
                    cont.resume(returning: .failure(.networkFailure("Cancelled")))
                    return
                }
                continuation = cont
            }
        } onCancel: {
            Task {
                await self.markCancelled()
            }
        }
    }

    func hasWaiter() -> Bool {
        continuation != nil
    }

    func wasCancelled() -> Bool {
        cancelled
    }

    private func markCancelled() {
        cancelled = true
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: .failure(.networkFailure("Cancelled")))
    }
}

private actor DeterministicSleeper {
    private struct Entry {
        let id: Int
        let duration: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private var entries: [Entry] = []
    private var durationsHistory: [TimeInterval] = []
    private var cancellationCount = 0
    private var nextID = 0

    func sleep(_ duration: TimeInterval) async throws {
        durationsHistory.append(duration)
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                entries.append(Entry(id: id, duration: duration, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancel(id: id)
            }
        }
    }

    func recordedDurations() -> [TimeInterval] {
        durationsHistory
    }

    func pendingDurations() -> [TimeInterval] {
        entries.map(\.duration)
    }

    func cancelledCount() -> Int {
        cancellationCount
    }

    func resumeFirst(where predicate: @Sendable (TimeInterval) -> Bool) -> Bool {
        guard let index = entries.firstIndex(where: { predicate($0.duration) }) else {
            return false
        }
        let entry = entries.remove(at: index)
        entry.continuation.resume()
        return true
    }

    private func cancel(id: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        cancellationCount += 1
        let entry = entries.remove(at: index)
        entry.continuation.resume(throwing: CancellationError())
    }
}

private func makeTestSnapshot(
    providerID: AIUsageProviderID,
    usedRatio: Double = 0.25,
    fetchedAt: Date
) -> AIProviderQuotaSnapshot {
    AIProviderQuotaSnapshot(
        providerID: providerID,
        primaryWindow: AIQuotaWindow(
            id: "\(providerID.rawValue)-primary",
            kind: .session5h,
            title: "5-hour session",
            usedRatio: usedRatio,
            resetsAt: fetchedAt.addingTimeInterval(3_600)
        ),
        secondaryWindow: nil,
        additionalWindows: [],
        extraUsage: nil,
        planLabel: "Pro",
        credits: nil,
        accountLabel: nil,
        fetchedAt: fetchedAt
    )
}

@MainActor
final class AIUsageViewModelMultiProviderTests: XCTestCase {
    private func makeSettings() -> Settings {
        let suiteName = "AIUsageViewModelMultiProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return Settings(defaults: defaults)
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testZeroIOGuaranteeWhenAllProvidersDisabled() async throws {
        let settings = makeSettings()
        let claude = SpyAIUsageProvider(id: .claude) { now, _ in
            .success(makeTestSnapshot(providerID: .claude, fetchedAt: now))
        }
        let codex = SpyAIUsageProvider(id: .codex) { now, _ in
            .success(makeTestSnapshot(providerID: .codex, fetchedAt: now))
        }
        let gemini = SpyAIUsageProvider(id: .antigravity) { now, _ in
            .success(makeTestSnapshot(providerID: .antigravity, fetchedAt: now))
        }

        let sleeper = DeterministicSleeper()
        let viewModel = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claude, .codex: codex, .antigravity: gemini],
            sleeper: { try await sleeper.sleep($0) }
        )

        viewModel.startSampling()
        for providerID in AIUsageProviderID.allCases {
            XCTAssertEqual(viewModel.state(for: providerID), .disabled)
            XCTAssertFalse(viewModel.isEnabled(for: providerID))
        }

        let codexManual = await viewModel.performManualRefresh(for: .codex)
        XCTAssertEqual(codexManual, .failure(.disabled))

        let allManual = await viewModel.performManualRefresh(for: nil)
        XCTAssertEqual(allManual, .failure(.disabled))

        viewModel.refreshNow()
        viewModel.refreshNow(for: .antigravity)
        try await Task.sleep(for: .milliseconds(30))

        let claudeCount = await claude.fetchCount()
        let codexCount = await codex.fetchCount()
        let geminiCount = await gemini.fetchCount()
        XCTAssertEqual(claudeCount, 0)
        XCTAssertEqual(codexCount, 0)
        XCTAssertEqual(geminiCount, 0)
        XCTAssertFalse(viewModel.isEnabled)
        XCTAssertEqual(viewModel.state, .disabled)
        XCTAssertTrue(viewModel.activeSnapshots.isEmpty)
    }

    func testIndependentPerProviderTogglingLeavesSiblingsUndisturbed() async throws {
        let settings = makeSettings()
        settings.claudeUsageEnabled = true

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let claude = SpyAIUsageProvider(id: .claude) { _, _ in
            .success(makeTestSnapshot(providerID: .claude, usedRatio: 0.2, fetchedAt: fixedDate))
        }
        let codex = SpyAIUsageProvider(id: .codex) { _, _ in
            .success(makeTestSnapshot(providerID: .codex, usedRatio: 0.4, fetchedAt: fixedDate))
        }
        let gemini = SpyAIUsageProvider(id: .antigravity) { _, _ in
            .success(makeTestSnapshot(providerID: .antigravity, usedRatio: 0.6, fetchedAt: fixedDate))
        }

        let sleeper = DeterministicSleeper()
        let viewModel = AIUsageViewModel(
            settings: settings,
            providers: [claude, codex, gemini],
            sleeper: { try await sleeper.sleep($0) },
            now: { fixedDate }
        )

        viewModel.startSampling()
        try await waitUntil {
            if case .loaded = viewModel.state(for: .claude) { return true }
            return false
        }

        var claudeCount = await claude.fetchCount()
        var codexCount = await codex.fetchCount()
        var geminiCount = await gemini.fetchCount()
        XCTAssertEqual(claudeCount, 1)
        XCTAssertEqual(codexCount, 0)
        XCTAssertEqual(geminiCount, 0)

        // Enable Codex live without disturbing Claude's polling loop or snapshot.
        settings.codexUsageEnabled = true
        try await waitUntil {
            if case .loaded = viewModel.state(for: .codex) { return true }
            return false
        }

        claudeCount = await claude.fetchCount()
        codexCount = await codex.fetchCount()
        geminiCount = await gemini.fetchCount()
        XCTAssertEqual(claudeCount, 1)
        XCTAssertEqual(codexCount, 1)
        XCTAssertEqual(geminiCount, 0)
        XCTAssertEqual(viewModel.enabledProviderIDs, [.claude, .codex])
        XCTAssertEqual(viewModel.activeSnapshots.map(\.providerID), [.claude, .codex])

        // Disable Codex live; Claude remains loaded and untouched.
        settings.codexUsageEnabled = false
        XCTAssertEqual(viewModel.state(for: .codex), .disabled)
        XCTAssertNil(viewModel.snapshot(for: .codex))
        XCTAssertEqual(viewModel.enabledProviderIDs, [.claude])
        XCTAssertNotNil(viewModel.snapshot(for: .claude))
        claudeCount = await claude.fetchCount()
        XCTAssertEqual(claudeCount, 1)
    }

    func testDisablingProviderMidFlightDiscardsLateResult() async throws {
        let settings = makeSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let codexGate = FetchGate()

        let claude = SpyAIUsageProvider(id: .claude) { _, _ in
            .success(makeTestSnapshot(providerID: .claude, fetchedAt: fixedDate))
        }
        let codex = SpyAIUsageProvider(id: .codex) { _, _ in
            await codexGate.wait()
        }

        let sleeper = DeterministicSleeper()
        let viewModel = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claude, .codex: codex],
            sleeper: { try await sleeper.sleep($0) },
            now: { fixedDate }
        )

        viewModel.startSampling()
        try await waitUntil {
            let waiting = await codexGate.hasWaiter()
            return waiting && viewModel.isRefreshing(for: .codex)
        }

        settings.codexUsageEnabled = false
        XCTAssertEqual(viewModel.state(for: .codex), .disabled)
        XCTAssertFalse(viewModel.isRefreshing(for: .codex))

        let lateCodexSnapshot = makeTestSnapshot(providerID: .codex, fetchedAt: fixedDate)
        await codexGate.resolve(.success(lateCodexSnapshot))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(viewModel.state(for: .codex), .disabled)
        XCTAssertNil(viewModel.snapshot(for: .codex))
        XCTAssertNotNil(viewModel.snapshot(for: .claude))
    }

    func testCooldownAndManualThrottleAreIsolatedPerProvider() async throws {
        let settings = makeSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true

        let claude = SpyAIUsageProvider(id: .claude) { now, _ in
            .success(makeTestSnapshot(providerID: .claude, fetchedAt: now))
        }
        let codex = SpyAIUsageProvider(id: .codex) { now, _ in
            .success(makeTestSnapshot(providerID: .codex, fetchedAt: now))
        }

        let sleeper = DeterministicSleeper()

        final class MutableClock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Date

            init(_ initial: Date) { self.value = initial }

            func now() -> Date {
                lock.lock()
                defer { lock.unlock() }
                return value
            }

            func advance(by interval: TimeInterval) {
                lock.lock()
                value = value.addingTimeInterval(interval)
                lock.unlock()
            }
        }

        let mutableClock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claude, .codex: codex],
            sleeper: { try await sleeper.sleep($0) },
            now: { mutableClock.now() }
        )

        vm.startSampling()
        try await waitUntil {
            let claudeHits = await claude.fetchCount()
            let codexHits = await codex.fetchCount()
            return claudeHits == 1 && codexHits == 1
        }

        // Within 60s cooldown, stopSampling + startSampling reuses cached snapshots without fetching.
        mutableClock.advance(by: 20)
        vm.stopSampling()
        vm.startSampling()
        try await waitUntil {
            let pending = await sleeper.pendingDurations()
            return pending.filter { abs($0 - 280) < 0.01 }.count == 2
        }
        var claudeCount = await claude.fetchCount()
        var codexCount = await codex.fetchCount()
        XCTAssertEqual(claudeCount, 1)
        XCTAssertEqual(codexCount, 1)

        // Manual refresh on Claude bypasses cooldown and triggers Claude only.
        let claudeManual1 = await vm.performManualRefresh(for: .claude)
        XCTAssertNotNil(claudeManual1)
        claudeCount = await claude.fetchCount()
        codexCount = await codex.fetchCount()
        XCTAssertEqual(claudeCount, 2)
        XCTAssertEqual(codexCount, 1)

        // Within 5s throttle, Claude is throttled (returns nil), while Codex is NOT throttled!
        mutableClock.advance(by: 2)
        let claudeThrottled = await vm.performManualRefresh(for: .claude)
        XCTAssertNil(claudeThrottled)
        let codexAllowed = await vm.performManualRefresh(for: .codex)
        XCTAssertNotNil(codexAllowed)

        claudeCount = await claude.fetchCount()
        codexCount = await codex.fetchCount()
        XCTAssertEqual(claudeCount, 2)
        XCTAssertEqual(codexCount, 2)
    }

    func testSingleFlightDeduplicationPerProvider() async throws {
        let settings = makeSettings()
        settings.claudeUsageEnabled = true

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let gate = FetchGate()

        let claude = SpyAIUsageProvider(id: .claude) { _, _ in
            await gate.wait()
        }

        let sleeper = DeterministicSleeper()
        let viewModel = AIUsageViewModel(
            settings: settings,
            provider: claude,
            sleeper: { try await sleeper.sleep($0) },
            now: { fixedDate }
        )

        async let first = viewModel.performManualRefresh(for: .claude)
        try await waitUntil { await gate.hasWaiter() }
        async let second = viewModel.performManualRefresh(for: .claude)

        let expected = makeTestSnapshot(providerID: .claude, usedRatio: 0.33, fetchedAt: fixedDate)
        await gate.resolve(.success(expected))

        let (result1, result2) = await (first, second)
        XCTAssertEqual(result1, .success(expected))
        XCTAssertEqual(result2, .success(expected))

        let count = await claude.fetchCount()
        XCTAssertEqual(count, 1)
    }

    func testRateLimitBackoffAndStopRetryAreIsolatedBetweenProviders() async throws {
        let settings = makeSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        settings.antigravityUsageEnabled = true

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let claude = SpyAIUsageProvider(id: .claude) { _, _ in
            .failure(.tokenExpired)
        }
        let codex = SpyAIUsageProvider(id: .codex) { now, callIndex in
            if callIndex == 1 {
                return .failure(.rateLimited(retryAfter: 42))
            }
            return .success(makeTestSnapshot(providerID: .codex, usedRatio: 0.15, fetchedAt: now))
        }
        let gemini = SpyAIUsageProvider(id: .antigravity) { now, _ in
            .success(makeTestSnapshot(providerID: .antigravity, usedRatio: 0.5, fetchedAt: now))
        }

        let sleeper = DeterministicSleeper()
        let viewModel = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claude, .codex: codex, .antigravity: gemini],
            sleeper: { try await sleeper.sleep($0) },
            now: { fixedDate }
        )

        viewModel.startSampling()
        try await waitUntil {
            let claudeHits = await claude.fetchCount()
            let codexHits = await codex.fetchCount()
            let geminiHits = await gemini.fetchCount()
            let pending = await sleeper.pendingDurations()
            return claudeHits == 1
                && codexHits == 1
                && geminiHits == 1
                && pending.contains(42)
        }

        XCTAssertEqual(viewModel.state(for: .claude), .error(.tokenExpired))
        XCTAssertEqual(viewModel.state(for: .codex), .error(.rateLimited(retryAfter: 42)))
        if case .loaded = viewModel.state(for: .antigravity) {
        } else {
            XCTFail("Expected Gemini to remain loaded")
        }

        // Resume Codex's 42s Retry-After sleep; Codex recovers while Claude stays stopped.
        let resumed = await sleeper.resumeFirst { abs($0 - 42) < 0.01 }
        XCTAssertTrue(resumed)

        try await waitUntil {
            await codex.fetchCount() == 2
        }

        if case .loaded = viewModel.state(for: .codex) {
        } else {
            XCTFail("Expected Codex to recover after Retry-After")
        }
        let claudeCount = await claude.fetchCount()
        let geminiCount = await gemini.fetchCount()
        XCTAssertEqual(claudeCount, 1)
        XCTAssertEqual(geminiCount, 1)
    }

    func testStaleWhileErrorAndSelectiveVsAllRefreshAndDemandLifecycle() async throws {
        let settings = makeSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true

        final class StepClock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Date
            init(_ initial: Date) { self.value = initial }
            func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
            func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
        }

        let clock = StepClock(Date(timeIntervalSince1970: 1_700_000_000))
        let claude = SpyAIUsageProvider(id: .claude) { now, _ in
            .success(makeTestSnapshot(providerID: .claude, usedRatio: 0.20, fetchedAt: now))
        }
        let codex = SpyAIUsageProvider(id: .codex) { now, _ in
            .success(makeTestSnapshot(providerID: .codex, usedRatio: 0.30, fetchedAt: now))
        }

        let sleeper = DeterministicSleeper()
        let viewModel = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claude, .codex: codex],
            sleeper: { try await sleeper.sleep($0) },
            now: { clock.now() }
        )

        viewModel.startSampling()
        try await waitUntil {
            let claudeHits = await claude.fetchCount()
            let codexHits = await codex.fetchCount()
            return claudeHits == 1 && codexHits == 1
        }
        let initialClaude = viewModel.snapshot(for: .claude)
        XCTAssertNotNil(initialClaude)

        // stopSampling() clears active tasks while preserving snapshots.
        viewModel.stopSampling()
        XCTAssertFalse(viewModel.isRefreshing(for: .claude))
        XCTAssertFalse(viewModel.isRefreshing(for: .codex))
        XCTAssertEqual(viewModel.snapshot(for: .claude), initialClaude)

        // Selective refresh for Codex only leaves Claude at count 1.
        clock.advance(10)
        await codex.setHandler { now, _ in
            .success(makeTestSnapshot(providerID: .codex, usedRatio: 0.55, fetchedAt: now))
        }
        _ = await viewModel.performManualRefresh(for: .codex)
        let claudeCountAfterSelective = await claude.fetchCount()
        let codexCountAfterSelective = await codex.fetchCount()
        XCTAssertEqual(claudeCountAfterSelective, 1)
        XCTAssertEqual(codexCountAfterSelective, 2)
        XCTAssertEqual(viewModel.snapshot(for: .codex)?.primaryWindow?.usedRatio, 0.55)

        // Refresh all enabled: Claude fails (becomes .stale), Codex succeeds with updated ratio.
        clock.advance(10)
        await claude.setHandler { _, _ in
            .failure(.networkFailure("Offline"))
        }
        await codex.setHandler { now, _ in
            .success(makeTestSnapshot(providerID: .codex, usedRatio: 0.65, fetchedAt: now))
        }

        let allResult = await viewModel.performManualRefresh(for: nil)
        XCTAssertNotNil(allResult)
        if case .stale(let retained, let error) = viewModel.state(for: .claude) {
            XCTAssertEqual(retained, initialClaude)
            XCTAssertEqual(error, .networkFailure("Offline"))
        } else {
            XCTFail("Expected Claude to be in stale-while-error state")
        }
        XCTAssertEqual(viewModel.snapshot(for: .codex)?.primaryWindow?.usedRatio, 0.65)
        XCTAssertEqual(viewModel.activeSnapshots.map(\.providerID), [.claude, .codex])
        XCTAssertTrue(viewModel.isEnabled)
        XCTAssertNotNil(viewModel.currentSnapshot)
    }

    func testDeinitReleasesViewModelAndCancelsPollingWhenSuspendedInSleeper() async throws {
        let settings = makeSettings()
        settings.claudeUsageEnabled = true

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let claude = SpyAIUsageProvider(id: .claude) { _, _ in
            .success(makeTestSnapshot(providerID: .claude, fetchedAt: fixedDate))
        }
        let sleeper = DeterministicSleeper()

        var viewModel: AIUsageViewModel? = AIUsageViewModel(
            settings: settings,
            provider: claude,
            sleeper: { try await sleeper.sleep($0) },
            now: { fixedDate }
        )
        weak let weakViewModel = viewModel

        if let vm = viewModel {
            vm.startSampling()
        }
        try await waitUntil {
            let pending = await sleeper.pendingDurations()
            return pending.count == 1
        }

        // Dropping the last strong reference without stopSampling() must immediately deinit and cancel pollingTask.
        viewModel = nil
        XCTAssertNil(weakViewModel)

        try await waitUntil {
            let cancelled = await sleeper.cancelledCount()
            let pending = await sleeper.pendingDurations()
            return cancelled == 1 && pending.isEmpty
        }
    }

    func testDeinitReleasesViewModelAndCancelsPollingWhenSuspendedInFetchQuota() async throws {
        let settings = makeSettings()
        settings.claudeUsageEnabled = true

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let gate = CancellableFetchGate()
        let claude = SpyAIUsageProvider(id: .claude) { _, _ in
            await gate.wait()
        }
        let sleeper = DeterministicSleeper()

        var viewModel: AIUsageViewModel? = AIUsageViewModel(
            settings: settings,
            provider: claude,
            sleeper: { try await sleeper.sleep($0) },
            now: { fixedDate }
        )
        weak let weakViewModel = viewModel

        if let vm = viewModel {
            vm.startSampling()
        }
        try await waitUntil {
            await gate.hasWaiter()
        }

        // Dropping the last strong reference mid-fetch must immediately deinit and cancel fetchQuota.
        viewModel = nil
        XCTAssertNil(weakViewModel)

        try await waitUntil {
            await gate.wasCancelled()
        }
    }

    func testDeinitReleasesViewModelAndCancelsFetchWhenSuspendedInRefreshNowAll() async throws {
        let settings = makeSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let claudeGate = CancellableFetchGate()
        let codexGate = CancellableFetchGate()
        let claude = SpyAIUsageProvider(id: .claude) { _, _ in
            await claudeGate.wait()
        }
        let codex = SpyAIUsageProvider(id: .codex) { _, _ in
            await codexGate.wait()
        }
        let sleeper = DeterministicSleeper()

        var viewModel: AIUsageViewModel? = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claude, .codex: codex],
            sleeper: { try await sleeper.sleep($0) },
            now: { fixedDate }
        )
        weak let weakViewModel = viewModel

        viewModel?.refreshNow()
        try await waitUntil {
            let claudeWaiting = await claudeGate.hasWaiter()
            let codexWaiting = await codexGate.hasWaiter()
            return claudeWaiting && codexWaiting
        }

        viewModel = nil
        XCTAssertNil(weakViewModel)

        try await waitUntil {
            let claudeCancelled = await claudeGate.wasCancelled()
            let codexCancelled = await codexGate.wasCancelled()
            return claudeCancelled && codexCancelled
        }
    }

    func testDeinitReleasesViewModelAndCancelsFetchWhenSuspendedInTargetedRefreshNow() async throws {
        let settings = makeSettings()
        settings.claudeUsageEnabled = true

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let gate = CancellableFetchGate()
        let claude = SpyAIUsageProvider(id: .claude) { _, _ in
            await gate.wait()
        }
        let sleeper = DeterministicSleeper()

        var viewModel: AIUsageViewModel? = AIUsageViewModel(
            settings: settings,
            provider: claude,
            sleeper: { try await sleeper.sleep($0) },
            now: { fixedDate }
        )
        weak let weakViewModel = viewModel

        viewModel?.refreshNow(for: .claude)
        try await waitUntil {
            await gate.hasWaiter()
        }

        viewModel = nil
        XCTAssertNil(weakViewModel)

        try await waitUntil {
            await gate.wasCancelled()
        }
    }

    func testDeinitReleasesViewModelAndCancelsFetchWhenRefreshNowJoinsStartSamplingFetch() async throws {
        let settings = makeSettings()
        settings.claudeUsageEnabled = true

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let gate = CancellableFetchGate()
        let claude = SpyAIUsageProvider(id: .claude) { _, _ in
            await gate.wait()
        }
        let sleeper = DeterministicSleeper()

        var viewModel: AIUsageViewModel? = AIUsageViewModel(
            settings: settings,
            provider: claude,
            sleeper: { try await sleeper.sleep($0) },
            now: { fixedDate }
        )
        weak let weakViewModel = viewModel

        viewModel?.startSampling()
        try await waitUntil {
            await gate.hasWaiter()
        }

        // Joining the active single-flight fetch via refreshNow must not retain self across await.
        viewModel?.refreshNow(for: .claude)
        try await Task.sleep(for: .milliseconds(20))

        viewModel = nil
        XCTAssertNil(weakViewModel)

        try await waitUntil {
            await gate.wasCancelled()
        }
        let fetchCount = await claude.fetchCount()
        XCTAssertEqual(fetchCount, 1)
    }
}
