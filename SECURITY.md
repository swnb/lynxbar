# Security Policy

## Supported Versions

| Version | Supported |
| --- | --- |
| `0.1.x` | Yes |

---

## Reporting a Vulnerability

If you discover a security or privacy vulnerability in **LynxBar** (such as accidental credential exposure, privilege boundary bypass, or unsafe file deletion):

- **Do not** open a public GitHub issue with exploit details, OAuth tokens, Keychain payloads, or personal system logs.
- Report privately via **GitHub Security Advisories** on [`github.com/swnb/lynxbar/security/advisories`](https://github.com/swnb/lynxbar/security/advisories).
- Include the affected LynxBar version, macOS version, reproduction steps, and expected vs. actual behavior.

We will acknowledge reports as quickly as possible and coordinate a fix before public disclosure.

---

## Security & Privacy Architecture

### 1. Read-Only Keychain & Local CLI Credential Boundary
When any opt-in **AI subscription quota** provider (`claudeUsageEnabled`, `codexUsageEnabled`, or `geminiUsageEnabled`) is enabled by the user:
- **Claude** (`ClaudeCredentialReader` in `Sources/LynxBar/Providers/AIUsage/ClaudeCredentialReader.swift`): queries macOS Keychain via `SecItemCopyMatching` (`kSecClassGenericPassword`, `kSecAttrService = "Claude Code-credentials"`, `kSecReturnData: true`) in **strictly read-only** mode, skipping MCP-only Keychain items lacking `claudeAiOauth.accessToken`, and falls back to read-only `~/.claude/.credentials.json` if needed. If Keychain access is denied (`errSecAuthFailed` / `errSecUserCanceled` / `errSecInteractionNotAllowed`) and no valid file token exists, automatic retries stop immediately.
- **OpenAI Codex** (`CodexCredentialReader` in `Sources/LynxBar/Providers/AIUsage/CodexCredentialReader.swift`): reads `$CODEX_HOME/auth.json` or `~/.codex/auth.json` **strictly read-only**, pre-checking JWT `exp` / `last_refresh` locally without ever redeeming `refresh_token`.
- **Gemini** (`GeminiCredentialReader` in `Sources/LynxBar/Providers/AIUsage/GeminiCredentialReader.swift`): reads `~/.gemini/settings.json` (confirming `oauth-personal` or unset auth type) and `~/.gemini/oauth_creds.json` **strictly read-only**, pre-checking `expiry_date` locally without ever refreshing tokens.
- LynxBar **never** writes to Keychain, `~/.claude/`, `~/.codex/`, or `~/.gemini/`, **never** reads browser cookies, **never** stores plaintext passwords, and **never** silently launches browsers or CLI commands.

### 2. Zero Telemetry & Secret-Redacting Logging
- LynxBar collects **zero** telemetry, analytics, or crash reports.
- Diagnostic logs use Apple's unified logging (`os.Logger`, subsystem `com.swnb.LynxBar` in `Sources/LynxBar/Kit/Log.swift`).
- OAuth tokens, `Authorization` headers, raw Keychain JSON, and HTTP response bodies are strictly forbidden at every log level.
- IP addresses, file system paths, usernames, and OS error descriptions are marked `.private` or omitted.
- `ClaudeOAuthCredentials`, `CodexOAuthCredentials`, and `GeminiOAuthCredentials` implement redacted `description` and `debugDescription` strings (`accessToken: [REDACTED]`, `refreshToken: [REDACTED]`, `idToken: [REDACTED]`).

### 3. Opt-In Outbound Network Calls
By default, LynxBar makes **zero** outbound network requests:
- `Settings.showPublicIP` defaults to `false`. When enabled, it queries `api.ipify.org`, `ifconfig.me/ip`, or `icanhazip.com` over HTTPS at most once every 10 minutes.
- Per-provider AI toggles (`Settings.claudeUsageEnabled`, `Settings.codexUsageEnabled`, `Settings.geminiUsageEnabled`, and aggregate `Settings.aiUsageEnabled`) all default to `false`. When enabled, each active provider uses an ephemeral `URLSession` (`URLSessionConfiguration.ephemeral`, no persistent cookies or HTTP cache, 15s timeout) only while the AI tab, Overview, or an AI menu bar slot has active demand:
  - Claude → `https://api.anthropic.com/api/oauth/usage`
  - OpenAI Codex → `https://chatgpt.com/backend-api/wham/usage`
  - Gemini → `https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` & `:retrieveUserQuota`

### 4. Non-Sandboxed Entitlements Rationale
`Sources/LynxBar/Resources/LynxBar.entitlements` enables Hardened Runtime with:
- `com.apple.security.app-sandbox = false`
- `com.apple.security.network.client = true`

App Sandbox is disabled solely so `NetworkProcessProvider` can invoke `/usr/bin/nettop` for on-demand per-process network attribution and the read-only AI credential readers can inspect `~/.claude/.credentials.json`, `$CODEX_HOME/auth.json` (`~/.codex/auth.json`), and `~/.gemini/` without requesting persistent broad filesystem bookmarks.

### 5. Trash-Safe Disk Cleanup Guardrails
`DiskCleanup` (`LocalDiskReadAdapter`, `DiskScanPolicy`, `DiskCleanupExecutor`):
- Refuses volume roots, home root (`~`), `~/Library` and its descendants, symbolic links, `.app` bundles/packages, and non-local volumes.
- Excludes hidden files, cloud-only placeholders, and multi-hard-link files.
- Preselects zero items, revalidates root identity and per-file fingerprints immediately before execution, and moves items only to macOS **Trash** (never permanent deletion).
