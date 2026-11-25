import AppKit
import Foundation
import os
import XCTest
@testable import LynxBar

/// Offline unit tests for `MenuBarStatusSlot.aiUsage`, `MenuBarStatusFormatter`,
/// `MenuBarStatusRenderer`, and `MenuBarStatusPresenter` AI quota integration.
@MainActor
final class MenuBarAIUsageTests: XCTestCase {
    private let baseNow = Date(timeIntervalSince1970: 1_750_000_000)

    /// Verifies `MenuBarStatusSlot.aiUsage` renders `AI —` when unavailable/disabled
    /// and never falls back to `AI 0%`.
    func testUnavailableAIUsageRendersPlaceholderNeverZero() {
        let snapshot = MenuBarStatusSnapshot(health: .healthy, readings: [:])
        let en = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "en_US"),
            now: baseNow
        )
        let zh = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "zh_Hans_CN"),
            now: baseNow
        )

        XCTAssertEqual(en.segments.first?.text, "AI —")
        XCTAssertFalse(en.title.contains("0%"))
        XCTAssertTrue(en.accessibilityLabel.contains("AI quota unavailable"))
        XCTAssertEqual(zh.segments.first?.text, "AI —")
        XCTAssertTrue(zh.accessibilityLabel.contains("AI 额度 不可用"))
    }

    /// Verifies `.remaining` (`AI 78%`) vs `.used` (`AI 22%`) formatting and 15-minute (900s) TTL expiry.
    func testRemainingVsUsedFormattingAnd15MinuteTTLBoundary() {
        let resetsAt = baseNow.addingTimeInterval(2 * 3_600 + 14 * 60)
        let reading = MenuBarMetricReading.aiQuota(
            usedRatio: 0.22,
            resetsAt: resetsAt,
            displayStyle: .remaining,
            observedAt: baseNow
        )
        let snapshot = MenuBarStatusSnapshot(health: .healthy, readings: [.aiUsage: reading])

        let remainingPresentation = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "en_US"),
            now: baseNow,
            aiQuotaDisplayStyle: .remaining
        )
        XCTAssertEqual(remainingPresentation.segments.first?.text, "AI 78%")

        let usedPresentation = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "en_US"),
            now: baseNow,
            aiQuotaDisplayStyle: .used
        )
        XCTAssertEqual(usedPresentation.segments.first?.text, "AI 22%")

        // Exactly at 900s (15 min) TTL boundary: still available.
        let atBoundary = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "en_US"),
            now: baseNow.addingTimeInterval(900)
        )
        XCTAssertEqual(atBoundary.segments.first?.text, "AI 78%")

        // Past 900s (901s): enters stale and renders "AI —".
        let staleEN = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "en_US"),
            now: baseNow.addingTimeInterval(901)
        )
        let staleZH = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "zh_Hans_CN"),
            now: baseNow.addingTimeInterval(901)
        )
        XCTAssertEqual(staleEN.segments.first?.text, "AI —")
        XCTAssertTrue(staleEN.accessibilityLabel.contains("stale"))
        XCTAssertEqual(staleZH.segments.first?.text, "AI —")
        XCTAssertTrue(staleZH.accessibilityLabel.contains("数据已陈旧"))
    }

    /// Verifies bilingual (`en` and `zh-Hans`) VoiceOver / tooltip labels include reset countdowns.
    func testBilingualVoiceOverLabelsIncludeResetCountdowns() {
        let resetsAt = baseNow.addingTimeInterval(2 * 3_600 + 14 * 60)
        let reading = MenuBarMetricReading.aiQuota(
            usedRatio: 0.22,
            resetsAt: resetsAt,
            displayStyle: .remaining,
            observedAt: baseNow
        )
        let snapshot = MenuBarStatusSnapshot(health: .healthy, readings: [.aiUsage: reading])

        let enRemaining = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "en_US"),
            now: baseNow,
            aiQuotaDisplayStyle: .remaining
        )
        XCTAssertTrue(enRemaining.accessibilityLabel.contains("Claude quota 78% remaining"))
        XCTAssertTrue(enRemaining.accessibilityLabel.contains("resets in 2h 14m"))

        let enUsed = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "en_US"),
            now: baseNow,
            aiQuotaDisplayStyle: .used
        )
        XCTAssertTrue(enUsed.accessibilityLabel.contains("Claude quota 22% used"))
        XCTAssertTrue(enUsed.accessibilityLabel.contains("resets in 2h 14m"))

        let zhRemaining = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "zh_Hans_CN"),
            now: baseNow,
            aiQuotaDisplayStyle: .remaining
        )
        XCTAssertTrue(zhRemaining.accessibilityLabel.contains("Claude 额度剩余 78%"))
        XCTAssertTrue(zhRemaining.accessibilityLabel.contains("2 小时 14 分后重置"))

        let zhUsed = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.aiUsage],
            snapshot: snapshot,
            locale: Locale(identifier: "zh_Hans_CN"),
            now: baseNow,
            aiQuotaDisplayStyle: .used
        )
        XCTAssertTrue(zhUsed.accessibilityLabel.contains("Claude 额度已用 22%"))
        XCTAssertTrue(zhUsed.accessibilityLabel.contains("2 小时 14 分后重置"))
    }

    /// Verifies `MenuBarStatusSlot.validated`, `.focus` / `.compact` width budgets,
    /// and `MenuBarStatusPresenter` demand acquisition & live updates for `.aiUsage`.
    func testSlotValidationWidthBudgetsAndPresenterDemandUpdates() async {
        XCTAssertEqual(
            MenuBarStatusSlot.validated(["aiUsage", "cpu", "aiUsage", "disk", "network"]),
            [.aiUsage, .cpu, .disk]
        )

        let settings = makeSettings()
        settings.menuBarDisplayMode = .focus
        settings.menuBarSlots = [.aiUsage]
        XCTAssertFalse(settings.aiUsageEnabled)

        let clock = MenuBarTestClock(baseNow)
        let fetchedSnapshot = AIProviderQuotaSnapshot(
            providerID: .claude,
            primaryWindow: AIQuotaWindow(
                id: "five_hour",
                kind: .session5h,
                title: "5-hour session",
                usedRatio: 0.22,
                resetsAt: baseNow.addingTimeInterval(3_600)
            ),
            secondaryWindow: nil,
            additionalWindows: [],
            extraUsage: nil,
            planLabel: "Pro",
            fetchedAt: baseNow
        )
        let provider = StubAIUsageProvider(snapshot: fetchedSnapshot)
        let aiUsage = AIUsageViewModel(
            settings: settings,
            provider: provider,
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
        XCTAssertEqual(coordinator.demandCount(for: .aiUsage), 1)
        XCTAssertEqual(presentations.last?.segments.first?.text, "AI —")
        let initialCalls = await provider.callCount
        XCTAssertEqual(initialCalls, 0)

        // Opt in live -> fetches immediately and renders "AI 78%" within focus width budget.
        settings.aiUsageEnabled = true
        await waitUntil { presentations.last?.segments.first?.text == "AI 78%" }
        let focusLayout = MenuBarStatusRenderer.layout(for: presentations.last!)
        XCTAssertLessThanOrEqual(focusLayout.width, CGFloat(MenuBarDisplayMode.focus.widthBudget))

        // Switch display style to .used -> updates immediately to "AI 22%".
        settings.aiQuotaDisplayStyle = .used
        await waitUntil { presentations.last?.segments.first?.text == "AI 22%" }

        // Compact mode with 3 slots including .aiUsage fits within compact width budget.
        settings.menuBarDisplayMode = .compact
        settings.menuBarSlots = [.cpu, .disk, .aiUsage]
        await waitUntil { presentations.last?.mode == .compact }
        let compactPresentation = presentations.last!
        XCTAssertEqual(compactPresentation.segments.map(\.slot), [.cpu, .disk, .aiUsage])
        let compactLayout = MenuBarStatusRenderer.layout(for: compactPresentation)
        XCTAssertLessThanOrEqual(compactLayout.width, CGFloat(MenuBarDisplayMode.compact.widthBudget))

        // Advance past 15-minute TTL -> shows "AI —" stale.
        clock.set(baseNow.addingTimeInterval(901))
        presenter.refreshPresentation()
        XCTAssertEqual(presentations.last?.segments.last?.text, "AI —")
        XCTAssertTrue(presentations.last?.accessibilityLabel.contains("stale") == true)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition not met within deadline")
    }

    private func makeSettings() -> Settings {
        let suiteName = "com.swnb.LynxBarTests.menuBarAI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return Settings(defaults: defaults)
    }
}

private final class MenuBarTestClock: Sendable {
    private let storage: OSAllocatedUnfairLock<Date>

    init(_ initial: Date) {
        self.storage = OSAllocatedUnfairLock(initialState: initial)
    }

    func now() -> Date { storage.withLock { $0 } }
    func set(_ date: Date) { storage.withLock { $0 = date } }
}

private actor StubAIUsageProvider: AIUsageProvider {
    nonisolated let id: AIUsageProviderID = .claude
    let snapshot: AIProviderQuotaSnapshot
    private(set) var callCount: Int = 0

    init(snapshot: AIProviderQuotaSnapshot) {
        self.snapshot = snapshot
    }

    func fetchQuota(now: Date) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        callCount += 1
        return .success(snapshot)
    }
}
