import Foundation
import XCTest
@testable import LynxBar

final class NetworkChartInspectorTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testSelectsNearestRealTimestampAndDirectionValues() throws {
        let down = [
            point(0, 10),
            point(10, 20),
            point(20, 30),
        ]
        let up = [
            point(0, 1),
            point(10, 2),
            point(20, 3),
        ]

        let selection = try XCTUnwrap(
            NetworkChartInspector.nearestSelection(
                to: origin.addingTimeInterval(12),
                down: down,
                up: up
            )
        )

        XCTAssertEqual(selection.timestamp, origin.addingTimeInterval(10))
        XCTAssertEqual(selection.downloadBytesPerSecond, 20)
        XCTAssertEqual(selection.uploadBytesPerSecond, 2)
        XCTAssertEqual(selection.id, selection.timestamp)
    }

    func testSparseDirectionUsesItsNearestRealPointWithoutInventingData() throws {
        let selection = try XCTUnwrap(
            NetworkChartInspector.nearestSelection(
                to: origin.addingTimeInterval(9),
                down: [point(10, 50)],
                up: []
            )
        )

        XCTAssertEqual(selection.timestamp, origin.addingTimeInterval(10))
        XCTAssertEqual(selection.downloadBytesPerSecond, 50)
        XCTAssertNil(selection.uploadBytesPerSecond)
    }

    func testEmptySeriesHasNoSelection() {
        XCTAssertNil(
            NetworkChartInspector.nearestSelection(
                to: origin,
                down: [],
                up: []
            )
        )
    }

    func testClockTimeAlwaysIncludesSeconds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 3_723)

        XCTAssertEqual(Formatters.clockTime(date, calendar: calendar), "01:02:03")
    }

    func testRelativeTimeKeepsLiveAndFuturePointsAtRightAnchor() {
        XCTAssertEqual(
            NetworkChartCoordinates.relativeX(
                for: origin,
                domainEnd: origin
            ),
            0
        )
        XCTAssertEqual(
            NetworkChartCoordinates.relativeX(
                for: origin.addingTimeInterval(1),
                domainEnd: origin
            ),
            0
        )
        XCTAssertEqual(
            NetworkChartCoordinates.relativeX(
                for: origin.addingTimeInterval(-12),
                domainEnd: origin
            ),
            -12
        )
    }

    func testRelativeTimeConvertsHoverOffsetBackToTimestamp() {
        XCTAssertEqual(
            NetworkChartCoordinates.timestamp(
                for: -15,
                domainEnd: origin
            ),
            origin.addingTimeInterval(-15)
        )
        XCTAssertEqual(
            NetworkChartCoordinates.timestamp(
                for: 3,
                domainEnd: origin
            ),
            origin
        )
    }

    func testScaleExpandsImmediatelyAndShrinksOnlyAfterHysteresis() {
        let initial = NetworkChartScalePolicy.initial(maximum: 90)
        XCTAssertEqual(initial.upperBound, 200)

        let expanded = NetworkChartScalePolicy.updated(
            state: initial,
            maximum: 220
        )
        XCTAssertEqual(expanded.upperBound, 500)

        var state = expanded
        for expectedCount in 1 ..< NetworkChartScalePolicy.shrinkDelaySamples {
            state = NetworkChartScalePolicy.updated(state: state, maximum: 20)
            XCTAssertEqual(state.upperBound, 500)
            XCTAssertEqual(state.lowSampleCount, expectedCount)
        }

        state = NetworkChartScalePolicy.updated(state: state, maximum: 20)
        XCTAssertEqual(state.upperBound, 50)
        XCTAssertEqual(state.lowSampleCount, 0)
    }

    func testScaleDoesNotAlterMeasuredValues() {
        XCTAssertEqual(NetworkChartScalePolicy.niceUpperBound(for: 0), 1)
        XCTAssertEqual(NetworkChartScalePolicy.niceUpperBound(for: 1_024), 2_000)
    }

    func testTooltipCenterIsClampedToBothPlotEdges() {
        XCTAssertEqual(
            NetworkChartTooltipLayout.clampedCenterX(
                pointX: 1,
                plotMinX: 10,
                plotMaxX: 210,
                tooltipWidth: 80
            ),
            50
        )
        XCTAssertEqual(
            NetworkChartTooltipLayout.clampedCenterX(
                pointX: 200,
                plotMinX: 10,
                plotMaxX: 210,
                tooltipWidth: 80
            ),
            170
        )
        XCTAssertEqual(
            NetworkChartTooltipLayout.clampedCenterX(
                pointX: 100,
                plotMinX: 10,
                plotMaxX: 210,
                tooltipWidth: 80
            ),
            100
        )
    }

    private func point(_ offset: TimeInterval, _ value: Double) -> MetricPoint {
        MetricPoint(timestamp: origin.addingTimeInterval(offset), value: value)
    }
}
