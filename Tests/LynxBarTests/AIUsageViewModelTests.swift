import Foundation
import os
import XCTest
@testable import LynxBar

/// Offline unit tests for `AIUsageViewModel` covering opt-in gating, live toggles,
/// 60s cooldown, 5s manual throttle + single-flight deduplication, 429 & exponential backoff,
/// automatic retry stopping on auth/credential errors, stale-while-error, and display style updates.
@MainActor
final class AIUsageViewModelTests: XCTestCase {
    private func makeSettings() -> Settings {
        let suiteName = "com.swnb.LynxBarTests.aiUsageVM.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return Settings(defaults: defaults)
    }

    private func makeSnapshot(at date: Date, usedRatio: Double = 0.22) -> AIProviderQuotaSnapshot {
        AIProviderQuotaSnapshot(
            providerID: .claude,
            primaryWindow: AIQuotaWindow(
                id: "five_hour",
                kind: .session5h,
                title: "5-hour session",
                usedRatio: usedRatio,
                resetsAt: date.addingTimeInterval(3_600)
            ),
            secondaryWindow: AIQuotaWindow(
                id: "seven_day",
                kind: .weekly7d,
                title: "7-day weekly",
                usedRatio: 0.40,
                resetsAt: date.addingTimeInterval(86_400)
            ),
            additionalWindows: [],
            extraUsage: nil,
            planLabel: "Pro",
            fetchedAt: date
        )
    }

    /// Verifies that when `aiUsageEnabled` defaults to `false`, `startSampling()` issues zero
    /// provider calls and remains `.disabled` with `currentSnapshot == nil`.
    func testDisabledByDefaultPerformsZeroProviderCallsAndNeverShowsZero() async {
        let settings = makeSettings()
        XCTAssertFalse(settings.aiUsageEnabled)

        let provider = MockAIUsageProvider()
        let sleeper = MockSleeper()
        let viewModel = AIUsageViewModel(
            settings: settings,
            provider: provider,
            sleeper: { try await sleeper.sleep($0) },
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
        defer { viewModel.stopSampling() }

        viewModel.startSampling()
        await Task.yield()

        XCTAssertEqual(viewModel.state, .disabled)
        XCTAssertNil(viewModel.currentSnapshot)
        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 0)
        let manualResult = await viewModel.performManualRefresh()
        XCTAssertEqual(manualResult, .failure(.disabled))
        let callCountAfterManual = await provider.callCount
        XCTAssertEqual(callCountAfterManual, 0)
    }

    /// Verifies live opt-in toggle triggers immediate fetch when demanded, and toggling back
    /// to `false` cancels polling and clears state, error, and cached snapshot to `.disabled`.
    func testLiveOptInAndOptOutTogglesWhileDemanded() async {
        let settings = makeSettings()
        let clock = TestClock(Date(timeIntervalSince1970: 1_750_000_000))
        let expectedSnapshot = makeSnapshot(at: clock.now())
        let provider = MockAIUsageProvider(results: [.success(expectedSnapshot)])
        let sleeper = MockSleeper()
        let viewModel = AIUsageViewModel(
            settings: settings,
            provider: provider,
            sleeper: { try await sleeper.sleep($0) },
            now: { clock.now() }
        )
        defer { viewModel.stopSampling() }

        viewModel.startSampling()
        XCTAssertEqual(viewModel.state, .disabled)

        settings.aiUsageEnabled = true
        await waitUntil { viewModel.state == .loaded(expectedSnapshot) }
        XCTAssertEqual(viewModel.currentSnapshot, expectedSnapshot)
        XCTAssertEqual(viewModel.lastSuccessfulFetchAt, clock.now())

        settings.aiUsageEnabled = false
        XCTAssertEqual(viewModel.state, .disabled)
        XCTAssertNil(viewModel.currentSnapshot)
        XCTAssertNil(viewModel.lastSuccessfulFetchAt)
        XCTAssertNil(viewModel.lastError)
    }

