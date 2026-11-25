import Foundation
import os
import Security
import XCTest
@testable import LynxBar

/// Offline unit tests for `ClaudeCredentialReader` covering Keychain parsing,
/// MCP-only miss fallback, file fallback, error taxonomy, and 30s expiry validation.
final class ClaudeCredentialReaderTests: XCTestCase {
    private let baseNow = Date(timeIntervalSince1970: 1_750_000_000)

    /// Verifies that valid Keychain JSON extracts `accessToken`, millisecond `expiresAt`,
    /// `subscriptionType`, and `rateLimitTier` without consulting the file fallback,
    /// and that credential descriptions redact the OAuth token.
    func testKeychainValidJSONParsesCredentialsAndRedactsDescription() {
        let futureMs = Int64((baseNow.timeIntervalSince1970 + 3_600) * 1_000)
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-secret-token-value",
            "expiresAt": \(futureMs),
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_5x"
          }
        }
        """
        let fileCallCount = OSAllocatedUnfairLock(initialState: 0)
        let reader = ClaudeCredentialReader(
            keychainReader: { .data(Data(json.utf8)) },
            fileReader: {
                fileCallCount.withLock { $0 += 1 }
                return nil
            }
        )

        let result = reader.readCredentials(now: baseNow)
        guard case .success(let credentials) = result else {
            return XCTFail("Expected success, got \(result)")
        }

        XCTAssertEqual(credentials.accessToken, "sk-ant-oat01-secret-token-value")
        XCTAssertEqual(credentials.subscriptionType, "max")
        XCTAssertEqual(credentials.rateLimitTier, "default_claude_max_5x")
        XCTAssertEqual(
            credentials.expiresAt?.timeIntervalSince1970 ?? 0,
            Double(futureMs) / 1_000.0,
            accuracy: 0.001
        )
        XCTAssertEqual(fileCallCount.withLock { $0 }, 0)
        XCTAssertFalse(credentials.description.contains("sk-ant-oat01-secret-token-value"))
        XCTAssertFalse(credentials.debugDescription.contains("sk-ant-oat01-secret-token-value"))
        XCTAssertTrue(credentials.description.contains("[REDACTED]"))
    }

    /// Verifies that a Keychain entry containing only MCP OAuth fields (missing `claudeAiOauth.accessToken`)
    /// is treated as a miss and falls back to `~/.claude/.credentials.json`.
    func testMCPOnlyKeychainEntryFallsBackToCredentialsFile() {
        let mcpOnlyJSON = """
        {
          "mcpOAuth": {
            "linear|123": {
              "accessToken": "mcp-only-token"
            }
          }
        }
        """
        let futureSec = Int64(baseNow.timeIntervalSince1970 + 1_800)
        let fileJSON = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-fallback-token",
            "expiresAt": \(futureSec),
            "subscriptionType": "pro"
          }
        }
        """
        let reader = ClaudeCredentialReader(
            keychainReader: { .data(Data(mcpOnlyJSON.utf8)) },
            fileReader: { Data(fileJSON.utf8) }
        )

        let result = reader.readCredentials(now: baseNow)
        XCTAssertEqual(
            result,
            .success(
                ClaudeOAuthCredentials(
                    accessToken: "sk-ant-fallback-token",
                    expiresAt: Date(timeIntervalSince1970: TimeInterval(futureSec)),
                    subscriptionType: "pro",
                    rateLimitTier: nil
                )
            )
        )
    }

    /// Verifies that `errSecItemNotFound` falls back to the credentials file reader.
    func testKeychainNotFoundFallsBackToCredentialsFile() {
        let futureSec = Int64(baseNow.timeIntervalSince1970 + 600)
        let fileJSON = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-file-only-token",
            "expiresAt": \(futureSec)
          }
        }
        """
        let reader = ClaudeCredentialReader(
            keychainReader: { .notFound },
            fileReader: { Data(fileJSON.utf8) }
        )

        let result = reader.readCredentials(now: baseNow)
        guard case .success(let credentials) = result else {
            return XCTFail("Expected success from file fallback, got \(result)")
        }
        XCTAssertEqual(credentials.accessToken, "sk-ant-file-only-token")
    }

    /// Verifies that Keychain auth failures (`errSecAuthFailed` / `errSecUserCanceled`) check the file
    /// fallback once and return `.unauthorized` without re-prompting when the file is absent.
    func testKeychainAccessDeniedTriesFileFallbackOnceAndReturnsUnauthorizedWhenAbsent() {
        for status in [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed] {
            let keychainCalls = OSAllocatedUnfairLock(initialState: 0)
            let fileCalls = OSAllocatedUnfairLock(initialState: 0)
            let reader = ClaudeCredentialReader(
                keychainReader: {
                    keychainCalls.withLock { $0 += 1 }
                    return .accessDenied(status)
                },
                fileReader: {
                    fileCalls.withLock { $0 += 1 }
                    return nil
                }
            )

            XCTAssertEqual(reader.readCredentials(now: baseNow), .failure(.unauthorized))
            XCTAssertEqual(keychainCalls.withLock { $0 }, 1)
            XCTAssertEqual(fileCalls.withLock { $0 }, 1)
        }
    }

    /// Verifies that valid file credentials still succeed when Keychain access is denied.
    func testKeychainAccessDeniedSucceedsWhenFileFallbackHasValidToken() {
        let futureSec = Int64(baseNow.timeIntervalSince1970 + 900)
        let fileJSON = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-file-rescue",
            "expiresAt": \(futureSec)
          }
        }
        """
        let reader = ClaudeCredentialReader(
            keychainReader: { .accessDenied(errSecUserCanceled) },
            fileReader: { Data(fileJSON.utf8) }
        )

        guard case .success(let credentials) = reader.readCredentials(now: baseNow) else {
            return XCTFail("Expected file fallback to succeed")
        }
        XCTAssertEqual(credentials.accessToken, "sk-ant-file-rescue")
    }

    /// Verifies `.credentialsMissing` vs `.credentialsMalformed` across absent, empty, and broken JSON inputs.
    func testMissingAndMalformedCredentialPayloads() {
        let missingReader = ClaudeCredentialReader(
            keychainReader: { .notFound },
            fileReader: { nil }
        )
        XCTAssertEqual(missingReader.readCredentials(now: baseNow), .failure(.credentialsMissing))

        let emptyOAuthReader = ClaudeCredentialReader(
            keychainReader: { .data(Data("{\"claudeAiOauth\":{\"accessToken\":\"   \"}}".utf8)) },
            fileReader: { Data("{}".utf8) }
        )
        XCTAssertEqual(emptyOAuthReader.readCredentials(now: baseNow), .failure(.credentialsMissing))

        let malformedKeychainReader = ClaudeCredentialReader(
            keychainReader: { .data(Data("{not-json".utf8)) },
            fileReader: { nil }
        )
        XCTAssertEqual(malformedKeychainReader.readCredentials(now: baseNow), .failure(.credentialsMalformed))

        let malformedFileReader = ClaudeCredentialReader(
            keychainReader: { .notFound },
            fileReader: { Data("[broken".utf8) }
        )
        XCTAssertEqual(malformedFileReader.readCredentials(now: baseNow), .failure(.credentialsMalformed))
    }

    /// Verifies expiry pre-check at the 30-second safety margin boundary across millisecond,
    /// second, and ISO-8601 `expiresAt` formats.
    func testExpiryPreCheckWith30SecondSafetyMarginAcrossTimestampFormats() {
        let atBoundarySec = Int64(baseNow.timeIntervalSince1970 + 30)
        let beyondBoundarySec = Int64(baseNow.timeIntervalSince1970 + 31)
        let atBoundaryMs = atBoundarySec * 1_000
        let beyondBoundaryMs = beyondBoundarySec * 1_000

        let expiredSecReader = makeReader(expiresAtJSON: "\(atBoundarySec)")
        XCTAssertEqual(expiredSecReader.readCredentials(now: baseNow), .failure(.tokenExpired))

        let validSecReader = makeReader(expiresAtJSON: "\(beyondBoundarySec)")
        guard case .success = validSecReader.readCredentials(now: baseNow) else {
            return XCTFail("Expected token at now + 31s (seconds) to be valid")
        }

        let expiredMsReader = makeReader(expiresAtJSON: "\(atBoundaryMs)")
        XCTAssertEqual(expiredMsReader.readCredentials(now: baseNow), .failure(.tokenExpired))

        let validMsReader = makeReader(expiresAtJSON: "\(beyondBoundaryMs)")
        guard case .success = validMsReader.readCredentials(now: baseNow) else {
            return XCTFail("Expected token at now + 31s (milliseconds) to be valid")
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiredISO = isoFormatter.string(from: baseNow.addingTimeInterval(30))
        let validISO = isoFormatter.string(from: baseNow.addingTimeInterval(31))

        XCTAssertEqual(makeReader(expiresAtJSON: "\"\(expiredISO)\"").readCredentials(now: baseNow), .failure(.tokenExpired))
        guard case .success = makeReader(expiresAtJSON: "\"\(validISO)\"").readCredentials(now: baseNow) else {
            return XCTFail("Expected token at now + 31s (ISO-8601) to be valid")
        }
    }

    private func makeReader(expiresAtJSON: String) -> ClaudeCredentialReader {
        let payload = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-boundary-token",
            "expiresAt": \(expiresAtJSON)
          }
        }
        """
        return ClaudeCredentialReader(
            keychainReader: { .data(Data(payload.utf8)) },
            fileReader: { nil }
        )
    }
}
