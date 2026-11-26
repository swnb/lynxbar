import SwiftUI

/// Detailed multi-provider AI subscription quota view supporting independent opt-in toggles,
/// simultaneous per-provider cards (Claude, OpenAI Codex, Gemini), quota windows, credits/extra usage,
/// stale-while-error status, and CLI re-authentication remediation.
struct AIUsagePanelView: View {
    @ObservedObject var viewModel: AIUsageViewModel
    @Binding var selection: DashboardSection

    private var enabledProviderIDs: [AIUsageProviderID] {
        viewModel.enabledProviderIDs
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                headerRow

                if enabledProviderIDs.isEmpty {
                    onboardingCard
                } else {
                    providerToggleStrip

                    ForEach(enabledProviderIDs) { providerID in
                        providerCard(for: providerID)
                    }

                    footerCard
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    /// Top header row displaying the AI Quota title and an all-provider manual refresh button when active.
    private var headerRow: some View {
        HStack(spacing: 8) {
            Label("AI Quota", systemImage: "sparkles")
                .font(Theme.Font.title2.weight(.bold))
                .foregroundStyle(Theme.aiUsage)

            Spacer()

            if !enabledProviderIDs.isEmpty {
                if let latestSuccess = enabledProviderIDs.compactMap({ viewModel.lastSuccessfulFetchAt(for: $0) }).max() {
                    Text(
                        String(
                            format: NSLocalizedString("Updated %@", comment: ""),
                            Formatters.clockTime(latestSuccess)
                        )
                    )
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.mutedInk)
                    .monospacedDigit()
                }

                CompactRefreshButton(
                    isRefreshing: enabledProviderIDs.contains { viewModel.isRefreshing(for: $0) },
                    hasError: enabledProviderIDs.contains { viewModel.lastError(for: $0) != nil },
                    tint: Theme.aiUsage,
                    accessibilityLabel: NSLocalizedString("Refresh AI quota", comment: ""),
                    helpText: refreshHelp(for: nil),
                    action: { viewModel.refreshNow() }
                )
            }
        }
        .frame(height: 28)
    }

    /// Privacy-first onboarding card with independent opt-in toggles for Claude, OpenAI Codex, and Antigravity.
    private var onboardingCard: some View {
        V2Card {
            V2InsetCardContent(verticalPadding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    IconSectionHeader(
                        systemName: "sparkles",
                        title: "AI Subscription Quota",
                        tint: Theme.aiUsage
                    )

                    Text("Choose which local AI CLI subscriptions to monitor. All providers are off by default, strictly read-only, and never access browser cookies or store passwords.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(AIUsageProviderID.allCases) { providerID in
                            onboardingProviderRow(for: providerID)
                            if providerID != AIUsageProviderID.allCases.last {
                                Divider().overlay(Theme.divider)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Text("No credential files or Keychain items are read while a provider is off. Quota fetches only run while this tab, Overview, or a menu bar AI slot is active.")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Single provider opt-in row inside the onboarding card with flush leading icons and trailing switches.
    private func onboardingProviderRow(for providerID: AIUsageProviderID) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: providerID.symbolName)
                .font(Theme.Font.callout.weight(.semibold))
                .foregroundStyle(Theme.aiProviderAccent(for: providerID))
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(providerID.displayName))
                    .font(Theme.Font.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(LocalizedStringKey(onboardingHintKey(for: providerID)))
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(isOn: providerBinding(for: providerID)) {
                Text(LocalizedStringKey(providerID.displayName))
            }
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: Theme.aiProviderAccent(for: providerID)))
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Compact multi-provider toggle strip allowing users to enable/disable providers directly in the AI panel.
    private var providerToggleStrip: some View {
        V2Card {
            V2InsetCardContent(horizontalPadding: 10, verticalPadding: 6) {
                HStack(spacing: 6) {
                    ForEach(AIUsageProviderID.allCases) { providerID in
                        ProviderToggleChip(
                            providerID: providerID,
                            isEnabled: viewModel.isEnabled(for: providerID),
                            tint: Theme.aiProviderAccent(for: providerID),
                            action: {
                                viewModel.setEnabled(!viewModel.isEnabled(for: providerID), for: providerID)
                            }
                        )
                    }
                }
            }
        }
    }

    /// Independent `V2Card` rendering status, windows, credits/extra usage, and error remediation for one provider.
    private func providerCard(for providerID: AIUsageProviderID) -> some View {
        let state = viewModel.providerStates[providerID] ?? .disabled(for: providerID)
        let accent = Theme.aiProviderAccent(for: providerID)

        return V2Card(accentTint: state.lastError != nil && state.currentSnapshot == nil ? Theme.warning : accent) {
            V2InsetCardContent(verticalPadding: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    providerCardHeader(for: providerID, state: state, accent: accent)

                    if let snapshot = state.currentSnapshot {
                        if let lastError = state.lastError {
                            staleBanner(for: providerID, snapshot: snapshot, error: lastError)
                        }

                        let windows = orderedWindows(from: snapshot)
                        if !windows.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                                    windowRow(
                                        window: window,
                                        isPrimary: index == 0 && window.id == snapshot.primaryWindow?.id
                                    )
                                }
                            }
                        }

                        if let extra = snapshot.extraUsage, extra.isEnabled {
                            Divider().overlay(Theme.divider)
                            IconSectionHeader(
                                systemName: "creditcard",
                                title: "Extra usage",
                                tint: accent
                            ) {
                                Text(formattedExtraUsage(extra))
                                    .font(Theme.Font.captionMono)
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                        }

                        if let credits = snapshot.credits,
                           credits.hasCredits || credits.unlimited || credits.balanceText != nil || credits.balanceAmount != nil {
                            Divider().overlay(Theme.divider)
                            IconSectionHeader(
                                systemName: "banknote",
                                title: "Credits",
                                tint: accent
                            ) {
                                Text(formattedCredits(credits))
                                    .font(Theme.Font.captionMono)
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                        }
                    } else if let lastError = state.lastError {
                        errorSection(for: providerID, error: lastError, isRefreshing: state.isRefreshing, accent: accent)
                    } else {
                        loadingSection(for: providerID)
                    }
                }
            }
        }
    }

    /// Provider card header showing icon, name, optional plan/account badges, update time, and per-provider refresh button.
    private func providerCardHeader(
        for providerID: AIUsageProviderID,
        state: AIUsageProviderState,
        accent: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: providerID.symbolName)
                .font(Theme.Font.callout.weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(providerID.displayName))
                        .font(Theme.Font.callout.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)

                    if let plan = state.currentSnapshot?.planLabel {
                        Text(plan)
                            .font(Theme.Font.micro.weight(.semibold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(accent.opacity(0.14))
                            .clipShape(Capsule())
                            .lineLimit(1)
                    }
                }

                if let account = state.currentSnapshot?.accountLabel {
                    Text(account)
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.mutedInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if let fetchedAt = state.lastSuccessfulFetchAt {
                Text(Formatters.clockTime(fetchedAt))
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.mutedInk)
                    .monospacedDigit()
            }

            CompactRefreshButton(
                isRefreshing: state.isRefreshing,
                hasError: state.lastError != nil,
                tint: accent,
                accessibilityLabel: String(
                    format: NSLocalizedString("Refresh %@ quota", comment: ""),
                    NSLocalizedString(providerID.displayName, comment: "")
                ),
                helpText: refreshHelp(for: state),
                action: { viewModel.refreshNow(for: providerID) }
            )
        }
    }

