# LynxBar

English | [简体中文](./README.zh-CN.md)

**A native, privacy-first macOS menu bar system monitor with Trash-safe disk cleanup and opt-in Claude subscription quota tracking.**

Built in Swift 6 (`complete` strict concurrency) with AppKit, SwiftUI, and zero third-party dependencies.

---

## Features

### Menu Bar & `420×600` Dashboard
- **Single Status Item (`LSUIElement`)**: Lives quietly in your menu bar with no Dock icon and three display modes:
  - **Minimal** — system health symbol only
  - **Focus** — 1 metric slot
  - **Compact** — up to 3 slots (defaults to `CPU`, `DSK`, `NET`)
- **9 Menu Bar Metric Slots**: `CPU`, `MEM` (Memory), `DSK` (Disk usage), `NET` (Network ↓/↑), `GPU`, `TMP` (System thermal state), `BAT` (Internal battery), `ACC` (Accessory battery), and `AI` (AI Quota).
- **Fixed `420×600` Panel**: Header with quick-access Settings gear (`⚙`), Overview + per-resource detail views, and customizable bottom navigation tabs.
- **Appearance Modes**: Choose **System** (default), **Dark**, or **Light** in Settings.

### System Monitoring
- **Overview**: Honest health evaluation (`Healthy` / `Attention` / `Critical` / `Collecting`), 60-second primary trend (`CPU`, `Memory`, or `Network`), top actionable `Attention` item, top 3 processes, and an optional compact `AI Quota` row when enabled.
- **CPU**: Total utilization, per-core bars, load averages (`1 / 5 / 15m`), uptime, thermal context, and top CPU processes.
- **Memory**: Event-driven macOS memory pressure (`DispatchSource.makeMemoryPressureSource`), active/wired/compressed breakdown, swap usage, and top memory processes.
- **Disk**: Root volume (`/`) capacity & low-frequency trends (`10 min` / `1 hour` / `1 day` cadence; `1h` / `1d` / `1w` ranges), mounted volumes, and Trash-safe cleanup.
- **Network**: Default-route primary physical interface (`SystemConfiguration` + `sysctl` 64-bit counters), download/upload rates, on-demand per-process attribution (`nettop`), primary private IP & MAC address, and opt-in Public IP lookup.
- **GPU**: Metal device info, hardware utilization, and thermal context.
- **Battery & Accessories**: Internal battery charge/health/power draw, plus `GameController` battery and opt-in standard Bluetooth Battery Service (`180F` / `2A19`) accessories.
- **Thermal & Processes**: Public `ProcessInfo.thermalState` monitoring and top `5–20` process list with guided `Quit` / `Force Quit` remediation.

### Trash-Safe Disk Cleanup
Launch **Review Files…** from the **Disk** panel to open the **LynxBar — Free Up Space Safely** window:
- **Narrow Scope**: Scans `Downloads` or a user-chosen folder while refusing volume roots, the home root (`~`), `~/Library`, symbolic links, `.app` bundles/packages, and non-local volumes.
- **Conservative Rules**: Flags only downloaded, non-hidden regular local files with hard-link count `1` that are either **Large** (`≥ 1 GiB`) or **Old & large** (`≥ 100 MiB` and unmodified for `≥ 90` days).
- **Safe Execution**: Zero items preselected, **All / Large / Old** filters, **Show in Finder**, explicit confirmation dialog, and per-item identity revalidation before moving files to macOS **Trash** (never permanently deleted).

### Opt-In Claude Subscription Quota (`AI Quota`)
- **Disabled by Default**: Zero requests until you explicitly enable **Claude subscription quota** in the **AI** tab or **Settings → Privacy**.
- **Read-Only Local OAuth**: Reuses your existing local Claude Code credentials read-only (macOS Keychain `"Claude Code-credentials"` skipping MCP-only entries, with fallback to `~/.claude/.credentials.json`).
- **Quota & Breakdown Views**: Displays **5-hour session**, **7-day weekly**, optional model-specific windows (`Sonnet 7-day`, `Opus 7-day`, `OAuth apps 7-day`, `Cowork 7-day`), **Extra usage** overage when enabled, reset countdowns, and a **Remaining quota** (default) vs. **Used quota** toggle.
- **Menu Bar & Overview Integration**: Optional `AI` menu bar slot (`AI 78%`, or `AI —` when off/unavailable/stale past its 15-minute TTL) and a compact `Overview` row that preserves the `420×600` zero-overflow budget.
- **Resilient Demand Scheduling**: Polls every 5 minutes only while viewed or displayed in the menu bar, with a 60-second cooldown, single-flight deduplication, 5-second manual refresh throttle, `429` exponential backoff (`Retry-After` aware), stale-while-error banner retention, and guided `claude /login` remediation when credentials are missing or expired.

