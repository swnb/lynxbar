import Foundation
import os
import XCTest
@testable import LynxBar

/// Offline unit tests for `CodexCredentialReader` and `CodexUsageProvider`.
final class CodexUsageProviderTests: XCTestCase {
    private let baseNow = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - CodexCredentialReader Tests

    /// Verifies `$CODEX_HOME/auth.json` takes precedence over `~/.codex/auth.json`
    /// and whitespace-only `CODEX_HOME` falls back to `~/.codex/auth.json`.
    func testPathResolutionForCodexHomeAndDefaultDirectory() {
        let fakeHome = URL(fileURLWithPath: "/Users/testuser", isDirectory: true)

        let customURL = CodexCredentialReader.resolveAuthFileURL(
            environment: ["CODEX_HOME": " /opt/custom-codex "],
            homeDirectory: fakeHome
        )
        XCTAssertEqual(customURL.path, "/opt/custom-codex/auth.json")

        let whitespaceEnvURL = CodexCredentialReader.resolveAuthFileURL(
            environment: ["CODEX_HOME": "   \n  "],
            homeDirectory: fakeHome
        )
        XCTAssertEqual(whitespaceEnvURL.path, "/Users/testuser/.codex/auth.json")

        let defaultURL = CodexCredentialReader.resolveAuthFileURL(
            environment: [:],
            homeDirectory: fakeHome
        )
        XCTAssertEqual(defaultURL.path, "/Users/testuser/.codex/auth.json")
    }

    /// Verifies missing file, malformed JSON, and API-key-only `auth.json` error mappings.
    func testMissingMalformedAndAPIKeyOnlyCredentials() {
        let missingReader = CodexCredentialReader(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/testuser"),
            fileReader: { _ in nil }
        )
        XCTAssertEqual(missingReader.readCredentials(now: baseNow), .failure(.credentialsMissing))

        let malformedReader = CodexCredentialReader(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/testuser"),
            fileReader: { _ in Data("{broken".utf8) }
        )
        XCTAssertEqual(malformedReader.readCredentials(now: baseNow), .failure(.credentialsMalformed))

        let apiKeyOnlyJSON = """
        {
          "OPENAI_API_KEY": "sk-proj-only-api-key",
          "tokens": null
        }
        """
        let apiKeyReader = CodexCredentialReader(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/testuser"),
            fileReader: { _ in Data(apiKeyOnlyJSON.utf8) }
        )
        XCTAssertEqual(apiKeyReader.readCredentials(now: baseNow), .failure(.credentialsMissing))

        let emptyAccessTokenJSON = """
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "access_token": "   "
          }
        }
        """
        let emptyTokenReader = CodexCredentialReader(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/testuser"),
            fileReader: { _ in Data(emptyAccessTokenJSON.utf8) }
        )
        XCTAssertEqual(emptyTokenReader.readCredentials(now: baseNow), .failure(.credentialsMissing))
    }

