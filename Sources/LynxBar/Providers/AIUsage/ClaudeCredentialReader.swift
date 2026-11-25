import Foundation
import Security

/// Outcome of a read-only macOS Keychain lookup for Claude Code credentials.
enum ClaudeKeychainReadOutcome: Equatable, Sendable {
    case data(Data)
    case notFound
    case accessDenied(OSStatus)
    case error(OSStatus)
}

/// Abstraction for reading local Claude Code OAuth credentials without touching Keychain or disk in tests.
protocol ClaudeCredentialReading: Sendable {
    /// Reads and validates local Claude Code OAuth credentials against `now`.
    func readCredentials(now: Date) -> Result<ClaudeOAuthCredentials, AIUsageFetchError>
}

/// Strictly read-only credential reader for local Claude Code OAuth tokens.
/// Checks macOS Keychain (`Claude Code-credentials`) first, skipping MCP-only payloads without
/// `claudeAiOauth.accessToken`, then falls back to `~/.claude/.credentials.json`.
struct ClaudeCredentialReader: ClaudeCredentialReading, Sendable {
    static let keychainServiceName = "Claude Code-credentials"
    static let defaultExpirySafetyMargin: TimeInterval = 30

    private let keychainReader: @Sendable () -> ClaudeKeychainReadOutcome
    private let fileReader: @Sendable () -> Data?
    private let expirySafetyMargin: TimeInterval

    /// Creates a read-only credential reader with injectable Keychain, file, and expiry margin dependencies.
    init(
        keychainReader: @escaping @Sendable () -> ClaudeKeychainReadOutcome = ClaudeCredentialReader.readSystemKeychain,
        fileReader: @escaping @Sendable () -> Data? = ClaudeCredentialReader.readDefaultCredentialsFile,
        expirySafetyMargin: TimeInterval = ClaudeCredentialReader.defaultExpirySafetyMargin
    ) {
        self.keychainReader = keychainReader
        self.fileReader = fileReader
        self.expirySafetyMargin = expirySafetyMargin
    }

    /// Reads local credentials in deterministic order: Keychain first, then `~/.claude/.credentials.json`.
    /// Pre-validates `expiresAt` with `expirySafetyMargin` so guaranteed-401 tokens fail locally.
    func readCredentials(now: Date = Date()) -> Result<ClaudeOAuthCredentials, AIUsageFetchError> {
        var keychainAccessDenied = false
        var keychainMalformed = false

        switch keychainReader() {
        case .data(let data):
            switch parsePayload(from: data) {
            case .valid(let credentials):
                return validateExpiry(credentials, now: now)
            case .missingOAuth:
                // Keychain item exists (e.g. MCP-only OAuth entry) without `claudeAiOauth.accessToken`;
                // treat as a primary-credential miss and fall through to `~/.claude/.credentials.json`.
                Log.aiUsage.debug("Keychain entry lacks claudeAiOauth.accessToken; checking credentials file fallback")
            case .malformed:
                keychainMalformed = true
                Log.aiUsage.warning("Malformed Claude Code credential payload in Keychain; checking file fallback")
            }

        case .notFound:
            break

        case .accessDenied(let status):
            keychainAccessDenied = true
            Log.aiUsage.notice("Keychain credential read declined or unavailable (status: \(status, privacy: .public))")

        case .error(let status):
            Log.aiUsage.notice("Keychain credential lookup failed (status: \(status, privacy: .public))")
        }

        if let fileData = fileReader() {
            switch parsePayload(from: fileData) {
            case .valid(let credentials):
                return validateExpiry(credentials, now: now)
            case .missingOAuth:
                if keychainAccessDenied { return .failure(.unauthorized) }
                if keychainMalformed { return .failure(.credentialsMalformed) }
                return .failure(.credentialsMissing)
            case .malformed:
                return .failure(.credentialsMalformed)
            }
        }

        if keychainAccessDenied {
            return .failure(.unauthorized)
        }
        if keychainMalformed {
            return .failure(.credentialsMalformed)
        }
        return .failure(.credentialsMissing)
    }

