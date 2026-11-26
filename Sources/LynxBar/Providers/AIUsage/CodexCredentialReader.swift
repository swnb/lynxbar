import Foundation

/// Read-only OAuth credentials extracted from local OpenAI Codex CLI storage (`auth.json`).
/// Redacts all sensitive tokens in `description` and `debugDescription`.
struct CodexOAuthCredentials: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Bearer OAuth access token used for Codex usage requests.
    let accessToken: String
    /// Local OAuth refresh token, never redeemed or persisted by LynxBar.
    let refreshToken: String?
    /// Optional OpenID Connect ID token containing non-secret account claims.
    let idToken: String?
    /// ChatGPT workspace/account identifier sent in `ChatGPT-Account-Id` when non-empty.
    let accountId: String?
    /// Non-secret user email extracted from JWT claims, if available.
    let accountEmail: String?
    /// Expiration timestamp extracted from `accessToken` JWT `exp` claim, if present.
    let expiresAt: Date?
    /// Last refresh timestamp recorded in `auth.json`.
    let lastRefresh: Date?
    /// Raw subscription plan type extracted from JWT auth claims, if present.
    let planType: String?

    /// Convenience alias for the account label displayed in snapshots.
    var accountLabel: String? { accountEmail }

    /// Redacted textual description that never exposes secret tokens or email PII.
    var description: String {
        let refreshDisplay = refreshToken == nil ? "nil" : "[REDACTED]"
        let idDisplay = idToken == nil ? "nil" : "[REDACTED]"
        let emailDisplay = accountEmail == nil ? "nil" : "[REDACTED]"
        return "CodexOAuthCredentials(accessToken: [REDACTED], refreshToken: \(refreshDisplay), idToken: \(idDisplay), accountId: \(accountId ?? "nil"), accountEmail: \(emailDisplay), expiresAt: \(String(describing: expiresAt)), lastRefresh: \(String(describing: lastRefresh)), planType: \(planType ?? "nil"))"
    }

    /// Redacted debug description delegating to `description`.
    var debugDescription: String {
        description
    }
}

/// Abstraction for reading local Codex OAuth credentials without touching disk in unit tests.
protocol CodexCredentialReading: Sendable {
    /// Reads and validates local Codex OAuth credentials against `now`.
    func readCredentials(now: Date) -> Result<CodexOAuthCredentials, AIUsageFetchError>
}

/// Strictly read-only credential reader for local OpenAI Codex CLI OAuth tokens.
/// Resolves `$CODEX_HOME/auth.json` when `CODEX_HOME` is non-empty, otherwise `~/.codex/auth.json`.
struct CodexCredentialReader: CodexCredentialReading, Sendable {
    static let defaultExpirySafetyMargin: TimeInterval = 30
    static let defaultMaxRefreshAge: TimeInterval = 8 * 86_400

    private let environment: [String: String]
    private let homeDirectory: URL
    private let fileReader: @Sendable (URL) -> Data?
    private let expirySafetyMargin: TimeInterval
    private let maxRefreshAge: TimeInterval

