import Foundation

/// Supported AI subscription quota providers. Raw values are persisted in Settings.
enum AIUsageProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex
    case antigravity

    /// Stable `Identifiable` identifier matching the provider raw value.
    var id: Self { self }

    /// Human-readable display name for UI labels and accessibility announcements.
    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "OpenAI Codex"
        case .antigravity:
            return "Antigravity"
        }
    }

    /// Concise provider name suitable for compact UI rows and badges.
    var shortName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .antigravity:
            return "Antigravity"
        }
    }

    /// Terminal command users run to authenticate or refresh this provider's local CLI session.
    var cliLoginCommand: String {
        switch self {
        case .claude:
            return "claude /login"
        case .codex:
            return "codex login"
        case .antigravity:
            return "agy login"
        }
    }

    /// SF Symbol name representing this provider in dashboard cards and menus.
    var symbolName: String {
        switch self {
        case .claude:
            return "sparkles"
        case .codex:
            return "terminal"
        case .antigravity:
            return "diamond"
        }
    }
}

/// User-selectable percentage convention for AI quota progress bars and menu bar text.
enum AIQuotaDisplayStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Displays remaining capacity before reset (e.g., "78% left").
    case remaining
    /// Displays consumed capacity in the current window (e.g., "22% used").
    case used

    /// Stable `Identifiable` identifier matching the display style raw value.
    var id: Self { self }

    /// Decodes a persisted raw string, falling back to `.remaining` when missing or unknown.
    static func validated(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .remaining
    }
}

/// A single rolling rate-limit window reported by an AI subscription provider.
struct AIQuotaWindow: Equatable, Sendable {
    /// Semantic role of a quota window within the provider's rate-limit model.
    enum Kind: String, Equatable, Sendable {
        case session5h
        case weekly7d
        case weeklyModelSpecific
        case codeReview
        case modelQuota
    }

    let id: String
    let kind: Kind
    /// Localization key or provider-supplied label (e.g., "5-hour session", "7-day weekly").
    let title: String
    /// Raw utilization ratio clamped to `0...1` (e.g., `0.22` means 22% used).
    let usedRatio: Double
    /// Exact reset timestamp if reported by the provider.
    let resetsAt: Date?

    /// Creates a quota window while clamping `usedRatio` defensively into `0...1`.
    init(
        id: String,
        kind: Kind,
        title: String,
        usedRatio: Double,
        resetsAt: Date?
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        if usedRatio.isFinite {
            self.usedRatio = min(max(usedRatio, 0), 1)
        } else {
            self.usedRatio = 0
        }
        self.resetsAt = resetsAt
    }

    /// Remaining capacity ratio in `0...1` (`1.0 - usedRatio`).
    var remainingRatio: Double {
        max(0, min(1, 1.0 - usedRatio))
    }

    /// Returns either `remainingRatio` or `usedRatio` according to the requested display style.
    func displayedRatio(style: AIQuotaDisplayStyle) -> Double {
        switch style {
        case .remaining: return remainingRatio
        case .used: return usedRatio
        }
    }
}

/// Optional pay-as-you-go or overage spend summary reported alongside subscription windows.
struct AIExtraUsageSummary: Equatable, Sendable {
    /// Indicates whether pay-as-you-go extra usage is enabled on the account.
    let isEnabled: Bool
    /// Accrued extra-usage spend in `currencyCode`, if reported.
    let usedAmount: Double?
    /// Configured monthly extra-usage spend limit in `currencyCode`, if any.
    let monthlyLimit: Double?
    /// ISO 4217 currency code for extra-usage amounts (defaults to `"USD"`).
    let currencyCode: String
}

/// Optional credits balance summary reported by providers with prepaid or credit-based overages.
struct AIProviderCreditsSummary: Equatable, Sendable {
    /// Indicates whether the account has a credits balance available.
    let hasCredits: Bool
    /// Indicates whether the account has unlimited credits.
    let unlimited: Bool
    /// Raw or formatted textual representation of the remaining balance, if provided.
    let balanceText: String?
    /// Numeric credit balance when parseable as a finite `Double`.
    let balanceAmount: Double?

