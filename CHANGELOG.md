# Changelog

All notable changes to **LynxBar** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-11-26

### Added
- **macOS Native Glass UI Refresh**: Upgraded the `420×600` panel with `VisualEffectBackdrop`, `0.5pt` hairlines, continuous corners, `V2Card(accentTint:)`, `LynxProgressBar`, `LynxSegmentedPill`, `LynxActionPillButton`, and gradient-filled live charts with glowing head markers.
- **Multi-Provider AI Subscription Quota (`Claude`, `OpenAI Codex`, `Antigravity`) powered by `CodexBarCore` (MIT)**:
  - Integrated `CodexBarCore` (`v0.85.0`, MIT) via SwiftPM with `CodexBarUsageProvider` (`cookieSource = .off`, `webExtrasEnabled = false`, `desktopCookiesEnabled = false`), replacing the sunset consumer Gemini CLI provider with **Antigravity** (`agy login` / local app & CLI probes) alongside **Claude** and **OpenAI Codex**.
  - Added independent opt-in toggles (`claudeUsageEnabled`, `codexUsageEnabled`, `antigravityUsageEnabled`, all defaulting to `false`) with isolated per-provider polling, cooldown, single-flight deduplication, `429` backoff, stale-while-error retention, `LoginShellPathCache` warmup, and persistent CLI session cleanup on app termination.
  - Upgraded `AIUsagePanelView` to simultaneous multi-card display with per-provider CLI login remediation (`claude /login`, `codex login`, `agy login`), extended `OverviewAIQuotaRow` (`36pt` height within the `420×600` budget), and updated `MenuBarStatusModel` / `MenuBarStatusPresenter` (`132pt` Focus / `300pt` Compact width budgets, `900s` TTL, bilingual VoiceOver announcements).
  - Updated `SettingsView` Privacy toggles and bilingual `en` / `zh-Hans` localization strings.
- **Overview Multi-Issue Switcher**: Added an inline `1/N ▸` pager pill in the Overview attention banner when multiple health issues are active so users can inspect and jump to any active issue directly.
- **Disk & Memory Product Polish**: Promoted safe Disk Cleanup CTA, added elevated/high Swap alerts in Memory, and unified card/bar visual alignment across Overview, Disk, Memory, and AI onboarding.

### Changed
- Raised minimum macOS deployment target from `macOS 13.0` to `macOS 14.0` to support `CodexBarCore`.
- Upgraded GitHub Actions CI & Release workflows to `macos-26` (Xcode 26) and migrated Swift Charts / SwiftUI modifiers to macOS 14 APIs (`plotFrame`, two-parameter `onChange`) to maintain a zero-warning build gate.

### Fixed
- Anchored `SystemHealthEvaluator`'s 30-second sustained CPU window to the latest fresh sample timestamp so wall-clock jitter between sampling ticks no longer causes the Overview attention card to flicker between CPU and Disk alerts.
- Fixed horizontal staircase misalignment in `AIUsagePanelView` onboarding rows and `SettingsView` toggle labels.
- Fixed `CodexBarUsageProvider` offline fallback snapshots to surface underlying live probe failures instead of generic decoding errors.

## [0.1.0] - 2026-11-25

Initial open-source release of **LynxBar** (`com.swnb.LynxBar`).

### Added
- **Brand & Bundle Identity**: Introduced the `LynxBar` application identity (`com.swnb.LynxBar`, `com.swnb.LynxBarTests`, `com.swnb.LynxBar.ProcessQAHelper`), `~/Library/Application Support/LynxBar/history-v3.plist` storage path, and `Assets.xcassets` (`AppIcon` and `MenuBarIcon`) scaffolding with SF Symbol fallbacks.
- **Structured Logging & Entitlements**: Added `Log` (`os.Logger` subsystem `com.swnb.LynxBar`) with secret-redaction rules across `try?`/`catch` paths, plus `LynxBar.entitlements` (Hardened Runtime, `network.client`).
- **Appearance Preferences**: Added `AppAppearanceMode` (`System` default, `Dark`, `Light`) in `SettingsView` and dynamic `NSApp.appearance` updates in `AppDelegate`.
- **Opt-In AI Subscription Quota Module (`AI Quota`)**:
  - Extensible `AIUsageProvider` protocol and data models (`AIUsageProviderID`, `AIQuotaWindow`, `AIExtraUsageSummary`, `AIProviderQuotaSnapshot`, `AIUsageFetchError`, `AIQuotaDisplayStyle`).
  - Read-only `ClaudeCredentialReader` (macOS Keychain `"Claude Code-credentials"` skipping MCP-only entries + `~/.claude/.credentials.json` fallback + expiry pre-check).
  - `ClaudeUsageProvider` (`actor`) querying `api.anthropic.com/api/oauth/usage` via an ephemeral `URLSession`.
  - Demand-driven `AIUsageViewModel` gated by `aiUsageEnabled = false` default, `MonitoringModule.aiUsage` (excluded from `overviewHealthModules`), 5-minute polling, 60-second cooldown, single-flight deduplication, `429` exponential backoff, and stale-while-error retention.
  - `AIUsagePanelView` (5-hour session, 7-day weekly, model breakdowns, extra usage, reset countdowns, `claude /login` remediation), `OverviewAIQuotaRow`, `MenuBarStatusSlot.aiUsage` (15-minute TTL), and `Remaining quota` / `Used quota` display toggle.
- **Header Settings Gear**: Moved Settings access to a dedicated gear button in `DashboardHeader`, freeing space in `BottomNavigation` for the `AI` tab (toggleable under `Visible destinations`).
- **Open-Source Standards & CI/CD**: Added MIT `LICENSE`, English `README.md`, Simplified Chinese `README.zh-CN.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `.github` issue/PR templates, slim `docs/` hierarchy, `Casks/lynxbar.rb`, and CI/release workflows with a 0-warning Swift 6 cold-build gate.

### Changed
- Flipped `Settings.showPublicIP` default to `false` (preserving explicit existing user preferences) and added clear privacy disclosures in `SettingsView`.
- Adjusted `OverviewView` card layout metrics to accommodate the optional `OverviewAIQuotaRow` within the fixed `420×600` panel without overflow.

### Removed
- Removed environment-specific cargo cache cleanup code, scripts, tests, and localization strings while keeping the general Trash-safe `DiskCleanup` workflow.
- Removed oversized historical QA screenshots, redundant product/design scratch directories, and standalone site files to keep the repository lightweight.
