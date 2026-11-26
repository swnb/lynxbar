import Charts
import SwiftUI

struct NetworkChartSampleSignature: Equatable {
    let downTimestamp: Date?
    let downValue: Double?
    let upTimestamp: Date?
    let upValue: Double?
}

struct NetworkChartScaleState: Equatable {
    let upperBound: Double
    let lowSampleCount: Int
}

enum NetworkChartScalePolicy {
    static let shrinkThreshold = 0.55
    static let shrinkDelaySamples = 6

    static func initial(maximum: Double) -> NetworkChartScaleState {
        NetworkChartScaleState(
            upperBound: niceUpperBound(for: maximum),
            lowSampleCount: 0
        )
    }

    static func updated(
        state: NetworkChartScaleState,
        maximum: Double
    ) -> NetworkChartScaleState {
        let required = niceUpperBound(for: maximum)
        if required > state.upperBound {
            return NetworkChartScaleState(upperBound: required, lowSampleCount: 0)
        }

        guard required < state.upperBound * shrinkThreshold else {
            return NetworkChartScaleState(
                upperBound: state.upperBound,
                lowSampleCount: 0
            )
        }

        let lowSampleCount = state.lowSampleCount + 1
        guard lowSampleCount >= shrinkDelaySamples else {
            return NetworkChartScaleState(
                upperBound: state.upperBound,
                lowSampleCount: lowSampleCount
            )
        }
        return NetworkChartScaleState(upperBound: required, lowSampleCount: 0)
    }

    static func niceUpperBound(for maximum: Double) -> Double {
        guard maximum.isFinite, maximum > 0 else { return 1 }
        let padded = maximum * 1.12
        let magnitude = pow(10, floor(log10(padded)))
        let normalized = padded / magnitude
        let niceNormalized: Double
        switch normalized {
        case ...1:
            niceNormalized = 1
        case ...2:
            niceNormalized = 2
        case ...5:
            niceNormalized = 5
        default:
            niceNormalized = 10
        }
        return niceNormalized * magnitude
    }
}

struct NetworkThroughputChart: View {
    private static let plotInsets = ContinuousChartPlotInsets(
        startPadding: 0,
        endPadding: 9,
        verticalPadding: 3
    )

    let down: MetricHistoryResult
    let up: MetricHistoryResult
    let cadenceHint: TimeInterval

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: NetworkChartSelection?
    @State private var downPlayback: ContinuousChartPlayback
    @State private var upPlayback: ContinuousChartPlayback
    @State private var scalePlayback: ContinuousChartScalarPlayback
    @State private var displayedRange: HistoryRange
    @State private var scaleState: NetworkChartScaleState

