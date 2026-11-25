import Foundation
import XCTest
@testable import LynxBar

final class ThermalProviderTests: XCTestCase {
    func testPublicProcessInfoStatesMapWithoutNumericInference() {
        XCTAssertEqual(ThermalProvider.state(from: .nominal), .nominal)
        XCTAssertEqual(ThermalProvider.state(from: .fair), .fair)
        XCTAssertEqual(ThermalProvider.state(from: .serious), .serious)
        XCTAssertEqual(ThermalProvider.state(from: .critical), .critical)
    }

    func testCurrentMachinePublicStateUsesKnownPublicEnum() {
        XCTAssertNotEqual(ThermalProvider.currentState(), .unknown)
    }

    func testOnlyPublicThermalStateDrivesHealthSeverity() {
        let now = Date(timeIntervalSince1970: 10_000)
        let base = SystemHealthInput(
            cpuHistory: stride(from: 30.0, through: 0.0, by: -2.0).map {
                MetricPoint(
                    timestamp: now.addingTimeInterval(-$0),
                    value: 0.2
                )
            },
            memoryPressure: .normal,
            diskFreeBytes: 100_000_000_000,
            diskTotalBytes: 500_000_000_000,
            hasPrimaryNetwork: true,
            now: now
        )

        var nominal = base
        nominal.thermalState = .nominal
        XCTAssertEqual(SystemHealthEvaluator.evaluate(nominal).severity, .healthy)

        var serious = base
        serious.thermalState = .serious
        let seriousSummary = SystemHealthEvaluator.evaluate(serious)
        XCTAssertEqual(seriousSummary.severity, .attention)
        XCTAssertEqual(seriousSummary.issues.first?.kind, .thermalSerious)

        var critical = base
        critical.thermalState = .critical
        let criticalSummary = SystemHealthEvaluator.evaluate(critical)
        XCTAssertEqual(criticalSummary.severity, .critical)
        XCTAssertEqual(criticalSummary.issues.first?.kind, .thermalCritical)
    }
}