    /// Verifies the 60-second cooldown on `startSampling()` reuses the cached snapshot without
    /// calling `provider.fetchQuota`, and fetches again once elapsed >= 60s.
    func testCooldownOnStartSamplingReusesSnapshotWithin60Seconds() async {
        let settings = makeSettings()
        settings.aiUsageEnabled = true
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let clock = TestClock(start)
        let firstSnapshot = makeSnapshot(at: start, usedRatio: 0.22)
        let secondSnapshot = makeSnapshot(at: start.addingTimeInterval(61), usedRatio: 0.30)
        let provider = MockAIUsageProvider(results: [.success(firstSnapshot), .success(secondSnapshot)])
        let sleeper = MockSleeper()

        let viewModel = AIUsageViewModel(
            settings: settings,
            provider: provider,
            sleeper: { try await sleeper.sleep($0) },
            now: { clock.now() }
        )
        defer { viewModel.stopSampling() }

        viewModel.startSampling()
        await waitUntil { viewModel.state == .loaded(firstSnapshot) }
        await waitUntil { await sleeper.recordedDelays.count == 1 }
        viewModel.stopSampling()

        // Re-start within 60s cooldown -> must reuse snapshot without calling provider.
        clock.set(start.addingTimeInterval(30))
        viewModel.startSampling()
        await waitUntil { await sleeper.recordedDelays.count == 2 }

        let callsDuringCooldown = await provider.callCount
        XCTAssertEqual(callsDuringCooldown, 1)
        XCTAssertEqual(viewModel.state, .loaded(firstSnapshot))
        let delays = await sleeper.recordedDelays
        XCTAssertEqual(delays[1], 270, accuracy: 0.001)
        viewModel.stopSampling()

        // Re-start past 60s cooldown -> must issue fresh upstream fetch.
        clock.set(start.addingTimeInterval(61))
        viewModel.startSampling()
        await waitUntil { viewModel.state == .loaded(secondSnapshot) }
        let callsAfterCooldown = await provider.callCount
        XCTAssertEqual(callsAfterCooldown, 2)
    }

    /// Verifies that when a subsequent refresh fails within 60s of a prior success,
    /// `stopSampling()` + `startSampling()` within the cooldown window does NOT clear
    /// `.stale` / `lastError` and immediately triggers a fresh upstream retry.
    func testCooldownDoesNotClearStaleErrorOnStopAndRestartWithin60Seconds() async {
        let settings = makeSettings()
        settings.aiUsageEnabled = true
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let clock = TestClock(start)
        let firstSnapshot = makeSnapshot(at: start, usedRatio: 0.22)
        let recoveredSnapshot = makeSnapshot(at: start.addingTimeInterval(20), usedRatio: 0.28)
        let failureError = AIUsageFetchError.networkFailure("transient timeout")
        let provider = MockAIUsageProvider(results: [
            .success(firstSnapshot),
            .failure(failureError),
            .success(recoveredSnapshot),
        ])
        let sleeper = MockSleeper()

        let viewModel = AIUsageViewModel(
            settings: settings,
            provider: provider,
            sleeper: { try await sleeper.sleep($0) },
            now: { clock.now() }
        )
        defer { viewModel.stopSampling() }

        viewModel.startSampling()
        await waitUntil { viewModel.state == .loaded(firstSnapshot) }
        await waitUntil { await sleeper.recordedDelays.count == 1 }

        clock.set(start.addingTimeInterval(10))
        let manualResult = await viewModel.performManualRefresh()
        XCTAssertEqual(manualResult, .failure(failureError))
        XCTAssertEqual(viewModel.state, .stale(snapshot: firstSnapshot, lastError: failureError))
        XCTAssertEqual(viewModel.lastError, failureError)

        viewModel.stopSampling()
        XCTAssertEqual(viewModel.state, .stale(snapshot: firstSnapshot, lastError: failureError))
        XCTAssertEqual(viewModel.lastError, failureError)

        // Gate the recovery fetch so we can verify stale state survives startSampling() before completion.
        await provider.setGateEnabled(true)
        clock.set(start.addingTimeInterval(20))
        viewModel.startSampling()
        await waitUntil { await provider.inFlightGateWaiterCount == 1 }

        let callsOnRestart = await provider.callCount
        XCTAssertEqual(callsOnRestart, 3)
        XCTAssertEqual(viewModel.state, .stale(snapshot: firstSnapshot, lastError: failureError))
        XCTAssertEqual(viewModel.lastError, failureError)

        await provider.releaseGate()
        await waitUntil { viewModel.state == .loaded(recoveredSnapshot) }
        XCTAssertNil(viewModel.lastError)
    }

