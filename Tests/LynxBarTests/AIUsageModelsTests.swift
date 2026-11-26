import Foundation
import XCTest
@testable import LynxBar

/// Offline unit tests for shared AI quota models, descriptors, defensive ratio clamping,
/// JWT payload decoding, and timestamp/`Retry-After` parsing helpers.
final class AIUsageModelsTests: XCTestCase {
    private let baseNow = Date(timeIntervalSince1970: 1_750_000_000)

    /// Verifies `AIUsageProviderID` cases, descriptor properties, and `Codable` round-tripping.
    func testProviderIDCasesAndDescriptors() throws {
        XCTAssertEqual(AIUsageProviderID.allCases, [.claude, .codex, .antigravity])

        XCTAssertEqual(AIUsageProviderID.claude.id, .claude)
        XCTAssertEqual(AIUsageProviderID.claude.displayName, "Claude")
        XCTAssertEqual(AIUsageProviderID.claude.shortName, "Claude")
        XCTAssertEqual(AIUsageProviderID.claude.cliLoginCommand, "claude /login")

        XCTAssertEqual(AIUsageProviderID.codex.id, .codex)
        XCTAssertEqual(AIUsageProviderID.codex.displayName, "OpenAI Codex")
        XCTAssertEqual(AIUsageProviderID.codex.shortName, "Codex")
        XCTAssertEqual(AIUsageProviderID.codex.cliLoginCommand, "codex login")

        XCTAssertEqual(AIUsageProviderID.antigravity.id, .antigravity)
        XCTAssertEqual(AIUsageProviderID.antigravity.displayName, "Antigravity")
        XCTAssertEqual(AIUsageProviderID.antigravity.shortName, "Antigravity")
        XCTAssertEqual(AIUsageProviderID.antigravity.cliLoginCommand, "agy login")

        let encoded = try JSONEncoder().encode(AIUsageProviderID.allCases)
        let decoded = try JSONDecoder().decode([AIUsageProviderID].self, from: encoded)
        XCTAssertEqual(decoded, AIUsageProviderID.allCases)
    }

    /// Verifies `AIQuotaWindow` clamps `usedRatio` into `0...1` across negative, >1, `NaN`, and ±infinity inputs.
    func testQuotaWindowClampingForOutOfBoundsAndNonFiniteInputs() {
        let negative = AIQuotaWindow(id: "neg", kind: .session5h, title: "Neg", usedRatio: -0.25, resetsAt: nil)
        XCTAssertEqual(negative.usedRatio, 0.0)
        XCTAssertEqual(negative.remainingRatio, 1.0)

        let overOne = AIQuotaWindow(id: "over", kind: .weekly7d, title: "Over", usedRatio: 1.75, resetsAt: nil)
        XCTAssertEqual(overOne.usedRatio, 1.0)
        XCTAssertEqual(overOne.remainingRatio, 0.0)

        let nanWindow = AIQuotaWindow(id: "nan", kind: .codeReview, title: "NaN", usedRatio: .nan, resetsAt: nil)
        XCTAssertEqual(nanWindow.usedRatio, 0.0)
        XCTAssertEqual(nanWindow.remainingRatio, 1.0)

        let posInf = AIQuotaWindow(id: "pinf", kind: .modelQuota, title: "+Inf", usedRatio: .infinity, resetsAt: nil)
        XCTAssertEqual(posInf.usedRatio, 0.0)
        XCTAssertEqual(posInf.remainingRatio, 1.0)

        let negInf = AIQuotaWindow(id: "ninf", kind: .modelQuota, title: "-Inf", usedRatio: -.infinity, resetsAt: nil)
        XCTAssertEqual(negInf.usedRatio, 0.0)
        XCTAssertEqual(negInf.remainingRatio, 1.0)

        let normal = AIQuotaWindow(id: "norm", kind: .modelQuota, title: "Normal", usedRatio: 0.35, resetsAt: nil)
        XCTAssertEqual(normal.displayedRatio(style: .used), 0.35, accuracy: 0.0001)
        XCTAssertEqual(normal.displayedRatio(style: .remaining), 0.65, accuracy: 0.0001)
    }

    /// Verifies backward-compatible `AIProviderQuotaSnapshot` initializer and new `credits`/`accountLabel` fields.
    func testQuotaSnapshotInitializerAndCreditsSummary() {
        let primary = AIQuotaWindow(id: "p", kind: .session5h, title: "5h", usedRatio: 0.2, resetsAt: nil)
        let compatSnapshot = AIProviderQuotaSnapshot(
            providerID: .claude,
            primaryWindow: primary,
            secondaryWindow: nil,
            additionalWindows: [],
            extraUsage: nil,
            planLabel: "Pro",
            fetchedAt: baseNow
        )
        XCTAssertNil(compatSnapshot.credits)
        XCTAssertNil(compatSnapshot.accountLabel)
        XCTAssertEqual(compatSnapshot.planLabel, "Pro")

        let credits = AIProviderCreditsSummary(
            hasCredits: true,
            unlimited: false,
            balanceText: "  4.20  ",
            balanceAmount: 4.20
        )
        XCTAssertEqual(credits.balanceText, "4.20")
        XCTAssertEqual(credits.balanceAmount ?? -1, 4.20, accuracy: 0.001)

        let nonFiniteCredits = AIProviderCreditsSummary(
            hasCredits: false,
            unlimited: false,
            balanceText: "   ",
            balanceAmount: .nan
        )
        XCTAssertNil(nonFiniteCredits.balanceText)
        XCTAssertNil(nonFiniteCredits.balanceAmount)

        let codexSnapshot = AIProviderQuotaSnapshot(
            providerID: .codex,
            primaryWindow: primary,
            planLabel: "Plus",
            credits: credits,
            accountLabel: "dev@example.com",
            fetchedAt: baseNow
        )
        XCTAssertEqual(codexSnapshot.credits, credits)
        XCTAssertEqual(codexSnapshot.accountLabel, "dev@example.com")
    }

