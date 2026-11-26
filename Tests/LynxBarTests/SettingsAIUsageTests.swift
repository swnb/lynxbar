import Combine
import XCTest
@testable import LynxBar

@MainActor
final class SettingsAIUsageTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "SettingsAIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func testFreshDefaultsHaveAllAIProvidersDisabled() {
        let defaults = makeIsolatedDefaults()
        let settings = Settings(defaults: defaults)

        XCTAssertFalse(settings.claudeUsageEnabled)
        XCTAssertFalse(settings.codexUsageEnabled)
        XCTAssertFalse(settings.antigravityUsageEnabled)
        XCTAssertFalse(settings.anyAIUsageEnabled)
        XCTAssertFalse(settings.aiUsageEnabled)
        XCTAssertTrue(settings.enabledAIUsageProviders.isEmpty)

        for providerID in AIUsageProviderID.allCases {
            XCTAssertFalse(settings.isAIProviderEnabled(providerID))
        }
    }

    func testIndependentPerProviderTogglesPersistenceAndCanonicalOrder() {
        let defaults = makeIsolatedDefaults()
        let settings = Settings(defaults: defaults)

        settings.setAIProviderEnabled(true, for: .antigravity)
        settings.setAIProviderEnabled(true, for: .codex)

        XCTAssertFalse(settings.claudeUsageEnabled)
        XCTAssertTrue(settings.codexUsageEnabled)
        XCTAssertTrue(settings.antigravityUsageEnabled)
        XCTAssertTrue(settings.anyAIUsageEnabled)
        XCTAssertTrue(settings.aiUsageEnabled)
        XCTAssertEqual(settings.enabledAIUsageProviders, [.codex, .antigravity])
        XCTAssertFalse(settings.isAIProviderEnabled(.claude))
        XCTAssertTrue(settings.isAIProviderEnabled(.codex))
        XCTAssertTrue(settings.isAIProviderEnabled(.antigravity))

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.claudeUsageEnabled)
        XCTAssertTrue(reloaded.codexUsageEnabled)
        XCTAssertTrue(reloaded.antigravityUsageEnabled)
        XCTAssertTrue(reloaded.aiUsageEnabled)
        XCTAssertEqual(reloaded.enabledAIUsageProviders, [.codex, .antigravity])

        reloaded.setAIProviderEnabled(false, for: .codex)
        XCTAssertEqual(reloaded.enabledAIUsageProviders, [.antigravity])
        XCTAssertTrue(reloaded.anyAIUsageEnabled)
        XCTAssertTrue(reloaded.aiUsageEnabled)

        reloaded.setAIProviderEnabled(false, for: .antigravity)
        XCTAssertEqual(reloaded.enabledAIUsageProviders, [])
        XCTAssertFalse(reloaded.anyAIUsageEnabled)
        XCTAssertFalse(reloaded.aiUsageEnabled)
    }

    func testLegacyAIUsageEnabledMigratesOnlyClaude() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "aiUsage.enabled")

        let settings = Settings(defaults: defaults)

        XCTAssertTrue(settings.claudeUsageEnabled)
        XCTAssertFalse(settings.codexUsageEnabled)
        XCTAssertFalse(settings.antigravityUsageEnabled)
        XCTAssertTrue(settings.anyAIUsageEnabled)
        XCTAssertTrue(settings.aiUsageEnabled)
        XCTAssertEqual(settings.enabledAIUsageProviders, [.claude])

        settings.codexUsageEnabled = true
        let withCodex = Settings(defaults: defaults)
        XCTAssertTrue(withCodex.claudeUsageEnabled)
        XCTAssertTrue(withCodex.codexUsageEnabled)
        XCTAssertFalse(withCodex.antigravityUsageEnabled)

        withCodex.claudeUsageEnabled = false
        withCodex.codexUsageEnabled = false
        XCTAssertFalse(withCodex.aiUsageEnabled)

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.claudeUsageEnabled)
        XCTAssertFalse(reloaded.codexUsageEnabled)
        XCTAssertFalse(reloaded.antigravityUsageEnabled)
        XCTAssertFalse(reloaded.aiUsageEnabled)
    }

    func testAggregateAIUsageFlagBidirectionalSynchronization() {
        let defaults = makeIsolatedDefaults()
        let settings = Settings(defaults: defaults)

        settings.aiUsageEnabled = true
        XCTAssertTrue(settings.claudeUsageEnabled)
        XCTAssertFalse(settings.codexUsageEnabled)
        XCTAssertFalse(settings.antigravityUsageEnabled)
        XCTAssertEqual(settings.enabledAIUsageProviders, [.claude])

        settings.codexUsageEnabled = true
        settings.antigravityUsageEnabled = true
        XCTAssertEqual(settings.enabledAIUsageProviders, [.claude, .codex, .antigravity])

        settings.aiUsageEnabled = false
        XCTAssertFalse(settings.claudeUsageEnabled)
        XCTAssertFalse(settings.codexUsageEnabled)
        XCTAssertFalse(settings.antigravityUsageEnabled)
        XCTAssertFalse(settings.anyAIUsageEnabled)
        XCTAssertTrue(settings.enabledAIUsageProviders.isEmpty)

        settings.codexUsageEnabled = true
        XCTAssertTrue(settings.aiUsageEnabled)
        settings.aiUsageEnabled = true
        XCTAssertFalse(settings.claudeUsageEnabled)
        XCTAssertTrue(settings.codexUsageEnabled)
        XCTAssertFalse(settings.antigravityUsageEnabled)
    }

    func testReentrantCombineSinkMutatingAggregateConvergesCleanly() {
        let defaults = makeIsolatedDefaults()
        let settings = Settings(defaults: defaults)
        var cancellables = Set<AnyCancellable>()

        settings.$claudeUsageEnabled
            .dropFirst()
            .sink { enabled in
                if enabled {
                    settings.aiUsageEnabled = false
                }
            }
            .store(in: &cancellables)

        settings.aiUsageEnabled = true

        XCTAssertFalse(settings.aiUsageEnabled)
        XCTAssertFalse(settings.claudeUsageEnabled)
        XCTAssertFalse(settings.codexUsageEnabled)
        XCTAssertFalse(settings.antigravityUsageEnabled)
        XCTAssertFalse(settings.anyAIUsageEnabled)
        XCTAssertEqual(settings.aiUsageEnabled, settings.anyAIUsageEnabled)

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.aiUsageEnabled)
        XCTAssertFalse(reloaded.claudeUsageEnabled)
        XCTAssertFalse(reloaded.codexUsageEnabled)
        XCTAssertFalse(reloaded.antigravityUsageEnabled)
    }

    func testReentrantCombineSinkReenablingAggregateDuringDisableConvergesCleanly() {
        let defaults = makeIsolatedDefaults()
        let settings = Settings(defaults: defaults)
        settings.claudeUsageEnabled = true
        var cancellables = Set<AnyCancellable>()

        settings.$claudeUsageEnabled
            .dropFirst()
            .sink { enabled in
                if !enabled {
                    settings.aiUsageEnabled = true
                }
            }
            .store(in: &cancellables)

        settings.aiUsageEnabled = false

        XCTAssertTrue(settings.aiUsageEnabled)
        XCTAssertTrue(settings.claudeUsageEnabled)
        XCTAssertFalse(settings.codexUsageEnabled)
        XCTAssertFalse(settings.antigravityUsageEnabled)
        XCTAssertEqual(settings.aiUsageEnabled, settings.anyAIUsageEnabled)
    }

    func testOscillatingReentrantCombineSinksHitBreakerAndConvergeWithPersistedDefaults() {
        let defaults = makeIsolatedDefaults()
        let settings = Settings(defaults: defaults)
        var cancellables = Set<AnyCancellable>()
        var claudeEmissions = 0
        var aggregateEmissions = 0
        var didMutateGeminiOnBreaker = false

        // Drive >16 sync iterations by flipping `aiUsageEnabled` on every `$claudeUsageEnabled` change.
        settings.$claudeUsageEnabled
            .dropFirst()
            .sink { enabled in
                claudeEmissions += 1
                settings.aiUsageEnabled = !enabled
            }
            .store(in: &cancellables)

        // During the breaker's aggregate reconciliation write (`aggregateEmissions >= 18`), mutate
        // `antigravityUsageEnabled` once (`1C7c`) so the final passes must re-reconcile aggregate & defaults.
        settings.$aiUsageEnabled
            .dropFirst()
            .sink { enabled in
                aggregateEmissions += 1
                if aggregateEmissions >= 18 && !didMutateGeminiOnBreaker {
                    didMutateGeminiOnBreaker = true
                    settings.antigravityUsageEnabled = !enabled
                }
            }
            .store(in: &cancellables)

        settings.aiUsageEnabled = true

        XCTAssertGreaterThanOrEqual(claudeEmissions, 16)
        XCTAssertGreaterThanOrEqual(aggregateEmissions, 18)
        XCTAssertTrue(didMutateGeminiOnBreaker)
        XCTAssertEqual(settings.aiUsageEnabled, settings.anyAIUsageEnabled)
        XCTAssertTrue(settings.antigravityUsageEnabled)
        XCTAssertTrue(settings.aiUsageEnabled)

        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.aiUsageEnabled, settings.aiUsageEnabled)
        XCTAssertEqual(reloaded.claudeUsageEnabled, settings.claudeUsageEnabled)
        XCTAssertEqual(reloaded.codexUsageEnabled, settings.codexUsageEnabled)
        XCTAssertEqual(reloaded.antigravityUsageEnabled, settings.antigravityUsageEnabled)
        XCTAssertEqual(reloaded.aiUsageEnabled, reloaded.anyAIUsageEnabled)
    }
}