    /// Verifies single-flight deduplication for concurrent `performManualRefresh()` calls
    /// and the 5-second manual refresh throttle.
    func testManualRefreshSingleFlightDeduplicationAnd5SecondThrottle() async {
        let settings = makeSettings()
        settings.aiUsageEnabled = true
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let clock = TestClock(start)
        let firstSnapshot = makeSnapshot(at: start, usedRatio: 0.25)
        let secondSnapshot = makeSnapshot(at: start.addingTimeInterval(5), usedRatio: 0.35)
        let provider = MockAIUsageProvider(results: [.success(firstSnapshot), .success(secondSnapshot)])
        await provider.setGateEnabled(true)
        let sleeper = MockSleeper()

        let viewModel = AIUsageViewModel(
            settings: settings,
            provider: provider,
            sleeper: { try await sleeper.sleep($0) },
            now: { clock.now() }
        )
        defer { viewModel.stopSampling() }

        async let firstTask = viewModel.performManualRefresh()
        await waitUntil { await provider.inFlightGateWaiterCount == 1 }
        async let secondTask = viewModel.performManualRefresh()
        await Task.yield()

        await provider.releaseGate()
        let (firstResult, secondResult) = await (firstTask, secondTask)
        XCTAssertEqual(firstResult, .success(firstSnapshot))
        XCTAssertEqual(secondResult, .success(firstSnapshot))
        let callsAfterConcurrent = await provider.callCount
        XCTAssertEqual(callsAfterConcurrent, 1)

        // Within 5s throttle -> returns nil and issues zero upstream fetches.
        clock.set(start.addingTimeInterval(4))
        let throttled = await viewModel.performManualRefresh()
        XCTAssertNil(throttled)
        let callsWhileThrottled = await provider.callCount
        XCTAssertEqual(callsWhileThrottled, 1)

        // At 5s -> allowed again.
        clock.set(start.addingTimeInterval(5))
        let refreshed = await viewModel.performManualRefresh()
        XCTAssertEqual(refreshed, .success(secondSnapshot))
        let callsAfterThrottle = await provider.callCount
        XCTAssertEqual(callsAfterThrottle, 2)
    }

    /// Verifies 429 respects explicit `Retry-After`, and repeated failures follow
    /// the capped `5m -> 10m -> 20m -> 30m` exponential backoff schedule.
    func testRateLimitRetryAfterAndExponentialBackoffSchedule() async {
        let settings = makeSettings()
        settings.aiUsageEnabled = true
        let clock = TestClock(Date(timeIntervalSince1970: 1_750_000_000))
        let provider = MockAIUsageProvider(results: [
            .failure(.rateLimited(retryAfter: 90)),
            .failure(.networkFailure("timeout-1")),
            .failure(.networkFailure("timeout-2")),
            .failure(.rateLimited(retryAfter: nil)),
            .failure(.endpointUnavailable(statusCode: 503)),
            .failure(.networkFailure("timeout-cap")),
        ])
        let sleeper = MockSleeper()
        let viewModel = AIUsageViewModel(
            settings: settings,
            provider: provider,
            sleeper: { try await sleeper.sleep($0) },
            now: { clock.now() }
        )
        defer { viewModel.stopSampling() }

        viewModel.startSampling()
        for expectedCount in 1...6 {
            await waitUntil { await sleeper.recordedDelays.count == expectedCount }
            if expectedCount < 6 {
                await sleeper.resumeNext()
            }
        }

        let delays = await sleeper.recordedDelays
        // Failure #0 (`retryAfter: 90`) uses Retry-After (90s) while advancing failure counter to 1.
        // Subsequent failures follow backoffSchedule[1], [2], [3], [3], [3] = 600, 1200, 1800, 1800, 1800.
        XCTAssertEqual(delays, [90, 600, 1_200, 1_800, 1_800, 1_800])
    }

    /// Verifies that pure backoff without `Retry-After` starts at 5m (300s) and caps at 30m (1800s).
    func testPureExponentialBackoffStartsAt300Seconds() async {
        let settings = makeSettings()
        settings.aiUsageEnabled = true
        let clock = TestClock(Date(timeIntervalSince1970: 1_750_000_000))
        let provider = MockAIUsageProvider(results: [
            .failure(.networkFailure("1")),
            .failure(.networkFailure("2")),
            .failure(.networkFailure("3")),
            .failure(.networkFailure("4")),
            .failure(.networkFailure("5")),
        ])
        let sleeper = MockSleeper()
        let viewModel = AIUsageViewModel(
            settings: settings,
            provider: provider,
            sleeper: { try await sleeper.sleep($0) },
            now: { clock.now() }
        )
        defer { viewModel.stopSampling() }

        viewModel.startSampling()
        for expectedCount in 1...5 {
            await waitUntil { await sleeper.recordedDelays.count == expectedCount }
            if expectedCount < 5 {
                await sleeper.resumeNext()
            }
        }

        let delays = await sleeper.recordedDelays
        XCTAssertEqual(delays, [300, 600, 1_200, 1_800, 1_800])
    }

