import AppKit
import Foundation
import SwiftUI

/// Navigation destinations available in the LynxBar popover dashboard.
enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case cpu = "CPU"
    case memory = "Memory"
    case disk = "Disk"
    case network = "Network"
    case gpu = "GPU"
    case battery = "Battery"
    case aiUsage = "AI"
    case settings = "Settings"

    /// Stable `Identifiable` identifier matching `self`.
    var id: Self { self }

    /// SF Symbol icon name representing each dashboard destination.
    var systemName: String {
        switch self {
        case .overview: return "waveform.path.ecg"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "externaldrive"
        case .network: return "network"
        case .gpu: return "square.stack.3d.up"
        case .battery: return "battery.75percent"
        case .aiUsage: return "sparkles"
        case .settings: return "gearshape"
        }
    }

    /// Descriptive VoiceOver label for each navigation destination.
    var accessibilityTitle: String {
        switch self {
        case .aiUsage: return "AI Quota"
        default: return rawValue
        }
    }
}

/// V2 稳定根布局：品牌头和底部目的地固定，只有详情内容在需要时滚动。
struct DashboardView: View {
    @ObservedObject var cpu: CPUViewModel
    @ObservedObject var memory: MemoryViewModel
    @ObservedObject var disk: DiskViewModel
    @ObservedObject var network: NetworkViewModel
    @ObservedObject var gpu: GPUViewModel
    @ObservedObject var battery: BatteryViewModel
    @ObservedObject var process: ProcessViewModel
    @ObservedObject var thermal: ThermalViewModel
    @ObservedObject var accessoryPower: AccessoryPowerViewModel
    @ObservedObject var aiUsage: AIUsageViewModel
    @ObservedObject private var settings = Settings.shared
    @State private var selection: DashboardSection = .overview
    private let onSelectionChange: (DashboardSection) -> Void
    private let openDiskCleanup: () -> Void

    /// Creates the root `DashboardView` with module view models, initial tab selection, and cleanup callback.
    init(
        cpu: CPUViewModel,
        memory: MemoryViewModel,
        disk: DiskViewModel,
        network: NetworkViewModel,
        gpu: GPUViewModel,
        battery: BatteryViewModel,
        process: ProcessViewModel,
        thermal: ThermalViewModel? = nil,
        accessoryPower: AccessoryPowerViewModel? = nil,
        aiUsage: AIUsageViewModel? = nil,
        initialSelection: DashboardSection = .overview,
        onSelectionChange: @escaping (DashboardSection) -> Void = { _ in },
        openDiskCleanup: @escaping () -> Void = {}
    ) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.gpu = gpu
        self.battery = battery
        self.process = process
        self.thermal = thermal ?? ThermalViewModel(settings: .shared)
        self.accessoryPower = accessoryPower ?? AccessoryPowerViewModel(settings: .shared)
        self.aiUsage = aiUsage ?? AIUsageViewModel(settings: .shared)
        self.onSelectionChange = onSelectionChange
        self.openDiskCleanup = openDiskCleanup
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        VStack(spacing: 0) {
            DashboardHeader(
                isSettingsSelected: selection == .settings,
                onToggleSettings: {
                    selection = (selection == .settings ? .overview : .settings)
                }
            )

            Group {
                switch selection {
                case .overview:
                    OverviewView(
                        selection: $selection,
                        cpu: cpu,
                        memory: memory,
                        disk: disk,
                        network: network,
                        process: process,
                        aiUsage: aiUsage,
                        thermalState: thermal.snapshot.publicState
                    )
                case .cpu:
                    CPUPanelView(
                        viewModel: cpu,
                        processViewModel: process,
                        remediationContextProvider: processContext,
                        thermalSnapshot: thermal.snapshot
                    )
                case .memory:
                    MemoryPanelView(
                        viewModel: memory,
                        processViewModel: process,
                        remediationContextProvider: processContext
                    )
                case .disk:
                    DiskPanelView(
                        viewModel: disk,
                        openCleanup: openDiskCleanup
                    )
                case .network:
                    NetworkPanelView(viewModel: network)
                case .gpu:
                    GPUPanelView(viewModel: gpu, thermalSnapshot: thermal.snapshot)
                case .battery:
                    BatteryPanelView(viewModel: battery, accessoryPower: accessoryPower)
                case .aiUsage:
                    AIUsagePanelView(viewModel: aiUsage, selection: $selection)
                case .settings:
                    SettingsView()
                }
            }
            .id(selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .transition(.opacity.combined(with: .move(edge: .trailing)))

            BottomNavigation(
                selection: $selection,
                sections: visibleSections
            )
        }
        .animation(.easeOut(duration: 0.15), value: selection)
        .onChange(of: selection) { newValue in
            onSelectionChange(newValue)
        }
        .frame(width: 420, height: 600)
        .background(Theme.surface)
        .foregroundStyle(Theme.ink)
    }

