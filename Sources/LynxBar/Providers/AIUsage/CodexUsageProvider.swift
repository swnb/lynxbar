import Foundation

/// Queries ChatGPT's Codex usage endpoint using strictly read-only local Codex CLI OAuth credentials.
actor CodexUsageProvider: AIUsageProvider {
    static let defaultEndpointURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    nonisolated let id: AIUsageProviderID = .codex

    private let credentialReader: any CodexCredentialReading
    private let transport: any AIUsageHTTPTransport
    private let endpointURL: URL
    private let userAgentVersion: String

    /// Creates a Codex quota provider with injectable credential reader, HTTP transport, endpoint, and version.
    init(
        credentialReader: any CodexCredentialReading = CodexCredentialReader(),
        transport: any AIUsageHTTPTransport = AIUsageHTTPClient(),
        endpointURL: URL = CodexUsageProvider.defaultEndpointURL,
        userAgentVersion: String = AIUsageParsing.defaultBundleVersion()
    ) {
        self.credentialReader = credentialReader
        self.transport = transport
        self.endpointURL = endpointURL
        self.userAgentVersion = userAgentVersion
    }

    /// Reads local Codex OAuth credentials and requests current Codex rate-limit windows and credits.
    func fetchQuota(now: Date = Date()) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        let credentials: CodexOAuthCredentials
        switch credentialReader.readCredentials(now: now) {
        case .success(let value):
            credentials = value
        case .failure(let error):
            return .failure(error)
        }

        var request = URLRequest(
            url: endpointURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: AIUsageHTTPClient.defaultTimeout
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LynxBar/\(userAgentVersion)", forHTTPHeaderField: "User-Agent")
        if let accountId = AIUsageParsing.nonEmptyTrimmed(credentials.accountId) {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            return .failure(.networkFailure("Cancelled"))
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .failure(.networkFailure("Cancelled"))
        } catch {
            Log.aiUsage.warning(
                "Codex usage request failed: \(error.localizedDescription, privacy: .private)"
            )
            return .failure(.networkFailure(error.localizedDescription))
        }

        switch response.statusCode {
        case 200:
            return decodeSnapshot(from: data, credentials: credentials, fetchedAt: now)
        case 401, 403:
            Log.aiUsage.notice("Codex usage request rejected with HTTP \(response.statusCode, privacy: .public)")
            return .failure(.unauthorized)
        case 429:
            let retryAfter = AIUsageParsing.parseRetryAfter(
                response.value(forHTTPHeaderField: "Retry-After"),
                now: now
            )
            Log.aiUsage.notice("Codex usage request rate limited (HTTP 429)")
            return .failure(.rateLimited(retryAfter: retryAfter))
        default:
            Log.aiUsage.warning("Codex usage endpoint returned HTTP \(response.statusCode, privacy: .public)")
            return .failure(.endpointUnavailable(statusCode: response.statusCode))
        }
    }

    /// Maps raw Codex `plan_type` strings to human-readable subscription badges.
    static func derivePlanLabel(_ rawPlanType: String?) -> String? {
        guard let trimmed = AIUsageParsing.nonEmptyTrimmed(rawPlanType) else { return nil }
        switch trimmed.lowercased() {
        case "free":
            return "Free"
        case "plus":
            return "Plus"
        case "pro":
            return "Pro"
        case "team":
            return "Team"
        case "enterprise":
            return "Enterprise"
        default:
            return trimmed.capitalized
        }
    }

    /// Decodes the Codex `wham/usage` response payload into a normalized `AIProviderQuotaSnapshot`.
    private func decodeSnapshot(
        from data: Data,
        credentials: CodexOAuthCredentials,
        fetchedAt: Date
    ) -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        let payload: CodexUsageResponse
        do {
            payload = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        } catch {
            Log.aiUsage.warning("Failed to decode Codex usage response JSON")
            return .failure(.decodingFailure("Invalid Codex usage response payload"))
        }

        let primaryWindow = makeWindow(
            id: "codex-primary",
            defaultKind: .session5h,
            defaultTitle: "5-hour session",
            payload: payload.rateLimit?.primaryWindow,
            now: fetchedAt
        )
        let secondaryWindow = makeWindow(
            id: "codex-secondary",
            defaultKind: .weekly7d,
            defaultTitle: "7-day weekly",
            payload: payload.rateLimit?.secondaryWindow,
            now: fetchedAt
        )

        var additionalWindows: [AIQuotaWindow] = []

        if let codeReviewPrimary = makeFixedKindWindow(
            id: "codex-code-review",
            kind: .codeReview,
            title: "Code Review",
            payload: payload.codeReviewRateLimit?.primaryWindow,
            now: fetchedAt
        ) {
            additionalWindows.append(codeReviewPrimary)
        }

        if let additionalLimits = payload.additionalRateLimits {
            for (index, item) in additionalLimits.enumerated() {
                let baseTitle = AIUsageParsing.nonEmptyTrimmed(item.limitName)
                    ?? AIUsageParsing.nonEmptyTrimmed(item.meteredFeature)
                    ?? "Model Quota"

                let pWindow = item.rateLimit?.primaryWindow
                let sWindow = item.rateLimit?.secondaryWindow

                let decodedPrimary = pWindow.flatMap { windowPayload in
                    let title = sWindow != nil
                        ? "\(baseTitle) (\(windowDurationLabel(windowPayload.limitWindowSeconds, fallback: "Primary")))"
                        : baseTitle
                    return makeFixedKindWindow(
                        id: sWindow != nil ? "codex-additional-\(index)-primary" : "codex-additional-\(index)",
                        kind: .modelQuota,
                        title: title,
                        payload: windowPayload,
                        now: fetchedAt
                    )
                }

                let decodedSecondary = sWindow.flatMap { windowPayload in
                    let title = pWindow != nil
                        ? "\(baseTitle) (\(windowDurationLabel(windowPayload.limitWindowSeconds, fallback: "Secondary")))"
                        : baseTitle
                    return makeFixedKindWindow(
                        id: pWindow != nil ? "codex-additional-\(index)-secondary" : "codex-additional-\(index)",
                        kind: .modelQuota,
                        title: title,
                        payload: windowPayload,
                        now: fetchedAt
                    )
                }

                if let decodedPrimary {
                    additionalWindows.append(decodedPrimary)
                }
                if let decodedSecondary {
                    additionalWindows.append(decodedSecondary)
                }
            }
        }

        let credits = payload.credits.map(makeCreditsSummary)

        guard primaryWindow != nil || secondaryWindow != nil || !additionalWindows.isEmpty || credits != nil else {
            Log.aiUsage.warning("Codex usage response contained no valid quota windows or credits")
            return .failure(.decodingFailure("Missing Codex quota windows and credits"))
        }

        let planLabel = Self.derivePlanLabel(
            AIUsageParsing.nonEmptyTrimmed(payload.planType) ?? credentials.planType
        )

        let snapshot = AIProviderQuotaSnapshot(
            providerID: .codex,
            primaryWindow: primaryWindow,
            secondaryWindow: secondaryWindow,
            additionalWindows: additionalWindows,
            extraUsage: nil,
            planLabel: planLabel,
            credits: credits,
            accountLabel: credentials.accountEmail,
            fetchedAt: fetchedAt
        )
        return .success(snapshot)
    }

    /// Decodes a Codex rate-limit window while inferring `.session5h`, `.weekly7d`, or `.modelQuota` from duration.
    private func makeWindow(
        id: String,
        defaultKind: AIQuotaWindow.Kind,
        defaultTitle: String,
        payload: CodexWindowPayload?,
        now: Date
    ) -> AIQuotaWindow? {
        guard let payload,
              let usedRatio = AIUsageParsing.normalizedRatio(fromPercent: payload.usedPercent) else {
            return nil
        }

        let (kind, title) = inferKindAndTitle(
            limitWindowSeconds: payload.limitWindowSeconds,
            defaultKind: defaultKind,
            defaultTitle: defaultTitle
        )

        return AIQuotaWindow(
            id: id,
            kind: kind,
            title: title,
            usedRatio: usedRatio,
            resetsAt: resolveResetDate(from: payload, now: now)
        )
    }

    /// Decodes a Codex window using an explicit `AIQuotaWindow.Kind` and title.
    private func makeFixedKindWindow(
        id: String,
        kind: AIQuotaWindow.Kind,
        title: String,
        payload: CodexWindowPayload?,
        now: Date
    ) -> AIQuotaWindow? {
        guard let payload,
              let usedRatio = AIUsageParsing.normalizedRatio(fromPercent: payload.usedPercent) else {
            return nil
        }

        return AIQuotaWindow(
            id: id,
            kind: kind,
            title: title,
            usedRatio: usedRatio,
            resetsAt: resolveResetDate(from: payload, now: now)
        )
    }

    /// Resolves reset timestamp from `reset_at` or falls back to `now + reset_after_seconds`.
    private func resolveResetDate(from payload: CodexWindowPayload, now: Date) -> Date? {
        if let resetAt = payload.resetAt?.resolvedDate {
            return resetAt
        }
        if let resetAfter = payload.resetAfterSeconds, resetAfter.isFinite, resetAfter >= 0 {
            return now.addingTimeInterval(resetAfter)
        }
        return nil
    }

    /// Infers normalized window kind and display title from `limit_window_seconds`.
    private func inferKindAndTitle(
        limitWindowSeconds: Double?,
        defaultKind: AIQuotaWindow.Kind,
        defaultTitle: String
    ) -> (AIQuotaWindow.Kind, String) {
        guard let seconds = limitWindowSeconds, seconds.isFinite, seconds > 0 else {
            return (defaultKind, defaultTitle)
        }
        if abs(seconds - 18_000) <= 3_600 {
            return (.session5h, "5-hour session")
        }
        if abs(seconds - 604_800) <= 86_400 {
            return (.weekly7d, "7-day weekly")
        }
        return (.modelQuota, "\(windowDurationLabel(seconds, fallback: defaultTitle)) window")
    }

    /// Formats a positive finite window duration in seconds (within `Int` range) into a concise label
    /// such as `"7-day"`, `"5-hour"`, `"15m"`, or `"30s"`, returning `fallback` for invalid or out-of-range values.
    private func windowDurationLabel(_ seconds: Double?, fallback: String) -> String {
        guard let seconds,
              seconds.isFinite,
              seconds > 0,
              seconds.rounded() < Double(Int.max),
              let rounded = Int(exactly: seconds.rounded()) else {
            return fallback
        }
        if rounded >= 86_400 && rounded % 86_400 == 0 {
            return "\(rounded / 86_400)-day"
        }
        if rounded >= 3_600 && rounded % 3_600 == 0 {
            return "\(rounded / 3_600)-hour"
        }
        if rounded >= 60 {
            return "\(rounded / 60)m"
        }
        return "\(rounded)s"
    }

    /// Maps Codex's flexible `credits` payload (string, number, or null balance) to `AIProviderCreditsSummary`.
    private func makeCreditsSummary(from payload: CodexCreditsPayload) -> AIProviderCreditsSummary {
        var balanceText: String?
        var balanceAmount: Double?

        if let balance = payload.balance {
            switch balance {
            case .string(let rawText):
                if let trimmed = AIUsageParsing.nonEmptyTrimmed(rawText) {
                    balanceText = trimmed
                    if let parsed = Double(trimmed), parsed.isFinite {
                        balanceAmount = parsed
                    }
                }
            case .number(let numeric):
                if numeric.isFinite {
                    balanceAmount = numeric
                    balanceText = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), numeric)
                }
            }
        }

        return AIProviderCreditsSummary(
            hasCredits: payload.hasCredits ?? false,
            unlimited: payload.unlimited ?? false,
            balanceText: balanceText,
            balanceAmount: balanceAmount
        )
    }
}

