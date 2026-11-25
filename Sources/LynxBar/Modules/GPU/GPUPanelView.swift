import SwiftUI

struct GPUPanelView: View {
    @ObservedObject var viewModel: GPUViewModel
    var thermalSnapshot: ThermalSnapshot? = nil

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Label("GPU", systemImage: "square.stack.3d.up")
                    .font(Theme.Font.title2.weight(.bold))
                    .foregroundStyle(Theme.gpu)
                Spacer()
                Text("Last 60 seconds")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.mutedInk)
            }
            .frame(height: 28)

            V2Card {
                HStack(alignment: .firstTextBaseline) {
                    Text(primaryValue)
                        .font(
                            viewModel.snapshot.usage == nil
                                ? Theme.Font.title.weight(.bold)
                                : Theme.Font.metricValue.weight(.bold)
                        )
                        .foregroundStyle(viewModel.snapshot.usage == nil
                            ? Theme.secondaryInk : Theme.gpu)
                        .monospacedDigit()
                    Text(activityStateLabel)
                        .font(Theme.Font.subheadline.weight(.semibold))
                        .foregroundStyle(activityStateColor)
                    Spacer()
                    Text(deviceCountLabel)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.secondaryInk)
                }
                .padding(.horizontal, 10)
                .frame(height: 64)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("GPU activity")
            }

            V2Card {
                VStack(alignment: .leading, spacing: V2LayoutPolicy.chartHeaderToPlot) {
                    IconSectionHeader(
                        systemName: "chart.xyaxis.line",
                        title: "Usage trend",
                        tint: Theme.gpu,
                        accessibilityLabel: "GPU utilization history"
                    ) {
                        if let status = visibleHistoryStatus(viewModel.historyResult) {
                            Text(status)
                                .font(Theme.Font.micro)
                                .foregroundStyle(Theme.mutedInk)
                        }
                    }
                    PercentHistoryChart(
                        result: viewModel.historyResult,
                        color: Theme.gpu
                    )
                }
                .padding(8)
                .frame(height: 170)
            }

            V2Card {
                VStack(spacing: 0) {
                    IconSectionHeader(
                        systemName: "gauge.medium",
                        title: "Activity details",
                        tint: Theme.gpu,
                        accessibilityLabel: "GPU activity details"
                    )
                    .padding(.horizontal, 9)
                    .frame(height: 28)

                    HStack {
                        ContextColumn(
                            systemName: "paintbrush.pointed",
                            label: "Renderer",
                            value: percentOrUnavailable(viewModel.snapshot.rendererUsage),
                            detail: nil,
                            color: Theme.gpu
                        )
                        Divider().overlay(Theme.divider)
                        ContextColumn(
                            systemName: "square.3.layers.3d",
                            label: "Tiler",
                            value: percentOrUnavailable(viewModel.snapshot.tilerUsage),
                            detail: nil,
                            color: Theme.gpu
                        )
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 56)

                    Divider().overlay(Theme.divider)

                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(Theme.gpu)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(primaryDevice?.name ?? NSLocalizedString("No GPU detected", comment: ""))
                                .font(Theme.Font.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(primaryDevice.map(deviceDetail) ?? "")
                                .font(Theme.Font.micro)
                                .foregroundStyle(Theme.mutedInk)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 42)
                    .accessibilityElement(children: .combine)
                }
                .frame(height: 127)
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(Theme.secondaryInk)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GPU utilization depends on compatible system statistics.")
                    if let thermalSnapshot {
                        Text(ThermalContextText.summary(thermalSnapshot, group: .gpu))
                            .help(ThermalContextText.sourceDescription(thermalSnapshot))
                    }
                }
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.mutedInk)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var primaryDevice: GPUDeviceSnapshot? {
        viewModel.snapshot.devices.first
    }

    private var primaryValue: String {
        if viewModel.snapshot.availability == .noDevice {
            return NSLocalizedString("No GPU", comment: "")
        }
        return viewModel.snapshot.usage
            .map(Formatters.percent) ?? NSLocalizedString("Unavailable", comment: "")
    }

    /// 高利用率描述活动强度而不是健康告警；没有温度、降频或任务意图时，
    /// 不能把“GPU 很忙”错误翻译成 Critical。
    private var activityStateLabel: String {
        guard let usage = viewModel.snapshot.usage else {
            return viewModel.snapshot.availability == .noDevice
                ? NSLocalizedString("Not detected", comment: "")
                : NSLocalizedString("No compatible metric", comment: "")
        }
        if usage < 0.1 { return NSLocalizedString("Idle", comment: "") }
        if usage < 0.8 { return NSLocalizedString("Active", comment: "") }
        return NSLocalizedString("High activity", comment: "")
    }

    private var activityStateColor: Color {
        guard let usage = viewModel.snapshot.usage else { return Theme.mutedInk }
        return usage < 0.1 ? Theme.secondaryInk : Theme.gpu
    }

    private var deviceCountLabel: String {
        if viewModel.snapshot.devices.count == 1 {
            return NSLocalizedString("1 device", comment: "")
        }
        return String(
            format: NSLocalizedString("%lld devices", comment: ""),
            viewModel.snapshot.devices.count
        )
    }

    private func percentOrUnavailable(_ value: Double?) -> String {
        value.map(Formatters.percent) ?? NSLocalizedString("Unavailable", comment: "")
    }

    private func deviceDetail(_ device: GPUDeviceSnapshot) -> String {
        let memory = NSLocalizedString(
            device.hasUnifiedMemory ? "Unified memory" : "Discrete memory",
            comment: ""
        )
        guard device.recommendedMaxWorkingSetBytes > 0 else { return memory }
        return String(
            format: NSLocalizedString("%@ · %@ working set", comment: ""),
            memory,
            Formatters.bytes(device.recommendedMaxWorkingSetBytes)
        )
    }
}
