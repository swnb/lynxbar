import XCTest
@testable import LynxBar

final class MonitoringDemandBindingTests: XCTestCase {
    func testOverviewDemandsExactlyWhatItRenders() {
        XCTAssertEqual(
            Set(MonitoringDemandBinding.modules(for: .overview)),
            [.cpu, .memory, .disk, .network, .process, .aiUsage]
        )
    }

    /// Verifies that the dedicated `.aiUsage` section maps strictly to `[.aiUsage]`.
    func testAIUsageSectionMapsToAIUsageOnly() {
        XCTAssertEqual(MonitoringDemandBinding.modules(for: .aiUsage), [.aiUsage])
    }

    func testGPUIsNotDemandedByOverview() {
        XCTAssertFalse(MonitoringDemandBinding.modules(for: .overview).contains(.gpu))
        XCTAssertFalse(MonitoringDemandBinding.modules(for: .overview).contains(.battery))
    }

    func testCPUAndMemoryPanelsBothDemandProcess() {
        XCTAssertTrue(MonitoringDemandBinding.modules(for: .cpu).contains(.process))
        XCTAssertTrue(MonitoringDemandBinding.modules(for: .memory).contains(.process))
    }

    func testOnlyNetworkPanelDemandsProcessAttribution() {
        for section in DashboardSection.allCases {
            let demandsAttribution = MonitoringDemandBinding
                .modules(for: section)
                .contains(.networkProcessAttribution)
            XCTAssertEqual(
                demandsAttribution, section == .network,
                "\(section) 对 nettop 归因的需求判定错误 —— 它是最贵的采样源"
            )
        }
    }

    func testSettingsSectionDemandsNothing() {
        XCTAssertTrue(MonitoringDemandBinding.modules(for: .settings).isEmpty)
    }

    func testOverviewHealthDemandsLightweightModulesOnly() {
        XCTAssertEqual(
            Set(MonitoringDemandBinding.overviewHealthModules),
            [.cpu, .memory, .disk, .network, .thermal]
        )
    }

    func testOverviewHealthDoesNotDemandExpensiveModules() {
        let health = Set(MonitoringDemandBinding.overviewHealthModules)
        for expensive in [MonitoringModule.gpu, .battery, .process, .networkProcessAttribution, .numericTemperature, .accessoryPower, .aiUsage] {
            XCTAssertFalse(
                health.contains(expensive),
                "\(expensive) 是昂贵模块，不得由常驻的 overviewHealth 需求"
            )
        }
    }

    /// Verifies `0 <-> 1` demand edges on `MonitoringDemandCoordinator` for `.aiUsage`
    /// across panel section switches and menu bar slot acquisition.
    @MainActor
    func testAIUsageDemandEdgesAcrossPanelSwitchesAndMenuBarSlot() {
        final class Owner: MonitoringDemandOwner {}

        let coordinator = MonitoringDemandCoordinator()
        var edges: [Bool] = []
        coordinator.onDemandChange = { module, demanded in
            if module == .aiUsage {
                edges.append(demanded)
            }
        }

        let panelOwner = Owner()
        let menuBarOwner = Owner()

        // Acquire overview modules -> 0 -> 1 edge for .aiUsage.
        var overviewTokens = MonitoringDemandBinding.modules(for: .overview).map {
            coordinator.acquire(module: $0, reason: .panel(.overview), owner: panelOwner)
        }
        XCTAssertEqual(coordinator.demandCount(for: .aiUsage), 1)
        XCTAssertEqual(edges, [true])

        // Acquire menu bar .aiUsage slot -> shared demand stays 1 (no extra edge).
        let menuBarToken = coordinator.acquire(module: .aiUsage, reason: .menuBar, owner: menuBarOwner)
        XCTAssertEqual(coordinator.demandCount(for: .aiUsage), 2)
        XCTAssertEqual(edges, [true])

        // Switch panel from .overview to .aiUsage and then .gpu -> menu bar keeps demand alive.
        let aiPanelToken = coordinator.acquire(module: .aiUsage, reason: .panel(.aiUsage), owner: panelOwner)
        overviewTokens.forEach { $0.cancel() }
        overviewTokens.removeAll()
        XCTAssertEqual(coordinator.demandCount(for: .aiUsage), 2)
        XCTAssertEqual(edges, [true])

        aiPanelToken.cancel()
        let gpuTokens = MonitoringDemandBinding.modules(for: .gpu).map {
            coordinator.acquire(module: $0, reason: .panel(.gpu), owner: panelOwner)
        }
        XCTAssertEqual(coordinator.demandCount(for: .aiUsage), 1)
        XCTAssertEqual(edges, [true])

        // Releasing menu bar slot drops .aiUsage demand 1 -> 0.
        menuBarToken.cancel()
        XCTAssertEqual(coordinator.demandCount(for: .aiUsage), 0)
        XCTAssertEqual(edges, [true, false])

        gpuTokens.forEach { $0.cancel() }
    }

    func testNumericTemperatureDemandIsLimitedToVisibleCPUOrGPU() {
        for section in DashboardSection.allCases {
            XCTAssertEqual(
                MonitoringDemandBinding.modules(for: section).contains(.numericTemperature),
                section == .cpu || section == .gpu
            )
        }
        XCTAssertTrue(MonitoringDemandBinding.modules(for: .battery).contains(.accessoryPower))
    }

    func testEverySectionMappingIsExhaustive() {
        // 保证新增 section 时不会静默落到空映射。
        for section in DashboardSection.allCases where section != .settings {
            XCTAssertFalse(
                MonitoringDemandBinding.modules(for: section).isEmpty,
                "\(section) 没有任何 module 映射，新增 section 后忘了补映射？"
            )
        }
    }
}
