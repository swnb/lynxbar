import CodexBarCore
import Foundation

/// Adapts `CodexBarCore` (MIT) provider pipelines to LynxBar's `AIUsageProvider` protocol
/// for Claude, OpenAI Codex, and Antigravity subscriptions.
///
/// Privacy & Lifecycle Boundaries:
/// - Browser cookie scraping is explicitly disabled (`cookieSource = .off`, `webExtrasEnabled = false`,
///   `desktopCookiesEnabled = false`).
/// - Claude uses `.oauth` only; Codex uses `.auto` (`[pat, oauth, cli]`, never web);
///   Antigravity uses `.auto` (local app/CLI/IDE/OAuth/offline probes, never web).
/// - Upstream fetching is injected via `UpstreamFetch` so all unit tests run 100% offline.
actor CodexBarUsageProvider: AIUsageProvider {
    typealias UpstreamFetch = @Sendable (UsageProvider, ProviderFetchContext) async -> ProviderFetchOutcome

    nonisolated let id: AIUsageProviderID

    private let upstreamProvider: UsageProvider
    private let environment: [String: String]
    private let upstreamFetch: UpstreamFetch

    /// Creates an adapter backed by `CodexBarCore` for `providerID`, with an injectable upstream fetcher for offline tests.
    init(
        providerID: AIUsageProviderID,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        upstreamFetch: @escaping UpstreamFetch = CodexBarUsageProvider.liveFetch(provider:context:)
    ) {
        self.id = providerID
        self.upstreamProvider = Self.mapProviderID(providerID)
        self.environment = environment
        self.upstreamFetch = upstreamFetch
    }

    /// Invokes the configured `CodexBarCore` pipeline and maps its snapshot or error into LynxBar's models.
    func fetchQuota(now: Date = Date()) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        let context = Self.makeFetchContext(for: id, environment: environment)
        let outcome = await upstreamFetch(upstreamProvider, context)

        switch outcome.result {
        case .success(let fetchResult):
            let mapped = Self.mapSnapshot(
                fetchResult: fetchResult,
                attempts: outcome.attempts,
                providerID: id,
                upstreamProvider: upstreamProvider,
                fetchedAt: now
            )
            if case .failure = mapped {
                let attemptSummary = Self.formatAttemptsForLog(outcome.attempts)
                Log.aiUsage.notice(
                    "CodexBarCore returned non-quota result for \(self.id.rawValue, privacy: .public) via \(fetchResult.strategyID, privacy: .public); attempts=\(attemptSummary, privacy: .public)"
                )
            }
            return mapped
        case .failure(let error):
            let attemptSummary = Self.formatAttemptsForLog(outcome.attempts)
            Log.aiUsage.notice(
                "CodexBarCore fetch failed for \(self.id.rawValue, privacy: .public); attempts=\(attemptSummary, privacy: .public); error=\(error.localizedDescription, privacy: .private)"
            )
            return .failure(Self.mapError(error))
        }
    }

    /// Maps LynxBar's `AIUsageProviderID` to `CodexBarCore.UsageProvider`.
    nonisolated static func mapProviderID(_ providerID: AIUsageProviderID) -> UsageProvider {
        switch providerID {
        case .claude:
            return .claude
        case .codex:
            return .codex
        case .antigravity:
            return .antigravity
        }
    }

    /// Builds a privacy-hardened `ProviderFetchContext` that explicitly disables browser cookie extraction.
    nonisolated static func makeFetchContext(
        for providerID: AIUsageProviderID,
        environment: [String: String]
    ) -> ProviderFetchContext {
        let sourceMode: ProviderSourceMode = switch providerID {
        case .claude:
            .oauth
        case .codex:
            .auto
        case .antigravity:
            .auto
        }

        let settings = ProviderSettingsSnapshot(
            debugMenuEnabled: false,
            debugKeepCLISessionsAlive: false,
            contributions: [
                .claude(ClaudeProviderSettings(
                    usageDataSource: .oauth,
                    webExtrasEnabled: false,
                    cookieSource: .off,
                    manualCookieHeader: nil,
                    organizationID: nil,
                    desktopCookiesEnabled: false
                )),
                .codex(CodexProviderSettings(
                    usageDataSource: .auto,
                    cookieSource: .off,
                    manualCookieHeader: nil
                )),
            ]
        )

        let browserDetection = BrowserDetection(
            fileExists: { _ in false },
            directoryContents: { _ in nil }
        )

        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: providerID == .codex,
            includeOptionalUsage: true,
            includeAccountIdentity: false,
            requiresOptionalUsageCompleteness: false,
            webTimeout: AIUsageHTTPClient.defaultTimeout,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: settings,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ClaudeUsageFetcher(
                browserDetection: browserDetection,
                environment: environment,
                runtime: .app,
                dataSource: .oauth,
                oauthKeychainPromptCooldownEnabled: true,
                oauthSafeCredentialSourcesOnly: true,
                useDesktopCookies: false,
                useWebExtras: false,
                manualCookieHeader: nil
            ),
            browserDetection: browserDetection,
            persistsCLISessions: providerID == .antigravity,
            persistentCLISessionIdleWindow: providerID == .antigravity ? 360 : nil
        )
    }

    /// Live upstream fetch delegating directly to `CodexBarCore`'s descriptor registry after warming the login shell PATH cache.
    nonisolated static func liveFetch(
        provider: UsageProvider,
        context: ProviderFetchContext
    ) async -> ProviderFetchOutcome {
        if LoginShellPathCache.shared.current == nil {
            await withCheckedContinuation { continuation in
                LoginShellPathCache.shared.captureOnce { _ in
                    continuation.resume()
                }
            }
        }
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        return await descriptor.fetchOutcome(context: context)
    }

    /// Maps a `CodexBarCore.ProviderFetchResult` into an immutable LynxBar `AIProviderQuotaSnapshot`.
    nonisolated static func mapSnapshot(
        fetchResult: ProviderFetchResult,
        attempts: [ProviderFetchAttempt] = [],
        providerID: AIUsageProviderID,
        upstreamProvider: UsageProvider,
        fetchedAt: Date
    ) -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        let usage = fetchResult.usage
        let descriptor = ProviderDescriptorRegistry.descriptor(for: upstreamProvider)
        let metadata = descriptor.metadata

        var primary: AIQuotaWindow?
        var secondary: AIQuotaWindow?
        var additional: [AIQuotaWindow] = []
        var seenIDs = Set<String>()

        if let rawPrimary = usage.primary?.measured {
            let mapped = mapRateWindow(
                rawPrimary,
                defaultID: "\(providerID.rawValue)_primary",
                defaultTitle: defaultTitle(for: rawPrimary, slot: .primary, providerID: providerID, metadata: metadata),
                defaultKind: inferWindowKind(for: rawPrimary, slot: .primary, providerID: providerID)
            )
            primary = mapped
            seenIDs.insert(mapped.id)
        }

        if let rawSecondary = usage.secondary?.measured {
            let mapped = mapRateWindow(
                rawSecondary,
                defaultID: "\(providerID.rawValue)_secondary",
                defaultTitle: defaultTitle(for: rawSecondary, slot: .secondary, providerID: providerID, metadata: metadata),
                defaultKind: inferWindowKind(for: rawSecondary, slot: .secondary, providerID: providerID)
            )
            secondary = mapped
            seenIDs.insert(mapped.id)
        }

        if let rawTertiary = usage.tertiary?.measured {
            let mapped = mapRateWindow(
                rawTertiary,
                defaultID: "\(providerID.rawValue)_tertiary",
                defaultTitle: defaultTitle(for: rawTertiary, slot: .tertiary, providerID: providerID, metadata: metadata),
                defaultKind: inferWindowKind(for: rawTertiary, slot: .tertiary, providerID: providerID)
            )
            additional.append(mapped)
            seenIDs.insert(mapped.id)
        }

        for named in (usage.extraRateWindows ?? []) where named.usageKnown {
            guard let measured = named.window.measured else { continue }
            guard seenIDs.insert(named.id).inserted else { continue }
            let cleanTitle = AIUsageParsing.nonEmptyTrimmed(named.title)
                ?? AIUsageParsing.nonEmptyTrimmed(measured.title)
                ?? named.id
            let mapped = mapRateWindow(
                measured,
                defaultID: named.id,
                defaultTitle: cleanTitle,
                defaultKind: inferWindowKind(for: measured, slot: .extra, providerID: providerID)
            )
            additional.append(mapped)
        }

        // Promote the first additional window when upstream (e.g., Antigravity quota summary) populates
        // `extraRateWindows` without setting `primary` / `secondary`.
        if primary == nil, !additional.isEmpty {
            primary = additional.removeFirst()
        }
        if secondary == nil, !additional.isEmpty {
            secondary = additional.removeFirst()
        }

        let extraUsage = mapExtraUsage(usage.providerCost)
        let credits = mapCredits(fetchResult.credits)

        guard primary != nil || secondary != nil || !additional.isEmpty || credits != nil || extraUsage != nil else {
            if let fallbackError = Self.resolveEmptySnapshotError(
                fetchResult: fetchResult,
                attempts: attempts
            ) {
                return .failure(fallbackError)
            }
            return .failure(.decodingFailure("CodexBarCore returned an empty quota snapshot"))
        }

        let identityPresentation = descriptor.presentation.identity(provider: upstreamProvider, snapshot: usage)
        let rawLoginMethod = AIUsageParsing.nonEmptyTrimmed(usage.identity?.loginMethod)
        let rawBadge = AIUsageParsing.nonEmptyTrimmed(identityPresentation.badge)
            ?? AIUsageParsing.nonEmptyTrimmed(identityPresentation.plan)
        let planLabel: String?
        if let rawLoginMethod,
           let rawBadge,
           rawBadge.caseInsensitiveCompare(rawLoginMethod) == .orderedSame,
           rawLoginMethod.contains(where: \.isUppercase) {
            planLabel = rawLoginMethod
        } else {
            planLabel = rawBadge ?? rawLoginMethod
        }
        let accountLabel = AIUsageParsing.nonEmptyTrimmed(usage.identity?.accountEmail)

        return .success(AIProviderQuotaSnapshot(
            providerID: providerID,
            primaryWindow: primary,
            secondaryWindow: secondary,
            additionalWindows: additional,
            extraUsage: extraUsage,
            planLabel: planLabel,
            credits: credits,
            accountLabel: accountLabel,
            fetchedAt: fetchedAt
        ))
    }

    /// Maps upstream `CodexBarCore` errors into LynxBar's explicit `AIUsageFetchError` taxonomy.
    nonisolated static func mapError(_ error: Error) -> AIUsageFetchError {
        if error is CancellationError {
            return .networkFailure("Cancelled")
        }
        if let urlError = error as? URLError {
            return .networkFailure(urlError.localizedDescription)
        }
        if let classified = error as? ProviderFetchClassifiedError {
            switch classified.kind {
            case .missingCredential:
                return .credentialsMissing
            case .authenticationExpired:
                return .tokenExpired
            case .permissionDenied:
                return .unauthorized
            case .rateLimited:
                return .rateLimited(retryAfter: classified.retryAfterSeconds)
            case .parseFailure:
                return .decodingFailure(classified.message)
            case .networkFailure:
                return .networkFailure(classified.message)
            case .providerUnavailable, .apiFailure:
                return .endpointUnavailable(statusCode: 503)
            }
        }
        if let probeError = error as? AntigravityStatusProbeError {
            switch probeError {
            case .notRunning, .missingCSRFToken, .portDetectionFailed:
                return .credentialsMissing
            case .authenticationRequired, .accountMismatch:
                return .unauthorized
            case .timedOut:
                return .networkFailure(probeError.localizedDescription)
            case .apiError(let message):
                return classifyErrorMessage(message)
            case .parseFailed(let message):
                return .decodingFailure(message)
            case .cliReportFailed:
                return classifyErrorMessage(probeError.localizedDescription)
            }
        }

        return classifyErrorMessage(error.localizedDescription)
    }

    /// Shuts down any persistent CLI helper sessions managed by `CodexBarCore` (e.g., Antigravity `agy`).
    nonisolated static func shutdownPersistentSessions() async {
        await ProviderCLISessionLifecycle.shutdownPersistentSessions()
    }

    // MARK: - Mapping Helpers

    private enum WindowSlot {
        case primary
        case secondary
        case tertiary
        case extra
    }

    /// Normalizes a `CodexBarCore.RateWindow` (`0...100` percent) into a clamped `0...1` `AIQuotaWindow`.
    private nonisolated static func mapRateWindow(
        _ window: RateWindow,
        defaultID: String,
        defaultTitle: String,
        defaultKind: AIQuotaWindow.Kind
    ) -> AIQuotaWindow {
        let ratio: Double = if window.usedPercent.isFinite {
            min(max(window.usedPercent / 100.0, 0), 1)
        } else {
            0
        }
        let title = AIUsageParsing.nonEmptyTrimmed(window.title) ?? defaultTitle
        return AIQuotaWindow(
            id: defaultID,
            kind: defaultKind,
            title: title,
            usedRatio: ratio,
            resetsAt: window.resetsAt
        )
    }

    /// Infers a LynxBar `AIQuotaWindow.Kind` from `windowMinutes` and slot metadata.
    private nonisolated static func inferWindowKind(
        for window: RateWindow,
        slot: WindowSlot,
        providerID: AIUsageProviderID
    ) -> AIQuotaWindow.Kind {
        if providerID == .antigravity {
            if window.windowMinutes == 300 { return .session5h }
            if window.windowMinutes == 7 * 24 * 60 { return .weekly7d }
            return .modelQuota
        }
        if let minutes = window.windowMinutes {
            if minutes == 300 { return .session5h }
            if minutes == 7 * 24 * 60 { return .weekly7d }
        }
        switch slot {
        case .primary:
            return .session5h
        case .secondary:
            return .weekly7d
        case .tertiary:
            return .weeklyModelSpecific
        case .extra:
            return .modelQuota
        }
    }

    /// Resolves a concise human-readable window title when `RateWindow.title` is absent.
    private nonisolated static func defaultTitle(
        for window: RateWindow,
        slot: WindowSlot,
        providerID: AIUsageProviderID,
        metadata: ProviderMetadata
    ) -> String {
        if let explicit = AIUsageParsing.nonEmptyTrimmed(window.title) {
            return explicit
        }
        if providerID == .antigravity {
            switch slot {
            case .primary: return metadata.sessionLabel
            case .secondary: return metadata.weeklyLabel
            case .tertiary, .extra: return "Model quota"
            }
        }
        if let minutes = window.windowMinutes {
            if minutes == 300 { return "5-hour session" }
            if minutes == 7 * 24 * 60 { return "7-day weekly" }
        }
        switch slot {
        case .primary: return "5-hour session"
        case .secondary: return "7-day weekly"
        case .tertiary: return metadata.opusLabel ?? "Model quota"
        case .extra: return "Model quota"
        }
    }

    /// Converts `CodexBarCore.ProviderCostSnapshot` into `AIExtraUsageSummary` for monetary overage plans.
    private nonisolated static func mapExtraUsage(_ cost: ProviderCostSnapshot?) -> AIExtraUsageSummary? {
        guard let cost else { return nil }
        let currency = AIUsageParsing.nonEmptyTrimmed(cost.currencyCode) ?? "USD"
        guard currency.uppercased() != "CREDITS" else { return nil }
        let used = cost.used.isFinite ? cost.used : nil
        let limit = (cost.limit.isFinite && cost.limit > 0) ? cost.limit : nil
        guard used != nil || limit != nil else { return nil }
        return AIExtraUsageSummary(
            isEnabled: true,
            usedAmount: used,
            monthlyLimit: limit,
            currencyCode: currency
        )
    }

    /// Converts `CodexBarCore.CreditsSnapshot` into `AIProviderCreditsSummary`.
    private nonisolated static func mapCredits(_ credits: CreditsSnapshot?) -> AIProviderCreditsSummary? {
        guard let credits else { return nil }
        let displayRemaining = credits.displayRemaining
        let hasCredits = credits.creditsAvailable ?? (displayRemaining != nil)
        guard hasCredits || displayRemaining != nil else { return nil }
        return AIProviderCreditsSummary(
            hasCredits: hasCredits,
            unlimited: false,
            balanceText: nil,
            balanceAmount: displayRemaining
        )
    }

    /// Classifies unstructured upstream error descriptions into LynxBar's actionable `AIUsageFetchError` cases.
    private nonisolated static func classifyErrorMessage(_ message: String) -> AIUsageFetchError {
        let lower = message.lowercased()
        if lower.contains("429") || lower.contains("rate limit") || lower.contains("too many requests") {
            return .rateLimited(retryAfter: nil)
        }
        if lower.contains("expired") || lower.contains("re-login") || lower.contains("reauthenticate") {
            return .tokenExpired
        }
        if lower.contains("401") || lower.contains("403") || lower.contains("unauthorized") || lower.contains("forbidden")
            || lower.contains("authentication required") || lower.contains("not logged in")
            || lower.contains("not signed in") {
            return .unauthorized
        }
        if lower.contains("not found") || lower.contains("not running") || lower.contains("missing")
            || lower.contains("no credentials") || lower.contains("sign in") || lower.contains("login")
            || lower.contains("no available fetch strategy") || lower.contains("csrf") {
            return .credentialsMissing
        }
        if lower.contains("decode") || lower.contains("parse") || lower.contains("malformed") {
            return .decodingFailure(message)
        }
        return .networkFailure(message)
    }

    /// Resolves the underlying live-strategy error when `CodexBarCore` falls back to a non-quota offline snapshot.
    private nonisolated static func resolveEmptySnapshotError(
        fetchResult: ProviderFetchResult,
        attempts: [ProviderFetchAttempt]
    ) -> AIUsageFetchError? {
        if let diagnostic = AIUsageParsing.nonEmptyTrimmed(fetchResult.diagnostic) {
            return classifyErrorMessage(diagnostic)
        }
        let priorFailures = attempts.compactMap { attempt -> String? in
            guard attempt.strategyID != fetchResult.strategyID else { return nil }
            return AIUsageParsing.nonEmptyTrimmed(attempt.errorDescription)
        }
        if let firstFailure = priorFailures.first {
            return classifyErrorMessage(firstFailure)
        }
        if fetchResult.sourceLabel == "offline" || fetchResult.strategyID.hasSuffix(".offline") {
            return .credentialsMissing
        }
        return nil
    }

    /// Produces a privacy-safe summary of `CodexBarCore` strategy attempts (strategy IDs and status categories only).
    private nonisolated static func formatAttemptsForLog(_ attempts: [ProviderFetchAttempt]) -> String {
        guard !attempts.isEmpty else { return "none" }
        return attempts.map { attempt in
            if !attempt.wasAvailable {
                return "\(attempt.strategyID):skipped"
            }
            if let desc = AIUsageParsing.nonEmptyTrimmed(attempt.errorDescription) {
                let category = Self.classifyErrorCategory(desc)
                return "\(attempt.strategyID):failed(\(category))"
            }
            return "\(attempt.strategyID):ok"
        }.joined(separator: ",")
    }

    /// Maps an upstream attempt error string to a short non-sensitive diagnostic category for logs.
    private nonisolated static func classifyErrorCategory(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("not running") { return "not_running" }
        if lower.contains("csrf") { return "missing_csrf" }
        if lower.contains("port") { return "port_detection" }
        if lower.contains("timed out") || lower.contains("timeout") { return "timeout" }
        if lower.contains("401") || lower.contains("403") || lower.contains("auth") { return "auth" }
        if lower.contains("429") || lower.contains("rate") { return "rate_limit" }
        if lower.contains("1.1.11") || lower.contains("version") { return "version" }
        if lower.contains("exited") { return "cli_exit" }
        if lower.contains("parse") || lower.contains("decode") { return "parse" }
        if lower.contains("http") || lower.contains("api") { return "api" }
        return "other"
    }
}
