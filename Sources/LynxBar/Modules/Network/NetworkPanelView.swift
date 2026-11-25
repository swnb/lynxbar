import SwiftUI

struct NetworkPanelView: View {
    @ObservedObject var viewModel: NetworkViewModel
    @ObservedObject private var settings = Settings.shared
    @State private var interfacesExpanded = false

    private var primary: NetworkProvider.Interface? {
        viewModel.snapshot.primaryInterface
    }

    private var advancedInterfaces: [NetworkProvider.Interface] {
        viewModel.snapshot.interfaces.filter { $0.name != primary?.name }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                HStack {
                    Label("Network", systemImage: "network")
                        .font(Theme.Font.title2.weight(.bold))
                        .foregroundStyle(Theme.networkInput)
                    Spacer()
                    RangePicker(
                        ranges: NetworkViewModel.allowedRanges,
                        selection: viewModel.selectedRange,
                        select: viewModel.selectRange
                    )
                }
                .frame(height: 28)

                HStack(spacing: 8) {
                    V2Card {
                        RateHero(
                            label: "Download",
                            value: Formatters.rate(viewModel.snapshot.downloadBytesPerSecond),
                            systemName: "arrow.down",
                            color: Theme.networkInput
                        )
                    }
                    V2Card {
                        RateHero(
                            label: "Upload",
                            value: Formatters.rate(viewModel.snapshot.uploadBytesPerSecond),
                            systemName: "arrow.up",
                            color: Theme.networkOutput
                        )
                    }
                }

                V2Card {
                    VStack(
                        alignment: .leading,
                        spacing: V2LayoutPolicy.chartHeaderToPlot
                    ) {
                        IconSectionHeader(
                            systemName: "waveform.path.ecg",
                            title: "Throughput",
                            tint: Theme.networkInput,
                            accessibilityLabel: "Network throughput"
                        ) {
                            NetworkSeriesLegend()
                        }
                        NetworkThroughputChart(
                            down: viewModel.downHistoryResult,
                            up: viewModel.upHistoryResult
                        )
                    }
                    .padding(10)
                    .frame(height: 145)
                }

                V2Card {
                    NetworkProcessTrafficCard(
                        usages: displayedProcessTraffic,
                        availability: displayedAttributionAvailability
                    )
                }

                V2Card {
                    SelectedRangeTrafficCard(totals: displayedTransferTotals)
                }

                V2Card {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: primary == nil ? "wifi.slash" : "wifi")
                                .font(Theme.Font.title2.weight(.semibold))
                                .foregroundStyle(primary == nil ? Theme.warning : Theme.networkInput)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(primary.map { "Wi-Fi · \($0.name)" }
                                    ?? NSLocalizedString("No primary interface", comment: ""))
                                    .font(Theme.Font.callout.weight(.semibold))
                                Text(primary == nil ? "Unavailable" : "Connected")
                                    .font(Theme.Font.micro.weight(.medium))
                                    .foregroundStyle(primary == nil ? Theme.warning : Theme.health)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 34)

