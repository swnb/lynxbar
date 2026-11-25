import SwiftUI

enum NetworkChartTooltipLayout {
    static func clampedCenterX(
        pointX: CGFloat,
        plotMinX: CGFloat,
        plotMaxX: CGFloat,
        tooltipWidth: CGFloat
    ) -> CGFloat {
        let plotWidth = max(0, plotMaxX - plotMinX)
        let constrainedWidth = min(max(0, tooltipWidth), plotWidth)
        let minimum = plotMinX + constrainedWidth / 2
        let maximum = plotMaxX - constrainedWidth / 2
        return min(max(pointX, minimum), maximum)
    }
}

enum NetworkChartCoordinates {
    /// 图表使用固定相对时间域；所有将来时间都收敛到右端 live anchor，
    /// 因此动画中不会在两颗 live 点右侧提前出现轨迹。
    static func relativeX(for timestamp: Date, domainEnd: Date) -> TimeInterval {
        min(0, timestamp.timeIntervalSince(domainEnd))
    }

    static func timestamp(for relativeX: TimeInterval, domainEnd: Date) -> Date {
        domainEnd.addingTimeInterval(min(0, relativeX))
    }
}

struct NetworkPlaybackSelectionOverlay: View {
    let selection: NetworkChartSelection
    let domainEnd: Date
    let plotFrame: CGRect
    let xDomain: ClosedRange<TimeInterval>
    let yDomain: ClosedRange<Double>

    var body: some View {
        let relativeX = NetworkChartCoordinates.relativeX(
            for: selection.timestamp,
            domainEnd: domainEnd
        )
        let rulePoint = ContinuousChartGeometry.plotPoint(
            relativeX: relativeX,
            value: yDomain.lowerBound,
            plotRect: plotFrame,
            xDomain: xDomain,
            yDomain: yDomain
        )
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                var rule = Path()
                rule.move(to: CGPoint(x: rulePoint.x, y: plotFrame.minY))
                rule.addLine(to: CGPoint(x: rulePoint.x, y: plotFrame.maxY))
                context.stroke(
                    rule,
                    with: .color(Theme.mutedInk),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 3])
                )
                drawPoint(
                    selection.downloadBytesPerSecond,
                    color: Theme.networkInput,
                    relativeX: relativeX,
                    context: &context
                )
                drawPoint(
                    selection.uploadBytesPerSecond,
                    color: Theme.networkOutput,
                    relativeX: relativeX,
                    context: &context
                )
            }
            .allowsHitTesting(false)

            NetworkChartTooltip(selection: selection)
                .frame(width: 138, alignment: .leading)
                .position(
                    x: NetworkChartTooltipLayout.clampedCenterX(
                        pointX: rulePoint.x,
                        plotMinX: plotFrame.minX,
                        plotMaxX: plotFrame.maxX,
                        tooltipWidth: 138
                    ),
                    y: plotFrame.minY + 22
                )
        }
    }

    private func drawPoint(
        _ value: Double?,
        color: Color,
        relativeX: TimeInterval,
        context: inout GraphicsContext
    ) {
        guard let value else { return }
        let center = ContinuousChartGeometry.plotPoint(
            relativeX: relativeX,
            value: value,
            plotRect: plotFrame,
            xDomain: xDomain,
            yDomain: yDomain
        )
        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - 3,
                y: center.y - 3,
                width: 6,
                height: 6
            )),
            with: .color(color)
        )
    }
}

struct NetworkChartSelection: Equatable, Identifiable {
    let timestamp: Date
    let downloadBytesPerSecond: Double?
    let uploadBytesPerSecond: Double?

    var id: Date { timestamp }
}

enum NetworkChartInspector {
    static func nearestSelection(
        to target: Date,
        down: [MetricPoint],
        up: [MetricPoint]
    ) -> NetworkChartSelection? {
        let timestamps = Set(down.map(\.timestamp) + up.map(\.timestamp))
        guard let timestamp = timestamps.min(by: { lhs, rhs in
            let leftDistance = abs(lhs.timeIntervalSince(target))
            let rightDistance = abs(rhs.timeIntervalSince(target))
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            return lhs < rhs
        }) else {
            return nil
        }

        return NetworkChartSelection(
            timestamp: timestamp,
            downloadBytesPerSecond: nearestValue(to: timestamp, in: down),
            uploadBytesPerSecond: nearestValue(to: timestamp, in: up)
        )
    }

    private static func nearestValue(
        to timestamp: Date,
        in points: [MetricPoint]
    ) -> Double? {
        points.min(by: { lhs, rhs in
            let leftDistance = abs(lhs.timestamp.timeIntervalSince(timestamp))
            let rightDistance = abs(rhs.timestamp.timeIntervalSince(timestamp))
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            return lhs.timestamp < rhs.timestamp
        })?.value
    }
}

private struct NetworkChartTooltip: View {
    let selection: NetworkChartSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Formatters.clockTime(selection.timestamp))
                .font(Theme.Font.microMono.weight(.semibold))
                .foregroundStyle(Theme.ink)
            HStack(spacing: 7) {
                tooltipValue(
                    systemName: "arrow.down",
                    value: selection.downloadBytesPerSecond,
                    color: Theme.networkInput
                )
                tooltipValue(
                    systemName: "arrow.up",
                    value: selection.uploadBytesPerSecond,
                    color: Theme.networkOutput
                )
            }
        }
        // tooltip 固定宽 138pt（见下方 .frame），封顶 xxxLarge 避免超大字号下文字换行/溢出。
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Theme.raisedStrong)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.divider, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
        .accessibilityHidden(true)
    }

    private func tooltipValue(
        systemName: String,
        value: Double?,
        color: Color
    ) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemName)
                .font(Theme.Font.micro.weight(.bold))
                .foregroundStyle(color)
            Text(value.map(Formatters.rate) ?? "—")
                .font(Theme.Font.microMono.weight(.medium))
                .foregroundStyle(Theme.secondaryInk)
        }
    }
}

/// 与图表共用同一组方向语义，保证 Overview 与 Network 详情的图例不会漂移。
struct NetworkSeriesLegend: View {
    var body: some View {
        HStack(spacing: 8) {
            NetworkSeriesLegendItem(label: "Download", color: Theme.networkInput)
            NetworkSeriesLegendItem(label: "Upload", color: Theme.networkOutput)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network direction styles")
        .accessibilityValue("Download uses cyan solid; upload uses yellow solid")
    }
}

private struct NetworkSeriesLegendItem: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(label))
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.secondaryInk)
        }
    }
}

struct ChartTimeLabels: View {
    let labels: [String]
    var leadingPadding: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                Text(label)
                    .frame(
                        maxWidth: .infinity,
                        alignment: index == 0 ? .leading : (index == labels.count - 1 ? .trailing : .center)
                    )
            }
        }
        .font(Theme.Font.micro)
        // 原本 .frame(height: 12) 是硬高度；封顶 xxxLarge 后放宽成 minHeight，
        // 超大字号时行高可以长大而不是把文字裁掉。
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .foregroundStyle(Theme.mutedInk)
        .padding(.leading, leadingPadding)
        .padding(.trailing, 4)
        .frame(minHeight: 12)
        .accessibilityHidden(true)
    }
}
