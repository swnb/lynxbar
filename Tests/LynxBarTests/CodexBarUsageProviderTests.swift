import CodexBarCore
import Foundation
import XCTest
@testable import LynxBar

/// Offline unit tests verifying `CodexBarUsageProvider` privacy constraints, snapshot normalization,
/// Antigravity quota window promotion, and upstream error classification without touching disk or network.
final class CodexBarUsageProviderTests: XCTestCase {
    private let referenceNow = Date(timeIntervalSince1970: 1_760_000_000)

    func testMakeFetchContextDisablesBrowserCookiesAcrossAllProviders() {
        for providerID in AIUsageProviderID.allCases {
            let context = CodexBarUsageProvider.makeFetchContext(for: providerID, environment: [:])
            XCTAssertEqual(context.settings?.claude?.cookieSource, .off)
            XCTAssertEqual(context.settings?.claude?.webExtrasEnabled, false)
            XCTAssertEqual(context.settings?.claude?.desktopCookiesEnabled, false)
            XCTAssertEqual(context.settings?.codex?.cookieSource, .off)
            XCTAssertFalse(context.webDebugDumpHTML)
            if providerID == .claude {
                XCTAssertEqual(context.sourceMode, .oauth)
            } else {
                XCTAssertEqual(context.sourceMode, .auto)
            }
            XCTAssertEqual(context.persistsCLISessions, providerID == .antigravity)
        }
    }

