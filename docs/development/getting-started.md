# Developer Getting Started

> **Language**: English | **Related**: [Contributing Guide](../../CONTRIBUTING.md) · [Architecture Specification](../architecture/v2-architecture-design.md) · [Security Policy](../../SECURITY.md)

This guide covers building, running, testing, and verifying **LynxBar** locally.

---

## 1. Prerequisites

- **macOS 13.0 (Ventura)** or later (macOS 14.0+ recommended for `LynxBarTests` and `LynxBarProcessQAHelper`)
- **Xcode** with **Swift 6** (`SWIFT_STRICT_CONCURRENCY: complete`)
- **XcodeGen** `2.46.0` or newer:

```sh
brew install xcodegen
```

---

## 2. Quick Start

`LynxBar.xcodeproj` and `Sources/LynxBar/Resources/Info.plist` are generated from `project.yml` and are excluded from Git.

```sh
# Generate LynxBar.xcodeproj
xcodegen generate

# Build Debug configuration (runs xcodegen generate automatically)
make build

# Launch the built Debug app from DerivedData
make run

# Remove build/ and generated LynxBar.xcodeproj
make clean
```

To inspect the project in Xcode:

```sh
xcodegen generate && open LynxBar.xcodeproj
```

---

## 3. Repository Structure

```text
.
├── Sources/
│   ├── LynxBar/
│   │   ├── App/          # LynxBarApp, AppDelegate, MenuBarStatusPresenter
│   │   ├── Kit/          # Log, Settings, MonitoringDemand*, MenuBar*, MetricHistory, Theme, PanelHost
│   │   ├── Providers/    # System probes, DiskCleanup/, AIUsage/ (ClaudeCredentialReader, ClaudeUsageProvider)
│   │   ├── Modules/      # Dashboard/, Settings/, DiskCleanup/, AIUsage/, per-metric views & view models
│   │   └── Resources/    # LynxBar.entitlements, Assets.xcassets, en.lproj/, zh-Hans.lproj/
│   └── LynxBarProcessQAHelper/
├── Tests/
│   └── LynxBarTests/     # Offline unit tests (zero Keychain prompts or network requests)
├── Casks/
│   └── lynxbar.rb        # Homebrew cask definition
├── scripts/
│   └── release.sh        # Local DMG archive, notarization, and stapling helper
├── docs/
│   ├── architecture/     # Core V2 architecture and AI quota design baseline
│   ├── development/      # Developer guides
│   └── guides/           # End-user documentation
└── project.yml           # XcodeGen project specification
```

---

## 4. Running Tests & 0-Warning Cold-Build Gate

### Full Unit Test Suite

```sh
xcodegen generate
xcodebuild \
  -project LynxBar.xcodeproj \
  -scheme LynxBar \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Unit tests run completely offline using dependency injection (`ClaudeCredentialReading`, `AIUsageHTTPTransport`, mock clocks, and test doubles). Environment-gated native integration tests (such as `LocalDiskTrashIntegrationTests`) skip cleanly unless explicitly opted in.

### Cold-Build Zero-Warning Verification

CI enforces **zero** compiler warnings on a fresh `DerivedData` build. To reproduce locally:

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

---

## 5. Localization Workflow (`en` & `zh-Hans`)

LynxBar maintains 100% key and format-specifier parity between:
- `Sources/LynxBar/Resources/en.lproj/Localizable.strings`
- `Sources/LynxBar/Resources/zh-Hans.lproj/Localizable.strings`

Validate syntax before committing changes:

```sh
plutil -lint \
  Sources/LynxBar/Resources/en.lproj/Localizable.strings \
  Sources/LynxBar/Resources/zh-Hans.lproj/Localizable.strings
```

---

## 6. Debug Visual QA Flags (`#if DEBUG`)

`AppDelegate` exposes launch arguments in `Debug` builds for inspecting the `420×600` dashboard or `DiskCleanup` window in a regular foreground window:

| Argument | Purpose |
| --- | --- |
| `--visual-qa <section>` | Open QA window at section (`overview`, `cpu`, `memory`, `disk`, `network`, `gpu`, `battery`, `ai`, `settings`) |
| `--visual-qa-appearance <light\|dark>` | Override QA window appearance without mutating user settings |
| `--visual-qa-text-size <size>` | Test Dynamic Type sizes (`xsmall` through `accessibility5`) |
| `--visual-qa-cleanup` | Launch the **LynxBar — Free Up Space Safely** window |
| `--visual-qa-cleanup-root <path>` | Auto-scan a disposable test root in cleanup QA mode |
| `--visual-qa-capture <path>` | Capture the QA window bitmap as a PNG after layout settles |

---

## 7. Extending AI Quota Providers

See [Contributing Guide — Adding a New `AIUsageProvider`](../../CONTRIBUTING.md#adding-a-new-aiusageprovider) for the protocol, demand gating, localization, and offline testing checklist.
