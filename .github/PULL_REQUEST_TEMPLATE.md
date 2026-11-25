## Summary

<!-- Briefly describe what this PR changes and why. -->

## Related Issue(s)

<!-- e.g. Fixes #123 -->

## Checklist

- [ ] **XcodeGen**: Regenerated project (`xcodegen generate`) if files were added, moved, or removed.
- [ ] **Swift 6 Strict Concurrency**: Builds cleanly under `SWIFT_STRICT_CONCURRENCY: complete` without `@unchecked Sendable` workarounds.
- [ ] **Zero-Warning Cold Build**: Clean `DerivedData` build-for-testing produces `0` `: warning:` lines.
- [ ] **Unit Tests**: Full `xcodebuild test` suite passes with `0` failures, and new behavior is covered by offline unit tests.
- [ ] **Localization Parity**: `Sources/LynxBar/Resources/en.lproj/Localizable.strings` and `zh-Hans.lproj/Localizable.strings` pass `plutil -lint` with 100% key and format-specifier parity.
- [ ] **Documentation & Docstrings**: Public APIs and functions include concise `///` doc comments explaining behavior; relevant docs are updated.
- [ ] **Privacy & Hygiene**: Zero OAuth tokens, authorization headers, or raw Keychain JSON logged (`Log.swift` rules); no personal paths or usernames committed.
