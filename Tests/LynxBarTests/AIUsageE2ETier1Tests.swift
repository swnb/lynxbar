import AppKit
import CodexBarCore
import Foundation
import Security
import SwiftUI
import XCTest
@testable import LynxBar

/// Tier 1 Opaque-Box E2E Tests: 5 feature-coverage tests × 20 features = 100 tests.
@MainActor
final class AIUsageE2ETier1Tests: XCTestCase {
    private let cleanup = E2ECleanupTracker()

    override func tearDown() {
        cleanup.cleanupAll()
        super.tearDown()
    }

    private func makeIsolatedSettings() -> LynxBar.Settings {
        let (settings, suite, _) = E2EIsolatedStore.makeSettings()
        cleanup.registerSuite(suite)
        return settings
    }

    private func makeTempHome() throws -> E2ETempHomeFixture {
        let home = try E2ETempHomeFixture()
        cleanup.registerHome(home)
        return home
    }

    // MARK: - F1: AIUsageProviderID & AIUsageProvider Contract (5)

    func testF01_01_providerIDCaseIterableAndRawValues() {
        XCTAssertEqual(AIUsageProviderID.allCases, [.claude, .codex, .antigravity])
        let rawValues = AIUsageProviderID.allCases.map(\.rawValue)
        XCTAssertEqual(rawValues, ["claude", "codex", "antigravity"])
        XCTAssertEqual(Set(rawValues).count, 3)
    }

    func testF01_02_providerDisplayNamesAndShortNamesAreNonEmpty() {
        XCTAssertEqual(AIUsageProviderID.claude.displayName, "Claude")
        XCTAssertEqual(AIUsageProviderID.codex.displayName, "OpenAI Codex")
        XCTAssertEqual(AIUsageProviderID.antigravity.displayName, "Antigravity")
        XCTAssertEqual(AIUsageProviderID.claude.shortName, "Claude")
        XCTAssertEqual(AIUsageProviderID.codex.shortName, "Codex")
        XCTAssertEqual(AIUsageProviderID.antigravity.shortName, "Antigravity")
    }

    func testF01_03_providerCLILoginCommandsMatchContract() {
        XCTAssertEqual(AIUsageProviderID.claude.cliLoginCommand, "claude /login")
        XCTAssertEqual(AIUsageProviderID.codex.cliLoginCommand, "codex login")
        XCTAssertEqual(AIUsageProviderID.antigravity.cliLoginCommand, "agy login")
    }