    /// Placeholder section shown inside a provider card while initial quota fetch is running.
    private func loadingSection(for providerID: AIUsageProviderID) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(
                String(
                    format: NSLocalizedString("Checking %@ subscription quota…", comment: ""),
                    NSLocalizedString(providerID.displayName, comment: "")
                )
            )
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.mutedInk)
        }
        .padding(.vertical, 8)
    }

    /// Inline warning banner shown above cached quota windows when the latest refresh for `providerID` fails.
    private func staleBanner(
        for providerID: AIUsageProviderID,
        snapshot: AIProviderQuotaSnapshot,
        error: AIUsageFetchError
    ) -> some View {
        let ageText = Formatters.duration(max(0, Date().timeIntervalSince(snapshot.fetchedAt)))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                Text(
                    String(
                        format: NSLocalizedString("Update failed: %@ · showing data from %@ ago", comment: ""),
                        shortErrorReason(error, for: providerID),
                        ageText
                    )
                )
                .font(Theme.Font.micro.weight(.medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            }

            if error.stopsAutomaticRetry {
                CopyableValueRow(
                    label: "Terminal command",
                    value: providerID.cliLoginCommand,
                    minHeight: 26
                )
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.24), lineWidth: 0.5)
        }
    }

    /// Renders a single rolling or model quota window with percentage, reset countdown, and `LynxProgressBar`.
    private func windowRow(window: AIQuotaWindow, isPrimary: Bool) -> some View {
        let style = viewModel.displayStyle
        let displayed = window.displayedRatio(style: style)
        let tint = quotaColor(for: window)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(LocalizedStringKey(window.title))
                    .font(isPrimary ? Theme.Font.subheadline.weight(.semibold) : Theme.Font.caption.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if let resetLabel = resetText(for: window.resetsAt) {
                    Text(resetLabel)
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.mutedInk)
                        .monospacedDigit()
                        .lineLimit(1)
                        .layoutPriority(0.5)
                }

                Text(
                    String(
                        format: NSLocalizedString(
                            style == .remaining ? "%@ left" : "%@ used",
                            comment: ""
                        ),
                        Formatters.percent(displayed)
                    )
                )
                .font(isPrimary ? Theme.Font.bodyRounded.weight(.bold) : Theme.Font.subheadlineRounded.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lynxNumericTransition()
                .lineLimit(1)
                .layoutPriority(1)
            }

            LynxProgressBar(value: displayed, tint: tint, height: isPrimary ? 6 : 5)
        }
    }

    /// Actionable error section shown inside a provider card when no cached snapshot exists.
    private func errorSection(
        for providerID: AIUsageProviderID,
        error: AIUsageFetchError,
        isRefreshing: Bool,
        accent: Color
    ) -> some View {
        let details = errorDetails(for: error, providerID: providerID)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: error.stopsAutomaticRetry ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(Theme.Font.callout.weight(.semibold))
                    .foregroundStyle(error.stopsAutomaticRetry ? Theme.critical : Theme.warning)
                    .accessibilityHidden(true)
                Text(details.title)
                    .font(Theme.Font.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
            }

            Text(details.message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            if error.stopsAutomaticRetry {
                CopyableValueRow(
                    label: "Terminal command",
                    value: providerID.cliLoginCommand,
                    minHeight: 26
                )
            }

            HStack {
                LynxActionPillButton(
                    title: isRefreshing ? "Refreshing" : "Retry",
                    tint: accent,
                    isProminent: true,
                    action: {
                        guard !isRefreshing else { return }
                        viewModel.refreshNow(for: providerID)
                    }
                )
                .disabled(isRefreshing)
                Spacer()
            }
        }
    }

    /// Footer card exposing inline display-style switching (`LynxSegmentedPill`), Settings jump, and privacy boundary.
    private var footerCard: some View {
        V2Card {
            V2InsetCardContent(verticalPadding: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Quota display")
                            .font(Theme.Font.micro.weight(.medium))
                            .foregroundStyle(Theme.secondaryInk)

                        Spacer()

                        LynxSegmentedPill(
                            options: AIQuotaDisplayStyle.allCases,
                            selection: viewModel.displayStyle,
                            title: { $0 == .remaining ? "Quota left" : "Quota used" },
                            minItemWidth: 46,
                            itemHeight: 19,
                            onSelect: { viewModel.setDisplayStyle($0) }
                        )
                    }

                    HStack(alignment: .center, spacing: 8) {
                        Text("Read-only local OAuth · No browser cookies or password storage")
                            .font(Theme.Font.micro)
                            .foregroundStyle(Theme.mutedInk)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Settings") {
                            selection = .settings
                        }
                        .buttonStyle(.plain)
                        .font(Theme.Font.micro.weight(.semibold))
                        .foregroundStyle(Theme.selection)
                        .lineLimit(1)
                        .layoutPriority(1)
                    }
                }
            }
        }
    }

    /// Returns a SwiftUI `Binding` to the view model's per-provider opt-in toggle state.
    private func providerBinding(for providerID: AIUsageProviderID) -> Binding<Bool> {
        Binding(
            get: { viewModel.isEnabled(for: providerID) },
            set: { viewModel.setEnabled($0, for: providerID) }
        )
    }

    /// Collects primary, secondary, and additional windows in canonical display order.
    private func orderedWindows(from snapshot: AIProviderQuotaSnapshot) -> [AIQuotaWindow] {
        var windows: [AIQuotaWindow] = []
        if let primary = snapshot.primaryWindow {
            windows.append(primary)
        }
        if let secondary = snapshot.secondaryWindow {
            windows.append(secondary)
        }
        windows.append(contentsOf: snapshot.additionalWindows)
        return windows
    }

    /// Tooltip text describing refresh status for one provider or across all enabled providers.
    private func refreshHelp(for state: AIUsageProviderState?) -> String {
        if let state {
            if state.isRefreshing {
                return NSLocalizedString("Refreshing AI quota…", comment: "")
            }
            if state.lastError != nil {
                return NSLocalizedString("Last refresh failed", comment: "")
            }
            if let fetchedAt = state.lastSuccessfulFetchAt {
                return String(
                    format: NSLocalizedString("Refresh now · last updated %@", comment: ""),
                    Formatters.clockTime(fetchedAt)
                )
            }
            return NSLocalizedString("Refresh AI quota", comment: "")
        }

        if enabledProviderIDs.contains(where: { viewModel.isRefreshing(for: $0) }) {
            return NSLocalizedString("Refreshing AI quota…", comment: "")
        }
        if enabledProviderIDs.contains(where: { viewModel.lastError(for: $0) != nil }) {
            return NSLocalizedString("Last refresh failed", comment: "")
        }
        if let latest = enabledProviderIDs.compactMap({ viewModel.lastSuccessfulFetchAt(for: $0) }).max() {
            return String(
                format: NSLocalizedString("Refresh now · last updated %@", comment: ""),
                Formatters.clockTime(latest)
            )
        }
        return NSLocalizedString("Refresh AI quota", comment: "")
    }

    /// Maps remaining ratio to green (`>30%`), amber (`10%...30%`), or red (`<=10%`).
    private func quotaColor(for window: AIQuotaWindow) -> Color {
        if window.remainingRatio <= 0.10 { return Theme.critical }
        if window.remainingRatio <= 0.30 { return Theme.warning }
        return Theme.health
    }

    /// Formats a window's reset countdown and timestamp using `Date.FormatStyle` without allocating formatters.
    private func resetText(for date: Date?) -> String? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSinceNow
        if remaining > 0 {
            return String(
                format: NSLocalizedString("Resets in %@ · %@", comment: ""),
                Formatters.duration(remaining),
                date.formatted(date: .omitted, time: .shortened)
            )
        }
        return String(
            format: NSLocalizedString("Resets %@", comment: ""),
            date.formatted(date: .numeric, time: .shortened)
        )
    }

    /// Formats optional extra-usage spend and monthly limit using `FloatingPointFormatStyle.Currency`.
    private func formattedExtraUsage(_ extra: AIExtraUsageSummary) -> String {
        guard let used = extra.usedAmount else {
            return NSLocalizedString("Unavailable", comment: "")
        }
        let currencyStyle = FloatingPointFormatStyle<Double>.Currency(code: extra.currencyCode)
        let usedText = used.formatted(currencyStyle)
        if let limit = extra.monthlyLimit {
            let limitText = limit.formatted(currencyStyle)
            return "\(usedText) / \(limitText)"
        }
        return usedText
    }

    /// Formats optional Codex prepaid/credit balance cleanly.
    private func formattedCredits(_ credits: AIProviderCreditsSummary) -> String {
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
            return NSLocalizedString("Available", comment: "")
        }
        return NSLocalizedString("Unavailable", comment: "")
    }

    /// Returns the concise credential source hint localization key shown during onboarding.
    private func onboardingHintKey(for providerID: AIUsageProviderID) -> String {
        switch providerID {
        case .claude:
            return "Keychain or ~/.claude/.credentials.json · may prompt once for Keychain access"
        case .codex:
            return "$CODEX_HOME/auth.json or ~/.codex/auth.json"
        case .antigravity:
            return "Local Antigravity app, IDE, or agy CLI session"
        }
    }

    /// Returns the localized CLI tool name for remediation instructions.
    private func cliName(for providerID: AIUsageProviderID) -> String {
        switch providerID {
        case .claude: return NSLocalizedString("Claude Code", comment: "")
        case .codex: return NSLocalizedString("Codex CLI", comment: "")
        case .antigravity: return NSLocalizedString("Antigravity CLI", comment: "")
        }
    }

    /// Returns the localized upstream service name for error messages.
    private func vendorName(for providerID: AIUsageProviderID) -> String {
        switch providerID {
        case .claude: return NSLocalizedString("Anthropic", comment: "")
        case .codex: return NSLocalizedString("OpenAI", comment: "")
        case .antigravity: return NSLocalizedString("Google", comment: "")
        }
    }

    /// Maps an `AIUsageFetchError` to a short localized summary label for the stale banner.
    private func shortErrorReason(_ error: AIUsageFetchError, for providerID: AIUsageProviderID) -> String {
        switch error {
        case .credentialsMissing:
            return NSLocalizedString("Sign in required", comment: "")
        case .credentialsMalformed:
            return NSLocalizedString("Credentials could not be read", comment: "")
        case .tokenExpired, .unauthorized:
            return String(
                format: NSLocalizedString("%@ session expired", comment: ""),
                NSLocalizedString(providerID.shortName, comment: "")
            )
        case .rateLimited:
            return NSLocalizedString("Rate limited", comment: "")
        case .endpointUnavailable, .networkFailure, .decodingFailure, .disabled:
            return NSLocalizedString("Quota unavailable", comment: "")
        }
    }

    /// Maps an `AIUsageFetchError` to a localized title and remediation message for `providerID`.
    private func errorDetails(for error: AIUsageFetchError, providerID: AIUsageProviderID) -> (title: String, message: String) {
        let cli = cliName(for: providerID)
        let vendor = vendorName(for: providerID)
        let command = providerID.cliLoginCommand

        switch error {
        case .credentialsMissing:
            return (
                String(format: NSLocalizedString("%@ credentials not found", comment: ""), cli),
                String(format: NSLocalizedString("Sign in with %@ in Terminal, then retry.", comment: ""), cli)
            )
        case .tokenExpired, .unauthorized:
            return (
                String(
                    format: NSLocalizedString("%@ session expired", comment: ""),
                    NSLocalizedString(providerID.shortName, comment: "")
                ),
                String(format: NSLocalizedString("Run %@ in Terminal to refresh your session, then retry.", comment: ""), command)
            )
        case .credentialsMalformed:
            return (
                NSLocalizedString("Credentials could not be read", comment: ""),
                String(format: NSLocalizedString("Run %@ in Terminal to regenerate valid credentials, then retry.", comment: ""), command)
            )
        case .rateLimited(let retryAfter):
            let base = NSLocalizedString("Too many requests. Please wait before retrying.", comment: "")
            let message: String
            if let retryAfter, retryAfter > 0 {
                let hint = String(
                    format: NSLocalizedString("Retry suggested in %@.", comment: ""),
                    Formatters.duration(retryAfter)
                )
                message = "\(base) \(hint)"
            } else {
                message = base
            }
            return (
                String(format: NSLocalizedString("Rate limited by %@", comment: ""), vendor),
                message
            )
        case .endpointUnavailable(let statusCode):
            return (
                String(
                    format: NSLocalizedString("%@ usage endpoint unavailable (HTTP %lld)", comment: ""),
                    vendor,
                    Int64(statusCode)
                ),
                String(format: NSLocalizedString("Unable to reach %@", comment: ""), vendor)
            )
        case .networkFailure, .decodingFailure, .disabled:
            return (
                String(format: NSLocalizedString("Unable to reach %@", comment: ""), vendor),
                NSLocalizedString("Quota unavailable", comment: "")
            )
        }
    }
}

