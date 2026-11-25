import SwiftUI

struct MemoryPanelView: View {
    @ObservedObject var viewModel: MemoryViewModel
    @ObservedObject var processViewModel: ProcessViewModel
    var remediationContextProvider: @MainActor () -> ProcessRemediationContext
    @State private var processMetric: ProcessListView.Metric = .memory
    @State private var compositionExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let compositionSectionID = "memory-composition"

    init(
        viewModel: MemoryViewModel,
        processViewModel: ProcessViewModel,
        compositionInitiallyExpanded: Bool = false,
        remediationContextProvider: @escaping @MainActor () -> ProcessRemediationContext = { .inspectionOnly }
    ) {
        self.viewModel = viewModel
        self.processViewModel = processViewModel
        self.remediationContextProvider = remediationContextProvider
        _compositionExpanded = State(initialValue: compositionInitiallyExpanded)
    }

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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    HStack {
                        Label("Memory", systemImage: "memorychip")
                            .font(Theme.Font.title2.weight(.bold))
                            .foregroundStyle(Theme.memory)
                        Spacer()
                        RangePicker(
                            ranges: MemoryViewModel.allowedRanges,
                            selection: viewModel.selectedRange,
                            select: viewModel.selectRange
                        )
                    }
                    .frame(height: 28)

                    V2Card {
                        HStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Image(systemName: "gauge.medium")
                                    .font(Theme.Font.title2.weight(.semibold))
                                    .foregroundStyle(pressureColor)
                                    .frame(width: 22)
                                    .accessibilityHidden(true)
                                Text(LocalizedStringKey(pressureTitle))
                                    .font(Theme.Font.title2.weight(.bold))
                                    .foregroundStyle(pressureColor)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Memory pressure")
                            .accessibilityValue(Text(LocalizedStringKey(pressureTitle)))

                            Divider().overlay(Theme.divider)

                            HStack(spacing: 8) {
                                Image(systemName: "memorychip")
                                    .font(Theme.Font.title3.weight(.semibold))
                                    .foregroundStyle(Theme.memory)
                                    .frame(width: 20)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Formatters.percent(viewModel.snapshot.usage))
                                        .font(Theme.Font.metricValue.weight(.bold))
                                        .foregroundStyle(Theme.memory)
                                        .monospacedDigit()
                                    Text(
                                        String(
                                            format: NSLocalizedString("%@ of %@", comment: ""),
                                            Formatters.bytes(usedMemory),
                                            Formatters.bytes(viewModel.snapshot.total)
                                        )
                                    )
                                    .font(Theme.Font.micro)
                                    .foregroundStyle(Theme.mutedInk)
                                }
                            }
                            .padding(.leading, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Memory usage")
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 64)
                    }

                    V2Card {
                        VStack(
                            alignment: .leading,
                            spacing: V2LayoutPolicy.chartHeaderToPlot
                        ) {
                            IconSectionHeader(
                                systemName: "chart.xyaxis.line",
                                title: "Usage trend",
                                tint: Theme.memory,
                                accessibilityLabel: "Memory capacity used"
                            ) {
                                if let status = visibleHistoryStatus(viewModel.historyResult) {
                                    Text(status)
                                        .font(Theme.Font.micro)
                                        .foregroundStyle(Theme.mutedInk)
                                }
                            }
                            PercentHistoryChart(
                                result: viewModel.historyResult,
                                color: Theme.memory
                            )
                        }
                        .padding(8)
                        .frame(height: 135)
                    }

                    HStack(spacing: 4) {
                        V2Card {
                            ContextColumn(
                                systemName: "arrow.left.arrow.right",
                                label: "Swap",
                                value: Formatters.bytes(viewModel.snapshot.swapUsed),
                                detail: nil,
                                color: Theme.memory
                            )
                            .padding(.horizontal, 9)
                        }
                        V2Card {
                            ContextColumn(
                                systemName: "rectangle.compress.vertical",
                                label: "Compressed",
                                value: Formatters.bytes(viewModel.snapshot.compressed),
                                detail: nil,
                                color: Theme.memory
                            )
                            .padding(.horizontal, 9)
                        }
                    }
                    .frame(height: 50)

                    Button {
                        ActivityMonitor.open()
                    } label: {
                        HStack {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .font(Theme.Font.body.weight(.semibold))
                                .foregroundStyle(Theme.memory)
                                .accessibilityHidden(true)
                            Text("Inspect apps")
                                .font(Theme.Font.caption.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(Theme.Font.micro.weight(.semibold))
                                .foregroundStyle(Theme.mutedInk)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .v2InteractiveSurface()
                    }
                    .buttonStyle(.plain)
                    .background(Theme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .accessibilityLabel("Review memory-heavy apps")
                    .accessibilityHint("Opens Activity Monitor")

                    V2Card {
                        VStack(spacing: 0) {
                            IconSectionHeader(
                                systemName: "list.number",
                                title: "Processes",
                                tint: Theme.memory,
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
                        DisclosureRow(
                            title: "Composition",
                            subtitle: "",
                            systemName: "square.3.layers.3d",
                            tint: Theme.memory,
                            accessibilityLabel: "Memory composition",
                            isExpanded: $compositionExpanded
                        ) {
                            VStack(spacing: 5) {
                                CompositionRow(
                                    label: "App Memory",
                                    value: viewModel.snapshot.appMemory
                                )
                                CompositionRow(label: "Wired", value: viewModel.snapshot.wired)
                                CompositionRow(label: "Cached", value: viewModel.snapshot.cached)
                                CompositionRow(label: "Free", value: viewModel.snapshot.free)
                            }
                        }
                    }
                    .frame(minHeight: 42, alignment: .top)
                    .id(compositionSectionID)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: compositionExpanded) { expanded in
                guard expanded else { return }
                Task { @MainActor in
                    // Disclosure 自身仍在做高度动画。必须等它完成后按最终高度
                    // 计算 anchor；只 yield 一帧会在英文等较高内容中偶发滚动不足。
                    try? await Task.sleep(
                        nanoseconds: V2LayoutPolicy.expandedSectionRevealDelayNanoseconds
                    )
                    guard compositionExpanded else { return }
                    if reduceMotion {
                        proxy.scrollTo(compositionSectionID, anchor: .bottom)
                    } else {
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo(compositionSectionID, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var usedMemory: UInt64 {
        viewModel.snapshot.appMemory
            &+ viewModel.snapshot.wired
            &+ viewModel.snapshot.compressed
    }

    private var pressureTitle: String {
        switch viewModel.pressure {
        case .unknown: return "Collecting"
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    private var pressureColor: Color {
        switch viewModel.pressure {
        case .unknown: return Theme.secondaryInk
        case .normal: return Theme.health
        case .warning: return Theme.warning
        case .critical: return Theme.critical
        }
    }
}

private struct CompositionRow: View {
    let label: String
    let value: UInt64

    var body: some View {
        HStack {
            Text(LocalizedStringKey(label))
                .foregroundStyle(Theme.secondaryInk)
            Spacer()
            Text(Formatters.bytes(value))
                .monospacedDigit()
        }
        .font(Theme.Font.caption)
    }
}
