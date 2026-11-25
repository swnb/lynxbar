import SwiftUI

struct BatteryPanelView: View {
    @ObservedObject var viewModel: BatteryViewModel
    var accessoryPower: AccessoryPowerViewModel? = nil
    @State private var detailsExpanded = false

    var body: some View {
        // 外设列表数量由实际连接决定；保持内置电池卡片尺寸，并让详情可滚动到达。
        ScrollView(.vertical) {
        VStack(spacing: 4) {
            HStack {
                Label("Battery", systemImage: batteryIcon)
                    .font(Theme.Font.title2.weight(.bold))
                    .foregroundStyle(Theme.battery)
                Spacer()
                Label(powerSourceLabel, systemImage: powerSourceIcon)
                    .font(Theme.Font.caption.weight(.medium))
                    .foregroundStyle(Theme.secondaryInk)
            }
            .frame(height: 28)

            V2Card {
                VStack(spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(levelLabel)
                                    .font(
                                        viewModel.snapshot.level == nil
                                            ? Theme.Font.title.weight(.bold)
                                            : Theme.Font.metricValue.weight(.bold)
                                    )
                                    .foregroundStyle(viewModel.snapshot.level == nil
                                        ? Theme.secondaryInk : Theme.battery)
                                    .monospacedDigit()
                                Text(chargeStateLabel)
                                    .font(Theme.Font.subheadline.weight(.semibold))
                                    .foregroundStyle(chargeStateColor)
                            }
                            Text(primaryStatusDetail)
                                .font(Theme.Font.micro)
                                .foregroundStyle(Theme.mutedInk)
                                .lineLimit(1)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(timeLabel)
                                .font(Theme.Font.micro)
                                .foregroundStyle(Theme.mutedInk)
                            Text(remainingTimeLabel)
                                .font(Theme.Font.title3Rounded.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .monospacedDigit()
                        }
                    }

                    ProgressView(value: viewModel.snapshot.level ?? 0)
                        .tint(Theme.battery)
                        .opacity(viewModel.snapshot.level == nil ? 0.25 : 1)
                }
                .padding(.horizontal, 12)
                .frame(height: 118)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Battery status")
            }

            V2Card {
                VStack(spacing: 0) {
                    IconSectionHeader(
                        systemName: "heart.text.square",
                        title: "Power & condition",
                        tint: healthColor,
                        accessibilityLabel: "Battery power and condition"
                    )
                    .padding(.horizontal, 10)
                    .frame(height: 32)

                    HStack {
                        ContextColumn(
                            systemName: healthIcon,
                            label: "Battery health",
                            value: healthLabel,
                            detail: healthDetail,
                            color: healthColor
                        )
                        Divider().overlay(Theme.divider)
                        ContextColumn(
                            systemName: "leaf",
                            label: "Low Power Mode",
                            value: viewModel.snapshot.isLowPowerModeEnabled
                                ? NSLocalizedString("On", comment: "")
                                : NSLocalizedString("Off", comment: ""),
                            detail: lowPowerDetail,
                            color: viewModel.snapshot.isLowPowerModeEnabled
                                ? Theme.warning : Theme.battery
                        )
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 74)
                }
                .frame(height: 106)
            }

            V2Card {
                DisclosureRow(
                    title: "Details",
                    subtitle: "",
                    systemName: "info.circle",
                    tint: Theme.secondaryInk,
                    accessibilityLabel: "Battery details",
                    isExpanded: $detailsExpanded
                ) {
                    VStack(spacing: 0) {
                        BatteryDetailRow(
                            label: "Device",
                            value: viewModel.snapshot.name
                                ?? NSLocalizedString("Unavailable", comment: "")
                        )
                        Divider().overlay(Theme.divider)
                        BatteryDetailRow(
                            label: "Data source",
                            value: NSLocalizedString("macOS power sources", comment: "")
                        )
                    }
                }
            }
            .frame(height: detailsExpanded ? 135 : 42, alignment: .top)

            if let accessoryPower {
                AccessoryPowerSection(viewModel: accessoryPower)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Image(systemName: availabilityIcon)
                    .foregroundStyle(availabilityColor)
                    .accessibilityHidden(true)
                Text(availabilityDetail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.mutedInk)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 60)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        }
    }

    private var levelLabel: String {
        viewModel.snapshot.level
            .map(Formatters.percent) ?? NSLocalizedString("No battery", comment: "")
    }

    private var chargeStateLabel: String {
        switch viewModel.snapshot.chargeState {
        case .charging: return NSLocalizedString("Charging", comment: "")
        case .charged: return NSLocalizedString("Charged", comment: "")
        case .discharging: return NSLocalizedString("Discharging", comment: "")
        case .notCharging: return NSLocalizedString("Not charging", comment: "")
        case .unknown: return NSLocalizedString("Unknown", comment: "")
        }
    }

    private var chargeStateColor: Color {
        switch viewModel.snapshot.chargeState {
        case .charging, .charged: return Theme.health
        case .discharging, .notCharging: return Theme.secondaryInk
        case .unknown: return Theme.mutedInk
        }
    }

    private var primaryStatusDetail: String {
        switch viewModel.snapshot.chargeState {
        case .charging:
            return NSLocalizedString("External power connected", comment: "")
        case .charged:
            return NSLocalizedString("External power connected", comment: "")
        case .discharging:
            return NSLocalizedString("Running on battery", comment: "")
        case .notCharging:
            return NSLocalizedString("External power connected", comment: "")
        case .unknown:
            return viewModel.snapshot.availability == .available
                ? NSLocalizedString("Status unavailable", comment: "")
                : NSLocalizedString("No internal battery", comment: "")
        }
    }

    private var powerSourceLabel: String {
        switch viewModel.snapshot.powerSource {
        case .ac: return NSLocalizedString("AC power", comment: "")
        case .battery: return NSLocalizedString("Battery power", comment: "")
        case .unknown: return NSLocalizedString("Unknown", comment: "")
        }
    }

    private var powerSourceIcon: String {
        switch viewModel.snapshot.powerSource {
        case .ac: return "powerplug"
        case .battery: return "battery.75percent"
        case .unknown: return "questionmark.circle"
        }
    }

    private var batteryIcon: String {
        viewModel.snapshot.chargeState == .charging
            ? "battery.75percent.bolt" : "battery.75percent"
    }

    private var timeLabel: String {
        switch viewModel.snapshot.chargeState {
        case .charging:
            return NSLocalizedString("Until full", comment: "")
        case .discharging:
            return NSLocalizedString("Remaining", comment: "")
        case .charged, .notCharging, .unknown:
            return NSLocalizedString("Time estimate", comment: "")
        }
    }

    private var remainingTimeLabel: String {
        if viewModel.snapshot.chargeState == .charged {
            return NSLocalizedString("Not needed", comment: "")
        }
        return viewModel.snapshot.timeRemaining
            .map(Formatters.duration) ?? NSLocalizedString("Unavailable", comment: "")
    }

    private var healthLabel: String {
        if let condition = viewModel.snapshot.healthCondition {
            return NSLocalizedString(condition, comment: "")
        }
        switch viewModel.snapshot.health {
        case .good: return NSLocalizedString("Good", comment: "")
        case .fair: return NSLocalizedString("Fair", comment: "")
        case .poor: return NSLocalizedString("Poor", comment: "")
        case .unknown: return NSLocalizedString("Unavailable", comment: "")
        }
    }

    private var healthDetail: String? {
        guard viewModel.snapshot.healthCondition == nil else {
            return NSLocalizedString("Service recommended", comment: "")
        }
        switch viewModel.snapshot.health {
        case .good: return NSLocalizedString("No service issue reported", comment: "")
        case .fair: return NSLocalizedString("Capacity may be limited", comment: "")
        case .poor: return NSLocalizedString("Service may be required", comment: "")
        case .unknown: return nil
        }
    }

    private var healthColor: Color {
        if viewModel.snapshot.healthCondition != nil { return Theme.critical }
        switch viewModel.snapshot.health {
        case .good: return Theme.health
        case .fair: return Theme.warning
        case .poor: return Theme.critical
        case .unknown: return Theme.secondaryInk
        }
    }

    private var healthIcon: String {
        switch viewModel.snapshot.health {
        case .good: return "checkmark.circle"
        case .fair: return "exclamationmark.triangle"
        case .poor: return "exclamationmark.octagon"
        case .unknown: return "questionmark.circle"
        }
    }

    private var lowPowerDetail: String? {
        viewModel.snapshot.isLowPowerModeEnabled
            ? NSLocalizedString("Performance is reduced", comment: "")
            : NSLocalizedString("Standard performance", comment: "")
    }

    private var availabilityIcon: String {
        viewModel.snapshot.availability == .available
            ? "checkmark.circle" : "info.circle"
    }

    private var availabilityColor: Color {
        viewModel.snapshot.availability == .available
            ? Theme.health : Theme.secondaryInk
    }

    private var availabilityDetail: String {
        viewModel.snapshot.availability == .available
            ? NSLocalizedString("Battery status uses macOS power-source data.", comment: "")
            : NSLocalizedString("This Mac reports no internal battery.", comment: "")
    }
}

private struct BatteryDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(LocalizedStringKey(label))
                .foregroundStyle(Theme.secondaryInk)
            Spacer()
            Text(value)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .font(Theme.Font.caption)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .accessibilityElement(children: .combine)
    }
}