/// Interactive pill toggle for enabling or disabling a single AI quota provider from the AI panel.
private struct ProviderToggleChip: View {
    let providerID: AIUsageProviderID
    let isEnabled: Bool
    let tint: Color
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: providerID.symbolName)
                    .font(Theme.Font.micro.weight(.semibold))
                    .foregroundStyle(isEnabled ? tint : Theme.mutedInk)
                    .accessibilityHidden(true)

                Text(LocalizedStringKey(providerID.shortName))
                    .font(Theme.Font.micro.weight(isEnabled ? .semibold : .medium))
                    .foregroundStyle(isEnabled ? Theme.ink : Theme.secondaryInk)
                    .lineLimit(1)

                Spacer(minLength: 2)

                Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(Theme.Font.micro.weight(.semibold))
                    .foregroundStyle(isEnabled ? tint : Theme.mutedInk)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 24)
            .v2InteractiveSurface()
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isEnabled ? tint.opacity(isHovered ? 0.18 : 0.12) : (isHovered ? Theme.hoverFill : Theme.controlTrack))
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(isEnabled ? tint.opacity(0.35) : Theme.cardHairline, lineWidth: 0.5)
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .stroke(Theme.focusRingColor(isSelected: isEnabled), lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityLabel(
            String(
                format: NSLocalizedString("Toggle %@ quota monitoring", comment: ""),
                NSLocalizedString(providerID.displayName, comment: "")
            )
        )
        .accessibilityValue(NSLocalizedString(isEnabled ? "On" : "Off", comment: ""))
        .accessibilityAddTraits(isEnabled ? .isSelected : [])
    }
}