    /// Creates a read-only Codex credential reader with injectable environment, home directory, and file reader.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileReader: @escaping @Sendable (URL) -> Data? = CodexCredentialReader.readFile(at:),
        expirySafetyMargin: TimeInterval = CodexCredentialReader.defaultExpirySafetyMargin,
        maxRefreshAge: TimeInterval = CodexCredentialReader.defaultMaxRefreshAge
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileReader = fileReader
        self.expirySafetyMargin = expirySafetyMargin
        self.maxRefreshAge = maxRefreshAge
    }

    /// Resolves the Codex `auth.json` file URL using `$CODEX_HOME` or `~/.codex/auth.json`.
    static func resolveAuthFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let codexHome = AIUsageParsing.nonEmptyTrimmed(environment["CODEX_HOME"]) {
            let expanded = (codexHome as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent("auth.json", isDirectory: false)
        }
        return homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    /// Reads `url` strictly read-only, returning `nil` when the file does not exist or cannot be read.
    static func readFile(at url: URL) -> Data? {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            Log.aiUsage.notice(
                "Unable to read Codex credentials file at \(url.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    /// Reads and pre-validates Codex OAuth credentials against `now` without performing token refresh.
    func readCredentials(now: Date = Date()) -> Result<CodexOAuthCredentials, AIUsageFetchError> {
        let authURL = Self.resolveAuthFileURL(environment: environment, homeDirectory: homeDirectory)
        guard let data = fileReader(authURL) else {
            return .failure(.credentialsMissing)
        }

        let payload: CodexAuthFilePayload
        do {
            payload = try JSONDecoder().decode(CodexAuthFilePayload.self, from: data)
        } catch {
            Log.aiUsage.warning(
                "Malformed Codex credentials JSON at \(authURL.path, privacy: .private)"
            )
            return .failure(.credentialsMalformed)
        }

        guard let accessToken = AIUsageParsing.nonEmptyTrimmed(payload.tokens?.accessToken) else {
            if AIUsageParsing.nonEmptyTrimmed(payload.openAIAPIKey) != nil {
                Log.aiUsage.info("Codex auth.json is configured with API key only; subscription OAuth quota unavailable")
            }
            return .failure(.credentialsMissing)
        }

        let refreshToken = AIUsageParsing.nonEmptyTrimmed(payload.tokens?.refreshToken)
        let idToken = AIUsageParsing.nonEmptyTrimmed(payload.tokens?.idToken)

        let idClaims = idToken.flatMap { AIUsageJWTDecoder.decodePayload(CodexJWTClaims.self, from: $0) }
        let accessClaims = AIUsageJWTDecoder.decodePayload(CodexJWTClaims.self, from: accessToken)

        let accountEmail = AIUsageParsing.nonEmptyTrimmed(idClaims?.email)
            ?? AIUsageParsing.nonEmptyTrimmed(accessClaims?.email)
            ?? AIUsageParsing.nonEmptyTrimmed(idClaims?.profile?.email)
            ?? AIUsageParsing.nonEmptyTrimmed(accessClaims?.profile?.email)

        let accountId = AIUsageParsing.nonEmptyTrimmed(payload.tokens?.accountId)
            ?? AIUsageParsing.nonEmptyTrimmed(idClaims?.auth?.chatgptAccountId)
            ?? AIUsageParsing.nonEmptyTrimmed(accessClaims?.auth?.chatgptAccountId)

        let planType = AIUsageParsing.nonEmptyTrimmed(idClaims?.auth?.chatgptPlanType)
            ?? AIUsageParsing.nonEmptyTrimmed(accessClaims?.auth?.chatgptPlanType)

        let expiresAt = accessClaims?.exp?.resolvedExpiryDate
        let lastRefresh = payload.lastRefresh?.resolvedDate

        if let expiresAt {
            if expiresAt.timeIntervalSince(now) <= expirySafetyMargin {
                Log.aiUsage.info("Codex OAuth access token is expired or within expiry safety margin")
                return .failure(.tokenExpired)
            }
        } else if let lastRefresh {
            if now.timeIntervalSince(lastRefresh) >= maxRefreshAge {
                Log.aiUsage.info("Codex OAuth session exceeded maximum refresh age without JWT expiry")
                return .failure(.tokenExpired)
            }
        }

        let credentials = CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: accountId,
            accountEmail: accountEmail,
            expiresAt: expiresAt,
            lastRefresh: lastRefresh,
            planType: planType
        )
        return .success(credentials)
    }
}

/// Top-level JSON schema stored by OpenAI Codex CLI in `auth.json`.
private struct CodexAuthFilePayload: Decodable {
    let openAIAPIKey: String?
    let tokens: TokensPayload?
    let lastRefresh: AIUsageFlexibleTimestamp?

    enum CodingKeys: String, CodingKey {
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }

    /// Nested OAuth token container inside `auth.json`.
    struct TokensPayload: Decodable {
        let idToken: String?
        let accessToken: String?
        let refreshToken: String?
        let accountId: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case accountId = "account_id"
        }
    }
}

/// Subset of non-secret JWT claims parsed from Codex OAuth `access_token` or `id_token`.
private struct CodexJWTClaims: Decodable {
    let email: String?
    let exp: AIUsageFlexibleTimestamp?
    let auth: OpenAIAuthClaim?
    let profile: OpenAIProfileClaim?

    enum CodingKeys: String, CodingKey {
        case email
        case exp
        case auth = "https://api.openai.com/auth"
        case profile = "https://api.openai.com/profile"
    }

    /// OpenAI auth claim container holding workspace and subscription tier metadata.
    struct OpenAIAuthClaim: Decodable {
        let chatgptAccountId: String?
        let chatgptPlanType: String?

        enum CodingKeys: String, CodingKey {
            case chatgptAccountId = "chatgpt_account_id"
            case chatgptPlanType = "chatgpt_plan_type"
        }
    }

    /// OpenAI profile claim container holding user email if omitted at top level.
    struct OpenAIProfileClaim: Decodable {
        let email: String?
    }
}