                        Divider().overlay(Theme.divider)
                        VStack(spacing: 0) {
                            CopyableValueRow(
                                label: "Public IP",
                                value: settings.showPublicIP ? viewModel.snapshot.publicIP : nil,
                                detail: publicIPDetail,
                                minHeight: 27
                            )
                            Divider().overlay(Theme.divider)
                            CopyableValueRow(
                                label: "Private IP",
                                value: primary?.ipv4,
                                minHeight: 27
                            )
                            Divider().overlay(Theme.divider)
                            CopyableValueRow(
                                label: "MAC",
                                value: primary?.macAddress,
                                minHeight: 27
                            )
                        }
                        .padding(.horizontal, 11)
                    }
                }

                V2Card {
                    DisclosureRow(
                        title: "Interfaces",
                        subtitle: String(
                            format: NSLocalizedString("%lld interfaces", comment: ""),
                            viewModel.snapshot.interfaces.count
                        ),
                        systemName: "network",
                        tint: Theme.networkInput,
                        accessibilityLabel: "Advanced interfaces",
                        isExpanded: $interfacesExpanded
                    ) {
                        if advancedInterfaces.isEmpty {
                            Text("No additional interfaces")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.mutedInk)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(advancedInterfaces, id: \.name) { interface in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(interface.name)
                                                .font(Theme.Font.subheadline.weight(.medium))
                                            Text(interface.ipv4 ?? interface.ipv6 ?? "No address")
                                                .font(Theme.Font.microMono)
                                                .foregroundStyle(Theme.mutedInk)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Text(interface.isUp && interface.isRunning ? "Active" : "Inactive")
                                            .font(Theme.Font.micro)
                                            .foregroundStyle(Theme.secondaryInk)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 34, alignment: .top)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var publicIPDetail: String? {
        if !settings.showPublicIP { return "Disabled in Settings" }
        if viewModel.snapshot.publicIPIsCached { return "Cached · refreshing" }
        return nil
    }

    private var displayedProcessTraffic: [NetworkProcessProvider.Usage] {
#if DEBUG
        if let usages = NetworkInsightsVisualQAFixture.networkUsages {
            return usages
        }
#endif
        return viewModel.processTraffic
    }

    private var displayedAttributionAvailability: NetworkProcessAttributionAvailability {
#if DEBUG
        if let availability = NetworkInsightsVisualQAFixture.attributionAvailability {
            return availability
        }
#endif
        return viewModel.processAttributionAvailability
    }

    private var displayedTransferTotals: NetworkRangeTransferTotals {
#if DEBUG
        if let totals = NetworkInsightsVisualQAFixture.transferTotals {
            return NetworkRangeTransferTotals(
                range: viewModel.selectedRange,
                downloadBytes: totals.downloadBytes,
                uploadBytes: totals.uploadBytes,
                downloadCoveredDuration: totals.downloadCoveredDuration,
                uploadCoveredDuration: totals.uploadCoveredDuration,
                status: totals.status
            )
        }
#endif
        return viewModel.selectedTransferTotals
    }
}

private struct NetworkProcessTrafficCard: View {
    let usages: [NetworkProcessProvider.Usage]
    let availability: NetworkProcessAttributionAvailability

    var body: some View {
        VStack(spacing: 0) {
            IconSectionHeader(
                systemName: "list.number",
                title: "Processes",
                tint: Theme.networkInput,
                accessibilityLabel: "Top network processes"
            ) {
                HStack(spacing: 6) {
                    RankingOverflowHint(
                        rowCount: usages.count,
                        visibleRowCount: 3
                    )
                    Label("External traffic", systemImage: "arrow.up.right")
                        .font(Theme.Font.micro.weight(.medium))
                        .foregroundStyle(Theme.mutedInk)
                        .help(
                            NSLocalizedString(
                                "Includes external interfaces and may differ from primary-interface totals",
                                comment: ""
                            )
                        )
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 27)

            HStack(spacing: 6) {
                Text("Process")
                Spacer()
                Text("Download")
                    .frame(width: 65, alignment: .trailing)
                Text("Upload")
                    .frame(width: 65, alignment: .trailing)
            }
            .font(Theme.Font.micro)
            .foregroundStyle(Theme.mutedInk)
            .padding(.horizontal, 10)
            .frame(height: 17)

            Divider().overlay(Theme.divider)

            if availability == .ready, !usages.isEmpty {
                ScrollableProcessRanking(
                    rowCount: usages.count,
                    visibleRowCount: 3,
                    rowHeight: 25
                ) {
                    ForEach(usages) { usage in
                        NetworkProcessTrafficRow(usage: usage)
                        Divider().overlay(Theme.divider)
                    }
                }
            } else {
                Text(emptyStateText)
                    .font(Theme.Font.caption)
                    .foregroundStyle(
                        availability == .unavailable ? Theme.warning : Theme.mutedInk
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(emptyStateText)
            }
        }
        .frame(height: 119, alignment: .top)
    }

    private var emptyStateText: LocalizedStringKey {
        switch availability {
        case .collecting:
            return "Collecting process traffic…"
        case .ready:
            return "No active external process traffic"
        case .unavailable:
            return "Process traffic unavailable"
        }
    }
}

private struct SelectedRangeTrafficCard: View {
    let totals: NetworkRangeTransferTotals

    var body: some View {
        V2InsetCardContent {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(
                        String(
                            format: NSLocalizedString("Traffic in %@", comment: ""),
                            totals.range.rawValue
                        )
                    )
                    .font(Theme.Font.callout.weight(.semibold))
                    Text(coverageText)
                        .font(Theme.Font.micro.weight(.medium))
                        .foregroundStyle(coverageColor)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Label("Primary interface", systemImage: "wifi")
                        .font(Theme.Font.micro.weight(.medium))
                        .foregroundStyle(Theme.mutedInk)
                        .help(
                            NSLocalizedString(
                                "Selected totals use the primary interface only",
                                comment: ""
                            )
                        )
                }
                HStack {
                    TrafficTotal(
                        label: "Downloaded",
                        value: formatted(totals.downloadBytes),
                        systemName: "arrow.down",
                        color: Theme.networkInput
                    )
                    Divider().overlay(Theme.divider)
                    TrafficTotal(
                        label: "Uploaded",
                        value: formatted(totals.uploadBytes),
                        systemName: "arrow.up",
                        color: Theme.networkOutput
                    )
                }
            }
        }
        .frame(minHeight: 67)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                format: NSLocalizedString(
                    "%@ traffic, downloaded %@, uploaded %@, %@",
                    comment: ""
                ),
                totals.range.rawValue,
                formatted(totals.downloadBytes),
                formatted(totals.uploadBytes),
                coverageText
            )
        )
    }

    private func formatted(_ bytes: UInt64?) -> String {
        bytes.map(Formatters.bytes) ?? "—"
    }

    private var coverageText: String {
        switch totals.status {
        case .complete:
            return NSLocalizedString("Recorded selected range", comment: "")
        case .partial:
            return String(
                format: NSLocalizedString("Recorded ↓ %@ · ↑ %@", comment: ""),
                Formatters.compactDuration(totals.downloadCoveredDuration),
                Formatters.compactDuration(totals.uploadCoveredDuration)
            )
        case .collecting:
            return NSLocalizedString("Collecting selected range…", comment: "")
        case .unavailable:
            return NSLocalizedString("Primary interface unavailable", comment: "")
        }
    }

    private var coverageColor: Color {
        switch totals.status {
        case .complete:
            return Theme.health
        case .partial, .collecting:
            return Theme.mutedInk
        case .unavailable:
            return Theme.warning
        }
    }
}