    /// Verifies JWT `exp` expiry validation with a 30-second safety margin and `last_refresh` 8-day fallback.
    func testExpiryPreCheckWithJWTMarginAndLastRefreshFallback() {
        let boundaryExp = Int64(baseNow.timeIntervalSince1970 + 30)
        let validExp = Int64(baseNow.timeIntervalSince1970 + 31)

        let expiredJWT = makeJWT(payload: #"{"exp": \#(boundaryExp)}"#)
        let validJWT = makeJWT(payload: #"{"exp": \#(validExp)}"#)

        XCTAssertEqual(
            makeCodexReader(accessToken: expiredJWT, lastRefresh: nil).readCredentials(now: baseNow),
            .failure(.tokenExpired)
        )
        guard case .success = makeCodexReader(accessToken: validJWT, lastRefresh: nil).readCredentials(now: baseNow) else {
            return XCTFail("Expected access token at now + 31s to pass")
        }

        // Fallback when access_token has no valid `exp`: 8 days since `last_refresh`
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let staleRefresh = isoFormatter.string(from: baseNow.addingTimeInterval(-8 * 86_400))
        let freshRefresh = isoFormatter.string(from: baseNow.addingTimeInterval(-(8 * 86_400 - 1)))

        XCTAssertEqual(
            makeCodexReader(accessToken: "opaque-token-without-exp", lastRefresh: staleRefresh).readCredentials(now: baseNow),
            .failure(.tokenExpired)
        )
        guard case .success = makeCodexReader(
            accessToken: "opaque-token-without-exp",
            lastRefresh: freshRefresh
        ).readCredentials(now: baseNow) else {
            return XCTFail("Expected opaque token refreshed < 8 days ago to pass")
        }

        // When JWT `exp` IS valid, stale `last_refresh` does not cause false expiry
        guard case .success = makeCodexReader(
            accessToken: validJWT,
            lastRefresh: staleRefresh
        ).readCredentials(now: baseNow) else {
            return XCTFail("Expected valid JWT exp to take precedence over last_refresh fallback")
        }
    }

    /// Verifies JWT claim extraction (`email`, fallback `accountId`, `planType`) and redacted descriptions.
    func testJWTClaimExtractionAndRedactedDescriptions() {
        let futureExp = Int64(baseNow.timeIntervalSince1970 + 3_600)
        let accessJWT = makeJWT(payload: """
        {
          "exp": \(futureExp),
          "https://api.openai.com/auth": {
            "chatgpt_account_id": "acct-from-jwt",
            "chatgpt_plan_type": "plus"
          }
        }
        """)
        let idJWT = makeJWT(payload: """
        {
          "email": "codex.user@example.com"
        }
        """)
        let json = """
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "id_token": "\(idJWT)",
            "access_token": "\(accessJWT)",
            "refresh_token": "rt-secret-refresh",
            "account_id": ""
          },
          "last_refresh": "2025-06-15T10:00:00Z"
        }
        """
        let reader = CodexCredentialReader(
            environment: ["CODEX_HOME": "/custom/codex"],
            fileReader: { url in
                XCTAssertEqual(url.path, "/custom/codex/auth.json")
                return Data(json.utf8)
            }
        )

        let result = reader.readCredentials(now: baseNow)
        guard case .success(let creds) = result else {
            return XCTFail("Expected success, got \(result)")
        }

        XCTAssertEqual(creds.accessToken, accessJWT)
        XCTAssertEqual(creds.refreshToken, "rt-secret-refresh")
        XCTAssertEqual(creds.idToken, idJWT)
        XCTAssertEqual(creds.accountId, "acct-from-jwt")
        XCTAssertEqual(creds.accountEmail, "codex.user@example.com")
        XCTAssertEqual(creds.planType, "plus")

        XCTAssertFalse(creds.description.contains(accessJWT))
        XCTAssertFalse(creds.description.contains("rt-secret-refresh"))
        XCTAssertFalse(creds.description.contains(idJWT))
        XCTAssertFalse(creds.description.contains("codex.user@example.com"))
        XCTAssertFalse(creds.debugDescription.contains("rt-secret-refresh"))
        XCTAssertTrue(creds.description.contains("[REDACTED]"))
    }

    // MARK: - CodexUsageProvider Tests

    /// Verifies outgoing request headers, including `ChatGPT-Account-Id` inclusion vs complete omission.
    func testRequestHeadersIncludeOrOmitAccountIdHeader() async throws {
        let responseBody = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 15, "limit_window_seconds": 18000, "reset_after_seconds": 3600 }
          }
        }
        """

        let transportWithAccount = MockCodexHTTPTransport { request in
            (Data(responseBody.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
        }
        let providerWithAccount = CodexUsageProvider(
            credentialReader: StubCodexCredentialReader(result: .success(defaultCredentials(accountId: "acct-123"))),
            transport: transportWithAccount,
            userAgentVersion: "0.1.0"
        )
        _ = await providerWithAccount.fetchQuota(now: baseNow)
        let requests1 = await transportWithAccount.recordedRequests
        let req1 = try XCTUnwrap(requests1.first)
        XCTAssertEqual(req1.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(req1.httpMethod, "GET")
        XCTAssertEqual(req1.value(forHTTPHeaderField: "Authorization"), "Bearer codex-access-token")
        XCTAssertEqual(req1.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(req1.value(forHTTPHeaderField: "User-Agent"), "LynxBar/0.1.0")
        XCTAssertEqual(req1.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-123")

        let transportWithoutAccount = MockCodexHTTPTransport { request in
            (Data(responseBody.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
        }
        let providerWithoutAccount = CodexUsageProvider(
            credentialReader: StubCodexCredentialReader(result: .success(defaultCredentials(accountId: "   "))),
            transport: transportWithoutAccount,
            userAgentVersion: "0.1.0"
        )
        _ = await providerWithoutAccount.fetchQuota(now: baseNow)
        let requests2 = await transportWithoutAccount.recordedRequests
        let req2 = try XCTUnwrap(requests2.first)
        XCTAssertNil(req2.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
    }

    /// Verifies full Codex response decoding: `plan_type`, primary/secondary windows,
    /// `code_review_rate_limit`, `additional_rate_limits`, `credits` (string/number/null), and `accountLabel`.
    func testDecodesFullCodexUsageResponseAndCreditsVariants() async {
        let resetAtEpoch = Int64(baseNow.timeIntervalSince1970 + 7_200)
        let fullJSON = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {
              "used_percent": 25.0,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 5000,
              "reset_at": \(resetAtEpoch)
            },
            "secondary_window": {
              "used_percent": 60.0,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 86400
            }
          },
          "code_review_rate_limit": {
            "primary_window": {
              "used_percent": 10.0,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 43200
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "codex_spark",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 40.0,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 1800
                }
              }
            }
          ],
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": "4.20"
          }
        }
        """