    func testAntigravitySnapshotPromotesExtraQuotaSummaryWindowsAndMapsIdentity() async throws {
        let resetAt = referenceNow.addingTimeInterval(3_600)
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Models",
                    window: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: resetAt, resetDescription: nil),
                    usageKnown: true
                ),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude and GPT",
                    window: RateWindow(usedPercent: 40, windowMinutes: 10_080, resetsAt: resetAt, resetDescription: nil),
                    usageKnown: true
                ),
                NamedRateWindow(
                    id: "antigravity-unknown",
                    title: "Unknown Window",
                    window: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    usageKnown: false
                ),
            ],
            updatedAt: referenceNow,
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: "dev@example.com",
                accountOrganization: nil,
                loginMethod: "Google AI Pro"
            )
        )

        let fetchResult = ProviderFetchResult(
            usage: usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "antigravity.app-local",
            strategyID: "antigravity.app-local",
            strategyKind: .localProbe
        )

        let provider = CodexBarUsageProvider(
            providerID: .antigravity,
            environment: [:],
            upstreamFetch: { upstream, _ in
                XCTAssertEqual(upstream, .antigravity)
                return ProviderFetchOutcome(result: .success(fetchResult), attempts: [])
            }
        )

        let result = await provider.fetchQuota(now: referenceNow)
        let snapshot = try result.get()
        XCTAssertEqual(snapshot.providerID, .antigravity)
        XCTAssertEqual(snapshot.primaryWindow?.title, "Gemini Models")
        XCTAssertEqual(snapshot.primaryWindow?.usedRatio ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.primaryWindow?.kind, .session5h)
        XCTAssertEqual(snapshot.secondaryWindow?.title, "Claude and GPT")
        XCTAssertEqual(snapshot.secondaryWindow?.usedRatio ?? -1, 0.40, accuracy: 0.0001)
        XCTAssertEqual(snapshot.secondaryWindow?.kind, .weekly7d)
        XCTAssertTrue(snapshot.additionalWindows.isEmpty, "Unknown usage windows must be filtered out")
        XCTAssertEqual(snapshot.accountLabel, "dev@example.com")
        XCTAssertEqual(snapshot.planLabel, "Google AI Pro")
    }

    func testClaudeAndCodexSnapshotsFilterSyntheticPlaceholdersAndMapExtrasAndCredits() async throws {
        let placeholderPrimary = RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: true
        )
        let realWeekly = RateWindow(
            usedPercent: 35,
            windowMinutes: 10_080,
            resetsAt: referenceNow.addingTimeInterval(86_400),
            resetDescription: nil
        )
        let usage = UsageSnapshot(
            primary: placeholderPrimary,
            secondary: realWeekly,
            providerCost: ProviderCostSnapshot(used: 12.5, limit: 50, currencyCode: "USD", updatedAt: referenceNow),
            updatedAt: referenceNow,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "codex@example.com",
                accountOrganization: nil,
                loginMethod: "plus"
            )
        )
        let credits = CreditsSnapshot(
            remaining: 42.25,
            events: [],
            updatedAt: referenceNow,
            balanceReadSucceeded: true,
            creditsAvailable: true
        )
        let fetchResult = ProviderFetchResult(
            usage: usage,
            credits: credits,
            dashboard: nil,
            sourceLabel: "codex.oauth",
            strategyID: "codex.oauth",
            strategyKind: .oauth
        )

        let provider = CodexBarUsageProvider(
            providerID: .codex,
            environment: [:],
            upstreamFetch: { _, _ in
                ProviderFetchOutcome(result: .success(fetchResult), attempts: [])
            }
        )

        let snapshot = try await provider.fetchQuota(now: referenceNow).get()
        XCTAssertNil(snapshot.primaryWindow, "Synthetic placeholder windows must not render as 0% usage")
        XCTAssertEqual(snapshot.secondaryWindow?.usedRatio ?? -1, 0.35, accuracy: 0.0001)
        XCTAssertEqual(snapshot.extraUsage?.usedAmount, 12.5)
        XCTAssertEqual(snapshot.extraUsage?.monthlyLimit, 50)
        XCTAssertEqual(snapshot.credits?.balanceAmount, 42.25)
        XCTAssertEqual(snapshot.credits?.hasCredits, true)
    }

    func testErrorMappingClassifiesUpstreamErrorsAccurately() {
        XCTAssertEqual(
            CodexBarUsageProvider.mapError(ProviderFetchClassifiedError(kind: .missingCredential, message: "missing")),
            .credentialsMissing
        )
        XCTAssertEqual(
            CodexBarUsageProvider.mapError(ProviderFetchClassifiedError(kind: .authenticationExpired, message: "expired")),
            .tokenExpired
        )
        XCTAssertEqual(
            CodexBarUsageProvider.mapError(ProviderFetchClassifiedError(kind: .permissionDenied, message: "denied")),
            .unauthorized
        )
        XCTAssertEqual(
            CodexBarUsageProvider.mapError(ProviderFetchClassifiedError(kind: .rateLimited, message: "429", retryAfterSeconds: 8)),
            .rateLimited(retryAfter: 8)
        )
        XCTAssertEqual(
            CodexBarUsageProvider.mapError(AntigravityStatusProbeError.notRunning),
            .credentialsMissing
        )
    }

    func testOfflineFallbackSnapshotSurfacesUnderlyingLiveFailureInsteadOfDecodingFailure() async {
        let offlineUsage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-offline-conversations",
                    title: "Offline · 3 conversations",
                    window: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    usageKnown: false
                ),
            ],
            updatedAt: referenceNow
        )
        let fetchResult = ProviderFetchResult(
            usage: offlineUsage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "offline",
            strategyID: "antigravity.offline",
            strategyKind: .localProbe,
            diagnostic: "Live Antigravity usage is unavailable; showing offline data. Antigravity is not running."
        )
        let provider = CodexBarUsageProvider(providerID: .antigravity, environment: [:]) { _, _ in
            ProviderFetchOutcome(
                result: .success(fetchResult),
                attempts: [
                    ProviderFetchAttempt(strategyID: "antigravity.app-local", kind: .localProbe, wasAvailable: true, errorDescription: "Antigravity is not running"),
                    ProviderFetchAttempt(strategyID: "antigravity.cli-https", kind: .cli, wasAvailable: false, errorDescription: nil),
                    ProviderFetchAttempt(strategyID: "antigravity.offline", kind: .localProbe, wasAvailable: true, errorDescription: nil),
                ]
            )
        }

        let result = await provider.fetchQuota(now: referenceNow)
        XCTAssertEqual(result, .failure(.credentialsMissing))
    }
}