private struct NetworkProcessTrafficRow: View {
    let usage: NetworkProcessProvider.Usage
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            ActivityMonitor.open()
        } label: {
            HStack(spacing: 7) {
                ApplicationProcessIconView(pid: usage.pid, size: 16)
                Text(usage.name)
                    .font(Theme.Font.caption.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 3)
                Text(Formatters.rate(usage.downloadBytesPerSecond))
                    .foregroundStyle(Theme.networkInput)
                    .frame(width: 65, alignment: .trailing)
                Text(Formatters.rate(usage.uploadBytesPerSecond))
                    .foregroundStyle(Theme.networkOutput)
                    .frame(width: 65, alignment: .trailing)
            }
            .font(Theme.Font.microMono)
            .monospacedDigit()
            .padding(.horizontal, 10)
            .frame(height: 25)
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
        .help(NSLocalizedString("Open Activity Monitor", comment: ""))
        .accessibilityLabel(
            String(
                format: NSLocalizedString("%@, download %@, upload %@", comment: ""),
                usage.name,
                Formatters.rate(usage.downloadBytesPerSecond),
                Formatters.rate(usage.uploadBytesPerSecond)
            )
        )
        .accessibilityHint(NSLocalizedString("Opens Activity Monitor", comment: ""))
    }
}

private struct RateHero: View {
    let label: String
    let value: String
    let systemName: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(Theme.Font.callout.weight(.bold))
                    .foregroundStyle(color)
                Text(LocalizedStringKey(label))
                    .font(Theme.Font.caption.weight(.medium))
                    .foregroundStyle(Theme.secondaryInk)
            }
            Text(value)
                .font(Theme.Font.statValue.weight(.bold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 52)
    }
}

private struct TrafficTotal: View {
    let label: String
    let value: String
    let systemName: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemName)
                .font(Theme.Font.callout.weight(.bold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(label))
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.secondaryInk)
                Text(value)
                    .font(Theme.Font.bodyRounded.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
