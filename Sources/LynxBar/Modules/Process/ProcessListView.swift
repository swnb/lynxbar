import SwiftUI
import AppKit

/// Top 进程列表，可按 CPU 或内存展示对应数值列。
struct ProcessListView: View {
    let processes: [DisplayProcess]
    var value: Metric
    var limit: Int?
    var remediationContextProvider: @MainActor () -> ProcessRemediationContext = { .inspectionOnly }
    @State private var selectedProcess: DisplayProcess?

    enum Metric: String, CaseIterable {
        case cpu = "CPU"
        case memory = "Memory"
    }

    var body: some View {
        ScrollableProcessRanking(
            rowCount: processes.count,
            visibleRowCount: limit ?? max(1, processes.count),
            rowHeight: 31
        ) {
            ForEach(processes) { process in
                ProcessRow(process: process, metric: value, action: { selectedProcess = process })
                Divider()
            }
        }
        .sheet(item: $selectedProcess) { process in
            ProcessRemediationSheet(process: process, contextProvider: remediationContextProvider)
        }
    }
}

/// 排行卡片共用的固定高度滚动区。调用方把标题、列头和排序控件放在外部，
/// 因而只有数据行滚动；`rowCount` 只控制溢出语义，不裁剪传入的完整 Top N。
struct ScrollableProcessRanking<Rows: View>: View {
    let rowCount: Int
    let visibleRowCount: Int
    let rowHeight: CGFloat
    private let rows: Rows

    init(
        rowCount: Int,
        visibleRowCount: Int = 3,
        rowHeight: CGFloat,
        @ViewBuilder rows: () -> Rows
    ) {
        self.rowCount = max(0, rowCount)
        self.visibleRowCount = max(1, visibleRowCount)
        self.rowHeight = max(1, rowHeight)
        self.rows = rows()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: hasOverflow) {
            LazyVStack(spacing: 0) {
                rows
            }
        }
        .frame(height: CGFloat(visibleRowCount) * rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            String(
                format: NSLocalizedString("%lld ranked processes", comment: ""),
                rowCount
            )
        )
        .accessibilityHint(
            hasOverflow
                ? NSLocalizedString("Scroll to view all ranked processes", comment: "")
                : ""
        )
    }

    private var hasOverflow: Bool {
        rowCount > visibleRowCount
    }
}

/// 小型溢出提示与系统滚动条共同说明“当前只露出三行，但完整 Top N 可达”。
struct RankingOverflowHint: View {
    let rowCount: Int
    let visibleRowCount: Int

    var body: some View {
        if rowCount > visibleRowCount {
            Label(
                String(
                    format: NSLocalizedString("%lld rows · scroll", comment: ""),
                    rowCount
                ),
                systemImage: "arrow.up.and.down"
            )
            .font(Theme.Font.micro.weight(.medium))
            .foregroundStyle(Theme.mutedInk)
            .labelStyle(.titleAndIcon)
            .help(NSLocalizedString("Scroll to view all ranked processes", comment: ""))
            .accessibilityLabel(
                String(
                    format: NSLocalizedString(
                        "%lld ranked processes, scroll to view all",
                        comment: ""
                    ),
                    rowCount
                )
            )
        }
    }
}

/// V2 详情页同时保留 CPU 与内存两列；排序只改变顺序，不隐藏另一项决策信息。
struct DualMetricProcessTable: View {
    let processes: [DisplayProcess]
    var visibleRowCount = 5
    var headerHeight: CGFloat = 22
    var rowHeight: CGFloat = 29
    var remediationContextProvider: @MainActor () -> ProcessRemediationContext = { .inspectionOnly }
    @State private var selectedProcess: DisplayProcess?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Process")
                Spacer()
                Text("CPU").frame(width: 58, alignment: .trailing)
                Text("Memory").frame(width: 68, alignment: .trailing)
            }
            .font(Theme.Font.micro)
            .foregroundStyle(Theme.mutedInk)
            .padding(.horizontal, 10)
            .frame(height: headerHeight)

            Divider().overlay(Theme.divider)

            if processes.isEmpty {
                Text("Collecting process samples…")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.mutedInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollableProcessRanking(
                    rowCount: processes.count,
                    visibleRowCount: visibleRowCount,
                    rowHeight: rowHeight
                ) {
                    ForEach(processes) { process in
                        DualMetricProcessRow(process: process, rowHeight: rowHeight, action: { selectedProcess = process })
                        Divider().overlay(Theme.divider)
                    }
                }
            }
        }
        .sheet(item: $selectedProcess) { process in
            ProcessRemediationSheet(process: process, contextProvider: remediationContextProvider)
        }
    }
}

private struct DualMetricProcessRow: View {
    let process: DisplayProcess
    let rowHeight: CGFloat
    let action: () -> Void
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                ProcessIconView(process: process, size: 18)
                Text(process.name)
                    .font(Theme.Font.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(ProcessRowFormatter.cpuText(for: process))
                    .frame(width: 58, alignment: .trailing)
                Text(Formatters.bytes(process.memoryBytes))
                    .frame(width: 68, alignment: .trailing)
            }
            .font(Theme.Font.caption)
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
        .accessibilityHint("Opens application details")
    }
}

struct ProcessRow: View {
    let process: DisplayProcess
    let metric: ProcessListView.Metric
    var action: () -> Void = { ActivityMonitor.open() }
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 9) {
                ProcessIconView(process: process)

                Text(process.name)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(ProcessRowFormatter.displayValue(for: process, metric: metric))
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.secondaryInk)
                    .monospacedDigit()
                    .frame(minWidth: 62, alignment: .trailing)

                Image(systemName: "ellipsis")
                    .font(Theme.Font.subheadline.weight(.medium))
                    .foregroundStyle(Theme.mutedInk)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(height: 31)
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
        .help(NSLocalizedString("Open application details", comment: ""))
        .accessibilityLabel(ProcessRowFormatter.accessibilityLabel(for: process, metric: metric))
        .accessibilityHint(NSLocalizedString("Opens application details", comment: ""))
    }
}

struct ProcessIconView: View {
    let process: DisplayProcess
    var size: CGFloat = 20

    var body: some View {
        ApplicationProcessIconView(pid: process.pid, identity: process.identity, size: size)
    }
}

/// CPU、内存和网络排行共享同一套真实应用图标解析，避免网络页为了复用图标
/// 伪造一个 CPU / memory 为零的 `DisplayProcess`。
struct ApplicationProcessIconView: View {
    let pid: Int32
    /// 调用方已知完整身份（pid + start time）时传入，图标缓存按身份查询，
    /// 天然免疫 pid 复用；Network 面板的数据来自 nettop，只有裸 pid，传 nil
    /// 时退化到 `ProcessIconCache.icon(forPID:)`，每次调用重新解析 identity。
    var identity: ProcessProvider.ProcessIdentity? = nil
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let icon = applicationIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "terminal")
                    .resizable()
                    .scaledToFit()
                    .padding(3)
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// GUI 进程优先取所属 app bundle 的真实图标；命令行进程回退到系统符号。
    /// 图标经 `ProcessIconCache` 按身份缓存，避免每次 body 求值都重新读盘。
    private var applicationIcon: NSImage? {
        if let identity {
            return ProcessIconCache.shared.icon(for: identity)
        }
        return ProcessIconCache.shared.icon(forPID: pid)
    }
}

@MainActor
enum ActivityMonitor {
    static func open() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