    /// Verifies `AIUsageFetchError.stopsAutomaticRetry` across all 9 error cases.
    func testFetchErrorStopsAutomaticRetryClassification() {
        XCTAssertTrue(AIUsageFetchError.disabled.stopsAutomaticRetry)
        XCTAssertTrue(AIUsageFetchError.credentialsMissing.stopsAutomaticRetry)
        XCTAssertTrue(AIUsageFetchError.credentialsMalformed.stopsAutomaticRetry)
        XCTAssertTrue(AIUsageFetchError.tokenExpired.stopsAutomaticRetry)
        XCTAssertTrue(AIUsageFetchError.unauthorized.stopsAutomaticRetry)

        XCTAssertFalse(AIUsageFetchError.rateLimited(retryAfter: 60).stopsAutomaticRetry)
        XCTAssertFalse(AIUsageFetchError.endpointUnavailable(statusCode: 503).stopsAutomaticRetry)
        XCTAssertFalse(AIUsageFetchError.networkFailure("offline").stopsAutomaticRetry)
        XCTAssertFalse(AIUsageFetchError.decodingFailure("bad json").stopsAutomaticRetry)
    }

    /// Verifies `AIUsageJWTDecoder` decodes valid Base64URL payloads with padding edge cases and rejects malformed tokens.
    func testJWTDecoderValidPaddingAndMalformedInputs() {
        struct SampleClaims: Decodable {
            let email: String?
            let note: String?
        }

        // Payload containing '-' and '_' in Base64URL (from `~` / `?` bytes or non-aligned lengths)
        let payloads = [
            #"{"email":"a@b.com","note":"x"}"#,       // remainder 0 or 2 or 3 depending on exact length
            #"{"email":"user@example.com","note":"??>>"}"#,
            #"{"email":"pad@test.io","note":"12"}"#,
            #"{"email":"pad2@test.io","note":"123"}"#,
        ]
        let header = base64URLEncode(#"{"alg":"none"}"#)

        for json in payloads {
            let encodedPayload = base64URLEncode(json)
            let threePart = "\(header).\(encodedPayload).sig"
            let twoPart = "\(header).\(encodedPayload)"

            XCTAssertNotNil(AIUsageJWTDecoder.decodePayload(SampleClaims.self, from: threePart))
            XCTAssertNotNil(AIUsageJWTDecoder.decodePayload(SampleClaims.self, from: twoPart))
            XCTAssertNotNil(AIUsageJWTDecoder.decodeClaimsDictionary(from: threePart))
        }

        XCTAssertNil(AIUsageJWTDecoder.decodePayloadData(from: ""))
        XCTAssertNil(AIUsageJWTDecoder.decodePayloadData(from: "single-segment"))
        XCTAssertNil(AIUsageJWTDecoder.decodePayloadData(from: "hdr..sig"))
        XCTAssertNil(AIUsageJWTDecoder.decodePayloadData(from: "hdr.A.sig")) // invalid base64 length % 4 == 1
        XCTAssertNil(AIUsageJWTDecoder.decodeClaimsDictionary(from: "hdr.\(base64URLEncode("not-json")).sig"))
    }

    /// Verifies Unix timestamp seconds/ms heuristic, ISO-8601 parsing, and `Retry-After` numeric/HTTP-date parsing.
    func testTimestampAndRetryAfterParsing() throws {
        // Seconds vs milliseconds
        let secDate = AIUsageParsing.parseUnixTimestamp(1_750_000_000)
        XCTAssertEqual(secDate?.timeIntervalSince1970 ?? -1, 1_750_000_000, accuracy: 0.001)

        let msDate = AIUsageParsing.parseUnixTimestamp(1_750_000_000_000)
        XCTAssertEqual(msDate?.timeIntervalSince1970 ?? -1, 1_750_000_000, accuracy: 0.001)

        XCTAssertNil(AIUsageParsing.parseUnixTimestamp(0))
        XCTAssertNil(AIUsageParsing.parseUnixTimestamp(-10))
        XCTAssertNil(AIUsageParsing.parseUnixTimestamp(.nan))
        XCTAssertNil(AIUsageParsing.parseUnixTimestamp(.infinity))

        // ISO-8601 fractional and whole seconds
        XCTAssertNotNil(AIUsageParsing.parseISO8601Date("2025-06-15T14:30:00.456Z"))
        XCTAssertNotNil(AIUsageParsing.parseISO8601Date("2025-06-15T14:30:00Z"))
        XCTAssertNil(AIUsageParsing.parseISO8601Date("   "))

        // Retry-After numeric and HTTP-date
        XCTAssertEqual(AIUsageParsing.parseRetryAfter("45", now: baseNow), 45)
        XCTAssertNil(AIUsageParsing.parseRetryAfter("0", now: baseNow))
        XCTAssertNil(AIUsageParsing.parseRetryAfter("-5", now: baseNow))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let futureHTTPDate = formatter.string(from: baseNow.addingTimeInterval(75))
        let parsedDelay = try XCTUnwrap(AIUsageParsing.parseRetryAfter(futureHTTPDate, now: baseNow))
        XCTAssertEqual(parsedDelay, 75, accuracy: 1.0)

        let pastHTTPDate = formatter.string(from: baseNow.addingTimeInterval(-30))
        XCTAssertNil(AIUsageParsing.parseRetryAfter(pastHTTPDate, now: baseNow))
    }

    private func base64URLEncode(_ text: String) -> String {
        Data(text.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
