import AppKit
import SwiftUI
import XCTest
@testable import LynxBar

/// Geometry and layout-budget tests verifying `OverviewLayoutMetrics` and actual SwiftUI
/// `NSHostingView` sizing inside the `420×600` dashboard panel for both `aiUsageEnabled == false`
/// and `aiUsageEnabled == true`.
@MainActor
final class OverviewLayoutGeometryTests: XCTestCase {
    /// Verifies exact `OverviewLayoutMetrics` budget math for both disabled and enabled AI quota states.
    func testOverviewLayoutMetricsStayWithin496PointBudgetAndPreventProcessClipping() {
        XCTAssertEqual(OverviewLayoutMetrics.availableOverviewHeight, 496)
        XCTAssertEqual(OverviewLayoutMetrics.aiQuotaRowHeight, 36)
        XCTAssertEqual(OverviewLayoutMetrics.visibleProcessRowCount, 3)

        XCTAssertEqual(OverviewLayoutMetrics.totalHeight(aiEnabled: false), 494)
        XCTAssertLessThanOrEqual(
            OverviewLayoutMetrics.totalHeight(aiEnabled: false),
            OverviewLayoutMetrics.availableOverviewHeight
        )
        XCTAssertEqual(OverviewLayoutMetrics.totalHeight(aiEnabled: true), 494)
        XCTAssertLessThanOrEqual(
            OverviewLayoutMetrics.totalHeight(aiEnabled: true),
            OverviewLayoutMetrics.availableOverviewHeight
        )

        XCTAssertLessThanOrEqual(
            OverviewLayoutMetrics.processCardContentHeight(aiEnabled: false),
            OverviewLayoutMetrics.processCardHeight(aiEnabled: false)
        )
        XCTAssertLessThanOrEqual(
            OverviewLayoutMetrics.processCardContentHeight(aiEnabled: true),
            OverviewLayoutMetrics.processCardHeight(aiEnabled: true)
        )
    }

