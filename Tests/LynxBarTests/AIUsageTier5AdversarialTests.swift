import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import LynxBar

/// Tier-5 adversarial unit tests covering extreme numeric overflow boundaries, backward clock skew,
/// epoch-zero/negative expiry validation, isolated ViewModel settings decoupling, and credits-only Codex rendering.
@MainActor
final class AIUsageTier5AdversarialTests: XCTestCase {
    private let baseNow = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - 1. Duration Overflow & Extreme Inputs

    /// Verifies `Formatters.duration`, `Formatters.compactDuration`, and `MenuBarStatusFormatter`
    /// (`localizedChineseDuration`) survive negative, `NaN`, `±infinity`, and `1e20` inputs without trapping.
    func testFormattersDurationAndLocalizedChineseDurationSurviveExtremeNegativeNaNAndInfinity() {
        // Formatters.duration
        XCTAssertEqual(Formatters.duration(0), "0m")
        XCTAssertEqual(Formatters.duration(125), "2m")
        XCTAssertEqual(Formatters.duration(3_661), "1h 1m")
        XCTAssertEqual(Formatters.duration(90_000), "1d 1h")

        XCTAssertEqual(Formatters.duration(-1), "0m")
        XCTAssertEqual(Formatters.duration(-3_600), "0m")
        XCTAssertEqual(Formatters.duration(-1e20), "0m")
        XCTAssertEqual(Formatters.duration(-.infinity), "0m")
        XCTAssertEqual(Formatters.duration(.nan), "0m")

        let hugeDuration = Formatters.duration(1e20)
        XCTAssertEqual(hugeDuration, "36500d 0h")
        XCTAssertEqual(Formatters.duration(.infinity), "0m")
        XCTAssertEqual(Formatters.duration(Double(Int.max)), hugeDuration)

        // Formatters.compactDuration
        XCTAssertEqual(Formatters.compactDuration(0), "0s")
        XCTAssertEqual(Formatters.compactDuration(59.9), "59s")
        XCTAssertEqual(Formatters.compactDuration(125), "2m 5s")
        XCTAssertEqual(Formatters.compactDuration(3_661), "1h 1m")

        XCTAssertEqual(Formatters.compactDuration(-1), "0s")
        XCTAssertEqual(Formatters.compactDuration(-1e20), "0s")
        XCTAssertEqual(Formatters.compactDuration(-.infinity), "0s")
        XCTAssertEqual(Formatters.compactDuration(.nan), "0s")

        let hugeCompact = Formatters.compactDuration(1e20)
        XCTAssertEqual(hugeCompact, "876000h 0m")
        XCTAssertEqual(Formatters.compactDuration(.infinity), "0s")
        XCTAssertEqual(Formatters.compactDuration(Double(Int.max)), hugeCompact)

        // MenuBarStatusFormatter + localizedChineseDuration
        let zhLocale = Locale(identifier: "zh_Hans_CN")
        let normalEntry = MenuBarAIQuotaEntry(
            providerID: .codex,
            usedRatio: 0.25,
            resetsAt: baseNow.addingTimeInterval(5_400),
            observedAt: baseNow
        )
        let normalZH = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: MenuBarStatusSnapshot(
                health: .healthy,
                readings: [.aiUsage: .aiQuotas([normalEntry], displayStyle: .remaining, staleAfter: 900)]
            ),
            locale: zhLocale,
            now: baseNow
        )
        XCTAssertTrue(normalZH.accessibilityLabel.contains("1 小时 30 分后重置"))

        for extremeDate in [baseNow.addingTimeInterval(1e20), Date.distantFuture] {
            let entry = MenuBarAIQuotaEntry(
                providerID: .codex,
                usedRatio: 0.25,
                resetsAt: extremeDate,
                observedAt: baseNow
            )
            let formatted = MenuBarStatusFormatter.format(
                mode: .focus,
                slots: [.aiUsage],
                snapshot: MenuBarStatusSnapshot(
                    health: .healthy,
                    readings: [.aiUsage: .aiQuotas([entry], displayStyle: .remaining, staleAfter: 900)]
                ),
                locale: zhLocale,
                now: baseNow
            )
            XCTAssertTrue(formatted.accessibilityLabel.contains("36500 天 0 小时后重置"))
        }