    func testF01_04_providerIDCodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(AIUsageProviderID.allCases)
        let decoded = try JSONDecoder().decode([AIUsageProviderID].self, from: encoded)
        XCTAssertEqual(decoded, AIUsageProviderID.allCases)
    }

    func testF01_05_quotaWindowDisplayedRatioMatchesStyle() {
        let window = AIQuotaWindow(
            id: "w1",
            kind: .session5h,
            title: "5-hour session",
            usedRatio: 0.35,
            resetsAt: nil
        )
        XCTAssertEqual(window.displayedRatio(style: .remaining), 0.65, accuracy: 0.0001)
        XCTAssertEqual(window.displayedRatio(style: .used), 0.35, accuracy: 0.0001)
    }

    // MARK: - F2: AIUsageHTTPTransport Ephemeral HTTP Client (5)

    func testF02_01_httpClientUsesEphemeralNonPersistentSessionConfiguration() {
        let client = AIUsageHTTPClient()
        let session = Mirror(reflecting: client).descendant("session") as? URLSession
        XCTAssertNotNil(session)
        let config = session?.configuration
        XCTAssertNil(config?.identifier)
        XCTAssertNil(config?.httpCookieStorage)
        XCTAssertNil(config?.urlCache)
    }

    func testF02_02_httpClientDisablesCookieStorageAndCookieSetting() {
        let client = AIUsageHTTPClient()
        let session = Mirror(reflecting: client).descendant("session") as? URLSession
        XCTAssertNil(session?.configuration.httpCookieStorage)
        XCTAssertEqual(session?.configuration.httpShouldSetCookies, false)
    }

    func testF02_03_httpClientDisablesURLCacheAndIgnoresLocalCache() {
        let client = AIUsageHTTPClient()
        let session = Mirror(reflecting: client).descendant("session") as? URLSession
        XCTAssertNil(session?.configuration.urlCache)
        XCTAssertEqual(session?.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testF02_04_httpClientDefaultTimeoutIs15Seconds() {
        XCTAssertEqual(AIUsageHTTPClient.defaultTimeout, 15, accuracy: 0.001)
        let client = AIUsageHTTPClient()
        let session = Mirror(reflecting: client).descendant("session") as? URLSession
        XCTAssertEqual(session?.configuration.timeoutIntervalForRequest ?? 0, 15, accuracy: 0.001)
        XCTAssertEqual(session?.configuration.timeoutIntervalForResource ?? 0, 15, accuracy: 0.001)
    }

    func testF02_05_mockHTTPTransportRecordsRequestAcrossActorBoundary() async throws {
        let url = URL(string: "https://example.invalid/quota")!
        let payload = Data("{\"ok\":true}".utf8)
        let response = E2ERecordingHTTPTransport.makeResponse(url: url, statusCode: 200)
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [.success((payload, response))])

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer token-123", forHTTPHeaderField: "Authorization")

        let (data, httpResp) = try await transport.data(for: req)
        XCTAssertEqual(data, payload)
        XCTAssertEqual(httpResp.statusCode, 200)
        let recorded = await transport.requests
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
    }

    // MARK: - F3: Claude Credential Discovery & Expiry Precheck (5)

    func testF03_01_claudeKeychainValidJSONReturnsCredentials() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let futureMs = (now.timeIntervalSince1970 + 600) * 1000
        let keychainData = E2EFixtureFactory.claudeCredentialsData(
            accessToken: "sk-ant-keychain-valid",
            expiresAtValue: futureMs,
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x"
        )
        let reader = ClaudeCredentialReader(
            keychainReader: { .data(keychainData) },
            fileReader: { nil }
        )

        let result = reader.readCredentials(now: now)
        guard case .success(let creds) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(creds.accessToken, "sk-ant-keychain-valid")
        XCTAssertEqual(creds.subscriptionType, "max")
        XCTAssertEqual(creds.rateLimitTier, "default_claude_max_20x")
        XCTAssertEqual(creds.expiresAt?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970 + 600, accuracy: 0.01)
    }

    func testF03_02_claudeKeychainNotFoundFallsBackToFile() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let fileData = E2EFixtureFactory.claudeCredentialsData(
            accessToken: "sk-ant-file-fallback",
            expiresAtValue: (now.timeIntervalSince1970 + 600) * 1000,
            subscriptionType: "pro"
        )
        let reader = ClaudeCredentialReader(
            keychainReader: { .notFound },
            fileReader: { fileData }
        )

        let result = reader.readCredentials(now: now)
        guard case .success(let creds) = result else {
            return XCTFail("Expected file fallback success, got \(result)")
        }
        XCTAssertEqual(creds.accessToken, "sk-ant-file-fallback")
        XCTAssertEqual(creds.subscriptionType, "pro")
    }

    func testF03_03_claudeMCPOAuthOnlyKeychainFallsBackToFile() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let mcpOnlyData = Data(#"{"mcpOAuth":{"accessToken":"mcp-token-only"}}"#.utf8)
        let fileData = E2EFixtureFactory.claudeCredentialsData(
            accessToken: "sk-ant-from-file",
            expiresAtValue: now.timeIntervalSince1970 + 600
        )
        let reader = ClaudeCredentialReader(
            keychainReader: { .data(mcpOnlyData) },
            fileReader: { fileData }
        )

        let result = reader.readCredentials(now: now)
        guard case .success(let creds) = result else {
            return XCTFail("Expected fallback after MCP-only keychain, got \(result)")
        }
        XCTAssertEqual(creds.accessToken, "sk-ant-from-file")
    }

    func testF03_04_claudeMissingKeychainAndFileReturnsCredentialsMissing() {
        let reader = ClaudeCredentialReader(
            keychainReader: { .notFound },
            fileReader: { nil }
        )
        XCTAssertEqual(reader.readCredentials(now: Date()), .failure(.credentialsMissing))
    }

    func testF03_05_claudeExpiresAtMillisecondsAndSecondsParseIdentically() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let targetSeconds = now.timeIntervalSince1970 + 3600
        let targetMillis = targetSeconds * 1000

        let readerMs = ClaudeCredentialReader(
            keychainReader: { .data(E2EFixtureFactory.claudeCredentialsData(expiresAtValue: targetMillis)) },
            fileReader: { nil }
        )
        let readerSec = ClaudeCredentialReader(
            keychainReader: { .data(E2EFixtureFactory.claudeCredentialsData(expiresAtValue: targetSeconds)) },
            fileReader: { nil }
        )

        guard case .success(let msCreds) = readerMs.readCredentials(now: now),
              case .success(let secCreds) = readerSec.readCredentials(now: now) else {
            return XCTFail("Expected both ms and seconds timestamps to parse")
        }
        XCTAssertEqual(msCreds.expiresAt?.timeIntervalSince1970 ?? -1, secCreds.expiresAt?.timeIntervalSince1970 ?? -2, accuracy: 0.001)
    }

    // MARK: - F4: Claude Usage API & Model Window Decoding (5)

    func testF04_01_claudeSendsExpectedEndpointMethodAndHeaders() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let reader = E2ESpyClaudeCredentialReader(result: .success(
            ClaudeOAuthCredentials(accessToken: "tok-claude-1", expiresAt: now.addingTimeInterval(600), subscriptionType: "max", rateLimitTier: nil)
        ))
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((
                E2EFixtureFactory.claudeUsageJSON(),
                E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)
            ))
        ])
        let provider = ClaudeUsageProvider(credentialReader: reader, transport: transport, userAgentVersion: "1.2.3")
        _ = await provider.fetchQuota(now: now)

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let req = requests[0]
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url, ClaudeUsageProvider.defaultEndpointURL)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-claude-1")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "LynxBar/1.2.3")
    }

    func testF04_02_claudeDecodesPrimaryAndSecondaryWindowsNormalized() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let reader = E2ESpyClaudeCredentialReader(result: .success(
            ClaudeOAuthCredentials(accessToken: "tok", expiresAt: nil, subscriptionType: "pro", rateLimitTier: nil)
        ))
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((
                E2EFixtureFactory.claudeUsageJSON(fiveHourPercent: 42.0, sevenDayPercent: 65.0),
                E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)
            ))
        ])
        let provider = ClaudeUsageProvider(credentialReader: reader, transport: transport)
        let result = await provider.fetchQuota(now: now)
        guard case .success(let snapshot) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(snapshot.primaryWindow?.usedRatio ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(snapshot.secondaryWindow?.usedRatio ?? -1, 0.65, accuracy: 0.0001)
        XCTAssertEqual(snapshot.primaryWindow?.kind, .session5h)
        XCTAssertEqual(snapshot.secondaryWindow?.kind, .weekly7d)
    }

    func testF04_03_claudeDecodesModelSpecificAdditionalWindows() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let reader = E2ESpyClaudeCredentialReader(result: .success(
            ClaudeOAuthCredentials(accessToken: "tok", expiresAt: nil, subscriptionType: "max", rateLimitTier: nil)
        ))
        let body = E2EFixtureFactory.claudeUsageJSON(
            sonnetPercent: 18,
            opusPercent: 72,
            oauthAppsPercent: 10,
            coworkPercent: 30
        )
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((body, E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)))
        ])
        let provider = ClaudeUsageProvider(credentialReader: reader, transport: transport)
        let result = await provider.fetchQuota(now: now)
        guard case .success(let snapshot) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(snapshot.additionalWindows.map(\.id), [
            "seven_day_sonnet",
            "seven_day_opus",
            "seven_day_oauth_apps",
            "seven_day_cowork",
        ])
        XCTAssertTrue(snapshot.additionalWindows.allSatisfy { $0.kind == .weeklyModelSpecific })
        XCTAssertEqual(snapshot.additionalWindows[1].usedRatio, 0.72, accuracy: 0.0001)
    }

    func testF04_04_claudeDecodesExtraUsageSummary() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let reader = E2ESpyClaudeCredentialReader(result: .success(
            ClaudeOAuthCredentials(accessToken: "tok", expiresAt: nil, subscriptionType: "max", rateLimitTier: nil)
        ))
        let body = E2EFixtureFactory.claudeUsageJSON(
            extraEnabled: true,
            extraUsed: 14.5,
            extraLimit: 50.0,
            extraCurrency: "USD"
        )
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((body, E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)))
        ])
        let provider = ClaudeUsageProvider(credentialReader: reader, transport: transport)
        let result = await provider.fetchQuota(now: now)
        guard case .success(let snapshot) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(snapshot.extraUsage, AIExtraUsageSummary(isEnabled: true, usedAmount: 14.5, monthlyLimit: 50.0, currencyCode: "USD"))
    }

    func testF04_05_claudeDerivesPlanLabelAndRecordsFetchedAt() async {
        let now = Date(timeIntervalSince1970: 1_760_000_456)
        let reader = E2ESpyClaudeCredentialReader(result: .success(
            ClaudeOAuthCredentials(accessToken: "tok", expiresAt: nil, subscriptionType: "default", rateLimitTier: "default_claude_max_20x")
        ))
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((
                E2EFixtureFactory.claudeUsageJSON(),
                E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)
            ))
        ])
        let provider = ClaudeUsageProvider(credentialReader: reader, transport: transport)
        let result = await provider.fetchQuota(now: now)
        guard case .success(let snapshot) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(snapshot.planLabel, "Max")
        XCTAssertEqual(ClaudeUsageProvider.derivePlanLabel(subscriptionType: "pro", rateLimitTier: nil), "Pro")
        XCTAssertEqual(snapshot.fetchedAt, now)
    }

    // MARK: - F5: Codex Credential Discovery & Expiry Precheck (5)

    func testF05_01_codexReadsCodexHomeAuthJSONWhenSet() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let home = try makeTempHome()
        let customCodexDir = home.rootURL.appendingPathComponent("custom-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: customCodexDir, withIntermediateDirectories: true)

        let jwt = E2EFixtureFactory.makeJWT(claims: [
            "exp": now.timeIntervalSince1970 + 600,
            "email": "user@example.com",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"]
        ])
        let authURL = customCodexDir.appendingPathComponent("auth.json")
        try E2EFixtureFactory.codexAuthJSON(accessToken: jwt, accountId: "acct_custom").write(to: authURL)

        let reader = CodexCredentialReader(
            environment: ["CODEX_HOME": customCodexDir.path],
            homeDirectory: home.rootURL
        )
        let result = reader.readCredentials(now: now)
        guard case .success(let creds) = result else {
            return XCTFail("Expected success from CODEX_HOME, got \(result)")
        }
        XCTAssertEqual(creds.accessToken, jwt)
        XCTAssertEqual(creds.accountId, "acct_custom")
        XCTAssertEqual(creds.accountEmail, "user@example.com")
    }

    func testF05_02_codexFallsBackToDotCodexWhenCodexHomeUnset() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let home = try makeTempHome()
        let jwt = E2EFixtureFactory.makeJWT(claims: ["exp": now.timeIntervalSince1970 + 600])
        _ = try home.writeFile(
            relativePath: ".codex/auth.json",
            data: E2EFixtureFactory.codexAuthJSON(accessToken: jwt, accountId: "acct_home")
        )

        let reader = CodexCredentialReader(environment: [:], homeDirectory: home.rootURL)
        let result = reader.readCredentials(now: now)
        guard case .success(let creds) = result else {
            return XCTFail("Expected fallback to ~/.codex/auth.json, got \(result)")
        }
        XCTAssertEqual(creds.accountId, "acct_home")
    }

    func testF05_03_codexExtractsAccountIdAlongsideAccessToken() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let home = try makeTempHome()
        let jwt = E2EFixtureFactory.makeJWT(claims: ["exp": now.timeIntervalSince1970 + 600])
        _ = try home.writeFile(
            relativePath: ".codex/auth.json",
            data: E2EFixtureFactory.codexAuthJSON(accessToken: jwt, accountId: "org_acct_777")
        )

        let reader = CodexCredentialReader(environment: [:], homeDirectory: home.rootURL)
        guard case .success(let creds) = reader.readCredentials(now: now) else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(creds.accountId, "org_acct_777")
        XCTAssertEqual(creds.accessToken, jwt)
    }

    func testF05_04_codexValidJWTExpAndRecentLastRefreshSucceeds() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let home = try makeTempHome()
        let jwt = E2EFixtureFactory.makeJWT(claims: ["exp": now.timeIntervalSince1970 + 3_600])
        _ = try home.writeFile(
            relativePath: ".codex/auth.json",
            data: E2EFixtureFactory.codexAuthJSON(
                accessToken: jwt,
                lastRefresh: now.timeIntervalSince1970 - 3_600
            )
        )

        let reader = CodexCredentialReader(environment: [:], homeDirectory: home.rootURL)
        guard case .success = reader.readCredentials(now: now) else {
            return XCTFail("Expected success with valid JWT exp and recent last_refresh")
        }
    }

    func testF05_05_codexAPIKeyOnlyReturnsCredentialsMissingWithZeroHTTP() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let home = try makeTempHome()
        _ = try home.writeFile(
            relativePath: ".codex/auth.json",
            data: E2EFixtureFactory.codexAuthJSON(accessToken: nil, refreshToken: nil, accountId: nil, openAIAPIKey: "sk-proj-only")
        )

        let reader = CodexCredentialReader(environment: [:], homeDirectory: home.rootURL)
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [])
        let provider = CodexUsageProvider(credentialReader: reader, transport: transport)

        let result = await provider.fetchQuota(now: now)
        XCTAssertEqual(result, .failure(.credentialsMissing))
        let calls = await transport.callCount
        XCTAssertEqual(calls, 0)
    }

    // MARK: - F6: Codex Usage API Request & Snapshot Decoding (5)

    func testF06_01_codexSendsGetWithBearerTokenToWhamUsage() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let reader = E2ESpyCodexCredentialReader(result: .success(
            CodexOAuthCredentials(
                accessToken: "codex-tok",
                refreshToken: nil,
                idToken: nil,
                accountId: nil,
                accountEmail: nil,
                expiresAt: now.addingTimeInterval(600),
                lastRefresh: now,
                planType: "pro"
            )
        ))
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((
                E2EFixtureFactory.codexUsageJSON(),
                E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)
            ))
        ])
        let provider = CodexUsageProvider(credentialReader: reader, transport: transport)
        _ = await provider.fetchQuota(now: now)

        let reqs = await transport.requests
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs[0].httpMethod, "GET")
        XCTAssertEqual(reqs[0].url, CodexUsageProvider.defaultEndpointURL)
        XCTAssertEqual(reqs[0].value(forHTTPHeaderField: "Authorization"), "Bearer codex-tok")
    }

    func testF06_02_codexAttachesChatGPTAccountIdHeaderWhenPresent() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let reader = E2ESpyCodexCredentialReader(result: .success(
            CodexOAuthCredentials(
                accessToken: "codex-tok",
                refreshToken: nil,
                idToken: nil,
                accountId: "acct_workspace_9",
                accountEmail: nil,
                expiresAt: nil,
                lastRefresh: nil,
                planType: "team"
            )
        ))
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((
                E2EFixtureFactory.codexUsageJSON(),
                E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)
            ))
        ])
        let provider = CodexUsageProvider(credentialReader: reader, transport: transport)
        _ = await provider.fetchQuota(now: now)

        let reqs = await transport.requests
        XCTAssertEqual(reqs[0].value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct_workspace_9")
    }

    func testF06_03_codexOmitsChatGPTAccountIdHeaderWhenAbsent() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let reader = E2ESpyCodexCredentialReader(result: .success(
            CodexOAuthCredentials(
                accessToken: "codex-tok",
                refreshToken: nil,
                idToken: nil,
                accountId: nil,
                accountEmail: nil,
                expiresAt: nil,
                lastRefresh: nil,
                planType: nil
            )
        ))
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((
                E2EFixtureFactory.codexUsageJSON(),
                E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)
            ))
        ])
        let provider = CodexUsageProvider(credentialReader: reader, transport: transport)
        _ = await provider.fetchQuota(now: now)

        let reqs = await transport.requests
        XCTAssertNil(reqs[0].value(forHTTPHeaderField: "ChatGPT-Account-Id"))
    }

    func testF06_04_codexDecodesPrimaryAndSecondaryWindowsAndResetsAt() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let resetTimestamp = now.timeIntervalSince1970 + 3_600
        let reader = E2ESpyCodexCredentialReader(result: .success(
            CodexOAuthCredentials(accessToken: "t", refreshToken: nil, idToken: nil, accountId: nil, accountEmail: nil, expiresAt: nil, lastRefresh: nil, planType: nil)
        ))
        let body = E2EFixtureFactory.codexUsageJSON(
            primaryUsedPercent: 40,
            primaryResetAt: resetTimestamp,
            secondaryUsedPercent: 25,
            secondaryResetAfterSeconds: 86_400
        )
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((body, E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)))
        ])
        let provider = CodexUsageProvider(credentialReader: reader, transport: transport)
        let result = await provider.fetchQuota(now: now)
        guard case .success(let snapshot) = result else {
            return XCTFail("Expected Codex decode success, got \(result)")
        }
        XCTAssertEqual(snapshot.primaryWindow?.kind, .session5h)
        XCTAssertEqual(snapshot.primaryWindow?.usedRatio ?? -1, 0.40, accuracy: 0.0001)
        XCTAssertEqual(snapshot.primaryWindow?.resetsAt?.timeIntervalSince1970 ?? -1, resetTimestamp, accuracy: 0.01)
        XCTAssertEqual(snapshot.secondaryWindow?.kind, .weekly7d)
        XCTAssertEqual(snapshot.secondaryWindow?.usedRatio ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.secondaryWindow?.resetsAt?.timeIntervalSince1970 ?? -1, now.timeIntervalSince1970 + 86_400, accuracy: 0.01)
    }

    func testF06_05_codexSetsProviderIDPlanLabelCreditsAndFetchedAt() async {
        let now = Date(timeIntervalSince1970: 1_760_000_999)
        let reader = E2ESpyCodexCredentialReader(result: .success(
            CodexOAuthCredentials(accessToken: "t", refreshToken: nil, idToken: nil, accountId: nil, accountEmail: "dev@example.com", expiresAt: nil, lastRefresh: nil, planType: "plus")
        ))
        let body = E2EFixtureFactory.codexUsageJSON(
            planType: "pro",
            creditsHasCredits: true,
            creditsUnlimited: false,
            creditsBalance: "24.75"
        )
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((body, E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)))
        ])
        let provider = CodexUsageProvider(credentialReader: reader, transport: transport)
        let result = await provider.fetchQuota(now: now)
        guard case .success(let snapshot) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(snapshot.providerID, .codex)
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(snapshot.planLabel, "Pro")
        XCTAssertEqual(snapshot.accountLabel, "dev@example.com")
        XCTAssertEqual(snapshot.credits?.hasCredits, true)
        XCTAssertEqual(snapshot.credits?.balanceText, "24.75")
        XCTAssertEqual(snapshot.credits?.balanceAmount ?? -1, 24.75, accuracy: 0.001)
    }

    // MARK: - F7: CodexBarCore Privacy Context & Provider Mapping (5)

    func testF07_01_codexBarContextDisablesBrowserCookiesForAllProviders() {
        for id in AIUsageProviderID.allCases {
            let ctx = CodexBarUsageProvider.makeFetchContext(for: id, environment: [:])
            XCTAssertEqual(ctx.settings?.claude?.cookieSource, .off)
            XCTAssertEqual(ctx.settings?.claude?.webExtrasEnabled, false)
            XCTAssertEqual(ctx.settings?.claude?.desktopCookiesEnabled, false)
            XCTAssertEqual(ctx.settings?.codex?.cookieSource, .off)
        }
    }

    func testF07_02_codexBarContextSetsExpectedSourceModes() {
        XCTAssertEqual(CodexBarUsageProvider.makeFetchContext(for: .claude, environment: [:]).sourceMode, .oauth)
        XCTAssertEqual(CodexBarUsageProvider.makeFetchContext(for: .codex, environment: [:]).sourceMode, .auto)
        XCTAssertEqual(CodexBarUsageProvider.makeFetchContext(for: .antigravity, environment: [:]).sourceMode, .auto)
    }

    func testF07_03_codexBarContextEnablesPersistentCLISessionsOnlyForAntigravity() {
        XCTAssertFalse(CodexBarUsageProvider.makeFetchContext(for: .claude, environment: [:]).persistsCLISessions)
        XCTAssertFalse(CodexBarUsageProvider.makeFetchContext(for: .codex, environment: [:]).persistsCLISessions)
        XCTAssertTrue(CodexBarUsageProvider.makeFetchContext(for: .antigravity, environment: [:]).persistsCLISessions)
    }

    func testF07_04_codexBarMapsProviderIDsExactly() {
        XCTAssertEqual(CodexBarUsageProvider.mapProviderID(.claude), .claude)
        XCTAssertEqual(CodexBarUsageProvider.mapProviderID(.codex), .codex)
        XCTAssertEqual(CodexBarUsageProvider.mapProviderID(.antigravity), .antigravity)
    }

    func testF07_05_codexBarContextDisablesWebDebugDumpAndAccountIdentityFetch() {
        let ctx = CodexBarUsageProvider.makeFetchContext(for: .antigravity, environment: [:])
        XCTAssertFalse(ctx.webDebugDumpHTML)
        XCTAssertFalse(ctx.includeAccountIdentity)
        XCTAssertEqual(ctx.webTimeout, AIUsageHTTPClient.defaultTimeout)
    }

    // MARK: - F8: Antigravity Snapshot Mapping & Quota Window Promotion (5)

    func testF08_01_antigravityPromotesKnownExtraRateWindowsToPrimaryAndSecondary() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Models",
                    window: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: now.addingTimeInterval(3_600), resetDescription: nil),
                    usageKnown: true
                ),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude and GPT",
                    window: RateWindow(usedPercent: 60, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400), resetDescription: nil),
                    usageKnown: true
                ),
            ],
            updatedAt: now,
            identity: ProviderIdentitySnapshot(providerID: .antigravity, accountEmail: "dev@example.com", accountOrganization: nil, loginMethod: "Google AI Pro")
        )
        let fetchResult = ProviderFetchResult(usage: usage, credits: nil, dashboard: nil, sourceLabel: "antigravity.app-local", strategyID: "antigravity.app-local", strategyKind: .localProbe)
        let provider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
            ProviderFetchOutcome(result: .success(fetchResult), attempts: [])
        }

        let snapshot = try await provider.fetchQuota(now: now).get()
        XCTAssertEqual(snapshot.providerID, .antigravity)
        XCTAssertEqual(snapshot.primaryWindow?.title, "Gemini Models")
        XCTAssertEqual(snapshot.primaryWindow?.usedRatio ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.secondaryWindow?.title, "Claude and GPT")
        XCTAssertEqual(snapshot.secondaryWindow?.usedRatio ?? -1, 0.60, accuracy: 0.0001)
    }

    func testF08_02_antigravityFiltersUnknownUsageExtraRateWindows() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "known-1",
                    title: "Gemini Models",
                    window: RateWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    usageKnown: true
                ),
                NamedRateWindow(
                    id: "unknown-1",
                    title: "Unknown Model",
                    window: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    usageKnown: false
                ),
            ],
            updatedAt: now
        )
        let fetchResult = ProviderFetchResult(usage: usage, credits: nil, dashboard: nil, sourceLabel: "antigravity", strategyID: "antigravity", strategyKind: .localProbe)
        let provider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
            ProviderFetchOutcome(result: .success(fetchResult), attempts: [])
        }

        let snapshot = try await provider.fetchQuota(now: now).get()
        XCTAssertEqual(snapshot.primaryWindow?.id, "known-1")
        XCTAssertNil(snapshot.secondaryWindow)
        XCTAssertTrue(snapshot.additionalWindows.isEmpty)
    }

    func testF08_03_antigravityPreservesAdditionalModelWindowsBeyondPrimaryAndSecondary() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 15, windowMinutes: 300, resetsAt: nil, resetDescription: nil, title: "Gemini Models"),
            secondary: RateWindow(usedPercent: 45, windowMinutes: 10_080, resetsAt: nil, resetDescription: nil, title: "Claude and GPT"),
            extraRateWindows: [
                NamedRateWindow(
                    id: "extra-flash",
                    title: "Flash Pool",
                    window: RateWindow(usedPercent: 80, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    usageKnown: true
                ),
            ],
            updatedAt: now
        )
        let fetchResult = ProviderFetchResult(usage: usage, credits: nil, dashboard: nil, sourceLabel: "antigravity", strategyID: "antigravity", strategyKind: .localProbe)
        let provider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
            ProviderFetchOutcome(result: .success(fetchResult), attempts: [])
        }

        let snapshot = try await provider.fetchQuota(now: now).get()
        XCTAssertEqual(snapshot.primaryWindow?.usedRatio ?? -1, 0.15, accuracy: 0.0001)
        XCTAssertEqual(snapshot.secondaryWindow?.usedRatio ?? -1, 0.45, accuracy: 0.0001)
        XCTAssertEqual(snapshot.additionalWindows.first?.id, "extra-flash")
        XCTAssertEqual(snapshot.additionalWindows.first?.usedRatio ?? -1, 0.80, accuracy: 0.0001)
    }

    func testF08_04_antigravityProbeNotRunningMapsToCredentialsMissing() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let provider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
            ProviderFetchOutcome(result: .failure(AntigravityStatusProbeError.notRunning), attempts: [])
        }
        let result = await provider.fetchQuota(now: now)
        XCTAssertEqual(result, .failure(.credentialsMissing))
    }

    func testF08_05_antigravitySnapshotHasProviderIDWindowsPlanAccountAndFetchedAt() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_777)
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 45, windowMinutes: 300, resetsAt: nil, resetDescription: nil, title: "Gemini Models"),
            secondary: RateWindow(usedPercent: 15, windowMinutes: 10_080, resetsAt: nil, resetDescription: nil, title: "Claude and GPT"),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(providerID: .antigravity, accountEmail: "dev@corp.com", accountOrganization: nil, loginMethod: "Google AI Ultra")
        )
        let fetchResult = ProviderFetchResult(usage: usage, credits: nil, dashboard: nil, sourceLabel: "antigravity", strategyID: "antigravity", strategyKind: .localProbe)
        let provider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
            ProviderFetchOutcome(result: .success(fetchResult), attempts: [])
        }

        let snapshot = try await provider.fetchQuota(now: now).get()
        XCTAssertEqual(snapshot.providerID, .antigravity)
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(snapshot.planLabel, "Google AI Ultra")
        XCTAssertEqual(snapshot.accountLabel, "dev@corp.com")
    }

    // MARK: - F9: HTTP Error, 429 Retry-After & Failure Taxonomy (5)

    func testF09_01_http401And403MapToUnauthorizedAcrossAllThreeProviders() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        for status in [401, 403] {
            let claudeProvider = ClaudeUsageProvider(
                credentialReader: E2ESpyClaudeCredentialReader(result: .success(ClaudeOAuthCredentials(accessToken: "t", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil))),
                transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((Data(), E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: status)))])
            )
            let codexProvider = CodexUsageProvider(
                credentialReader: E2ESpyCodexCredentialReader(result: .success(CodexOAuthCredentials(accessToken: "t", refreshToken: nil, idToken: nil, accountId: nil, accountEmail: nil, expiresAt: nil, lastRefresh: nil, planType: nil))),
                transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((Data(), E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: status)))])
            )
            let antigravityProvider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
                ProviderFetchOutcome(result: .failure(AntigravityStatusProbeError.authenticationRequired), attempts: [])
            }

            let r1 = await claudeProvider.fetchQuota(now: now)
            let r2 = await codexProvider.fetchQuota(now: now)
            let r3 = await antigravityProvider.fetchQuota(now: now)
            XCTAssertEqual(r1, .failure(.unauthorized))
            XCTAssertEqual(r2, .failure(.unauthorized))
            XCTAssertEqual(r3, .failure(.unauthorized))
        }
    }

    func testF09_02_http429WithNumericRetryAfter120() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let provider = CodexUsageProvider(
            credentialReader: E2ESpyCodexCredentialReader(result: .success(CodexOAuthCredentials(accessToken: "t", refreshToken: nil, idToken: nil, accountId: nil, accountEmail: nil, expiresAt: nil, lastRefresh: nil, planType: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [
                .success((Data(), E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 429, headers: ["Retry-After": "120"])))
            ])
        )
        let result = await provider.fetchQuota(now: now)
        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 120)))
    }

    func testF09_03_http404_410_503MapToEndpointUnavailable() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        for code in [404, 410, 503] {
            let provider = ClaudeUsageProvider(
                credentialReader: E2ESpyClaudeCredentialReader(result: .success(ClaudeOAuthCredentials(accessToken: "t", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil))),
                transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((Data(), E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: code)))])
            )
            let result = await provider.fetchQuota(now: now)
            XCTAssertEqual(result, .failure(.endpointUnavailable(statusCode: code)))
        }
    }

    func testF09_04_malformed200JSONMapsToDecodingFailure() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let provider = CodexUsageProvider(
            credentialReader: E2ESpyCodexCredentialReader(result: .success(CodexOAuthCredentials(accessToken: "t", refreshToken: nil, idToken: nil, accountId: nil, accountEmail: nil, expiresAt: nil, lastRefresh: nil, planType: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [
                .success((Data("{not-json".utf8), E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)))
            ])
        )
        let result = await provider.fetchQuota(now: now)
        guard case .failure(.decodingFailure) = result else {
            return XCTFail("Expected decodingFailure, got \(result)")
        }
    }

    func testF09_05_urlErrorTimedOutAndStopsAutomaticRetryTaxonomy() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let provider = ClaudeUsageProvider(
            credentialReader: E2ESpyClaudeCredentialReader(result: .success(ClaudeOAuthCredentials(accessToken: "t", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [.failure(URLError(.timedOut))])
        )
        let result = await provider.fetchQuota(now: now)
        guard case .failure(.networkFailure) = result else {
            return XCTFail("Expected networkFailure, got \(result)")
        }

        XCTAssertTrue(AIUsageFetchError.disabled.stopsAutomaticRetry)
        XCTAssertTrue(AIUsageFetchError.credentialsMissing.stopsAutomaticRetry)
        XCTAssertTrue(AIUsageFetchError.credentialsMalformed.stopsAutomaticRetry)
        XCTAssertTrue(AIUsageFetchError.tokenExpired.stopsAutomaticRetry)
        XCTAssertTrue(AIUsageFetchError.unauthorized.stopsAutomaticRetry)
        XCTAssertFalse(AIUsageFetchError.rateLimited(retryAfter: 60).stopsAutomaticRetry)
        XCTAssertFalse(AIUsageFetchError.endpointUnavailable(statusCode: 503).stopsAutomaticRetry)
        XCTAssertFalse(AIUsageFetchError.networkFailure("offline").stopsAutomaticRetry)
        XCTAssertFalse(AIUsageFetchError.decodingFailure("bad").stopsAutomaticRetry)
    }

    // MARK: - F10: Independent Per-Provider Opt-In Toggles & Style (5)

    func testF10_01_settingsDefaultsAllThreeProvidersToFalse() {
        let settings = makeIsolatedSettings()
        XCTAssertFalse(settings.claudeUsageEnabled)
        XCTAssertFalse(settings.codexUsageEnabled)
        XCTAssertFalse(settings.antigravityUsageEnabled)
        XCTAssertFalse(settings.aiUsageEnabled)
        XCTAssertFalse(settings.anyAIUsageEnabled)
        XCTAssertTrue(settings.enabledAIUsageProviders.isEmpty)
    }

    func testF10_02_enablingCodexLeavesClaudeAndAntigravityFalse() {
        let settings = makeIsolatedSettings()
        settings.codexUsageEnabled = true
        XCTAssertFalse(settings.claudeUsageEnabled)
        XCTAssertTrue(settings.codexUsageEnabled)
        XCTAssertFalse(settings.antigravityUsageEnabled)
        XCTAssertTrue(settings.aiUsageEnabled)
        XCTAssertEqual(settings.enabledAIUsageProviders, [.codex])
    }

    func testF10_03_allThreeProvidersPersistIndependentlyAcrossReload() {
        let (settings, suite, defaults) = E2EIsolatedStore.makeSettings()
        cleanup.registerSuite(suite)

        settings.antigravityUsageEnabled = true
        settings.claudeUsageEnabled = true
        XCTAssertEqual(settings.enabledAIUsageProviders, [.claude, .antigravity])

        let reloaded = LynxBar.Settings(defaults: defaults)
        XCTAssertTrue(reloaded.claudeUsageEnabled)
        XCTAssertFalse(reloaded.codexUsageEnabled)
        XCTAssertTrue(reloaded.antigravityUsageEnabled)
        XCTAssertTrue(reloaded.aiUsageEnabled)
    }

    func testF10_04_displayStyleDefaultsRemainingAndPersistsUsed() {
        let (settings, suite, defaults) = E2EIsolatedStore.makeSettings()
        cleanup.registerSuite(suite)

        XCTAssertEqual(settings.aiQuotaDisplayStyle, .remaining)
        settings.aiQuotaDisplayStyle = .used

        let reloaded = LynxBar.Settings(defaults: defaults)
        XCTAssertEqual(reloaded.aiQuotaDisplayStyle, .used)
    }

    func testF10_05_aiUsageSectionVisibleDefaultsTrueAndIsIndependent() {
        let settings = makeIsolatedSettings()
        XCTAssertTrue(settings.aiUsageSectionVisible)
        settings.aiUsageSectionVisible = false
        XCTAssertFalse(settings.claudeUsageEnabled)
        XCTAssertFalse(settings.codexUsageEnabled)
        XCTAssertFalse(settings.antigravityUsageEnabled)
        settings.claudeUsageEnabled = true
        XCTAssertFalse(settings.aiUsageSectionVisible)
    }

    // MARK: - F11: Zero Disabled Provider Reads & Network Requests (5)

    func testF11_01_allDisabledTriggersZeroReadsAndZeroHTTP() async {
        let settings = makeIsolatedSettings()
        let claudeSpy = E2ESpyAIUsageProvider(id: .claude)
        let codexSpy = E2ESpyAIUsageProvider(id: .codex)
        let antigravitySpy = E2ESpyAIUsageProvider(id: .antigravity)
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claudeSpy, .codex: codexSpy, .antigravity: antigravitySpy],
            sleeper: { try await sleeper.sleep($0) }
        )

        vm.startSampling()
        let manual = await vm.performManualRefresh()
        XCTAssertEqual(manual, .failure(.disabled))
        await E2EAsync.settle()

        let c1 = await claudeSpy.callCount
        let c2 = await codexSpy.callCount
        let c3 = await antigravitySpy.callCount
        XCTAssertEqual(c1 + c2 + c3, 0)
        vm.stopSampling()
    }

    func testF11_02_onlyClaudeEnabledLeavesCodexAndAntigravityAtZero() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let claudeSpy = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.2)))
        let codexSpy = E2ESpyAIUsageProvider(id: .codex)
        let antigravitySpy = E2ESpyAIUsageProvider(id: .antigravity)
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claudeSpy, .codex: codexSpy, .antigravity: antigravitySpy],
            sleeper: { try await sleeper.sleep($0) }
        )

        vm.startSampling()
        await claudeSpy.waitForFetchStart(atLeast: 1)
        await sleeper.waitUntilPendingCount(atLeast: 1)

        let c1 = await claudeSpy.callCount
        let c2 = await codexSpy.callCount
        let c3 = await antigravitySpy.callCount
        XCTAssertEqual(c1, 1)
        XCTAssertEqual(c2, 0)
        XCTAssertEqual(c3, 0)
        vm.stopSampling()
    }

    func testF11_03_onlyCodexEnabledLeavesClaudeAndAntigravityAtZero() async {
        let settings = makeIsolatedSettings()
        settings.codexUsageEnabled = true
        let claudeSpy = E2ESpyAIUsageProvider(id: .claude)
        let codexSpy = E2ESpyAIUsageProvider(id: .codex, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.3)))
        let antigravitySpy = E2ESpyAIUsageProvider(id: .antigravity)
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claudeSpy, .codex: codexSpy, .antigravity: antigravitySpy],
            sleeper: { try await sleeper.sleep($0) }
        )

        vm.startSampling()
        await codexSpy.waitForFetchStart(atLeast: 1)
        await sleeper.waitUntilPendingCount(atLeast: 1)

        let c1 = await claudeSpy.callCount
        let c2 = await codexSpy.callCount
        let c3 = await antigravitySpy.callCount
        XCTAssertEqual(c1, 0)
        XCTAssertEqual(c2, 1)
        XCTAssertEqual(c3, 0)
        vm.stopSampling()
    }

    func testF11_04_onlyAntigravityEnabledLeavesClaudeAndCodexAtZero() async {
        let settings = makeIsolatedSettings()
        settings.antigravityUsageEnabled = true
        let claudeSpy = E2ESpyAIUsageProvider(id: .claude)
        let codexSpy = E2ESpyAIUsageProvider(id: .codex)
        let antigravitySpy = E2ESpyAIUsageProvider(id: .antigravity, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .antigravity, usedRatio: 0.4)))
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claudeSpy, .codex: codexSpy, .antigravity: antigravitySpy],
            sleeper: { try await sleeper.sleep($0) }
        )

        vm.startSampling()
        await antigravitySpy.waitForFetchStart(atLeast: 1)
        await sleeper.waitUntilPendingCount(atLeast: 1)

        let c1 = await claudeSpy.callCount
        let c2 = await codexSpy.callCount
        let c3 = await antigravitySpy.callCount
        XCTAssertEqual(c1, 0)
        XCTAssertEqual(c2, 0)
        XCTAssertEqual(c3, 1)
        vm.stopSampling()
    }

    func testF11_05_togglingProviderOffSetsDisabledAndStopsFutureFetches() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        let claudeSpy = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.2)))
        let codexSpy = E2ESpyAIUsageProvider(id: .codex, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.4)))
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claudeSpy, .codex: codexSpy],
            sleeper: { try await sleeper.sleep($0) }
        )

        vm.startSampling()
        await claudeSpy.waitForFetchStart(atLeast: 1)
        await codexSpy.waitForFetchStart(atLeast: 1)
        await sleeper.waitUntilPendingCount(atLeast: 2)

        settings.codexUsageEnabled = false
        let didDisable = await E2EAsync.waitUntil { vm.state(for: .codex) == .disabled }
        XCTAssertTrue(didDisable)

        await sleeper.resumeAll()
        await claudeSpy.waitForFetchStart(atLeast: 2)
        await E2EAsync.settle()

        let claudeCalls = await claudeSpy.callCount
        let codexCalls = await codexSpy.callCount
        XCTAssertEqual(claudeCalls, 2)
        XCTAssertEqual(codexCalls, 1)
        vm.stopSampling()
    }

    // MARK: - F12: Demand-Driven Per-Provider State Machine (5)

    func testF12_01_monitoringDemandBindingIncludesAIUsageInOverviewButNotHealth() {
        XCTAssertTrue(MonitoringDemandBinding.modules(for: .overview).contains(.aiUsage))
        XCTAssertTrue(MonitoringDemandBinding.modules(for: .aiUsage).contains(.aiUsage))
        XCTAssertFalse(MonitoringDemandBinding.overviewHealthModules.contains(.aiUsage))
    }

    func testF12_02_independentPerProviderStatesCoexistSimultaneously() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        let claudeSpy = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.25)))
        let codexSpy = E2ESpyAIUsageProvider(id: .codex, fallback: .failure(.tokenExpired))
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claudeSpy, .codex: codexSpy],
            sleeper: { try await sleeper.sleep($0) }
        )

        vm.startSampling()
        let ready = await E2EAsync.waitUntil {
            if case .loaded = vm.state(for: .claude),
               case .error(.tokenExpired) = vm.state(for: .codex) {
                return true
            }
            return false
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(vm.state(for: .antigravity), .disabled)
        vm.stopSampling()
    }

    func testF12_03_sixtySecondCooldownSuppressesReopenBefore60sAndFetchesAfter() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let claudeSpy = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.25)))
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claudeSpy],
            sleeper: { try await sleeper.sleep($0) },
            now: clock.makeProvider()
        )

        vm.startSampling()
        await claudeSpy.waitForFetchStart(atLeast: 1)
        let firstDone = await E2EAsync.waitUntil { vm.snapshot(for: .claude) != nil }
        XCTAssertTrue(firstDone)
        vm.stopSampling()

        clock.advance(by: 45)
        vm.startSampling()
        await sleeper.waitUntilPendingCount(atLeast: 1)
        let callsDuringCooldown = await claudeSpy.callCount
        XCTAssertEqual(callsDuringCooldown, 1)
        vm.stopSampling()

        clock.advance(by: 20) // total 65s >= 60s
        vm.startSampling()
        await claudeSpy.waitForFetchStart(atLeast: 2)
        let callsAfterCooldown = await claudeSpy.callCount
        XCTAssertEqual(callsAfterCooldown, 2)
        vm.stopSampling()
    }

    func testF12_04_fiveSecondManualThrottleIsPerProviderIndependent() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        let claudeSpy = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.2)))
        let codexSpy = E2ESpyAIUsageProvider(id: .codex, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.3)))
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claudeSpy, .codex: codexSpy],
            now: clock.makeProvider()
        )

        let r1 = await vm.performManualRefresh(for: .claude)
        XCTAssertNotNil(r1)

        clock.advance(by: 2)
        let throttledClaude = await vm.performManualRefresh(for: .claude)
        XCTAssertNil(throttledClaude)

        let unthrottledCodex = await vm.performManualRefresh(for: .codex)
        XCTAssertNotNil(unthrottledCodex)

        let c1 = await claudeSpy.callCount
        let c2 = await codexSpy.callCount
        XCTAssertEqual(c1, 1)
        XCTAssertEqual(c2, 1)
    }

    func testF12_05_429TriggersExponentialBackoffWhileRetainingStaleSnapshot() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let snapshot = E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.25)
        let claudeSpy = E2ESpyAIUsageProvider(
            id: .claude,
            results: [
                .success(snapshot),
                .failure(.rateLimited(retryAfter: nil)),
                .failure(.rateLimited(retryAfter: nil)),
            ],
            fallback: .failure(.rateLimited(retryAfter: nil))
        )
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: claudeSpy],
            sleeper: { try await sleeper.sleep($0) },
            now: clock.makeProvider()
        )

        vm.startSampling()
        await sleeper.waitUntilPendingCount(atLeast: 1) // 300s after success
        await sleeper.resumeNext()
        await sleeper.waitUntilPendingCount(atLeast: 1) // 300s backoff #1
        await sleeper.resumeNext()
        await sleeper.waitUntilPendingCount(atLeast: 1) // 600s backoff #2

        let delays = await sleeper.recordedDelays
        XCTAssertEqual(delays, [300, 300, 600])
        if case .stale(let retained, let err) = vm.state(for: .claude) {
            XCTAssertEqual(retained.primaryWindow?.usedRatio, 0.25)
            XCTAssertEqual(err, .rateLimited(retryAfter: nil))
        } else {
            XCTFail("Expected .stale state, got \(vm.state(for: .claude))")
        }
        vm.stopSampling()
    }

    // MARK: - F13: Multi-Entry AI Panel & CLI Remediation Views (5)

    func testF13_01_allDisabledPanelRendersOnboardingWithoutErrors() {
        let settings = makeIsolatedSettings()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [:]
        )
        XCTAssertTrue(vm.enabledProviderIDs.isEmpty)
        XCTAssertEqual(vm.state, .disabled)

        let origClaude = LynxBar.Settings.shared.claudeUsageEnabled
        let origCodex = LynxBar.Settings.shared.codexUsageEnabled
        let origAntigravity = LynxBar.Settings.shared.antigravityUsageEnabled
        defer {
            LynxBar.Settings.shared.claudeUsageEnabled = origClaude
            LynxBar.Settings.shared.codexUsageEnabled = origCodex
            LynxBar.Settings.shared.antigravityUsageEnabled = origAntigravity
        }
        LynxBar.Settings.shared.claudeUsageEnabled = false
        LynxBar.Settings.shared.codexUsageEnabled = false
        LynxBar.Settings.shared.antigravityUsageEnabled = false

        var section: DashboardSection = .aiUsage
        let view = AIUsagePanelView(viewModel: vm, selection: Binding(get: { section }, set: { section = $0 }))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 100)
    }

    func testF13_02_multipleProvidersEnabledLoadedPresentInDeterministicOrder() async {
        let settings = makeIsolatedSettings()
        settings.antigravityUsageEnabled = true
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.2))),
                .codex: E2ESpyAIUsageProvider(id: .codex, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.4))),
                .antigravity: E2ESpyAIUsageProvider(id: .antigravity, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .antigravity, usedRatio: 0.6))),
            ]
        )
        _ = await vm.performManualRefresh()
        XCTAssertEqual(vm.enabledProviderIDs, [.claude, .codex, .antigravity])
        XCTAssertEqual(vm.activeSnapshots.map(\.providerID), [.claude, .codex, .antigravity])
    }

    func testF13_03_thresholdColorClassificationMatchesContract() throws {
        let panelURL = E2ERepoInspector.repoRootURL()
            .appendingPathComponent("Sources/LynxBar/Modules/AIUsage/AIUsagePanelView.swift")
        let rowURL = E2ERepoInspector.repoRootURL()
            .appendingPathComponent("Sources/LynxBar/Modules/AIUsage/OverviewAIQuotaRow.swift")
        let panelSource = try String(contentsOf: panelURL, encoding: .utf8)
        let rowSource = try String(contentsOf: rowURL, encoding: .utf8)

        for source in [panelSource, rowSource] {
            XCTAssertTrue(source.contains("if window.remainingRatio <= 0.10 { return Theme.critical }"))
            XCTAssertTrue(source.contains("if window.remainingRatio <= 0.30 { return Theme.warning }"))
            XCTAssertTrue(source.contains("return Theme.health"))
        }
    }

    func testF13_04_errorStateSuppliesExactCLILoginCommandPerProvider() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        settings.antigravityUsageEnabled = true

        let vm = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: E2ESpyAIUsageProvider(id: .claude, fallback: .failure(.tokenExpired)),
                .codex: E2ESpyAIUsageProvider(id: .codex, fallback: .failure(.unauthorized)),
                .antigravity: E2ESpyAIUsageProvider(id: .antigravity, fallback: .failure(.credentialsMissing)),
            ]
        )
        _ = await vm.performManualRefresh()
        for id in AIUsageProviderID.allCases {
            let err = vm.lastError(for: id)
            XCTAssertTrue(err?.stopsAutomaticRetry == true)
        }
        XCTAssertEqual(AIUsageProviderID.claude.cliLoginCommand, "claude /login")
        XCTAssertEqual(AIUsageProviderID.codex.cliLoginCommand, "codex login")
        XCTAssertEqual(AIUsageProviderID.antigravity.cliLoginCommand, "agy login")
    }

    func testF13_05_aiUsagePanelViewReusesV2ComponentsWithZeroLegacyControls() throws {
        let url = E2ERepoInspector.repoRootURL()
            .appendingPathComponent("Sources/LynxBar/Modules/AIUsage/AIUsagePanelView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("V2Card"))
        XCTAssertTrue(source.contains("LynxProgressBar"))
        XCTAssertTrue(source.contains("LynxSegmentedPill"))
        XCTAssertTrue(source.contains("LynxActionPillButton"))
        XCTAssertFalse(source.contains("ProgressView(value:"))
        XCTAssertFalse(source.contains(".borderedProminent"))
    }

    // MARK: - F14: OverviewAIQuotaRow 36pt & 420x600 Geometry (5)

    func testF14_01_overviewAIQuotaRowHeightConstantIs36() {
        XCTAssertEqual(OverviewLayoutMetrics.aiQuotaRowHeight, 36)
    }

    func testF14_02_overviewTotalHeightAIDisabledWithin496Budget() {
        let total = OverviewLayoutMetrics.totalHeight(aiEnabled: false)
        XCTAssertLessThanOrEqual(total, OverviewLayoutMetrics.availableOverviewHeight)
        XCTAssertEqual(total, 494)
    }

    func testF14_03_overviewTotalHeightAIEnabledWithin496Budget() {
        let total = OverviewLayoutMetrics.totalHeight(aiEnabled: true)
        XCTAssertLessThanOrEqual(total, OverviewLayoutMetrics.availableOverviewHeight)
        XCTAssertEqual(total, 494)
    }

    func testF14_04_overviewAIQuotaRowRenders1_2_3ProvidersAt36ptHeight() async {
        let settings = makeIsolatedSettings()
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.25))),
                .codex: E2ESpyAIUsageProvider(id: .codex, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.45))),
                .antigravity: E2ESpyAIUsageProvider(id: .antigravity, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .antigravity, usedRatio: 0.75))),
            ]
        )

        for provider in AIUsageProviderID.allCases {
            settings.setAIProviderEnabled(true, for: provider)
            _ = await vm.performManualRefresh(for: provider)
            var sel: DashboardSection = .overview
            let row = OverviewAIQuotaRow(aiUsage: vm, selection: Binding(get: { sel }, set: { sel = $0 }))
            let host = NSHostingView(rootView: row)
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 36)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.height, 36, accuracy: 0.5)
        }
    }

    func testF14_05_overviewProcessCardContentFitsAllocatedCardHeight() {
        for aiEnabled in [false, true] {
            XCTAssertLessThanOrEqual(
                OverviewLayoutMetrics.processCardContentHeight(aiEnabled: aiEnabled),
                OverviewLayoutMetrics.processCardHeight(aiEnabled: aiEnabled)
            )
            XCTAssertEqual(OverviewLayoutMetrics.visibleProcessRowCount, 3)
        }
    }

    // MARK: - F15: Menu Bar AI Slot Formatting, Budgets & 900s TTL (5)

    func testF15_01_singleEnabledProviderFormatsWithinFocusAndCompactBudgets() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let snapshot = MenuBarStatusSnapshot(
            health: .healthy,
            readings: [.aiUsage: .aiQuota(usedRatio: 0.22, observedAt: now)]
        )
        let focus = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: snapshot, locale: Locale(identifier: "en"), now: now)
        let compact = MenuBarStatusFormatter.format(mode: .compact, slots: [.aiUsage, .cpu, .memory], snapshot: snapshot, locale: Locale(identifier: "en"), now: now)

        XCTAssertTrue(focus.title.contains("AI 78%"))
        XCTAssertLessThanOrEqual(MenuBarStatusRenderer.layout(for: focus).width, 132)
        XCTAssertLessThanOrEqual(MenuBarStatusRenderer.layout(for: compact).width, 300)
    }

    func testF15_02_multipleEnabledProvidersFormatWithinFocusAndCompactBudgets() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let entries = [
            MenuBarAIQuotaEntry(providerID: .claude, usedRatio: 0.20, observedAt: now),
            MenuBarAIQuotaEntry(providerID: .codex, usedRatio: 0.70, observedAt: now),
            MenuBarAIQuotaEntry(providerID: .antigravity, usedRatio: 0.40, observedAt: now),
        ]
        let snapshot = MenuBarStatusSnapshot(
            health: .healthy,
            readings: [
                .aiUsage: .aiQuotas(entries, displayStyle: .remaining),
                .cpu: .numeric(0.50, observedAt: now),
                .memory: .numeric(0.60, observedAt: now),
            ]
        )
        let focus = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: snapshot, locale: Locale(identifier: "en"), now: now)
        let compact = MenuBarStatusFormatter.format(mode: .compact, slots: [.cpu, .memory, .aiUsage], snapshot: snapshot, locale: Locale(identifier: "en"), now: now)

        // Most constrained provider is Codex (70% used -> 30% remaining)
        XCTAssertTrue(focus.title.contains("AI 30%"))
        XCTAssertLessThanOrEqual(MenuBarStatusRenderer.layout(for: focus).width, 132)
        XCTAssertLessThanOrEqual(MenuBarStatusRenderer.layout(for: compact).width, 300)
    }

    func testF15_03_disabledOrUnavailableAISlotFallsBackToDash() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let snapshot = MenuBarStatusSnapshot(health: .healthy, readings: [.aiUsage: .unavailable])
        let focus = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: snapshot, now: now)
        XCTAssertTrue(focus.title.contains("AI —"))
    }

    func testF15_04_menuBarTTL900SecondsFreshAt899AndStaleAt901() {
        XCTAssertEqual(AIUsageViewModel.menuBarTTL, 900)
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let reading = MenuBarMetricReading.aiQuota(usedRatio: 0.25, observedAt: t0, staleAfter: AIUsageViewModel.menuBarTTL)

        let freshSnapshot = MenuBarStatusSnapshot(health: .healthy, readings: [.aiUsage: reading])
        let at899 = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: freshSnapshot, now: t0.addingTimeInterval(899))
        let at901 = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: freshSnapshot, now: t0.addingTimeInterval(901))

        XCTAssertEqual(reading.resolvedAvailability(at: t0.addingTimeInterval(899)), .available)
        XCTAssertTrue(at899.title.contains("AI 75%"))
        XCTAssertEqual(reading.resolvedAvailability(at: t0.addingTimeInterval(901)), .stale)
        XCTAssertTrue(at901.title.contains("AI —"))
    }

    func testF15_05_bilingualAccessibilityDescriptionsRenderInEnAndZhHans() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let entries = [
            MenuBarAIQuotaEntry(providerID: .claude, usedRatio: 0.25, resetsAt: now.addingTimeInterval(3_600), observedAt: now),
            MenuBarAIQuotaEntry(providerID: .codex, usedRatio: 0.50, observedAt: now),
        ]
        let snapshot = MenuBarStatusSnapshot(health: .healthy, readings: [.aiUsage: .aiQuotas(entries, displayStyle: .remaining)])
        let en = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: snapshot, locale: Locale(identifier: "en"), now: now)
        let zh = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: snapshot, locale: Locale(identifier: "zh-Hans"), now: now)

        XCTAssertTrue(en.accessibilityLabel.contains("Claude quota 75% remaining"))
        XCTAssertTrue(en.accessibilityLabel.contains("OpenAI Codex quota 50% remaining"))
        XCTAssertTrue(zh.accessibilityLabel.contains("Claude 额度剩余 75%"))
        XCTAssertTrue(zh.accessibilityLabel.contains("OpenAI Codex 额度剩余 50%"))
    }

    // MARK: - F16: Bilingual en / zh-Hans Key & Specifier Parity (5)

    func testF16_01_localizableStringsFilesParseCleanlyAsValidPropertyLists() throws {
        let root = E2ERepoInspector.repoRootURL()
        let enURL = root.appendingPathComponent("Sources/LynxBar/Resources/en.lproj/Localizable.strings")
        let zhURL = root.appendingPathComponent("Sources/LynxBar/Resources/zh-Hans.lproj/Localizable.strings")

        let enParsed = try E2ERepoInspector.parseLocalizableStrings(at: enURL)
        let zhParsed = try E2ERepoInspector.parseLocalizableStrings(at: zhURL)
        XCTAssertGreaterThan(enParsed.entries.count, 700)
        XCTAssertGreaterThan(zhParsed.entries.count, 700)
    }

    func testF16_02_zeroDuplicateKeysInEnAndZhHansStrings() throws {
        let root = E2ERepoInspector.repoRootURL()
        let enParsed = try E2ERepoInspector.parseLocalizableStrings(at: root.appendingPathComponent("Sources/LynxBar/Resources/en.lproj/Localizable.strings"))
        let zhParsed = try E2ERepoInspector.parseLocalizableStrings(at: root.appendingPathComponent("Sources/LynxBar/Resources/zh-Hans.lproj/Localizable.strings"))

        XCTAssertTrue(enParsed.duplicates.isEmpty, "Duplicate keys in en: \(enParsed.duplicates)")
        XCTAssertTrue(zhParsed.duplicates.isEmpty, "Duplicate keys in zh-Hans: \(zhParsed.duplicates)")
    }

    func testF16_03_keySetEqualityBetweenEnAndZhHans() throws {
        let root = E2ERepoInspector.repoRootURL()
        let enParsed = try E2ERepoInspector.parseLocalizableStrings(at: root.appendingPathComponent("Sources/LynxBar/Resources/en.lproj/Localizable.strings"))
        let zhParsed = try E2ERepoInspector.parseLocalizableStrings(at: root.appendingPathComponent("Sources/LynxBar/Resources/zh-Hans.lproj/Localizable.strings"))

        let enKeys = Set(enParsed.entries.keys)
        let zhKeys = Set(zhParsed.entries.keys)
        XCTAssertEqual(enKeys.subtracting(zhKeys), [])
        XCTAssertEqual(zhKeys.subtracting(enKeys), [])
    }

    func testF16_04_formatSpecifierSequenceEqualityAcrossAllKeys() throws {
        let root = E2ERepoInspector.repoRootURL()
        let enParsed = try E2ERepoInspector.parseLocalizableStrings(at: root.appendingPathComponent("Sources/LynxBar/Resources/en.lproj/Localizable.strings"))
        let zhParsed = try E2ERepoInspector.parseLocalizableStrings(at: root.appendingPathComponent("Sources/LynxBar/Resources/zh-Hans.lproj/Localizable.strings"))

        // Verify exact ordered specifier extraction catches swaps and ignores prose "%" such as "5% or".
        XCTAssertEqual(E2ERepoInspector.extractFormatSpecifiers(from: "below 5% or 10 GB"), [])
        XCTAssertNotEqual(
            E2ERepoInspector.extractFormatSpecifiers(from: "%@ %lld"),
            E2ERepoInspector.extractFormatSpecifiers(from: "%lld %@")
        )

        for key in enParsed.entries.keys.sorted() {
            let enSpecs = E2ERepoInspector.extractFormatSpecifiers(from: enParsed.entries[key] ?? "")
            let zhSpecs = E2ERepoInspector.extractFormatSpecifiers(from: zhParsed.entries[key] ?? "")
            XCTAssertEqual(enSpecs, zhSpecs, "Format specifier mismatch for key: \(key)")
        }
    }

    func testF16_05_multiProviderAIKeysResolveInAppBundle() {
        let keys = [
            "OpenAI Codex",
            "Codex",
            "Antigravity",
            "AI Subscription Quota",
            "Credits",
            "Codex CLI",
            "Antigravity CLI",
            "OpenAI",
            "Google",
            "Unlimited",
        ]
        for key in keys {
            XCTAssertNotNil(E2ERepoInspector.localizedString(key, localeIdentifier: "en"), "Missing en key: \(key)")
            XCTAssertNotNil(E2ERepoInspector.localizedString(key, localeIdentifier: "zh-Hans"), "Missing zh-Hans key: \(key)")
        }
    }

    // MARK: - F17: Dynamic Type Compliance (5)

    func testF17_01_zeroFixedSystemPointSizesInSources() throws {
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar")
        let regex = try NSRegularExpression(pattern: #"\.system\(\s*size:"#)
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            let matches = regex.numberOfMatches(in: content, range: range)
            XCTAssertEqual(matches, 0, "Found forbidden .system(size:) in \(file.lastPathComponent)")
        }
    }

    func testF17_02_aiViewsReferenceThemeFontTokensOnly() throws {
        let root = E2ERepoInspector.repoRootURL()
        let aiPanel = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Modules/AIUsage/AIUsagePanelView.swift"), encoding: .utf8)
        let aiRow = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Modules/AIUsage/OverviewAIQuotaRow.swift"), encoding: .utf8)

        for source in [aiPanel, aiRow] {
            XCTAssertTrue(source.contains("Theme.Font."))
            XCTAssertFalse(source.contains(".font(.system("))
        }
    }

    func testF17_03_themeFontDefinesSemanticDynamicTypeHierarchy() throws {
        let themeURL = E2ERepoInspector.repoRootURL().appendingPathComponent("Sources/LynxBar/Kit/Theme.swift")
        let source = try String(contentsOf: themeURL, encoding: .utf8)
        let expectedTokens = [
            "SwiftUI.Font.system(.title2,",
            "SwiftUI.Font.system(.title3,",
            "SwiftUI.Font.system(.body,",
            "SwiftUI.Font.system(.callout,",
            "SwiftUI.Font.system(.subheadline,",
            "SwiftUI.Font.system(.caption,",
            "SwiftUI.Font.system(.caption2,",
            "SwiftUI.Font.system(.largeTitle,",
        ]
        for token in expectedTokens {
            XCTAssertTrue(source.contains(token), "Missing Theme.Font semantic style: \(token)")
        }
    }

    func testF17_04_themeFontTokensAreConstructible() {
        let fonts: [SwiftUI.Font] = [
            Theme.Font.title,
            Theme.Font.title2,
            Theme.Font.title3,
            Theme.Font.body,
            Theme.Font.bodyRounded,
            Theme.Font.callout,
            Theme.Font.subheadline,
            Theme.Font.subheadlineRounded,
            Theme.Font.caption,
            Theme.Font.captionMono,
            Theme.Font.micro,
        ]
        XCTAssertEqual(fonts.count, 11)
    }

    func testF17_05_aiViewsScaleUnderDynamicTypeAX3WithoutClippingRowBudget() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.35))),
                .codex: E2ESpyAIUsageProvider(id: .codex, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.55))),
            ]
        )
        _ = await vm.performManualRefresh()

        var sel: DashboardSection = .overview
        let row = OverviewAIQuotaRow(aiUsage: vm, selection: Binding(get: { sel }, set: { sel = $0 }))
            .environment(\.dynamicTypeSize, .accessibility3)
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 36)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, 36, accuracy: 0.5)
    }

    // MARK: - F18: Secret-Redacting os.Logger & Zero Cookie/CLI Side Effects (5)

    func testF18_01_credentialDescriptionsRedactAllTokensAndPII() {
        let canary = "CANARY-SECRET-TOKEN-ABC-999"
        let claude = ClaudeOAuthCredentials(accessToken: canary, expiresAt: nil, subscriptionType: "max", rateLimitTier: nil)
        let codex = CodexOAuthCredentials(accessToken: canary, refreshToken: canary, idToken: canary, accountId: "acct_1", accountEmail: "secret@example.com", expiresAt: nil, lastRefresh: nil, planType: "pro")

        for desc in [
            String(describing: claude), String(reflecting: claude),
            String(describing: codex), String(reflecting: codex),
        ] {
            XCTAssertTrue(desc.contains("[REDACTED]"))
            XCTAssertFalse(desc.contains(canary))
            XCTAssertFalse(desc.contains("secret@example.com"))
        }
    }

    func testF18_02_aiFilesNeverLogTokensAuthorizationOrResponseBodies() throws {
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Providers/AIUsage")
            + E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Modules/AIUsage")
        let logCallRegex = try NSRegularExpression(pattern: #"Log\.[A-Za-z_]+\.[A-Za-z_]+\((?:[^()]|\([^()]*\))*\)"#)
        let interpolationRegex = try NSRegularExpression(pattern: #"\\\(([^)]*)\)"#)
        let forbiddenInterpolations = [
            "accessToken", "refreshToken", "idToken", "Authorization",
            "credentials", "fileData", "quotaData", "loadAssistData", "String(data:",
        ]

        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
            for match in logCallRegex.matches(in: content, range: fullRange) {
                guard let callRange = Range(match.range, in: content) else { continue }
                let callText = String(content[callRange])
                XCTAssertFalse(callText.contains("Bearer "), "Log contains Bearer header in \(file.lastPathComponent)")
                let callNSRange = NSRange(callText.startIndex..<callText.endIndex, in: callText)
                for interp in interpolationRegex.matches(in: callText, range: callNSRange) {
                    guard let exprRange = Range(interp.range(at: 1), in: callText) else { continue }
                    let expr = String(callText[exprRange])
                    for forbidden in forbiddenInterpolations {
                        XCTAssertFalse(
                            expr.contains(forbidden),
                            "Log interpolates \(forbidden) in \(file.lastPathComponent): \(expr)"
                        )
                    }
                }
            }
        }
    }

    func testF18_03_aiLoggerCallsMarkPathsAndErrorsPrivate() throws {
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Providers/AIUsage")
            + E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Modules/AIUsage")

        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            let normalized = content.replacingOccurrences(of: "\n", with: " ")
            if normalized.contains("error.localizedDescription") && normalized.contains("Log.") {
                XCTAssertTrue(content.contains("error.localizedDescription, privacy: .private"), "Missing .private on error.localizedDescription in \(file.lastPathComponent)")
            }
            if normalized.contains(".path,") && normalized.contains("Log.") {
                XCTAssertTrue(content.contains(".path, privacy: .private"), "Missing .private on path in \(file.lastPathComponent)")
            }
        }
    }

    func testF18_04_aiProvidersContainZeroCookieBrowserOrProcessAPIs() throws {
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Providers/AIUsage")
            + E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Modules/AIUsage")
        let forbidden = ["HTTPCookie", "NSHTTPCookieStorage", "Cookies.binarycookies", "NSWorkspace.shared.open", "Process("]

        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            for term in forbidden {
                XCTAssertFalse(content.contains(term), "Forbidden API \(term) found in \(file.lastPathComponent)")
            }
        }
    }

    func testF18_05_runtimeProvidersNeverSendCookieHeaderOrTouchSharedCookieStorage() async throws {
        let beforeCookies = HTTPCookieStorage.shared.cookies ?? []
        let response1 = "HTTP/1.1 200 OK\r\nSet-Cookie: lynx_canary=secret_cookie; Path=/; HttpOnly\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        let response2 = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"

        let server = try E2ELoopbackHTTPServer(responses: [response1, response2])
        cleanup.registerLoopbackServer(server)
        defer { server.stop() }

        let client = AIUsageHTTPClient(timeout: 5)
        let (data1, http1) = try await client.data(for: URLRequest(url: server.url(path: "/step1")))
        XCTAssertEqual(http1.statusCode, 200)
        XCTAssertEqual(String(data: data1, encoding: .utf8), "{}")
        XCTAssertEqual(http1.value(forHTTPHeaderField: "Set-Cookie"), "lynx_canary=secret_cookie; Path=/; HttpOnly")

        let (data2, http2) = try await client.data(for: URLRequest(url: server.url(path: "/step2")))
        XCTAssertEqual(http2.statusCode, 200)
        XCTAssertEqual(String(data: data2, encoding: .utf8), "{}")

        let captured = server.capturedRequests
        XCTAssertEqual(captured.count, 2)
        let req2HeaderLines = E2ELoopbackHTTPServer.headerLines(from: captured[1])
        XCTAssertFalse(
            req2HeaderLines.contains { $0.lowercased().hasPrefix("cookie:") },
            "Unexpected Cookie header sent by AIUsageHTTPClient: \(req2HeaderLines)"
        )
        XCTAssertFalse(captured[1].contains("lynx_canary"))
        XCTAssertFalse(captured[1].contains("secret_cookie"))

        let afterCookies = HTTPCookieStorage.shared.cookies ?? []
        XCTAssertFalse(afterCookies.contains { $0.name == "lynx_canary" || $0.value.contains("secret_cookie") })
        XCTAssertEqual(afterCookies.count, beforeCookies.count)
    }

    // MARK: - F19: CodexBarCore Integration & Swift 6 Strict Concurrency Compliance (5)

    func testF19_01_projectYmlDeclaresCodexBarCoreOnlyAndZeroCocoaPods() throws {
        let ymlURL = E2ERepoInspector.repoRootURL().appendingPathComponent("project.yml")
        let yml = try String(contentsOf: ymlURL, encoding: .utf8)
        XCTAssertTrue(yml.contains("CodexBarCore"))
        XCTAssertFalse(yml.lowercased().contains("cocoapods"))
    }

    func testF19_02_projectYmlEnforcesSwift6StrictConcurrencyAndMacOS14Target() throws {
        let ymlURL = E2ERepoInspector.repoRootURL().appendingPathComponent("project.yml")
        let yml = try String(contentsOf: ymlURL, encoding: .utf8)
        XCTAssertTrue(yml.contains(#"SWIFT_VERSION: "6.0""#))
        XCTAssertTrue(yml.contains("SWIFT_STRICT_CONCURRENCY: complete"))
        XCTAssertTrue(yml.contains(#"MACOSX_DEPLOYMENT_TARGET: "14.0""#))
    }

    func testF19_03_aiSourcesContainZeroUncheckedSendable() throws {
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Providers/AIUsage")
            + E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Modules/AIUsage")
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(content.contains("@unchecked Sendable"), "Found @unchecked Sendable in \(file.lastPathComponent)")
        }
    }

    func testF19_04_aiSourcesContainZeroDispatchSemaphoreBlocking() throws {
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Providers/AIUsage")
            + E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Modules/AIUsage")
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(content.contains("DispatchSemaphore"), "Found DispatchSemaphore in \(file.lastPathComponent)")
        }
    }

    func testF19_05_aiProvidersAreStrictlyReadOnlyZeroKeychainOrDiskWrites() throws {
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Providers/AIUsage")
        let forbidden = ["SecItemAdd", "SecItemUpdate", "SecItemDelete", ".write(", "createFile(", "removeItem("]
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            for term in forbidden {
                XCTAssertFalse(content.contains(term), "Write API \(term) found in \(file.lastPathComponent)")
            }
        }
    }

    // MARK: - F20: Phase 1+2 Preservation, V2 Reuse & Docs/Comments (5)

    func testF20_01_phase1And2GlassAndUXTokensRemainIntact() throws {
        let root = E2ERepoInspector.repoRootURL()
        let v2 = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Kit/V2Components.swift"), encoding: .utf8)
        let mem = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Modules/Memory/MemoryPanelView.swift"), encoding: .utf8)
        let disk = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Modules/Disk/DiskPanelView.swift"), encoding: .utf8)
        let dash = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Modules/Dashboard/DashboardView.swift"), encoding: .utf8)

        XCTAssertTrue(v2.contains("VisualEffectBackdrop"))
        XCTAssertTrue(v2.contains("V2Card"))
        XCTAssertTrue(mem.contains("High swap"))
        XCTAssertTrue(mem.contains("Elevated"))
        XCTAssertTrue(disk.contains("V2Card"))
        XCTAssertTrue(dash.contains("AIUsagePanelView"))
    }

    func testF20_02_aiViewsReuseV2Components() throws {
        let root = E2ERepoInspector.repoRootURL()
        let panel = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Modules/AIUsage/AIUsagePanelView.swift"), encoding: .utf8)
        let row = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Modules/AIUsage/OverviewAIQuotaRow.swift"), encoding: .utf8)

        XCTAssertTrue(panel.contains("V2Card"))
        XCTAssertTrue(panel.contains("LynxProgressBar"))
        XCTAssertTrue(panel.contains("LynxSegmentedPill"))
        XCTAssertTrue(panel.contains("LynxActionPillButton"))
        XCTAssertTrue(row.contains("V2Card"))
        XCTAssertTrue(row.contains("LynxProgressBar"))
    }

    func testF20_03_newCodexAntigravityAndAIModuleFunctionsHaveDocComments() throws {
        let targetFiles = [
            "Sources/LynxBar/Providers/AIUsage/AIUsageModels.swift",
            "Sources/LynxBar/Providers/AIUsage/AIUsageParsing.swift",
            "Sources/LynxBar/Providers/AIUsage/CodexCredentialReader.swift",
            "Sources/LynxBar/Providers/AIUsage/CodexUsageProvider.swift",
            "Sources/LynxBar/Providers/AIUsage/CodexBarUsageProvider.swift",
            "Sources/LynxBar/Modules/AIUsage/AIUsageViewModel.swift",
            "Sources/LynxBar/Modules/AIUsage/OverviewAIQuotaRow.swift",
        ]
        for rel in targetFiles {
            let url = E2ERepoInspector.repoRootURL().appendingPathComponent(rel)
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("func ") || trimmed.hasPrefix("static func ") || trimmed.hasPrefix("private func ") || trimmed.hasPrefix("nonisolated static func ") {
                    let prevLines = lines[max(0, idx - 6)..<idx].map { $0.trimmingCharacters(in: .whitespaces) }
                    let hasDoc = prevLines.contains { $0.hasPrefix("///") }
                    XCTAssertTrue(hasDoc, "Missing /// doc comment above function at \(rel):\(idx + 1): \(trimmed)")
                }
            }
        }
    }

    func testF20_04_docsCoverCodexAntigravityAndMultiProviderArchitecture() throws {
        let root = E2ERepoInspector.repoRootURL()
        let archDoc = try String(contentsOf: root.appendingPathComponent("docs/architecture/lynxbar-ai-quota-and-opensource-plan.md"), encoding: .utf8)
        let guideDoc = try String(contentsOf: root.appendingPathComponent("docs/guides/user-guide.md"), encoding: .utf8)

        for doc in [archDoc, guideDoc] {
            XCTAssertTrue(doc.contains("Claude"))
            XCTAssertTrue(doc.contains("Codex"))
            XCTAssertTrue(doc.contains("Antigravity"))
        }
    }

    func testF20_05_readmeAndDocsContainZeroStaleClaudeOnlyClaims() throws {
        let root = E2ERepoInspector.repoRootURL()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let readmeZH = try String(contentsOf: root.appendingPathComponent("README.zh-CN.md"), encoding: .utf8)

        XCTAssertTrue(readme.contains("OpenAI Codex"))
        XCTAssertTrue(readme.contains("Antigravity"))
        XCTAssertTrue(readmeZH.contains("OpenAI Codex"))
        XCTAssertTrue(readmeZH.contains("Antigravity"))
        XCTAssertFalse(readme.lowercased().contains("claude-only"))
        XCTAssertFalse(readmeZH.contains("仅支持 Claude"))
    }
}
