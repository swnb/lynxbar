import AppKit
import CodexBarCore
import Foundation
import Security
import SwiftUI
import XCTest
@testable import LynxBar

/// Tier 2 Opaque-Box E2E Tests: 5 boundary & corner-case tests × 20 features = 100 tests.
@MainActor
final class AIUsageE2ETier2Tests: XCTestCase {
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

    // MARK: - F1 Boundary Cases (5)

    func testF01_01_unknownProviderRawValueReturnsNil() {
        XCTAssertNil(AIUsageProviderID(rawValue: "unknown"))
        XCTAssertNil(AIUsageProviderID(rawValue: ""))
    }

    func testF01_02_providerIDRawValueIsCaseSensitive() {
        XCTAssertNil(AIUsageProviderID(rawValue: "CLAUDE"))
        XCTAssertNil(AIUsageProviderID(rawValue: "Codex"))
        XCTAssertNil(AIUsageProviderID(rawValue: "ANTIGRAVITY"))
    }

    func testF01_03_displayStyleValidatedNilDefaultsToRemaining() {
        XCTAssertEqual(AIQuotaDisplayStyle.validated(nil), .remaining)
    }

    func testF01_04_displayStyleValidatedInvalidRawDefaultsToRemaining() {
        XCTAssertEqual(AIQuotaDisplayStyle.validated("invalid"), .remaining)
        XCTAssertEqual(AIQuotaDisplayStyle.validated("REMAINING"), .remaining)
    }

    func testF01_05_quotaWindowClampsNegativeOverflowNaNInfinityAndNegativeZero() {
        let neg = AIQuotaWindow(id: "a", kind: .session5h, title: "t", usedRatio: -0.1, resetsAt: nil)
        let over = AIQuotaWindow(id: "b", kind: .session5h, title: "t", usedRatio: 1.5, resetsAt: nil)
        let nan = AIQuotaWindow(id: "c", kind: .session5h, title: "t", usedRatio: .nan, resetsAt: nil)
        let inf = AIQuotaWindow(id: "d", kind: .session5h, title: "t", usedRatio: .infinity, resetsAt: nil)
        let negZero = AIQuotaWindow(id: "e", kind: .session5h, title: "t", usedRatio: -0.0, resetsAt: nil)

        XCTAssertEqual(neg.usedRatio, 0.0)
        XCTAssertEqual(over.usedRatio, 1.0)
        XCTAssertEqual(nan.usedRatio, 0.0)
        XCTAssertEqual(inf.usedRatio, 0.0)
        XCTAssertEqual(negZero.usedRatio, 0.0)
    }

    // MARK: - F2 Boundary Cases (5)

    func testF02_01_httpClientRejectsNonHTTPFileURLResponseWithBadServerResponse() async throws {
        let home = try makeTempHome()
        let fileURL = try home.writeUTF8(relativePath: "probe.txt", content: "not-http")
        let client = AIUsageHTTPClient()

        do {
            _ = try await client.data(for: URLRequest(url: fileURL))
            XCTFail("Expected URLError(.badServerResponse) for non-HTTP file:// response")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }
    }