    /// Creates a credits summary while filtering out non-finite numeric balances.
    init(
        hasCredits: Bool,
        unlimited: Bool,
        balanceText: String? = nil,
        balanceAmount: Double? = nil
    ) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        let trimmed = balanceText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.balanceText = (trimmed?.isEmpty == false) ? trimmed : nil
        if let balanceAmount, balanceAmount.isFinite {
            self.balanceAmount = balanceAmount
        } else {
            self.balanceAmount = nil
        }
    }
}

/// Immutable quota snapshot returned by an `AIUsageProvider`.
struct AIProviderQuotaSnapshot: Equatable, Sendable {
    let providerID: AIUsageProviderID
    /// Primary quota window (e.g., 5-hour session for Claude/Codex, or Gemini Pro) driving menu bar and Overview summaries.
    let primaryWindow: AIQuotaWindow?
    /// Secondary quota window (e.g., 7-day weekly for Claude/Codex, or Gemini Flash).
    let secondaryWindow: AIQuotaWindow?
    /// Optional breakdown windows (e.g., model-specific, code-review, or additional model quotas) when returned.
    let additionalWindows: [AIQuotaWindow]
    let extraUsage: AIExtraUsageSummary?
    /// Optional credits balance summary reported alongside quota windows (e.g., OpenAI Codex).
    let credits: AIProviderCreditsSummary?
    /// Optional subscription tier label derived from credential metadata or API tier info (e.g., "Pro", "Max").
    let planLabel: String?
    /// Optional non-secret account identifier such as the signed-in email address.
    let accountLabel: String?
    /// Timestamp when this snapshot was successfully fetched.
    let fetchedAt: Date

    /// Creates a normalized quota snapshot with defaults for optional provider-specific fields.
    init(
        providerID: AIUsageProviderID,
        primaryWindow: AIQuotaWindow? = nil,
        secondaryWindow: AIQuotaWindow? = nil,
        additionalWindows: [AIQuotaWindow] = [],
        extraUsage: AIExtraUsageSummary? = nil,
        planLabel: String? = nil,
        credits: AIProviderCreditsSummary? = nil,
        accountLabel: String? = nil,
        fetchedAt: Date
    ) {
        self.providerID = providerID
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
        self.additionalWindows = additionalWindows
        self.extraUsage = extraUsage
        self.planLabel = planLabel
        self.credits = credits
        self.accountLabel = accountLabel
        self.fetchedAt = fetchedAt
    }
}

/// Explicit failure taxonomy so the UI can render actionable remediation instead of opaque errors.
enum AIUsageFetchError: Error, Equatable, Sendable {
    case disabled
    case credentialsMissing
    case credentialsMalformed
    case tokenExpired
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case endpointUnavailable(statusCode: Int)
    case networkFailure(String)
    case decodingFailure(String)

    /// Returns `true` when background auto-retry must stop until the user intervenes or re-opens the panel.
    var stopsAutomaticRetry: Bool {
        switch self {
        case .disabled, .credentialsMissing, .credentialsMalformed, .tokenExpired, .unauthorized:
            return true
        case .rateLimited, .endpointUnavailable, .networkFailure, .decodingFailure:
            return false
        }
    }
}

/// Read-only OAuth credentials extracted from local Claude Code storage.
/// Conforms to `CustomStringConvertible` and `CustomDebugStringConvertible` with redacted token output
/// so formatting or debugging never leaks secret material.
struct ClaudeOAuthCredentials: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Bearer OAuth access token read from local Claude Code storage.
    let accessToken: String
    /// Token expiration timestamp used for local pre-flight validity checks.
    let expiresAt: Date?
    /// Raw subscription tier string from credential metadata (e.g., `"pro"`, `"max"`).
    let subscriptionType: String?
    /// Raw rate-limit tier identifier from credential metadata, if present.
    let rateLimitTier: String?

    /// Redacted textual description that never exposes `accessToken`.
    var description: String {
        "ClaudeOAuthCredentials(accessToken: [REDACTED], expiresAt: \(String(describing: expiresAt)), subscriptionType: \(subscriptionType ?? "nil"))"
    }

    /// Redacted debug description delegating to `description`.
    var debugDescription: String {
        description
    }
}

/// Protocol implemented by each AI subscription quota provider.
protocol AIUsageProvider: Sendable {
    /// Unique identifier of the AI quota provider.
    var id: AIUsageProviderID { get }

    /// Fetches the current subscription quota snapshot at `now`.
    func fetchQuota(now: Date) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError>
}
