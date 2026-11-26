import Foundation
import SwiftUI

/// 连续图表只接受有限、单调的展示时间。采集 timestamp 仍保留给 hover，
/// presentation timestamp 则负责把数据发布和屏幕播放解耦。
struct ContinuousChartPlaybackConfiguration: Equatable {
    static let maximumRealtimeCadence: TimeInterval = 12
    static let slowCadencePresentationDuration: TimeInterval = 1.2

    let rangeDuration: TimeInterval
    let cadenceHint: TimeInterval
    let presentationDelay: TimeInterval
    let transitionDuration: TimeInterval

    init(rangeDuration: TimeInterval, cadenceHint: TimeInterval) {
        let safeRange = rangeDuration.isFinite && rangeDuration > 0 ? rangeDuration : 60
        let safeCadence = cadenceHint.isFinite && cadenceHint > 0 ? cadenceHint : 2

        self.rangeDuration = safeRange
        self.cadenceHint = safeCadence
        if safeCadence <= Self.maximumRealtimeCadence {
            // 两个 cadence 的缓冲保证正常下一点发布时，前一目标仍在播放头右侧。
            presentationDelay = safeCadence * 2
            transitionDuration = safeCadence
        } else {
            // Disk 的分钟/小时级采样不能让 UI 同样延迟；耗尽缓冲后通过
            // forward-only hold + target segment 在未来 1.2 秒内展示新值。
            presentationDelay = Self.slowCadencePresentationDuration
            transitionDuration = Self.slowCadencePresentationDuration
        }
    }
}

struct ContinuousChartFramePoint: Equatable {
    let presentationTimestamp: Date
    let sampleTimestamp: Date?
    let relativeX: TimeInterval
    let value: Double
}

struct ContinuousChartFrame: Equatable {
    let playhead: Date
    let points: [ContinuousChartFramePoint]
    let liveHead: ContinuousChartFramePoint?

    static func empty(at playhead: Date) -> Self {
        Self(playhead: playhead, points: [], liveHead: nil)
    }
}

private struct ContinuousChartScalarSample: Equatable {
    let sequence: Int
    let presentationTimestamp: Date
    let value: Double
}

/// 与曲线播放头共用延迟和过渡节奏的标量通道。
///
/// 网络图的 Y 轴上限也属于可见几何状态。若它在原始样本发布时立即更新，
/// 即使路径本身连续，整条曲线仍会在单帧内被压缩或拉伸。该通道把量程目标
/// 放到同一展示时间轴，并只改写尚未播放的未来区间。
struct ContinuousChartScalarPlayback: Equatable {
    let configuration: ContinuousChartPlaybackConfiguration

    private var samples: [ContinuousChartScalarSample] = []
    private var nextSequence = 0

    init(
        configuration: ContinuousChartPlaybackConfiguration,
        value: Double,
        receivedAt: Date = Date()
    ) {
        self.configuration = configuration
        reset(value: value, receivedAt: receivedAt)
    }

    var latestPresentationTimestamp: Date? {
        samples.last?.presentationTimestamp
    }

    mutating func reset(value: Double, receivedAt: Date) {
        samples = []
        nextSequence = 0
        append(
            presentationTimestamp: receivedAt,
            value: value
        )
    }

    mutating func ingest(
        value targetValue: Double,
        sampledAt: Date,
        receivedAt: Date
    ) {
        guard targetValue.isFinite,
              sampledAt.timeIntervalSinceReferenceDate.isFinite,
              receivedAt.timeIntervalSinceReferenceDate.isFinite else {
            return
        }
        if let last = samples.last,
           abs(last.value - targetValue) < 0.000_001 {
            return
        }

        let naturalTarget = sampledAt.addingTimeInterval(
            configuration.presentationDelay
        )
        let targetTimestamp = max(
            naturalTarget,
            receivedAt.addingTimeInterval(configuration.transitionDuration)
        )
        let transitionStart = max(
            receivedAt,
            targetTimestamp.addingTimeInterval(
                -configuration.transitionDuration
            )
        )
        let startValue = value(at: transitionStart) ?? targetValue

        // 新目标可以替换尚未播放的量程计划，但绝不回写 transitionStart
        // 之前的像素。连续采样下，开始/结束点与路径的新线段完全对齐。
        samples.removeAll {
            $0.presentationTimestamp >= transitionStart
        }
        append(
            presentationTimestamp: transitionStart,
            value: startValue
        )
        append(
            presentationTimestamp: targetTimestamp,
            value: targetValue
        )
        prune(before: receivedAt)
    }

