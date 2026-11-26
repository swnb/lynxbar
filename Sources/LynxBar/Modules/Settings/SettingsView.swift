import SwiftUI

/// Preferences panel configuring menu bar presentation, sampling intervals, visible tabs, privacy, and appearance.
struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(Theme.Font.title2.weight(.bold))
                    .frame(minHeight: 22)

                SettingsGroup(title: "Menu bar") {
                    SettingsValueRow(
                        systemName: "menubar.rectangle",
                        color: Theme.selection,
                        title: "Display mode",
                        detail: "Choose the amount of detail in the menu bar"
                    ) {
                        Picker(
                            "Menu bar display mode",
                            selection: $settings.menuBarDisplayMode
                        ) {
                            ForEach(MenuBarDisplayMode.allCases) { mode in
                                Text(LocalizedStringKey(mode.localizationKey)).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 116)
                    }

                    if settings.menuBarDisplayMode != .minimal {
                        Divider().overlay(Theme.divider)
                        ForEach(
                            Array(settings.menuBarSlots.prefix(
                                settings.menuBarDisplayMode.maximumSlotCount
                            )).indices,
                            id: \.self
                        ) { index in
                            SettingsValueRow(
                                systemName: "rectangle.split.3x1",
                                color: Theme.selection,
                                title: String(
                                    format: NSLocalizedString(
                                        "Metric slot %lld",
                                        comment: ""
                                    ),
                                    index + 1
                                ),
                                detail: "Choose a metric to show without opening LynxBar"
                            ) {
                                Picker(
                                    "Menu bar metric",
                                    selection: menuBarSlotBinding(index)
                                ) {
                                    ForEach(MenuBarStatusSlot.allCases) { slot in
                                        Text(LocalizedStringKey(slot.localizationKey)).tag(slot)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 116)
                            }
                            if index + 1 < min(
                                settings.menuBarSlots.count,
                                settings.menuBarDisplayMode.maximumSlotCount
                            ) {
                                Divider().overlay(Theme.divider)
                            }
                        }
                        if settings.menuBarSlots.count
                            < settings.menuBarDisplayMode.maximumSlotCount {
                            Button {
                                let choices = MenuBarStatusSlot.recommended
                                    + MenuBarStatusSlot.allCases
                                guard let slot = choices.first(where: {
                                    !settings.menuBarSlots.contains($0)
                                }) else { return }
                                settings.setMenuBarSlot(slot, at: settings.menuBarSlots.count)
                            } label: {
                                Label("Add metric slot", systemImage: "plus.circle")
                                    .font(Theme.Font.caption.weight(.medium))
                                    .foregroundStyle(Theme.selection)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                        }
                        if settings.menuBarSlots
                            .prefix(settings.menuBarDisplayMode.maximumSlotCount)
                            .contains(.aiUsage),
                           !settings.anyAIUsageEnabled {
                            Text("All AI quota providers are off in Privacy. The menu bar slot displays AI — without making network requests.")
                                .font(Theme.Font.micro)
                                .foregroundStyle(Theme.mutedInk)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }
                }

                SettingsGroup(title: "Monitoring") {
                    SettingsValueRow(
                        systemName: "clock",
                        color: Theme.selection,
                        title: "Live update interval",
                        detail: "Live modules and processes"
                    ) {
                        Picker("Live update interval", selection: $settings.updateInterval) {
                            ForEach(Settings.intervals, id: \.self) { interval in
                                Text(
                                    String(
                                        format: NSLocalizedString("%lld seconds", comment: ""),
                                        Int(interval)
                                    )
                                )
                                .tag(interval)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 116)
                    }

                    Divider().overlay(Theme.divider)

                    SettingsValueRow(
                        systemName: "externaldrive",
                        color: Theme.disk,
                        title: "Disk capacity",
                        detail: "Adjustable low-frequency sampling"
                    ) {
                        Picker(
                            "Disk capacity interval",
                            selection: $settings.diskCapacityCadence
                        ) {
                            ForEach(DiskCapacityCadence.allCases) { cadence in
                                Text(LocalizedStringKey(cadence.shortLabel))
                                    .tag(cadence)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 116)
                    }
                }

                SettingsGroup(title: "Visible destinations") {
                    DestinationToggle(
                        title: "CPU",
                        systemName: "cpu",
                        color: Theme.cpu,
                        isOn: $settings.cpuEnabled
                    )
                    Divider().overlay(Theme.divider)
                    DestinationToggle(
                        title: "Memory",
                        systemName: "memorychip",
                        color: Theme.memory,
                        isOn: $settings.memoryEnabled
                    )
                    Divider().overlay(Theme.divider)
                    DestinationToggle(
                        title: "Disk",
                        systemName: "externaldrive",
                        color: Theme.disk,
                        isOn: $settings.diskEnabled
                    )
                    Divider().overlay(Theme.divider)
                    DestinationToggle(
                        title: "Network",
                        systemName: "network",
                        color: Theme.networkInput,
                        isOn: $settings.networkEnabled
                    )
                    Divider().overlay(Theme.divider)
                    DestinationToggle(
                        title: "GPU",
                        systemName: "square.stack.3d.up",
                        color: Theme.gpu,
                        isOn: $settings.gpuEnabled
                    )
                    Divider().overlay(Theme.divider)
                    DestinationToggle(
                        title: "Battery",
                        systemName: "battery.75percent",
                        color: Theme.battery,
                        isOn: $settings.batteryEnabled
                    )
                    Divider().overlay(Theme.divider)
                    DestinationToggle(
                        title: "AI Quota",
                        systemName: "sparkles",
                        color: Theme.aiUsage,
                        isOn: $settings.aiUsageSectionVisible
                    )
                    Text("Overview health remains available")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.mutedInk)
                        .padding(.top, 2)
                }

                SettingsGroup(title: "History") {
                    SettingsValueRow(
                        systemName: "calendar.badge.clock",
                        color: Theme.selection,
                        title: "History",
                        detail: "Bounded local aggregates · no cloud sync"
                    ) {
                        Text("Up to 1 week")
                            .font(Theme.Font.caption.weight(.medium))
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }

                SettingsGroup(title: "Accessory battery") {
                    Toggle(isOn: $settings.standardBLEBatteryEnabled) {
                        SettingsLabel(
                            systemName: "antenna.radiowaves.left.and.right",
                            color: Theme.battery,
                            title: "Standard Bluetooth battery service",
                            detail: "Scan supported accessories while their battery is visible"
                        )
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.selection))
                    Text("Controller battery uses public GameController data. Bluetooth scanning is optional; unsupported or disconnected devices show unavailable.")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsGroup(title: "Privacy") {
                    Toggle(isOn: $settings.showPublicIP) {
                        SettingsLabel(
                            systemName: "hand.raised",
                            color: Theme.health,
                            title: "Show public IP",
                            detail: "Off by default · HTTPS lookup every 10 min"
                        )
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.selection))
                    Text("No outbound network requests by default. When enabled, LynxBar queries ipify, ifconfig.me, or icanhazip over HTTPS every 10 minutes and caches the last successful IP locally.")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(Theme.divider)

                    Toggle(isOn: $settings.claudeUsageEnabled) {
                        SettingsLabel(
                            systemName: AIUsageProviderID.claude.symbolName,
                            color: Theme.aiProviderAccent(for: .claude),
                            title: "Claude subscription quota",
                            detail: "Off by default · read-only local OAuth"
                        )
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.selection))
                    Text("Reads local Claude Code OAuth credentials read-only (Keychain or ~/.claude/.credentials.json) and queries api.anthropic.com every 5 minutes only while viewed or shown in the menu bar. Never reads browser cookies or stores passwords.")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(Theme.divider)

                    Toggle(isOn: $settings.codexUsageEnabled) {
                        SettingsLabel(
                            systemName: AIUsageProviderID.codex.symbolName,
                            color: Theme.aiProviderAccent(for: .codex),
                            title: "OpenAI Codex subscription quota",
                            detail: "Off by default · read-only local OAuth"
                        )
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.selection))
                    Text("Reads local Codex CLI OAuth credentials read-only ($CODEX_HOME/auth.json or ~/.codex/auth.json) and queries chatgpt.com every 5 minutes only while viewed or shown in the menu bar. Never reads browser cookies or refreshes tokens.")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(Theme.divider)

                    Toggle(isOn: $settings.antigravityUsageEnabled) {
                        SettingsLabel(
                            systemName: AIUsageProviderID.antigravity.symbolName,
                            color: Theme.aiProviderAccent(for: .antigravity),
                            title: "Antigravity subscription quota",
                            detail: "Off by default · local app / agy CLI via CodexBarCore"
                        )
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.selection))
                    Text("Queries your local Antigravity app, IDE, or agy CLI session every 5 minutes via CodexBarCore only while viewed or shown in the menu bar. Never reads browser cookies or stores passwords.")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(Theme.divider)

                    SettingsValueRow(
                        systemName: "percent",
                        color: Theme.aiUsage,
                        title: "Quota display",
                        detail: "Remaining or used percentage"
                    ) {
                        Picker(
                            "Quota display",
                            selection: $settings.aiQuotaDisplayStyle
                        ) {
                            ForEach(AIQuotaDisplayStyle.allCases) { style in
                                Text(LocalizedStringKey(style.localizationKey)).tag(style)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 116)
                    }
                }

                SettingsGroup(title: "Processes") {
                    Stepper(value: $settings.processTopN, in: 5...20, step: 5) {
                        SettingsLabel(
                            systemName: "list.number",
                            color: Theme.selection,
                            title: "Rows collected",
                            detail: String(
                                format: NSLocalizedString("%lld rows", comment: ""),
                                settings.processTopN
                            )
                        )
                    }
                }

                SettingsGroup(title: "General") {
                    SettingsValueRow(
                        systemName: "circle.lefthalf.filled",
                        color: Theme.selection,
                        title: "Appearance",
                        detail: "Match macOS or choose light or dark"
                    ) {
                        Picker(
                            "Appearance",
                            selection: $settings.appearanceMode
                        ) {
                            ForEach(AppAppearanceMode.allCases) { mode in
                                Text(LocalizedStringKey(mode.localizationKey)).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 116)
                    }

                    Divider().overlay(Theme.divider)

                    Toggle(
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { enabled in
                                settings.launchAtLogin = enabled
                                LaunchAtLogin.set(enabled)
                            }
                        )
                    ) {
                        SettingsLabel(
                            systemName: "gearshape",
                            color: Theme.secondaryInk,
                            title: "Launch at login",
                            detail: "Start LynxBar after signing in"
                        )
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.selection))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    /// Returns a `Binding` for the menu bar slot picker at `index`, defaulting safely to `.cpu`.
    private func menuBarSlotBinding(_ index: Int) -> Binding<MenuBarStatusSlot> {
        Binding(
            get: {
                settings.menuBarSlots.indices.contains(index)
                    ? settings.menuBarSlots[index]
                    : .cpu
            },
            set: { settings.setMenuBarSlot($0, at: index) }
        )
    }
}

private extension MenuBarDisplayMode {
    /// Maps each display mode to its localization key in `Localizable.strings`.
    var localizationKey: String {
        switch self {
        case .minimal: return "Minimal"
        case .focus: return "Focus"
        case .compact: return "Compact"
        }
    }
}

private extension AppAppearanceMode {
    /// Maps each appearance mode case to its localization key in `Localizable.strings`.
    var localizationKey: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

private extension MenuBarStatusSlot {
    /// Maps each menu bar metric slot to its localization key in `Localizable.strings`.
    var localizationKey: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk usage"
        case .network: return "Network ↓/↑"
        case .gpu: return "GPU"
        case .thermal: return "System thermal state"
        case .internalBattery: return "Internal battery"
        case .accessoryBattery: return "Accessory battery"
        case .aiUsage: return "AI Quota"
        }
    }
}

private extension AIQuotaDisplayStyle {
    /// Maps each quota display style to distinct localization keys avoiding Battery/Disk collisions.
    var localizationKey: String {
        switch self {
        case .remaining: return "Remaining quota"
        case .used: return "Used quota"
        }
    }
}

/// Titled card container grouping related settings rows.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title))
                .font(Theme.Font.micro.weight(.semibold))
                .foregroundStyle(Theme.mutedInk)
                .padding(.leading, 3)
            V2Card {
                VStack(alignment: .leading, spacing: 2) {
                    content()
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .controlSize(.small)
            }
        }
    }
}

/// Settings row pairing an icon, title, and subtitle with a trailing control.
private struct SettingsValueRow<Trailing: View>: View {
    let systemName: String
    let color: Color
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 9) {
            SettingsLabel(
                systemName: systemName,
                color: color,
                title: title,
                detail: detail
            )
            Spacer()
            trailing()
        }
        .frame(minHeight: 28)
    }
}

/// Reusable icon, title, and single-line subtitle block used inside settings rows and toggles.
private struct SettingsLabel: View {
    let systemName: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemName)
                .font(Theme.Font.callout.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 19)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(title))
                    .font(Theme.Font.caption.weight(.medium))
                Text(LocalizedStringKey(detail))
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.mutedInk)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Toggle row controlling whether a dashboard section appears in the bottom navigation bar.
private struct DestinationToggle: View {
    let title: String
    let systemName: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 9) {
                Image(systemName: systemName)
                    .font(Theme.Font.callout.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 19)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(title))
                    .font(Theme.Font.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(SwitchToggleStyle(tint: Theme.selection))
        .controlSize(.small)
        .frame(minHeight: 24)
    }
}
