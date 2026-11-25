import SwiftUI

struct CPUPanelView: View {
    @ObservedObject var viewModel: CPUViewModel
    @ObservedObject var processViewModel: ProcessViewModel
    var remediationContextProvider: @MainActor () -> ProcessRemediationContext = { .inspectionOnly }
    var thermalSnapshot: ThermalSnapshot? = nil
    @State private var processMetric: ProcessListView.Metric = .cpu

    private var processes: [DisplayProcess] {
#if DEBUG
        if let rows = NetworkInsightsVisualQAFixture.processRows {
            return processMetric == .cpu
                ? rows
                : rows.sorted { $0.memoryBytes > $1.memoryBytes }
        }
#endif
        return processMetric == .cpu ? processViewModel.byCpu : processViewModel.byMemory
    }

    private var coreUsages: [Double] {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--visual-qa-core-gauges") {
            return CoreGaugeVisualQAFixture.usages
        }
#endif
        return viewModel.snapshot.perCoreUsage
    }

    var body: some View {
        // 趋势、进程与 per-core 都是 CPU 决策入口，固定高度保证它们在 420×600 首屏同时可见。
        VStack(spacing: 4) {
            HStack {
                Label("CPU", systemImage: "cpu")
                    .font(Theme.Font.title2.weight(.bold))
                    .foregroundStyle(Theme.cpu)
                Spacer()
                RangePicker(
                    ranges: CPUViewModel.allowedRanges,
                    selection: viewModel.selectedRange,
                    select: viewModel.selectRange
                )
            }
            .frame(height: 28)

            V2Card {
                HStack(alignment: .firstTextBaseline) {
                    Text(Formatters.percent(viewModel.snapshot.usage))
                        .font(Theme.Font.metricValue.weight(.bold))
                        .foregroundStyle(Theme.cpu)
                        .monospacedDigit()
                    Text(cpuState)
                        .font(Theme.Font.callout.weight(.semibold))
                        .foregroundStyle(viewModel.snapshot.usage >= 0.85
                            ? Theme.warning : Theme.health)
                    Spacer()
                    Text(
                        String(
                            format: NSLocalizedString("%lld cores", comment: ""),
                            viewModel.snapshot.perCoreUsage.count
                        )
                    )
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.secondaryInk)
                }
                .padding(.horizontal, 10)
                .frame(height: 48)
            }

            V2Card {
                VStack(alignment: .leading, spacing: V2LayoutPolicy.chartHeaderToPlot) {
                    IconSectionHeader(
                        systemName: "chart.xyaxis.line",
                        title: "Usage trend",
                        tint: Theme.cpu,
                        accessibilityLabel: "Total CPU usage"
                    ) {
                        if let status = visibleHistoryStatus(viewModel.historyResult) {
                            Text(status)
                            .font(Theme.Font.micro)
                            .foregroundStyle(Theme.mutedInk)
                        }
                    }
                    PercentHistoryChart(
                        result: viewModel.historyResult,
                        color: Theme.cpu
                    )
                }
                .padding(8)
                .frame(height: 146)
            }

            V2Card {
                HStack {
                    ContextColumn(
                        systemName: "gauge.medium",
                        label: "Load",
                        value: String(format: "%.2f", viewModel.snapshot.loadAverage.one),
                        detail: String(
                            format: NSLocalizedString("5m %.2f · 15m %.2f", comment: ""),
                            viewModel.snapshot.loadAverage.five,
                            viewModel.snapshot.loadAverage.fifteen
                        )
                    )
                    Divider().overlay(Theme.divider)
                    ContextColumn(
                        systemName: "clock",
                        label: "Uptime",
                        value: Formatters.duration(viewModel.snapshot.uptime),
                        detail: thermalSnapshot.map {
                            $0.publicState.localizedLabel
                        } ?? NSLocalizedString("Since last restart", comment: "")
                    )
                }
                .padding(.horizontal, 10)
                .frame(height: 52)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("System context")
            }

            V2Card {
                VStack(spacing: 0) {
                    IconSectionHeader(
                        systemName: "list.number",
                        title: "Processes",
                        tint: Theme.cpu,
                        accessibilityLabel: "Top processes"
                    ) {
                        HStack(spacing: 6) {
                            RankingOverflowHint(
                                rowCount: processes.count,
                                visibleRowCount: 3
                            )
                            Picker("Sort processes", selection: $processMetric) {
                                Text("CPU").tag(ProcessListView.Metric.cpu)
                                Text("Memory").tag(ProcessListView.Metric.memory)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .controlSize(.mini)
                            .frame(width: 112)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 27)
                    DualMetricProcessTable(
                        processes: processes,
                        visibleRowCount: 3,
                        headerHeight: 15,
                        rowHeight: 22,
                        remediationContextProvider: remediationContextProvider
                    )
                }
                .frame(height: 108, alignment: .top)
            }

            V2Card {
                VStack(alignment: .leading, spacing: 3) {
                    IconSectionHeader(
                        systemName: "square.grid.3x3.fill",
                        title: "Cores",
                        tint: Theme.cpu,
                        accessibilityLabel: "Logical cores"
                    )
                    CoreDistribution(usages: coreUsages)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(height: 70)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var cpuState: String {
        if viewModel.snapshot.usage >= 0.95 { return NSLocalizedString("Critical", comment: "") }
        if viewModel.snapshot.usage >= 0.85 { return NSLocalizedString("Attention", comment: "") }
        return NSLocalizedString("Normal", comment: "")
    }
}

struct ContextColumn: View {
    let systemName: String
    let label: String
    let value: String
    let detail: String?
    var color: Color = Theme.secondaryInk

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemName)
                .font(Theme.Font.callout.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 14)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(label))
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.secondaryInk)
                Text(value)
                    .font(Theme.Font.bodyRounded.weight(.semibold))
                    .monospacedDigit()
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.mutedInk)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

enum CoreUtilizationBand: Equatable {
    case low
    case moderate
    case active
    case elevated
    case saturated

    static func normalized(_ usage: Double) -> Double {
        guard usage.isFinite else { return 0 }
        return min(max(usage, 0), 1)
    }

    static func resolve(_ usage: Double) -> Self {
        switch normalized(usage) {
        case ..<0.35:
            return .low
        case ..<0.45:
            return .moderate
        case ..<0.60:
            return .active
        case ..<0.85:
            return .elevated
        default:
            return .saturated
        }
    }

    /// 这些颜色只表示单核占用强度，不复用或替代 System Health 的告警结论。
    ///
    /// moderate/active/elevated/saturated 四档改用 Theme 里的双外观语义 token
    /// （见 Theme.swift「CPU 逐核占用强度色阶」一节）——原先是不带外观判断的
    /// `Color(red:green:blue:)` 字面量，在浅色模式下对比度不足且告警强度与
    /// 对比度顺序颠倒，问题记录见 task-E.2-report.md。
    var tint: Color {
        switch self {
        case .low:
            return Theme.cpu
        case .moderate:
            return Theme.coreModerate
        case .active:
            return Theme.coreActive
        case .elevated:
            return Theme.coreElevated
        case .saturated:
            return Theme.coreSaturated
        }
    }
}

enum CoreGaugeLayout {
    static let itemWidth: CGFloat = 28
    static let itemSpacing: CGFloat = 4
    static let gaugeDiameter: CGFloat = 28
    static let ringLineWidth: CGFloat = 3
    static let baselineContentWidth: CGFloat = 384

    /// 描边走 `strokeBorder` 收在形状内侧，所以环内可用直径要减掉两侧各一个线宽——
    /// 任何画进环里的东西都不能宽过它。逐核读数正是越过这条线才压到相邻仪表上的，
    /// 见 `CPUCoreGaugeTests` 里的宽度实测。
    static var ringInnerDiameter: CGFloat { gaugeDiameter - 2 * ringLineWidth }

    static func rowWidth(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        return CGFloat(itemCount) * itemWidth
            + CGFloat(itemCount - 1) * itemSpacing
    }
}

/// 环内不画任何文本：28pt 圆环减去两侧描边只剩 22pt 可用直径，而随 Dynamic Type
/// 缩放的百分比读数最宽要 32.9pt，画进去必然压到相邻仪表上（回归锁见
/// `CPUCoreGaugeTests`）。占用强度改由弧长和色阶单独承担，精确数值走
/// `accessibilityValue` 与 tooltip。
private struct CompactCoreGaugeStyle: GaugeStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            // strokeBorder 把描边收进形状内侧；换成 stroke 会让描边居中骑在路径上、
            // 视觉外径撑到 31pt，越过 28pt 的布局位挤掉相邻仪表的间距。
            Circle()
                .strokeBorder(
                    Theme.raisedStrong,
                    lineWidth: CoreGaugeLayout.ringLineWidth
                )
            // trim 之后不再是 InsettableShape，用不了 strokeBorder，
            // 先 inset 半个线宽把路径收进来，效果与上面的槽同心等径。
            Circle()
                .inset(by: CoreGaugeLayout.ringLineWidth / 2)
                .trim(from: 0, to: CGFloat(configuration.value))
                .stroke(
                    tint,
                    style: StrokeStyle(
                        lineWidth: CoreGaugeLayout.ringLineWidth,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
        }
    }
}