        let provider = makeProvider(
            credentials: defaultCredentials(accountId: "acct-1", email: "user@openai.com"),
            statusCode: 200,
            body: fullJSON
        )
        let result = await provider.fetchQuota(now: baseNow)
        guard case .success(let snapshot) = result else {
            return XCTFail("Expected success, got \(result)")
        }

        XCTAssertEqual(snapshot.providerID, .codex)
        XCTAssertEqual(snapshot.planLabel, "Plus")
        XCTAssertEqual(snapshot.accountLabel, "user@openai.com")
        XCTAssertEqual(snapshot.fetchedAt, baseNow)

        XCTAssertEqual(snapshot.primaryWindow?.kind, .session5h)
        XCTAssertEqual(snapshot.primaryWindow?.usedRatio ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.primaryWindow?.resetsAt, Date(timeIntervalSince1970: TimeInterval(resetAtEpoch)))

        XCTAssertEqual(snapshot.secondaryWindow?.kind, .weekly7d)
        XCTAssertEqual(snapshot.secondaryWindow?.usedRatio ?? -1, 0.60, accuracy: 0.0001)
        XCTAssertEqual(snapshot.secondaryWindow?.resetsAt, baseNow.addingTimeInterval(86_400))

        XCTAssertEqual(snapshot.additionalWindows.count, 2)
        XCTAssertEqual(snapshot.additionalWindows[0].kind, .codeReview)
        XCTAssertEqual(snapshot.additionalWindows[0].title, "Code Review")
        XCTAssertEqual(snapshot.additionalWindows[0].usedRatio, 0.10, accuracy: 0.0001)