---

## Privacy Commitments

- **Zero Telemetry & Zero Cloud Sync**: No analytics, no crash reporting, no remote storage, and no background daemon.
- **Zero Outbound Requests by Default**: Both **Show public IP** (`showPublicIP`) and **Claude subscription quota** (`aiUsageEnabled`) default to `false`.
- **Strict Credential Boundary**: Never reads browser cookies, never stores plaintext passwords, never silently launches browsers or CLI commands, and never writes to Keychain or `~/.claude/`.
- **Secret-Redacting Diagnostics**: Structured `os.Logger` (`com.swnb.LynxBar`) never logs OAuth tokens, authorization headers, raw Keychain JSON, or HTTP response bodies; file paths, IP addresses, and usernames are marked `.private`.
- **Transparent Entitlements**: Distributed non-sandboxed (`com.apple.security.app-sandbox = false` with Hardened Runtime and `com.apple.security.network.client = true`) solely to support `nettop` per-process network attribution and read-only `~/.claude/.credentials.json` fallback access.

---

## Installation

### Requirements
- **macOS 13.0 (Ventura)** or later

### Homebrew Cask
Install from the local cask formula or tap once published:

```sh
brew install --cask ./Casks/lynxbar.rb
```

*(If installing an unsigned or ad-hoc release build, add `--no-quarantine` or right-click **LynxBar.app → Open** on first launch.)*

### GitHub Releases
Download the latest archive from [GitHub Releases](https://github.com/swnb/lynxbar/releases):
- `LynxBar-<version>.dmg` — notarized Developer ID build (when signing credentials are configured)
- `LynxBar-<version>-unsigned.zip` — ad-hoc / unsigned fallback build with `SHA256SUMS.txt` verification

### Build from Source
Requires Xcode with **Swift 6** and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`2.46.0` or newer):

```sh
brew install xcodegen
git clone https://github.com/swnb/lynxbar.git
cd lynxbar
make build
make run
```

Or open the generated Xcode project directly:

```sh
xcodegen generate && open LynxBar.xcodeproj
```

---

## Architecture Highlights

- **Demand-Driven Sampling (`MonitoringDemandCoordinator`)**: Reference-counted `0 ↔ 1` demand edges across `.panel`, `.overviewHealth`, `.menuBar`, and `.remediation` leases ensure expensive probes (like `nettop` process attribution or AI quota fetches) never run unless actively needed. `.aiUsage` is excluded from `overviewHealthModules`.
- **4-Tier Bounded Local History**: In-memory 5-minute live samples plus four persisted archive tiers (`15s` / `1m` / `5m` / `30m` buckets up to 1 week, ~1,164 buckets per series) stored atomically in `~/Library/Application Support/LynxBar/history-v3.plist`.
- **Honest "Never Show 0 When Unknown" Semantics**: Missing credentials, expired tokens, offline networks, warm-up windows, and disabled opt-in features render explicit states instead of fabricating `0%` or `100%`.
- **Zero Third-Party Dependencies**: Built exclusively on Apple system frameworks (`AppKit`, `SwiftUI`, `Combine`, `IOKit`, `Metal`, `GameController`, `CoreBluetooth`, `Security`, `SystemConfiguration`, `ServiceManagement`, `os`).

---

## Unofficial Anthropic OAuth Endpoint Notice

The Claude quota feature queries `https://api.anthropic.com/api/oauth/usage` using local Claude Code OAuth credentials. This is an **unofficial, undocumented endpoint** whose response schema, headers, or availability may change at any time, and whose use is subject to Anthropic's Terms of Service.

- The feature is **disabled by default** and strictly opt-in.
- Polling is capped at a 5-minute interval with cooldown and `429` exponential backoff to avoid upstream load.
- **LynxBar is an independent open-source project and has no official affiliation with, endorsement from, or sponsorship by Anthropic.**

---

## Documentation & Community

- [User Guide](./docs/guides/user-guide.md) — menu bar modes, Disk Cleanup, Claude Code `claude /login` setup, and Appearance/Privacy settings
- [Developer Getting Started](./docs/development/getting-started.md) — local build, 0-warning cold-build gate, test suite, localization, and QA flags
- [Architecture Specification](./docs/architecture/v2-architecture-design.md) — system design, demand coordination, metric definitions, and bounded history
- [Contributing Guide](./CONTRIBUTING.md) — Swift 6 conventions, CI checks, and adding a new `AIUsageProvider`
- [Security Policy](./SECURITY.md) — vulnerability reporting, Keychain boundary, and logging rules
- [Changelog](./CHANGELOG.md) — release history

## License

Licensed under the [MIT License](./LICENSE).