    func value(at date: Date) -> Double? {
        guard let first = samples.first else { return nil }
        guard let priorIndex = samples.lastIndex(where: {
            $0.presentationTimestamp <= date
        }) else {
            return first.value
        }
        let prior = samples[priorIndex]
        guard samples.indices.contains(priorIndex + 1) else {
            return prior.value
        }
        let next = samples[priorIndex + 1]
        let duration = next.presentationTimestamp.timeIntervalSince(
            prior.presentationTimestamp
        )
        guard duration > 0 else { return next.value }
        let progress = min(
            1,
            max(0, date.timeIntervalSince(prior.presentationTimestamp) / duration)
        )
        return prior.value + (next.value - prior.value) * progress
    }

    private mutating func append(
        presentationTimestamp: Date,
        value: Double
    ) {
        guard presentationTimestamp.timeIntervalSinceReferenceDate.isFinite,
              value.isFinite else {
            return
        }
        samples.append(
            ContinuousChartScalarSample(
                sequence: nextSequence,
                presentationTimestamp: presentationTimestamp,
                value: value
            )
        )
        nextSequence += 1
        samples.sort {
            if $0.presentationTimestamp != $1.presentationTimestamp {
                return $0.presentationTimestamp < $1.presentationTimestamp
            }
            return $0.sequence < $1.sequence
        }
    }

    private mutating func prune(before receivedAt: Date) {
        let cutoff = receivedAt.addingTimeInterval(
            -configuration.rangeDuration
                - max(configuration.presentationDelay, configuration.cadenceHint) * 2
        )
        guard let firstInside = samples.firstIndex(where: {
            $0.presentationTimestamp >= cutoff
        }), firstInside > samples.startIndex else {
            return
        }
        samples.removeFirst(firstInside - 1)
    }
}

private struct ContinuousChartBufferedSample: Equatable {
    let sequence: Int
    let sampleTimestamp: Date?
    let presentationTimestamp: Date
    var value: Double
}

/// 纯值播放状态，不拥有 timer，也不依赖 SwiftUI animation transaction。
///
/// 新输入只能追加到播放头右侧；一旦某段时间已经播放，迟到数据不会回写这段
/// 几何。这样父视图发布完整新数组时，当前 Canvas frame 的像素保持不变。
struct ContinuousChartPlayback: Equatable {
    let configuration: ContinuousChartPlaybackConfiguration

    private var bufferedSamples: [ContinuousChartBufferedSample] = []
    private var sourceValues: [Date: Double] = [:]
    private var lastSourceTimestamp: Date?
    private var nextSequence = 0

    init(
        configuration: ContinuousChartPlaybackConfiguration,
        points: [MetricPoint] = [],
        receivedAt: Date = Date()
    ) {
        self.configuration = configuration
        reset(points: points, receivedAt: receivedAt)
    }

    var isEmpty: Bool {
        bufferedSamples.isEmpty
    }

    var presentationDelay: TimeInterval {
        configuration.presentationDelay
    }

    var latestPresentationTimestamp: Date? {
        bufferedSamples.last?.presentationTimestamp
    }

    var bufferedSampleCount: Int {
        bufferedSamples.count
    }

    func hasFutureSample(at date: Date) -> Bool {
        bufferedSamples.contains { $0.presentationTimestamp > date }
    }

    mutating func reset(points: [MetricPoint], receivedAt: Date) {
        bufferedSamples = []
        sourceValues = [:]
        lastSourceTimestamp = nil
        nextSequence = 0

        let validPoints = Self.validSorted(points)
        // 延迟播放只应用于后续可见运动；epoch 的第一个真实样本仍需保留
        // 原始时间锚点。否则整个历史的左端会被 presentationDelay 推空，
        // 单个首样本也会在缓冲耗尽前完全没有可绘制的 prior point。
        if let first = validPoints.first {
            appendBuffered(
                sampleTimestamp: first.timestamp,
                presentationTimestamp: first.timestamp,
                value: first.value
            )
        }

        for point in validPoints {
            sourceValues[point.timestamp] = point.value
            lastSourceTimestamp = max(lastSourceTimestamp ?? point.timestamp, point.timestamp)
            appendBuffered(
                sampleTimestamp: point.timestamp,
                presentationTimestamp: point.timestamp.addingTimeInterval(
                    configuration.presentationDelay
                ),
                value: point.value
            )
        }
        prune(before: receivedAt)
    }