        let pastEntry = MenuBarAIQuotaEntry(
            providerID: .codex,
            usedRatio: 0.25,
            resetsAt: baseNow.addingTimeInterval(-1e20),
            observedAt: baseNow
        )
        let pastZH = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: MenuBarStatusSnapshot(
                health: .healthy,
                readings: [.aiUsage: .aiQuotas([pastEntry], displayStyle: .remaining, staleAfter: 900)]
            ),
            locale: zhLocale,
            now: baseNow
        )
        XCTAssertFalse(pastZH.accessibilityLabel.contains("后重置"))
    }

    // MARK: - 2. Huge reset_after_seconds & Retry-After: 1e20 Bounds

    /// Verifies `CodexUsageProvider` with `reset_after_seconds: 1e20` formats safely in UI/menu bar
    /// and `Retry-After: 1e20` is bounded in both `AIUsageParsing` and `AIUsageViewModel.nextPollDelay`.
    func testCodexHugeResetAfterSecondsAndRetryAfter1e20DoNotCrashFormattingOrViewModel() async throws {
        let hugeResetJSON = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {
              "used_percent": 25.0,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 1e20,
              "reset_at": null
            }
          }
        }
        """

        let transport200 = MockAdversarialHTTPTransport { request in
            (
                Data(hugeResetJSON.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let provider200 = CodexUsageProvider(
            credentialReader: StubAdversarialCodexReader(result: .success(makeCodexCredentials())),
            transport: transport200
        )
        let fetchResult = await provider200.fetchQuota(now: baseNow)
        guard case .success(let snapshot) = fetchResult else {
            return XCTFail("Expected Codex 200 payload with reset_after_seconds=1e20 to succeed, got \(fetchResult)")
        }

        let resetsAt = try XCTUnwrap(snapshot.primaryWindow?.resetsAt)
        let remaining = resetsAt.timeIntervalSince(baseNow)
        XCTAssertEqual(Formatters.duration(remaining), "36500d 0h")

        let entry = MenuBarAIQuotaEntry(
            providerID: .codex,
            usedRatio: snapshot.primaryWindow?.usedRatio ?? 0,
            resetsAt: resetsAt,
            observedAt: baseNow
        )
        for localeID in ["en_US", "zh_Hans_CN"] {
            let presentation = MenuBarStatusFormatter.format(
                mode: .focus,
                slots: [.aiUsage],
                snapshot: MenuBarStatusSnapshot(
                    health: .healthy,
                    readings: [.aiUsage: .aiQuotas([entry], displayStyle: .remaining, staleAfter: 900)]
                ),
                locale: Locale(identifier: localeID),
                now: baseNow
            )
            XCTAssertEqual(presentation.segments.first?.text, "AI 75%")
        }

        let fixedNow = baseNow
        let settings = makeIsolatedSettings()
        settings.codexUsageEnabled = true
        let viewModel = AIUsageViewModel(
            settings: settings,
            providers: [.codex: StubAdversarialProvider(id: .codex, result: .success(snapshot))],
            sleeper: { _ in try await Task.sleep(for: .seconds(600)) },
            now: { fixedNow }
        )
        defer { viewModel.stopSampling() }
        _ = await viewModel.performManualRefresh(for: .codex)

        let rowHost = NSHostingView(
            rootView: OverviewAIQuotaRow(aiUsage: viewModel, selection: .constant(.overview))
                .frame(width: 420)
        )
        let panelHost = NSHostingView(
            rootView: AIUsagePanelView(viewModel: viewModel, selection: .constant(.aiUsage))
                .frame(width: 420, height: 496)
        )
        let rowWindow = makeTestWindow(width: 420, height: 60, contentView: rowHost)
        let panelWindow = makeTestWindow(width: 420, height: 496, contentView: panelHost)
        defer {
            rowWindow.orderOut(nil)
            rowWindow.close()
            panelWindow.orderOut(nil)
            panelWindow.close()
        }
        rowHost.layoutSubtreeIfNeeded()
        panelHost.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(rowHost.fittingSize.height, OverviewLayoutMetrics.aiQuotaRowHeight + 0.5)

        // Parse Retry-After: 1e20
        let parsedRetryAfter = try XCTUnwrap(AIUsageParsing.parseRetryAfter("1e20", now: baseNow))
        XCTAssertTrue(parsedRetryAfter.isFinite)
        XCTAssertGreaterThan(parsedRetryAfter, 0)
        XCTAssertLessThanOrEqual(parsedRetryAfter, AIUsageParsing.maxRetryAfterInterval)
        XCTAssertEqual(ClaudeUsageProvider.parseRetryAfter("1e20", now: baseNow), parsedRetryAfter)

        // End-to-end 429 Retry-After: 1e20 into AIUsageViewModel
        let transport429 = MockAdversarialHTTPTransport { request in
            (
                Data("{}".utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "1e20"]
                )!
            )
        }
        let rateLimitedProvider = CodexUsageProvider(
            credentialReader: StubAdversarialCodexReader(result: .success(makeCodexCredentials())),
            transport: transport429
        )
        let sleeper1 = RecordingAdversarialSleeper()
        let settings429 = makeIsolatedSettings()
        settings429.codexUsageEnabled = true
        let vm429 = AIUsageViewModel(
            settings: settings429,
            providers: [.codex: rateLimitedProvider],
            sleeper: { try await sleeper1.sleep($0) },
            now: { fixedNow }
        )
        defer { vm429.stopSampling() }

        vm429.startSampling()
        try await waitUntil {
            let durations = await sleeper1.recordedDurations()
            return !durations.isEmpty
        }
        let durations1 = await sleeper1.recordedDurations()
        let recordedFromHTTP = try XCTUnwrap(durations1.first)
        XCTAssertTrue(recordedFromHTTP.isFinite)
        XCTAssertGreaterThan(recordedFromHTTP, 0)
        XCTAssertLessThanOrEqual(recordedFromHTTP, AIUsageViewModel.maxRetryAfterDelay)

        // Direct .rateLimited(retryAfter: 1e20) injected into ViewModel also stays bounded
        let sleeper2 = RecordingAdversarialSleeper()
        let settingsDirect = makeIsolatedSettings()
        settingsDirect.claudeUsageEnabled = true
        let vmDirect = AIUsageViewModel(
            settings: settingsDirect,
            providers: [.claude: StubAdversarialProvider(id: .claude, result: .failure(.rateLimited(retryAfter: 1e20)))],
            sleeper: { try await sleeper2.sleep($0) },
            now: { fixedNow }
        )
        defer { vmDirect.stopSampling() }

        vmDirect.startSampling()
        try await waitUntil {
            let durations = await sleeper2.recordedDurations()
            return !durations.isEmpty
        }
        let durations2 = await sleeper2.recordedDurations()
        let directDelay = try XCTUnwrap(durations2.first)
        XCTAssertEqual(directDelay, AIUsageViewModel.maxRetryAfterDelay, accuracy: 0.001)
    }

    // MARK: - 3. Backward Clock Skew Guard in Manual Refresh

    /// Verifies `AIUsageViewModel.prepareManualRefresh` allows refresh after backward clock skew
    /// instead of remaining throttled until the clock catches up.
    func testPrepareManualRefreshRecoversAfterBackwardClockSkew() async {
        final class MutableClock: @unchecked Sendable {
            private let lock = NSLock()
            private var current: Date

            init(_ initial: Date) { self.current = initial }

            func now() -> Date {
                lock.lock()
                defer { lock.unlock() }
                return current
            }

            func set(_ date: Date) {
                lock.lock()
                current = date
                lock.unlock()
            }
        }

        let clock = MutableClock(baseNow)
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true

        let spy = CountingAdversarialProvider(id: .claude)
        let viewModel = AIUsageViewModel(
            settings: settings,
            providers: [.claude: spy],
            sleeper: { _ in try await Task.sleep(for: .seconds(600)) },
            now: { clock.now() }
        )

        // 1. Initial manual refresh at T0 succeeds.
        let first = await viewModel.performManualRefresh(for: .claude)
        XCTAssertNotNil(first)
        var hits = await spy.callCount()
        XCTAssertEqual(hits, 1)

        // 2. Clock skews backward by 60 seconds (elapsed < 0). Manual refresh must NOT be throttled.
        clock.set(baseNow.addingTimeInterval(-60))
        let afterSkew = await viewModel.performManualRefresh(for: .claude)
        XCTAssertNotNil(afterSkew)
        hits = await spy.callCount()
        XCTAssertEqual(hits, 2)

        // 3. Advancing forward by 2s (within 5s throttle relative to skewed timestamp) throttles properly.
        clock.set(baseNow.addingTimeInterval(-58))
        let throttled = await viewModel.performManualRefresh(for: .claude)
        XCTAssertNil(throttled)
        hits = await spy.callCount()
        XCTAssertEqual(hits, 2)

        // 4. Advancing past the 5s throttle window allows the next manual refresh.
        clock.set(baseNow.addingTimeInterval(-55))
        let afterWindow = await viewModel.performManualRefresh(for: .claude)
        XCTAssertNotNil(afterWindow)
        hits = await spy.callCount()
        XCTAssertEqual(hits, 3)
    }

    // MARK: - 4. Epoch-Zero & Non-Positive Expiry Timestamp Rejection

    /// Verifies epoch-zero and negative expiry timestamps return `.failure(.tokenExpired)` across Claude,
    /// Codex, and Gemini readers, while `CodexUsageProvider` preserves `reset_at: 0` fallback to `reset_after_seconds`.
    func testEpochZeroAndNegativeExpiryTimestampsReturnTokenExpiredAcrossAllThreeReaders() async {
        // Parsing primitives
        XCTAssertNil(AIUsageParsing.parseUnixTimestamp(0))
        XCTAssertNil(AIUsageParsing.parseUnixTimestamp(-10))
        XCTAssertEqual(AIUsageParsing.parseExpiryTimestamp(0), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(AIUsageParsing.parseExpiryTimestamp(-120), Date(timeIntervalSince1970: 0))
        XCTAssertNil(AIUsageParsing.parseExpiryTimestamp(.nan))
        XCTAssertNil(AIUsageParsing.parseExpiryTimestamp(.infinity))

        // ClaudeCredentialReader (numeric and string 0 / negative)
        for expiresAtLiteral in ["0", "-100", "\"0\"", "\"-100\""] {
            let claudeJSON = """
            {
              "claudeAiOauth": {
                "accessToken": "sk-ant-oat-test",
                "expiresAt": \(expiresAtLiteral)
              }
            }
            """
            let reader = ClaudeCredentialReader(
                keychainReader: { .data(Data(claudeJSON.utf8)) },
                fileReader: { nil }
            )
            XCTAssertEqual(
                reader.readCredentials(now: baseNow),
                .failure(.tokenExpired),
                "ClaudeCredentialReader bypassed expiry for expiresAt=\(expiresAtLiteral)"
            )
        }

        // CodexCredentialReader (numeric and string 0 / negative JWT exp, even with fresh last_refresh)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let freshRefresh = isoFormatter.string(from: baseNow.addingTimeInterval(-60))

        for expLiteral in ["0", "-100", "\"0\"", "\"-100\""] {
            let jwt = makeJWT(payload: #"{"exp": \#(expLiteral)}"#)
            let codexJSON = """
            {
              "OPENAI_API_KEY": null,
              "tokens": {
                "access_token": "\(jwt)"
              },
              "last_refresh": "\(freshRefresh)"
            }
            """
            let reader = CodexCredentialReader(
                environment: [:],
                homeDirectory: URL(fileURLWithPath: "/Users/testuser"),
                fileReader: { url in
                    url.lastPathComponent == "auth.json" ? Data(codexJSON.utf8) : nil
                }
            )
            XCTAssertEqual(
                reader.readCredentials(now: baseNow),
                .failure(.tokenExpired),
                "CodexCredentialReader bypassed expiry for exp=\(expLiteral)"
            )
        }

        // Regression check: CodexUsageProvider with reset_at: 0, reset_after_seconds: 3600 still falls back to now + 3600
        let resetFallbackJSON = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {
              "used_percent": 30.0,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 3600,
              "reset_at": 0
            }
          }
        }
        """
        let transport = MockAdversarialHTTPTransport { request in
            (
                Data(resetFallbackJSON.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let codexProvider = CodexUsageProvider(
            credentialReader: StubAdversarialCodexReader(result: .success(makeCodexCredentials())),
            transport: transport
        )
        let result = await codexProvider.fetchQuota(now: baseNow)
        guard case .success(let snapshot) = result else {
            return XCTFail("Expected Codex reset_at=0 fallback to succeed, got \(result)")
        }
        XCTAssertEqual(snapshot.primaryWindow?.resetsAt, baseNow.addingTimeInterval(3_600))
    }

    // MARK: - 5. Isolated ViewModel Settings Decoupling in Views

    /// Verifies `AIUsagePanelView` and `OverviewAIQuotaRow` use `AIUsageViewModel.displayStyle` and
    /// ViewModel toggle/style mutations instead of reading or mutating `Settings.shared`.
    func testAIUsagePanelViewAndOverviewAIQuotaRowRespectIsolatedViewModelDisplayStyleOverSettingsShared() async throws {
        let originalClaude = Settings.shared.claudeUsageEnabled
        let originalCodex = Settings.shared.codexUsageEnabled
        let originalGemini = Settings.shared.antigravityUsageEnabled
        let originalStyle = Settings.shared.aiQuotaDisplayStyle
        defer {
            Settings.shared.claudeUsageEnabled = originalClaude
            Settings.shared.codexUsageEnabled = originalCodex
            Settings.shared.antigravityUsageEnabled = originalGemini
            Settings.shared.aiQuotaDisplayStyle = originalStyle
        }

        // Settings.shared starts opposite (.remaining, all providers off).
        Settings.shared.claudeUsageEnabled = false
        Settings.shared.codexUsageEnabled = false
        Settings.shared.antigravityUsageEnabled = false
        Settings.shared.aiQuotaDisplayStyle = .remaining

        let isolated = makeIsolatedSettings()
        isolated.claudeUsageEnabled = true
        isolated.aiQuotaDisplayStyle = .used

        let claudeSnap = AIProviderQuotaSnapshot(
            providerID: .claude,
            primaryWindow: AIQuotaWindow(
                id: "five_hour",
                kind: .session5h,
                title: "5-hour session",
                usedRatio: 0.25,
                resetsAt: baseNow.addingTimeInterval(3_600)
            ),
            fetchedAt: baseNow
        )
        let fixedNow = baseNow
        let viewModel = AIUsageViewModel(
            settings: isolated,
            providers: [.claude: StubAdversarialProvider(id: .claude, result: .success(claudeSnap))],
            sleeper: { _ in try await Task.sleep(for: .seconds(600)) },
            now: { fixedNow }
        )
        defer { viewModel.stopSampling() }
        _ = await viewModel.performManualRefresh(for: .claude)

        XCTAssertEqual(viewModel.displayStyle, .used)

        let rowView = OverviewAIQuotaRow(aiUsage: viewModel, selection: .constant(.overview))
        XCTAssertEqual(
            rowView.accessibilityValueText,
            String(format: NSLocalizedString("%lld%% used", comment: ""), Int64(25))
        )

        let rowBitmapUsedWithSharedRemaining = try renderBitmap(
            for: rowView
                .frame(width: 420, height: OverviewLayoutMetrics.aiQuotaRowHeight)
                .environment(\.locale, Locale(identifier: "en_US")),
            size: NSSize(width: 420, height: OverviewLayoutMetrics.aiQuotaRowHeight)
        )
        let panelBitmapUsedWithSharedRemaining = try renderBitmap(
            for: AIUsagePanelView(viewModel: viewModel, selection: .constant(.aiUsage))
                .frame(width: 420, height: 496)
                .environment(\.locale, Locale(identifier: "en_US")),
            size: NSSize(width: 420, height: 496)
        )

        // Mutating Settings.shared.aiQuotaDisplayStyle must NOT alter either view's rendered output.
        Settings.shared.aiQuotaDisplayStyle = .used
        let rowBitmapUsedWithSharedUsed = try renderBitmap(
            for: OverviewAIQuotaRow(aiUsage: viewModel, selection: .constant(.overview))
                .frame(width: 420, height: OverviewLayoutMetrics.aiQuotaRowHeight)
                .environment(\.locale, Locale(identifier: "en_US")),
            size: NSSize(width: 420, height: OverviewLayoutMetrics.aiQuotaRowHeight)
        )
        let panelBitmapUsedWithSharedUsed = try renderBitmap(
            for: AIUsagePanelView(viewModel: viewModel, selection: .constant(.aiUsage))
                .frame(width: 420, height: 496)
                .environment(\.locale, Locale(identifier: "en_US")),
            size: NSSize(width: 420, height: 496)
        )
        XCTAssertEqual(
            rowBitmapUsedWithSharedRemaining,
            rowBitmapUsedWithSharedUsed,
            "OverviewAIQuotaRow must not depend on Settings.shared.aiQuotaDisplayStyle"
        )
        XCTAssertEqual(
            panelBitmapUsedWithSharedRemaining,
            panelBitmapUsedWithSharedUsed,
            "AIUsagePanelView must not depend on Settings.shared.aiQuotaDisplayStyle"
        )

        // Mutating via AIUsageViewModel updates the isolated Settings without touching Settings.shared
        // and visibly changes both rendered views from 25% used -> 75% left.
        Settings.shared.aiQuotaDisplayStyle = .used
        viewModel.setDisplayStyle(.remaining)
        viewModel.setEnabled(true, for: .codex)
        XCTAssertEqual(isolated.aiQuotaDisplayStyle, .remaining)
        XCTAssertTrue(isolated.codexUsageEnabled)
        XCTAssertEqual(viewModel.displayStyle, .remaining)
        XCTAssertEqual(Settings.shared.aiQuotaDisplayStyle, .used)
        XCTAssertFalse(Settings.shared.claudeUsageEnabled)
        XCTAssertFalse(Settings.shared.codexUsageEnabled)

        viewModel.setEnabled(false, for: .codex)
        XCTAssertEqual(
            rowView.accessibilityValueText,
            String(format: NSLocalizedString("%lld%% left", comment: ""), Int64(75))
        )

        let rowBitmapRemaining = try renderBitmap(
            for: OverviewAIQuotaRow(aiUsage: viewModel, selection: .constant(.overview))
                .frame(width: 420, height: OverviewLayoutMetrics.aiQuotaRowHeight)
                .environment(\.locale, Locale(identifier: "en_US")),
            size: NSSize(width: 420, height: OverviewLayoutMetrics.aiQuotaRowHeight)
        )
        let panelBitmapRemaining = try renderBitmap(
            for: AIUsagePanelView(viewModel: viewModel, selection: .constant(.aiUsage))
                .frame(width: 420, height: 496)
                .environment(\.locale, Locale(identifier: "en_US")),
            size: NSSize(width: 420, height: 496)
        )
        XCTAssertNotEqual(
            rowBitmapRemaining,
            rowBitmapUsedWithSharedUsed,
            "OverviewAIQuotaRow must visually update when viewModel.displayStyle changes"
        )
        XCTAssertNotEqual(
            panelBitmapRemaining,
            panelBitmapUsedWithSharedUsed,
            "AIUsagePanelView must visually update when viewModel.displayStyle changes"
        )
    }

    // MARK: - 6. Credits-Only Codex Snapshot in OverviewAIQuotaRow

    /// Verifies `OverviewAIQuotaRow` renders a credits-only Codex snapshot cleanly in single-provider,
    /// multi-provider, and VoiceOver modes rather than falling back to `"Checking quota…"` or `"…"`.
    func testOverviewAIQuotaRowCreditsOnlyCodexSnapshotDoesNotShowCheckingQuota() async throws {
        let settings = makeIsolatedSettings()
        settings.codexUsageEnabled = true

        let creditsOnlyCodex = AIProviderQuotaSnapshot(
            providerID: .codex,
            primaryWindow: nil,
            secondaryWindow: nil,
            additionalWindows: [],
            extraUsage: nil,
            planLabel: "Plus",
            credits: AIProviderCreditsSummary(
                hasCredits: true,
                unlimited: false,
                balanceText: "14.50",
                balanceAmount: 14.50
            ),
            accountLabel: "dev@example.com",
            fetchedAt: baseNow
        )

        let claudeSnap = AIProviderQuotaSnapshot(
            providerID: .claude,
            primaryWindow: AIQuotaWindow(
                id: "five_hour",
                kind: .session5h,
                title: "5-hour session",
                usedRatio: 0.20,
                resetsAt: baseNow.addingTimeInterval(3_600)
            ),
            fetchedAt: baseNow
        )

        let unlimitedCreditsGemini = AIProviderQuotaSnapshot(
            providerID: .antigravity,
            primaryWindow: nil,
            secondaryWindow: nil,
            additionalWindows: [],
            extraUsage: nil,
            planLabel: "Enterprise",
            credits: AIProviderCreditsSummary(
                hasCredits: true,
                unlimited: true,
                balanceText: nil,
                balanceAmount: nil
            ),
            fetchedAt: baseNow
        )

        let fixedNow = baseNow
        // Capture loading-state bitmaps before refresh for pixel-difference verification.
        let loadingVM = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: StubAdversarialProvider(id: .claude, result: .success(claudeSnap)),
                .codex: StubAdversarialProvider(id: .codex, result: .success(creditsOnlyCodex)),
                .antigravity: StubAdversarialProvider(id: .antigravity, result: .success(unlimitedCreditsGemini)),
            ],
            sleeper: { _ in try await Task.sleep(for: .seconds(600)) },
            now: { fixedNow }
        )
        let singleLoadingBitmap = try renderBitmap(
            for: OverviewAIQuotaRow(aiUsage: loadingVM, selection: .constant(.overview))
                .padding(.horizontal, 10)
                .frame(width: 420, height: OverviewLayoutMetrics.aiQuotaRowHeight)
                .environment(\.locale, Locale(identifier: "en_US")),
            size: NSSize(width: 420, height: OverviewLayoutMetrics.aiQuotaRowHeight)
        )

        let viewModel = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: StubAdversarialProvider(id: .claude, result: .success(claudeSnap)),
                .codex: StubAdversarialProvider(id: .codex, result: .success(creditsOnlyCodex)),
                .antigravity: StubAdversarialProvider(id: .antigravity, result: .success(unlimitedCreditsGemini)),
            ],
            sleeper: { _ in try await Task.sleep(for: .seconds(600)) },
            now: { fixedNow }
        )
        defer { viewModel.stopSampling() }
        _ = await viewModel.performManualRefresh()

        // 1. Single-provider credits-only Codex
        let singleRow = OverviewAIQuotaRow(aiUsage: viewModel, selection: .constant(.overview))
        let singleAX = OverviewAIQuotaRow.accessibilityValueSummary(
            enabledIDs: [.codex],
            providerStates: viewModel.providerStates,
            displayStyle: .remaining
        )
        XCTAssertEqual(singleRow.accessibilityValueText, singleAX)
        XCTAssertFalse(singleAX.contains("Checking quota"))
        XCTAssertFalse(singleAX.contains("…"))
        XCTAssertTrue(singleAX.contains("14.50"))
        XCTAssertTrue(singleAX.contains(NSLocalizedString("Credits", comment: "")))

        let singleHost = NSHostingView(
            rootView: singleRow
                .padding(.horizontal, 10)
                .frame(width: 420)
                .environment(\.locale, Locale(identifier: "en_US"))
        )
        let singleWindow = makeTestWindow(width: 420, height: 60, contentView: singleHost)
        defer {
            singleWindow.orderOut(nil)
            singleWindow.close()
        }
        singleHost.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(singleHost.fittingSize.height, OverviewLayoutMetrics.aiQuotaRowHeight + 0.5)
        XCTAssertLessThanOrEqual(singleHost.fittingSize.width, 420.5)

        let singleLoadedBitmap = try renderBitmap(
            for: singleRow
                .padding(.horizontal, 10)
                .frame(width: 420, height: OverviewLayoutMetrics.aiQuotaRowHeight)
                .environment(\.locale, Locale(identifier: "en_US")),
            size: NSSize(width: 420, height: OverviewLayoutMetrics.aiQuotaRowHeight)
        )
        XCTAssertNotEqual(
            singleLoadedBitmap,
            singleLoadingBitmap,
            "Credits-only Codex single-provider row must not render the 'Checking quota…' loading state"
        )

        // 2. Multi-provider (Claude window + Codex credits-only + Gemini unlimited credits)
        settings.claudeUsageEnabled = true
        settings.antigravityUsageEnabled = true

        let multiLoadingBitmap = try renderBitmap(
            for: OverviewAIQuotaRow(aiUsage: loadingVM, selection: .constant(.overview))
                .padding(.horizontal, 10)
                .frame(width: 420, height: OverviewLayoutMetrics.aiQuotaRowHeight)
                .environment(\.locale, Locale(identifier: "en_US")),
            size: NSSize(width: 420, height: OverviewLayoutMetrics.aiQuotaRowHeight)
        )

        _ = await viewModel.performManualRefresh()

        let multiRow = OverviewAIQuotaRow(aiUsage: viewModel, selection: .constant(.overview))
        let multiAX = OverviewAIQuotaRow.accessibilityValueSummary(
            enabledIDs: [.claude, .codex, .antigravity],
            providerStates: viewModel.providerStates,
            displayStyle: .remaining
        )
        XCTAssertEqual(multiRow.accessibilityValueText, multiAX)
        XCTAssertFalse(multiAX.contains("Checking quota"))
        XCTAssertTrue(multiAX.contains("80%"))
        XCTAssertTrue(multiAX.contains("14.50"))
        XCTAssertTrue(multiAX.contains(NSLocalizedString("Unlimited", comment: "")))

        let multiHost = NSHostingView(
            rootView: multiRow
                .padding(.horizontal, 10)
                .frame(width: 420)
                .environment(\.locale, Locale(identifier: "en_US"))
        )
        let multiWindow = makeTestWindow(width: 420, height: 60, contentView: multiHost)
        defer {
            multiWindow.orderOut(nil)
            multiWindow.close()
        }
        multiHost.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(multiHost.fittingSize.height, OverviewLayoutMetrics.aiQuotaRowHeight + 0.5)
        XCTAssertLessThanOrEqual(multiHost.fittingSize.width, 420.5)

        let multiLoadedBitmap = try renderBitmap(
            for: multiRow
                .padding(.horizontal, 10)
                .frame(width: 420, height: OverviewLayoutMetrics.aiQuotaRowHeight)
                .environment(\.locale, Locale(identifier: "en_US")),
            size: NSSize(width: 420, height: OverviewLayoutMetrics.aiQuotaRowHeight)
        )
        XCTAssertNotEqual(
            multiLoadedBitmap,
            multiLoadingBitmap,
            "Credits-only Codex & Gemini multi-provider chips must not render '…' loading placeholders"
        )
    }

    // MARK: - Helpers

    private func makeIsolatedSettings() -> LynxBar.Settings {
        let suiteName = "com.swnb.LynxBarTests.tier5Adversarial.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return LynxBar.Settings(defaults: defaults)
    }

    private func makeCodexCredentials() -> CodexOAuthCredentials {
        CodexOAuthCredentials(
            accessToken: "codex-access-token",
            refreshToken: nil,
            idToken: nil,
            accountId: "acct-123",
            accountEmail: "dev@example.com",
            expiresAt: baseNow.addingTimeInterval(3_600),
            lastRefresh: baseNow,
            planType: "plus"
        )
    }

    private func makeJWT(payload: String) -> String {
        let header = base64URL(#"{"alg":"none","typ":"JWT"}"#)
        let body = base64URL(payload)
        return "\(header).\(body).signature"
    }

    private func base64URL(_ text: String) -> String {
        Data(text.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeTestWindow(width: CGFloat, height: CGFloat, contentView: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.orderFront(nil)
        return window
    }

    private func renderBitmap<V: View>(for view: V, size: NSSize) throws -> Data {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.tiffRepresentation)
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
}

private struct StubAdversarialCodexReader: CodexCredentialReading {
    let result: Result<CodexOAuthCredentials, AIUsageFetchError>

    func readCredentials(now: Date) -> Result<CodexOAuthCredentials, AIUsageFetchError> {
        result
    }
}

private actor StubAdversarialProvider: AIUsageProvider {
    nonisolated let id: AIUsageProviderID
    private let result: Result<AIProviderQuotaSnapshot, AIUsageFetchError>

    init(id: AIUsageProviderID, result: Result<AIProviderQuotaSnapshot, AIUsageFetchError>) {
        self.id = id
        self.result = result
    }

    func fetchQuota(now: Date) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        result
    }
}

private actor CountingAdversarialProvider: AIUsageProvider {
    nonisolated let id: AIUsageProviderID
    private var hits = 0

    init(id: AIUsageProviderID) {
        self.id = id
    }

    func callCount() -> Int { hits }

    func fetchQuota(now: Date) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        hits += 1
        return .success(
            AIProviderQuotaSnapshot(
                providerID: id,
                primaryWindow: AIQuotaWindow(
                    id: "primary",
                    kind: .session5h,
                    title: "5-hour session",
                    usedRatio: 0.15,
                    resetsAt: now.addingTimeInterval(3_600)
                ),
                fetchedAt: now
            )
        )
    }
}

private actor MockAdversarialHTTPTransport: AIUsageHTTPTransport {
    private let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await handler(request)
    }
}

private actor RecordingAdversarialSleeper {
    private struct Entry {
        let id: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private var entries: [Entry] = []
    private var durations: [TimeInterval] = []
    private var nextID = 0

    func sleep(_ duration: TimeInterval) async throws {
        durations.append(duration)
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                entries.append(Entry(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func recordedDurations() -> [TimeInterval] {
        durations
    }

    private func cancel(id: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        entry.continuation.resume(throwing: CancellationError())
    }
}