final class TemperatureSensorContractTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 20_000)
    private let policy = TemperatureSensorPolicy(
        allowlistedGroups: [
            "cpu-die-0": .cpu,
            "cpu-die-1": .cpu,
            "gpu-die": .gpu,
        ],
        staleAfter: 10
    )

    func testHottestAggregateKeepsGroupCountSourceAndTime() {
        let snapshot = TemperatureSensorAggregator.aggregate(
            source: .hid,
            samples: [
                sample("cpu-die-0", 71),
                sample("cpu-die-1", 83),
                sample("gpu-die", 64),
            ],
            policy: policy,
            now: now
        )

        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.source, .hid)
        XCTAssertEqual(snapshot.aggregate(for: .cpu)?.hottestCelsius, 83)
        XCTAssertEqual(snapshot.aggregate(for: .cpu)?.sensorCount, 2)
        XCTAssertEqual(snapshot.aggregate(for: .cpu)?.source, .hid)
        XCTAssertEqual(snapshot.aggregate(for: .gpu)?.hottestCelsius, 64)
        XCTAssertEqual(snapshot.observedAt, now)
    }

    func testUnknownKeyWrongSourceAndOutliersAreExcluded() {
        let snapshot = TemperatureSensorAggregator.aggregate(
            source: .smc,
            samples: [
                sample("unknown", 55, source: .smc),
                sample("cpu-die-0", 70, source: .hid),
                sample("cpu-die-0", .nan, source: .smc),
                sample("cpu-die-0", 126, source: .smc),
            ],
            policy: policy,
            now: now
        )

        XCTAssertEqual(snapshot.availability, .unavailable)
        XCTAssertTrue(snapshot.aggregates.isEmpty)
        XCTAssertNil(snapshot.observedAt)
    }

    func testStaleSnapshotDropsNumericAggregates() {
        let staleTime = now.addingTimeInterval(-11)
        let snapshot = TemperatureSensorAggregator.aggregate(
            source: .ioReport,
            samples: [
                sample("gpu-die", 67, source: .ioReport, at: staleTime),
            ],
            policy: policy,
            now: now
        )

        XCTAssertEqual(snapshot.availability, .stale)
        XCTAssertEqual(snapshot.observedAt, staleTime)
        XCTAssertTrue(snapshot.aggregates.isEmpty)
        XCTAssertNil(snapshot.aggregate(for: .gpu))
    }

    func testFreshGroupDoesNotKeepAnotherGroupsExpiredTemperature() {
        let snapshot = TemperatureSensorAggregator.aggregate(
            source: .hid,
            samples: [
                sample(
                    "cpu-die-0",
                    82,
                    at: now.addingTimeInterval(-11)
                ),
                sample("gpu-die", 61),
            ],
            policy: policy,
            now: now
        )

        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertNil(snapshot.aggregate(for: .cpu))
        XCTAssertEqual(snapshot.aggregate(for: .gpu)?.hottestCelsius, 61)
    }

    func testFutureTimestampIsUnavailableRatherThanCurrentOrStale() {
        let snapshot = TemperatureSensorAggregator.aggregate(
            source: .hid,
            samples: [
                sample(
                    "cpu-die-0",
                    70,
                    at: now.addingTimeInterval(1)
                ),
            ],
            policy: policy,
            now: now
        )

        XCTAssertEqual(snapshot.availability, .unavailable)
        XCTAssertNil(snapshot.observedAt)
        XCTAssertTrue(snapshot.aggregates.isEmpty)
    }

    func testMixedFreshAndFutureGroupsPublishOnlyFreshAggregateTime() {
        let freshTime = now.addingTimeInterval(-1)
        let snapshot = TemperatureSensorAggregator.aggregate(source: .hid,
            samples: [sample("cpu-die-0", 70, at: freshTime),
                      sample("gpu-die", 65, at: now.addingTimeInterval(60))],
            policy: policy, now: now)
        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.observedAt, freshTime)
        XCTAssertEqual(snapshot.aggregate(for: .cpu)?.hottestCelsius, 70)
        XCTAssertNil(snapshot.aggregate(for: .gpu))
    }

    func testMixedExpiredAndFutureGroupsPreserveOnlyExpiredObservationTime() {
        let expiredTime = now.addingTimeInterval(-11)
        let snapshot = TemperatureSensorAggregator.aggregate(source: .hid,
            samples: [sample("cpu-die-0", 70, at: expiredTime),
                      sample("gpu-die", 65, at: now.addingTimeInterval(60))],
            policy: policy, now: now)
        XCTAssertEqual(snapshot.availability, .stale)
        XCTAssertEqual(snapshot.observedAt, expiredTime)
        XCTAssertTrue(snapshot.aggregates.isEmpty)
    }

    func testUnavailableAdapterNeverFabricatesZero() async {
        let adapter = UnavailableTemperatureSensorAdapter()
        let snapshot = await adapter.sample(at: now)

        XCTAssertEqual(snapshot.availability, .unavailable)
        XCTAssertNil(snapshot.observedAt)
        XCTAssertTrue(snapshot.aggregates.isEmpty)
    }

    func testDuplicateSensorIdentityKeepsLatestReadingAndOneCount() {
        let snapshot = TemperatureSensorAggregator.aggregate(source: .hid,
            samples: [sample("cpu-die-0", 90, at: now.addingTimeInterval(-1)),
                      sample("cpu-die-0", 70)], policy: policy, now: now)
        XCTAssertEqual(snapshot.aggregate(for: .cpu)?.hottestCelsius, 70)
        XCTAssertEqual(snapshot.aggregate(for: .cpu)?.sensorCount, 1)
    }

    func testLatestInvalidValueDoesNotResurrectOlderValue() {
        let snapshot = TemperatureSensorAggregator.aggregate(source: .hid,
            samples: [sample("cpu-die-0", 70, at: now.addingTimeInterval(-1)),
                      sample("cpu-die-0", .nan)], policy: policy, now: now)
        XCTAssertEqual(snapshot.availability, .unavailable)
        XCTAssertTrue(snapshot.aggregates.isEmpty)
    }

    func testNonfiniteFreshnessPolicyDoesNotPublishTemperature() {
        let snapshot = TemperatureSensorAggregator.aggregate(source: .hid,
            samples: [sample("cpu-die-0", 70)],
            policy: TemperatureSensorPolicy(allowlistedGroups: ["cpu-die-0": .cpu],
                                             staleAfter: .infinity), now: now)
        XCTAssertEqual(snapshot.availability, .unavailable)
        XCTAssertTrue(snapshot.aggregates.isEmpty)
    }

    private func sample(
        _ stableID: String,
        _ celsius: Double,
        source: TemperatureSensorSource = .hid,
        at observedAt: Date? = nil
    ) -> TemperatureSensorSample {
        TemperatureSensorSample(
            identity: TemperatureSensorIdentity(
                source: source,
                stableID: stableID
            ),
            celsius: celsius,
            observedAt: observedAt ?? now
        )
    }
}

