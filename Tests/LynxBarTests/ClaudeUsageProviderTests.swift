import Foundation
import XCTest
@testable import LynxBar

/// Offline unit tests for `ClaudeUsageProvider` using an injected `AIUsageHTTPTransport`
/// and `ClaudeCredentialReading` stub.
final class ClaudeUsageProviderTests: XCTestCase {
    private let baseNow = Date(timeIntervalSince1970: 1_750_000_000)

    /// Verifies that outgoing usage requests target the Anthropic OAuth endpoint with GET
    /// and all required headers (`Authorization`, `Accept`, `anthropic-beta`, `User-Agent`).
    func testRequestURLMethodAndRequiredHeaders() async {
        let credentials = ClaudeOAuthCredentials(
            accessToken: "sk-ant-header-test-token",
            expiresAt: baseNow.addingTimeInterval(3_600),
            subscriptionType: "pro",
            rateLimitTier: nil
        )
        let transport = MockAIUsageHTTPTransport { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let payload = """
            { "five_hour": { "utilization": 22.0, "resets_at": "2025-06-15T12:00:00Z" } }
            """
            return (Data(payload.utf8), response)
        }
        let provider = ClaudeUsageProvider(
            credentialReader: StubCredentialReader(result: .success(credentials)),
            transport: transport,
            userAgentVersion: "0.1.0"
        )

        let result = await provider.fetchQuota(now: baseNow)
        guard case .success = result else {
            return XCTFail("Expected success, got \(result)")
        }

        let requests = await transport.recordedRequests
        XCTAssertEqual(requests.count, 1)
        let request = try? XCTUnwrap(requests.first)
        XCTAssertEqual(request?.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-header-test-token")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"), "LynxBar/0.1.0")
    }

    /// Verifies full HTTP 200 response decoding including `five_hour`, `seven_day`,
    /// model-specific windows, `extra_usage`, fractional/non-fractional ISO-8601 dates, and `planLabel`.
    func testDecodesFull200ResponseWithFractionalAndNonFractionalTimestamps() async {
        let credentials = ClaudeOAuthCredentials(
            accessToken: "sk-ant-full",
            expiresAt: baseNow.addingTimeInterval(3_600),
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_5x"
        )
        let json = """
        {
          "five_hour": {
            "utilization": 22.0,
            "resets_at": "2025-06-15T14:30:00.123Z"
          },
          "seven_day": {
            "utilization": 45.5,
            "resets_at": "2025-06-20T00:00:00Z"
          },
          "seven_day_sonnet": {
            "utilization": 10.0,
            "resets_at": "2025-06-20T00:00:00Z"
          },
          "seven_day_opus": {
            "utilization": 5.0,
            "resets_at": "2025-06-20T00:00:00Z"
          },
          "extra_usage": {
            "is_enabled": true,
            "used_credits": 12.5,
            "monthly_limit": 50.0,
            "currency": "USD"
          }
        }
        """
        let provider = makeProvider(credentials: credentials, statusCode: 200, body: json)

        let result = await provider.fetchQuota(now: baseNow)
        guard case .success(let snapshot) = result else {
            return XCTFail("Expected success, got \(result)")
        }

        XCTAssertEqual(snapshot.providerID, .claude)
        XCTAssertEqual(snapshot.planLabel, "Max")
        XCTAssertEqual(snapshot.fetchedAt, baseNow)

        XCTAssertEqual(snapshot.primaryWindow?.kind, .session5h)
        XCTAssertEqual(snapshot.primaryWindow?.usedRatio ?? -1, 0.22, accuracy: 0.0001)
        XCTAssertEqual(snapshot.primaryWindow?.remainingRatio ?? -1, 0.78, accuracy: 0.0001)
        XCTAssertNotNil(snapshot.primaryWindow?.resetsAt)

        XCTAssertEqual(snapshot.secondaryWindow?.kind, .weekly7d)
        XCTAssertEqual(snapshot.secondaryWindow?.usedRatio ?? -1, 0.455, accuracy: 0.0001)
        XCTAssertNotNil(snapshot.secondaryWindow?.resetsAt)

        XCTAssertEqual(snapshot.additionalWindows.map(\.id), ["seven_day_sonnet", "seven_day_opus"])
        XCTAssertEqual(snapshot.additionalWindows.map(\.kind), [.weeklyModelSpecific, .weeklyModelSpecific])

        XCTAssertEqual(
            snapshot.extraUsage,
            AIExtraUsageSummary(isEnabled: true, usedAmount: 12.5, monthlyLimit: 50.0, currencyCode: "USD")
        )
    }

    /// Verifies tolerant decoding when optional windows or `extra_usage` are missing/disabled,
    /// and verifies `.decodingFailure` when both `five_hour` and `seven_day` are absent.
    func testOptionalFieldToleranceAndDecodingFailureWhenBothPrimaryWindowsMissing() async {
        let partialJSON = """
        {
          "five_hour": { "utilization": 30.0 },
          "extra_usage": { "is_enabled": false, "used_credits": 5.0 }
        }
        """
        let partialProvider = makeProvider(statusCode: 200, body: partialJSON)
        guard case .success(let partial) = await partialProvider.fetchQuota(now: baseNow) else {
            return XCTFail("Expected partial 200 response with five_hour to succeed")
        }
        XCTAssertNotNil(partial.primaryWindow)
        XCTAssertNil(partial.secondaryWindow)
        XCTAssertTrue(partial.additionalWindows.isEmpty)
        XCTAssertNil(partial.extraUsage)

        let missingBothJSON = """
        {
          "seven_day_sonnet": { "utilization": 15.0 }
        }
        """
        let missingBothProvider = makeProvider(statusCode: 200, body: missingBothJSON)
        guard case .failure(.decodingFailure) = await missingBothProvider.fetchQuota(now: baseNow) else {
            return XCTFail("Expected .decodingFailure when both five_hour and seven_day are absent")
        }

        let invalidJSONProvider = makeProvider(statusCode: 200, body: "{broken")
        guard case .failure(.decodingFailure) = await invalidJSONProvider.fetchQuota(now: baseNow) else {
            return XCTFail("Expected .decodingFailure for invalid JSON")
        }
    }

    /// Verifies 0...100 utilization normalization, out-of-range clamping, and non-finite `AIQuotaWindow` safety.
    func testUtilizationNormalizationClampingAndNonFiniteSafety() async {
        let extremeJSON = """
        {
          "five_hour": { "utilization": -25.0 },
          "seven_day": { "utilization": 145.0 }
        }
        """
        let provider = makeProvider(statusCode: 200, body: extremeJSON)
        guard case .success(let snapshot) = await provider.fetchQuota(now: baseNow) else {
            return XCTFail("Expected clamped snapshot")
        }

        XCTAssertEqual(snapshot.primaryWindow?.usedRatio, 0.0)
        XCTAssertEqual(snapshot.primaryWindow?.remainingRatio, 1.0)
        XCTAssertEqual(snapshot.secondaryWindow?.usedRatio, 1.0)
        XCTAssertEqual(snapshot.secondaryWindow?.remainingRatio, 0.0)

        let nanWindow = AIQuotaWindow(
            id: "nan",
            kind: .session5h,
            title: "5-hour session",
            usedRatio: .nan,
            resetsAt: nil
        )
        XCTAssertEqual(nanWindow.usedRatio, 0.0)
        XCTAssertEqual(nanWindow.remainingRatio, 1.0)
        XCTAssertEqual(nanWindow.displayedRatio(style: .remaining), 1.0)
        XCTAssertEqual(nanWindow.displayedRatio(style: .used), 0.0)
    }

    /// Verifies HTTP 401 and 403 map to `.unauthorized`.
    func testHTTP401And403MapToUnauthorized() async {
        for status in [401, 403] {
            let provider = makeProvider(statusCode: status, body: "{}")
            let result = await provider.fetchQuota(now: baseNow)
            XCTAssertEqual(result, .failure(.unauthorized))
        }
    }

    /// Verifies HTTP 429 `Retry-After` parsing for numeric seconds, HTTP-date, and missing header.
    func testHTTP429RetryAfterSecondsHTTPDateAndAbsentHeader() async throws {
        let secondsProvider = makeProvider(
            statusCode: 429,
            headers: ["Retry-After": "120"],
            body: "{}"
        )
        let secondsResult = await secondsProvider.fetchQuota(now: baseNow)
        XCTAssertEqual(secondsResult, .failure(.rateLimited(retryAfter: 120)))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let retryDate = baseNow.addingTimeInterval(90)
        let httpDate = formatter.string(from: retryDate)

        let dateProvider = makeProvider(
            statusCode: 429,
            headers: ["Retry-After": httpDate],
            body: "{}"
        )
        guard case .failure(.rateLimited(let parsedDelay)) = await dateProvider.fetchQuota(now: baseNow) else {
            return XCTFail("Expected .rateLimited with HTTP-date delay")
        }
        let delay = try XCTUnwrap(parsedDelay)
        XCTAssertEqual(delay, 90, accuracy: 1.0)

        let noHeaderProvider = makeProvider(statusCode: 429, body: "{}")
        let noHeaderResult = await noHeaderProvider.fetchQuota(now: baseNow)
        XCTAssertEqual(noHeaderResult, .failure(.rateLimited(retryAfter: nil)))
    }

    /// Verifies HTTP 404, 410, and 500 map to `.endpointUnavailable(statusCode:)`.
    func testHTTP404410And500MapToEndpointUnavailable() async {
        for status in [404, 410, 500, 503] {
            let provider = makeProvider(statusCode: status, body: "{}")
            let result = await provider.fetchQuota(now: baseNow)
            XCTAssertEqual(result, .failure(.endpointUnavailable(statusCode: status)))
        }
    }

    /// Verifies transport errors map to `.networkFailure` and credential failures skip HTTP transport completely.
    func testTransportErrorsAndCredentialShortCircuit() async {
        let failingTransport = MockAIUsageHTTPTransport { _ in
            throw URLError(.notConnectedToInternet)
        }
        let networkProvider = ClaudeUsageProvider(
            credentialReader: StubCredentialReader(result: .success(defaultCredentials())),
            transport: failingTransport
        )
        guard case .failure(.networkFailure) = await networkProvider.fetchQuota(now: baseNow) else {
            return XCTFail("Expected .networkFailure when transport throws")
        }

        let unusedTransport = MockAIUsageHTTPTransport { _ in
            XCTFail("HTTP transport must not be called when credentials fail")
            throw URLError(.cancelled)
        }
        let missingCredsProvider = ClaudeUsageProvider(
            credentialReader: StubCredentialReader(result: .failure(.tokenExpired)),
            transport: unusedTransport
        )
        let missingCredsResult = await missingCredsProvider.fetchQuota(now: baseNow)
        XCTAssertEqual(missingCredsResult, .failure(.tokenExpired))
        let count = await unusedTransport.recordedRequests.count
        XCTAssertEqual(count, 0)
    }

    private func defaultCredentials() -> ClaudeOAuthCredentials {
        ClaudeOAuthCredentials(
            accessToken: "sk-ant-test",
            expiresAt: baseNow.addingTimeInterval(3_600),
            subscriptionType: "pro",
            rateLimitTier: nil
        )
    }

    private func makeProvider(
        credentials: ClaudeOAuthCredentials? = nil,
        statusCode: Int,
        headers: [String: String]? = nil,
        body: String
    ) -> ClaudeUsageProvider {
        let resolvedCredentials = credentials ?? defaultCredentials()
        let transport = MockAIUsageHTTPTransport { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
            return (Data(body.utf8), response)
        }
        return ClaudeUsageProvider(
            credentialReader: StubCredentialReader(result: .success(resolvedCredentials)),
            transport: transport
        )
    }
}

private struct StubCredentialReader: ClaudeCredentialReading {
    let result: Result<ClaudeOAuthCredentials, AIUsageFetchError>

    func readCredentials(now: Date) -> Result<ClaudeOAuthCredentials, AIUsageFetchError> {
        result
    }
}

private actor MockAIUsageHTTPTransport: AIUsageHTTPTransport {
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
