import AppKit
import Foundation
import os
import SwiftUI
import XCTest
@testable import LynxBar

/// M3 unit tests covering multi-provider `MenuBarStatusModel` / `MenuBarStatusPresenter`,
/// `OverviewAIQuotaRow` 36pt geometry, `AIUsagePanelView` onboarding & multi-card rendering,
/// `SettingsView` opt-in wiring, `Theme` provider accents, and `en` / `zh-Hans` localization parity.
@MainActor
final class AIUsageMultiProviderUITests: XCTestCase {
    private let baseNow = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - MenuBarStatusModel & Presenter Multi-Provider Tests

    func testSingleCodexAndGeminiMenuBarFormattingAndBilingualAXWithoutClaudeHardcoding() {
        let resetsAt = baseNow.addingTimeInterval(90 * 60)

        let codexReading = MenuBarMetricReading.aiQuotas(
            [MenuBarAIQuotaEntry(providerID: .codex, usedRatio: 0.35, resetsAt: resetsAt, observedAt: baseNow)],
            displayStyle: .remaining,
            staleAfter: AIUsageViewModel.menuBarTTL
        )
        let codexSnap = MenuBarStatusSnapshot(health: .healthy, readings: [.aiUsage: codexReading])

        let codexEN = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: codexSnap,
            locale: Locale(identifier: "en_US"),
            now: baseNow
        )
        let codexZH = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: codexSnap,
            locale: Locale(identifier: "zh_Hans_CN"),
            now: baseNow
        )

        XCTAssertEqual(codexEN.segments.first?.text, "AI 65%")
        XCTAssertTrue(codexEN.accessibilityLabel.contains("OpenAI Codex quota 65% remaining"))
        XCTAssertTrue(codexEN.accessibilityLabel.contains("resets in 1h 30m"))
        XCTAssertFalse(codexEN.accessibilityLabel.contains("Claude"))
        XCTAssertTrue(codexZH.accessibilityLabel.contains("OpenAI Codex 额度剩余 65%"))
        XCTAssertTrue(codexZH.accessibilityLabel.contains("1 小时 30 分后重置"))
        XCTAssertFalse(codexZH.accessibilityLabel.contains("Claude"))

        let geminiReading = MenuBarMetricReading.aiQuotas(
            [MenuBarAIQuotaEntry(providerID: .antigravity, usedRatio: 0.12, resetsAt: nil, observedAt: baseNow)],
            displayStyle: .used,
            staleAfter: AIUsageViewModel.menuBarTTL
        )
        let geminiSnap = MenuBarStatusSnapshot(health: .healthy, readings: [.aiUsage: geminiReading])

        let geminiEN = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: geminiSnap,
            locale: Locale(identifier: "en_US"),
            now: baseNow
        )
        let geminiZH = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: geminiSnap,
            locale: Locale(identifier: "zh_Hans_CN"),
            now: baseNow
        )

        XCTAssertEqual(geminiEN.segments.first?.text, "AI 12%")
        XCTAssertTrue(geminiEN.accessibilityLabel.contains("Antigravity quota 12% used"))
        XCTAssertFalse(geminiEN.accessibilityLabel.contains("Claude"))
        XCTAssertTrue(geminiZH.accessibilityLabel.contains("Antigravity 额度已用 12%"))
        XCTAssertFalse(geminiZH.accessibilityLabel.contains("Claude"))
    }

    func testMultiProviderMenuBarPicksMostConstrainedFitsBudgetsAndHandlesPartialStaleness() {
        let entries = [
            MenuBarAIQuotaEntry(providerID: .antigravity, usedRatio: 0.10, resetsAt: nil, observedAt: baseNow),
            MenuBarAIQuotaEntry(providerID: .claude, usedRatio: 0.25, resetsAt: baseNow.addingTimeInterval(3_600), observedAt: baseNow),
            MenuBarAIQuotaEntry(providerID: .codex, usedRatio: 0.80, resetsAt: baseNow.addingTimeInterval(7_200), observedAt: baseNow.addingTimeInterval(-600)),
        ]
        let reading = MenuBarMetricReading.aiQuotas(
            entries,
            displayStyle: .remaining,
            staleAfter: AIUsageViewModel.menuBarTTL
        )
        let snapshot = MenuBarStatusSnapshot(
            health: .healthy,
            readings: [
                .cpu: .numeric(0.42, observedAt: baseNow),
                .network: .numeric(1_250_000, secondary: 340_000, observedAt: baseNow),
                .aiUsage: reading,
            ]
        )

        // All 3 fresh at baseNow: Codex is most constrained (80% used -> 20% remaining).
        let focus = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "en_US"),
            now: baseNow
        )
        XCTAssertEqual(focus.segments.first?.text, "AI 20%")
        let focusLayout = MenuBarStatusRenderer.layout(for: focus)
        XCTAssertLessThanOrEqual(focusLayout.width, CGFloat(MenuBarDisplayMode.focus.widthBudget))
        XCTAssertNotEqual(focusLayout.title, "●")

        let compact = MenuBarStatusFormatter.format(
            mode: .compact,
            slots: [.cpu, .network, .aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "en_US"),
            now: baseNow
        )
        let compactLayout = MenuBarStatusRenderer.layout(for: compact)
        XCTAssertLessThanOrEqual(compactLayout.width, CGFloat(MenuBarDisplayMode.compact.widthBudget))
        XCTAssertNotEqual(compactLayout.title, "●")
        XCTAssertTrue(compactLayout.title.contains("AI 20%"))

        // AX lists all 3 active providers in canonical order (Claude, OpenAI Codex, Gemini).
        let axEN = focus.accessibilityLabel
        XCTAssertTrue(axEN.contains("Claude quota 75% remaining"))
        XCTAssertTrue(axEN.contains("OpenAI Codex quota 20% remaining"))
        XCTAssertTrue(axEN.contains("Antigravity quota 90% remaining"))

        let focusZH = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "zh_Hans_CN"),
            now: baseNow
        )
        XCTAssertTrue(focusZH.accessibilityLabel.contains("Claude 额度剩余 75%"))
        XCTAssertTrue(focusZH.accessibilityLabel.contains("OpenAI Codex 额度剩余 20%"))
        XCTAssertTrue(focusZH.accessibilityLabel.contains("Antigravity 额度剩余 90%"))

        // At baseNow + 400s: Codex (observed at baseNow - 600s) is 1000s old (> 900s TTL),
        // while Claude & Gemini are still fresh (400s <= 900s). Now Claude (75% remaining) is most constrained.
        let partialStale = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "en_US"),
            now: baseNow.addingTimeInterval(400)
        )
        XCTAssertEqual(partialStale.segments.first?.text, "AI 75%")
        XCTAssertFalse(partialStale.accessibilityLabel.contains("OpenAI Codex"))
        XCTAssertTrue(partialStale.accessibilityLabel.contains("Claude quota 75% remaining"))
        XCTAssertTrue(partialStale.accessibilityLabel.contains("Antigravity quota 90% remaining"))

        // At baseNow + 901s: all entries exceed 900s TTL -> "AI —" stale.
        let allStale = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "en_US"),
            now: baseNow.addingTimeInterval(901)
        )
        XCTAssertEqual(allStale.segments.first?.text, "AI —")
        XCTAssertTrue(allStale.accessibilityLabel.contains("stale"))
    }

    func testMenuBarStatusPresenterLiveMultiProviderUpdatesAndFallback() async {
        let settings = makeIsolatedSettings()
        settings.menuBarDisplayMode = .focus
        settings.menuBarSlots = [.aiUsage]

        let clock = MultiProviderTestClock(baseNow)
        let claudeSnap = makeSnapshot(providerID: .claude, usedRatio: 0.20, fetchedAt: baseNow, planLabel: "Pro")
        let codexSnap = makeSnapshot(providerID: .codex, usedRatio: 0.65, fetchedAt: baseNow, planLabel: "Plus")
        let geminiSnap = makeSnapshot(providerID: .antigravity, usedRatio: 0.15, fetchedAt: baseNow, planLabel: "Paid")

        let aiUsage = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: StubMultiProvider(id: .claude, result: .success(claudeSnap)),
                .codex: StubMultiProvider(id: .codex, result: .success(codexSnap)),
                .antigravity: StubMultiProvider(id: .antigravity, result: .success(geminiSnap)),
            ],
            sleeper: { _ in try await Task.sleep(for: .seconds(600)) },
            now: { clock.now() }
        )
        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { module, demanded in
            guard module == .aiUsage else { return }
            demanded ? aiUsage.startSampling() : aiUsage.stopSampling()
        }

        let store = MetricHistoryStore(fileURL: nil)
        var presentations: [MenuBarStatusPresentation] = []
        let presenter = MenuBarStatusPresenter(
            statusItem: nil,
            settings: settings,
            cpu: CPUViewModel(settings: settings, historyStore: store),
            memory: MemoryViewModel(settings: settings, historyStore: store),
            disk: DiskViewModel(settings: settings, historyStore: store),
            network: NetworkViewModel(settings: settings, historyStore: store),
            gpu: GPUViewModel(settings: settings),
            battery: BatteryViewModel(settings: settings),
            thermal: ThermalViewModel(settings: settings),
            accessoryPower: AccessoryPowerViewModel(settings: settings),
            aiUsage: aiUsage,
            demandCoordinator: coordinator,
            locale: Locale(identifier: "en_US"),
            now: { clock.now() },
            render: { presentations.append($0) }
        )
        defer {
            presenter.invalidate()
            aiUsage.stopSampling()
        }

        presenter.startDemand()
        XCTAssertEqual(presentations.last?.segments.first?.text, "AI —")

        // Enable Gemini only -> 85% remaining, AX names Gemini (never Claude).
        settings.antigravityUsageEnabled = true
        await waitUntil { presentations.last?.segments.first?.text == "AI 85%" }
        XCTAssertTrue(presentations.last?.accessibilityLabel.contains("Antigravity quota 85% remaining") == true)
        XCTAssertFalse(presentations.last?.accessibilityLabel.contains("Claude") == true)

        // Enable Codex -> 35% remaining is more constrained than 85%.
        settings.codexUsageEnabled = true
        await waitUntil { presentations.last?.segments.first?.text == "AI 35%" }
        XCTAssertTrue(presentations.last?.accessibilityLabel.contains("OpenAI Codex quota 35% remaining") == true)
        XCTAssertTrue(presentations.last?.accessibilityLabel.contains("Antigravity quota 85% remaining") == true)

        // Disable Codex -> reverts to Gemini 85%.
        settings.codexUsageEnabled = false
        await waitUntil { presentations.last?.segments.first?.text == "AI 85%" }

        // Disable Gemini -> returns to "AI —".
        settings.antigravityUsageEnabled = false
        await waitUntil { presentations.last?.segments.first?.text == "AI —" }
    }

    // MARK: - OverviewAIQuotaRow Geometry & Accessibility Tests

    func testOverviewAIQuotaRowFits36PtBudgetAcrossOneTwoAndThreeProviders() async {
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

        Settings.shared.aiUsageEnabled = false
        Settings.shared.aiQuotaDisplayStyle = .remaining

        let claudeSnap = makeSnapshot(providerID: .claude, usedRatio: 0.22, fetchedAt: baseNow, planLabel: "Max")
        let codexSnap = makeSnapshot(providerID: .codex, usedRatio: 0.45, fetchedAt: baseNow, planLabel: "Plus")
        let geminiSnap = makeSnapshot(providerID: .antigravity, usedRatio: 0.10, fetchedAt: baseNow, planLabel: "Paid")

        let fixedNow = baseNow
        let aiUsage = AIUsageViewModel(
            settings: LynxBar.Settings.shared,
            providers: [
                .claude: StubMultiProvider(id: .claude, result: .success(claudeSnap)),
                .codex: StubMultiProvider(id: .codex, result: .failure(.tokenExpired)),
                .antigravity: StubMultiProvider(id: .antigravity, result: .success(geminiSnap)),
            ],
            sleeper: { _ in try await Task.sleep(for: .seconds(600)) },
            now: { fixedNow }
        )
        defer { aiUsage.stopSampling() }

        let scenarios: [[AIUsageProviderID]] = [
            [.claude],
            [.codex],
            [.claude, .codex],
            [.claude, .codex, .antigravity],
        ]

        for activeIDs in scenarios {
            Settings.shared.claudeUsageEnabled = activeIDs.contains(.claude)
            Settings.shared.codexUsageEnabled = activeIDs.contains(.codex)
            Settings.shared.antigravityUsageEnabled = activeIDs.contains(.antigravity)
            _ = await aiUsage.performManualRefresh()

            let rowView = OverviewAIQuotaRow(aiUsage: aiUsage, selection: .constant(.overview))
                .padding(.horizontal, 10)
                .frame(width: 420)
            let host = NSHostingView(rootView: rowView)
            let window = makeTestWindow(width: 420, height: 60, contentView: host)
            defer {
                window.orderOut(nil)
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()

            XCTAssertLessThanOrEqual(
                host.fittingSize.height,
                OverviewLayoutMetrics.aiQuotaRowHeight + 0.5,
                "OverviewAIQuotaRow exceeded 36pt for providers: \(activeIDs)"
            )
            XCTAssertLessThanOrEqual(
                host.fittingSize.width,
                420.5,
                "OverviewAIQuotaRow exceeded 420pt width for providers: \(activeIDs)"
            )
        }

        // Also test 3 providers all loaded simultaneously.
        let allLoadedVM = AIUsageViewModel(
            settings: LynxBar.Settings.shared,
            providers: [
                .claude: StubMultiProvider(id: .claude, result: .success(claudeSnap)),
                .codex: StubMultiProvider(id: .codex, result: .success(codexSnap)),
                .antigravity: StubMultiProvider(id: .antigravity, result: .success(geminiSnap)),
            ],
            sleeper: { _ in try await Task.sleep(for: .seconds(600)) },
            now: { fixedNow }
        )
        defer { allLoadedVM.stopSampling() }
        Settings.shared.claudeUsageEnabled = true
        Settings.shared.codexUsageEnabled = true
        Settings.shared.antigravityUsageEnabled = true
        _ = await allLoadedVM.performManualRefresh()

        let threeLoadedHost = NSHostingView(
            rootView: OverviewAIQuotaRow(aiUsage: allLoadedVM, selection: .constant(.overview))
                .padding(.horizontal, 10)
                .frame(width: 420)
        )
        let threeWindow = makeTestWindow(width: 420, height: 60, contentView: threeLoadedHost)
        defer {
            threeWindow.orderOut(nil)
            threeWindow.close()
        }
        threeLoadedHost.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(threeLoadedHost.fittingSize.height, OverviewLayoutMetrics.aiQuotaRowHeight + 0.5)
        XCTAssertLessThanOrEqual(threeLoadedHost.fittingSize.width, 420.5)

        // Verify accessibilityValueSummary includes all 3 provider names without Claude hardcoding.
        let summary = OverviewAIQuotaRow.accessibilityValueSummary(
            enabledIDs: [.claude, .codex, .antigravity],
            providerStates: allLoadedVM.providerStates,
            displayStyle: .remaining
        )
        XCTAssertTrue(summary.contains("Claude"))
        XCTAssertTrue(summary.contains("78%"))
        XCTAssertTrue(summary.contains("OpenAI Codex"))
        XCTAssertTrue(summary.contains("55%"))
        XCTAssertTrue(summary.contains("Antigravity"))
        XCTAssertTrue(summary.contains("90%"))

        let codexOnlySummary = OverviewAIQuotaRow.accessibilityValueSummary(
            enabledIDs: [.codex],
            providerStates: allLoadedVM.providerStates,
            displayStyle: .remaining
        )
        XCTAssertTrue(codexOnlySummary.contains("55%"))
        XCTAssertFalse(codexOnlySummary.contains("Claude"))
    }

    func testOverviewAIQuotaRowThreeSimultaneousStale100PercentProvidersFitWithinBudget() async {
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

        Settings.shared.claudeUsageEnabled = true
        Settings.shared.codexUsageEnabled = true
        Settings.shared.antigravityUsageEnabled = true
        Settings.shared.aiQuotaDisplayStyle = .remaining

        let clock = MultiProviderTestClock(baseNow)
        let claudeStub = SequentialStubMultiProvider(
            id: .claude,
            results: [
                .success(makeSnapshot(providerID: .claude, usedRatio: 0.0, fetchedAt: baseNow, planLabel: "Max")),
                .failure(.rateLimited(retryAfter: 120)),
            ]
        )
        let codexStub = SequentialStubMultiProvider(
            id: .codex,
            results: [
                .success(makeSnapshot(providerID: .codex, usedRatio: 0.0, fetchedAt: baseNow, planLabel: "Plus")),
                .failure(.networkFailure("offline")),
            ]
        )
        let geminiStub = SequentialStubMultiProvider(
            id: .antigravity,
            results: [
                .success(makeSnapshot(providerID: .antigravity, usedRatio: 0.0, fetchedAt: baseNow, planLabel: "Paid")),
                .failure(.tokenExpired),
            ]
        )

        let aiUsage = AIUsageViewModel(
            settings: LynxBar.Settings.shared,
            providers: [
                .claude: claudeStub,
                .codex: codexStub,
                .antigravity: geminiStub,
            ],
            sleeper: { _ in try await Task.sleep(for: .seconds(600)) },
            now: { clock.now() }
        )
        defer { aiUsage.stopSampling() }

        _ = await aiUsage.performManualRefresh()
        clock.advance(by: 10)
        _ = await aiUsage.performManualRefresh()

        for providerID in AIUsageProviderID.allCases {
            XCTAssertNotNil(aiUsage.snapshot(for: providerID), "\(providerID) should retain stale snapshot")
            XCTAssertNotNil(aiUsage.lastError(for: providerID), "\(providerID) should record stale error")
        }

        for localeID in ["en_US", "zh_Hans_CN"] {
            let idealHost = NSHostingView(
                rootView: OverviewAIQuotaRow(aiUsage: aiUsage, selection: .constant(.overview))
                    .environment(\.locale, Locale(identifier: localeID))
            )
            let idealWindow = makeTestWindow(width: 480, height: 60, contentView: idealHost)
            defer {
                idealWindow.orderOut(nil)
                idealWindow.close()
            }
            idealHost.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
            idealHost.layoutSubtreeIfNeeded()

            XCTAssertEqual(
                idealHost.fittingSize.height,
                OverviewLayoutMetrics.aiQuotaRowHeight,
                accuracy: 0.5,
                "Row height drifted for locale \(localeID)"
            )
            XCTAssertLessThanOrEqual(
                idealHost.fittingSize.width,
                390.0,
                "3 simultaneous stale 100% chips ideal width (\(idealHost.fittingSize.width)) exceeded 390pt for locale \(localeID)"
            )

            let constrainedHost = NSHostingView(
                rootView: OverviewAIQuotaRow(aiUsage: aiUsage, selection: .constant(.overview))
                    .padding(.horizontal, 10)
                    .frame(width: 420)
                    .environment(\.locale, Locale(identifier: localeID))
            )
            let constrainedWindow = makeTestWindow(width: 420, height: 60, contentView: constrainedHost)
            defer {
                constrainedWindow.orderOut(nil)
                constrainedWindow.close()
            }
            constrainedHost.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
            constrainedHost.layoutSubtreeIfNeeded()

            XCTAssertEqual(
                constrainedHost.fittingSize.height,
                OverviewLayoutMetrics.aiQuotaRowHeight,
                accuracy: 0.5,
                "Constrained row height drifted for locale \(localeID)"
            )
            XCTAssertLessThanOrEqual(
                constrainedHost.fittingSize.width,
                420.5,
                "Constrained row overflowed 420pt for locale \(localeID)"
            )
        }
    }

    // MARK: - AIUsagePanelView & SettingsView Hosting Tests

    func testAIUsagePanelViewOnboardingAndMultiCardHostingFit420Width() async {
        let originalClaude = Settings.shared.claudeUsageEnabled
        let originalCodex = Settings.shared.codexUsageEnabled
        let originalGemini = Settings.shared.antigravityUsageEnabled
        defer {
            Settings.shared.claudeUsageEnabled = originalClaude
            Settings.shared.codexUsageEnabled = originalCodex
            Settings.shared.antigravityUsageEnabled = originalGemini
        }

        // 1. Empty state (0 providers enabled) -> onboarding renders cleanly with zero provider fetches.
        Settings.shared.aiUsageEnabled = false
        let claudeSpy = StubMultiProvider(
            id: .claude,
            result: .success(makeSnapshot(providerID: .claude, usedRatio: 0.25, fetchedAt: baseNow, planLabel: "Pro"))
        )
        let codexRichSnap = AIProviderQuotaSnapshot(
            providerID: .codex,
            primaryWindow: AIQuotaWindow(
                id: "codex-primary",
                kind: .session5h,
                title: "5-hour session",
                usedRatio: 0.40,
                resetsAt: baseNow.addingTimeInterval(3_600)
            ),
            secondaryWindow: AIQuotaWindow(
                id: "codex-secondary",
                kind: .weekly7d,
                title: "7-day weekly",
                usedRatio: 0.55,
                resetsAt: baseNow.addingTimeInterval(86_400)
            ),
            additionalWindows: [
                AIQuotaWindow(
                    id: "codex-code-review",
                    kind: .codeReview,
                    title: "Code Review",
                    usedRatio: 0.15,
                    resetsAt: nil
                ),
            ],
            extraUsage: nil,
            planLabel: "Plus",
            credits: AIProviderCreditsSummary(hasCredits: true, unlimited: false, balanceText: "14.50", balanceAmount: 14.5),
            accountLabel: "dev@example.com",
            fetchedAt: baseNow
        )
        let geminiSpy = StubMultiProvider(id: .antigravity, result: .failure(.credentialsMissing))

        let fixedNow = baseNow
        let vm = AIUsageViewModel(
            settings: LynxBar.Settings.shared,
            providers: [
                .claude: claudeSpy,
                .codex: StubMultiProvider(id: .codex, result: .success(codexRichSnap)),
                .antigravity: geminiSpy,
            ],
            sleeper: { _ in try await Task.sleep(for: .seconds(600)) },
            now: { fixedNow }
        )
        defer { vm.stopSampling() }
        vm.startSampling()

        let onboardingHost = NSHostingView(
            rootView: AIUsagePanelView(viewModel: vm, selection: .constant(.aiUsage))
                .frame(width: 420, height: 496)
        )
        let onboardingWindow = makeTestWindow(width: 420, height: 496, contentView: onboardingHost)
        defer {
            onboardingWindow.orderOut(nil)
            onboardingWindow.close()
        }
        onboardingHost.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(onboardingHost.fittingSize.width, 420.5)
        let claudeCallsWhenOff = await claudeSpy.callCount
        let geminiCallsWhenOff = await geminiSpy.callCount
        XCTAssertEqual(claudeCallsWhenOff, 0)
        XCTAssertEqual(geminiCallsWhenOff, 0)

        // 2. Multi-provider state: Claude + Codex (with credits & Code Review) + Gemini (error remediation).
        Settings.shared.claudeUsageEnabled = true
        Settings.shared.codexUsageEnabled = true
        Settings.shared.antigravityUsageEnabled = true
        _ = await vm.performManualRefresh()

        let multiHost = NSHostingView(
            rootView: AIUsagePanelView(viewModel: vm, selection: .constant(.aiUsage))
                .frame(width: 420, height: 496)
        )
        let multiWindow = makeTestWindow(width: 420, height: 496, contentView: multiHost)
        defer {
            multiWindow.orderOut(nil)
            multiWindow.close()
        }
        multiHost.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(30))
        multiHost.layoutSubtreeIfNeeded()

        XCTAssertEqual(vm.enabledProviderIDs, [.claude, .codex, .antigravity])
        XCTAssertNotNil(vm.snapshot(for: .claude))
        XCTAssertNotNil(vm.snapshot(for: .codex))
        XCTAssertEqual(vm.lastError(for: .antigravity), .credentialsMissing)
        XCTAssertLessThanOrEqual(multiHost.fittingSize.width, 420.5)

        // 3. SettingsView hosts cleanly with all 3 independent toggles.
        let settingsHost = NSHostingView(
            rootView: SettingsView()
                .frame(width: 420, height: 496)
        )
        let settingsWindow = makeTestWindow(width: 420, height: 496, contentView: settingsHost)
        defer {
            settingsWindow.orderOut(nil)
            settingsWindow.close()
        }
        settingsHost.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(settingsHost.fittingSize.width, 420.5)
    }

    func testAIUsagePanelViewLongModelTitleAndFooterRenderWithoutOverflowAt420Width() async {
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

        Settings.shared.claudeUsageEnabled = false
        Settings.shared.codexUsageEnabled = true
        Settings.shared.antigravityUsageEnabled = false
        Settings.shared.aiQuotaDisplayStyle = .remaining

        let longTitleSnap = AIProviderQuotaSnapshot(
            providerID: .codex,
            primaryWindow: AIQuotaWindow(
                id: "codex-long-model",
                kind: .modelQuota,
                title: "GPT-5.3-Codex-Spark-Preview (5-hour)",
                usedRatio: 0.0,
                resetsAt: baseNow.addingTimeInterval(6 * 86_400 + 23 * 3_600)
            ),
            secondaryWindow: AIQuotaWindow(
                id: "codex-weekly",
                kind: .weekly7d,
                title: "7-day weekly",
                usedRatio: 0.12,
                resetsAt: baseNow.addingTimeInterval(4 * 86_400)
            ),
            additionalWindows: [],
            extraUsage: nil,
            planLabel: "Pro",
            credits: nil,
            accountLabel: "dev@example.com",
            fetchedAt: baseNow
        )

        let fixedNow = baseNow
        let vm = AIUsageViewModel(
            settings: LynxBar.Settings.shared,
            providers: [
                .codex: StubMultiProvider(id: .codex, result: .success(longTitleSnap)),
            ],
            sleeper: { _ in try await Task.sleep(for: .seconds(600)) },
            now: { fixedNow }
        )
        defer { vm.stopSampling() }
        _ = await vm.performManualRefresh()

        for localeID in ["en_US", "zh_Hans_CN"] {
            let host = NSHostingView(
                rootView: AIUsagePanelView(viewModel: vm, selection: .constant(.aiUsage))
                    .frame(width: 420, height: 496)
                    .environment(\.locale, Locale(identifier: localeID))
            )
            let window = makeTestWindow(width: 420, height: 496, contentView: host)
            defer {
                window.orderOut(nil)
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()

            XCTAssertLessThanOrEqual(
                host.fittingSize.width,
                420.5,
                "AIUsagePanelView overflowed 420pt width with long model title for locale \(localeID)"
            )
        }
    }

    // MARK: - Theme Additive Provider Accents & Localization Parity

    func testAdditiveAIProviderAccentsMeetContrastAndAppearancesDiffer() {
        let pairs: [(String, NSColor)] = [
            ("aiUsage", Theme.nsAiUsage),
            ("aiCodex", Theme.nsAiCodex),
            ("aiAntigravity", Theme.nsAiAntigravity),
        ]
        for (name, color) in pairs {
            let light = color.resolved(for: .aqua)
            let dark = color.resolved(for: .darkAqua)
            XCTAssertNotEqual(light, dark, "\(name) must adapt to light/dark appearance")

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let surfaceRatio = Theme.contrastRatio(
                    color.resolved(for: appearance),
                    Theme.nsSurface.resolved(for: appearance)
                )
                XCTAssertGreaterThanOrEqual(
                    surfaceRatio,
                    4.5,
                    "\(appearance.rawValue) \(name) contrast \(surfaceRatio) < 4.5"
                )
            }
        }
    }

    func testLocalizationFilesHaveZeroDuplicatesFullKeysetParityAndMatchingFormatSpecifiers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enURL = root.appendingPathComponent("Sources/LynxBar/Resources/en.lproj/Localizable.strings")
        let zhURL = root.appendingPathComponent("Sources/LynxBar/Resources/zh-Hans.lproj/Localizable.strings")

        let enParsed = try parseLocalizableStrings(at: enURL)
        let zhParsed = try parseLocalizableStrings(at: zhURL)

        XCTAssertTrue(enParsed.duplicates.isEmpty, "Duplicate keys in en.lproj: \(enParsed.duplicates)")
        XCTAssertTrue(zhParsed.duplicates.isEmpty, "Duplicate keys in zh-Hans.lproj: \(zhParsed.duplicates)")

        let enKeys = Set(enParsed.entries.keys)
        let zhKeys = Set(zhParsed.entries.keys)
        XCTAssertEqual(enKeys, zhKeys, "Mismatch between en and zh-Hans localization keys")

        // Verify key M3 provider & UI keys exist.
        for requiredKey in [
            "OpenAI Codex", "Codex", "Antigravity", "Antigravity CLI", "Code Review", "Model Quota",
            "Credits", "Unlimited",
            "AI Subscription Quota", "OpenAI Codex subscription quota", "Antigravity subscription quota",
            "All AI quota providers are off in Privacy. The menu bar slot displays AI — without making network requests.",
            "High swap", "Elevated",
        ] {
            XCTAssertTrue(enKeys.contains(requiredKey), "Missing key: \(requiredKey)")
        }

        let specifierRegex = try NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:ll|l)?[@dfs]|%\\.\\d+f|%%")
        for key in enKeys.intersection(zhKeys) {
            let enSpecs = formatSpecifiers(in: enParsed.entries[key] ?? "", regex: specifierRegex)
            let zhSpecs = formatSpecifiers(in: zhParsed.entries[key] ?? "", regex: specifierRegex)
            XCTAssertEqual(enSpecs, zhSpecs, "Format specifier mismatch for key '\(key)'")
        }
    }

    // MARK: - Helpers

    private func makeSnapshot(
        providerID: AIUsageProviderID,
        usedRatio: Double,
        fetchedAt: Date,
        planLabel: String?
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
            planLabel: planLabel,
            fetchedAt: fetchedAt
        )
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

    private func makeIsolatedSettings() -> LynxBar.Settings {
        let suiteName = "com.swnb.LynxBarTests.m3UI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return LynxBar.Settings(defaults: defaults)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition not met within deadline")
    }

    private func parseLocalizableStrings(at url: URL) throws -> (entries: [String: String], duplicates: [String]) {
        let content = try String(contentsOf: url, encoding: .utf8)
        let nsContent = content as NSString
        let regex = try NSRegularExpression(
            pattern: "\"((?:\\\\.|[^\"\\\\])*)\"\\s*=\\s*\"((?:\\\\.|[^\"\\\\])*)\"\\s*;",
            options: []
        )
        var entries: [String: String] = [:]
        var duplicates: [String] = []
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        for match in matches {
            let key = nsContent.substring(with: match.range(at: 1))
            let value = nsContent.substring(with: match.range(at: 2))
            if entries[key] != nil {
                duplicates.append(key)
            }
            entries[key] = value
        }
        return (entries, duplicates)
    }

    private func formatSpecifiers(in text: String, regex: NSRegularExpression) -> [String] {
        let nsText = text as NSString
        return regex
            .matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { nsText.substring(with: $0.range) }
            .sorted()
    }
}