    /// Verifies that auth/credential errors stop the automatic polling retry loop immediately.
    func testAuthAndCredentialErrorsStopAutomaticRetryLoop() async {
        let stoppingErrors: [AIUsageFetchError] = [
            .tokenExpired,
            .unauthorized,
            .credentialsMissing,
            .credentialsMalformed,
        ]

        for error in stoppingErrors {
            let settings = makeSettings()
            settings.aiUsageEnabled = true
            let provider = MockAIUsageProvider(results: [.failure(error)])
            let sleeper = MockSleeper()
            let viewModel = AIUsageViewModel(
                settings: settings,
                provider: provider,
                sleeper: { try await sleeper.sleep($0) },
                now: { Date(timeIntervalSince1970: 1_750_000_000) }
            )

            viewModel.startSampling()
            await waitUntil { viewModel.state == .error(error) }
            // Give the polling task a chance to schedule any sleep if it wrongly continued.
            await Task.yield()

            let delays = await sleeper.recordedDelays
            XCTAssertTrue(delays.isEmpty, "Error \(error) must stop automatic retries")
            let calls = await provider.callCount
            XCTAssertEqual(calls, 1)
            viewModel.stopSampling()
        }
    }

    /// Verifies stale-while-error preserves `lastCachedSnapshot` in `.stale(snapshot:lastError:)`.
    func testStaleWhileErrorPreservesCachedSnapshot() async {
        let settings = makeSettings()
        settings.aiUsageEnabled = true
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let clock = TestClock(start)
        let cached = makeSnapshot(at: start, usedRatio: 0.22)
        let provider = MockAIUsageProvider(results: [
            .success(cached),
            .failure(.rateLimited(retryAfter: 60)),
        ])
        let sleeper = MockSleeper()
        let viewModel = AIUsageViewModel(
            settings: settings,
            provider: provider,
            sleeper: { try await sleeper.sleep($0) },
            now: { clock.now() }
        )
        defer { viewModel.stopSampling() }

        let first = await viewModel.performManualRefresh()
        XCTAssertEqual(first, .success(cached))
        XCTAssertEqual(viewModel.state, .loaded(cached))

        clock.set(start.addingTimeInterval(10))
        let second = await viewModel.performManualRefresh()
        XCTAssertEqual(second, .failure(.rateLimited(retryAfter: 60)))
        XCTAssertEqual(viewModel.state, .stale(snapshot: cached, lastError: .rateLimited(retryAfter: 60)))
        XCTAssertEqual(viewModel.currentSnapshot, cached)
        XCTAssertEqual(viewModel.lastError, .rateLimited(retryAfter: 60))
    }

    /// Verifies switching `settings.aiQuotaDisplayStyle` updates `viewModel.displayStyle` immediately.
    func testDisplayStyleUpdatesImmediatelyFromSettings() {
        let settings = makeSettings()
        let viewModel = AIUsageViewModel(
            settings: settings,
            provider: MockAIUsageProvider(),
            sleeper: { _ in throw CancellationError() },
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )

        XCTAssertEqual(viewModel.displayStyle, .remaining)
        settings.aiQuotaDisplayStyle = .used
        XCTAssertEqual(viewModel.displayStyle, .used)
        settings.aiQuotaDisplayStyle = .remaining
        XCTAssertEqual(viewModel.displayStyle, .remaining)
    }

    private func waitUntil(_ predicate: @MainActor () async -> Bool) async {
        for _ in 0..<500 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition not satisfied before deadline")
    }
}

private final class TestClock: Sendable {
    private let storage: OSAllocatedUnfairLock<Date>

    init(_ initial: Date) {
        self.storage = OSAllocatedUnfairLock(initialState: initial)
    }

    func now() -> Date {
        storage.withLock { $0 }
    }

    func set(_ newValue: Date) {
        storage.withLock { $0 = newValue }
    }
}

private actor MockAIUsageProvider: AIUsageProvider {
    nonisolated let id: AIUsageProviderID = .claude
    private var results: [Result<AIProviderQuotaSnapshot, AIUsageFetchError>]
    private(set) var callCount: Int = 0
    private var gateEnabled = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    init(results: [Result<AIProviderQuotaSnapshot, AIUsageFetchError>] = []) {
        self.results = results
    }

    var inFlightGateWaiterCount: Int {
        gateWaiters.count
    }

    func setGateEnabled(_ enabled: Bool) {
        gateEnabled = enabled
    }

    func releaseGate() {
        gateEnabled = false
        let waiters = gateWaiters
        gateWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func fetchQuota(now: Date) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        callCount += 1
        if gateEnabled {
            await withCheckedContinuation { continuation in
                gateWaiters.append(continuation)
            }
        }
        if !results.isEmpty {
            return results.removeFirst()
        }
        return .failure(.networkFailure("No stubbed result"))
    }
}

private actor MockSleeper {
    private(set) var recordedDelays: [TimeInterval] = []
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    func sleep(_ duration: TimeInterval) async throws {
        try Task.checkCancellation()
        recordedDelays.append(duration)
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((waiterID, continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    func resumeNext() {
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        next.continuation.resume()
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let entry = waiters.remove(at: index)
        entry.continuation.resume(throwing: CancellationError())
    }
}
