import SwiftUI

/// Battery 详情的独立只读外设区域。采样生命周期由外部 demand 协调器拥有，View
/// 重建不会创建扫描。来源与观察时间可见；过期/断连/无值只显示状态而非旧百分比。
struct AccessoryPowerSection: View {
    @ObservedObject var viewModel: AccessoryPowerViewModel

    var body: some View {
        V2Card {
            VStack(spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "gamecontroller")
                        .foregroundStyle(Theme.battery)
                        .accessibilityHidden(true)
                    Text("Accessory batteries")
                        .font(Theme.Font.caption.weight(.semibold))
                    Spacer()
                    Text(statusLabel)
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.secondaryInk)
                }

                if viewModel.snapshot.records.isEmpty {
                    Text(emptyDetail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        VStack(spacing: Theme.Spacing.small) {
                            ForEach(viewModel.snapshot.records) { record in
                                AccessoryPowerRow(record: record)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(viewModel.snapshot.records.count) * 72, 156))
                }
            }
            .padding(Theme.Spacing.medium)
        }
    }

    private var statusLabel: String {
        switch viewModel.snapshot.sourceAvailability[.standardBLE] {
        case .permissionDenied: return NSLocalizedString("Bluetooth denied", comment: "")
        case .bluetoothPoweredOff: return NSLocalizedString("Bluetooth off", comment: "")
        case .scanning: return NSLocalizedString("Scanning", comment: "")
        case .optedOut: return NSLocalizedString("BLE off", comment: "")
        default:
            return String(format: NSLocalizedString("%lld devices", comment: ""),
                          viewModel.snapshot.records.count)
        }
    }

    private var emptyDetail: String {
        switch viewModel.snapshot.sourceAvailability[.standardBLE] {
        case .permissionNotDetermined:
            return NSLocalizedString("Waiting for Bluetooth permission.", comment: "")
        case .permissionDenied:
            return NSLocalizedString("Bluetooth permission denied; controllers remain separate.", comment: "")
        case .bluetoothPoweredOff:
            return NSLocalizedString("Bluetooth is off.", comment: "")
        case .scanning:
            return NSLocalizedString("Looking only for standard Battery Service devices…", comment: "")
        case .optedOut:
            return NSLocalizedString("No controller battery. Standard BLE discovery is off.", comment: "")
        case .unsupported:
            return NSLocalizedString("No supported Battery Service was found.", comment: "")
        case .discoveryFailed:
            return NSLocalizedString("Discovery failed", comment: "")
        default:
            return NSLocalizedString("No compatible accessory battery is available.", comment: "")
        }
    }
}

/// 独立行的格式化属性也供聚焦回归检查，确保可见与 AX 的分部状态保持一致。
struct AccessoryPowerRow: View {
    let record: AccessoryPowerRecord

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack {
                Text(record.displayName)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.small)
            }
            .font(Theme.Font.caption.weight(.medium))

            // 多分部使用完整行宽并允许换行，避免把充电状态挤进设备名剩余宽度。
            Text(partsLabel)
                .foregroundStyle(record.availability == .available
                    ? Theme.battery : Theme.secondaryInk)
                .monospacedDigit()
                .font(Theme.Font.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(sourceLabel)
                Spacer(minLength: Theme.Spacing.small)
                if let observedAt = record.observedAt {
                    Text(observedAt, style: .time)
                } else {
                    Text("Not yet observed")
                }
            }
            .font(Theme.Font.micro)
            .foregroundStyle(Theme.secondaryInk)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }

    var partsLabel: String {
        guard record.availability == .available, !record.parts.isEmpty else {
            return availabilityLabel
        }
        return record.parts.map {
            "\(partLabel($0.kind)) \(Formatters.percent($0.level)) · \(chargeLabel($0.chargeState))"
        }.joined(separator: " · ")
    }

    var accessibilityLabel: String {
        let detail = record.availability == .available
            ? record.parts.map {
                "\(partLabel($0.kind)), \(Formatters.percent($0.level)), \(chargeLabel($0.chargeState))"
            }.joined(separator: ", ")
            : availabilityLabel
        let time = record.observedAt?.formatted(date: .numeric, time: .standard)
            ?? NSLocalizedString("Not yet observed", comment: "")
        return "\(record.displayName), \(sourceLabel), \(detail), \(time)"
    }

    private func chargeLabel(_ state: AccessoryChargeState) -> String {
        switch state {
        case .charging: return NSLocalizedString("Charging", comment: "")
        case .full: return NSLocalizedString("Full", comment: "")
        case .discharging: return NSLocalizedString("Discharging", comment: "")
        case .unknown: return NSLocalizedString("Charge state unknown", comment: "")
        }
    }

    private var sourceLabel: String {
        switch record.identity.source {
        case .gameController: return NSLocalizedString("Game Controller", comment: "")
        case .standardBLE: return NSLocalizedString("Standard BLE Battery Service", comment: "")
        }
    }

    private var availabilityLabel: String {
        switch record.availability {
        case .available, .batteryUnavailable:
            return NSLocalizedString("Battery unavailable", comment: "")
        case .stale: return NSLocalizedString("Stale", comment: "")
        case .disconnected: return NSLocalizedString("Disconnected", comment: "")
        case .permissionNotDetermined:
            return NSLocalizedString("Permission not determined", comment: "")
        case .permissionDenied: return NSLocalizedString("Permission denied", comment: "")
        case .bluetoothPoweredOff: return NSLocalizedString("Bluetooth off", comment: "")
        case .unsupported: return NSLocalizedString("Unsupported", comment: "")
        case .discoveryFailed: return NSLocalizedString("Discovery failed", comment: "")
        case .optedOut: return NSLocalizedString("Off", comment: "")
        case .scanning: return NSLocalizedString("Scanning", comment: "")
        }
    }

    private func partLabel(_ part: AccessoryBatteryPartKind) -> String {
        switch part {
        case .main: return NSLocalizedString("Main", comment: "")
        case .left: return NSLocalizedString("Left", comment: "")
        case .right: return NSLocalizedString("Right", comment: "")
        case .case: return NSLocalizedString("Case", comment: "")
        }
    }
}