@MainActor
final class ThermalViewModelTests: XCTestCase {
    func testPublicStateNotificationRefreshesWithoutNumericAdapterTimer() async {
        let (settings, defaults, suiteName) = settingsFixture()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = NotificationCenter()
        let publicState = ThermalStateBox(.nominal)
        let sleepProbe = ThermalSleepProbe()
        let viewModel = ThermalViewModel(
            settings: settings,
            notificationCenter: center,
            stateSampler: { publicState.value },
            sleeper: { _ in await sleepProbe.record() }
        )

        viewModel.startSampling()
        XCTAssertTrue(viewModel.isPublicObservationActive)
        XCTAssertEqual(viewModel.snapshot.publicState, .nominal)
        XCTAssertEqual(viewModel.snapshot.temperatures.availability, .unavailable)
        let originalObservation = viewModel.snapshot.publicStateObservedAt
        XCTAssertNotNil(originalObservation)

        publicState.value = .serious
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        for _ in 0..<100 where viewModel.snapshot.publicState != .serious {
            try? await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(viewModel.snapshot.publicState, .serious)
        let sleepCount = await sleepProbe.count
        XCTAssertEqual(sleepCount, 0)
        viewModel.stopSampling()
        XCTAssertFalse(viewModel.isPublicObservationActive)
    }

    func testPublicDemandDoesNotStartAvailableNumericAdapter() async {
        let (settings, defaults, suiteName) = settingsFixture()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = SuspendedTemperatureAdapter()
        let viewModel = ThermalViewModel(settings: settings, temperatureAdapter: adapter)
        viewModel.startSampling()
        defer { viewModel.stopSampling(); viewModel.numericTemperature.stopSampling() }
        for _ in 0..<10 { await Task.yield() }
        let idleCount = await adapter.count
        XCTAssertEqual(idleCount, 0)
        XCTAssertFalse(viewModel.numericTemperature.isSamplingActive)

        viewModel.numericTemperature.startSampling()
        viewModel.numericTemperature.startSampling()
        await waitForSample(adapter)
        let activeCount = await adapter.count
        XCTAssertEqual(activeCount, 1)
        XCTAssertTrue(viewModel.numericTemperature.isSamplingActive)
        let next = TemperatureSensorSnapshot(source: .hid, availability: .available,
            aggregates: [], observedAt: Date())
        await adapter.resume(next)
        for _ in 0..<100 where viewModel.snapshot.temperatures != next { await Task.yield() }
        XCTAssertEqual(viewModel.snapshot.temperatures, next)
    }

    func testUnavailableNumericDemandDoesNotCreateSamplingOrSleep() async {
        let (settings, defaults, suiteName) = settingsFixture()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = SuspendedTemperatureAdapter(availability: .unsupported)
        let sleeper = ThermalSleepProbe()
        let numeric = NumericTemperatureViewModel(settings: settings, adapter: adapter,
            sleeper: { _ in await sleeper.record() })
        numeric.startSampling()
        for _ in 0..<10 { await Task.yield() }
        let sampleCount = await adapter.count
        let sleepCount = await sleeper.count
        XCTAssertEqual(sampleCount, 0)
        XCTAssertEqual(sleepCount, 0)
        XCTAssertFalse(numeric.isSamplingActive)
        XCTAssertEqual(numeric.snapshot.availability, .unsupported)
        XCTAssertNil(numeric.snapshot.observedAt)
    }

    func testStopDropsLateNumericSampleAndDoesNotSleepOrRestart() async {
        let (settings, defaults, suiteName) = settingsFixture()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = SuspendedTemperatureAdapter()
        let sleeper = ThermalSleepProbe()
        let numeric = NumericTemperatureViewModel(settings: settings, adapter: adapter,
            sleeper: { _ in await sleeper.record() })
        numeric.startSampling()
        await waitForSample(adapter)
        let before = numeric.snapshot
        numeric.stopSampling()
        await adapter.resume(TemperatureSensorSnapshot(source: .hid,
            availability: .available, aggregates: [], observedAt: Date()))
        for _ in 0..<10 { await Task.yield() }
        let sampleCount = await adapter.count
        let sleepCount = await sleeper.count
        XCTAssertEqual(numeric.snapshot, before)
        XCTAssertFalse(numeric.isSamplingActive)
        XCTAssertEqual(sampleCount, 1)
        XCTAssertEqual(sleepCount, 0)
    }

    func testStopRejectsQueuedPublicNotificationAndKeepsLastSnapshot() async {
        let (settings, defaults, suiteName) = settingsFixture()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = NotificationCenter()
        let state = ThermalStateBox(.nominal)
        let viewModel = ThermalViewModel(settings: settings, notificationCenter: center,
            stateSampler: { state.value })
        viewModel.startSampling()
        let before = viewModel.snapshot
        state.value = .critical
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        viewModel.stopSampling()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(viewModel.snapshot, before)
        XCTAssertFalse(viewModel.isPublicObservationActive)
    }

    func testStopRetractsNumericValueAndRestartWaitsForFreshFirstSample() async {
        let (settings, defaults, suiteName) = settingsFixture()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = SuspendedTemperatureAdapter()
        let numeric = NumericTemperatureViewModel(settings: settings, adapter: adapter)
        numeric.startSampling()
        await waitForSample(adapter)
        let initial = numericSample(70)
        await adapter.resume(initial, call: 1)
        await waitForSnapshot(initial, in: numeric)
        numeric.stopSampling()
        XCTAssertEqual(numeric.snapshot.availability, .stale)
        XCTAssertTrue(numeric.snapshot.aggregates.isEmpty)
        XCTAssertEqual(numeric.snapshot.observedAt, initial.observedAt)

        numeric.startSampling()
        await waitForSample(adapter, count: 2)
        XCTAssertEqual(numeric.snapshot.availability, .stale)
        XCTAssertTrue(numeric.snapshot.aggregates.isEmpty)
        let next = numericSample(60)
        await adapter.resume(next, call: 2)
        await waitForSnapshot(next, in: numeric)
        XCTAssertEqual(numeric.snapshot.aggregate(for: .cpu)?.hottestCelsius, 60)
        numeric.stopSampling()
    }

    func testRestartRejectsPreviousGenerationsPendingSample() async {
        let (settings, defaults, suiteName) = settingsFixture()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = SuspendedTemperatureAdapter()
        let numeric = NumericTemperatureViewModel(settings: settings, adapter: adapter)
        numeric.startSampling()
        await waitForSample(adapter)
        numeric.stopSampling()
        numeric.startSampling()
        await waitForSample(adapter, count: 2)
        await adapter.resume(numericSample(99), call: 1)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(numeric.snapshot.availability, .unavailable)
        XCTAssertTrue(numeric.snapshot.aggregates.isEmpty)
        let current = numericSample(55)
        await adapter.resume(current, call: 2)
        await waitForSnapshot(current, in: numeric)
        XCTAssertEqual(numeric.snapshot.aggregate(for: .cpu)?.hottestCelsius, 55)
        numeric.stopSampling()
    }

    private func numericSample(_ value: Double) -> TemperatureSensorSnapshot {
        let now = Date()
        return TemperatureSensorSnapshot(source: .hid, availability: .available,
            aggregates: [TemperatureSensorAggregate(group: .cpu,
                hottestCelsius: value, sensorCount: 1, observedAt: now, source: .hid)],
            observedAt: now)
    }

    private func waitForSnapshot(_ expected: TemperatureSensorSnapshot,
                                 in numeric: NumericTemperatureViewModel) async {
        for _ in 0..<100 where numeric.snapshot != expected { await Task.yield() }
        XCTAssertEqual(numeric.snapshot, expected)
    }

    private func waitForSample(_ adapter: SuspendedTemperatureAdapter, count: Int = 1) async {
        for _ in 0..<100 {
            if await adapter.count >= count { return }
            await Task.yield()
        }
        XCTFail("Numeric sampler did not begin its first sample")
    }

    private func settingsFixture() -> (Settings, UserDefaults, String) {
        let suite = "LynxBarTests.Thermal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (Settings(defaults: defaults), defaults, suite)
    }
}

@MainActor
private final class ThermalStateBox {
    var value: SystemThermalState
    init(_ value: SystemThermalState) { self.value = value }
}

private actor ThermalSleepProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor SuspendedTemperatureAdapter: TemperatureSensorAdapter {
    nonisolated let source: TemperatureSensorSource = .hid
    nonisolated let declaredAvailability: TemperatureSensorAvailability
    private(set) var count = 0
    private var continuations: [Int: CheckedContinuation<TemperatureSensorSnapshot, Never>] = [:]

    init(availability: TemperatureSensorAvailability = .available) {
        declaredAvailability = availability
    }

    func sample(at now: Date) async -> TemperatureSensorSnapshot {
        count += 1
        let call = count
        return await withCheckedContinuation { continuations[call] = $0 }
    }

    func resume(_ snapshot: TemperatureSensorSnapshot, call: Int? = nil) {
        guard let selected = call ?? continuations.keys.min() else { return }
        continuations.removeValue(forKey: selected)?.resume(returning: snapshot)
    }
}