    /// 只采集当前上下文，不发动作；sheet 每次准备/复测均重新读取该闭包。
    private func processContext() -> ProcessRemediationContext {
        ProcessRemediationContext.current(
            cpuHistory: cpu.recentHistory.points,
            memoryPressure: memory.pressure,
            swapUsedBytes: memory.snapshot.swapUsed
        )
    }

    /// Returns the ordered list of destinations currently enabled for the bottom navigation bar.
    private var visibleSections: [DashboardSection] {
        var sections: [DashboardSection] = [.overview]
        if settings.cpuEnabled { sections.append(.cpu) }
        if settings.memoryEnabled { sections.append(.memory) }
        if settings.diskEnabled { sections.append(.disk) }
        if settings.networkEnabled { sections.append(.network) }
        if settings.gpuEnabled { sections.append(.gpu) }
        if settings.batteryEnabled { sections.append(.battery) }
        if settings.aiUsageSectionVisible { sections.append(.aiUsage) }
        return sections
    }
}

/// Fixed 42pt brand header displaying the LynxBar icon, host name, live badge, and Settings button.
struct DashboardHeader: View {
    var isSettingsSelected: Bool = false
    var onToggleSettings: () -> Void = {}

    @FocusState private var isSettingsFocused: Bool
    @State private var isSettingsHovered = false

    /// Localized Mac host name shown in the center of the header.
    private var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    var body: some View {
        HStack(spacing: 8) {
            headerIcon
            Text("LynxBar")
                .font(Theme.Font.title2.weight(.bold))
            Spacer()
            Text(deviceName)
                .font(Theme.Font.subheadline.weight(.medium))
                .foregroundStyle(Theme.secondaryInk)
                .lineLimit(1)
            Spacer()
            Circle()
                .fill(Theme.health)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text("Live")
                .font(Theme.Font.subheadline.weight(.medium))
                .foregroundStyle(Theme.health)
            settingsButton
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            String(
                format: NSLocalizedString("LynxBar on %@, live", comment: ""),
                deviceName
            )
        )
    }

    /// Top-right Settings toggle button preserving an 8-destination `BottomNavigation` bar.
    private var settingsButton: some View {
        Button(action: onToggleSettings) {
            Image(systemName: isSettingsSelected ? "gearshape.fill" : "gearshape")
                .font(Theme.Font.callout.weight(.semibold))
                .foregroundStyle(isSettingsSelected ? Theme.selection : Theme.secondaryInk)
                .frame(width: 28, height: 28)
                .v2InteractiveSurface()
                .background(
                    isSettingsSelected
                        ? Theme.selectionSoft
                        : (isSettingsHovered ? Theme.hoverFill : Color.clear)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                .overlay {
                    if isSettingsFocused {
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .stroke(Theme.focusRingColor(isSelected: isSettingsSelected), lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .focused($isSettingsFocused)
        .onHover { isSettingsHovered = $0 }
        .help(NSLocalizedString("Settings", comment: ""))
        .accessibilityLabel(NSLocalizedString("Settings", comment: ""))
        .accessibilityAddTraits(isSettingsSelected ? .isSelected : [])
    }

    /// Renders the custom `MenuBarIcon` template asset when available, falling back to an SF Symbol.
    @ViewBuilder
    private var headerIcon: some View {
        if let custom = NSImage(named: NSImage.Name("MenuBarIcon")),
           !custom.representations.isEmpty {
            Image(nsImage: custom)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(Theme.health)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "waveform.path.ecg")
                .font(Theme.Font.title2.weight(.bold))
                .foregroundStyle(Theme.health)
                .accessibilityHidden(true)
        }
    }
}

/// Fixed 62pt bottom navigation strip hosting up to 8 visible module destinations.
private struct BottomNavigation: View {
    @Binding var selection: DashboardSection
    let sections: [DashboardSection]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(sections) { section in
                BottomDestinationButton(
                    section: section,
                    isSelected: selection == section,
                    action: { selection = section }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(height: 62)
        .background(Theme.raised)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}

/// Single destination tab button inside `BottomNavigation` with hover, focus, and VoiceOver states.
private struct BottomDestinationButton: View {
    let section: DashboardSection
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: section.systemName)
                    .font(Theme.Font.title2.weight(.semibold))
                Text(LocalizedStringKey(section.rawValue))
                    .font(Theme.Font.micro.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Theme.selection : Theme.secondaryInk)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .v2InteractiveSurface()
            .background(isSelected ? Theme.selectionSoft : (isHovered ? Theme.hoverFill : .clear))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .stroke(Theme.focusRingColor(isSelected: isSelected), lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityLabel(NSLocalizedString(section.accessibilityTitle, comment: ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
