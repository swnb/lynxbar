import Foundation

/// Supported AI subscription quota providers. Raw values are persisted in Settings.
enum AIUsageProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude

    /// Stable `Identifiable` identifier matching the provider raw value.
    var id: Self { self }
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

/// Immutable quota snapshot returned by an `AIUsageProvider`.
struct AIProviderQuotaSnapshot: Equatable, Sendable {
    let providerID: AIUsageProviderID
    /// Primary rolling window (Claude: 5-hour session) driving menu bar and Overview summaries.
    let primaryWindow: AIQuotaWindow?
    /// Secondary rolling window (Claude: 7-day weekly).
    let secondaryWindow: AIQuotaWindow?
    /// Optional breakdown windows (e.g., model-specific 7-day quotas) when returned.
    let additionalWindows: [AIQuotaWindow]
    let extraUsage: AIExtraUsageSummary?
    /// Optional subscription tier label derived from credential metadata (e.g., "Pro", "Max").
    let planLabel: String?
    /// Timestamp when this snapshot was successfully fetched.
    let fetchedAt: Date
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