        XCTAssertEqual(snapshot.additionalWindows[1].kind, .modelQuota)
        XCTAssertEqual(snapshot.additionalWindows[1].title, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(snapshot.additionalWindows[1].usedRatio, 0.40, accuracy: 0.0001)

        XCTAssertEqual(
            snapshot.credits,
            AIProviderCreditsSummary(hasCredits: true, unlimited: false, balanceText: "4.20", balanceAmount: 4.20)
        )

        // Numeric balance and null balance variants (credits-only payload also succeeds)
        let numericCreditsJSON = """
        {
          "plan_type": "enterprise",
          "credits": { "has_credits": true, "unlimited": true, "balance": 12.5 }
        }
        """
        guard case .success(let numSnapshot) = await makeProvider(statusCode: 200, body: numericCreditsJSON).fetchQuota(now: baseNow) else {
            return XCTFail("Expected numeric credits payload to succeed")
        }
        XCTAssertEqual(numSnapshot.planLabel, "Enterprise")
        XCTAssertEqual(numSnapshot.credits?.unlimited, true)
        XCTAssertEqual(numSnapshot.credits?.balanceText, "12.50")
        XCTAssertEqual(numSnapshot.credits?.balanceAmount ?? -1, 12.5, accuracy: 0.0001)

        let nullCreditsJSON = """
        {
          "plan_type": "free",
          "credits": { "has_credits": false, "unlimited": false, "balance": null }
        }
        """
        guard case .success(let nullSnapshot) = await makeProvider(statusCode: 200, body: nullCreditsJSON).fetchQuota(now: baseNow) else {
            return XCTFail("Expected null credits payload to succeed")
        }
        XCTAssertEqual(nullSnapshot.planLabel, "Free")
        XCTAssertNil(nullSnapshot.credits?.balanceText)
        XCTAssertNil(nullSnapshot.credits?.balanceAmount)
    }

    /// Verifies empty/invalid payloads map to `.decodingFailure` and HTTP/network errors map accurately.
    func testEmptyPayloadHTTPStatusCodesAndNetworkFailures() async {
        guard case .failure(.decodingFailure) = await makeProvider(statusCode: 200, body: "{}").fetchQuota(now: baseNow) else {
            return XCTFail("Expected empty JSON object to fail with .decodingFailure")
        }
        guard case .failure(.decodingFailure) = await makeProvider(statusCode: 200, body: "{not-json").fetchQuota(now: baseNow) else {
            return XCTFail("Expected malformed JSON to fail with .decodingFailure")
        }

        for status in [401, 403] {
            let authResult = await makeProvider(statusCode: status, body: "{}").fetchQuota(now: baseNow)
            XCTAssertEqual(authResult, .failure(.unauthorized))
        }

        let rateLimitedWithHeader = await makeProvider(statusCode: 429, headers: ["Retry-After": "90"], body: "{}").fetchQuota(now: baseNow)
        XCTAssertEqual(rateLimitedWithHeader, .failure(.rateLimited(retryAfter: 90)))

        let rateLimitedNoHeader = await makeProvider(statusCode: 429, body: "{}").fetchQuota(now: baseNow)
        XCTAssertEqual(rateLimitedNoHeader, .failure(.rateLimited(retryAfter: nil)))

        let serverErrorResult = await makeProvider(statusCode: 500, body: "{}").fetchQuota(now: baseNow)
        XCTAssertEqual(serverErrorResult, .failure(.endpointUnavailable(statusCode: 500)))

        let failingTransport = MockCodexHTTPTransport { _ in
            throw URLError(.timedOut)
        }
        let networkProvider = CodexUsageProvider(
            credentialReader: StubCodexCredentialReader(result: .success(defaultCredentials())),
            transport: failingTransport
        )
        guard case .failure(.networkFailure) = await networkProvider.fetchQuota(now: baseNow) else {
            return XCTFail("Expected .networkFailure on transport error")
        }

        let unusedTransport = MockCodexHTTPTransport { _ in
            XCTFail("Transport must not run when credentials fail")
            throw URLError(.cancelled)
        }
        let credErrorProvider = CodexUsageProvider(
            credentialReader: StubCodexCredentialReader(result: .failure(.credentialsMissing)),
            transport: unusedTransport
        )
        let credErrorResult = await credErrorProvider.fetchQuota(now: baseNow)
        XCTAssertEqual(credErrorResult, .failure(.credentialsMissing))
        let count = await unusedTransport.recordedRequests.count
        XCTAssertEqual(count, 0)
    }

