import SwiftUI

/// Compact 36pt Overview summary row showing Claude's 5-hour quota window and jumping to the AI tab on click.
struct OverviewAIQuotaRow: View {
    @ObservedObject var aiUsage: AIUsageViewModel
    @Binding var selection: DashboardSection
    @ObservedObject private var settings = Settings.shared
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        V2Card {
            Button {
                selection = .aiUsage
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(Theme.Font.callout.weight(.semibold))
                        .foregroundStyle(leadingTint)
                        .frame(width: 14)
                        .accessibilityHidden(true)

                    Text("Claude")
                        .font(Theme.Font.caption.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    statusContent

                    Image(systemName: "chevron.right")
                        .font(Theme.Font.micro.weight(.semibold))
                        .foregroundStyle(Theme.mutedInk)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .v2InteractiveSurface()
                .background(isHovered ? Theme.hoverFill : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .stroke(Theme.selection, lineWidth: 2)
                            .padding(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .onHover { isHovered = $0 }
            .accessibilityLabel(NSLocalizedString("Claude AI quota", comment: ""))
            .accessibilityValue(accessibilityValueText)
            .accessibilityHint(NSLocalizedString("Open AI quota details", comment: ""))
        }
        .frame(height: OverviewLayoutMetrics.aiQuotaRowHeight)
    }

    /// Trailing status view showing the primary quota bar/percentage, error indicator, or loading text.
    @ViewBuilder
    private var statusContent: some View {
        if let snapshot = aiUsage.currentSnapshot, let primary = snapshot.primaryWindow {
            let style = settings.aiQuotaDisplayStyle
            let displayed = primary.displayedRatio(style: style)
            let percent = Int((min(max(displayed, 0), 1) * 100).rounded())
            let color = quotaColor(for: primary)

            HStack(spacing: 6) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.raisedStrong)
                        Capsule()
                            .fill(color)
                            .frame(width: max(3, proxy.size.width * CGFloat(displayed)))
                    }
                }
                .frame(width: 44, height: 5)
                .accessibilityHidden(true)

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
                .lineLimit(1)

                if aiUsage.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Font.micro.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                } else if let resetsAt = primary.resetsAt {
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
        } else if let error = aiUsage.lastError {
            Text(LocalizedStringKey(errorSummaryKey(error)))
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

    /// Leading icon tint reflecting current quota health or error severity.
    private var leadingTint: Color {
        if let primary = aiUsage.currentSnapshot?.primaryWindow {
            return quotaColor(for: primary)
        }
        if let error = aiUsage.lastError {
            return error.stopsAutomaticRetry ? Theme.critical : Theme.warning
        }
        return Theme.aiUsage
    }

    /// Localized VoiceOver value summarizing the current quota percentage or fetch state.
    private var accessibilityValueText: String {
        if let primary = aiUsage.currentSnapshot?.primaryWindow {
            let style = settings.aiQuotaDisplayStyle
            let percent = Int((min(max(primary.displayedRatio(style: style), 0), 1) * 100).rounded())
            return String(
                format: NSLocalizedString(
                    style == .remaining ? "%lld%% left" : "%lld%% used",
                    comment: ""
                ),
                Int64(percent)
            )
        }
        if let error = aiUsage.lastError {
            return NSLocalizedString(errorSummaryKey(error), comment: "")
        }
        return NSLocalizedString("Checking quota…", comment: "")
    }

    /// Maps remaining capacity to green (`>30%`), amber (`10%...30%`), or red (`<=10%`).
    private func quotaColor(for window: AIQuotaWindow) -> Color {
        if window.remainingRatio <= 0.10 { return Theme.critical }
        if window.remainingRatio <= 0.30 { return Theme.warning }
        return Theme.health
    }

    /// Maps an `AIUsageFetchError` to a concise localization key for the compact row.
    private func errorSummaryKey(_ error: AIUsageFetchError) -> String {
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