    init(
        down: MetricHistoryResult,
        up: MetricHistoryResult,
        cadenceHint: TimeInterval? = nil
    ) {
        self.down = down
        self.up = up
        let resolvedCadence = cadenceHint
            ?? SamplingPolicy.liveInterval(Settings.shared.updateInterval)
        self.cadenceHint = resolvedCadence

        let configuration = ContinuousChartPlaybackConfiguration(
            rangeDuration: down.range.duration,
            cadenceHint: resolvedCadence
        )
        let receivedAt = Date()
        _downPlayback = State(initialValue: ContinuousChartPlayback(
            configuration: configuration,
            points: down.points,
            receivedAt: receivedAt
        ))
        _upPlayback = State(initialValue: ContinuousChartPlayback(
            configuration: configuration,
            points: up.points,
            receivedAt: receivedAt
        ))
        _displayedRange = State(initialValue: down.range)
        let initialScale = NetworkChartScalePolicy.initial(
            maximum: Self.maximumValue(down: down, up: up)
        )
        _scaleState = State(initialValue: initialScale)
        _scalePlayback = State(initialValue: ContinuousChartScalarPlayback(
            configuration: configuration,
            value: initialScale.upperBound,
            receivedAt: receivedAt
        ))
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 60.0,
            paused: timelineIsPaused
        )) { context in
            let playhead = playbackDate(for: context.date)
            let displayedYDomain = yDomain(at: playhead)

            VStack(spacing: 0) {
                Chart {
                    ContinuousChartDomainMarks(
                        xDomain: relativeXDomain,
                        yDomain: displayedYDomain
                    )
                }
                .chartLegend(.hidden)
                .chartXScale(
                    domain: relativeXDomain,
                    range: .plotDimension(
                        startPadding: Self.plotInsets.startPadding,
                        endPadding: Self.plotInsets.endPadding
                    )
                )
                .chartYScale(
                    domain: displayedYDomain,
                    range: .plotDimension(
                        startPadding: Self.plotInsets.verticalPadding,
                        endPadding: Self.plotInsets.verticalPadding
                    )
                )
                .chartPlotStyle { plotArea in
                    plotArea.clipped()
                }
                .chartXAxis {
                    AxisMarks(values: xAxisValues) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                            .foregroundStyle(Theme.chartGrid)
                    }
                }
                .chartYAxis {
                    AxisMarks(
                        position: .leading,
                        values: yAxisValues(for: displayedYDomain)
                    ) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                            .foregroundStyle(Theme.chartGrid)
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(Formatters.rate(number))
                                    .font(Theme.Font.micro)
                                    // 理由同 PercentHistoryChart：Y 轴刻度封顶 xxxLarge，
                                    // 避免定宽面板里绘图区被挤没。
                                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            }
                        }
                        .foregroundStyle(Theme.mutedInk)
                    }
                }
                .overlay {
                    if downPlayback.isEmpty && upPlayback.isEmpty {
                        Text("Collecting history…")
                            .font(Theme.Font.subheadline)
                            .foregroundStyle(Theme.mutedInk)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let warmUpText {
                        Text(warmUpText)
                            .font(Theme.Font.micro.weight(.medium))
                            .foregroundStyle(Theme.mutedInk)
                            .padding(.leading, 50)
                            .padding(.top, 2)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        let plotFrame = geometry[proxy.plotAreaFrame]
                        let dataFrame = Self.plotInsets.dataRect(in: plotFrame)
                        ZStack(alignment: .topLeading) {
                            ContinuousChartCanvas(
                                series: [
                                    ContinuousChartCanvasSeries(
                                        frame: downPlayback.frame(at: playhead),
                                        style: ContinuousChartSeriesStyle(
                                            color: Theme.networkInput,
                                            areaOpacity: 0.15,
                                            lineWidth: 1.8,
                                            markerDiameter: 5.5
                                        )
                                    ),
                                    ContinuousChartCanvasSeries(
                                        frame: upPlayback.frame(at: playhead),
                                        style: ContinuousChartSeriesStyle(
                                            color: Theme.networkOutput,
                                            areaOpacity: 0,
                                            lineWidth: 1.8,
                                            markerDiameter: 5.5
                                        )
                                    ),
                                ],
                                xDomain: relativeXDomain,
                                yDomain: displayedYDomain,
                                plotInsets: Self.plotInsets
                            )
                            .frame(width: plotFrame.width, height: plotFrame.height)
                            .position(x: plotFrame.midX, y: plotFrame.midY)

                            if let selection = presentedSelection(
                                at: hoverDomainEnd(for: playhead)
                            ) {
                                NetworkPlaybackSelectionOverlay(
                                    selection: selection,
                                    domainEnd: hoverDomainEnd(for: playhead),
                                    plotFrame: dataFrame,
                                    xDomain: relativeXDomain,
                                    yDomain: displayedYDomain
                                )
                            }

                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    updateSelection(
                                        phase,
                                        plotFrame: dataFrame,
                                        domainEnd: hoverDomainEnd(for: playhead)
                                    )
                                }
                        }
                    }
                }

                ChartTimeLabels(labels: xAxisLabelTexts, leadingPadding: 48)
            }
        }
        .onAppear {
            resetPlayback()
        }
        .onChange(of: sampleSignature) { _ in
            ingestLatest()
        }
        .onChange(of: range) { _ in
            resetPlayback()
        }
        .onChange(of: cadenceHint) { _ in
            resetPlayback()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network throughput history")
        .accessibilityValue(
            String(
                format: NSLocalizedString("Download %@, upload %@", comment: ""),
                Formatters.rate(down.points.last?.value ?? 0),
                Formatters.rate(up.points.last?.value ?? 0)
            )
        )
    }

    private var range: HistoryRange { down.range }

    private var sampleSignature: NetworkChartSampleSignature {
        NetworkChartSampleSignature(
            downTimestamp: down.points.last?.timestamp,
            downValue: down.points.last?.value,
            upTimestamp: up.points.last?.timestamp,
            upValue: up.points.last?.value
        )
    }

    private var relativeXDomain: ClosedRange<TimeInterval> {
        -displayedRange.duration ... 0
    }

    private func yDomain(at playhead: Date) -> ClosedRange<Double> {
        let upperBound = max(
            1,
            scalePlayback.value(at: playhead) ?? scaleState.upperBound
        )
        return 0 ... upperBound
    }

    private func yAxisValues(
        for domain: ClosedRange<Double>
    ) -> [Double] {
        (0...4).map { index in
            domain.upperBound * Double(index) / 4
        }
    }

    private var xAxisValues: [TimeInterval] {
        (0...4).map { index in
            -displayedRange.duration + displayedRange.duration * Double(index) / 4
        }
    }

    private var xAxisLabelTexts: [String] {
        (0...4).map { index in
            networkAxisLabel(
                forRemaining: displayedRange.duration * Double(4 - index) / 4
            )
        }
    }

    private func networkAxisLabel(forRemaining delta: TimeInterval) -> String {
        if displayedRange == .minute { return "\(Int(delta))s" }
        if delta < 3_600 { return "\(Int(delta / 60))m" }
        if delta <= 86_400 { return "\(Int(delta / 3_600))h" }
        return "\(Int(delta / 86_400))d"
    }

    private var warmUpText: String? {
        guard !(down.points.isEmpty && up.points.isEmpty),
              down.isWarmingUp || up.isWarmingUp else {
            return nil
        }
        let available = min(down.availableDuration, up.availableDuration)
        return String(
            format: NSLocalizedString("%lld seconds available · warming up", comment: ""),
            Int64(available)
        )
    }

    private var timelineIsPaused: Bool {
        (downPlayback.isEmpty && upPlayback.isEmpty)
            || motionIsReduced
    }

    private var motionIsReduced: Bool {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--visual-qa-reduce-motion") {
            return true
        }
