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
                VStack(spacing: 6) {
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

                    V2Card(accentTint: pressureAccentTint) {
                        HStack(spacing: 0) {
                            HStack(spacing: 9) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(pressureColor.opacity(0.15))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(pressureColor.opacity(0.28), lineWidth: 0.5)
                                        }
                                    Image(systemName: "gauge.medium")
                                        .font(Theme.Font.title3.weight(.semibold))
                                        .foregroundStyle(pressureColor)
                                }
                                .frame(width: 30, height: 30)
                                .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(LocalizedStringKey(pressureTitle))
                                        .font(Theme.Font.title3.weight(.bold))
                                        .foregroundStyle(pressureColor)
                                    Text("Memory pressure")
                                        .font(Theme.Font.micro)
                                        .foregroundStyle(Theme.mutedInk)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Memory pressure")
                            .accessibilityValue(Text(LocalizedStringKey(pressureTitle)))

                            Rectangle()
                                .fill(Theme.cardHairline)
                                .frame(width: 0.5)
                                .padding(.vertical, 10)

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
                                        .lynxNumericTransition()
                                    Text(
                                        String(
                                            format: NSLocalizedString("%@ of %@", comment: ""),
                                            Formatters.bytes(usedMemory),
                                            Formatters.bytes(viewModel.snapshot.total)
                                        )
                                    )
                                    .font(Theme.Font.micro)
                                    .foregroundStyle(Theme.secondaryInk)
                                    .lynxNumericTransition()
                                }
                            }
                            .padding(.leading, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Memory usage")
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 66)
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
                        .padding(10)
                        .frame(height: 152)
                    }

                    HStack(spacing: 6) {
                        V2Card(accentTint: swapAlertTint) {
                            ContextColumn(
                                systemName: "arrow.left.arrow.right",
                                label: "Swap",
                                value: Formatters.bytes(viewModel.snapshot.swapUsed),
                                detail: swapDetailText,
                                color: swapAlertTint ?? Theme.memory
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        }
                        V2Card {
                            ContextColumn(
                                systemName: "rectangle.compress.vertical",
                                label: "Compressed",
                                value: Formatters.bytes(viewModel.snapshot.compressed),
                                detail: nil,
                                color: Theme.memory
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        }
                    }
                    .frame(height: 62)

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
                                    LynxSegmentedPill(
                                        options: [ProcessListView.Metric.cpu, .memory],
                                        selection: processMetric,
                                        title: { $0 == .cpu ? "CPU" : "Memory" },
                                        minItemWidth: 42,
                                        itemHeight: 19,
                                        onSelect: { processMetric = $0 }
                                    )
                                    ActivityMonitorShortcutButton(tint: Theme.memory)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            DualMetricProcessTable(
                                processes: processes,
                                visibleRowCount: 3,
                                headerHeight: 16,
                                rowHeight: 24,
                                remediationContextProvider: remediationContextProvider
                            )
                        }
                        .frame(height: 118, alignment: .top)
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
                            VStack(spacing: 6) {
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
                .padding(.vertical, 6)
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

    /// 内存压力非正常时给 Hero 卡叠加对应的语义环境光晕。
    private var pressureAccentTint: Color? {
        switch viewModel.pressure {
        case .warning: return Theme.warning
        case .critical: return Theme.critical
        case .normal: return Theme.memory
        case .unknown: return nil
        }
    }

    /// Swap 占用偏高（>= 2 GB 预警，>= 8 GB 严重）或内存压力升高时高亮提示，直观解释压力来源。
    private var swapAlertTint: Color? {
        let swapBytes = viewModel.snapshot.swapUsed
        if viewModel.pressure == .critical || swapBytes >= 8 * 1_073_741_824 {
            return Theme.critical
        }
        if viewModel.pressure == .warning || swapBytes >= 2 * 1_073_741_824 {
            return Theme.warning
        }
        return nil
    }

    /// 当 Swap 偏高时给出简短状态说明，帮助用户快速理解内存压力原因。
    private var swapDetailText: String? {
        let swapBytes = viewModel.snapshot.swapUsed
        if swapBytes >= 8 * 1_073_741_824 {
            return NSLocalizedString("High swap", comment: "")
        }
        if swapBytes >= 2 * 1_073_741_824 {
            return NSLocalizedString("Elevated", comment: "")
        }
        return nil
    }
}

/// 进程卡片右上角轻量“打开活动监视器”快捷按钮，收敛旧版独立大卡片以聚焦内置进程处置闭环。
private struct ActivityMonitorShortcutButton: View {
    let tint: Color
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            ActivityMonitor.open()
        } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(isHovered ? tint : Theme.secondaryInk)
                .frame(width: 24, height: 24)
                .v2InteractiveSurface()
                .background(isHovered ? Theme.hoverFill : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Theme.selection, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help(NSLocalizedString("Open Activity Monitor", comment: ""))
        .accessibilityLabel("Review memory-heavy apps")
        .accessibilityHint("Opens Activity Monitor")
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
