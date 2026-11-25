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

### 1. Read-Only Keychain & Credential Boundary
When the opt-in **Claude subscription quota** feature is enabled by the user:
- `ClaudeCredentialReader` (`Sources/LynxBar/Providers/AIUsage/ClaudeCredentialReader.swift`) queries macOS Keychain via `SecItemCopyMatching` (`kSecClassGenericPassword`, `kSecAttrService = "Claude Code-credentials"`, `kSecReturnData: true`) in **strictly read-only** mode.
- MCP-only Keychain items lacking `claudeAiOauth.accessToken` are skipped cleanly without modifying Keychain state.
- If Keychain lookup returns no OAuth token or is declined, it checks `~/.claude/.credentials.json` read-only once; if Keychain access was denied (`errSecAuthFailed` / `errSecUserCanceled` / `errSecInteractionNotAllowed`) and no valid file token exists, it stops automatic retries immediately to avoid repeated system prompts.
- LynxBar **never** writes to Keychain or `~/.claude/`, **never** reads browser cookies, **never** stores plaintext passwords, and **never** silently launches browsers or CLI commands.

### 2. Zero Telemetry & Secret-Redacting Logging
- LynxBar collects **zero** telemetry, analytics, or crash reports.
- Diagnostic logs use Apple's unified logging (`os.Logger`, subsystem `com.swnb.LynxBar` in `Sources/LynxBar/Kit/Log.swift`).
- OAuth tokens, `Authorization` headers, raw Keychain JSON, and HTTP response bodies are strictly forbidden at every log level.
- IP addresses, file system paths, usernames, and OS error descriptions are marked `.private` or omitted.
- `ClaudeOAuthCredentials` implements redacted `description` and `debugDescription` strings (`accessToken: [REDACTED]`).

### 3. Opt-In Outbound Network Calls
By default, LynxBar makes **zero** outbound network requests:
- `Settings.showPublicIP` defaults to `false`. When enabled, it queries `api.ipify.org`, `ifconfig.me/ip`, or `icanhazip.com` over HTTPS at most once every 10 minutes.
- `Settings.aiUsageEnabled` defaults to `false`. When enabled, `ClaudeUsageProvider` sends requests to `https://api.anthropic.com/api/oauth/usage` using an ephemeral `URLSession` (`URLSessionConfiguration.ephemeral`, no persistent cookies or HTTP cache, 15s timeout) only while the AI tab, Overview, or an AI menu bar slot has active demand.

### 4. Non-Sandboxed Entitlements Rationale
`Sources/LynxBar/Resources/LynxBar.entitlements` enables Hardened Runtime with:
- `com.apple.security.app-sandbox = false`
- `com.apple.security.network.client = true`

App Sandbox is disabled solely so `NetworkProcessProvider` can invoke `/usr/bin/nettop` for on-demand per-process network attribution and `ClaudeCredentialReader` can perform its read-only fallback read of `~/.claude/.credentials.json` without requesting persistent broad filesystem bookmarks.

### 5. Trash-Safe Disk Cleanup Guardrails
`DiskCleanup` (`LocalDiskReadAdapter`, `DiskScanPolicy`, `DiskCleanupExecutor`):
- Refuses volume roots, home root (`~`), `~/Library` and its descendants, symbolic links, `.app` bundles/packages, and non-local volumes.
- Excludes hidden files, cloud-only placeholders, and multi-hard-link files.
- Preselects zero items, revalidates root identity and per-file fingerprints immediately before execution, and moves items only to macOS **Trash** (never permanent deletion).