    mutating func ingest(points: [MetricPoint], receivedAt: Date) {
        let validPoints = Self.validSorted(points)
        guard !validPoints.isEmpty else {
            reset(points: [], receivedAt: receivedAt)
            return
        }

        let incomingLatest = validPoints.last?.timestamp
        if let incomingLatest, let lastSourceTimestamp,
           incomingLatest < lastSourceTimestamp {
            reset(points: validPoints, receivedAt: receivedAt)
            return
        }

        let previousValues = sourceValues
        let previousLatest = lastSourceTimestamp
        var incomingValues: [Date: Double] = [:]
        for point in validPoints {
            incomingValues[point.timestamp] = point.value

            guard previousValues[point.timestamp] != point.value else { continue }
            if previousValues[point.timestamp] != nil {
                ingestRevision(point, receivedAt: receivedAt)
            } else {
                ingestNewPoint(
                    point,
                    previousLatest: previousLatest,
                    receivedAt: receivedAt
                )
            }
        }

        sourceValues = incomingValues
        lastSourceTimestamp = incomingLatest
        prune(before: receivedAt)
    }

    func frame(at playhead: Date) -> ContinuousChartFrame {
        guard let priorIndex = bufferedSamples.lastIndex(where: {
            $0.presentationTimestamp <= playhead
        }) else {
            return .empty(at: playhead)
        }

        let prior = bufferedSamples[priorIndex]
        let next = bufferedSamples.indices.contains(priorIndex + 1)
            ? bufferedSamples[priorIndex + 1]
            : nil
        let liveValue = Self.interpolatedValue(
            at: playhead,
            from: prior,
            to: next
        )
        let cutoff = playhead.addingTimeInterval(-configuration.rangeDuration)

        let committed = Array(bufferedSamples[...priorIndex])
        let firstInside = committed.firstIndex {
            $0.presentationTimestamp >= cutoff
        } ?? committed.endIndex
        let startIndex = firstInside == committed.startIndex
            ? committed.startIndex
            : committed.index(before: firstInside)

        var framePoints = committed[startIndex...].map {
            ContinuousChartFramePoint(
                presentationTimestamp: $0.presentationTimestamp,
                sampleTimestamp: $0.sampleTimestamp,
                relativeX: $0.presentationTimestamp.timeIntervalSince(playhead),
                value: $0.value
            )
        }

        let liveHead = ContinuousChartFramePoint(
            presentationTimestamp: playhead,
            sampleTimestamp: prior.presentationTimestamp == playhead
                ? prior.sampleTimestamp
                : nil,
            relativeX: 0,
            value: liveValue
        )

        if let last = framePoints.last,
           abs(last.presentationTimestamp.timeIntervalSince(playhead)) < 0.000_001 {
            framePoints[framePoints.index(before: framePoints.endIndex)] = liveHead
        } else {
            framePoints.append(liveHead)
        }

        return ContinuousChartFrame(
            playhead: playhead,
            points: Self.deduplicated(framePoints),
            liveHead: liveHead
        )
    }

    func snappedFrame(fallbackDate: Date) -> ContinuousChartFrame {
        frame(at: latestPresentationTimestamp ?? fallbackDate)
    }

    private mutating func ingestNewPoint(
        _ point: MetricPoint,
        previousLatest: Date?,
        receivedAt: Date
    ) {
        let naturalPresentation = point.timestamp.addingTimeInterval(
            configuration.presentationDelay
        )
        let hasBufferedFuture = hasFutureSample(at: receivedAt)

        if naturalPresentation > receivedAt, hasBufferedFuture {
            appendBuffered(
                sampleTimestamp: point.timestamp,
                presentationTimestamp: naturalPresentation,
                value: point.value
            )
            return
        }

        // 旧历史中间出现的新点属于 late arrival。原始 archive 仍保留它，
        // 但 live presentation 不回写已经播放的 path。
        guard previousLatest == nil || point.timestamp >= previousLatest! else {
            return
        }
        enqueueForwardTarget(point, receivedAt: receivedAt)
    }

    private mutating func ingestRevision(_ point: MetricPoint, receivedAt: Date) {
        if let futureIndex = bufferedSamples.lastIndex(where: {
            $0.sampleTimestamp == point.timestamp
                && $0.presentationTimestamp > receivedAt
        }) {
            bufferedSamples[futureIndex].value = point.value
            return
        }

        // 聚合桶 timestamp 不变但 value 修订时，从当前 presentation value
        // 向未来安排新目标，不能改写已经经过播放头的同 timestamp 点。
        enqueueForwardTarget(point, receivedAt: receivedAt)
    }

