import SwiftUI

struct DiskPanelView: View {
    @ObservedObject var viewModel: DiskViewModel
    @ObservedObject private var settings = Settings.shared
    @State private var volumesExpanded = false
    private let openCleanup: () -> Void

    init(
        viewModel: DiskViewModel,
        openCleanup: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.openCleanup = openCleanup
    }

    private var primary: DiskVolume? { viewModel.snapshot.primaryVolume }
    private var otherVolumes: [DiskVolume] {
        viewModel.snapshot.volumes.filter { $0.id != primary?.id }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                HStack {
                    Label("Disk", systemImage: "externaldrive")
                        .font(Theme.Font.title2.weight(.bold))
                        .foregroundStyle(Theme.disk)
                    Spacer()
                    CompactRefreshButton(
                        isRefreshing: viewModel.isRefreshing,
                        hasError: viewModel.lastSampleFailed,
                        tint: Theme.disk,
                        accessibilityLabel: NSLocalizedString(
                            "Refresh disk capacity",
                            comment: ""
                        ),
                        helpText: refreshHelp,
                        action: viewModel.refreshNow
                    )
                    RangePicker(
                        ranges: DiskViewModel.allowedRanges,
                        selection: viewModel.selectedRange,
                        select: viewModel.selectRange
                    )
                }
                .frame(height: 28)

                V2Card(accentTint: storageColor) {
                    if let primary {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 9) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(storageTint.opacity(0.14))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(storageTint.opacity(0.26), lineWidth: 0.5)
                                        }
                                    Image(systemName: "externaldrive.fill")
                                        .font(Theme.Font.title3.weight(.semibold))
                                        .foregroundStyle(storageTint)
                                }
                                .frame(width: 32, height: 32)
                                .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(primary.name)
                                        .font(Theme.Font.body.weight(.semibold))
                                        .lineLimit(1)
                                    HStack(spacing: 5) {
                                        Circle().fill(storageColor).frame(width: 6, height: 6)
                                        Text(LocalizedStringKey(storageState))
                                            .font(Theme.Font.caption.weight(.medium))
                                            .foregroundStyle(storageColor)
                                        Image(systemName: "info.circle")
                                            .font(Theme.Font.micro.weight(.medium))
                                            .foregroundStyle(Theme.mutedInk)
                                            .help(thresholdTooltip)
                                            .accessibilityLabel("Storage thresholds")
                                            .accessibilityValue(thresholdTooltip)
                                    }
                                }
                                Spacer()
                                Text(Formatters.percent(primary.usage))
                                    .font(Theme.Font.metricValue.weight(.bold))
                                    .foregroundStyle(storageTint)
                                    .monospacedDigit()
                                    .lynxNumericTransition()
                            }

                            LynxProgressBar(
                                value: primary.usage,
                                tint: storageTint,
                                height: 7
                            )

                            HStack {
                                Text(
                                    String(
                                        format: NSLocalizedString("%@ of %@", comment: ""),
                                        Formatters.bytes(primary.usedBytes),
                                        Formatters.bytes(primary.totalBytes)
                                    )
                                )
                                Spacer()
                                Text(
                                    String(
                                        format: NSLocalizedString("%@ free", comment: ""),
                                        Formatters.bytes(primary.freeBytes)
                                    )
                                )
                                .foregroundStyle(isStorageConstrained ? storageColor : Theme.secondaryInk)
                                .fontWeight(isStorageConstrained ? .semibold : .regular)
                            }
                            .font(Theme.Font.captionMono)
                            .foregroundStyle(Theme.secondaryInk)
                            .lynxNumericTransition()
                        }
                        .padding(11)
                    } else {
                        Text("Collecting disk capacity…")
                            .font(Theme.Font.subheadline)
                            .foregroundStyle(Theme.mutedInk)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    }
                }

                // 将安全清理行动卡片置顶到主卷容量卡正下方，用户在存储偏低时无需跳过科普卡片即可一步清理。
                V2Card(accentTint: isStorageConstrained ? storageColor : nil) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill((isStorageConstrained ? storageColor : Theme.disk).opacity(0.14))
                            Image(systemName: "trash.slash")
                                .font(Theme.Font.callout.weight(.semibold))
                                .foregroundStyle(isStorageConstrained ? storageColor : Theme.disk)
                        }
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Free up space safely")
                                .font(Theme.Font.subheadline.weight(.semibold))
                            Text("Review exact files before moving them to Trash")
                                .font(Theme.Font.micro)
                                .foregroundStyle(Theme.secondaryInk)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        LynxActionPillButton(
                            title: "Review Files…",
                            tint: isStorageConstrained ? storageColor : Theme.disk,
                            isProminent: isStorageConstrained,
                            action: openCleanup
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                }

                V2Card {
                    VStack(
                        alignment: .leading,
                        spacing: V2LayoutPolicy.chartHeaderToPlot
                    ) {
                        IconSectionHeader(
                            systemName: "chart.xyaxis.line",
                            title: "Capacity trend",
                            tint: Theme.disk,
                            accessibilityLabel: "Disk capacity used"
                        ) {
                            HStack(spacing: 7) {
                                if let status = visibleHistoryStatus(viewModel.historyResult) {
                                    Text(status)
                                        .font(Theme.Font.micro)
                                        .foregroundStyle(Theme.mutedInk)
                                }
                                Image(systemName: "clock")
                                    .font(Theme.Font.caption.weight(.medium))
                                    .foregroundStyle(Theme.mutedInk)
                                    .help(settings.diskCapacityCadence.scheduleLabel)
                                    .accessibilityLabel("Sampling schedule")
                                    .accessibilityValue(
                                        Text(LocalizedStringKey(
                                            settings.diskCapacityCadence.scheduleLabel
                                        ))
                                    )
                                Image(systemName: "info.circle")
                                    .font(Theme.Font.caption.weight(.medium))
                                    .foregroundStyle(Theme.mutedInk)
                                    .help(NSLocalizedString(
                                        "Capacity trend · not disk I/O",
                                        comment: ""
                                    ))
                                    .accessibilityLabel("Capacity trend, not disk I/O")
                            }
                        }
                        PercentHistoryChart(
                            result: viewModel.historyResult,
                            color: Theme.disk,
                            // 慢 cadence 使用有界的 forward-only 展示段，不能让
                            // 10 分钟到 1 天的采样周期等比例变成 UI 延迟。
                            cadenceHint: settings.diskCapacityCadence.rawValue
                        )
                    }
                    .padding(10)
                    .frame(height: 172)
                }

                V2Card {
                    DisclosureRow(
                        title: "Volumes",
                        subtitle: String(
                            format: NSLocalizedString("%lld mounted volumes", comment: ""),
                            viewModel.snapshot.volumes.count
                        ),
                        systemName: "externaldrive",
                        tint: Theme.disk,
                        accessibilityLabel: "Advanced volumes",
                        isExpanded: $volumesExpanded
                    ) {
                        if otherVolumes.isEmpty {
                            Text("No additional volumes")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.mutedInk)
                        } else {
                            VStack(spacing: 9) {
                                ForEach(otherVolumes) { volume in
                                    VStack(spacing: 4) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(volume.name)
                                                    .font(Theme.Font.subheadline.weight(.medium))
                                                Text("\(volume.fileSystem) · \(volume.mountPoint)")
                                                    .font(Theme.Font.micro)
                                                    .foregroundStyle(Theme.mutedInk)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Text(Formatters.percent(volume.usage))
                                                .font(Theme.Font.caption.weight(.medium))
                                                .monospacedDigit()
                                        }
                                        LynxProgressBar(value: volume.usage, tint: Theme.disk, height: 4)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 42, alignment: .top)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

    private var isStorageConstrained: Bool {
        storageState == "Storage critical" || storageState == "Storage needs attention"
    }

    private var storageTint: Color {
        switch storageState {
        case "Storage critical": return Theme.critical
        case "Storage needs attention": return Theme.warning
        default: return Theme.disk
        }
    }

    private var thresholdTooltip: String {
        let attention = NSLocalizedString("below 15% or 30 GB free", comment: "")
        let critical = NSLocalizedString("below 5% or 10 GB free", comment: "")
        return "\(NSLocalizedString("Attention", comment: "")): \(attention) · \(NSLocalizedString("Critical", comment: "")): \(critical)"
    }

    private var storageState: String {
        guard let primary else { return "Collecting" }
        let fraction = primary.totalBytes > 0
            ? Double(primary.freeBytes) / Double(primary.totalBytes)
            : 0
        if fraction <= 0.05 || primary.freeBytes <= SystemHealthEvaluator.diskCriticalBytes {
            return "Storage critical"
        }
        if fraction <= 0.15 || primary.freeBytes <= SystemHealthEvaluator.diskAttentionBytes {
            return "Storage needs attention"
        }
        return "Storage healthy"
    }

    private var storageColor: Color {
        switch storageState {
        case "Storage critical": return Theme.critical
        case "Storage needs attention": return Theme.warning
        default: return Theme.health
        }
    }

    private var refreshHelp: String {
        if viewModel.isRefreshing {
            return NSLocalizedString("Refreshing disk capacity…", comment: "")
        }
        if viewModel.lastSampleFailed {
            return NSLocalizedString(
                "Refresh failed · showing the last successful sample",
                comment: ""
            )
        }
        if let lastSuccessfulSampleAt = viewModel.lastSuccessfulSampleAt {
            return String(
                format: NSLocalizedString("Refresh now · last updated %@", comment: ""),
                Formatters.clockTime(lastSuccessfulSampleAt)
            )
        }
        return NSLocalizedString("Refresh disk capacity", comment: "")
    }
}

private struct ThresholdRow: View {
    let title: String
    let detail: String
    let color: Color
    let systemName: String

    var body: some View {
        HStack {
            Image(systemName: systemName)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title))
                .font(Theme.Font.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Spacer()
            Text(LocalizedStringKey(detail))
                .font(Theme.Font.captionMono)
                .foregroundStyle(Theme.secondaryInk)
        }
    }
}
