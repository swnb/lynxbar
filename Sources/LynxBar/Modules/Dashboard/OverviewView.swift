import SwiftUI

/// Exact vertical layout constants keeping `OverviewView` within the 496pt slot inside the 420×600 panel.
enum OverviewLayoutMetrics {
    static let availableOverviewHeight: CGFloat = 496
    static let cardSpacing: CGFloat = 6
    static let outerVerticalPadding: CGFloat = 6
    static let aiQuotaRowHeight: CGFloat = 36
    static let visibleProcessRowCount: Int = 3

    /// Returns the height of the top system health summary card.
    static func healthCardHeight(aiEnabled: Bool) -> CGFloat {
        aiEnabled ? 120 : 126
    }

    /// Returns the height of the interactive CPU/Memory/Network trend chart card.
    static func trendCardHeight(aiEnabled: Bool) -> CGFloat {
        aiEnabled ? 120 : 141
    }

    /// Returns the height of the attention banner card.
    static func attentionCardHeight(aiEnabled: Bool) -> CGFloat {
        aiEnabled ? 56 : V2LayoutPolicy.overviewAttentionCardHeight
    }

    /// Returns the vertical padding inside the attention banner card.
    static func attentionCardVerticalPadding(aiEnabled: Bool) -> CGFloat {
        aiEnabled ? 6 : V2LayoutPolicy.overviewAttentionCardVerticalPadding
    }

    /// Returns the outer height of the top-processes card.
    static func processCardHeight(aiEnabled: Bool) -> CGFloat {
        aiEnabled ? 126 : 136
    }

    /// Returns the header height inside the top-processes card.
    static func processHeaderHeight(aiEnabled: Bool) -> CGFloat {
        aiEnabled ? 28 : 31
    }

    /// Returns the column-label row height inside the top-processes card.
    static func processColumnHeaderHeight(aiEnabled: Bool) -> CGFloat {
        aiEnabled ? 18 : 19
    }

    /// Returns the total height allocated per row (row frame plus divider) in the process list.
    static func processRowHeight(aiEnabled: Bool) -> CGFloat {
        aiEnabled ? 26 : 28
    }

    /// Returns the clickable frame height for each `CompactProcessRow`.
    static func compactProcessRowFrameHeight(aiEnabled: Bool) -> CGFloat {
        aiEnabled ? 25 : 27
    }

    /// Computes the combined internal content height of the process card to ensure 3 rows never clip.
    static func processCardContentHeight(aiEnabled: Bool) -> CGFloat {
        processHeaderHeight(aiEnabled: aiEnabled)
            + 1
            + processColumnHeaderHeight(aiEnabled: aiEnabled)
            + CGFloat(visibleProcessRowCount) * processRowHeight(aiEnabled: aiEnabled)
    }

    /// Computes the total vertical height consumed by `OverviewView` for a given `aiEnabled` state.
    static func totalHeight(aiEnabled: Bool) -> CGFloat {
        let cardHeights = healthCardHeight(aiEnabled: aiEnabled)
            + (aiEnabled ? aiQuotaRowHeight : 0)
            + trendCardHeight(aiEnabled: aiEnabled)
            + attentionCardHeight(aiEnabled: aiEnabled)
            + processCardHeight(aiEnabled: aiEnabled)
        let spacingCount: CGFloat = aiEnabled ? 4 : 3
        return cardHeights + spacingCount * cardSpacing + 2 * outerVerticalPadding
    }
}

/// Selectable metric series displayed in the Overview trend chart card.
private enum OverviewTrend: String, CaseIterable {
    case cpu = "CPU"
    case memory = "Memory"
    case network = "Network"
}

/// Compact landing view summarizing system health, optional AI quota, recent trends, alerts, and top processes.
struct OverviewView: View {
    @Binding var selection: DashboardSection
    @ObservedObject var cpu: CPUViewModel
    @ObservedObject var memory: MemoryViewModel
    @ObservedObject var disk: DiskViewModel
    @ObservedObject var network: NetworkViewModel
    @ObservedObject var process: ProcessViewModel
    @ObservedObject var aiUsage: AIUsageViewModel
    @ObservedObject private var settings = Settings.shared
    var thermalState: SystemThermalState = .unknown
    @State private var trend: OverviewTrend = .cpu
    @State private var processMetric: ProcessListView.Metric = .cpu