    private mutating func enqueueForwardTarget(
        _ point: MetricPoint,
        receivedAt: Date
    ) {
        let currentValue = value(at: receivedAt) ?? point.value
        appendBuffered(
            sampleTimestamp: nil,
            presentationTimestamp: receivedAt,
            value: currentValue
        )
        appendBuffered(
            sampleTimestamp: point.timestamp,
            presentationTimestamp: receivedAt.addingTimeInterval(
                configuration.transitionDuration
            ),
            value: point.value
        )
    }

    private func value(at date: Date) -> Double? {
        guard let priorIndex = bufferedSamples.lastIndex(where: {
            $0.presentationTimestamp <= date
        }) else {
            return nil
        }
        let prior = bufferedSamples[priorIndex]
        let next = bufferedSamples.indices.contains(priorIndex + 1)
            ? bufferedSamples[priorIndex + 1]
            : nil
        return Self.interpolatedValue(at: date, from: prior, to: next)
    }

    private static func interpolatedValue(
        at date: Date,
        from prior: ContinuousChartBufferedSample,
        to next: ContinuousChartBufferedSample?
    ) -> Double {
        guard let next else { return prior.value }
        let duration = next.presentationTimestamp.timeIntervalSince(
            prior.presentationTimestamp
        )
        guard duration > 0 else { return next.value }
        let progress = min(
            1,
            max(0, date.timeIntervalSince(prior.presentationTimestamp) / duration)
        )
        return prior.value + (next.value - prior.value) * progress
    }

    private mutating func appendBuffered(
        sampleTimestamp: Date?,
        presentationTimestamp: Date,
        value: Double
    ) {
        guard presentationTimestamp.timeIntervalSinceReferenceDate.isFinite,
              value.isFinite else {
            return
        }
        bufferedSamples.append(
            ContinuousChartBufferedSample(
                sequence: nextSequence,
                sampleTimestamp: sampleTimestamp,
                presentationTimestamp: presentationTimestamp,
                value: value
            )
        )
        nextSequence += 1
        bufferedSamples.sort {
            if $0.presentationTimestamp != $1.presentationTimestamp {
                return $0.presentationTimestamp < $1.presentationTimestamp
            }
            return $0.sequence < $1.sequence
        }
    }

    private mutating func prune(before receivedAt: Date) {
        let cutoff = receivedAt.addingTimeInterval(
            -configuration.rangeDuration
                - max(configuration.presentationDelay, configuration.cadenceHint) * 2
        )
        guard let firstInside = bufferedSamples.firstIndex(where: {
            $0.presentationTimestamp >= cutoff
        }), firstInside > bufferedSamples.startIndex else {
            return
        }
        // 多保留一个左侧点，Canvas clip 后曲线仍能覆盖 plot 左边界。
        bufferedSamples.removeFirst(firstInside - 1)
    }

