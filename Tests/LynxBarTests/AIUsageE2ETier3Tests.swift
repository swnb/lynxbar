import AppKit
import CodexBarCore
import Foundation
import os
import SwiftUI
import XCTest
@testable import LynxBar

/// Tier 3 Opaque-Box E2E Tests: 24 Pairwise Cross-Feature Combination Tests.
@MainActor
final class AIUsageE2ETier3Tests: XCTestCase {
    private let cleanup = E2ECleanupTracker()

    override func tearDown() {
        cleanup.cleanupAll()
        super.tearDown()
    }

    private func makeIsolatedSettings() -> LynxBar.Settings {
        let (settings, suite, _) = E2EIsolatedStore.makeSettings()
        cleanup.registerSuite(suite)
        return settings
    }

    private func makeTempHome() throws -> E2ETempHomeFixture {
        let home = try E2ETempHomeFixture()
        cleanup.registerHome(home)
        return home
    }

    // P1: F3 x F5
    func testP01_claudeAndCodexCredentialsPresentOnlyClaudeEnabledLeavesCodexUntouched() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true

        let claudeReader = E2ESpyClaudeCredentialReader(result: .success(
            ClaudeOAuthCredentials(accessToken: "sk-claude", expiresAt: now.addingTimeInterval(600), subscriptionType: "max", rateLimitTier: nil)
        ))
        let codexReader = E2ESpyCodexCredentialReader(result: .success(
            CodexOAuthCredentials(accessToken: "sk-codex", refreshToken: nil, idToken: nil, accountId: "acct_1", accountEmail: nil, expiresAt: now.addingTimeInterval(600), lastRefresh: now, planType: "pro")
        ))

