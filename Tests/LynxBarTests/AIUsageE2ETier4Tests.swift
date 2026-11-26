import AppKit
import CodexBarCore
import Foundation
import os
import SwiftUI
import XCTest
@testable import LynxBar

/// Tier 4 Opaque-Box E2E Tests: 10 Real-World End-to-End Application Scenarios.
@MainActor
final class AIUsageE2ETier4Tests: XCTestCase {
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

    // S1: Clean First-Launch Privacy Baseline
    func testS01_cleanFirstLaunchPrivacyBaseline() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.menuBarDisplayMode = .focus
        settings.menuBarSlots = [.aiUsage]

        let claudeReader = E2ESpyClaudeCredentialReader(result: .failure(.credentialsMissing))
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
            ],
            now: clock.makeProvider()
        )

        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { module, active in
            if module == .aiUsage {
                if active { vm.startSampling() } else { vm.stopSampling() }
            }
        }

        var rendered: [MenuBarStatusPresentation] = []
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
        let owner = E2ETestDemandOwner()
        let overviewToken = coordinator.acquire(module: .aiUsage, reason: .panel(.overview), owner: owner)
        let panelToken = coordinator.acquire(module: .aiUsage, reason: .panel(.aiUsage), owner: owner)
        await E2EAsync.settle()

        XCTAssertTrue(vm.enabledProviderIDs.isEmpty)
        XCTAssertEqual(claudeReader.callCount, 0)
        XCTAssertEqual(codexReader.callCount, 0)
        XCTAssertEqual(antigravityCalls.withLock { $0 }, 0)
        let httpCount = await transport.callCount
        XCTAssertEqual(httpCount, 0)
        XCTAssertTrue(rendered.last?.title.contains("AI —") == true)
        XCTAssertEqual(OverviewLayoutMetrics.totalHeight(aiEnabled: settings.aiUsageEnabled), 494)

        var sel: DashboardSection = .aiUsage
        let host = NSHostingView(rootView: AIUsagePanelView(viewModel: vm, selection: Binding(get: { sel }, set: { sel = $0 })))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 100)

        overviewToken.cancel()
        panelToken.cancel()
    }

    // S2: Single-Provider Claude Max Power User
    func testS02_singleProviderClaudeMaxPowerUser() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true

        let mcpOnly = Data(#"{"mcpOAuth":{"accessToken":"mcp-only"}}"#.utf8)
        let fileCreds = E2EFixtureFactory.claudeCredentialsData(
            accessToken: "sk-ant-max-user",
            expiresAtValue: (clock.now.timeIntervalSince1970 + 3_600) * 1000,
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x"
        )
        let claudeReader = ClaudeCredentialReader(
            keychainReader: { .data(mcpOnly) },
            fileReader: { fileCreds }
        )
        let claudeTransport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((
                E2EFixtureFactory.claudeUsageJSON(
                    fiveHourPercent: 28,
                    sevenDayPercent: 45,
                    sonnetPercent: 12,
                    opusPercent: 60,
                    extraEnabled: true,
                    extraUsed: 8.5,
                    extraLimit: 100.0,
                    extraCurrency: "USD"
                ),
                E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)
            ))
        ])

        let codexSpy = E2ESpyAIUsageProvider(id: .codex)
        let antigravitySpy = E2ESpyAIUsageProvider(id: .antigravity)

        let vm = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: ClaudeUsageProvider(credentialReader: claudeReader, transport: claudeTransport),
                .codex: codexSpy,
                .antigravity: antigravitySpy,
            ],
            now: clock.makeProvider()
        )
        _ = await vm.performManualRefresh()

        let snap = try! XCTUnwrap(vm.snapshot(for: .claude))
        XCTAssertEqual(snap.planLabel, "Max")
        XCTAssertEqual(snap.primaryWindow?.usedRatio ?? -1, 0.28, accuracy: 0.0001)
        XCTAssertEqual(snap.secondaryWindow?.usedRatio ?? -1, 0.45, accuracy: 0.0001)
        XCTAssertEqual(snap.additionalWindows.map(\.id), ["seven_day_sonnet", "seven_day_opus"])
        XCTAssertEqual(snap.extraUsage?.usedAmount, 8.5)

        let c2 = await codexSpy.callCount
        let c3 = await antigravitySpy.callCount
        XCTAssertEqual(c2 + c3, 0)

        var sel: DashboardSection = .overview
        let rowHost = NSHostingView(rootView: OverviewAIQuotaRow(aiUsage: vm, selection: Binding(get: { sel }, set: { sel = $0 })))
        rowHost.frame = NSRect(x: 0, y: 0, width: 400, height: 36)
        rowHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(rowHost.fittingSize.height, 36, accuracy: 0.5)

        let mbSnap = MenuBarStatusSnapshot(health: .healthy, readings: [
            .aiUsage: .aiQuota(usedRatio: snap.primaryWindow?.usedRatio, observedAt: snap.fetchedAt, providerID: .claude)
        ])
        let focus = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: mbSnap, now: clock.now)
        XCTAssertTrue(focus.title.contains("AI 72%"))
        XCTAssertLessThanOrEqual(MenuBarStatusRenderer.layout(for: focus).width, 132)
    }

    // S3: Multi-Provider Power User (All 3 Enabled Simultaneously)
    func testS03_multiProviderPowerUserAllThreeEnabledSimultaneously() async throws {
        let clock = E2ETestClock()
        let home = try makeTempHome()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        settings.antigravityUsageEnabled = true

        // Claude (75% used -> 25% left)
        let claudeReader = E2ESpyClaudeCredentialReader(result: .success(
            ClaudeOAuthCredentials(accessToken: "sk-ant-s3", expiresAt: clock.now.addingTimeInterval(3_600), subscriptionType: "max", rateLimitTier: nil)
        ))
        let claudeTransport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((E2EFixtureFactory.claudeUsageJSON(fiveHourPercent: 75, sevenDayPercent: 50), E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)))
        ])

        // Codex via custom $CODEX_HOME + ChatGPT-Account-Id (40% used -> 60% left)
        let codexHome = home.rootURL.appendingPathComponent("codex-s3", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let jwt = E2EFixtureFactory.makeJWT(claims: ["exp": clock.now.timeIntervalSince1970 + 3_600])
        try E2EFixtureFactory.codexAuthJSON(accessToken: jwt, accountId: "acct_s3").write(to: codexHome.appendingPathComponent("auth.json"))
        let codexReader = CodexCredentialReader(environment: ["CODEX_HOME": codexHome.path], homeDirectory: home.rootURL)
        let codexTransport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((E2EFixtureFactory.codexUsageJSON(planType: "pro", primaryUsedPercent: 40), E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)))
        ])

        // Antigravity via CodexBarCore extraRateWindows promotion (85% used -> 15% left)
        let antigravityUsage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Models",
                    window: RateWindow(usedPercent: 85, windowMinutes: 300, resetsAt: clock.now.addingTimeInterval(3_600), resetDescription: nil),
                    usageKnown: true
                ),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude and GPT",
                    window: RateWindow(usedPercent: 25, windowMinutes: 10_080, resetsAt: clock.now.addingTimeInterval(86_400), resetDescription: nil),
                    usageKnown: true
                ),
            ],
            updatedAt: clock.now
        )
        let antigravityFetchResult = ProviderFetchResult(
            usage: antigravityUsage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "antigravity.app-local",
            strategyID: "antigravity.app-local",
            strategyKind: .localProbe
        )
        let antigravityProvider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
            ProviderFetchOutcome(result: .success(antigravityFetchResult), attempts: [])
        }

        let vm = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: ClaudeUsageProvider(credentialReader: claudeReader, transport: claudeTransport),
                .codex: CodexUsageProvider(credentialReader: codexReader, transport: codexTransport),
                .antigravity: antigravityProvider,
            ],
            now: clock.makeProvider()
        )
        _ = await vm.performManualRefresh()

        XCTAssertEqual(vm.activeSnapshots.map(\.providerID), [.claude, .codex, .antigravity])
        let codexReqs = await codexTransport.requests
        XCTAssertEqual(codexReqs.first?.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct_s3")
        XCTAssertEqual(vm.snapshot(for: .antigravity)?.primaryWindow?.usedRatio ?? -1, 0.85, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(OverviewLayoutMetrics.totalHeight(aiEnabled: true), 496)

        let entries = vm.activeSnapshots.compactMap { snap -> MenuBarAIQuotaEntry? in
            guard let win = snap.primaryWindow else { return nil }
            return MenuBarAIQuotaEntry(providerID: snap.providerID, usedRatio: win.usedRatio, resetsAt: win.resetsAt, observedAt: snap.fetchedAt)
        }
        let mbSnap = MenuBarStatusSnapshot(health: .healthy, readings: [
            .cpu: .numeric(0.45, observedAt: clock.now),
            .memory: .numeric(0.60, observedAt: clock.now),
            .aiUsage: .aiQuotas(entries, displayStyle: .remaining),
        ])
        let focus = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: mbSnap, now: clock.now)
        let compact = MenuBarStatusFormatter.format(mode: .compact, slots: [.cpu, .memory, .aiUsage], snapshot: mbSnap, now: clock.now)
        XCTAssertTrue(focus.title.contains("AI 15%"))
        XCTAssertLessThanOrEqual(MenuBarStatusRenderer.layout(for: focus).width, 132)
        XCTAssertLessThanOrEqual(MenuBarStatusRenderer.layout(for: compact).width, 300)
    }

    // S4: Mixed Auth & Expiration Recovery Workflow
    func testS04_mixedAuthAndExpirationRecoveryWorkflow() async throws {
        let clock = E2ETestClock()
        let home = try makeTempHome()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        settings.antigravityUsageEnabled = true

        // Claude healthy
        let claudeTransport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((E2EFixtureFactory.claudeUsageJSON(fiveHourPercent: 20), E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)))
        ])
        let claude = ClaudeUsageProvider(
            credentialReader: E2ESpyClaudeCredentialReader(result: .success(ClaudeOAuthCredentials(accessToken: "sk-c", expiresAt: nil, subscriptionType: "pro", rateLimitTier: nil))),
            transport: claudeTransport
        )

        // Codex expired initially, later fixed
        let expiredJWT = E2EFixtureFactory.makeJWT(claims: ["exp": clock.now.timeIntervalSince1970 - 60])
        _ = try home.writeFile(relativePath: ".codex/auth.json", data: E2EFixtureFactory.codexAuthJSON(accessToken: expiredJWT))
        let codexTransport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((E2EFixtureFactory.codexUsageJSON(primaryUsedPercent: 30), E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)))
        ])
        let codex = CodexUsageProvider(
            credentialReader: CodexCredentialReader(environment: [:], homeDirectory: home.rootURL),
            transport: codexTransport
        )

        // Antigravity not running / not signed in
        let antigravity = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
            ProviderFetchOutcome(result: .failure(AntigravityStatusProbeError.notRunning), attempts: [])
        }

        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claude, .codex: codex, .antigravity: antigravity],
            now: clock.makeProvider()
        )
        _ = await vm.performManualRefresh()

        if case .loaded = vm.state(for: .claude) {} else { XCTFail("Expected Claude loaded") }
        XCTAssertEqual(vm.state(for: .codex), .error(.tokenExpired))
        XCTAssertEqual(vm.state(for: .antigravity), .error(.credentialsMissing))
        let codexCallsBefore = await codexTransport.callCount
        XCTAssertEqual(codexCallsBefore, 0)

        // User runs `codex login` -> valid auth.json written -> manual retry for Codex only
        let validJWT = E2EFixtureFactory.makeJWT(claims: ["exp": clock.now.timeIntervalSince1970 + 3_600])
        _ = try home.writeFile(relativePath: ".codex/auth.json", data: E2EFixtureFactory.codexAuthJSON(accessToken: validJWT))
        clock.advance(by: 10)
        _ = await vm.performManualRefresh(for: .codex)

        if case .loaded(let codexSnap) = vm.state(for: .codex) {
            XCTAssertEqual(codexSnap.primaryWindow?.usedRatio ?? -1, 0.30, accuracy: 0.0001)
        } else {
            XCTFail("Expected Codex to recover on manual retry")
        }
        let claudeCallsTotal = await claudeTransport.callCount
        XCTAssertEqual(claudeCallsTotal, 1) // Claude untouched
    }

    // S5: Transient Rate Limit (429) & Network Outage Resilience
    func testS05_transientRateLimitAndNetworkOutageResilienceWithMenuBarTTL() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        settings.antigravityUsageEnabled = true

        let claude = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.25)))
        let codex = E2ESpyAIUsageProvider(
            id: .codex,
            results: [
                .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.40)),
                .failure(.rateLimited(retryAfter: 120)),
            ]
        )
        let antigravity = E2ESpyAIUsageProvider(
            id: .antigravity,
            results: [
                .success(E2EFixtureFactory.makeSnapshot(providerID: .antigravity, usedRatio: 0.60)),
                .failure(.networkFailure("The Internet connection appears to be offline.")),
            ]
        )

        let vm = AIUsageViewModel(settings: settings, providers: [.claude: claude, .codex: codex, .antigravity: antigravity], now: clock.makeProvider())
        _ = await vm.performManualRefresh()

        clock.advance(by: 10)
        _ = await vm.performManualRefresh(for: .codex)
        _ = await vm.performManualRefresh(for: .antigravity)

        if case .stale(let codexSnap, .rateLimited(retryAfter: 120)) = vm.state(for: .codex),
           case .stale(let agySnap, .networkFailure) = vm.state(for: .antigravity) {
            XCTAssertEqual(codexSnap.primaryWindow?.usedRatio, 0.40)
            XCTAssertEqual(agySnap.primaryWindow?.usedRatio, 0.60)
        } else {
            return XCTFail("Expected stale-while-error retention on Codex and Antigravity")
        }

        // MenuBar keeps serving stale-retained snapshots up to 900s from fetchedAt, then degrades to AI —
        let entries = vm.activeSnapshots.compactMap { snap -> MenuBarAIQuotaEntry? in
            guard let win = snap.primaryWindow else { return nil }
            return MenuBarAIQuotaEntry(providerID: snap.providerID, usedRatio: win.usedRatio, observedAt: snap.fetchedAt)
        }
        let mbSnap = MenuBarStatusSnapshot(health: .healthy, readings: [
            .aiUsage: .aiQuotas(entries, staleAfter: AIUsageViewModel.menuBarTTL)
        ])
        let at899 = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: mbSnap, now: clock.now.addingTimeInterval(889))
        let at901 = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: mbSnap, now: clock.now.addingTimeInterval(891))
        XCTAssertTrue(at899.title.contains("AI 40%"))
        XCTAssertTrue(at901.title.contains("AI —"))
    }

    // S6: Display Mode & Bilingual Locale Switching
    func testS06_displayModeAndBilingualLocaleSwitching() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.28)))],
            now: clock.makeProvider()
        )
        _ = await vm.performManualRefresh()
        let snap = try! XCTUnwrap(vm.snapshot(for: .claude))
        let mbSnap = MenuBarStatusSnapshot(health: .healthy, readings: [
            .aiUsage: .aiQuota(usedRatio: 0.28, observedAt: snap.fetchedAt, providerID: .claude)
        ])

        for style in [AIQuotaDisplayStyle.remaining, .used] {
            settings.aiQuotaDisplayStyle = style
            _ = await E2EAsync.waitUntil { vm.displayStyle == style }

            let expectedNum = style == .remaining ? "72" : "28"
            for localeId in ["en", "zh-Hans"] {
                let focus = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: mbSnap, locale: Locale(identifier: localeId), now: clock.now, aiQuotaDisplayStyle: style)
                XCTAssertTrue(focus.title.contains("AI \(expectedNum)%"))
                XCTAssertTrue(focus.accessibilityLabel.contains("\(expectedNum)%"))
                XCTAssertLessThanOrEqual(MenuBarStatusRenderer.layout(for: focus).width, 132)
            }
            let ovSummary = OverviewAIQuotaRow.accessibilityValueSummary(enabledIDs: [.claude], providerStates: vm.providerStates, displayStyle: style)
            XCTAssertTrue(ovSummary.contains(expectedNum))
        }
    }

    // S7: Demand-Driven Lifecycle Across Navigation & Sleep/Wake
    func testS07_demandDrivenLifecycleAcrossNavigationAndCooldownThrottle() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let claude = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.3)))
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claude],
            sleeper: { try await sleeper.sleep($0) },
            now: clock.makeProvider()
        )

        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { module, active in
            if module == .aiUsage {
                if active { vm.startSampling() } else { vm.stopSampling() }
            }
        }
        let owner = E2ETestDemandOwner()

        // Open Overview -> starts polling
        var navToken: DemandToken? = coordinator.acquire(module: .aiUsage, reason: .panel(.overview), owner: owner)
        await claude.waitForFetchStart(atLeast: 1)
        await sleeper.waitUntilPendingCount(atLeast: 1)

        // Navigate CPU (no aiUsage) -> Memory (no aiUsage) -> AI Panel (re-acquires aiUsage) -> Close
        navToken?.cancel()
        navToken = nil
        XCTAssertEqual(coordinator.demandCount(for: .aiUsage), 0)

        clock.advance(by: 40) // Reopen within 40s (< 60s cooldown)
        navToken = coordinator.acquire(module: .aiUsage, reason: .panel(.aiUsage), owner: owner)
        await sleeper.waitUntilPendingCount(atLeast: 1)
        let callsAt40s = await claude.callCount
        XCTAssertEqual(callsAt40s, 1) // Cooldown prevented refetch

        clock.advance(by: 6)
        let manualOK = await vm.performManualRefresh(for: .claude)
        XCTAssertNotNil(manualOK)
        let callsAfterManual = await claude.callCount
        XCTAssertEqual(callsAfterManual, 2)

        clock.advance(by: 2)
        let throttled = await vm.performManualRefresh(for: .claude)
        XCTAssertNil(throttled)
        let callsAfterRapidClick = await claude.callCount
        XCTAssertEqual(callsAfterRapidClick, 2)

        navToken?.cancel()
    }

    // S8: Dynamic Sub-Selection & Mid-Session Opt-Out
    func testS08_dynamicSubSelectionAndMidSessionOptOut() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        settings.antigravityUsageEnabled = true

        let claude = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.1)))
        let codex = E2ESpyAIUsageProvider(id: .codex, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.2)))
        let antigravity = E2ESpyAIUsageProvider(id: .antigravity, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .antigravity, usedRatio: 0.3)))
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claude, .codex: codex, .antigravity: antigravity],
            sleeper: { try await sleeper.sleep($0) }
        )

        vm.startSampling()
        await claude.waitForFetchStart(atLeast: 1)
        await codex.waitForFetchStart(atLeast: 1)
        await antigravity.waitForFetchStart(atLeast: 1)
        await sleeper.waitUntilPendingCount(atLeast: 3)

        // Opt out of Antigravity mid-session
        settings.antigravityUsageEnabled = false
        let agyDisabled = await E2EAsync.waitUntil { vm.state(for: .antigravity) == .disabled }
        XCTAssertTrue(agyDisabled)
        XCTAssertEqual(vm.enabledProviderIDs, [.claude, .codex])
        XCTAssertEqual(vm.activeSnapshots.map(\.providerID), [.claude, .codex])

        // Swap to Codex + Antigravity
        settings.claudeUsageEnabled = false
        settings.antigravityUsageEnabled = true
        let swapped = await E2EAsync.waitUntil {
            vm.state(for: .claude) == .disabled && vm.enabledProviderIDs == [.codex, .antigravity]
        }
        XCTAssertTrue(swapped)
        await antigravity.waitForFetchStart(atLeast: 2)
        vm.stopSampling()
    }

    // S9: Adversarial Privacy & Secret-Leak Audit
    func testS09_adversarialPrivacyAndSecretLeakAudit() async throws {
        let cToken = "sk-ant-CANARY-CLAUDE-999"
        let xToken = "codex-jwt-CANARY-CODEX-999"

        let cCreds = ClaudeOAuthCredentials(accessToken: cToken, expiresAt: nil, subscriptionType: "max", rateLimitTier: nil)
        let xCreds = CodexOAuthCredentials(accessToken: xToken, refreshToken: xToken, idToken: xToken, accountId: "acct", accountEmail: "u@e.com", expiresAt: nil, lastRefresh: nil, planType: "pro")

        for (canary, creds) in [(cToken, "\(cCreds) \(String(reflecting: cCreds))"), (xToken, "\(xCreds) \(String(reflecting: xCreds))")] {
            XCTAssertFalse(creds.contains(canary))
            XCTAssertTrue(creds.contains("[REDACTED]"))
        }

        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true

        let leakedBody = Data("{\"error\":\"leaked \(cToken)\"}".utf8)
        let response1 = E2ELoopbackHTTPServer.httpResponse(
            headers: [
                ("Set-Cookie", "lynx_canary=secret_cookie; Path=/; HttpOnly"),
                ("Content-Type", "application/json"),
            ],
            body: leakedBody
        )
        let response2 = E2ELoopbackHTTPServer.httpResponse(
            headers: [("Content-Type", "application/json")],
            body: E2EFixtureFactory.claudeUsageJSON()
        )
        let server = try E2ELoopbackHTTPServer(responses: [response1, response2])
        cleanup.registerLoopbackServer(server)
        defer { server.stop() }

        let beforeCookies = HTTPCookieStorage.shared.cookies ?? []
        let client = AIUsageHTTPClient(timeout: 5)
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: ClaudeUsageProvider(
                    credentialReader: E2ESpyClaudeCredentialReader(result: .success(cCreds)),
                    transport: client,
                    endpointURL: server.url(path: "/api/oauth/usage")
                )
            ],
            now: clock.makeProvider()
        )

        // Request 1: returns Set-Cookie + malformed body echoing canary token
        _ = await vm.performManualRefresh()
        let errText = "\(String(describing: vm.lastError(for: .claude)))"
        guard case .decodingFailure = vm.lastError(for: .claude) else {
            return XCTFail("Expected .decodingFailure, got \(errText)")
        }
        XCTAssertFalse(errText.contains(cToken))

        // Request 2: advance past 5s manual throttle and re-query through the same AIUsageHTTPClient
        clock.advance(by: 6)
        _ = await vm.performManualRefresh()
        XCTAssertNotNil(vm.snapshot(for: .claude))

        let captured = server.capturedRequests
        XCTAssertEqual(captured.count, 2)
        let req2HeaderLines = E2ELoopbackHTTPServer.headerLines(from: captured[1])
        XCTAssertFalse(
            req2HeaderLines.contains { $0.lowercased().hasPrefix("cookie:") },
            "Unexpected Cookie header sent by AIUsageHTTPClient: \(req2HeaderLines)"
        )
        XCTAssertFalse(captured[1].contains("lynx_canary"))
        XCTAssertFalse(captured[1].contains("secret_cookie"))

        let afterCookies = HTTPCookieStorage.shared.cookies ?? []
        XCTAssertFalse(afterCookies.contains { $0.name == "lynx_canary" || $0.value.contains("secret_cookie") })
        XCTAssertEqual(afterCookies.count, beforeCookies.count)
    }

    // S10: Full Release Acceptance Pipeline Check
    func testS10_fullReleaseAcceptanceComplianceGate() throws {
        let root = E2ERepoInspector.repoRootURL()

        // 1. Localization parity
        let en = try E2ERepoInspector.parseLocalizableStrings(at: root.appendingPathComponent("Sources/LynxBar/Resources/en.lproj/Localizable.strings"))
        let zh = try E2ERepoInspector.parseLocalizableStrings(at: root.appendingPathComponent("Sources/LynxBar/Resources/zh-Hans.lproj/Localizable.strings"))
        XCTAssertTrue(en.duplicates.isEmpty)
        XCTAssertTrue(zh.duplicates.isEmpty)
        XCTAssertEqual(Set(en.entries.keys), Set(zh.entries.keys))

        // 2. Zero fixed .system(size:) in Sources
        let systemSizeRegex = try NSRegularExpression(pattern: #"\.system\s*\(\s*size\s*:"#)
        for file in try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar") {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(systemSizeRegex.numberOfMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)), 0)
        }

        // 3. CodexBarCore SPM pin & Swift 6 strict concurrency in project.yml
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("CodexBarCore"))
        XCTAssertTrue(yml.contains("SWIFT_STRICT_CONCURRENCY: complete"))

        // 4. Overview 420x600 budget & zero @unchecked Sendable in AI files
        XCTAssertLessThanOrEqual(OverviewLayoutMetrics.totalHeight(aiEnabled: true), 496)
        for file in try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Providers/AIUsage") + E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Modules/AIUsage") {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("@unchecked Sendable"))
            XCTAssertFalse(text.contains("HTTPCookie"))
            XCTAssertFalse(text.contains("SecItemAdd"))
        }

        // 5. Phase 1+2 preservation & multi-provider docs
        let mem = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Modules/Memory/MemoryPanelView.swift"), encoding: .utf8)
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(mem.contains("High swap"))
        XCTAssertTrue(readme.contains("OpenAI Codex"))
        XCTAssertTrue(readme.contains("Antigravity"))
    }
}
