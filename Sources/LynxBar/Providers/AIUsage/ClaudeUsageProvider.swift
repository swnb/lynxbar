import Foundation

/// Queries Anthropic's Claude OAuth usage endpoint using strictly read-only local credentials.
actor ClaudeUsageProvider: AIUsageProvider {
    static let defaultEndpointURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let anthropicBetaHeaderValue = "oauth-2025-04-20"

    nonisolated let id: AIUsageProviderID = .claude

    private let credentialReader: any ClaudeCredentialReading
    private let transport: any AIUsageHTTPTransport
    private let endpointURL: URL
    private let userAgentVersion: String

    /// Creates a Claude quota provider with injectable credential reader, HTTP transport, endpoint, and version.
    init(
        credentialReader: any ClaudeCredentialReading = ClaudeCredentialReader(),
        transport: any AIUsageHTTPTransport = AIUsageHTTPClient(),
        endpointURL: URL = ClaudeUsageProvider.defaultEndpointURL,
        userAgentVersion: String = ClaudeUsageProvider.defaultBundleVersion()
    ) {
        self.credentialReader = credentialReader
        self.transport = transport
        self.endpointURL = endpointURL
        self.userAgentVersion = userAgentVersion
    }

    /// Reads local OAuth credentials and requests current Claude usage windows from Anthropic.
    func fetchQuota(now: Date = Date()) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        let credentials: ClaudeOAuthCredentials
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
        request.setValue(Self.anthropicBetaHeaderValue, forHTTPHeaderField: "anthropic-beta")
        request.setValue("LynxBar/\(userAgentVersion)", forHTTPHeaderField: "User-Agent")

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
                "Claude usage request failed: \(error.localizedDescription, privacy: .private)"
            )
            return .failure(.networkFailure(error.localizedDescription))
        }

        switch response.statusCode {
        case 200:
            return decodeSnapshot(from: data, credentials: credentials, fetchedAt: now)
        case 401, 403:
            Log.aiUsage.notice("Claude usage request rejected with HTTP \(response.statusCode, privacy: .public)")
            return .failure(.unauthorized)
        case 429:
            let retryAfter = Self.parseRetryAfter(
                response.value(forHTTPHeaderField: "Retry-After"),
                now: now
            )
            Log.aiUsage.notice("Claude usage request rate limited (HTTP 429)")
            return .failure(.rateLimited(retryAfter: retryAfter))
        default:
            Log.aiUsage.warning("Claude usage endpoint returned HTTP \(response.statusCode, privacy: .public)")
            return .failure(.endpointUnavailable(statusCode: response.statusCode))
        }
    }

    /// Parses a `Retry-After` HTTP header containing either integer/decimal seconds or an HTTP-date.
    static func parseRetryAfter(_ headerValue: String?, now: Date) -> TimeInterval? {
        guard let raw = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw), seconds.isFinite, seconds > 0 {
            return seconds
        }

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let retryDate = formatter.date(from: raw) {
                let delta = retryDate.timeIntervalSince(now)
                return delta > 0 ? delta : nil
            }
        }
        return nil
    }

    /// Reads `CFBundleShortVersionString` from the main bundle for the `User-Agent` header.
    nonisolated static func defaultBundleVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    /// Decodes Anthropic's tolerant usage payload into an `AIProviderQuotaSnapshot`.
    private func decodeSnapshot(
        from data: Data,
        credentials: ClaudeOAuthCredentials,
        fetchedAt: Date
    ) -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        let payload: UsageResponse
        do {
            payload = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            Log.aiUsage.warning("Failed to decode Claude usage response JSON")
            return .failure(.decodingFailure("Invalid usage response payload"))
        }

        let primary = makeWindow(
            id: "five_hour",
            kind: .session5h,
            title: "5-hour session",
            payload: payload.fiveHour
        )
        let secondary = makeWindow(
            id: "seven_day",
            kind: .weekly7d,
            title: "7-day weekly",
            payload: payload.sevenDay
        )

        guard primary != nil || secondary != nil else {
            Log.aiUsage.warning("Claude usage response omitted both five_hour and seven_day windows")
            return .failure(.decodingFailure("Missing primary and secondary quota windows"))
        }

        let modelSpecs: [(String, String, WindowPayload?)] = [
            ("seven_day_sonnet", "Sonnet 7-day", payload.sevenDaySonnet),
            ("seven_day_opus", "Opus 7-day", payload.sevenDayOpus),
            ("seven_day_oauth_apps", "OAuth apps 7-day", payload.sevenDayOauthApps),
            ("seven_day_cowork", "Cowork 7-day", payload.sevenDayCowork),
        ]
        let additional = modelSpecs.compactMap { id, title, windowPayload in
            makeWindow(
                id: id,
                kind: .weeklyModelSpecific,
                title: title,
                payload: windowPayload
            )
        }

        let extraUsage: AIExtraUsageSummary? = {
            guard let extra = payload.extraUsage, extra.isEnabled == true else { return nil }
            let used = extra.usedCredits.flatMap { $0.isFinite ? $0 : nil }
            let limit = extra.monthlyLimit.flatMap { $0.isFinite ? $0 : nil }
            let currency = extra.currency?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let currencyCode = (currency?.isEmpty == false ? currency! : "USD")
            return AIExtraUsageSummary(
                isEnabled: true,
                usedAmount: used,
                monthlyLimit: limit,
                currencyCode: currencyCode
            )
        }()

        let snapshot = AIProviderQuotaSnapshot(
            providerID: .claude,
            primaryWindow: primary,
            secondaryWindow: secondary,
            additionalWindows: additional,
            extraUsage: extraUsage,
            planLabel: Self.derivePlanLabel(
                subscriptionType: credentials.subscriptionType,
                rateLimitTier: credentials.rateLimitTier
            ),
            fetchedAt: fetchedAt
        )
        return .success(snapshot)
    }

    /// Normalizes a `0...100` utilization percentage into a clamped `0...1` `AIQuotaWindow`.
    private func makeWindow(
        id: String,
        kind: AIQuotaWindow.Kind,
        title: String,
        payload: WindowPayload?
    ) -> AIQuotaWindow? {
        guard let payload,
              let rawUtilization = payload.utilization,
              rawUtilization.isFinite,
              !rawUtilization.isNaN else {
            return nil
        }
        let normalized = min(max(rawUtilization / 100.0, 0), 1)
        return AIQuotaWindow(
            id: id,
            kind: kind,
            title: title,
            usedRatio: normalized,
            resetsAt: Self.parseISO8601Date(payload.resetsAt)
        )
    }

    /// Parses an ISO-8601 timestamp supporting both fractional and non-fractional seconds.
    static func parseISO8601Date(_ string: String?) -> Date? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed) {
            return date
        }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(trimmed)
    }

    /// Derives a concise plan badge label from credential tier metadata when available.
    static func derivePlanLabel(subscriptionType: String?, rateLimitTier: String?) -> String? {
        let candidates = [subscriptionType, rateLimitTier]
        for candidate in candidates {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            let lower = raw.lowercased()
            if lower.contains("max") { return "Max" }
            if lower.contains("pro") { return "Pro" }
            if lower.contains("team") { return "Team" }
            if lower.contains("enterprise") { return "Enterprise" }
        }
        if let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let lower = raw.lowercased()
            if lower != "default" && lower != "none" && lower != "free" {
                return raw.capitalized
            }
        }
        return nil
    }
}

/// JSON response payload returned by Anthropic's OAuth usage endpoint.
private struct UsageResponse: Decodable {
    let fiveHour: WindowPayload?
    let sevenDay: WindowPayload?
    let sevenDaySonnet: WindowPayload?
    let sevenDayOpus: WindowPayload?
    let sevenDayOauthApps: WindowPayload?
    let sevenDayCowork: WindowPayload?
    let extraUsage: ExtraUsagePayload?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayCowork = "seven_day_cowork"
        case extraUsage = "extra_usage"
    }
}

/// Decodable utilization and reset timestamp pair for a single quota window.
private struct WindowPayload: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// Decodable pay-as-you-go extra-usage fields from Anthropic's usage payload.
private struct ExtraUsagePayload: Decodable {
    let isEnabled: Bool?
    let usedCredits: Double?
    let monthlyLimit: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case usedCredits = "used_credits"
        case monthlyLimit = "monthly_limit"
        case currency
    }
}