        let claudeTransport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((E2EFixtureFactory.claudeUsageJSON(), E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)))
        ])
        let codexTransport = E2ERecordingHTTPTransport(scriptedQueue: [])

        let vm = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: ClaudeUsageProvider(credentialReader: claudeReader, transport: claudeTransport),
                .codex: CodexUsageProvider(credentialReader: codexReader, transport: codexTransport),
            ],
            now: { now }
        )

        _ = await vm.performManualRefresh()
        XCTAssertEqual(claudeReader.callCount, 1)
        XCTAssertEqual(codexReader.callCount, 0)
        let codexHTTPCalls = await codexTransport.callCount
        XCTAssertEqual(codexHTTPCalls, 0)
        XCTAssertNotNil(vm.snapshot(for: .claude))
        XCTAssertEqual(vm.state(for: .codex), .disabled)
    }

    // P2: F5 x F6
    func testP02_codexCustomHomeAndAccountIdFlowThroughToWhamUsageRequest() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let home = try makeTempHome()
        let codexDir = home.rootURL.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let jwt = E2EFixtureFactory.makeJWT(claims: [
            "exp": now.timeIntervalSince1970 + 1800,
            "email": "codex-user@example.com",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "team"],
        ])
        try E2EFixtureFactory.codexAuthJSON(accessToken: jwt, accountId: "acct_pair_2")
            .write(to: codexDir.appendingPathComponent("auth.json"))

        let reader = CodexCredentialReader(environment: ["CODEX_HOME": codexDir.path], homeDirectory: home.rootURL)
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((E2EFixtureFactory.codexUsageJSON(planType: "team", primaryUsedPercent: 30, secondaryUsedPercent: 15), E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)))
        ])
        let provider = CodexUsageProvider(credentialReader: reader, transport: transport)
        let result = await provider.fetchQuota(now: now)

        guard case .success(let snap) = result else {
            return XCTFail("Expected Codex P2 success, got \(result)")
        }
        let reqs = await transport.requests
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs[0].value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct_pair_2")
        XCTAssertEqual(snap.planLabel, "Team")
        XCTAssertEqual(snap.accountLabel, "codex-user@example.com")
        XCTAssertEqual(snap.primaryWindow?.usedRatio ?? -1, 0.30, accuracy: 0.0001)
    }

    // P3: F7 x F8
    func testP03_antigravityCodexBarContextAndExtraWindowPromotionWithIdentity() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Models",
                    window: RateWindow(usedPercent: 65, windowMinutes: 300, resetsAt: now.addingTimeInterval(3_600), resetDescription: nil),
                    usageKnown: true
                ),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude and GPT",
                    window: RateWindow(usedPercent: 50, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400), resetDescription: nil),
                    usageKnown: true
                ),
            ],
            updatedAt: now,
            identity: ProviderIdentitySnapshot(providerID: .antigravity, accountEmail: "agy@example.com", accountOrganization: nil, loginMethod: "Google AI Pro")
        )
        let fetchResult = ProviderFetchResult(usage: usage, credits: nil, dashboard: nil, sourceLabel: "antigravity", strategyID: "antigravity", strategyKind: .localProbe)
        let provider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { upstream, context in
            XCTAssertEqual(upstream, .antigravity)
            XCTAssertEqual(context.settings?.claude?.cookieSource, .off)
            XCTAssertTrue(context.persistsCLISessions)
            return ProviderFetchOutcome(result: .success(fetchResult), attempts: [])
        }

        guard case .success(let snap) = await provider.fetchQuota(now: now) else {
            return XCTFail("Expected Antigravity P3 success")
        }
        XCTAssertEqual(snap.primaryWindow?.usedRatio ?? -1, 0.65, accuracy: 0.0001)
        XCTAssertEqual(snap.secondaryWindow?.usedRatio ?? -1, 0.50, accuracy: 0.0001)
        XCTAssertEqual(snap.planLabel, "Google AI Pro")
        XCTAssertEqual(snap.accountLabel, "agy@example.com")
    }

    // P4: F4 x F9
    func testP04_claude200FollowedBy429RetryAfter45RetainsStaleAndRespects45sBackoff() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let reader = E2ESpyClaudeCredentialReader(result: .success(ClaudeOAuthCredentials(accessToken: "t", expiresAt: nil, subscriptionType: "max", rateLimitTier: nil)))
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((E2EFixtureFactory.claudeUsageJSON(fiveHourPercent: 35, sevenDayPercent: 50), E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200))),
            .success((Data(), E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 429, headers: ["Retry-After": "45"]))),
        ])
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: ClaudeUsageProvider(credentialReader: reader, transport: transport)],
            sleeper: { try await sleeper.sleep($0) }
        )

        vm.startSampling()
        await sleeper.waitUntilPendingCount(atLeast: 1) // 300s after 200
        await sleeper.resumeNext()
        await sleeper.waitUntilPendingCount(atLeast: 1) // 45s after 429

        let delays = await sleeper.recordedDelays
        XCTAssertEqual(delays, [300, 45])
        if case .stale(let snap, let err) = vm.state(for: .claude) {
            XCTAssertEqual(snap.primaryWindow?.usedRatio ?? -1, 0.35, accuracy: 0.0001)
            XCTAssertEqual(err, .rateLimited(retryAfter: 45))
        } else {
            XCTFail("Expected .stale state")
        }
        vm.stopSampling()
    }

    // P5: F6 x F9
    func testP05_codex200FollowedBy401RetainsStaleUnauthorizedAndHaltsAutoRetry() async {
        let settings = makeIsolatedSettings()
        settings.codexUsageEnabled = true
        let reader = E2ESpyCodexCredentialReader(result: .success(CodexOAuthCredentials(accessToken: "t", refreshToken: nil, idToken: nil, accountId: nil, accountEmail: nil, expiresAt: nil, lastRefresh: nil, planType: "pro")))
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((E2EFixtureFactory.codexUsageJSON(primaryUsedPercent: 20), E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200))),
            .success((Data(), E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 401))),
        ])
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.codex: CodexUsageProvider(credentialReader: reader, transport: transport)],
            sleeper: { try await sleeper.sleep($0) }
        )

        vm.startSampling()
        await sleeper.waitUntilPendingCount(atLeast: 1)
        await sleeper.resumeNext()
        let becameStale = await E2EAsync.waitUntil {
            if case .stale(_, .unauthorized) = vm.state(for: .codex) { return true }
            return false
        }
        XCTAssertTrue(becameStale)
        let pending = await sleeper.pendingCount
        XCTAssertEqual(pending, 0)
        vm.stopSampling()
    }

    // P6: F8 x F9
    func testP06_antigravityUpstreamUnavailableMapsToEndpointUnavailable503() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let provider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
            ProviderFetchOutcome(
                result: .failure(ProviderFetchClassifiedError(kind: .providerUnavailable, message: "service unavailable")),
                attempts: []
            )
        }
        let result = await provider.fetchQuota(now: now)
        XCTAssertEqual(result, .failure(.endpointUnavailable(statusCode: 503)))
    }

    // P7: F10 x F11
    func testP07_claudeAndAntigravityEnabledCodexDisabledFetchesOnlyClaudeAndAntigravity() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = false
        settings.antigravityUsageEnabled = true

        let claude = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.1)))
        let codex = E2ESpyAIUsageProvider(id: .codex)
        let antigravity = E2ESpyAIUsageProvider(id: .antigravity, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .antigravity, usedRatio: 0.2)))
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(settings: settings, providers: [.claude: claude, .codex: codex, .antigravity: antigravity], sleeper: { try await sleeper.sleep($0) })

        vm.startSampling()
        await claude.waitForFetchStart(atLeast: 1)
        await antigravity.waitForFetchStart(atLeast: 1)
        await sleeper.waitUntilPendingCount(atLeast: 2)

        let c1 = await claude.callCount
        let c2 = await codex.callCount
        let c3 = await antigravity.callCount
        XCTAssertEqual(c1, 1)
        XCTAssertEqual(c2, 0)
        XCTAssertEqual(c3, 1)
        vm.stopSampling()
    }

    // P8: F10 x F12
    func testP08_enablingCodexWhileClaudePollingDoesNotResetClaudeCadence() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let claude = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.2)))
        let codex = E2ESpyAIUsageProvider(id: .codex, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.4)))
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(settings: settings, providers: [.claude: claude, .codex: codex], sleeper: { try await sleeper.sleep($0) }, now: clock.makeProvider())

        vm.startSampling()
        await claude.waitForFetchStart(atLeast: 1)
        await sleeper.waitUntilPendingCount(atLeast: 1)

        settings.codexUsageEnabled = true
        await codex.waitForFetchStart(atLeast: 1)
        await sleeper.waitUntilPendingCount(atLeast: 2)

        let c1 = await claude.callCount
        let c2 = await codex.callCount
        XCTAssertEqual(c1, 1)
        XCTAssertEqual(c2, 1)
        vm.stopSampling()
    }

    // P9: F11 x F12
    func testP09_demandCoordinatorRefcountLifecycleForAntigravityOnly() async {
        let settings = makeIsolatedSettings()
        settings.antigravityUsageEnabled = true
        let claude = E2ESpyAIUsageProvider(id: .claude)
        let codex = E2ESpyAIUsageProvider(id: .codex)
        let antigravity = E2ESpyAIUsageProvider(id: .antigravity, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .antigravity, usedRatio: 0.5)))
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(settings: settings, providers: [.claude: claude, .codex: codex, .antigravity: antigravity], sleeper: { try await sleeper.sleep($0) })

        let coordinator = MonitoringDemandCoordinator()
        var edges: [Bool] = []
        coordinator.onDemandChange = { module, active in
            if module == .aiUsage {
                edges.append(active)
                if active { vm.startSampling() } else { vm.stopSampling() }
            }
        }

        let owner = E2ETestDemandOwner()
        let t1 = coordinator.acquire(module: .aiUsage, reason: .panel(.overview), owner: owner)
        let t2 = coordinator.acquire(module: .aiUsage, reason: .panel(.aiUsage), owner: owner)
        await antigravity.waitForFetchStart(atLeast: 1)
        await sleeper.waitUntilPendingCount(atLeast: 1)
        XCTAssertEqual(coordinator.demandCount(for: .aiUsage), 2)
        XCTAssertEqual(edges, [true])

        t1.cancel()
        XCTAssertEqual(coordinator.demandCount(for: .aiUsage), 1)
        XCTAssertEqual(edges, [true])

        t2.cancel()
        XCTAssertEqual(coordinator.demandCount(for: .aiUsage), 0)
        XCTAssertEqual(edges, [true, false])
        let c1 = await claude.callCount
        let c2 = await codex.callCount
        XCTAssertEqual(c1 + c2, 0)
    }

    // P10: F12 x F13
    func testP10_mixedLoadedStaleErrorStatesRenderSimultaneouslyInPanel() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        settings.antigravityUsageEnabled = true

        let claude = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.25)))
        let codex = E2ESpyAIUsageProvider(
            id: .codex,
            results: [
                .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.45)),
                .failure(.networkFailure("timeout")),
            ]
        )
        let antigravity = E2ESpyAIUsageProvider(id: .antigravity, fallback: .failure(.tokenExpired))

        let vm = AIUsageViewModel(settings: settings, providers: [.claude: claude, .codex: codex, .antigravity: antigravity], now: clock.makeProvider())
        _ = await vm.performManualRefresh()
        clock.advance(by: 10)
        _ = await vm.performManualRefresh(for: .codex)

        if case .loaded = vm.state(for: .claude),
           case .stale(_, .networkFailure) = vm.state(for: .codex),
           case .error(.tokenExpired) = vm.state(for: .antigravity) {
            // Expected simultaneous states
        } else {
            return XCTFail("Unexpected provider states: \(vm.providerStates)")
        }

        var sel: DashboardSection = .aiUsage
        let host = NSHostingView(rootView: AIUsagePanelView(viewModel: vm, selection: Binding(get: { sel }, set: { sel = $0 })))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 200)
        XCTAssertEqual(AIUsageProviderID.antigravity.cliLoginCommand, "agy login")
    }

    // P11: F10 x F13
    func testP11_displayStyleChangeUpdatesViewModelAndOverviewSummaryImmediately() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.30)))]
        )
        _ = await vm.performManualRefresh()
        XCTAssertEqual(vm.displayStyle, .remaining)

        let rem = OverviewAIQuotaRow.accessibilityValueSummary(enabledIDs: [.claude], providerStates: vm.providerStates, displayStyle: vm.displayStyle)
        XCTAssertTrue(rem.contains("70"))

        settings.aiQuotaDisplayStyle = .used
        let updated = await E2EAsync.waitUntil { vm.displayStyle == .used }
        XCTAssertTrue(updated)
        let used = OverviewAIQuotaRow.accessibilityValueSummary(enabledIDs: [.claude], providerStates: vm.providerStates, displayStyle: vm.displayStyle)
        XCTAssertTrue(used.contains("30"))
    }

    // P12: F13 x F14
    func testP12_enablingOneToThreeProvidersPreserves36ptOverviewRowAnd496Budget() async {
        let settings = makeIsolatedSettings()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.1))),
                .codex: E2ESpyAIUsageProvider(id: .codex, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.2))),
                .antigravity: E2ESpyAIUsageProvider(id: .antigravity, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .antigravity, usedRatio: 0.3))),
            ]
        )

        for id in AIUsageProviderID.allCases {
            settings.setAIProviderEnabled(true, for: id)
            _ = await vm.performManualRefresh(for: id)
            var sel: DashboardSection = .overview
            let host = NSHostingView(rootView: OverviewAIQuotaRow(aiUsage: vm, selection: Binding(get: { sel }, set: { sel = $0 })))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 36)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.height, 36, accuracy: 0.5)
            XCTAssertLessThanOrEqual(OverviewLayoutMetrics.totalHeight(aiEnabled: true), 496)
        }
    }

    // P13: F12 x F14
    func testP13_overviewReopenedWithin45sUsesCachedSnapshotWithZeroExtraFetches() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let claude = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.22)))
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(settings: settings, providers: [.claude: claude], sleeper: { try await sleeper.sleep($0) }, now: clock.makeProvider())

        vm.startSampling()
        await sleeper.waitUntilPendingCount(atLeast: 1)
        vm.stopSampling()

        clock.advance(by: 45)
        vm.startSampling()
        await sleeper.waitUntilPendingCount(atLeast: 1)

        let calls = await claude.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(vm.snapshot(for: .claude)?.primaryWindow?.usedRatio ?? -1, 0.22, accuracy: 0.0001)
        vm.stopSampling()
    }

    // P14: F10 x F15
    func testP14_togglingCodexOffUpdatesMenuBarPresenterImmediately() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.menuBarDisplayMode = .focus
        settings.menuBarSlots = [.aiUsage]
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true

        let vm = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.20))),
                .codex: E2ESpyAIUsageProvider(id: .codex, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.80))),
            ],
            now: clock.makeProvider()
        )
        _ = await vm.performManualRefresh()

        var rendered: [MenuBarStatusPresentation] = []
        let coordinator = MonitoringDemandCoordinator()
        let presenter = MenuBarStatusPresenter(
            statusItem: nil,
            settings: settings,
            cpu: CPUViewModel(settings: settings),
            memory: MemoryViewModel(settings: settings),
            disk: DiskViewModel(settings: settings),
            network: NetworkViewModel(settings: settings),
            gpu: GPUViewModel(settings: settings),
            battery: BatteryViewModel(settings: settings),
            thermal: ThermalViewModel(settings: settings),
            accessoryPower: AccessoryPowerViewModel(settings: settings),
            aiUsage: vm,
            demandCoordinator: coordinator,
            locale: Locale(identifier: "en"),
            now: clock.makeProvider(),
            render: { rendered.append($0) }
        )
        defer { presenter.invalidate() }

        presenter.startDemand()
        XCTAssertTrue(rendered.last?.title.contains("AI 20%") == true)

        settings.codexUsageEnabled = false
        let updated = await E2EAsync.waitUntil { rendered.last?.title.contains("AI 80%") == true }
        XCTAssertTrue(updated)
    }

    // P15: F12 x F15
    func testP15_menuBarFreshAt899sAndStaleDashAt901sAfterFetch() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.25)))],
            now: clock.makeProvider()
        )
        _ = await vm.performManualRefresh()
        let snap = try! XCTUnwrap(vm.snapshot(for: .claude))
        let reading = MenuBarMetricReading.aiQuota(
            usedRatio: snap.primaryWindow?.usedRatio,
            observedAt: snap.fetchedAt,
            staleAfter: AIUsageViewModel.menuBarTTL,
            providerID: .claude
        )
        let mbSnap = MenuBarStatusSnapshot(health: .healthy, readings: [.aiUsage: reading])

        clock.advance(by: 899)
        let fresh = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: mbSnap, now: clock.now)
        XCTAssertTrue(fresh.title.contains("AI 75%"))

        clock.advance(by: 2)
        let stale = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: mbSnap, now: clock.now)
        XCTAssertTrue(stale.title.contains("AI —"))
    }

    // P16: F15 x F16
    func testP16_menuBarBilingualEnAndZhHansAccessibilityWithinBudgets() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let entries = [
            MenuBarAIQuotaEntry(providerID: .claude, usedRatio: 0.30, resetsAt: now.addingTimeInterval(5_400), observedAt: now),
            MenuBarAIQuotaEntry(providerID: .codex, usedRatio: 0.50, observedAt: now),
            MenuBarAIQuotaEntry(providerID: .antigravity, usedRatio: 0.10, observedAt: now),
        ]
        let snapshot = MenuBarStatusSnapshot(health: .healthy, readings: [
            .cpu: .numeric(0.45, observedAt: now),
            .disk: .numeric(0.62, observedAt: now),
            .aiUsage: .aiQuotas(entries, displayStyle: .remaining),
        ])

        for localeId in ["en", "zh-Hans"] {
            let focus = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: snapshot, locale: Locale(identifier: localeId), now: now)
            let compact = MenuBarStatusFormatter.format(mode: .compact, slots: [.cpu, .disk, .aiUsage], snapshot: snapshot, locale: Locale(identifier: localeId), now: now)
            XCTAssertLessThanOrEqual(MenuBarStatusRenderer.layout(for: focus).width, 132)
            XCTAssertLessThanOrEqual(MenuBarStatusRenderer.layout(for: compact).width, 300)
            XCTAssertFalse(focus.accessibilityLabel.isEmpty)
            XCTAssertTrue(focus.accessibilityLabel.contains("OpenAI Codex"))
            XCTAssertTrue(focus.accessibilityLabel.contains("Antigravity"))
        }
    }

    // P17: F13 x F16
    func testP17_aiPanelStringsResolveInBothEnAndZhHans() {
        let uiKeys = [
            "AI Quota",
            "AI Subscription Quota",
            "OpenAI Codex",
            "Codex",
            "Antigravity",
            "Claude Code",
            "Codex CLI",
            "Antigravity CLI",
            "Quota display",
            "Quota left",
            "Quota used",
            "Extra usage",
            "Credits",
            "Unlimited",
            "Terminal command",
            "Retry",
            "Update failed: %@ · showing data from %@ ago",
        ]
        for key in uiKeys {
            XCTAssertNotNil(E2ERepoInspector.localizedString(key, localeIdentifier: "en"), "Missing en key: \(key)")
            XCTAssertNotNil(E2ERepoInspector.localizedString(key, localeIdentifier: "zh-Hans"), "Missing zh-Hans key: \(key)")
        }
    }

    // P18: F13 x F17
    func testP18_aiPanelAndOverviewRowCombineThemeFontAndV2ComponentsWithZeroFixedFont() throws {
        let root = E2ERepoInspector.repoRootURL()
        let panel = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Modules/AIUsage/AIUsagePanelView.swift"), encoding: .utf8)
        let row = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Modules/AIUsage/OverviewAIQuotaRow.swift"), encoding: .utf8)

        for src in [panel, row] {
            XCTAssertTrue(src.contains("Theme.Font."))
            XCTAssertTrue(src.contains("V2Card"))
            XCTAssertTrue(src.contains("LynxProgressBar"))
            XCTAssertFalse(src.contains(".system(size:"))
        }
    }

    // P19: F2 x F18
    func testP19_httpClientConfigAnd401SetCookieEchoingTokenIsolatesCookiesAndSecrets() async {
        let canary = "sk-ant-p19-secret-token"
        let client = AIUsageHTTPClient()
        let session = Mirror(reflecting: client).descendant("session") as? URLSession
        XCTAssertNil(session?.configuration.httpCookieStorage)
        XCTAssertEqual(session?.configuration.httpShouldSetCookies, false)

        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((
                Data("{\"error\":\"rejected \(canary)\"}".utf8),
                E2ERecordingHTTPTransport.makeResponse(
                    url: ClaudeUsageProvider.defaultEndpointURL,
                    statusCode: 401,
                    headers: ["Set-Cookie": "sid=\(canary); HttpOnly"]
                )
            ))
        ])
        let creds = ClaudeOAuthCredentials(accessToken: canary, expiresAt: nil, subscriptionType: nil, rateLimitTier: nil)
        let provider = ClaudeUsageProvider(
            credentialReader: E2ESpyClaudeCredentialReader(result: .success(creds)),
            transport: transport
        )
        let result = await provider.fetchQuota(now: Date())
        XCTAssertEqual(result, .failure(.unauthorized))
        XCTAssertFalse(String(describing: creds).contains(canary))
        XCTAssertFalse("\(result)".contains(canary))
    }

    // P20: F1 x F13
    func testP20_providerCLILoginCommandsFlowToRemediationUIKeys() {
        for id in AIUsageProviderID.allCases {
            XCTAssertFalse(id.cliLoginCommand.isEmpty)
            XCTAssertNotNil(E2ERepoInspector.localizedString(id.displayName, localeIdentifier: "en"))
            XCTAssertNotNil(E2ERepoInspector.localizedString(id.displayName, localeIdentifier: "zh-Hans"))
        }
        XCTAssertEqual(AIUsageProviderID.claude.cliLoginCommand, "claude /login")
        XCTAssertEqual(AIUsageProviderID.codex.cliLoginCommand, "codex login")
        XCTAssertEqual(AIUsageProviderID.antigravity.cliLoginCommand, "agy login")
    }

    // P21: F4 x F15
    func testP21_claudePrimary80UsedSecondary20UsedConsistentAcrossPanelOverviewMenuBar() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((E2EFixtureFactory.claudeUsageJSON(fiveHourPercent: 80, sevenDayPercent: 20), E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)))
        ])
        let provider = ClaudeUsageProvider(
            credentialReader: E2ESpyClaudeCredentialReader(result: .success(ClaudeOAuthCredentials(accessToken: "t", expiresAt: nil, subscriptionType: "max", rateLimitTier: nil))),
            transport: transport
        )
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let vm = AIUsageViewModel(settings: settings, providers: [.claude: provider], now: { now })
        _ = await vm.performManualRefresh()

        let snap = try! XCTUnwrap(vm.snapshot(for: .claude))
        let primary = try! XCTUnwrap(snap.primaryWindow)
        XCTAssertEqual(primary.displayedRatio(style: .remaining), 0.20, accuracy: 0.0001)
        XCTAssertEqual(primary.displayedRatio(style: .used), 0.80, accuracy: 0.0001)

        let ovRem = OverviewAIQuotaRow.accessibilityValueSummary(enabledIDs: [.claude], providerStates: vm.providerStates, displayStyle: .remaining)
        let ovUsed = OverviewAIQuotaRow.accessibilityValueSummary(enabledIDs: [.claude], providerStates: vm.providerStates, displayStyle: .used)
        XCTAssertTrue(ovRem.contains("20"))
        XCTAssertTrue(ovUsed.contains("80"))

        let mbSnap = MenuBarStatusSnapshot(health: .healthy, readings: [
            .aiUsage: .aiQuota(usedRatio: primary.usedRatio, observedAt: snap.fetchedAt, providerID: .claude)
        ])
        let mbRem = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: mbSnap, now: now, aiQuotaDisplayStyle: .remaining)
        let mbUsed = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: mbSnap, now: now, aiQuotaDisplayStyle: .used)
        XCTAssertTrue(mbRem.title.contains("AI 20%"))
        XCTAssertTrue(mbUsed.title.contains("AI 80%"))
    }

    // P22: F14 x F19
    func testP22_overviewGeometryAndZeroUncheckedSendableHoldTogether() throws {
        XCTAssertEqual(OverviewLayoutMetrics.aiQuotaRowHeight, 36)
        XCTAssertLessThanOrEqual(OverviewLayoutMetrics.totalHeight(aiEnabled: true), 496)
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Modules/AIUsage")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("@unchecked Sendable"))
        }
    }

    // P23: F11 x F18
    func testP23_disabledProvidersNeverTouchCredentialReadersOrEmitFetches() async {
        let settings = makeIsolatedSettings()
        let claudeReader = E2ESpyClaudeCredentialReader(result: .failure(.unauthorized))
        let codexReader = E2ESpyCodexCredentialReader(result: .failure(.credentialsMissing))
        let antigravityCalls = OSAllocatedUnfairLock(initialState: 0)
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [])

        let vm = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: ClaudeUsageProvider(credentialReader: claudeReader, transport: transport),
                .codex: CodexUsageProvider(credentialReader: codexReader, transport: transport),
                .antigravity: CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
                    antigravityCalls.withLock { $0 += 1 }
                    return ProviderFetchOutcome(result: .failure(AntigravityStatusProbeError.notRunning), attempts: [])
                },
            ]
        )
        vm.startSampling()
        _ = await vm.performManualRefresh()
        await E2EAsync.settle()

        XCTAssertEqual(claudeReader.callCount, 0)
        XCTAssertEqual(codexReader.callCount, 0)
        XCTAssertEqual(antigravityCalls.withLock { $0 }, 0)
        let httpCalls = await transport.callCount
        XCTAssertEqual(httpCalls, 0)
        vm.stopSampling()
    }

    // P24: F19 x F20
    func testP24_codexBarCoreSwift6ConfigWithIntactGlassAndMultiProviderDocs() throws {
        let root = E2ERepoInspector.repoRootURL()
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let theme = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Kit/Theme.swift"), encoding: .utf8)
        let guide = try String(contentsOf: root.appendingPathComponent("docs/guides/user-guide.md"), encoding: .utf8)

        XCTAssertTrue(yml.contains("CodexBarCore"))
        XCTAssertTrue(yml.contains("SWIFT_STRICT_CONCURRENCY: complete"))
        XCTAssertTrue(theme.contains("nsPanelBackdropTint"))
        XCTAssertTrue(guide.contains("Claude"))
        XCTAssertTrue(guide.contains("Codex"))
        XCTAssertTrue(guide.contains("Antigravity"))
    }
}