    /// Verifies actual SwiftUI `NSHostingView` layout geometry inside `420×600` (`DashboardView`)
    /// and `420×496` (`OverviewView`) with zero overflow when `aiUsageEnabled` is `false` or `true`.
    func testDashboardAndOverviewHostingGeometryFit420x600WithoutOverflow() async throws {
        let originalEnabled = Settings.shared.aiUsageEnabled
        let originalStyle = Settings.shared.aiQuotaDisplayStyle
        let originalVisible = Settings.shared.aiUsageSectionVisible
        defer {
            Settings.shared.aiUsageEnabled = originalEnabled
            Settings.shared.aiQuotaDisplayStyle = originalStyle
            Settings.shared.aiUsageSectionVisible = originalVisible
        }

        let store = MetricHistoryStore(fileURL: nil)
        let isolatedDefaults = makeIsolatedDefaults()
        let processSettings = Settings(defaults: isolatedDefaults)
        processSettings.processTopN = 5

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let snapshot = AIProviderQuotaSnapshot(
            providerID: .claude,
            primaryWindow: AIQuotaWindow(
                id: "five_hour",
                kind: .session5h,
                title: "5-hour session",
                usedRatio: 0.22,
                resetsAt: now.addingTimeInterval(2 * 3_600)
            ),
            secondaryWindow: AIQuotaWindow(
                id: "seven_day",
                kind: .weekly7d,
                title: "7-day weekly",
                usedRatio: 0.40,
                resetsAt: now.addingTimeInterval(86_400)
            ),
            additionalWindows: [],
            extraUsage: nil,
            planLabel: "Pro",
            fetchedAt: now
        )
        let aiUsage = AIUsageViewModel(
            settings: Settings.shared,
            provider: OfflineLayoutAIUsageProvider(snapshot: snapshot),
            sleeper: { _ in try await Task.sleep(for: .seconds(600)) },
            now: { now }
        )
        defer { aiUsage.stopSampling() }

        let process = ProcessViewModel(
            settings: processSettings,
            sampler: { _ in
                let raw = (1...5).map { idx in
                    ProcessProvider.RawProcess(
                        identity: ProcessProvider.ProcessIdentity(pid: Int32(1000 + idx), startTime: 100),
                        name: "Worker-\(idx)",
                        cpuTimeNs: UInt64(idx) * 1_000_000,
                        prevCpuTimeNs: nil,
                        memoryBytes: UInt64(idx) * 64 * 1_048_576,
                        actionIdentity: nil
                    )
                }
                return (raw: raw, cpuTimes: [:])
            },
            sleeper: { _ in throw CancellationError() },
            now: { now },
            applicationResolver: { _ in nil }
        )
        process.startSampling()
        await waitUntil { process.byCpu.count == 5 }
        process.stopSampling()

        let cpu = CPUViewModel(settings: processSettings, historyStore: store)
        let memory = MemoryViewModel(settings: processSettings, historyStore: store)
        let disk = DiskViewModel(settings: processSettings, historyStore: store)
        let network = NetworkViewModel(settings: processSettings, historyStore: store)
        let gpu = GPUViewModel(settings: processSettings)
        let battery = BatteryViewModel(settings: processSettings)
        let thermal = ThermalViewModel(settings: processSettings)
        let accessoryPower = AccessoryPowerViewModel(settings: processSettings)

        for aiEnabled in [false, true] {
            Settings.shared.aiUsageEnabled = aiEnabled
            if aiEnabled {
                _ = await aiUsage.performManualRefresh()
            }

            let dashboard = DashboardView(
                cpu: cpu,
                memory: memory,
                disk: disk,
                network: network,
                gpu: gpu,
                battery: battery,
                process: process,
                thermal: thermal,
                accessoryPower: accessoryPower,
                aiUsage: aiUsage,
                initialSelection: .overview
            )
            let dashboardHost = NSHostingView(rootView: dashboard)
            let dashboardWindow = makeTestWindow(width: 420, height: 600, contentView: dashboardHost)
            defer {
                dashboardWindow.orderOut(nil)
                dashboardWindow.close()
            }
            dashboardHost.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
            dashboardHost.layoutSubtreeIfNeeded()

            XCTAssertLessThanOrEqual(dashboardHost.fittingSize.width, 420.5)
            XCTAssertLessThanOrEqual(dashboardHost.fittingSize.height, 600.5)

            let overview = OverviewView(
                selection: .constant(.overview),
                cpu: cpu,
                memory: memory,
                disk: disk,
                network: network,
                process: process,
                aiUsage: aiUsage,
                thermalState: .nominal
            )
            .frame(width: 420)
            let overviewHost = NSHostingView(rootView: overview)
            let overviewWindow = makeTestWindow(width: 420, height: 496, contentView: overviewHost)
            defer {
                overviewWindow.orderOut(nil)
                overviewWindow.close()
            }
            overviewHost.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
            overviewHost.layoutSubtreeIfNeeded()

            XCTAssertLessThanOrEqual(
                overviewHost.fittingSize.height,
                OverviewLayoutMetrics.availableOverviewHeight + 0.5,
                "OverviewView height overflowed 496pt when aiUsageEnabled=\(aiEnabled)"
            )

            let scrollView = try XCTUnwrap(firstScrollView(in: overviewHost))
            let expectedViewportHeight = CGFloat(OverviewLayoutMetrics.visibleProcessRowCount)
                * OverviewLayoutMetrics.processRowHeight(aiEnabled: aiEnabled)
            XCTAssertEqual(
                scrollView.contentView.bounds.height,
                expectedViewportHeight,
                accuracy: 2.0,
                "Process ranking viewport should fit 3 rows without clipping when aiUsageEnabled=\(aiEnabled)"
            )
            XCTAssertGreaterThan(
                scrollView.documentView?.bounds.height ?? 0,
                scrollView.contentView.bounds.height
            )
        }
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

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let match = firstScrollView(in: subview) { return match }
        }
        return nil
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.swnb.LynxBarTests.overviewGeometry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition not met within deadline")
    }
}

private actor OfflineLayoutAIUsageProvider: AIUsageProvider {
    nonisolated let id: AIUsageProviderID = .claude
    let snapshot: AIProviderQuotaSnapshot

    init(snapshot: AIProviderQuotaSnapshot) {
        self.snapshot = snapshot
    }

    func fetchQuota(now: Date) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        .success(snapshot)
    }
}