    private static func validSorted(_ points: [MetricPoint]) -> [MetricPoint] {
        points
            .filter {
                $0.timestamp.timeIntervalSinceReferenceDate.isFinite
                    && $0.value.isFinite
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private static func deduplicated(
        _ points: [ContinuousChartFramePoint]
    ) -> [ContinuousChartFramePoint] {
        var result: [ContinuousChartFramePoint] = []
        for point in points {
            if let last = result.last,
               abs(last.presentationTimestamp.timeIntervalSince(
                point.presentationTimestamp
               )) < 0.000_001 {
                result[result.index(before: result.endIndex)] = point
            } else {
                result.append(point)
            }
        }
        return result
    }
}

struct ContinuousChartSeriesStyle {
    let color: Color
    var areaOpacity: Double = 0
    var lineWidth: CGFloat = 1.8
    var markerDiameter: CGFloat = 5
}

struct ContinuousChartCanvasSeries {
    let frame: ContinuousChartFrame
    let style: ContinuousChartSeriesStyle
}

/// Swift Charts 的刻度范围、Canvas 曲线和 hover 必须共用同一个数据矩形。
/// 留白以 pt 为单位，默认不缩进；非有限或负值按 0 处理，过大留白使可用尺寸归零。
/// 留白只改变绘制几何，不改变样本 domain 或播放时间；Canvas 仍裁剪到原 plot 边界。
struct ContinuousChartPlotInsets: Equatable {
    var startPadding: CGFloat = 0
    var endPadding: CGFloat = 0
    /// 上下对称留白，为位于 domain 边界的圆点保留半径空间。
    var verticalPadding: CGFloat = 0

    func dataRect(in plotRect: CGRect) -> CGRect {
        let safeStart = startPadding.isFinite ? max(0, startPadding) : 0
        let safeEnd = endPadding.isFinite ? max(0, endPadding) : 0
        let safeVertical = verticalPadding.isFinite ? max(0, verticalPadding) : 0
        let usableWidth = max(0, plotRect.width - safeStart - safeEnd)
        let usableHeight = max(0, plotRect.height - safeVertical * 2)
        return CGRect(
            x: plotRect.minX + safeStart,
            y: plotRect.minY + safeVertical,
            width: usableWidth,
            height: usableHeight
        )
    }
}

struct ContinuousChartCanvas: View {
    let series: [ContinuousChartCanvasSeries]
    let xDomain: ClosedRange<TimeInterval>
    let yDomain: ClosedRange<Double>
    var plotInsets = ContinuousChartPlotInsets()

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let plotRect = CGRect(origin: .zero, size: size)
            let dataRect = plotInsets.dataRect(in: plotRect)
            context.clip(to: Path(plotRect))

            for item in series {
                let paths = ContinuousChartGeometry.paths(
                    points: item.frame.points,
                    plotRect: dataRect,
                    xDomain: xDomain,
                    yDomain: yDomain
                )
                if item.style.areaOpacity > 0 {
                    let topOpacity = min(0.32, item.style.areaOpacity * 1.45)
                    context.fill(
                        paths.area,
                        with: .linearGradient(
                            Gradient(colors: [
                                item.style.color.opacity(topOpacity),
                                item.style.color.opacity(topOpacity * 0.25),
                                item.style.color.opacity(0),
                            ]),
                            startPoint: CGPoint(x: dataRect.midX, y: dataRect.minY),
                            endPoint: CGPoint(x: dataRect.midX, y: dataRect.maxY)
                        )
                    )
                }
                context.stroke(
                    paths.line,
                    with: .color(item.style.color),
                    style: StrokeStyle(
                        lineWidth: item.style.lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                if let liveHead = item.frame.liveHead {
                    let center = ContinuousChartGeometry.plotPoint(
                        relativeX: liveHead.relativeX,
                        value: liveHead.value,
                        plotRect: dataRect,
                        xDomain: xDomain,
                        yDomain: yDomain
                    )
                    let diameter = item.style.markerDiameter
                    let haloDiameter = diameter * 2.4
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: center.x - haloDiameter / 2,
                            y: center.y - haloDiameter / 2,
                            width: haloDiameter,
                            height: haloDiameter
                        )),
                        with: .color(item.style.color.opacity(0.22))
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: center.x - diameter / 2,
                            y: center.y - diameter / 2,
                            width: diameter,
                            height: diameter
                        )),
                        with: .color(item.style.color)
                    )
                    let coreDiameter = diameter * 0.42
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: center.x - coreDiameter / 2,
                            y: center.y - coreDiameter / 2,
                            width: coreDiameter,
                            height: coreDiameter
                        )),
                        with: .color(Color.white.opacity(0.75))
                    )
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct ContinuousChartPaths {
    let line: Path
    let area: Path
}

enum ContinuousChartGeometry {
    static func domainX(
        for plotX: CGFloat,
        plotRect: CGRect,
        xDomain: ClosedRange<TimeInterval>
    ) -> TimeInterval {
        guard plotRect.width > 0 else { return xDomain.lowerBound }
        let progress = min(
            1,
            max(0, (plotX - plotRect.minX) / plotRect.width)
        )
        return xDomain.lowerBound
            + (xDomain.upperBound - xDomain.lowerBound) * progress
    }

    static func plotPoint(
        relativeX: TimeInterval,
        value: Double,
        plotRect: CGRect,
        xDomain: ClosedRange<TimeInterval>,
        yDomain: ClosedRange<Double>
    ) -> CGPoint {
        let xSpan = max(Double.leastNonzeroMagnitude, xDomain.upperBound - xDomain.lowerBound)
        let ySpan = max(Double.leastNonzeroMagnitude, yDomain.upperBound - yDomain.lowerBound)
        let xProgress = (relativeX - xDomain.lowerBound) / xSpan
        let yProgress = (value - yDomain.lowerBound) / ySpan
        return CGPoint(
            x: plotRect.minX + plotRect.width * xProgress,
            y: plotRect.maxY - plotRect.height * yProgress
        )
    }