/// Top-level JSON response payload returned by ChatGPT's Codex `wham/usage` endpoint.
private struct CodexUsageResponse: Decodable {
    let planType: String?
    let rateLimit: CodexRateLimitPayload?
    let codeReviewRateLimit: CodexRateLimitPayload?
    let additionalRateLimits: [CodexAdditionalRateLimitPayload]?
    let credits: CodexCreditsPayload?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
    }
}

/// Primary and secondary window pair returned inside Codex rate-limit objects.
private struct CodexRateLimitPayload: Decodable {
    let primaryWindow: CodexWindowPayload?
    let secondaryWindow: CodexWindowPayload?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

/// Additional model-specific or metered feature rate-limit entry returned by Codex.
private struct CodexAdditionalRateLimitPayload: Decodable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: CodexRateLimitPayload?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }
}

/// Single Codex quota window containing percentage used, duration, and reset timing.
private struct CodexWindowPayload: Decodable {
    let usedPercent: Double?
    let limitWindowSeconds: Double?
    let resetAfterSeconds: Double?
    let resetAt: AIUsageFlexibleTimestamp?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

/// Credits balance payload returned by Codex (`balance` may be a string, number, or null).
private struct CodexCreditsPayload: Decodable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: FlexibleBalanceValue?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}

/// Decodable balance field accepting either a JSON string or JSON number.
private enum FlexibleBalanceValue: Decodable {
    case string(String)
    case number(Double)

    /// Decodes a string or numeric credit balance value.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .string(text)
            return
        }
        if let numeric = try? container.decode(Double.self) {
            self = .number(numeric)
            return
        }
        if let integer = try? container.decode(Int64.self) {
            self = .number(Double(integer))
            return
        }
        throw DecodingError.typeMismatch(
            FlexibleBalanceValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected string or numeric balance"
            )
        )
    }
}
