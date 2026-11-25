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
            VStack(spacing: 4) {
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

                V2Card {
                    if let primary {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "externaldrive.fill")
                            .font(Theme.Font.title)
                                    .foregroundStyle(Theme.disk)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(primary.name)
                                        .font(Theme.Font.body.weight(.semibold))
                                        .lineLimit(1)
                                    HStack(spacing: 4) {
                                        Circle().fill(storageColor).frame(width: 6, height: 6)
                                        Text(LocalizedStringKey(storageState))
                                            .font(Theme.Font.caption.weight(.medium))
                                            .foregroundStyle(storageColor)
                                    }
                                }
                                Spacer()
                                Text(Formatters.percent(primary.usage))
                                    .font(Theme.Font.metricValue.weight(.bold))
                                    .foregroundStyle(Theme.disk)
                                    .monospacedDigit()
                            }
                            ProgressView(value: primary.usage)
                                .tint(Theme.disk)
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
                            }
                            .font(Theme.Font.captionMono)
                            .foregroundStyle(Theme.secondaryInk)
                        }
                        .padding(10)
                        .frame(height: 94)
                    } else {
                        Text("Collecting disk capacity…")
                            .font(Theme.Font.subheadline)
                            .foregroundStyle(Theme.mutedInk)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    }
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
                    .padding(8)
                    .frame(height: 158)
                }

                V2Card {
                    VStack(alignment: .leading, spacing: 8) {
                        IconSectionHeader(
                            systemName: "exclamationmark.triangle.fill",
                            title: "Thresholds",
                            tint: Theme.warning,
                            accessibilityLabel: "Storage thresholds"
                        )
                        ThresholdRow(
                            title: "Attention",
                            detail: "below 15% or 30 GB free",
                            color: Theme.warning,
                            systemName: "exclamationmark.triangle.fill"
                        )
                        Divider().overlay(Theme.divider)
                        ThresholdRow(
                            title: "Critical",
                            detail: "below 5% or 10 GB free",
                            color: Theme.critical,
                            systemName: "exclamationmark.octagon.fill"
                        )
                    }
                    .padding(9)
                    .frame(height: 82)
                }

                V2Card {
                    HStack(spacing: 10) {
                        Image(systemName: "trash.slash")
                            .font(Theme.Font.title2.weight(.semibold))
                            .foregroundStyle(Theme.disk)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Free up space safely")
                                .font(Theme.Font.subheadline.weight(.semibold))
                            Text("Review exact files before moving them to Trash")
                                .font(Theme.Font.micro)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        Spacer()
                        Button("Review Files…", action: openCleanup)
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.disk)
                            .controlSize(.small)
                    }
                    .padding(9)
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
                            VStack(spacing: 8) {
                                ForEach(otherVolumes) { volume in
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
                                            .font(Theme.Font.caption)
                                            .monospacedDigit()
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 38, alignment: .top)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
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
