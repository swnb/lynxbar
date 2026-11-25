import Charts
import SwiftUI

/// Swift Charts 继续拥有轴、刻度与 plot frame，但动态曲线由 Canvas 绘制。
/// 两颗透明且固定拓扑的 anchor 只负责声明完整 domain。
struct ContinuousChartDomainMarks: ChartContent {
    let xDomain: ClosedRange<TimeInterval>
    let yDomain: ClosedRange<Double>

    var body: some ChartContent {
        PointMark(
            x: .value("Domain start", xDomain.lowerBound),
            y: .value("Domain minimum", yDomain.lowerBound)
        )
        .foregroundStyle(.clear)
        .symbolSize(0)
        PointMark(
            x: .value("Domain end", xDomain.upperBound),
            y: .value("Domain maximum", yDomain.upperBound)
        )
        .foregroundStyle(.clear)
        .symbolSize(0)
    }
}

struct PercentHistoryChart: View {
    private static let plotInsets = ContinuousChartPlotInsets(
        startPadding: 0,
        endPadding: 4,
        verticalPadding: 3
    )

    let result: MetricHistoryResult
    let color: Color
    let cadenceHint: TimeInterval

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playback: ContinuousChartPlayback
    @State private var displayedRange: HistoryRange

    init(
        result: MetricHistoryResult,
        color: Color,
        cadenceHint: TimeInterval? = nil
    ) {
        self.result = result
        self.color = color
        let resolvedCadence = cadenceHint
            ?? SamplingPolicy.liveInterval(Settings.shared.updateInterval)
        self.cadenceHint = resolvedCadence

        let receivedAt = Date()
        _playback = State(initialValue: ContinuousChartPlayback(
            configuration: ContinuousChartPlaybackConfiguration(
                rangeDuration: result.range.duration,
                cadenceHint: resolvedCadence
            ),
            points: result.points,
            receivedAt: receivedAt
        ))
        _displayedRange = State(initialValue: result.range)
    }

    var body: some View {
        VStack(spacing: 0) {
            Chart {
                ContinuousChartDomainMarks(
                    xDomain: xDomain,
                    yDomain: yDomain
                )
            }
            .chartXScale(
                domain: xDomain,
                range: .plotDimension(
                    startPadding: Self.plotInsets.startPadding,
                    endPadding: Self.plotInsets.endPadding
                )
            )
            .chartYScale(
                domain: yDomain,
                range: .plotDimension(
                    startPadding: Self.plotInsets.verticalPadding,
                    endPadding: Self.plotInsets.verticalPadding
                )
            )
            .chartXAxis {
                AxisMarks(values: xAxisValues) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Theme.divider)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Theme.divider)
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(Formatters.percent(number))
                                .font(Theme.Font.micro)
                                // 420pt 定宽面板里 Y 轴刻度列会随文字变宽挤压绘图区，
                                // 封顶在 xxxLarge——超大字号用户仍可读，但不会把图表挤没。
                                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        }
                    }
                    .foregroundStyle(Theme.mutedInk)
                }
            }
            .overlay {
                if playback.isEmpty {
                    Text("Collecting history…")
                        .font(Theme.Font.subheadline)
                        .foregroundStyle(Theme.mutedInk)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let plotFrame = geometry[proxy.plotAreaFrame]
                    TimelineView(.animation(
                        minimumInterval: 1.0 / 60.0,
                        paused: timelineIsPaused
                    )) { context in
                        ContinuousChartCanvas(
                            series: [
                                ContinuousChartCanvasSeries(
                                    frame: playbackFrame(at: context.date),
                                    style: ContinuousChartSeriesStyle(
                                        color: color,
                                        areaOpacity: 0.18,
                                        lineWidth: 1.7,
                                        markerDiameter: 5
                                    )
                                ),
                            ],
                            xDomain: xDomain,
                            yDomain: yDomain,
                            plotInsets: Self.plotInsets
                        )
                        .frame(width: plotFrame.width, height: plotFrame.height)
                        .position(x: plotFrame.midX, y: plotFrame.midY)
                    }
                }
            }

            ChartTimeLabels(labels: xAxisLabelTexts)
        }
        .onAppear {
            resetPlayback()
        }
        .onChange(of: sampleSignature) { _ in
            playback.ingest(points: result.points, receivedAt: Date())
        }
        .onChange(of: result.range) { _ in
            resetPlayback()
        }
        .onChange(of: cadenceHint) { _ in
            resetPlayback()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Metric history")
        .accessibilityValue(historyAccessibilityValue(result))
    }

    private var sampleSignature: MetricChartSampleSignature {
        MetricChartSampleSignature(
            timestamp: result.points.last?.timestamp,
            value: result.points.last?.value
        )
    }

    private var xDomain: ClosedRange<TimeInterval> {
        -displayedRange.duration ... 0
    }

    /// 固定五个等距刻度，既让不同页面可比较，也避免自动刻度把 60s/0s 端点裁掉。
    private var xAxisValues: [TimeInterval] {
        (0...4).map { index in
            -displayedRange.duration + displayedRange.duration * Double(index) / 4
        }
    }

    private var xAxisLabelTexts: [String] {
        (0...4).map { index in
            axisLabel(forRemaining: displayedRange.duration * Double(4 - index) / 4)
        }
    }

    private var yDomain: ClosedRange<Double> {
        0 ... 1
    }

    private func axisLabel(forRemaining delta: TimeInterval) -> String {
        if displayedRange == .minute { return "\(Int(delta.rounded()))s" }
        if delta < 3_600 { return "\(Int((delta / 60).rounded()))m" }
        if delta <= 86_400 { return "\(Int((delta / 3_600).rounded()))h" }
        return "\(Int((delta / 86_400).rounded()))d"
    }

    private var timelineIsPaused: Bool {
        playback.isEmpty || motionIsReduced
    }

    private var motionIsReduced: Bool {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--visual-qa-reduce-motion") {
            return true
        }
#endif
        return reduceMotion
    }

    private func playbackFrame(at timelineDate: Date) -> ContinuousChartFrame {
        motionIsReduced
            ? playback.snappedFrame(fallbackDate: timelineDate)
            : playback.frame(at: timelineDate)
    }

    private func resetPlayback() {
        displayedRange = result.range
        playback = ContinuousChartPlayback(
            configuration: ContinuousChartPlaybackConfiguration(
                rangeDuration: result.range.duration,
                cadenceHint: cadenceHint
            ),
            points: result.points,
            receivedAt: Date()
        )
    }
}

private struct MetricChartSampleSignature: Equatable {
    let timestamp: Date?
    let value: Double?
}

private func historyAccessibilityValue(_ result: MetricHistoryResult) -> String {
    let latest = result.points.last.map { Formatters.percent($0.value) }
        ?? NSLocalizedString("No samples", comment: "")
    return "\(latest), \(historySubtitle(result))"
}