    /// Creates an `OverviewView` with explicit module view models and an optional AI quota view model.
    init(
        selection: Binding<DashboardSection>,
        cpu: CPUViewModel,
        memory: MemoryViewModel,
        disk: DiskViewModel,
        network: NetworkViewModel,
        process: ProcessViewModel,
        aiUsage: AIUsageViewModel? = nil,
        thermalState: SystemThermalState = .unknown
    ) {
        _selection = selection
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.process = process
        self.aiUsage = aiUsage ?? AIUsageViewModel(settings: .shared)
        self.thermalState = thermalState
    }

    /// Reflects whether opt-in AI quota monitoring is enabled and should allocate the 36pt compact row.
    private var aiEnabled: Bool {
        settings.aiUsageEnabled
    }

    var body: some View {
        VStack(spacing: OverviewLayoutMetrics.cardSpacing) {
            healthCard
                .frame(height: OverviewLayoutMetrics.healthCardHeight(aiEnabled: aiEnabled))
            if aiEnabled {
                OverviewAIQuotaRow(aiUsage: aiUsage, selection: $selection)
            }
            trendCard
                .frame(height: OverviewLayoutMetrics.trendCardHeight(aiEnabled: aiEnabled))
            attentionCard
                .frame(height: OverviewLayoutMetrics.attentionCardHeight(aiEnabled: aiEnabled))
            processCard
                .frame(height: OverviewLayoutMetrics.processCardHeight(aiEnabled: aiEnabled))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, OverviewLayoutMetrics.outerVerticalPadding)
    }

    /// Evaluates current CPU, memory, disk, network, and thermal signals into an aggregate health summary.
    private var healthSummary: SystemHealthSummary {
        let primary = disk.snapshot.primaryVolume
        return SystemHealthEvaluator.evaluate(SystemHealthInput(
            cpuHistory: cpu.recentHistory.points,
            memoryPressure: memory.pressure,
            diskFreeBytes: primary?.freeBytes,
            diskTotalBytes: primary?.totalBytes,
            hasPrimaryNetwork: network.snapshot.interfaces.isEmpty
                ? nil
                : network.snapshot.primaryInterface != nil,
            now: Date(),
            thermalState: thermalState
        ))
    }

    /// Summary card pairing the overall system health badge with clickable CPU, Memory, Disk, and Network rows.
    private var healthCard: some View {
        V2Card {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Spacer()
                    HStack(spacing: 7) {
                        Image(systemName: healthIcon)
                            .font(Theme.Font.title.weight(.bold))
                            .foregroundStyle(healthColor)
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(healthTitle))
                            .font(Theme.Font.title2.weight(.bold))
                            .foregroundStyle(healthColor)
                    }
                    Text(LocalizedStringKey(healthSubtitle))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, aiEnabled ? 10 : 12)
                .frame(width: 133, alignment: .leading)

                Rectangle()
                    .fill(Theme.divider)
                    .frame(width: 1)
                    .padding(.vertical, 12)

                VStack(spacing: 0) {
                    HealthMetricButton(
                        title: "CPU",
                        systemName: "cpu",
                        value: Formatters.percent(cpu.snapshot.usage),
                        color: Theme.cpu,
                        isForcedHoveredForQA: visualQAForcedHoverMetric == "cpu",
                        action: { selection = .cpu }
                    )
                    HealthMetricButton(
                        title: "Memory",
                        systemName: "memorychip",
                        value: Formatters.percent(memory.snapshot.usage),
                        color: memory.pressure == .warning || memory.pressure == .critical
                            ? Theme.warning : Theme.memory,
                        isForcedHoveredForQA: visualQAForcedHoverMetric == "memory",
                        action: { selection = .memory }
                    )
                    HealthMetricButton(
                        title: "Disk",
                        systemName: "externaldrive",
                        value: Formatters.percent(disk.snapshot.usage),
                        color: Theme.disk,
                        isForcedHoveredForQA: visualQAForcedHoverMetric == "disk",
                        action: { selection = .disk }
                    )
                    HealthMetricButton(
                        title: "Network",
                        systemName: "network",
                        value: network.snapshot.primaryInterface == nil
                            ? NSLocalizedString("Unavailable", comment: "")
                            : NSLocalizedString("Live", comment: ""),
                        color: Theme.networkInput,
                        isForcedHoveredForQA: visualQAForcedHoverMetric == "network",
                        action: { selection = .network }
                    )
                }
                .padding(.horizontal, 7)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// 原生验收宿主可固定单行 hover，避免自动化截图工具的拖拽手势误触导航。
    private var visualQAForcedHoverMetric: String? {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--visual-qa-hover") else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        return arguments[next].lowercased()
#else
        return nil
#endif
    }