    func testF02_02_emptyDataWithHTTP200MapsToDecodingFailure() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let provider = ClaudeUsageProvider(
            credentialReader: E2ESpyClaudeCredentialReader(result: .success(ClaudeOAuthCredentials(accessToken: "t", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((Data(), E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)))])
        )
        let result = await provider.fetchQuota(now: now)
        guard case .failure(.decodingFailure) = result else {
            return XCTFail("Expected decodingFailure for empty 200 body, got \(result)")
        }
    }

    func testF02_03_nonUTF8BinaryGarbageWithHTTP200MapsToDecodingFailure() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let garbage = Data([0xFF, 0xFE, 0x00, 0x81, 0xC3, 0x28])
        let provider = CodexUsageProvider(
            credentialReader: E2ESpyCodexCredentialReader(result: .success(CodexOAuthCredentials(accessToken: "t", refreshToken: nil, idToken: nil, accountId: nil, accountEmail: nil, expiresAt: nil, lastRefresh: nil, planType: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((garbage, E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)))])
        )
        let result = await provider.fetchQuota(now: now)
        guard case .failure(.decodingFailure) = result else {
            return XCTFail("Expected decodingFailure for binary 200 body, got \(result)")
        }
    }

    func testF02_04_cancellationErrorHandledCleanlyWithoutStateCorruption() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let provider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
            ProviderFetchOutcome(result: .failure(CancellationError()), attempts: [])
        }
        let result = await provider.fetchQuota(now: now)
        XCTAssertEqual(result, .failure(.networkFailure("Cancelled")))
    }

    func testF02_05_customTimeoutBoundaryPropagatesToSessionConfiguration() {
        let client = AIUsageHTTPClient(timeout: 15.0)
        let session = Mirror(reflecting: client).descendant("session") as? URLSession
        XCTAssertEqual(session?.configuration.timeoutIntervalForRequest ?? 0, 15.0, accuracy: 0.0001)
        XCTAssertEqual(session?.configuration.timeoutIntervalForResource ?? 0, 15.0, accuracy: 0.0001)
    }

    // MARK: - F3 Boundary Cases (5)

    func testF03_01_claudeKeychainAccessDeniedWithValidFileFallbackSucceeds() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let reader = ClaudeCredentialReader(
            keychainReader: { .accessDenied(errSecAuthFailed) },
            fileReader: { E2EFixtureFactory.claudeCredentialsData(accessToken: "sk-file-ok", expiresAtValue: (now.timeIntervalSince1970 + 600) * 1000) }
        )
        guard case .success(let creds) = reader.readCredentials(now: now) else {
            return XCTFail("Expected fallback file success when keychain access denied")
        }
        XCTAssertEqual(creds.accessToken, "sk-file-ok")
    }

    func testF03_02_claudeKeychainAccessDeniedWithoutFileReturnsUnauthorizedStoppingRetry() {
        let reader = ClaudeCredentialReader(
            keychainReader: { .accessDenied(errSecAuthFailed) },
            fileReader: { nil }
        )
        let result = reader.readCredentials(now: Date())
        XCTAssertEqual(result, .failure(.unauthorized))
        if case .failure(let error) = result {
            XCTAssertTrue(error.stopsAutomaticRetry)
        }
    }

    func testF03_03_claudeExpiresAtExactlyAt30sMarginReturnsTokenExpired() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let boundary = (now.timeIntervalSince1970 + 30.0) * 1000
        let reader = ClaudeCredentialReader(
            keychainReader: { .data(E2EFixtureFactory.claudeCredentialsData(expiresAtValue: boundary)) },
            fileReader: { nil }
        )
        XCTAssertEqual(reader.readCredentials(now: now), .failure(.tokenExpired))
    }

    func testF03_04_claudeExpiresAtJustAbove30sMarginSucceeds() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let validBoundary = (now.timeIntervalSince1970 + 30.001) * 1000
        let reader = ClaudeCredentialReader(
            keychainReader: { .data(E2EFixtureFactory.claudeCredentialsData(expiresAtValue: validBoundary)) },
            fileReader: { nil }
        )
        guard case .success = reader.readCredentials(now: now) else {
            return XCTFail("Expected success at now + 30.001s")
        }
    }

    func testF03_05_claudeEmptyWhitespaceTokenAndMalformedJSONStopAutoRetry() {
        let emptyTokenReader = ClaudeCredentialReader(
            keychainReader: { .notFound },
            fileReader: { E2EFixtureFactory.claudeCredentialsData(accessToken: "   \n  ") }
        )
        let emptyResult = emptyTokenReader.readCredentials(now: Date())
        XCTAssertEqual(emptyResult, .failure(.credentialsMissing))
        if case .failure(let err) = emptyResult { XCTAssertTrue(err.stopsAutomaticRetry) }

        let malformedReader = ClaudeCredentialReader(
            keychainReader: { .notFound },
            fileReader: { Data("{bad json".utf8) }
        )
        XCTAssertEqual(malformedReader.readCredentials(now: Date()), .failure(.credentialsMalformed))
    }

    // MARK: - F4 Boundary Cases (5)

    func testF04_01_claudeFiveHourOnlySucceedsWithNilSecondaryWindow() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let provider = ClaudeUsageProvider(
            credentialReader: E2ESpyClaudeCredentialReader(result: .success(ClaudeOAuthCredentials(accessToken: "t", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((E2EFixtureFactory.claudeUsageJSON(fiveHourPercent: 12, sevenDayPercent: nil), E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)))])
        )
        guard case .success(let snap) = await provider.fetchQuota(now: now) else {
            return XCTFail("Expected success with five_hour only")
        }
        XCTAssertNotNil(snap.primaryWindow)
        XCTAssertNil(snap.secondaryWindow)
    }

    func testF04_02_claudeSevenDayOnlySucceedsWithNilPrimaryWindow() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let provider = ClaudeUsageProvider(
            credentialReader: E2ESpyClaudeCredentialReader(result: .success(ClaudeOAuthCredentials(accessToken: "t", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((E2EFixtureFactory.claudeUsageJSON(fiveHourPercent: nil, sevenDayPercent: 55), E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)))])
        )
        guard case .success(let snap) = await provider.fetchQuota(now: now) else {
            return XCTFail("Expected success with seven_day only")
        }
        XCTAssertNil(snap.primaryWindow)
        XCTAssertNotNil(snap.secondaryWindow)
    }

    func testF04_03_claudeBothWindowsNilReturnsDecodingFailure() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let provider = ClaudeUsageProvider(
            credentialReader: E2ESpyClaudeCredentialReader(result: .success(ClaudeOAuthCredentials(accessToken: "t", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((Data("{}".utf8), E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)))])
        )
        guard case .failure(.decodingFailure) = await provider.fetchQuota(now: now) else {
            return XCTFail("Expected decodingFailure when both windows nil")
        }
    }

    func testF04_04_claudeUtilizationClampsNegativeAndOver100Safely() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let provider = ClaudeUsageProvider(
            credentialReader: E2ESpyClaudeCredentialReader(result: .success(ClaudeOAuthCredentials(accessToken: "t", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((E2EFixtureFactory.claudeUsageJSON(fiveHourPercent: -5.0, sevenDayPercent: 125.0), E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)))])
        )
        guard case .success(let snap) = await provider.fetchQuota(now: now) else {
            return XCTFail("Expected clamped snapshot")
        }
        XCTAssertEqual(snap.primaryWindow?.usedRatio, 0.0)
        XCTAssertEqual(snap.secondaryWindow?.usedRatio, 1.0)
    }

    func testF04_05_claudeMalformedAndFractionalISO8601ResetStrings() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let provider = ClaudeUsageProvider(
            credentialReader: E2ESpyClaudeCredentialReader(result: .success(ClaudeOAuthCredentials(accessToken: "t", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((
                E2EFixtureFactory.claudeUsageJSON(fiveHourPercent: 20, fiveHourReset: "not-a-date", sevenDayPercent: 30, sevenDayReset: "2026-12-01T12:34:56.789Z"),
                E2ERecordingHTTPTransport.makeResponse(url: ClaudeUsageProvider.defaultEndpointURL, statusCode: 200)
            ))])
        )
        guard case .success(let snap) = await provider.fetchQuota(now: now) else {
            return XCTFail("Expected success even with malformed resets_at")
        }
        XCTAssertNil(snap.primaryWindow?.resetsAt)
        XCTAssertNotNil(snap.secondaryWindow?.resetsAt)
        XCTAssertNotNil(ClaudeUsageProvider.parseISO8601Date("2026-12-01T12:34:56Z"))
    }

    // MARK: - F5 Boundary Cases (5)

    func testF05_01_codexHomeWithoutAuthJSONDoesNotSilentlyLeakDotCodex() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let home = try makeTempHome()
        let emptyCodexHome = home.rootURL.appendingPathComponent("empty-codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyCodexHome, withIntermediateDirectories: true)

        let jwt = E2EFixtureFactory.makeJWT(claims: ["exp": now.timeIntervalSince1970 + 600])
        _ = try home.writeFile(relativePath: ".codex/auth.json", data: E2EFixtureFactory.codexAuthJSON(accessToken: jwt))

        let reader = CodexCredentialReader(environment: ["CODEX_HOME": emptyCodexHome.path], homeDirectory: home.rootURL)
        XCTAssertEqual(reader.readCredentials(now: now), .failure(.credentialsMissing))
    }

    func testF05_02_codexMalformedJSONAndNonJWTBoundary() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let home = try makeTempHome()
        _ = try home.writeUTF8(relativePath: ".codex/auth.json", content: "{corrupted")
        let malformedReader = CodexCredentialReader(environment: [:], homeDirectory: home.rootURL)
        XCTAssertEqual(malformedReader.readCredentials(now: now), .failure(.credentialsMalformed))

        // Opaque non-JWT access_token with valid last_refresh should not crash
        _ = try home.writeFile(
            relativePath: ".codex/auth.json",
            data: E2EFixtureFactory.codexAuthJSON(accessToken: "opaque-token-without-dots", lastRefresh: now.timeIntervalSince1970 - 60)
        )
        guard case .success(let opaqueCreds) = malformedReader.readCredentials(now: now) else {
            return XCTFail("Expected opaque token with fresh last_refresh to succeed without crashing")
        }
        XCTAssertNil(opaqueCreds.expiresAt)
    }

    func testF05_03_codexJWTExpAtNowOr30sMarginReturnsTokenExpired() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let home = try makeTempHome()
        let reader = CodexCredentialReader(environment: [:], homeDirectory: home.rootURL)

        let expAtNow = E2EFixtureFactory.makeJWT(claims: ["exp": now.timeIntervalSince1970])
        _ = try home.writeFile(relativePath: ".codex/auth.json", data: E2EFixtureFactory.codexAuthJSON(accessToken: expAtNow))
        XCTAssertEqual(reader.readCredentials(now: now), .failure(.tokenExpired))

        let expAtMargin = E2EFixtureFactory.makeJWT(claims: ["exp": now.timeIntervalSince1970 + 30.0])
        _ = try home.writeFile(relativePath: ".codex/auth.json", data: E2EFixtureFactory.codexAuthJSON(accessToken: expAtMargin))
        XCTAssertEqual(reader.readCredentials(now: now), .failure(.tokenExpired))

        let expJustValid = E2EFixtureFactory.makeJWT(claims: ["exp": now.timeIntervalSince1970 + 30.001])
        _ = try home.writeFile(relativePath: ".codex/auth.json", data: E2EFixtureFactory.codexAuthJSON(accessToken: expJustValid))
        guard case .success(let creds) = reader.readCredentials(now: now) else {
            return XCTFail("Expected success at JWT exp = now + 30.001s")
        }
        XCTAssertEqual(creds.accessToken, expJustValid)
    }

    func testF05_04_codexLastRefresh8DaysPlus1sReturnsTokenExpired() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let home = try makeTempHome()
        let staleRefresh = now.timeIntervalSince1970 - (8 * 86_400 + 1)
        _ = try home.writeFile(
            relativePath: ".codex/auth.json",
            data: E2EFixtureFactory.codexAuthJSON(accessToken: "opaque-no-exp", lastRefresh: staleRefresh)
        )

        let reader = CodexCredentialReader(environment: [:], homeDirectory: home.rootURL)
        XCTAssertEqual(reader.readCredentials(now: now), .failure(.tokenExpired))
    }

    func testF05_05_codexLastRefresh8DaysMinus1sSucceeds() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let home = try makeTempHome()
        let validRefresh = now.timeIntervalSince1970 - (8 * 86_400 - 1)
        _ = try home.writeFile(
            relativePath: ".codex/auth.json",
            data: E2EFixtureFactory.codexAuthJSON(accessToken: "opaque-no-exp", lastRefresh: validRefresh)
        )

        let reader = CodexCredentialReader(environment: [:], homeDirectory: home.rootURL)
        guard case .success = reader.readCredentials(now: now) else {
            return XCTFail("Expected success at 8 days - 1s")
        }
    }

    // MARK: - F6 Boundary Cases (5)

    func testF06_01_codex200WithEmptyObjectReturnsDecodingFailure() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let provider = CodexUsageProvider(
            credentialReader: E2ESpyCodexCredentialReader(result: .success(CodexOAuthCredentials(accessToken: "t", refreshToken: nil, idToken: nil, accountId: nil, accountEmail: nil, expiresAt: nil, lastRefresh: nil, planType: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((Data("{}".utf8), E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)))])
        )
        guard case .failure(.decodingFailure) = await provider.fetchQuota(now: now) else {
            return XCTFail("Expected decodingFailure when windows and credits are missing")
        }
    }

    func testF06_02_codexUsedPercentZeroAnd100ExactBounds() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let body = E2EFixtureFactory.codexUsageJSON(primaryUsedPercent: 0, secondaryUsedPercent: 100, creditsHasCredits: nil, creditsUnlimited: nil, creditsBalance: nil)
        let provider = CodexUsageProvider(
            credentialReader: E2ESpyCodexCredentialReader(result: .success(CodexOAuthCredentials(accessToken: "t", refreshToken: nil, idToken: nil, accountId: nil, accountEmail: nil, expiresAt: nil, lastRefresh: nil, planType: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((body, E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)))])
        )
        guard case .success(let snap) = await provider.fetchQuota(now: now) else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(snap.primaryWindow?.usedRatio, 0.0)
        XCTAssertEqual(snap.secondaryWindow?.usedRatio, 1.0)
    }

    func testF06_03_codexOutOfRangeUsedPercentClamps0To1() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let body = E2EFixtureFactory.codexUsageJSON(primaryUsedPercent: -1, secondaryUsedPercent: 105, creditsHasCredits: nil, creditsUnlimited: nil, creditsBalance: nil)
        let provider = CodexUsageProvider(
            credentialReader: E2ESpyCodexCredentialReader(result: .success(CodexOAuthCredentials(accessToken: "t", refreshToken: nil, idToken: nil, accountId: nil, accountEmail: nil, expiresAt: nil, lastRefresh: nil, planType: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((body, E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)))])
        )
        guard case .success(let snap) = await provider.fetchQuota(now: now) else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(snap.primaryWindow?.usedRatio, 0.0)
        XCTAssertEqual(snap.secondaryWindow?.usedRatio, 1.0)
    }

    func testF06_04_codexResetAfterZeroAndPastResetAt() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let pastTs = now.timeIntervalSince1970 - 300
        let body = E2EFixtureFactory.codexUsageJSON(
            primaryUsedPercent: 10,
            primaryResetAt: nil,
            primaryResetAfterSeconds: 0,
            secondaryUsedPercent: 20,
            secondaryResetAt: pastTs,
            secondaryResetAfterSeconds: nil,
            creditsHasCredits: nil,
            creditsUnlimited: nil,
            creditsBalance: nil
        )
        let provider = CodexUsageProvider(
            credentialReader: E2ESpyCodexCredentialReader(result: .success(CodexOAuthCredentials(accessToken: "t", refreshToken: nil, idToken: nil, accountId: nil, accountEmail: nil, expiresAt: nil, lastRefresh: nil, planType: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((body, E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)))])
        )
        guard case .success(let snap) = await provider.fetchQuota(now: now) else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(snap.primaryWindow?.resetsAt, now)
        XCTAssertEqual(snap.secondaryWindow?.resetsAt?.timeIntervalSince1970 ?? 0, pastTs, accuracy: 0.01)
    }

    func testF06_05_codexWhitespaceAccountIdOmitsHeader() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let transport = E2ERecordingHTTPTransport(scriptedQueue: [
            .success((E2EFixtureFactory.codexUsageJSON(), E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)))
        ])
        let provider = CodexUsageProvider(
            credentialReader: E2ESpyCodexCredentialReader(result: .success(CodexOAuthCredentials(accessToken: "t", refreshToken: nil, idToken: nil, accountId: "   ", accountEmail: nil, expiresAt: nil, lastRefresh: nil, planType: nil))),
            transport: transport
        )
        _ = await provider.fetchQuota(now: now)
        let reqs = await transport.requests
        XCTAssertNil(reqs[0].value(forHTTPHeaderField: "ChatGPT-Account-Id"))
    }

    // MARK: - F7 Boundary Cases: CodexBarCore Error Mapping (5)

    func testF07_01_antigravityProbeMissingTokenAndPortErrorsMapToCredentialsMissing() {
        XCTAssertEqual(CodexBarUsageProvider.mapError(AntigravityStatusProbeError.notRunning), .credentialsMissing)
        XCTAssertEqual(CodexBarUsageProvider.mapError(AntigravityStatusProbeError.missingCSRFToken), .credentialsMissing)
        XCTAssertEqual(CodexBarUsageProvider.mapError(AntigravityStatusProbeError.portDetectionFailed("no port")), .credentialsMissing)
    }

    func testF07_02_antigravityAuthAndMismatchErrorsMapToUnauthorized() {
        XCTAssertEqual(CodexBarUsageProvider.mapError(AntigravityStatusProbeError.authenticationRequired), .unauthorized)
        XCTAssertEqual(CodexBarUsageProvider.mapError(AntigravityStatusProbeError.accountMismatch(expected: "a@b.com", found: "c@d.com")), .unauthorized)
    }

    func testF07_03_antigravityParseFailedAndTimedOutMapAccurately() {
        guard case .decodingFailure(let msg) = CodexBarUsageProvider.mapError(AntigravityStatusProbeError.parseFailed("bad payload")) else {
            return XCTFail("Expected decodingFailure for parseFailed")
        }
        XCTAssertEqual(msg, "bad payload")

        guard case .networkFailure = CodexBarUsageProvider.mapError(AntigravityStatusProbeError.timedOut) else {
            return XCTFail("Expected networkFailure for timedOut")
        }
    }

    func testF07_04_classifiedErrorsMapAcrossAllVariants() {
        XCTAssertEqual(CodexBarUsageProvider.mapError(ProviderFetchClassifiedError(kind: .missingCredential, message: "m")), .credentialsMissing)
        XCTAssertEqual(CodexBarUsageProvider.mapError(ProviderFetchClassifiedError(kind: .authenticationExpired, message: "e")), .tokenExpired)
        XCTAssertEqual(CodexBarUsageProvider.mapError(ProviderFetchClassifiedError(kind: .permissionDenied, message: "p")), .unauthorized)
        XCTAssertEqual(CodexBarUsageProvider.mapError(ProviderFetchClassifiedError(kind: .rateLimited, message: "r", retryAfterSeconds: 9)), .rateLimited(retryAfter: 9))
        XCTAssertEqual(CodexBarUsageProvider.mapError(ProviderFetchClassifiedError(kind: .providerUnavailable, message: "u")), .endpointUnavailable(statusCode: 503))
    }

    func testF07_05_urlErrorMapsToNetworkFailure() {
        guard case .networkFailure = CodexBarUsageProvider.mapError(URLError(.notConnectedToInternet)) else {
            return XCTFail("Expected networkFailure for URLError")
        }
    }

    // MARK: - F8 Boundary Cases: CodexBarCore Snapshot Normalization (5)

    func testF08_01_emptyUsageSnapshotReturnsDecodingFailure() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let usage = UsageSnapshot(primary: nil, secondary: nil, tertiary: nil, extraRateWindows: [], updatedAt: now)
        let fetchResult = ProviderFetchResult(usage: usage, credits: nil, dashboard: nil, sourceLabel: "antigravity", strategyID: "antigravity", strategyKind: .localProbe)
        let provider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
            ProviderFetchOutcome(result: .success(fetchResult), attempts: [])
        }
        guard case .failure(.decodingFailure) = await provider.fetchQuota(now: now) else {
            return XCTFail("Expected decodingFailure for empty UsageSnapshot")
        }
    }

    func testF08_02_syntheticPlaceholderWindowsOnlyReturnsDecodingFailure() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let placeholder = RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil, isSyntheticPlaceholder: true)
        let usage = UsageSnapshot(primary: placeholder, secondary: nil, updatedAt: now)
        let fetchResult = ProviderFetchResult(usage: usage, credits: nil, dashboard: nil, sourceLabel: "claude", strategyID: "claude.oauth", strategyKind: .oauth)
        let provider = CodexBarUsageProvider(providerID: .claude, environment: [:]) { _, _ in
            ProviderFetchOutcome(result: .success(fetchResult), attempts: [])
        }
        guard case .failure(.decodingFailure) = await provider.fetchQuota(now: now) else {
            return XCTFail("Expected decodingFailure when only synthetic placeholder windows are present")
        }
    }

    func testF08_03_usedPercentZeroAnd100ExactBounds() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil, title: "Gemini Models"),
            secondary: RateWindow(usedPercent: 0, windowMinutes: 10_080, resetsAt: nil, resetDescription: nil, title: "Claude and GPT"),
            updatedAt: now
        )
        let fetchResult = ProviderFetchResult(usage: usage, credits: nil, dashboard: nil, sourceLabel: "antigravity", strategyID: "antigravity", strategyKind: .localProbe)
        let provider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
            ProviderFetchOutcome(result: .success(fetchResult), attempts: [])
        }
        let snap = try await provider.fetchQuota(now: now).get()
        XCTAssertEqual(snap.primaryWindow?.usedRatio, 1.0)
        XCTAssertEqual(snap.secondaryWindow?.usedRatio, 0.0)
    }

    func testF08_04_outOfRangeAndNaNUsedPercentClampCleanly() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 150, windowMinutes: 300, resetsAt: nil, resetDescription: nil, title: "High"),
            secondary: RateWindow(usedPercent: -25, windowMinutes: 10_080, resetsAt: nil, resetDescription: nil, title: "Low"),
            tertiary: RateWindow(usedPercent: .nan, windowMinutes: 300, resetsAt: nil, resetDescription: nil, title: "NaN"),
            updatedAt: now
        )
        let fetchResult = ProviderFetchResult(usage: usage, credits: nil, dashboard: nil, sourceLabel: "antigravity", strategyID: "antigravity", strategyKind: .localProbe)
        let provider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
            ProviderFetchOutcome(result: .success(fetchResult), attempts: [])
        }
        let snap = try await provider.fetchQuota(now: now).get()
        XCTAssertEqual(snap.primaryWindow?.usedRatio, 1.0)
        XCTAssertEqual(snap.secondaryWindow?.usedRatio, 0.0)
        XCTAssertEqual(snap.additionalWindows.first?.usedRatio, 0.0)
    }

    func testF08_05_creditsCurrencyCostSnapshotIgnoredAsMonetaryExtraUsage() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            providerCost: ProviderCostSnapshot(used: 10, limit: 100, currencyCode: "CREDITS", updatedAt: now),
            updatedAt: now
        )
        let fetchResult = ProviderFetchResult(usage: usage, credits: nil, dashboard: nil, sourceLabel: "antigravity", strategyID: "antigravity", strategyKind: .localProbe)
        let provider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
            ProviderFetchOutcome(result: .success(fetchResult), attempts: [])
        }
        let snap = try await provider.fetchQuota(now: now).get()
        XCTAssertNil(snap.extraUsage)
    }

    // MARK: - F9 Boundary Cases (5)

    func testF09_01_retryAfterZeroIgnoredSafely() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertNil(AIUsageParsing.parseRetryAfter("0", now: now))
        XCTAssertNil(ClaudeUsageProvider.parseRetryAfter("0", now: now))
    }

    func testF09_02_retryAfterHTTPDateAndInvalidStrings() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let futureHeader = formatter.string(from: now.addingTimeInterval(90))
        let parsed = AIUsageParsing.parseRetryAfter(futureHeader, now: now)
        XCTAssertEqual(parsed ?? -1, 90, accuracy: 1.0)
        XCTAssertNil(AIUsageParsing.parseRetryAfter("not-a-retry-header", now: now))
        XCTAssertNil(AIUsageParsing.parseRetryAfter(nil, now: now))
    }

    func testF09_03_retryAfterNegativeIgnoredSafely() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertNil(AIUsageParsing.parseRetryAfter("-5", now: now))
    }

    func testF09_04_httpStatus400_404_500_502_504PreserveExactStatusCode() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        for code in [400, 404, 500, 502, 504] {
            let provider = CodexUsageProvider(
                credentialReader: E2ESpyCodexCredentialReader(result: .success(CodexOAuthCredentials(accessToken: "t", refreshToken: nil, idToken: nil, accountId: nil, accountEmail: nil, expiresAt: nil, lastRefresh: nil, planType: nil))),
                transport: E2ERecordingHTTPTransport(scriptedQueue: [.success((Data(), E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: code)))])
            )
            let result = await provider.fetchQuota(now: now)
            XCTAssertEqual(result, .failure(.endpointUnavailable(statusCode: code)))
        }
    }

    func testF09_05_errorsNeverSynthesizeZeroOrHundredPercentSnapshot() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: E2ESpyAIUsageProvider(id: .claude, fallback: .failure(.networkFailure("offline")))]
        )
        _ = await vm.performManualRefresh()
        XCTAssertNil(vm.snapshot(for: .claude))
        XCTAssertEqual(vm.state(for: .claude), .error(.networkFailure("offline")))
    }

    // MARK: - F10 Boundary Cases (5)

    func testF10_01_prepopulatedCodexEnabledNotResetOnInit() {
        let (settings, suite, defaults) = E2EIsolatedStore.makeSettings()
        cleanup.registerSuite(suite)
        defaults.set(true, forKey: "aiUsage.codex.enabled")
        _ = settings

        let loaded = LynxBar.Settings(defaults: defaults)
        XCTAssertTrue(loaded.codexUsageEnabled)
        XCTAssertFalse(loaded.claudeUsageEnabled)
        XCTAssertFalse(loaded.antigravityUsageEnabled)
    }

    func testF10_02_legacyAIUsageEnabledDoesNotEnableCodexOrAntigravity() {
        let (_, suite, defaults) = E2EIsolatedStore.makeSettings()
        cleanup.registerSuite(suite)
        defaults.set(true, forKey: "aiUsage.enabled")

        let loaded = LynxBar.Settings(defaults: defaults)
        XCTAssertTrue(loaded.claudeUsageEnabled)
        XCTAssertFalse(loaded.codexUsageEnabled)
        XCTAssertFalse(loaded.antigravityUsageEnabled)
    }

    func testF10_03_rapidTogglingLeavesFinalPersistedStateConsistent() {
        let (settings, suite, defaults) = E2EIsolatedStore.makeSettings()
        cleanup.registerSuite(suite)
        settings.antigravityUsageEnabled = true
        settings.antigravityUsageEnabled = false
        settings.antigravityUsageEnabled = true
        XCTAssertTrue(defaults.bool(forKey: "aiUsage.antigravity.enabled"))
        XCTAssertTrue(settings.aiUsageEnabled)
    }

    func testF10_04_invalidDisplayStyleInDefaultsFallsBackToRemaining() {
        let (_, suite, defaults) = E2EIsolatedStore.makeSettings()
        cleanup.registerSuite(suite)
        defaults.set("corrupt_style", forKey: "aiUsage.displayStyle")

        let loaded = LynxBar.Settings(defaults: defaults)
        XCTAssertEqual(loaded.aiQuotaDisplayStyle, .remaining)
    }

    func testF10_05_isolatedUserDefaultsSuitesDoNotLeakAcrossInstances() {
        let s1 = makeIsolatedSettings()
        let s2 = makeIsolatedSettings()
        s1.codexUsageEnabled = true
        s1.aiQuotaDisplayStyle = .used
        XCTAssertFalse(s2.codexUsageEnabled)
        XCTAssertEqual(s2.aiQuotaDisplayStyle, .remaining)
    }

    // MARK: - F11 Boundary Cases (5)

    func testF11_01_claudeOnlyStartSamplingLeavesCodexAndAntigravityAtZero() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let claude = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.2)))
        let codex = E2ESpyAIUsageProvider(id: .codex)
        let antigravity = E2ESpyAIUsageProvider(id: .antigravity)
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(settings: settings, providers: [.claude: claude, .codex: codex, .antigravity: antigravity], sleeper: { try await sleeper.sleep($0) })

        vm.startSampling()
        await claude.waitForFetchStart(atLeast: 1)
        await sleeper.waitUntilPendingCount(atLeast: 1)
        let codexCount = await codex.callCount
        let antigravityCount = await antigravity.callCount
        XCTAssertEqual(codexCount, 0)
        XCTAssertEqual(antigravityCount, 0)
        vm.stopSampling()
    }

    func testF11_02_togglingClaudeOffMidSessionStopsSubsequent300sPollTicks() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let claude = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.2)))
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(settings: settings, providers: [.claude: claude], sleeper: { try await sleeper.sleep($0) })

        vm.startSampling()
        await sleeper.waitUntilPendingCount(atLeast: 1)
        settings.claudeUsageEnabled = false
        _ = await E2EAsync.waitUntil { vm.state(for: .claude) == .disabled }
        await sleeper.resumeAll()
        await E2EAsync.settle()
        let calls = await claude.callCount
        XCTAssertEqual(calls, 1)
        vm.stopSampling()
    }

    func testF11_03_codexEnabledWithOverviewDemandOnlyFetchesCodex() async {
        let settings = makeIsolatedSettings()
        settings.codexUsageEnabled = true
        let claude = E2ESpyAIUsageProvider(id: .claude)
        let codex = E2ESpyAIUsageProvider(id: .codex, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.3)))
        let antigravity = E2ESpyAIUsageProvider(id: .antigravity)
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(settings: settings, providers: [.claude: claude, .codex: codex, .antigravity: antigravity], sleeper: { try await sleeper.sleep($0) })

        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { module, active in
            if module == .aiUsage {
                if active { vm.startSampling() } else { vm.stopSampling() }
            }
        }
        let owner = E2ETestDemandOwner()
        let token = coordinator.acquire(module: .aiUsage, reason: .panel(.overview), owner: owner)
        await codex.waitForFetchStart(atLeast: 1)
        await sleeper.waitUntilPendingCount(atLeast: 1)

        let c1 = await claude.callCount
        let c2 = await codex.callCount
        let c3 = await antigravity.callCount
        XCTAssertEqual(c1, 0)
        XCTAssertEqual(c2, 1)
        XCTAssertEqual(c3, 0)
        token.cancel()
    }

    func testF11_04_menuBarAISlotWithAllProvidersDisabledMakesZeroFetches() async {
        let settings = makeIsolatedSettings()
        let claude = E2ESpyAIUsageProvider(id: .claude)
        let codex = E2ESpyAIUsageProvider(id: .codex)
        let antigravity = E2ESpyAIUsageProvider(id: .antigravity)
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(settings: settings, providers: [.claude: claude, .codex: codex, .antigravity: antigravity], sleeper: { try await sleeper.sleep($0) })

        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { module, active in
            if module == .aiUsage {
                if active { vm.startSampling() } else { vm.stopSampling() }
            }
        }
        settings.menuBarSlots = [.aiUsage, .cpu, .memory]
        let owner = E2ETestDemandOwner()
        let token = coordinator.acquire(module: .aiUsage, reason: .menuBar, owner: owner)
        await E2EAsync.settle()

        let c1 = await claude.callCount
        let c2 = await codex.callCount
        let c3 = await antigravity.callCount
        XCTAssertEqual(c1 + c2 + c3, 0)
        token.cancel()
    }

    func testF11_05_manualRefreshWithAntigravityOnlyLeavesClaudeAndCodexAtZero() async {
        let settings = makeIsolatedSettings()
        settings.antigravityUsageEnabled = true
        let claude = E2ESpyAIUsageProvider(id: .claude)
        let codex = E2ESpyAIUsageProvider(id: .codex)
        let antigravity = E2ESpyAIUsageProvider(id: .antigravity, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .antigravity, usedRatio: 0.4)))
        let vm = AIUsageViewModel(settings: settings, providers: [.claude: claude, .codex: codex, .antigravity: antigravity])

        _ = await vm.performManualRefresh()
        let c1 = await claude.callCount
        let c2 = await codex.callCount
        let c3 = await antigravity.callCount
        XCTAssertEqual(c1, 0)
        XCTAssertEqual(c2, 0)
        XCTAssertEqual(c3, 1)
    }

    // MARK: - F12 Boundary Cases (5)

    func testF12_01_cooldownExactBoundary59_9Vs60_0Seconds() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let claude = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.2)))
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(settings: settings, providers: [.claude: claude], sleeper: { try await sleeper.sleep($0) }, now: clock.makeProvider())

        vm.startSampling()
        await sleeper.waitUntilPendingCount(atLeast: 1)
        vm.stopSampling()

        clock.advance(by: 59.9)
        vm.startSampling()
        await sleeper.waitUntilPendingCount(atLeast: 1)
        let callsAt599 = await claude.callCount
        XCTAssertEqual(callsAt599, 1)
        vm.stopSampling()

        clock.advance(by: 0.1) // total 60.0s
        vm.startSampling()
        await claude.waitForFetchStart(atLeast: 2)
        let callsAt600 = await claude.callCount
        XCTAssertEqual(callsAt600, 2)
        vm.stopSampling()
    }

    func testF12_02_manualThrottleExactBoundary4_9Vs5_0Seconds() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.codexUsageEnabled = true
        let codex = E2ESpyAIUsageProvider(id: .codex, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.2)))
        let vm = AIUsageViewModel(settings: settings, providers: [.codex: codex], now: clock.makeProvider())

        let first = await vm.performManualRefresh(for: .codex)
        XCTAssertNotNil(first)

        clock.advance(by: 4.9)
        let throttled = await vm.performManualRefresh(for: .codex)
        XCTAssertNil(throttled)

        clock.advance(by: 0.1) // total 5.0s
        let allowed = await vm.performManualRefresh(for: .codex)
        XCTAssertNotNil(allowed)

        let calls = await codex.callCount
        XCTAssertEqual(calls, 2)
    }

    func testF12_03_singleFlightDeduplicatesConcurrentStartSamplingAndManualRefresh() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let claude = E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.2)))
        await claude.holdUpcomingFetch()

        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(settings: settings, providers: [.claude: claude], sleeper: { try await sleeper.sleep($0) })

        vm.startSampling()
        await claude.waitForFetchStart(atLeast: 1)

        async let manualResult = vm.performManualRefresh(for: .claude)
        await E2EAsync.settle()
        await claude.releaseHeldFetch()
        let outcome = await manualResult
        XCTAssertNotNil(outcome)

        let totalCalls = await claude.callCount
        XCTAssertEqual(totalCalls, 1)
        vm.stopSampling()
    }

    func testF12_04_consecutive429BackoffCapsAt1800Seconds() async {
        let settings = makeIsolatedSettings()
        settings.antigravityUsageEnabled = true
        let antigravity = E2ESpyAIUsageProvider(id: .antigravity, fallback: .failure(.rateLimited(retryAfter: nil)))
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(settings: settings, providers: [.antigravity: antigravity], sleeper: { try await sleeper.sleep($0) })

        vm.startSampling()
        for _ in 0..<4 {
            await sleeper.waitUntilPendingCount(atLeast: 1)
            await sleeper.resumeNext()
        }
        await sleeper.waitUntilPendingCount(atLeast: 1)

        let delays = await sleeper.recordedDelays
        XCTAssertEqual(delays, [300, 600, 1_200, 1_800, 1_800])
        vm.stopSampling()
    }

    func testF12_05_fatalErrorsStopAutomaticRetryUntilManualRefresh() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.codexUsageEnabled = true
        let codex = E2ESpyAIUsageProvider(
            id: .codex,
            results: [.failure(.tokenExpired)],
            fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.1))
        )
        let sleeper = E2EVirtualSleeper()
        let vm = AIUsageViewModel(settings: settings, providers: [.codex: codex], sleeper: { try await sleeper.sleep($0) }, now: clock.makeProvider())

        vm.startSampling()
        let errored = await E2EAsync.waitUntil { vm.state(for: .codex) == .error(.tokenExpired) }
        XCTAssertTrue(errored)
        let delays = await sleeper.recordedDelays
        XCTAssertTrue(delays.isEmpty)

        clock.advance(by: 10)
        _ = await vm.performManualRefresh(for: .codex)
        if case .loaded = vm.state(for: .codex) {
            // Recovered after manual refresh
        } else {
            XCTFail("Expected .loaded after manual refresh recovery")
        }
        vm.stopSampling()
    }

    // MARK: - F13 Boundary Cases (5)

    func testF13_01_thresholdBoundaries30_1Vs30Vs10_1Vs10Vs0() throws {
        let panelSource = try String(
            contentsOf: E2ERepoInspector.repoRootURL().appendingPathComponent("Sources/LynxBar/Modules/AIUsage/AIUsagePanelView.swift"),
            encoding: .utf8
        )
        // Verify exact boundary predicates: <= 0.10 -> critical, <= 0.30 -> warning, else health
        XCTAssertTrue(panelSource.contains("if window.remainingRatio <= 0.10 { return Theme.critical }"))
        XCTAssertTrue(panelSource.contains("if window.remainingRatio <= 0.30 { return Theme.warning }"))
        XCTAssertTrue(panelSource.contains("return Theme.health"))

        let green = AIQuotaWindow(id: "g", kind: .session5h, title: "t", usedRatio: 1.0 - 0.301, resetsAt: nil)
        let amberTop = AIQuotaWindow(id: "a1", kind: .session5h, title: "t", usedRatio: 1.0 - 0.30, resetsAt: nil)
        let amberLow = AIQuotaWindow(id: "a2", kind: .session5h, title: "t", usedRatio: 1.0 - 0.101, resetsAt: nil)
        let redTop = AIQuotaWindow(id: "r1", kind: .session5h, title: "t", usedRatio: 1.0 - 0.10, resetsAt: nil)
        let redZero = AIQuotaWindow(id: "r2", kind: .session5h, title: "t", usedRatio: 1.0, resetsAt: nil)

        XCTAssertGreaterThan(green.remainingRatio, 0.30)
        XCTAssertEqual(amberTop.remainingRatio, 0.30, accuracy: 0.0001)
        XCTAssertGreaterThan(amberLow.remainingRatio, 0.10)
        XCTAssertEqual(redTop.remainingRatio, 0.10, accuracy: 0.0001)
        XCTAssertEqual(redZero.remainingRatio, 0.0, accuracy: 0.0001)
    }

    func testF13_02_snapshotWithPrimaryWindowOnlyRendersCleanly() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let snap = E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.35, secondaryUsedRatio: nil, planLabel: "Pro")
        let vm = AIUsageViewModel(settings: settings, providers: [.claude: E2ESpyAIUsageProvider(id: .claude, fallback: .success(snap))])
        _ = await vm.performManualRefresh()

        var sel: DashboardSection = .aiUsage
        let host = NSHostingView(rootView: AIUsagePanelView(viewModel: vm, selection: Binding(get: { sel }, set: { sel = $0 })))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 80)
    }

    func testF13_03_snapshotWithNilPlanLabelAndNilExtraUsageRendersCleanly() async {
        let settings = makeIsolatedSettings()
        settings.codexUsageEnabled = true
        let snap = E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.5, planLabel: nil)
        let vm = AIUsageViewModel(settings: settings, providers: [.codex: E2ESpyAIUsageProvider(id: .codex, fallback: .success(snap))])
        _ = await vm.performManualRefresh()

        var sel: DashboardSection = .aiUsage
        let host = NSHostingView(rootView: AIUsagePanelView(viewModel: vm, selection: Binding(get: { sel }, set: { sel = $0 })))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 80)
    }

    func testF13_04_staleStatePreservesSnapshotAndSurfacesErrorSimultaneously() async {
        let clock = E2ETestClock()
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let snap = E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.25)
        let provider = E2ESpyAIUsageProvider(id: .claude, results: [.success(snap), .failure(.networkFailure("timeout"))])
        let vm = AIUsageViewModel(settings: settings, providers: [.claude: provider], now: clock.makeProvider())

        _ = await vm.performManualRefresh()
        clock.advance(by: 10)
        _ = await vm.performManualRefresh()

        XCTAssertNotNil(vm.snapshot(for: .claude))
        XCTAssertEqual(vm.lastError(for: .claude), .networkFailure("timeout"))
        if case .stale(let retained, let err) = vm.state(for: .claude) {
            XCTAssertEqual(retained.primaryWindow?.usedRatio, 0.25)
            XCTAssertEqual(err, .networkFailure("timeout"))
        } else {
            XCTFail("Expected .stale")
        }
    }

    func testF13_05_switchingDisplayStyleInvertsPercentageSummaries() {
        let snap = E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.80)
        let states: [AIUsageProviderID: AIUsageProviderState] = [
            .claude: AIUsageProviderState(providerID: .claude, state: .loaded(snap), isRefreshing: false, lastSuccessfulFetchAt: snap.fetchedAt, lastError: nil)
        ]

        let remainingText = OverviewAIQuotaRow.accessibilityValueSummary(
            enabledIDs: [.claude],
            providerStates: states,
            displayStyle: .remaining
        )
        let usedText = OverviewAIQuotaRow.accessibilityValueSummary(
            enabledIDs: [.claude],
            providerStates: states,
            displayStyle: .used
        )
        XCTAssertTrue(remainingText.contains("20"))
        XCTAssertTrue(usedText.contains("80"))
    }

    // MARK: - F14 Boundary Cases (5)

    func testF14_01_totalHeightAIEnabledHasNonNegativeHeadroomWithin496() {
        let margin = OverviewLayoutMetrics.availableOverviewHeight - OverviewLayoutMetrics.totalHeight(aiEnabled: true)
        XCTAssertGreaterThanOrEqual(margin, 0)
    }

    func testF14_02_totalHeightAIDisabledHasNonNegativeHeadroomWithin496() {
        let margin = OverviewLayoutMetrics.availableOverviewHeight - OverviewLayoutMetrics.totalHeight(aiEnabled: false)
        XCTAssertGreaterThanOrEqual(margin, 0)
    }

    func testF14_03_threeProvidersWithLongLabelsClampOverviewRowHeightTo36() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        settings.antigravityUsageEnabled = true
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.99, planLabel: "Enterprise Ultra Long Plan"))),
                .codex: E2ESpyAIUsageProvider(id: .codex, fallback: .failure(.tokenExpired)),
                .antigravity: E2ESpyAIUsageProvider(id: .antigravity, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .antigravity, usedRatio: 0.12, planLabel: "Google AI Ultra Business"))),
            ]
        )
        _ = await vm.performManualRefresh()

        var sel: DashboardSection = .overview
        let host = NSHostingView(rootView: OverviewAIQuotaRow(aiUsage: vm, selection: Binding(get: { sel }, set: { sel = $0 })))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 36)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, 36, accuracy: 0.5)
    }

    func testF14_04_singleProviderLoadingOrErrorClampsOverviewRowHeightTo36() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [.claude: E2ESpyAIUsageProvider(id: .claude, fallback: .failure(.endpointUnavailable(statusCode: 503)))]
        )
        var sel: DashboardSection = .overview
        let loadingHost = NSHostingView(rootView: OverviewAIQuotaRow(aiUsage: vm, selection: Binding(get: { sel }, set: { sel = $0 })))
        loadingHost.frame = NSRect(x: 0, y: 0, width: 400, height: 36)
        loadingHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(loadingHost.fittingSize.height, 36, accuracy: 0.5)

        _ = await vm.performManualRefresh()
        let errorHost = NSHostingView(rootView: OverviewAIQuotaRow(aiUsage: vm, selection: Binding(get: { sel }, set: { sel = $0 })))
        errorHost.frame = NSRect(x: 0, y: 0, width: 400, height: 36)
        errorHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(errorHost.fittingSize.height, 36, accuracy: 0.5)
    }

    func testF14_05_visibleProcessRowCountPreserves496Budget() {
        XCTAssertEqual(OverviewLayoutMetrics.visibleProcessRowCount, 3)
        XCTAssertLessThanOrEqual(OverviewLayoutMetrics.totalHeight(aiEnabled: true), 496)
        XCTAssertLessThanOrEqual(OverviewLayoutMetrics.totalHeight(aiEnabled: false), 496)
    }

    // MARK: - F15 Boundary Cases (5)

    func testF15_01_minimalModeHidesAISlotWithin28ptBudget() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let snapshot = MenuBarStatusSnapshot(health: .healthy, readings: [.aiUsage: .aiQuota(usedRatio: 0.25, observedAt: now)])
        let pres = MenuBarStatusFormatter.format(mode: .minimal, slots: [.aiUsage], snapshot: snapshot, now: now)
        XCTAssertTrue(pres.segments.isEmpty)
        XCTAssertLessThanOrEqual(MenuBarStatusRenderer.layout(for: pres).width, 28)
    }

    func testF15_02_focusModeWithThreeProvidersAt100PercentFits132pt() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let entries = [
            MenuBarAIQuotaEntry(providerID: .claude, usedRatio: 0.0, observedAt: now),
            MenuBarAIQuotaEntry(providerID: .codex, usedRatio: 0.0, observedAt: now),
            MenuBarAIQuotaEntry(providerID: .antigravity, usedRatio: 0.0, observedAt: now),
        ]
        let snapshot = MenuBarStatusSnapshot(health: .healthy, readings: [.aiUsage: .aiQuotas(entries, displayStyle: .remaining)])
        let pres = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: snapshot, now: now)
        XCTAssertTrue(pres.title.contains("AI 100%"))
        XCTAssertLessThanOrEqual(MenuBarStatusRenderer.layout(for: pres).width, 132)
    }

    func testF15_03_compactModeWithCPUMemoryAI3ProvidersFits300ptInEnAndZhHans() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let entries = [
            MenuBarAIQuotaEntry(providerID: .claude, usedRatio: 0.0, observedAt: now),
            MenuBarAIQuotaEntry(providerID: .codex, usedRatio: 0.0, observedAt: now),
            MenuBarAIQuotaEntry(providerID: .antigravity, usedRatio: 0.0, observedAt: now),
        ]
        let snapshot = MenuBarStatusSnapshot(
            health: .healthy,
            readings: [
                .cpu: .numeric(1.0, observedAt: now),
                .memory: .numeric(1.0, observedAt: now),
                .aiUsage: .aiQuotas(entries, displayStyle: .remaining),
            ]
        )
        for localeId in ["en", "zh-Hans"] {
            let pres = MenuBarStatusFormatter.format(mode: .compact, slots: [.cpu, .memory, .aiUsage], snapshot: snapshot, locale: Locale(identifier: localeId), now: now)
            XCTAssertLessThanOrEqual(MenuBarStatusRenderer.layout(for: pres).width, 300)
        }
    }

    func testF15_04_ttlExactBoundaries900Vs900_1AndNegativeSkew() {
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let reading = MenuBarMetricReading.aiQuota(usedRatio: 0.3, observedAt: t0, staleAfter: 900)
        XCTAssertEqual(reading.resolvedAvailability(at: t0.addingTimeInterval(900.0)), .available)
        XCTAssertEqual(reading.resolvedAvailability(at: t0.addingTimeInterval(900.1)), .stale)
        XCTAssertEqual(reading.resolvedAvailability(at: t0.addingTimeInterval(-1.0)), .stale)
    }

    func testF15_05_usedRatioZeroAndOneBoundsFormatAccuratelyInMenuBar() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let zeroSnap = MenuBarStatusSnapshot(health: .healthy, readings: [.aiUsage: .aiQuota(usedRatio: 0.0, displayStyle: .remaining, observedAt: now)])
        let fullSnap = MenuBarStatusSnapshot(health: .healthy, readings: [.aiUsage: .aiQuota(usedRatio: 1.0, displayStyle: .remaining, observedAt: now)])

        let remZero = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: zeroSnap, now: now, aiQuotaDisplayStyle: .remaining)
        let usedZero = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: zeroSnap, now: now, aiQuotaDisplayStyle: .used)
        let remFull = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: fullSnap, now: now, aiQuotaDisplayStyle: .remaining)
        let usedFull = MenuBarStatusFormatter.format(mode: .focus, slots: [.aiUsage], snapshot: fullSnap, now: now, aiQuotaDisplayStyle: .used)

        XCTAssertTrue(remZero.title.contains("AI 100%"))
        XCTAssertTrue(usedZero.title.contains("AI 0%"))
        XCTAssertTrue(remFull.title.contains("AI 0%"))
        XCTAssertTrue(usedFull.title.contains("AI 100%"))
    }

    // MARK: - F16 Boundary Cases (5)

    func testF16_01_noEmptyLocalizedValuesForNonEmptyKeys() throws {
        let root = E2ERepoInspector.repoRootURL()
        for rel in ["Sources/LynxBar/Resources/en.lproj/Localizable.strings", "Sources/LynxBar/Resources/zh-Hans.lproj/Localizable.strings"] {
            let parsed = try E2ERepoInspector.parseLocalizableStrings(at: root.appendingPathComponent(rel))
            for (key, value) in parsed.entries where !key.isEmpty {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty value for key \(key) in \(rel)")
            }
        }
    }

    func testF16_02_specifierMismatchDetectorCatchesPositionalAndTypeMismatch() {
        let enSpecs = E2ERepoInspector.extractFormatSpecifiers(from: "Updated %1$@ for %2$lld%%")
        let zhMismatch = E2ERepoInspector.extractFormatSpecifiers(from: "Updated %2$@ for %1$@%%")
        XCTAssertEqual(enSpecs, ["%1$@", "%2$lld"])
        XCTAssertNotEqual(enSpecs, zhMismatch)
    }

    func testF16_03_duplicateKeyDetectorCatchesShadowedDefinitions() throws {
        let sample = """
        "Codex" = "Codex";
        "Codex" = "OpenAI Codex";
        """
        let parsed = try E2ERepoInspector.parseLocalizableStrings(text: sample)
        XCTAssertEqual(parsed.duplicates, ["Codex"])
    }

    func testF16_04_missingSemicolonSyntaxErrorRejected() {
        let bad = """
        "Codex" = "Codex"
        "Gemini" = "Gemini";
        """
        XCTAssertThrowsError(try E2ERepoInspector.parseLocalizableStrings(text: bad))
    }

    func testF16_05_unbalancedBlockCommentRejected() {
        let bad = """
        /* Unterminated comment
        "Codex" = "Codex";
        """
        XCTAssertThrowsError(try E2ERepoInspector.parseLocalizableStrings(text: bad))
    }

    // MARK: - F17 Boundary Cases (5)

    func testF17_01_whitespaceVariantSystemSizeRegexMatchesZeroOccurrences() throws {
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar")
        let regex = try NSRegularExpression(pattern: #"\.system\s*\(\s*size\s*:"#)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let matches = regex.numberOfMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
            XCTAssertEqual(matches, 0, "Forbidden .system(size:) variant in \(file.lastPathComponent)")
        }
    }

    func testF17_02_zeroNSFontSystemFontOfSizeInSwiftUIViews() throws {
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Modules")
            + E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Kit")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("NSFont.systemFont(ofSize:"), "Found NSFont.systemFont(ofSize:) in \(file.lastPathComponent)")
        }
    }

    func testF17_03_dynamicTypeAX5Preserves36ptOverviewRowHeight() async {
        let settings = makeIsolatedSettings()
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        settings.antigravityUsageEnabled = true
        let vm = AIUsageViewModel(
            settings: settings,
            providers: [
                .claude: E2ESpyAIUsageProvider(id: .claude, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .claude, usedRatio: 0.25))),
                .codex: E2ESpyAIUsageProvider(id: .codex, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .codex, usedRatio: 0.50))),
                .antigravity: E2ESpyAIUsageProvider(id: .antigravity, fallback: .success(E2EFixtureFactory.makeSnapshot(providerID: .antigravity, usedRatio: 0.75))),
            ]
        )
        _ = await vm.performManualRefresh()

        var sel: DashboardSection = .overview
        let row = OverviewAIQuotaRow(aiUsage: vm, selection: Binding(get: { sel }, set: { sel = $0 }))
            .environment(\.dynamicTypeSize, .accessibility5)
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 36)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, 36, accuracy: 0.5)
    }

    func testF17_04_themeFontHierarchyExcludesFixedPointSizesInThemeFile() throws {
        let themeText = try String(contentsOf: E2ERepoInspector.repoRootURL().appendingPathComponent("Sources/LynxBar/Kit/Theme.swift"), encoding: .utf8)
        XCTAssertFalse(themeText.contains("size:"))
        XCTAssertFalse(themeText.contains("fixedSize:"))
    }

    func testF17_05_zeroCustomFixedSizeFontBypassesInSources() throws {
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar")
        let regex = try NSRegularExpression(pattern: #"\.custom\([^)]*fixedSize:"#)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let matches = regex.numberOfMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
            XCTAssertEqual(matches, 0, "Found .custom(..., fixedSize:) in \(file.lastPathComponent)")
        }
    }

    // MARK: - F18 Boundary Cases (5)

    func testF18_01_canarySecretNeverLeaksInDescriptionsOrErrors() {
        let canary = "sk-ant-oat01-CANARY-SECRET-TOKEN-9999"
        let claude = ClaudeOAuthCredentials(accessToken: canary, expiresAt: nil, subscriptionType: "max", rateLimitTier: nil)
        let codex = CodexOAuthCredentials(accessToken: canary, refreshToken: canary, idToken: canary, accountId: "acct", accountEmail: "canary@example.com", expiresAt: nil, lastRefresh: nil, planType: "pro")

        for output in [String(describing: claude), String(reflecting: claude), String(describing: codex), String(reflecting: codex)] {
            XCTAssertFalse(output.contains(canary))
            XCTAssertTrue(output.contains("[REDACTED]"))
        }
    }

    func testF18_02_decodingAndNetworkFailureMessagesDoNotEchoTokensOrAuthJSON() async {
        let secret = "eyJhbGciOiJSUzI1NiJ9.CANARY_PAYLOAD.CANARY_SIG"
        let provider = CodexUsageProvider(
            credentialReader: E2ESpyCodexCredentialReader(result: .success(CodexOAuthCredentials(accessToken: secret, refreshToken: secret, idToken: secret, accountId: nil, accountEmail: nil, expiresAt: nil, lastRefresh: nil, planType: nil))),
            transport: E2ERecordingHTTPTransport(scriptedQueue: [
                .success((Data("{\"error\":\"invalid token \(secret)\"}".utf8), E2ERecordingHTTPTransport.makeResponse(url: CodexUsageProvider.defaultEndpointURL, statusCode: 200)))
            ])
        )
        let result = await provider.fetchQuota(now: Date())
        guard case .failure(.decodingFailure(let msg)) = result else {
            return XCTFail("Expected decodingFailure")
        }
        XCTAssertFalse(msg.contains(secret))
    }

    func testF18_03_httpClientConfigNeverAcceptsOrPersistsSetCookie() {
        let client = AIUsageHTTPClient()
        let session = Mirror(reflecting: client).descendant("session") as? URLSession
        XCTAssertNil(session?.configuration.httpCookieStorage)
        XCTAssertEqual(session?.configuration.httpShouldSetCookies, false)
    }

    func testF18_04_zeroFileManagerWriteCallsInAIProviders() throws {
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Providers/AIUsage")
        let writeAPIs = ["createFile", "createDirectory", "removeItem", "moveItem", "copyItem", ".write("]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for api in writeAPIs {
                XCTAssertFalse(text.contains(api), "Found write API \(api) in \(file.lastPathComponent)")
            }
        }
    }

    func testF18_05_onlyReadOnlySecItemCopyMatchingInAIProviders() throws {
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Providers/AIUsage")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("SecItemAdd"))
            XCTAssertFalse(text.contains("SecItemUpdate"))
            XCTAssertFalse(text.contains("SecItemDelete"))
        }
    }

    // MARK: - F19 Boundary Cases (5)

    func testF19_01_projectYmlPinsCodexBarRevisionWithZeroCocoaPods() throws {
        let yml = try String(contentsOf: E2ERepoInspector.repoRootURL().appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("CodexBarCore"))
        XCTAssertTrue(yml.contains("revision:"))
        XCTAssertFalse(yml.contains("pod "))
    }

    func testF19_02_lynxBarTargetEnforcesMacOS14DeploymentTarget() throws {
        let yml = try String(contentsOf: E2ERepoInspector.repoRootURL().appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains(#"deploymentTarget: "14.0""#))
    }

    func testF19_03_zeroNonisolatedUnsafeEscapesInAIFiles() throws {
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Providers/AIUsage")
            + E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Modules/AIUsage")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("nonisolated(unsafe)"), "Found nonisolated(unsafe) in \(file.lastPathComponent)")
        }
    }

    func testF19_04_zeroBlockingSleepOrSemaphoreOnMainActorInAIModule() throws {
        let files = try E2ERepoInspector.swiftSourceFiles(under: "Sources/LynxBar/Modules/AIUsage")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("DispatchSemaphore"))
            XCTAssertFalse(text.contains("Thread.sleep"))
            XCTAssertFalse(text.contains("usleep("))
        }
    }

    func testF19_05_aiUsageViewModelContainsZeroUncheckedSendable() throws {
        let vmText = try String(contentsOf: E2ERepoInspector.repoRootURL().appendingPathComponent("Sources/LynxBar/Modules/AIUsage/AIUsageViewModel.swift"), encoding: .utf8)
        XCTAssertFalse(vmText.contains("@unchecked Sendable"))
    }

    // MARK: - F20 Boundary Cases (5)

    func testF20_01_themeAndV2ComponentsRetainPhase1And2Tokens() throws {
        let root = E2ERepoInspector.repoRootURL()
        let theme = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Kit/Theme.swift"), encoding: .utf8)
        let v2 = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Kit/V2Components.swift"), encoding: .utf8)
        XCTAssertTrue(theme.contains("nsPanelBackdropTint"))
        XCTAssertTrue(theme.contains("nsCardFill"))
        XCTAssertTrue(v2.contains("VisualEffectBackdrop"))
        XCTAssertTrue(v2.contains("LynxSegmentedPill"))
    }

    func testF20_02_diskAndMemoryPanelsRetainPhase1And2UXEdits() throws {
        let root = E2ERepoInspector.repoRootURL()
        let disk = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Modules/Disk/DiskPanelView.swift"), encoding: .utf8)
        let mem = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Modules/Memory/MemoryPanelView.swift"), encoding: .utf8)
        XCTAssertTrue(disk.contains("Sampling schedule"))
        XCTAssertTrue(mem.contains("High swap"))
        XCTAssertTrue(mem.contains("Elevated"))
    }

    func testF20_03_dashboardOverviewAndPanelHostRetainGlassEdits() throws {
        let root = E2ERepoInspector.repoRootURL()
        let host = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Kit/PanelHost.swift"), encoding: .utf8)
        let overview = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Modules/Dashboard/OverviewView.swift"), encoding: .utf8)
        let dashboard = try String(contentsOf: root.appendingPathComponent("Sources/LynxBar/Modules/Dashboard/DashboardView.swift"), encoding: .utf8)

        XCTAssertTrue(host.contains("PanelHost") || host.contains("NSPanel"))
        XCTAssertTrue(overview.contains("OverviewLayoutMetrics"))
        XCTAssertTrue(dashboard.contains("VisualEffectBackdrop") || dashboard.contains("DashboardHeader"))
    }

    func testF20_04_bilingualHighSwapAndElevatedStringsPresent() {
        XCTAssertEqual(E2ERepoInspector.localizedString("High swap", localeIdentifier: "en"), "High swap")
        XCTAssertEqual(E2ERepoInspector.localizedString("Elevated", localeIdentifier: "en"), "Elevated")
        XCTAssertEqual(E2ERepoInspector.localizedString("High swap", localeIdentifier: "zh-Hans"), "交换空间偏高")
        XCTAssertEqual(E2ERepoInspector.localizedString("Elevated", localeIdentifier: "zh-Hans"), "轻度升高")
    }

    func testF20_05_aiUsagePanelViewHasZeroLegacyProgressOrBorderedProminent() throws {
        let panel = try String(contentsOf: E2ERepoInspector.repoRootURL().appendingPathComponent("Sources/LynxBar/Modules/AIUsage/AIUsagePanelView.swift"), encoding: .utf8)
        XCTAssertFalse(panel.contains("ProgressView(value:"))
        XCTAssertFalse(panel.contains(".borderedProminent"))
    }
}