#endif
        return reduceMotion
    }

    private func playbackDate(for timelineDate: Date) -> Date {
        guard motionIsReduced else { return timelineDate }
        return [
            downPlayback.latestPresentationTimestamp,
            upPlayback.latestPresentationTimestamp,
            scalePlayback.latestPresentationTimestamp,
        ]
        .compactMap { $0 }
        .max() ?? timelineDate
    }

    private func hoverDomainEnd(for playhead: Date) -> Date {
        playhead.addingTimeInterval(-downPlayback.presentationDelay)
    }

    private func updateSelection(
        _ phase: HoverPhase,
        plotFrame: CGRect,
        domainEnd: Date
    ) {
        switch phase {
        case let .active(location):
            guard plotFrame.contains(location), plotFrame.width > 0 else {
                selection = nil
                return
            }
            let relativeX = ContinuousChartGeometry.domainX(
                for: location.x,
                plotRect: plotFrame,
                xDomain: relativeXDomain
            )
            let target = NetworkChartCoordinates.timestamp(
                for: relativeX,
                domainEnd: domainEnd
            )
            selection = NetworkChartInspector.nearestSelection(
                to: target,
                down: presentedPoints(down.points, through: domainEnd),
                up: presentedPoints(up.points, through: domainEnd)
            )
        case .ended:
            selection = nil
        }
    }

    private func presentedSelection(at domainEnd: Date) -> NetworkChartSelection? {
        if let selection {
            return selection.timestamp <= domainEnd ? selection : nil
        }
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let argumentIndex = arguments.firstIndex(of: "--visual-qa-chart-hover") {
            let downPoints = presentedPoints(down.points, through: domainEnd)
            let upPoints = presentedPoints(up.points, through: domainEnd)
            let timestamps = Array(
                Set(downPoints.map(\.timestamp) + upPoints.map(\.timestamp))
            ).sorted()
            guard !timestamps.isEmpty else { return nil }
            let valueIndex = arguments.index(after: argumentIndex)
            let requestedPosition = valueIndex < arguments.endIndex
                ? arguments[valueIndex].lowercased()
                : "right"
            let timestamp: Date
            switch requestedPosition {
            case "left":
                timestamp = timestamps[0]
            case "middle":
                timestamp = timestamps[timestamps.count / 2]
            default:
                timestamp = timestamps[timestamps.count - 1]
            }
            return NetworkChartInspector.nearestSelection(
                to: timestamp,
                down: downPoints,
                up: upPoints
            )
        }
#endif
        return nil
    }

    private func presentedPoints(
        _ points: [MetricPoint],
        through domainEnd: Date
    ) -> [MetricPoint] {
        points.filter { $0.timestamp <= domainEnd }
    }

    private func ingestLatest() {
        let receivedAt = Date()
        downPlayback.ingest(points: down.points, receivedAt: receivedAt)
        upPlayback.ingest(points: up.points, receivedAt: receivedAt)
        let nextScale = NetworkChartScalePolicy.updated(
            state: scaleState,
            maximum: Self.maximumValue(down: down, up: up)
        )
        if nextScale.upperBound != scaleState.upperBound {
            scalePlayback.ingest(
                value: nextScale.upperBound,
                sampledAt: latestSampleTimestamp ?? receivedAt,
                receivedAt: receivedAt
            )
        }
        scaleState = nextScale
    }

    private func resetPlayback() {
        let configuration = ContinuousChartPlaybackConfiguration(
            rangeDuration: range.duration,
            cadenceHint: cadenceHint
        )
        let receivedAt = Date()
        displayedRange = range
        downPlayback = ContinuousChartPlayback(
            configuration: configuration,
            points: down.points,
            receivedAt: receivedAt
        )
        upPlayback = ContinuousChartPlayback(
            configuration: configuration,
            points: up.points,
            receivedAt: receivedAt
        )
        let initialScale = NetworkChartScalePolicy.initial(
            maximum: Self.maximumValue(down: down, up: up)
        )
        scaleState = initialScale
        scalePlayback = ContinuousChartScalarPlayback(
            configuration: configuration,
            value: initialScale.upperBound,
            receivedAt: receivedAt
        )
        selection = nil
    }

    private var latestSampleTimestamp: Date? {
        [
            down.points.last?.timestamp,
            up.points.last?.timestamp,
        ]
        .compactMap { $0 }
        .max()
    }

    private static func maximumValue(
        down: MetricHistoryResult,
        up: MetricHistoryResult
    ) -> Double {
        (down.points + up.points).map(\.value).max() ?? 0
    }
}