    /// Card displaying the selectable recent history chart for CPU, Memory, or Network throughput.
    private var trendCard: some View {
        V2Card {
            VStack(spacing: V2LayoutPolicy.chartHeaderToPlot) {
                IconSectionHeader(
                    systemName: trendIcon,
                    title: trend.rawValue,
                    tint: trendColor,
                    accessibilityLabel: trendAccessibilityLabel
                ) {
                    HStack(spacing: 8) {
                        if trend == .network {
                            NetworkSeriesLegend()
                        }
                        OverviewTrendPicker(selection: $trend)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)

                Group {
                    switch trend {
                    case .cpu:
                        PercentHistoryChart(result: cpu.recentHistory, color: Theme.cpu)
                    case .memory:
                        PercentHistoryChart(result: memory.recentHistory, color: Theme.memory)
                    case .network:
                        NetworkThroughputChart(
                            down: network.downRecentHistory,
                            up: network.upRecentHistory
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
        }
    }

    /// Card highlighting the highest-priority active health issue with a direct jump to its detail tab.
    private var attentionCard: some View {
        V2Card {
            Group {
                if let issue = healthSummary.issues.first {
                    HStack(spacing: 9) {
                        Image(systemName: issue.severity == .critical
                            ? "exclamationmark.octagon.fill"
                            : "exclamationmark.triangle.fill")
                            .font(Theme.Font.title3)
                            .foregroundStyle(issue.severity == .critical ? Theme.critical : Theme.warning)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(issueTitle(issue)))
                                .font(Theme.Font.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(issueBody(issue))
                                .font(Theme.Font.micro)
                                .foregroundStyle(Theme.mutedInk)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Button("Review") {
                            selection = destination(for: issue)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(issue.severity == .critical ? Theme.critical : Theme.warning)
                        .accessibilityHint(issueBody(issue))
                    }
                } else {
                    HStack(spacing: 9) {
                        Image(systemName: healthSummary.severity == .collecting
                            ? "clock"
                            : "checkmark.circle.fill")
                            .foregroundStyle(healthSummary.severity == .collecting
                                ? Theme.secondaryInk : Theme.health)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(healthSummary.severity == .collecting
                                ? "Collecting health signals"
                                : "No action needed")
                                .font(Theme.Font.subheadline.weight(.semibold))
                            Text(healthSummary.severity == .collecting
                                ? "Unknown signals stay visible until measured."
                                : "All measured thresholds are below attention.")
                                .font(Theme.Font.micro)
                                .foregroundStyle(Theme.mutedInk)
                        }
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, V2LayoutPolicy.overviewAttentionCardHorizontalPadding)
            .padding(.vertical, OverviewLayoutMetrics.attentionCardVerticalPadding(aiEnabled: aiEnabled))
            // `V2Card` 的背景跟随内部内容尺寸；必须在卡片内部填满固定槽位，
            // 否则外层 61pt frame 只会在一条文字高度的窄背景外增加透明空间。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// Card listing top processes sorted by CPU or memory with remediation sheet support.
    private var processCard: some View {
        let rows = displayedProcessRows
        return V2Card {
            VStack(spacing: 0) {
                IconSectionHeader(
                    systemName: "list.number",
                    title: "Processes",
                    tint: processMetric == .cpu ? Theme.cpu : Theme.memory,
                    accessibilityLabel: "Top processes"
                ) {
                    HStack(spacing: 6) {
                        RankingOverflowHint(
                            rowCount: rows.count,
                            visibleRowCount: OverviewLayoutMetrics.visibleProcessRowCount
                        )
                        Picker("Sort processes", selection: $processMetric) {
                            Text("CPU").tag(ProcessListView.Metric.cpu)
                            Text("Memory").tag(ProcessListView.Metric.memory)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 112)
                        .controlSize(aiEnabled ? .mini : .small)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: OverviewLayoutMetrics.processHeaderHeight(aiEnabled: aiEnabled))

                Divider().overlay(Theme.divider)
                HStack {
                    Text("Process")
                    Spacer()
                    Text("CPU").frame(width: 54, alignment: .trailing)
                    Text("Memory").frame(width: 64, alignment: .trailing)
                }
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.mutedInk)
                .padding(.horizontal, 10)
                .frame(height: OverviewLayoutMetrics.processColumnHeaderHeight(aiEnabled: aiEnabled))

                if rows.isEmpty {
                    Text("Collecting process samples…")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollableProcessRanking(
                        rowCount: rows.count,
                        visibleRowCount: OverviewLayoutMetrics.visibleProcessRowCount,
                        rowHeight: OverviewLayoutMetrics.processRowHeight(aiEnabled: aiEnabled)
                    ) {
                        ForEach(rows) { item in
                            CompactProcessRow(
                                process: item,
                                rowHeight: OverviewLayoutMetrics.compactProcessRowFrameHeight(aiEnabled: aiEnabled),
                                contextProvider: {
                                    ProcessRemediationContext.current(
                                        cpuHistory: cpu.recentHistory.points,
                                        memoryPressure: memory.pressure,
                                        swapUsedBytes: memory.snapshot.swapUsed
                                    )
                                }
                            )
                            Divider().overlay(Theme.divider)
                        }
                    }
                }
            }
        }
    }

    /// Returns top processes sorted by the currently selected metric, or QA fixture rows in debug visual QA mode.
    private var displayedProcessRows: [DisplayProcess] {
#if DEBUG
        if let rows = NetworkInsightsVisualQAFixture.processRows {
            return processMetric == .cpu
                ? rows
                : rows.sorted { $0.memoryBytes > $1.memoryBytes }
        }
#endif
        return processMetric == .cpu ? process.byCpu : process.byMemory
    }

    /// SF Symbol name for the currently selected trend metric.
    private var trendIcon: String {
        switch trend {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "network"
        }
    }

    /// Accent color for the currently selected trend metric.
    private var trendColor: Color {
        switch trend {
        case .cpu: return Theme.cpu
        case .memory: return Theme.memory
        case .network: return Theme.networkInput
        }
    }

    /// Accessibility label describing the active trend chart section.
    private var trendAccessibilityLabel: String {
        switch trend {
        case .cpu: return "CPU history"
        case .memory: return "Memory history"
        case .network: return "Network history"
        }
    }

    /// SF Symbol name corresponding to the aggregate health severity.
    private var healthIcon: String {
        switch healthSummary.severity {
        case .collecting: return "clock.fill"
        case .healthy: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    /// Semantic tint color corresponding to the aggregate health severity.
    private var healthColor: Color {
        switch healthSummary.severity {
        case .collecting: return Theme.secondaryInk
        case .healthy: return Theme.health
        case .attention: return Theme.warning
        case .critical: return Theme.critical
        }
    }

    /// Localization key for the aggregate health severity title.
    private var healthTitle: String {
        switch healthSummary.severity {
        case .collecting: return "Collecting"
        case .healthy: return "Healthy"
        case .attention: return "Attention"
        case .critical: return "Critical"
        }
    }

    /// Localized subtitle summarizing signal readiness or active issue count.
    private var healthSubtitle: String {
        if healthSummary.severity == .collecting { return "Waiting for required signals" }
        if healthSummary.issues.isEmpty { return "No thresholds exceeded" }
        return String(
            format: NSLocalizedString("%lld issues need review", comment: ""),
            healthSummary.issues.count
        )
    }

    /// Returns the localization key for an active `HealthIssue` headline.
    private func issueTitle(_ issue: HealthIssue) -> String {
        switch issue.kind {
        case .sustainedCPU: return "CPU usage is sustained"
        case .criticalCPU: return "CPU usage is critical"
        case .memoryPressureWarning: return "Memory pressure is elevated"
        case .memoryPressureCritical: return "Memory pressure is critical"
        case .lowDisk: return "Storage is running low"
        case .criticalDisk: return "Storage is critically low"
        case .networkUnavailable: return "Primary network is unavailable"
        case .thermalFair: return "Thermal state is elevated"
        case .thermalSerious: return "Thermal state is serious"
        case .thermalCritical: return "Thermal state is critical"
        }
    }

    /// Formats the localized explanatory detail text for an active `HealthIssue`.
    private func issueBody(_ issue: HealthIssue) -> String {
        switch issue.kind {
        case .sustainedCPU, .criticalCPU:
            return String(
                format: NSLocalizedString("%@ average for at least 30 seconds.", comment: ""),
                Formatters.percent(issue.measuredValue ?? 0)
            )
        case .memoryPressureWarning:
            return NSLocalizedString("macOS reports warning pressure. Review memory-heavy apps.", comment: "")
        case .memoryPressureCritical:
            return NSLocalizedString("macOS reports critical pressure. Free memory now.", comment: "")
        case .lowDisk, .criticalDisk:
            return String(
                format: NSLocalizedString("%@ free on the primary volume.", comment: ""),
                Formatters.bytes(UInt64(max(0, issue.measuredValue ?? 0)))
            )
        case .networkUnavailable:
            return NSLocalizedString("No active physical primary interface was found.", comment: "")
        case .thermalFair, .thermalSerious, .thermalCritical:
            return NSLocalizedString("macOS reports thermal pressure. Reduce sustained work; exact temperature is unavailable.", comment: "")
        }
    }

    /// Maps a `HealthIssue` to the dashboard tab where the user can inspect it.
    private func destination(for issue: HealthIssue) -> DashboardSection {
        switch issue.kind {
        case .sustainedCPU, .criticalCPU: return .cpu
        case .memoryPressureWarning, .memoryPressureCritical: return .memory
        case .lowDisk, .criticalDisk: return .disk
        case .networkUnavailable: return .network
        case .thermalFair, .thermalSerious, .thermalCritical: return .cpu
        }
    }
}

/// Interactive metric row inside the Overview health card that navigates to a module panel.
private struct HealthMetricButton: View {
    let title: String
    let systemName: String
    let value: String
    let color: Color
    let isForcedHoveredForQA: Bool
    let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemName)
                    .font(Theme.Font.callout.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(LocalizedStringKey(title))
                    .font(Theme.Font.caption.weight(.semibold))
                Spacer()
                Text(value)
                    .font(Theme.Font.subheadlineRounded.weight(.semibold))
                    .foregroundStyle(color)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(Theme.Font.micro.weight(.semibold))
                    .foregroundStyle(Theme.mutedInk)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .v2InteractiveSurface()
            .background(isHovered || isForcedHoveredForQA ? Theme.hoverFill : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Theme.selection, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityValue(value)
    }
}

/// Segmented-style trend switcher for the Overview history chart card.
private struct OverviewTrendPicker: View {
    @Binding var selection: OverviewTrend

    var body: some View {
        HStack(spacing: 1) {
            ForEach(OverviewTrend.allCases, id: \.self) { trend in
                Button {
                    selection = trend
                } label: {
                    Text(LocalizedStringKey(trend.rawValue))
                        .font(Theme.Font.micro.weight(.medium))
                        .foregroundStyle(selection == trend ? Theme.ink : Theme.secondaryInk)
                        .frame(minWidth: 43, minHeight: 24)
                        .v2InteractiveSurface()
                        .background(selection == trend ? Theme.selectedFill : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == trend ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.raisedStrong)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// Compact process list row displaying CPU and memory usage and opening the remediation sheet on tap.
private struct CompactProcessRow: View {
    let process: DisplayProcess
    var rowHeight: CGFloat = 27
    let contextProvider: @MainActor () -> ProcessRemediationContext
    @State private var selectedProcess: DisplayProcess?
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            selectedProcess = process
        } label: {
            HStack(spacing: 7) {
                ProcessIconView(process: process, size: 17)
                Text(process.name)
                    .font(Theme.Font.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(ProcessRowFormatter.cpuText(for: process))
                    .frame(width: 54, alignment: .trailing)
                Text(Formatters.bytes(process.memoryBytes))
                    .frame(width: 64, alignment: .trailing)
            }
            .font(Theme.Font.micro)
            .foregroundStyle(Theme.secondaryInk)
            .monospacedDigit()
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .v2InteractiveSurface()
            .background(isHovered ? Theme.hoverFill : Color.clear)
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Theme.selection, lineWidth: 2)
                        .padding(.horizontal, 2)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityLabel(ProcessRowFormatter.accessibilityLabel(for: process))
        .accessibilityHint("Review application evidence and safe actions")
        .sheet(item: $selectedProcess) { process in
            ProcessRemediationSheet(process: process, contextProvider: contextProvider)
        }
    }
}
