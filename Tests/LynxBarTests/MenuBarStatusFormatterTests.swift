import XCTest
@testable import LynxBar

final class MenuBarStatusFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testModeAndSlotMigrationFallbacksAreBounded() {
        XCTAssertEqual(MenuBarDisplayMode.validated("future"), .compact)
        XCTAssertEqual(MenuBarStatusSlot.validated(nil), [.cpu, .disk, .network])
        XCTAssertEqual(
            MenuBarStatusSlot.validated([
                "cpu", "cpu", "future", "memory", "gpu", "disk",
            ]),
            [.cpu, .memory, .gpu]
        )
    }

    func testCompactRetainsLegitimateShortConfigurations() {
        let oneSlot = MenuBarConfiguration(mode: .compact, slots: [.network])
        let twoSlots = MenuBarConfiguration(mode: .compact, slots: [.gpu, .cpu])
        XCTAssertEqual(oneSlot.visibleSlots, [.network])
        XCTAssertEqual(twoSlots.visibleSlots, [.gpu, .cpu])
        XCTAssertEqual(oneSlot.visibleSlots.indices.count, 1)
        let presentation = MenuBarStatusFormatter.format(
            mode: oneSlot.mode,
            slots: oneSlot.slots,
            snapshot: fullSnapshot(),
            now: now
        )
        XCTAssertEqual(presentation.segments.map(\.slot), [.network])
    }

    func testMinimalFocusAndCompactHaveFixedSlotLimits() {
        let snapshot = fullSnapshot()
        let minimal = MenuBarStatusFormatter.format(
            mode: .minimal,
            slots: MenuBarStatusSlot.allCases,
            snapshot: snapshot,
            now: now
        )
        let focus = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: MenuBarStatusSlot.allCases,
            snapshot: snapshot,
            now: now
        )
        let compact = MenuBarStatusFormatter.format(
            mode: .compact,
            slots: MenuBarStatusSlot.allCases,
            snapshot: snapshot,
            now: now
        )

        XCTAssertEqual(minimal.title, "●")
        XCTAssertEqual(minimal.segments.count, 0)
        XCTAssertEqual(focus.segments.count, 1)
        XCTAssertEqual(compact.segments.count, 3)
        XCTAssertLessThanOrEqual(minimal.estimatedWidth, 28)
        XCTAssertLessThanOrEqual(focus.estimatedWidth, 132)
        XCTAssertLessThanOrEqual(compact.estimatedWidth, 300)
    }

    func testNetworkAlwaysKeepsBothDirectionsAndAccessibleUnits() {
        let presentation = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.network],
            snapshot: fullSnapshot(),
            locale: Locale(identifier: "en_US"),
            now: now
        )

        XCTAssertTrue(presentation.title.contains("↓"))
        XCTAssertTrue(presentation.title.contains("↑"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("download"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("upload"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("per second"))
    }

    func testUnavailableAndStaleNeverKeepOldNumbers() {
        let stale = MenuBarMetricReading.numeric(
            0.92,
            observedAt: now.addingTimeInterval(-31),
            staleAfter: 30
        )
        let snapshot = MenuBarStatusSnapshot(
            health: .attention,
            readings: [
                .cpu: stale,
                .memory: .unavailable,
            ]
        )
        let presentation = MenuBarStatusFormatter.format(
            mode: .compact,
            slots: [.cpu, .memory],
            snapshot: snapshot,
            locale: Locale(identifier: "en_US"),
            now: now
        )

        XCTAssertFalse(presentation.title.contains("92"))
        XCTAssertEqual(presentation.segments.map(\.text), ["CPU —", "MEM —"])
        XCTAssertTrue(presentation.accessibilityLabel.contains("stale"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("unavailable"))
    }

    func testPublicObservationStateDoesNotExpireWithoutAStateChange() {
        let reading = MenuBarMetricReading.observedState("nominal", observationActive: true)
        XCTAssertEqual(reading.resolvedAvailability(at: now.addingTimeInterval(600)), .available)
        let stopped = MenuBarMetricReading.observedState("nominal", observationActive: false)
        XCTAssertEqual(stopped.resolvedAvailability(at: now), .unavailable)
    }

    func testMissingNumbersDoNotRenderAsZero() {
        let snapshot = MenuBarStatusSnapshot(health: .collecting, readings: [
            .cpu: .numeric(nil, observedAt: now),
            .memory: .numeric(.nan, observedAt: now),
        ])
        let presentation = MenuBarStatusFormatter.format(
            mode: .compact,
            slots: [.cpu, .memory],
            snapshot: snapshot,
            now: now
        )
        XCTAssertEqual(presentation.segments.map(\.text), ["CPU —", "MEM —"])
        XCTAssertFalse(presentation.title.contains("0%"))
    }

    func testFutureTimestampDoesNotBecomeCurrent() {
        let snapshot = MenuBarStatusSnapshot(
            health: .healthy,
            readings: [
                .cpu: .numeric(
                    0.92,
                    observedAt: now.addingTimeInterval(1),
                    staleAfter: 30
                ),
            ]
        )

        let presentation = MenuBarStatusFormatter.format(
            mode: .focus,
            slots: [.cpu],
            snapshot: snapshot,
            locale: Locale(identifier: "en_US"),
            now: now
        )

        XCTAssertEqual(presentation.segments.first?.text, "CPU —")
        XCTAssertFalse(presentation.title.contains("92"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("stale"))
    }

    func testExtremeAndNonFiniteValuesAreBounded() {
        let snapshot = MenuBarStatusSnapshot(
            health: .healthy,
            readings: [
                .cpu: .numeric(99, observedAt: now),
                .disk: .numeric(.infinity, observedAt: now),
                .network: .numeric(
                    Double.greatestFiniteMagnitude,
                    secondary: .nan,
                    observedAt: now
                ),
            ]
        )
        let presentation = MenuBarStatusFormatter.format(
            mode: .compact,
            slots: [.cpu, .disk, .network],
            snapshot: snapshot,
            now: now
        )

        XCTAssertTrue(presentation.title.contains("100%"))
        XCTAssertTrue(presentation.title.contains("DSK —"))
        XCTAssertFalse(presentation.title.contains("DSK 0%"))
        XCTAssertFalse(presentation.title.lowercased().contains("inf"))
        XCTAssertFalse(presentation.title.lowercased().contains("nan"))
        XCTAssertLessThanOrEqual(presentation.estimatedWidth, 300)
    }

    func testEnglishAndChineseAccessibilityAreComplete() {
        let english = MenuBarStatusFormatter.format(
            mode: .compact,
            slots: [.cpu, .thermal, .internalBattery],
            snapshot: fullSnapshot(),
            locale: Locale(identifier: "en_US"),
            now: now
        )
        let chinese = MenuBarStatusFormatter.format(
            mode: .compact,
            slots: [.cpu, .thermal, .internalBattery],
            snapshot: fullSnapshot(),
            locale: Locale(identifier: "zh_Hans_CN"),
            now: now
        )

        XCTAssertTrue(english.accessibilityLabel.contains("System health"))
        XCTAssertTrue(english.accessibilityLabel.contains("System thermal state"))
        XCTAssertTrue(chinese.accessibilityLabel.contains("系统健康"))
        XCTAssertTrue(chinese.accessibilityLabel.contains("系统热状态"))
        XCTAssertEqual(english.segments.count, chinese.segments.count)
    }

    func testEverySlotHasFreshUnitOrStateSemantics() {
        let presentation = MenuBarStatusFormatter.format(
            mode: .compact,
            slots: [.gpu, .disk, .accessoryBattery],
            snapshot: fullSnapshot(),
            now: now
        )

        XCTAssertTrue(presentation.segments[0].text.contains("%"))
        XCTAssertTrue(presentation.segments[1].text.contains("%"))
        XCTAssertTrue(presentation.segments[2].text.contains("%"))
    }

    private func fullSnapshot() -> MenuBarStatusSnapshot {
        MenuBarStatusSnapshot(
            health: .healthy,
            readings: [
                .cpu: .numeric(0.42, observedAt: now),
                .memory: .numeric(0.63, observedAt: now),
                .disk: .numeric(0.72, observedAt: now),
                .network: .numeric(
                    1_250_000,
                    secondary: 840_000,
                    observedAt: now
                ),
                .gpu: .numeric(0.2, observedAt: now),
                .thermal: .state("nominal", observedAt: now),
                .internalBattery: .numeric(0.85, observedAt: now),
                .accessoryBattery: .numeric(0.75, observedAt: now),
            ]
        )
    }
}
