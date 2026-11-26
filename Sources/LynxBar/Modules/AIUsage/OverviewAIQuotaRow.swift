import SwiftUI

/// Compact 36pt Overview summary row showing 1–3 enabled AI quota providers and jumping to the AI tab on click.
struct OverviewAIQuotaRow: View {
    @ObservedObject var aiUsage: AIUsageViewModel
    @Binding var selection: DashboardSection
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    private var enabledIDs: [AIUsageProviderID] {
        aiUsage.enabledProviderIDs
    }

    var body: some View {
        V2Card {
            Button {
                selection = .aiUsage
            } label: {
                HStack(spacing: 6) {
                    if enabledIDs.count == 1, let providerID = enabledIDs.first {
                        singleProviderContent(for: providerID)
                    } else if enabledIDs.count > 1 {
                        multiProviderContent(for: enabledIDs)
                    } else {
                        emptyContent
                    }

                    Image(systemName: "chevron.right")
                        .font(Theme.Font.micro.weight(.semibold))
                        .foregroundStyle(Theme.mutedInk)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .v2InteractiveSurface()
                .background(isHovered ? Theme.hoverFill : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .stroke(Theme.selection, lineWidth: 2)
                            .padding(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .onHover { isHovered = $0 }
            .accessibilityLabel(accessibilityLabelText)
            .accessibilityValue(accessibilityValueText)
            .accessibilityHint(NSLocalizedString("Open AI quota details", comment: ""))
        }
        .frame(height: OverviewLayoutMetrics.aiQuotaRowHeight)
    }

    /// Single-provider compact row layout matching Phase 1+2 glass proportions.
    @ViewBuilder
    private func singleProviderContent(for providerID: AIUsageProviderID) -> some View {
        let state = providerState(for: providerID)
        let window = state.currentSnapshot.flatMap(representativeWindow(from:))

        Image(systemName: providerID.symbolName)
            .font(Theme.Font.callout.weight(.semibold))
            .foregroundStyle(leadingTint(for: providerID, state: state, window: window))
            .frame(width: 14)
            .accessibilityHidden(true)

        Text(LocalizedStringKey(providerID.shortName))
            .font(Theme.Font.caption.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)

        Spacer(minLength: 6)

        if let window {
            let style = aiUsage.displayStyle
            let displayed = window.displayedRatio(style: style)
            let percent = Int((min(max(displayed, 0), 1) * 100).rounded())
            let color = quotaColor(for: window)

            HStack(spacing: 6) {
                LynxProgressBar(value: displayed, tint: color, height: 5)
                    .frame(width: 44)

                Text(
                    String(
                        format: NSLocalizedString(
                            style == .remaining ? "%lld%% left" : "%lld%% used",
                            comment: ""
                        ),
                        Int64(percent)
                    )
                )
                .font(Theme.Font.subheadlineRounded.weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lynxNumericTransition()
                .lineLimit(1)

                if state.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Font.micro.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                } else if let resetsAt = window.resetsAt {
                    let remaining = resetsAt.timeIntervalSinceNow
                    if remaining > 0 {
                        Text("· \(Formatters.duration(remaining))")
                            .font(Theme.Font.micro)
                            .foregroundStyle(Theme.mutedInk)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }
        } else if let snapshot = state.currentSnapshot {
            HStack(spacing: 6) {
                Text(Self.snapshotFallbackText(for: snapshot))
                    .font(Theme.Font.caption.weight(.medium))
                    .foregroundStyle(Theme.secondaryInk)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)

                if state.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Font.micro.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                }
            }
        } else if let error = state.lastError {
            Text(LocalizedStringKey(Self.errorSummaryKey(error)))
                .font(Theme.Font.caption.weight(.medium))
                .foregroundStyle(error.stopsAutomaticRetry ? Theme.critical : Theme.warning)
                .lineLimit(1)
        } else {
            Text("Checking quota…")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.mutedInk)
                .lineLimit(1)
        }
    }

    /// Multi-provider single-line summary distributing 2–3 compact provider chips inside the 36pt row.
    @ViewBuilder
    private func multiProviderContent(for providerIDs: [AIUsageProviderID]) -> some View {
        HStack(spacing: providerIDs.count > 2 ? 4 : 5) {
            ForEach(providerIDs) { providerID in
                multiProviderChip(for: providerID, totalCount: providerIDs.count)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Single compact chip representing one enabled AI provider inside a multi-provider Overview row.
    /// In 3-provider mode, stale/error states are conveyed via `leadingTint` to preserve chip label readability within 400pt.
    @ViewBuilder
    private func multiProviderChip(for providerID: AIUsageProviderID, totalCount: Int) -> some View {
        let state = providerState(for: providerID)
        let window = state.currentSnapshot.flatMap(representativeWindow(from:))
        let chipTint = leadingTint(for: providerID, state: state, window: window)

        HStack(spacing: totalCount > 2 ? 3 : 5) {
            Image(systemName: providerID.symbolName)
                .font(Theme.Font.micro.weight(.semibold))
                .foregroundStyle(chipTint)
                .accessibilityHidden(true)

            Text(LocalizedStringKey(providerID.shortName))
                .font(Theme.Font.micro.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .layoutPriority(0.5)

            if let window {
                let style = aiUsage.displayStyle
                let displayed = window.displayedRatio(style: style)
                let percent = Int((min(max(displayed, 0), 1) * 100).rounded())
                let color = quotaColor(for: window)

                LynxProgressBar(value: displayed, tint: color, height: 4)
                    .frame(width: totalCount > 2 ? 12 : 28)

                Text("\(percent)%")
                    .font(Theme.Font.micro.weight(.semibold))
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .lynxNumericTransition()
                    .lineLimit(1)
                    .layoutPriority(1)

                if totalCount <= 2, state.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Font.micro.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                }
            } else if let snapshot = state.currentSnapshot {
                Text(Self.compactChipFallbackText(for: snapshot))
                    .font(Theme.Font.micro.weight(.semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)

                if totalCount <= 2, state.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Font.micro.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                }
            } else if let error = state.lastError {
                Image(systemName: error.stopsAutomaticRetry ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(Theme.Font.micro.weight(.semibold))
                    .foregroundStyle(error.stopsAutomaticRetry ? Theme.critical : Theme.warning)
                    .accessibilityHidden(true)
            } else {
                Text("…")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.mutedInk)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, totalCount > 2 ? 4 : 7)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.controlTrack)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.cardHairline, lineWidth: 0.5)
        }
    }

    /// Fallback content shown if `OverviewAIQuotaRow` is rendered with no enabled providers.
    private var emptyContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(Theme.Font.callout.weight(.semibold))
                .foregroundStyle(Theme.aiUsage)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text("AI Quota")
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("Disabled in Settings")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.mutedInk)
                .lineLimit(1)
        }
    }

    /// Resolves the UI state for `providerID` from `AIUsageViewModel`.
    private func providerState(for providerID: AIUsageProviderID) -> AIUsageProviderState {
        aiUsage.providerStates[providerID] ?? .disabled(for: providerID)
    }

    /// Selects the representative quota window for compact summary display.
    private func representativeWindow(from snapshot: AIProviderQuotaSnapshot) -> AIQuotaWindow? {
        snapshot.primaryWindow ?? snapshot.secondaryWindow ?? snapshot.additionalWindows.first
    }

    /// Leading icon tint reflecting error severity when stale or errored, quota headroom, or provider accent color.
    private func leadingTint(
        for providerID: AIUsageProviderID,
        state: AIUsageProviderState,
        window: AIQuotaWindow?
    ) -> Color {
        if let error = state.lastError {
            return error.stopsAutomaticRetry ? Theme.critical : Theme.warning
        }
        if let window {
            return quotaColor(for: window)
        }
        return Theme.aiProviderAccent(for: providerID)
    }

    /// Localized VoiceOver label reflecting single-provider or multi-provider mode.
    private var accessibilityLabelText: String {
        if enabledIDs.count == 1, let providerID = enabledIDs.first {
            return String(
                format: NSLocalizedString("%@ AI quota", comment: ""),
                NSLocalizedString(providerID.displayName, comment: "")
            )
        }
        return NSLocalizedString("AI Quota", comment: "")
    }

    /// Localized VoiceOver value summarizing all active providers and their percentages or error states.
    var accessibilityValueText: String {
        Self.accessibilityValueSummary(
            enabledIDs: enabledIDs,
            providerStates: aiUsage.providerStates,
            displayStyle: aiUsage.displayStyle
        )
    }

    /// Builds a deterministic localized summary string for VoiceOver across 0–3 enabled providers.
    static func accessibilityValueSummary(
        enabledIDs: [AIUsageProviderID],
        providerStates: [AIUsageProviderID: AIUsageProviderState],
        displayStyle: AIQuotaDisplayStyle
    ) -> String {
        guard !enabledIDs.isEmpty else {
            return NSLocalizedString("Disabled in Settings", comment: "")
        }

        if enabledIDs.count == 1, let providerID = enabledIDs.first {
            let state = providerStates[providerID] ?? .disabled(for: providerID)
            if let snapshot = state.currentSnapshot {
                if let window = snapshot.primaryWindow ?? snapshot.secondaryWindow ?? snapshot.additionalWindows.first {
                    let percent = Int((min(max(window.displayedRatio(style: displayStyle), 0), 1) * 100).rounded())
                    return String(
                        format: NSLocalizedString(
                            displayStyle == .remaining ? "%lld%% left" : "%lld%% used",
                            comment: ""
                        ),
                        Int64(percent)
                    )
                }
                return snapshotFallbackText(for: snapshot)
            }
            if let error = state.lastError {
                return NSLocalizedString(errorSummaryKey(error), comment: "")
            }
            return NSLocalizedString("Checking quota…", comment: "")
        }

        let parts = enabledIDs.map { providerID -> String in
            let name = NSLocalizedString(providerID.displayName, comment: "")
            let state = providerStates[providerID] ?? .disabled(for: providerID)
            if let snapshot = state.currentSnapshot {
                if let window = snapshot.primaryWindow ?? snapshot.secondaryWindow ?? snapshot.additionalWindows.first {
                    let percent = Int((min(max(window.displayedRatio(style: displayStyle), 0), 1) * 100).rounded())
                    let value = String(
                        format: NSLocalizedString(
                            displayStyle == .remaining ? "%lld%% left" : "%lld%% used",
                            comment: ""
                        ),
                        Int64(percent)
                    )
                    return "\(name) \(value)"
                }
                return "\(name) \(snapshotFallbackText(for: snapshot))"
            }
            if let error = state.lastError {
                return "\(name) \(NSLocalizedString(errorSummaryKey(error), comment: ""))"
            }
            return "\(name) \(NSLocalizedString("Checking quota…", comment: ""))"
        }
        return parts.joined(separator: "; ")
    }

    /// Formats a compact localized summary for loaded snapshots that omit quota windows (such as credits-only Codex accounts).
    static func snapshotFallbackText(for snapshot: AIProviderQuotaSnapshot) -> String {
        if let credits = snapshot.credits {
            let prefix = NSLocalizedString("Credits", comment: "")
            if credits.unlimited {
                return "\(prefix) · \(NSLocalizedString("Unlimited", comment: ""))"
            }
            if let text = credits.balanceText {
                return "\(prefix) · \(text)"
            }
            if let amount = credits.balanceAmount {
                let formatted = amount.formatted(.number.precision(.fractionLength(0...2)))
                return "\(prefix) · \(formatted)"
            }
            if credits.hasCredits {
                return "\(prefix) · \(NSLocalizedString("Available", comment: ""))"
            }
            return "\(prefix) · \(NSLocalizedString("Unavailable", comment: ""))"
        }
        return snapshot.planLabel ?? NSLocalizedString("Available", comment: "")
    }

    /// Formats an ultra-compact label for multi-provider chips when a loaded snapshot has no quota windows.
    private static func compactChipFallbackText(for snapshot: AIProviderQuotaSnapshot) -> String {
        if let credits = snapshot.credits {
            if credits.unlimited {
                return NSLocalizedString("Unlimited", comment: "")
            }
            if let text = credits.balanceText {
                return text
            }
            if let amount = credits.balanceAmount {
                return amount.formatted(.number.precision(.fractionLength(0...2)))
            }
            if credits.hasCredits {
                return NSLocalizedString("Credits", comment: "")
            }
            return NSLocalizedString("Unavailable", comment: "")
        }
        return snapshot.planLabel ?? NSLocalizedString("Available", comment: "")
    }

    /// Maps remaining capacity to green (`>30%`), amber (`10%...30%`), or red (`<=10%`).
    private func quotaColor(for window: AIQuotaWindow) -> Color {
        if window.remainingRatio <= 0.10 { return Theme.critical }
        if window.remainingRatio <= 0.30 { return Theme.warning }
        return Theme.health
    }

    /// Maps an `AIUsageFetchError` to a concise localization key for the compact row.
    static func errorSummaryKey(_ error: AIUsageFetchError) -> String {
        switch error {
        case .credentialsMissing, .credentialsMalformed, .tokenExpired, .unauthorized:
            return "Sign in required"
        case .rateLimited:
            return "Rate limited"
        case .disabled, .endpointUnavailable, .networkFailure, .decodingFailure:
            return "Quota unavailable"
        }
    }
}