    /// Queries the macOS Keychain read-only for `"Claude Code-credentials"`.
    static func readSystemKeychain() -> ClaudeKeychainReadOutcome {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return .error(errSecDecode)
            }
            return .data(data)
        case errSecItemNotFound:
            return .notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .accessDenied(status)
        default:
            return .error(status)
        }
    }

    /// Reads `~/.claude/.credentials.json` strictly read-only if present.
    static func readDefaultCredentialsFile() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json", isDirectory: false)
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            Log.aiUsage.notice(
                "Unable to read Claude credentials file at \(url.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    /// Parses a numeric Unix timestamp in either milliseconds or seconds into a `Date`.
    static func parseExpiresAt(_ rawValue: Double?) -> Date? {
        guard let rawValue, rawValue.isFinite, rawValue > 0 else { return nil }
        // Unix epoch seconds will not reach 1e11 until year ~5138; epoch ms exceeded 1e12 in 2001.
        let seconds = rawValue >= 100_000_000_000 ? rawValue / 1_000.0 : rawValue
        return Date(timeIntervalSince1970: seconds)
    }

    /// Checks whether parsed credentials are expired or within the pre-flight safety margin.
    private func validateExpiry(
        _ credentials: ClaudeOAuthCredentials,
        now: Date
    ) -> Result<ClaudeOAuthCredentials, AIUsageFetchError> {
        if let expiresAt = credentials.expiresAt,
           expiresAt.timeIntervalSince(now) <= expirySafetyMargin {
            Log.aiUsage.info("Claude OAuth token is expired or within the expiry safety margin")
            return .failure(.tokenExpired)
        }
        return .success(credentials)
    }

    /// Classification of a decoded Keychain or file credential payload.
    private enum ParsedPayloadOutcome {
        case valid(ClaudeOAuthCredentials)
        case missingOAuth
        case malformed
    }

    /// Decodes credential JSON without ever logging raw payload data or tokens.
    private func parsePayload(from data: Data) -> ParsedPayloadOutcome {
        guard !data.isEmpty else { return .missingOAuth }
        let decoded: CredentialsFilePayload
        do {
            decoded = try JSONDecoder().decode(CredentialsFilePayload.self, from: data)
        } catch {
            return .malformed
        }

        guard let oauth = decoded.claudeAiOauth,
              let token = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return .missingOAuth
        }

        let expiresAt = oauth.expiresAt?.resolvedDate
        let credentials = ClaudeOAuthCredentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth.subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            rateLimitTier: oauth.rateLimitTier?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        return .valid(credentials)
    }
}

/// Top-level JSON structure stored by Claude Code in Keychain or `~/.claude/.credentials.json`.
private struct CredentialsFilePayload: Decodable {
    let claudeAiOauth: OAuthPayload?

    /// Nested `claudeAiOauth` object containing the bearer token and metadata.
    struct OAuthPayload: Decodable {
        let accessToken: String?
        let expiresAt: FlexibleTimestamp?
        let subscriptionType: String?
        let rateLimitTier: String?
    }
}

/// Decodable timestamp accepting Unix epoch numbers (seconds/milliseconds) or ISO-8601 strings.
private enum FlexibleTimestamp: Decodable {
    case number(Double)
    case string(String)

    /// Decodes either a floating-point/integer Unix timestamp or a timestamp string.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let numeric = try? container.decode(Double.self) {
            self = .number(numeric)
            return
        }
        if let integer = try? container.decode(Int64.self) {
            self = .number(Double(integer))
            return
        }
        if let text = try? container.decode(String.self) {
            self = .string(text)
            return
        }
        throw DecodingError.typeMismatch(
            FlexibleTimestamp.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected numeric or ISO-8601 string timestamp")
        )
    }

    /// Converts the decoded numeric or string timestamp into a `Date`, if valid.
    var resolvedDate: Date? {
        switch self {
        case .number(let value):
            return ClaudeCredentialReader.parseExpiresAt(value)
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let numeric = Double(trimmed) {
                return ClaudeCredentialReader.parseExpiresAt(numeric)
            }
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed) {
                return date
            }
            return try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(trimmed)
        }
    }
}

private extension String {
    /// Returns `nil` when the string is empty, otherwise returns `self`.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