struct CoreUtilizationGauge: View {
    let coreIndex: Int
    let usage: Double

    var normalizedUsage: Double {
        CoreUtilizationBand.normalized(usage)
    }

    var accessibilityLabelText: String {
        String(
            format: NSLocalizedString("Core %lld", comment: ""),
            Int64(coreIndex + 1)
        )
    }

    var accessibilityValueText: String {
        Formatters.percent(normalizedUsage)
    }

    var tooltipText: String {
        "\(accessibilityLabelText) · \(accessibilityValueText)"
    }

    var body: some View {
        VStack(spacing: 1) {
            Gauge(value: normalizedUsage, in: 0...1) {
                Text(accessibilityLabelText)
            }
            .gaugeStyle(
                CompactCoreGaugeStyle(
                    tint: CoreUtilizationBand.resolve(usage).tint
                )
            )
            .frame(
                width: CoreGaugeLayout.gaugeDiameter,
                height: CoreGaugeLayout.gaugeDiameter
            )

            Text("\(coreIndex + 1)")
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.mutedInk)
        }
        .frame(width: CoreGaugeLayout.itemWidth)
        // 环内放不下读数，精确数值改由悬停 tooltip 补齐，鼠标用户不必只靠色阶估读。
        .help(Text(tooltipText))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityValue(Text(accessibilityValueText))
    }
}

private struct CoreDistribution: View {
    let usages: [Double]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .bottom, spacing: CoreGaugeLayout.itemSpacing) {
                ForEach(Array(usages.enumerated()), id: \.offset) { index, usage in
                    CoreUtilizationGauge(coreIndex: index, usage: usage)
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Logical cores")
    }
}

#if DEBUG
private enum CoreGaugeVisualQAFixture {
    static let usages = [
        0.620, 0.549, 0.449, 0.356, 0.301, 0.256,
        0.428, 0.415, 0.332, 0.298, 0.406, 0.236,
    ]
}
#endif