    static func paths(
        points: [ContinuousChartFramePoint],
        plotRect: CGRect,
        xDomain: ClosedRange<TimeInterval>,
        yDomain: ClosedRange<Double>
    ) -> ContinuousChartPaths {
        let ordered = deduplicatedDataPoints(points)
        guard let first = ordered.first else {
            return ContinuousChartPaths(line: Path(), area: Path())
        }

        let tangents = monotoneTangents(ordered)
        var line = Path()
        line.move(to: plotPoint(
            relativeX: first.relativeX,
            value: first.value,
            plotRect: plotRect,
            xDomain: xDomain,
            yDomain: yDomain
        ))
        appendCurve(
            to: &line,
            points: ordered,
            tangents: tangents,
            plotRect: plotRect,
            xDomain: xDomain,
            yDomain: yDomain
        )

        var area = line
        if let last = ordered.last {
            area.addLine(to: plotPoint(
                relativeX: last.relativeX,
                value: yDomain.lowerBound,
                plotRect: plotRect,
                xDomain: xDomain,
                yDomain: yDomain
            ))
            area.addLine(to: plotPoint(
                relativeX: first.relativeX,
                value: yDomain.lowerBound,
                plotRect: plotRect,
                xDomain: xDomain,
                yDomain: yDomain
            ))
            area.closeSubpath()
        }
        return ContinuousChartPaths(line: line, area: area)
    }

    static func monotoneTangents(
        _ points: [ContinuousChartFramePoint]
    ) -> [Double] {
        guard points.count > 1 else { return Array(repeating: 0, count: points.count) }
        let intervals = zip(points, points.dropFirst()).map {
            max(Double.leastNonzeroMagnitude, $1.relativeX - $0.relativeX)
        }
        let slopes = zip(points, points.dropFirst()).enumerated().map { index, pair in
            (pair.1.value - pair.0.value) / intervals[index]
        }

        var tangents = Array(repeating: 0.0, count: points.count)
        tangents[0] = slopes[0]
        tangents[points.count - 1] = slopes[slopes.count - 1]
        guard points.count > 2 else { return tangents }

        for index in 1 ..< points.count - 1 {
            let leftSlope = slopes[index - 1]
            let rightSlope = slopes[index]
            guard leftSlope * rightSlope > 0 else {
                tangents[index] = 0
                continue
            }
            let leftWidth = intervals[index - 1]
            let rightWidth = intervals[index]
            let weightOne = 2 * rightWidth + leftWidth
            let weightTwo = rightWidth + 2 * leftWidth
            tangents[index] = (weightOne + weightTwo)
                / (weightOne / leftSlope + weightTwo / rightSlope)
        }
        return tangents
    }

    private static func appendCurve(
        to path: inout Path,
        points: [ContinuousChartFramePoint],
        tangents: [Double],
        plotRect: CGRect,
        xDomain: ClosedRange<TimeInterval>,
        yDomain: ClosedRange<Double>
    ) {
        guard points.count > 1 else { return }
        for index in 0 ..< points.count - 1 {
            let current = points[index]
            let next = points[index + 1]
            let width = next.relativeX - current.relativeX
            let firstControl = plotPoint(
                relativeX: current.relativeX + width / 3,
                value: current.value + tangents[index] * width / 3,
                plotRect: plotRect,
                xDomain: xDomain,
                yDomain: yDomain
            )
            let secondControl = plotPoint(
                relativeX: next.relativeX - width / 3,
                value: next.value - tangents[index + 1] * width / 3,
                plotRect: plotRect,
                xDomain: xDomain,
                yDomain: yDomain
            )
            path.addCurve(
                to: plotPoint(
                    relativeX: next.relativeX,
                    value: next.value,
                    plotRect: plotRect,
                    xDomain: xDomain,
                    yDomain: yDomain
                ),
                control1: firstControl,
                control2: secondControl
            )
        }
    }

    private static func deduplicatedDataPoints(
        _ points: [ContinuousChartFramePoint]
    ) -> [ContinuousChartFramePoint] {
        let sorted = points.sorted { $0.relativeX < $1.relativeX }
        var result: [ContinuousChartFramePoint] = []
        for point in sorted {
            if let last = result.last, abs(last.relativeX - point.relativeX) < 0.000_001 {
                result[result.index(before: result.endIndex)] = point
            } else {
                result.append(point)
            }
        }
        return result
    }
}