    /// Verifies huge finite `limit_window_seconds` values (`1e20`, `1e308`) do not trap `Int` conversion
    /// and fall back cleanly in both primary/secondary and additional rate-limit window titles.
    func testLargeLimitWindowSecondsFallsBackWithoutOverflowCrash() async {
        let overflowJSON = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {
              "used_percent": 15.0,
              "limit_window_seconds": 1e20,
              "reset_after_seconds": 3600
            },
            "secondary_window": {
              "used_percent": 35.0,
              "limit_window_seconds": 1e308,
              "reset_after_seconds": 7200
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "Overflow Model",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 10.0,
                  "limit_window_seconds": 1e20,
                  "reset_after_seconds": 600
                },
                "secondary_window": {
                  "used_percent": 20.0,
                  "limit_window_seconds": 1e308,
                  "reset_after_seconds": 1200
                }
              }
            }
          ]
        }
        """

        let provider = makeProvider(statusCode: 200, body: overflowJSON)
        let result = await provider.fetchQuota(now: baseNow)
        guard case .success(let snapshot) = result else {
            return XCTFail("Expected overflow limit_window_seconds payload to decode cleanly, got \(result)")
        }

        XCTAssertEqual(snapshot.primaryWindow?.kind, .modelQuota)
        XCTAssertEqual(snapshot.primaryWindow?.title, "5-hour session window")
        XCTAssertEqual(snapshot.primaryWindow?.usedRatio ?? -1, 0.15, accuracy: 0.0001)

        XCTAssertEqual(snapshot.secondaryWindow?.kind, .modelQuota)
        XCTAssertEqual(snapshot.secondaryWindow?.title, "7-day weekly window")
        XCTAssertEqual(snapshot.secondaryWindow?.usedRatio ?? -1, 0.35, accuracy: 0.0001)

        XCTAssertEqual(snapshot.additionalWindows.count, 2)
        XCTAssertEqual(snapshot.additionalWindows[0].title, "Overflow Model (Primary)")
        XCTAssertEqual(snapshot.additionalWindows[0].usedRatio, 0.10, accuracy: 0.0001)
        XCTAssertEqual(snapshot.additionalWindows[1].title, "Overflow Model (Secondary)")
        XCTAssertEqual(snapshot.additionalWindows[1].usedRatio, 0.20, accuracy: 0.0001)
    }

    // MARK: - Helpers

    private func makeCodexReader(accessToken: String, lastRefresh: String?) -> CodexCredentialReader {
        let refreshLine = lastRefresh.map { "\"last_refresh\": \"\($0)\"" } ?? "\"last_refresh\": null"
        let json = """
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "access_token": "\(accessToken)"
          },
          \(refreshLine)
        }
        """
        return CodexCredentialReader(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/testuser"),
            fileReader: { _ in Data(json.utf8) }
        )
    }

    private func defaultCredentials(
        accountId: String? = "acct-default",
        email: String? = nil
    ) -> CodexOAuthCredentials {
        CodexOAuthCredentials(
            accessToken: "codex-access-token",
            refreshToken: nil,
            idToken: nil,
            accountId: accountId,
            accountEmail: email,
            expiresAt: baseNow.addingTimeInterval(3_600),
            lastRefresh: baseNow,
            planType: nil
        )
    }

    private func makeProvider(
        credentials: CodexOAuthCredentials? = nil,
        statusCode: Int,
        headers: [String: String]? = nil,
        body: String
    ) -> CodexUsageProvider {
        let resolved = credentials ?? defaultCredentials()
        let transport = MockCodexHTTPTransport { request in
            (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: statusCode, headers: headers))
        }
        return CodexUsageProvider(
            credentialReader: StubCodexCredentialReader(result: .success(resolved)),
            transport: transport
        )
    }

    private static func httpResponse(
        url: URL,
        statusCode: Int,
        headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
    }

    private func makeJWT(payload: String) -> String {
        let header = base64URL(#"{"alg":"none","typ":"JWT"}"#)
        let body = base64URL(payload)
        return "\(header).\(body).signature"
    }

    private func base64URL(_ text: String) -> String {
        Data(text.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct StubCodexCredentialReader: CodexCredentialReading {
    let result: Result<CodexOAuthCredentials, AIUsageFetchError>

    func readCredentials(now: Date) -> Result<CodexOAuthCredentials, AIUsageFetchError> {
        result
    }
}

private actor MockCodexHTTPTransport: AIUsageHTTPTransport {
    private let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private(set) var recordedRequests: [URLRequest] = []

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        return try await handler(request)
    }
}
