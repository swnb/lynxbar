import SwiftUI

/// Detailed AI subscription quota view showing onboarding, Claude 5h/7d windows,
/// optional model-specific and extra-usage breakdowns, stale-while-error status, and `claude /login` remediation.
struct AIUsagePanelView: View {
    @ObservedObject var viewModel: AIUsageViewModel
    @Binding var selection: DashboardSection
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                headerRow

                if !settings.aiUsageEnabled {
                    onboardingCard
                } else if let snapshot = viewModel.currentSnapshot {
                    if let lastError = viewModel.lastError {
                        staleBanner(snapshot: snapshot, error: lastError)
                    }
                    windowCard(
                        title: "5-hour session",
                        systemName: "timer",
                        window: snapshot.primaryWindow,
                        isPrimary: true
                    )
                    windowCard(
                        title: "7-day weekly",
                        systemName: "calendar",
                        window: snapshot.secondaryWindow,
                        isPrimary: false
                    )
                    if !snapshot.additionalWindows.isEmpty || snapshot.extraUsage?.isEnabled == true {
                        breakdownCard(snapshot: snapshot)
                    }
                    footerCard(snapshot: snapshot)
                } else if let lastError = viewModel.lastError {
                    errorCard(error: lastError)
                } else {
                    loadingCard
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    /// Top header row displaying the AI Quota title, optional plan badge, timestamp, and manual refresh button.
    private var headerRow: some View {
        HStack(spacing: 8) {
            Label("AI Quota", systemImage: "sparkles")
                .font(Theme.Font.title2.weight(.bold))
                .foregroundStyle(Theme.aiUsage)

            if settings.aiUsageEnabled, let plan = viewModel.currentSnapshot?.planLabel {
                Text(plan)
                    .font(Theme.Font.micro.weight(.semibold))
                    .foregroundStyle(Theme.selection)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.selectionSoft)
                    .clipShape(Capsule())
            }

            Spacer()

            if settings.aiUsageEnabled {
                if let fetchedAt = viewModel.lastSuccessfulFetchAt {
                    Text(
                        String(
                            format: NSLocalizedString("Updated %@", comment: ""),
                            Formatters.clockTime(fetchedAt)
                        )
                    )
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.mutedInk)
                    .monospacedDigit()
                }

                CompactRefreshButton(
                    isRefreshing: viewModel.isRefreshing,
                    hasError: viewModel.lastError != nil,
                    tint: Theme.aiUsage,
                    accessibilityLabel: NSLocalizedString("Refresh AI quota", comment: ""),
                    helpText: refreshHelp,
                    action: viewModel.refreshNow
                )
            }
        }
        .frame(height: 28)
    }

    /// Privacy-first onboarding card explaining local read-only credential access and enabling quota monitoring.
    private var onboardingCard: some View {
        V2Card {
            V2InsetCardContent(verticalPadding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    IconSectionHeader(
                        systemName: "sparkles",
                        title: "Claude Subscription Quota",
                        tint: Theme.aiUsage
                    )

                    Text("Reads local Claude Code OAuth credentials read-only to query 5-hour and 7-day usage directly from Anthropic. Never accesses browser cookies, stores passwords, or uploads data.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enabling may prompt once for macOS Keychain read access to \"Claude Code-credentials\".")
                            .font(Theme.Font.micro)
                            .foregroundStyle(Theme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Only fetches when this tab, Overview, or a menu bar AI slot is active.")
                            .font(Theme.Font.micro)
                            .foregroundStyle(Theme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button("Enable Claude Quota Monitoring") {
                        settings.aiUsageEnabled = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.aiUsage)
                    .controlSize(.regular)
                }
            }
        }
    }

    /// Placeholder card shown while the initial quota fetch is in progress without a cached snapshot.
    private var loadingCard: some View {
        V2Card {
            VStack(spacing: 10) {
                ProgressView()
                Text("Checking Claude subscription quota…")
                    .font(Theme.Font.subheadline)
                    .foregroundStyle(Theme.mutedInk)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    /// Warning banner displayed above cached quota cards when the latest refresh fails.
    private func staleBanner(snapshot: AIProviderQuotaSnapshot, error: AIUsageFetchError) -> some View {
        let ageText = Formatters.duration(max(0, Date().timeIntervalSince(snapshot.fetchedAt)))
        return V2Card {
            V2InsetCardContent(verticalPadding: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(Theme.Font.callout.weight(.semibold))
                            .foregroundStyle(Theme.warning)
                            .accessibilityHidden(true)
                        Text(
                            String(
                                format: NSLocalizedString("Update failed: %@ · showing data from %@ ago", comment: ""),
                                shortErrorReason(error),
                                ageText
                            )
                        )
                        .font(Theme.Font.caption.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if error.stopsAutomaticRetry {
                        CopyableValueRow(
                            label: "Terminal command",
                            value: "claude /login",
                            minHeight: 26
                        )
                    }
                }
            }
        }
    }

    /// Card rendering a single rolling quota window with percentage, progress bar, and reset countdown.
    private func windowCard(
        title: String,
        systemName: String,
        window: AIQuotaWindow?,
        isPrimary: Bool
    ) -> some View {
        let style = settings.aiQuotaDisplayStyle
        let tint = window.map(quotaColor(for:)) ?? Theme.mutedInk
        return V2Card {
            V2InsetCardContent(verticalPadding: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    IconSectionHeader(
                        systemName: systemName,
                        title: title,
                        tint: tint
                    ) {
                        if let window, let resetLabel = resetText(for: window.resetsAt) {
                            Text(resetLabel)
                                .font(Theme.Font.micro)
                                .foregroundStyle(Theme.mutedInk)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }

                    if let window {
                        let displayed = window.displayedRatio(style: style)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(Formatters.percent(displayed))
                                .font(isPrimary ? Theme.Font.metricValue.weight(.bold) : Theme.Font.statValue.weight(.bold))
                                .foregroundStyle(tint)
                                .monospacedDigit()
                            Text(LocalizedStringKey(style == .remaining ? "left" : "used"))
                                .font(Theme.Font.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.secondaryInk)
                            Spacer()
                        }

                        ProgressView(value: displayed)
                            .tint(tint)
                    } else {
                        Text("Unavailable")
                            .font(Theme.Font.subheadline)
                            .foregroundStyle(Theme.mutedInk)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    /// Card rendering optional model-specific weekly quotas and pay-as-you-go extra usage spend.
    private func breakdownCard(snapshot: AIProviderQuotaSnapshot) -> some View {
        let style = settings.aiQuotaDisplayStyle
        return V2Card {
            V2InsetCardContent(verticalPadding: 9) {
                VStack(alignment: .leading, spacing: 8) {
                    if !snapshot.additionalWindows.isEmpty {
                        IconSectionHeader(
                            systemName: "square.stack.3d.up",
                            title: "Model breakdown",
                            tint: Theme.aiUsage
                        )

                        ForEach(snapshot.additionalWindows, id: \.id) { window in
                            let displayed = window.displayedRatio(style: style)
                            let tint = quotaColor(for: window)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(LocalizedStringKey(window.title))
                                        .font(Theme.Font.caption.weight(.medium))
                                        .foregroundStyle(Theme.ink)
                                    Spacer()
                                    if let resetLabel = resetText(for: window.resetsAt) {
                                        Text(resetLabel)
                                            .font(Theme.Font.micro)
                                            .foregroundStyle(Theme.mutedInk)
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
                                    .font(Theme.Font.caption.weight(.semibold))
                                    .foregroundStyle(tint)
                                    .monospacedDigit()
                                }
                                ProgressView(value: displayed)
                                    .tint(tint)
                            }
                        }
                    }

                    if let extra = snapshot.extraUsage, extra.isEnabled {
                        if !snapshot.additionalWindows.isEmpty {
                            Divider().overlay(Theme.divider)
                        }
                        IconSectionHeader(
                            systemName: "creditcard",
                            title: "Extra usage",
                            tint: Theme.aiUsage
                        ) {
                            Text(formattedExtraUsage(extra))
                                .font(Theme.Font.captionMono)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }
                }
            }
        }
    }

    /// Actionable error card shown when no cached snapshot exists, including `claude /login` guidance when needed.
    private func errorCard(error: AIUsageFetchError) -> some View {
        let details = errorDetails(for: error)
        return V2Card {
            V2InsetCardContent(verticalPadding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: error.stopsAutomaticRetry ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(Theme.Font.title3.weight(.semibold))
                            .foregroundStyle(error.stopsAutomaticRetry ? Theme.critical : Theme.warning)
                            .accessibilityHidden(true)
                        Text(details.title)
                            .font(Theme.Font.callout.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }

                    Text(details.message)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)

                    if error.stopsAutomaticRetry {
                        CopyableValueRow(
                            label: "Terminal command",
                            value: "claude /login"
                        )
                    }

                    HStack {
                        Button("Retry") {
                            viewModel.refreshNow()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.aiUsage)
                        .disabled(viewModel.isRefreshing)
                        Spacer()
                    }
                }
            }
        }
    }

    /// Footer card showing the active remaining/used convention, Settings shortcut, and read-only boundary note.
    private func footerCard(snapshot: AIProviderQuotaSnapshot) -> some View {
        let style = settings.aiQuotaDisplayStyle
        return V2Card {
            V2InsetCardContent(verticalPadding: 7) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(LocalizedStringKey(style == .remaining ? "Showing remaining quota" : "Showing used quota"))
                            .font(Theme.Font.micro.weight(.medium))
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer()
                        Button("Switch in Settings") {
                            selection = .settings
                        }
                        .buttonStyle(.plain)
                        .font(Theme.Font.micro.weight(.semibold))
                        .foregroundStyle(Theme.selection)
                    }
                    Text("Read-only local OAuth · Direct to Anthropic")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.mutedInk)
                }
            }
        }
    }

    /// Tooltip text describing refresh status or the most recent successful fetch time.
    private var refreshHelp: String {
        if viewModel.isRefreshing {
            return NSLocalizedString("Refreshing AI quota…", comment: "")
        }
        if viewModel.lastError != nil {
            return NSLocalizedString("Last refresh failed", comment: "")
        }
        if let fetchedAt = viewModel.lastSuccessfulFetchAt {
            return String(
                format: NSLocalizedString("Refresh now · last updated %@", comment: ""),
                Formatters.clockTime(fetchedAt)
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

    /// Maps an `AIUsageFetchError` to a short localized summary label for the stale banner.
    private func shortErrorReason(_ error: AIUsageFetchError) -> String {
        switch error {
        case .credentialsMissing:
            return NSLocalizedString("Sign in required", comment: "")
        case .credentialsMalformed:
            return NSLocalizedString("Credentials could not be read", comment: "")
        case .tokenExpired, .unauthorized:
            return NSLocalizedString("Claude session expired", comment: "")
        case .rateLimited:
            return NSLocalizedString("Rate limited", comment: "")
        case .endpointUnavailable, .networkFailure, .decodingFailure, .disabled:
            return NSLocalizedString("Quota unavailable", comment: "")
        }
    }

    /// Maps an `AIUsageFetchError` to a localized title and remediation message for the full error card.
    private func errorDetails(for error: AIUsageFetchError) -> (title: String, message: String) {
        switch error {
        case .credentialsMissing:
            return (
                NSLocalizedString("Claude Code credentials not found", comment: ""),
                NSLocalizedString("Sign in with Claude Code in Terminal, then retry.", comment: "")
            )
        case .tokenExpired, .unauthorized:
            return (
                NSLocalizedString("Claude session expired", comment: ""),
                NSLocalizedString("Run claude /login in Terminal to refresh your session, then retry.", comment: "")
            )
        case .credentialsMalformed:
            return (
                NSLocalizedString("Credentials could not be read", comment: ""),
                NSLocalizedString("Run claude /login in Terminal to regenerate valid credentials, then retry.", comment: "")
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
            return (NSLocalizedString("Rate limited by Anthropic", comment: ""), message)
        case .endpointUnavailable(let statusCode):
            return (
                String(
                    format: NSLocalizedString("Anthropic usage endpoint unavailable (HTTP %lld)", comment: ""),
                    Int64(statusCode)
                ),
                NSLocalizedString("Unable to reach Anthropic", comment: "")
            )
        case .networkFailure, .decodingFailure, .disabled:
            return (
                NSLocalizedString("Unable to reach Anthropic", comment: ""),
                NSLocalizedString("Quota unavailable", comment: "")
            )
        }
    }
}
