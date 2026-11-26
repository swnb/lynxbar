# Contributing to LynxBar

Thank you for contributing to **LynxBar**! This guide covers local setup, code quality gates, localization parity, and how to extend the `AIUsageProvider` architecture.

---

## Prerequisites

- **macOS 13.0+** (macOS 14.0+ recommended to build and run the `LynxBarTests` and `LynxBarProcessQAHelper` targets)
- **Xcode** with **Swift 6** toolchain
- **XcodeGen** `2.46.0` or newer (`brew install xcodegen`)

---

## Local Build & Verification Gates

`LynxBar.xcodeproj` and `Sources/LynxBar/Resources/Info.plist` are generated from `project.yml` and gitignored. Always regenerate the project after adding, removing, or moving files:

```sh
xcodegen generate
```

### 1. Cold-Build Zero-Warning Gate (`SWIFT_STRICT_CONCURRENCY: complete`)

All code compiles under Swift 6 complete strict concurrency and must produce **zero** compiler warnings on a clean build:

```sh
rm -rf ./build/DerivedDataCI
xcodegen generate
xcodebuild \
  -project LynxBar.xcodeproj \
  -scheme LynxBar \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath ./build/DerivedDataCI \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing 2>&1 | tee ./build/build.log

grep -n ": warning:" ./build/build.log && exit 1 || echo "0 warnings"
```

### 2. Full Unit Test Suite

```sh
xcodebuild \
  -project LynxBar.xcodeproj \
  -scheme LynxBar \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath ./build/DerivedDataCI \
  CODE_SIGNING_ALLOWED=NO \
  test
```

All unit tests run completely offline with zero real Keychain prompts or network calls (except env-gated integration tests such as `LocalDiskTrashIntegrationTests`, which skip cleanly unless explicitly enabled).

### 3. Localization Parity (`en.lproj` & `zh-Hans.lproj`)

Every user-facing string must exist in both:
- `Sources/LynxBar/Resources/en.lproj/Localizable.strings`
- `Sources/LynxBar/Resources/zh-Hans.lproj/Localizable.strings`

Validate plist syntax and key parity before opening a PR:

```sh
plutil -lint \
  Sources/LynxBar/Resources/en.lproj/Localizable.strings \
  Sources/LynxBar/Resources/zh-Hans.lproj/Localizable.strings
```

Ensure both files have identical key sets, zero duplicate keys, and matching format specifiers (`%@`, `%lld`, `%.1f`, etc.).

---

## Coding & Privacy Standards

- **Zero Third-Party Dependencies**: Use Apple system frameworks only.
- **Swift 6 Concurrency**: Prefer value types, `actor` isolation, and explicit `Sendable` conformance. Do not bypass concurrency checks with `@unchecked Sendable`.
- **Docstrings**: Write concise English `///` doc comments on public APIs and functions explaining their behavior.
- **No Secret Logging**: Follow `Sources/LynxBar/Kit/Log.swift` rules strictly—never log OAuth tokens, authorization headers, raw Keychain JSON, or HTTP response bodies at any log level. Mark file paths, IP addresses, and usernames `.private`.
- **Honest Metrics**: Never display `0%` or `100%` when a measurement or quota is unknown, uncollected, expired, or disabled.
- **No Personal Paths**: Never commit local home directory paths or personal usernames in source, scripts, tests, or docs.

---

## Adding a New `AIUsageProvider`

LynxBar's AI quota system is designed around an extensible protocol in `Sources/LynxBar/Providers/AIUsage/`. Follow these steps to add a new subscription provider:

1. **Register the Provider ID** (`Sources/LynxBar/Providers/AIUsage/AIUsageModels.swift`):
   - Add a new `case` to `AIUsageProviderID` (e.g., `case myProvider`). Raw values are persisted in `Settings`.

2. **Implement `AIUsageProvider` as an `actor`**:
   - Follow the existing `ClaudeUsageProvider`, `CodexUsageProvider`, and `GeminiUsageProvider` implementations: create `Sources/LynxBar/Providers/AIUsage/<Provider>UsageProvider.swift` conforming to `AIUsageProvider` (`var id: AIUsageProviderID`, `func fetchQuota(now: Date) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError>`).
   - Inject your credential reader and `AIUsageHTTPTransport` (`AIUsageHTTPClient`) via `init(...)` so unit tests stay 100% offline.
   - Normalize provider utilization values defensively into clamped `0...1` `AIQuotaWindow` entries (`session5h`, `weekly7d`, `weeklyModelSpecific`, `codeReview`, `modelQuota`) and optional `AIExtraUsageSummary` / `AIProviderCreditsSummary`.
   - Never touch browser cookies, store plaintext passwords, refresh OAuth tokens silently, or launch browsers/CLIs when reading credentials.

3. **Wire Provider & Gating into `AIUsageViewModel` & `Settings`**:
   - Update `AIUsageViewModel` (`Sources/LynxBar/Modules/AIUsage/AIUsageViewModel.swift`) and `Settings` (`Sources/LynxBar/Kit/Settings.swift`) so fetching remains strictly opt-in (`false` by default), respects `MonitoringDemandCoordinator` (`overviewHealthModules` must exclude `.aiUsage`), and honors the `300s` polling interval, `60s` cooldown, `429` exponential backoff, and `stopsAutomaticRetry` error semantics.

4. **Update UI & Bilingual Strings**:
   - Update `AIUsagePanelView.swift`, `OverviewAIQuotaRow.swift`, and `MenuBarStatusModel.swift` if provider-specific labels or remediation instructions are required.
   - Add aligned localization keys in both `en.lproj/Localizable.strings` and `zh-Hans.lproj/Localizable.strings`.

5. **Add Offline Unit Tests (`Tests/LynxBarTests/`)**:
   - Add tests covering credential parsing/expiry, `200` / `401` / `403` / `429` (`Retry-After`) / `5xx` / malformed JSON handling via a mocked `AIUsageHTTPTransport`, and `AIUsageViewModel` demand/backoff transitions.
   - Never trigger real Keychain dialogs or live network calls in tests.

---

## Pull Request Process

1. Create a focused branch from `main`.
2. Regenerate the project if files changed (`xcodegen generate`).
3. Verify the 0-warning cold build, full test suite, and localization lint pass.
4. Complete the checklist in [`.github/PULL_REQUEST_TEMPLATE.md`](./.github/PULL_REQUEST_TEMPLATE.md).
