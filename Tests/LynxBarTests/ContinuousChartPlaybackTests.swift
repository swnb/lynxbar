import CoreGraphics
import XCTest
@testable import LynxBar

final class ContinuousChartPlaybackTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 10_000)

    func testRealtimeConfigurationBuffersTwoCadences() {
        let oneSecond = configuration(cadence: 1)
        XCTAssertEqual(oneSecond.presentationDelay, 2)
        XCTAssertEqual(oneSecond.transitionDuration, 1)

        let tenSeconds = configuration(cadence: 10)
        XCTAssertEqual(tenSeconds.presentationDelay, 20)
        XCTAssertEqual(tenSeconds.transitionDuration, 10)
    }

    func testSlowCadenceUsesBoundedPresentationDelay() {
        let slow = configuration(cadence: 600)
        XCTAssertEqual(
            slow.presentationDelay,
            ContinuousChartPlaybackConfiguration.slowCadencePresentationDuration
        )
        XCTAssertEqual(slow.transitionDuration, slow.presentationDelay)
        XCTAssertLessThan(slow.presentationDelay, 2)
    }

    func testFutureInputDoesNotChangeArrivalFrame() {
        var playback = makeRealtimePlayback()
        let arrival = origin.addingTimeInterval(1)
        let before = playback.frame(at: arrival)

        playback.ingest(
            points: [
                point(-3, 10),
                point(-2, 20),
                point(-1, 30),
                point(0, 40),
                point(1, 90),
            ],
            receivedAt: arrival
        )

        XCTAssertEqual(playback.frame(at: arrival), before)
        XCTAssertTrue(playback.hasFutureSample(at: arrival))
    }

    func testInitialSingleSampleIsVisibleBeforePresentationDelayElapses() throws {
        let playback = ContinuousChartPlayback(
            configuration: configuration(cadence: 2),
            points: [point(0, 40)],
            receivedAt: origin
        )

        let frame = playback.frame(at: origin)
        let head = try XCTUnwrap(frame.liveHead)

        XCTAssertEqual(head.relativeX, 0)
        XCTAssertEqual(head.value, 40)
        XCTAssertEqual(frame.points, [head])
    }

    func testInitialHistoryKeepsItsTrueSourceLeftEdge() throws {
        let playback = ContinuousChartPlayback(
            configuration: configuration(cadence: 2),
            points: [
                point(-60, 10),
                point(-58, 20),
                point(0, 40),
            ],
            receivedAt: origin
        )

        let first = try XCTUnwrap(playback.frame(at: origin).points.first)

        XCTAssertEqual(first.relativeX, -60, accuracy: 0.000_1)
        XCTAssertEqual(first.value, 10)
        XCTAssertEqual(first.sampleTimestamp, origin.addingTimeInterval(-60))
    }

    func testInitialAnchorKeepsEveryRealtimeCadenceContinuouslyDrawable() throws {
        let plotRect = CGRect(x: 0, y: 0, width: 300, height: 100)

        for cadence in [1.0, 2.0, 5.0, 10.0] {
            let configuration = configuration(cadence: cadence)
            var points: [MetricPoint] = []
            var offset = -60.0
            var index = 0
            while offset <= 0 {
                points.append(point(offset, Double(index % 4) * 10))
                offset += cadence
                index += 1
            }
            let playback = ContinuousChartPlayback(
                configuration: configuration,
                points: points,
                receivedAt: origin
            )

            var frameOffset = 0.0
            while frameOffset <= configuration.presentationDelay + cadence {
                let frame = playback.frame(
                    at: origin.addingTimeInterval(frameOffset)
                )
                let head = try XCTUnwrap(
                    frame.liveHead,
                    "cadence \(cadence), frame \(frameOffset)"
                )
                XCTAssertFalse(frame.points.isEmpty)
                XCTAssertEqual(head.relativeX, 0)
                XCTAssertEqual(
                    frame.points.filter {
                        abs($0.relativeX) < 0.000_001
                    }.count,
                    1
                )
                let paths = ContinuousChartGeometry.paths(
                    points: frame.points,
                    plotRect: plotRect,
                    xDomain: -60 ... 0,
                    yDomain: 0 ... 40
                )
                XCTAssertLessThanOrEqual(
                    paths.line.boundingRect.minX,
                    plotRect.minX + 0.001,
                    "cadence \(cadence), frame \(frameOffset)"
                )
                frameOffset += 0.5
            }
        }
    }

    func testPlayheadMovesContinuouslyBetweenInputEvents() throws {
        let playback = makeRealtimePlayback()
        let first = playback.frame(at: origin.addingTimeInterval(0.25))
        let second = playback.frame(at: origin.addingTimeInterval(0.75))
        let firstHead = try XCTUnwrap(first.liveHead)
        let secondHead = try XCTUnwrap(second.liveHead)

        XCTAssertEqual(firstHead.relativeX, 0)
        XCTAssertEqual(secondHead.relativeX, 0)
        XCTAssertEqual(firstHead.value, 22.5, accuracy: 0.0001)
        XCTAssertEqual(secondHead.value, 27.5, accuracy: 0.0001)

        let firstTracked = try XCTUnwrap(first.points.first {
            $0.sampleTimestamp == origin.addingTimeInterval(-3)
        })
        let secondTracked = try XCTUnwrap(second.points.first {
            $0.sampleTimestamp == origin.addingTimeInterval(-3)
        })
        XCTAssertEqual(
            secondTracked.relativeX - firstTracked.relativeX,
            -0.5,
            accuracy: 0.0001
        )
    }

    func testFrameHasExactlyOneRightEdgeHeadSharedWithPath() throws {
        let frame = makeRealtimePlayback().frame(
            at: origin.addingTimeInterval(0.5)
        )
        let head = try XCTUnwrap(frame.liveHead)

        XCTAssertEqual(frame.points.filter { abs($0.relativeX) < 0.000_001 }.count, 1)
        XCTAssertEqual(frame.points.last, head)
    }

    func testStalledInputKeepsValueWhileTimeContinuesScrolling() throws {
        let playback = makeRealtimePlayback()
        let first = playback.frame(at: origin.addingTimeInterval(3))
        let second = playback.frame(at: origin.addingTimeInterval(4))

        XCTAssertEqual(first.liveHead?.value, 40)
        XCTAssertEqual(second.liveHead?.value, 40)
        let firstPoint = try XCTUnwrap(first.points.first {
            $0.sampleTimestamp == origin
        })
        let secondPoint = try XCTUnwrap(second.points.first {
            $0.sampleTimestamp == origin
        })
        XCTAssertEqual(
            secondPoint.relativeX - firstPoint.relativeX,
            -1,
            accuracy: 0.0001
        )
    }

    func testLateMiddleSampleDoesNotRewriteCommittedFrame() {
        var playback = ContinuousChartPlayback(
            configuration: configuration(cadence: 1),
            points: [point(-2, 10), point(0, 30)],
            receivedAt: origin
        )
        let playhead = origin.addingTimeInterval(10)
        let before = playback.frame(at: playhead)

        playback.ingest(
            points: [point(-2, 10), point(-1, 100), point(0, 30)],
            receivedAt: playhead
        )

        XCTAssertEqual(playback.frame(at: playhead), before)
    }

    func testCommittedBucketRevisionStartsForwardWithoutArrivalJump() throws {
        var playback = makeRealtimePlayback()
        let arrival = origin.addingTimeInterval(4)
        let before = playback.frame(at: arrival)

        playback.ingest(
            points: [
                point(-3, 10),
                point(-2, 20),
                point(-1, 30),
                point(0, 80),
            ],
            receivedAt: arrival
        )

        XCTAssertEqual(playback.frame(at: arrival), before)
        let halfway = playback.frame(at: arrival.addingTimeInterval(0.5))
        XCTAssertEqual(
            try XCTUnwrap(halfway.liveHead).value,
            60,
            accuracy: 0.0001
        )
    }

    func testSlowCadenceAddsForwardHoldAndTarget() throws {
        let slowConfiguration = configuration(cadence: 600)
        var playback = ContinuousChartPlayback(
            configuration: slowConfiguration,
            points: [point(-600, 0.4)],
            receivedAt: origin
        )
        let arrival = origin
        let before = playback.frame(at: arrival)

        playback.ingest(
            points: [point(-600, 0.4), point(0, 0.8)],
            receivedAt: arrival
        )

        XCTAssertEqual(playback.frame(at: arrival), before)
        let halfway = playback.frame(
            at: arrival.addingTimeInterval(slowConfiguration.transitionDuration / 2)
        )
        XCTAssertEqual(
            try XCTUnwrap(halfway.liveHead).value,
            0.6,
            accuracy: 0.0001
        )
    }

    func testScalarScaleWaitsThenTransitionsOnPresentationTimeline() {
        let configuration = configuration(cadence: 1)
        var playback = ContinuousChartScalarPlayback(
            configuration: configuration,
            value: 2,
            receivedAt: origin
        )

        playback.ingest(
            value: 4,
            sampledAt: origin,
            receivedAt: origin
        )

        XCTAssertEqual(playback.value(at: origin), 2)
        XCTAssertEqual(playback.value(at: origin.addingTimeInterval(0.75)), 2)
        XCTAssertEqual(playback.value(at: origin.addingTimeInterval(1.5)), 3)
        XCTAssertEqual(playback.value(at: origin.addingTimeInterval(2)), 4)
    }

    func testScalarFutureTargetCanBeSupersededWithoutArrivalJump() {
        let configuration = configuration(cadence: 1)
        var playback = ContinuousChartScalarPlayback(
            configuration: configuration,
            value: 2,
            receivedAt: origin
        )
        playback.ingest(
            value: 4,
            sampledAt: origin,
            receivedAt: origin
        )

        let secondArrival = origin.addingTimeInterval(0.5)
        let before = playback.value(at: secondArrival)
        playback.ingest(
            value: 6,
            sampledAt: secondArrival,
            receivedAt: secondArrival
        )

        XCTAssertEqual(playback.value(at: secondArrival), before)
        XCTAssertEqual(playback.value(at: origin.addingTimeInterval(1.5)), 3)
        XCTAssertEqual(playback.value(at: origin.addingTimeInterval(2)), 4.5)
        XCTAssertEqual(playback.value(at: origin.addingTimeInterval(2.5)), 6)
    }

    func testSlowCadenceScalarUsesBoundedContinuousTransition() {
        let configuration = configuration(cadence: 600)
        var playback = ContinuousChartScalarPlayback(
            configuration: configuration,
            value: 2,
            receivedAt: origin
        )

        playback.ingest(
            value: 8,
            sampledAt: origin,
            receivedAt: origin
        )

        XCTAssertEqual(playback.value(at: origin), 2)
        XCTAssertEqual(
            playback.value(at: origin.addingTimeInterval(
                configuration.transitionDuration / 2
            )),
            5
        )
        XCTAssertEqual(
            playback.value(at: origin.addingTimeInterval(
                configuration.transitionDuration
            )),
            8
        )
    }

    func testPlotCoordinateMapsDomainEndpoints() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        XCTAssertEqual(
            ContinuousChartGeometry.plotPoint(
                relativeX: -60,
                value: 0,
                plotRect: rect,
                xDomain: -60 ... 0,
                yDomain: 0 ... 100
            ),
            CGPoint(x: 10, y: 120)
        )
        XCTAssertEqual(
            ContinuousChartGeometry.plotPoint(
                relativeX: 0,
                value: 100,
                plotRect: rect,
                xDomain: -60 ... 0,
                yDomain: 0 ... 100
            ),
            CGPoint(x: 210, y: 20)
        )
    }

    func testPlotInsetsKeepLiveMarkerInsideCanvasAndHoverDomainAligned() {
        let plotRect = CGRect(x: 10, y: 20, width: 200, height: 100)
        let dataRect = ContinuousChartPlotInsets(
            startPadding: 0,
            endPadding: 9,
            verticalPadding: 3
        ).dataRect(in: plotRect)
        let upperEndpoint = ContinuousChartGeometry.plotPoint(
            relativeX: 0,
            value: 100,
            plotRect: dataRect,
            xDomain: -60 ... 0,
            yDomain: 0 ... 100
        )
        let lowerEndpoint = ContinuousChartGeometry.plotPoint(
            relativeX: 0,
            value: 0,
            plotRect: dataRect,
            xDomain: -60 ... 0,
            yDomain: 0 ... 100
        )

        XCTAssertEqual(dataRect.maxX, plotRect.maxX - 9)
        XCTAssertEqual(dataRect.minY, plotRect.minY + 3)
        XCTAssertEqual(dataRect.maxY, plotRect.maxY - 3)
        XCTAssertEqual(upperEndpoint.x, dataRect.maxX)
        XCTAssertEqual(lowerEndpoint.x, dataRect.maxX)
        XCTAssertGreaterThanOrEqual(upperEndpoint.y - 2.75, plotRect.minY)
        XCTAssertLessThanOrEqual(lowerEndpoint.y + 2.75, plotRect.maxY)
        XCTAssertLessThanOrEqual(upperEndpoint.x + 2.75, plotRect.maxX)
        XCTAssertEqual(
            ContinuousChartGeometry.domainX(
                for: dataRect.minX,
                plotRect: dataRect,
                xDomain: -60 ... 0
            ),
            -60
        )
        XCTAssertEqual(
            ContinuousChartGeometry.domainX(
                for: dataRect.maxX,
                plotRect: dataRect,
                xDomain: -60 ... 0
            ),
            0
        )
    }

    func testPercentChartMarkersRemainInsidePlotAtZeroAndFullUtilization() {
        let plotRect = CGRect(x: 10, y: 20, width: 200, height: 100)
        let dataRect = ContinuousChartPlotInsets(
            startPadding: 0,
            endPadding: 4,
            verticalPadding: 3
        ).dataRect(in: plotRect)

        for value in [0.0, 1.0] {
            let endpoint = ContinuousChartGeometry.plotPoint(
                relativeX: 0,
                value: value,
                plotRect: dataRect,
                xDomain: -60 ... 0,
                yDomain: 0 ... 1
            )
            // 与 PercentHistoryChart 的 5pt marker 一致，验证完整圆点而非中心位置。
            let markerRect = CGRect(
                x: endpoint.x - 2.5,
                y: endpoint.y - 2.5,
                width: 5,
                height: 5
            )
            XCTAssertTrue(plotRect.contains(markerRect))
        }
    }

    func testVerticalPlotPaddingDefaultsToZeroAndRejectsInvalidValues() {
        let plotRect = CGRect(x: 10, y: 20, width: 200, height: 100)
        XCTAssertEqual(ContinuousChartPlotInsets().dataRect(in: plotRect), plotRect)

        for padding in [CGFloat(-3), .nan, .infinity, -.infinity] {
            let dataRect = ContinuousChartPlotInsets(
                verticalPadding: padding
            ).dataRect(in: plotRect)
            XCTAssertEqual(dataRect, plotRect)
        }
    }

    func testMonotoneTangentIsZeroAtLocalExtremum() {
        let points = [
            framePoint(x: -2, value: 0),
            framePoint(x: -1, value: 10),
            framePoint(x: 0, value: 0),
        ]
        let tangents = ContinuousChartGeometry.monotoneTangents(points)

        XCTAssertEqual(tangents[1], 0)
    }

    private func makeRealtimePlayback() -> ContinuousChartPlayback {
        ContinuousChartPlayback(
            configuration: configuration(cadence: 1),
            points: [
                point(-3, 10),
                point(-2, 20),
                point(-1, 30),
                point(0, 40),
            ],
            receivedAt: origin
        )
    }

    private func configuration(
        cadence: TimeInterval
    ) -> ContinuousChartPlaybackConfiguration {
        ContinuousChartPlaybackConfiguration(
            rangeDuration: 60,
            cadenceHint: cadence
        )
    }

    private func point(_ offset: TimeInterval, _ value: Double) -> MetricPoint {
        MetricPoint(timestamp: origin.addingTimeInterval(offset), value: value)
    }

    private func framePoint(
        x: TimeInterval,
        value: Double
    ) -> ContinuousChartFramePoint {
        ContinuousChartFramePoint(
            presentationTimestamp: origin.addingTimeInterval(x),
            sampleTimestamp: nil,
            relativeX: x,
            value: value
        )
    }
}
