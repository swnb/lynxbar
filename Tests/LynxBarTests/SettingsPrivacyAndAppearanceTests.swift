import AppKit
import XCTest
@testable import LynxBar

@MainActor
final class SettingsPrivacyAndAppearanceTests: XCTestCase {
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "com.swnb.LynxBarTests.privacyAppearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    /// Verifies that `showPublicIP` defaults to `false` when `"network.showPublicIP"` is absent.
    func testShowPublicIPDefaultsToFalseWhenKeyAbsent() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(defaults.object(forKey: "network.showPublicIP"))
        let settings = Settings(defaults: defaults)
        XCTAssertFalse(settings.showPublicIP)
    }

    /// Verifies that explicit stored boolean preferences for `showPublicIP` are preserved.
    func testShowPublicIPPreservesExplicitStoredValues() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "network.showPublicIP")
        XCTAssertTrue(Settings(defaults: defaults).showPublicIP)

        defaults.set(false, forKey: "network.showPublicIP")
        let settings = Settings(defaults: defaults)
        XCTAssertFalse(settings.showPublicIP)

        settings.showPublicIP = true
        XCTAssertTrue(Settings(defaults: defaults).showPublicIP)
    }

    /// Verifies that `appearanceMode` defaults to `.system` when absent or given an unrecognized raw value.
    func testAppearanceModeDefaultsToSystemWhenAbsentOrInvalid() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(defaults.object(forKey: "general.appearanceMode"))
        XCTAssertEqual(Settings(defaults: defaults).appearanceMode, .system)

        defaults.set("sepia", forKey: "general.appearanceMode")
        XCTAssertEqual(Settings(defaults: defaults).appearanceMode, .system)
    }

    /// Verifies that updating `appearanceMode` persists across separate `Settings(defaults:)` instances.
    func testAppearanceModePersistsAcrossSettingsInstances() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        for mode in [AppAppearanceMode.dark, .light, .system] {
            settings.appearanceMode = mode
            XCTAssertEqual(Settings(defaults: defaults).appearanceMode, mode)
        }
    }

    /// Verifies that `AppAppearanceMode` maps `.system`, `.dark`, and `.light` to the expected AppKit appearances.
    func testAppAppearanceModeNSAppearanceMapping() {
        XCTAssertEqual(AppAppearanceMode.allCases, [.system, .dark, .light])
        XCTAssertNil(AppAppearanceMode.system.appearanceName)
        XCTAssertNil(AppAppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppAppearanceMode.dark.appearanceName, .darkAqua)
        XCTAssertEqual(AppAppearanceMode.dark.nsAppearance?.name, .darkAqua)
        XCTAssertEqual(AppAppearanceMode.light.appearanceName, .aqua)
        XCTAssertEqual(AppAppearanceMode.light.nsAppearance?.name, .aqua)
    }

    /// Verifies that `aiUsageEnabled` defaults to `false` and preserves explicit stored values.
    func testAIUsageEnabledDefaultsToFalseAndPreservesExplicitValues() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(defaults.object(forKey: "aiUsage.enabled"))
        XCTAssertFalse(Settings(defaults: defaults).aiUsageEnabled)

        defaults.set(true, forKey: "aiUsage.enabled")
        XCTAssertTrue(Settings(defaults: defaults).aiUsageEnabled)

        defaults.set(false, forKey: "aiUsage.enabled")
        XCTAssertFalse(Settings(defaults: defaults).aiUsageEnabled)
    }

    /// Verifies that `aiQuotaDisplayStyle` defaults to `.remaining` and persists updates.
    func testAIQuotaDisplayStyleDefaultsToRemainingAndPersists() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(defaults.object(forKey: "aiUsage.displayStyle"))
        XCTAssertEqual(Settings(defaults: defaults).aiQuotaDisplayStyle, .remaining)

        defaults.set("unknown-style", forKey: "aiUsage.displayStyle")
        XCTAssertEqual(Settings(defaults: defaults).aiQuotaDisplayStyle, .remaining)

        let settings = Settings(defaults: defaults)
        settings.aiQuotaDisplayStyle = .used
        XCTAssertEqual(Settings(defaults: defaults).aiQuotaDisplayStyle, .used)
        settings.aiQuotaDisplayStyle = .remaining
        XCTAssertEqual(Settings(defaults: defaults).aiQuotaDisplayStyle, .remaining)
    }

    /// Verifies that `aiUsageSectionVisible` defaults to `true` and preserves explicit stored values.
    func testAIUsageSectionVisibleDefaultsToTrueAndPreservesExplicitValues() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(defaults.object(forKey: "module.aiUsage.visible"))
        XCTAssertTrue(Settings(defaults: defaults).aiUsageSectionVisible)

        let settings = Settings(defaults: defaults)
        settings.aiUsageSectionVisible = false
        XCTAssertFalse(Settings(defaults: defaults).aiUsageSectionVisible)
    }
}