private final class MultiProviderTestClock: Sendable {
    private let storage: OSAllocatedUnfairLock<Date>

    init(_ initial: Date) {
        self.storage = OSAllocatedUnfairLock(initialState: initial)
    }

    func now() -> Date { storage.withLock { $0 } }

    func advance(by interval: TimeInterval) {
        storage.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

private actor StubMultiProvider: AIUsageProvider {
    nonisolated let id: AIUsageProviderID
    let result: Result<AIProviderQuotaSnapshot, AIUsageFetchError>
    private(set) var callCount: Int = 0

    init(id: AIUsageProviderID, result: Result<AIProviderQuotaSnapshot, AIUsageFetchError>) {
        self.id = id
        self.result = result
    }

    func fetchQuota(now: Date) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        callCount += 1
        return result
    }
}

private actor SequentialStubMultiProvider: AIUsageProvider {
    nonisolated let id: AIUsageProviderID
    private let results: [Result<AIProviderQuotaSnapshot, AIUsageFetchError>]
    private var index = 0

    init(id: AIUsageProviderID, results: [Result<AIProviderQuotaSnapshot, AIUsageFetchError>]) {
        self.id = id
        self.results = results
    }

    func fetchQuota(now: Date) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        let current = results[min(index, max(0, results.count - 1))]
        index += 1
        return current
    }
}
