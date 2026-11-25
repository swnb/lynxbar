import AppKit
import XCTest
@testable import LynxBar

final class ClipboardAndCadenceTests: XCTestCase {
    func testCopyWritesExactVisibleValue() {
        var written: String?

        let succeeded = ClipboardAction.copy("3C:22:FB:8A:41:0D") {
            written = $0
            return true
        }

        XCTAssertTrue(succeeded)
        XCTAssertEqual(written, "3C:22:FB:8A:41:0D")
    }

    func testCopyRejectsUnavailableValue() {
        var writerCalled = false

        let succeeded = ClipboardAction.copy("   ") { _ in
            writerCalled = true
            return true
        }

        XCTAssertFalse(succeeded)
        XCTAssertFalse(writerCalled)
    }

    func testSamplingPolicyKeepsLiveChoicesAndSlowsDisk() {
        XCTAssertEqual(SamplingPolicy.liveInterval(1), 1)
        XCTAssertEqual(SamplingPolicy.liveInterval(10), 10)
        XCTAssertEqual(SamplingPolicy.liveInterval(3), 2)
        XCTAssertEqual(
            DiskCapacityCadence.allCases.map(\.rawValue),
            [600, 3_600, 86_400]
        )
        XCTAssertEqual(
            SamplingPolicy.diskCapacityInterval(.tenMinutes),
            600
        )
        XCTAssertEqual(
            SamplingPolicy.diskCapacityInterval(.oneHour),
            3_600
        )
        XCTAssertEqual(
            SamplingPolicy.diskCapacityInterval(.oneDay),
            86_400
        )
    }

    @MainActor
    func testDiskCadencePersistsAndRejectsUnsupportedValues() {
        let suiteName = "LynxBarTests.DiskCadence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.diskCapacityCadence, .tenMinutes)

        settings.diskCapacityCadence = .oneDay
        let restored = Settings(defaults: defaults)
        XCTAssertEqual(restored.diskCapacityCadence, .oneDay)

        defaults.set(1_234, forKey: "disk.capacity.cadence")
        let invalid = Settings(defaults: defaults)
        XCTAssertEqual(invalid.diskCapacityCadence, .tenMinutes)
    }

    @MainActor
    func testDiskCadenceChangeResamplesAndUsesNewInterval() async {
        let suiteName = "LynxBarTests.DiskReschedule.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        let probe = DiskSamplingProbe()
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lynxbar-disk-cadence-\(UUID().uuidString).json")
        let viewModel = DiskViewModel(
            settings: settings,
            historyStore: MetricHistoryStore(fileURL: historyURL),
            sampler: { await probe.sample() },
            sleeper: { interval in
                try await probe.sleep(for: interval)
            }
        )

        viewModel.startSampling()
        let initialScheduleObserved = await eventually {
            await probe.hasState(sampleCount: 1, intervals: [600])
        }
        XCTAssertTrue(initialScheduleObserved)

        settings.diskCapacityCadence = .oneHour
        let rescheduleObserved = await eventually {
            await probe.hasState(sampleCount: 2, intervals: [600, 3_600])
        }
        XCTAssertTrue(rescheduleObserved)
        viewModel.stopSampling()
    }

    @MainActor
    func testDiskManualRefreshInterruptsWaitAndResetsCadence() async {
        let suiteName = "LynxBarTests.DiskManualRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        settings.diskCapacityCadence = .oneDay
        let probe = DiskSamplingProbe()
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lynxbar-disk-refresh-\(UUID().uuidString).json")
        let viewModel = DiskViewModel(
            settings: settings,
            historyStore: MetricHistoryStore(fileURL: historyURL),
            sampler: { await probe.sample() },
            sleeper: { interval in
                try await probe.sleep(for: interval)
            }
        )

        viewModel.startSampling()
        let initialSampleObserved = await eventually {
            await probe.hasState(sampleCount: 1, intervals: [86_400])
        }
        XCTAssertTrue(initialSampleObserved)

        viewModel.refreshNow()
        viewModel.refreshNow()

        let manualRefreshObserved = await eventually {
            await probe.hasState(
                sampleCount: 2,
                intervals: [86_400, 86_400]
            )
        }
        XCTAssertTrue(manualRefreshObserved)
        try? await Task.sleep(for: .milliseconds(50))
        let finalProbeState = await probe.state()
        XCTAssertEqual(finalProbeState.sampleCount, 2)
        XCTAssertEqual(finalProbeState.intervals, [86_400, 86_400])
        XCTAssertTrue(viewModel.lastSampleFailed)
        viewModel.stopSampling()
    }

    @MainActor
    func testFailedDiskRefreshKeepsLastSuccessfulSnapshotAndHistory() async throws {
        let suiteName = "LynxBarTests.DiskRefreshFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        let successful = makeDiskSnapshot(totalBytes: 1_000, freeBytes: 250)
        let probe = DiskSnapshotSequenceProbe(
            snapshots: [successful, DiskSnapshot()]
        )
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lynxbar-disk-refresh-failure-\(UUID().uuidString).json")
        let viewModel = DiskViewModel(
            settings: settings,
            historyStore: MetricHistoryStore(fileURL: historyURL),
            sampler: { await probe.sample() },
            sleeper: { interval in
                try await probe.sleep(for: interval)
            }
        )

        viewModel.startSampling()
        let successfulSampleObserved = await eventually {
            await probe.hasState(sampleCount: 1, intervalCount: 1)
        }
        XCTAssertTrue(successfulSampleObserved)
        let successfulTimestamp = try XCTUnwrap(viewModel.lastSuccessfulSampleAt)
        let successfulHistory = viewModel.historyResult

        viewModel.refreshNow()

        let failedRefreshObserved = await eventually {
            await probe.hasState(sampleCount: 2, intervalCount: 2)
        }
        XCTAssertTrue(failedRefreshObserved)
        XCTAssertTrue(viewModel.lastSampleFailed)
        XCTAssertEqual(viewModel.snapshot.totalCapacity, 1_000)
        XCTAssertEqual(viewModel.snapshot.totalUsed, 750)
        XCTAssertEqual(viewModel.historyResult, successfulHistory)
        XCTAssertEqual(viewModel.lastSuccessfulSampleAt, successfulTimestamp)
        viewModel.stopSampling()
    }

    func testNetworkInputAndOutputColorsStaySemanticallyDistinct() throws {
        let input = try XCTUnwrap(
            Theme.color(for: .networkInput).usingColorSpace(.sRGB)
        )
        let output = try XCTUnwrap(
            Theme.color(for: .networkOutput).usingColorSpace(.sRGB)
        )

        XCTAssertGreaterThan(input.blueComponent, input.redComponent)
        XCTAssertGreaterThan(output.redComponent, output.blueComponent)
        XCTAssertGreaterThan(
            abs(input.blueComponent - output.blueComponent),
            0.25
        )
    }

    @MainActor
    func testEachWorkspaceExposesOnlyItsProductRanges() {
        XCTAssertEqual(CPUViewModel.allowedRanges, [.minute, .hour, .fiveHours, .day])
        XCTAssertEqual(MemoryViewModel.allowedRanges, [.minute, .hour, .fiveHours, .day])
        XCTAssertEqual(NetworkViewModel.allowedRanges, [.minute, .hour, .fiveHours, .day])
        XCTAssertEqual(DiskViewModel.allowedRanges, [.hour, .day, .week])
    }
}

private actor DiskSamplingProbe {
    private var sampleCount = 0
    private var intervals: [TimeInterval] = []

    func sample() -> DiskSnapshot {
        sampleCount += 1
        return DiskSnapshot()
    }

    func sleep(for interval: TimeInterval) async throws {
        intervals.append(interval)
        try await Task.sleep(for: .seconds(60))
    }

    func hasState(sampleCount expectedCount: Int, intervals expectedIntervals: [TimeInterval]) -> Bool {
        sampleCount >= expectedCount && intervals == expectedIntervals
    }

    func state() -> (sampleCount: Int, intervals: [TimeInterval]) {
        (sampleCount, intervals)
    }
}

private actor DiskSnapshotSequenceProbe {
    private let snapshots: [DiskSnapshot]
    private var sampleCount = 0
    private var intervals: [TimeInterval] = []

    init(snapshots: [DiskSnapshot]) {
        self.snapshots = snapshots
    }

    func sample() -> DiskSnapshot {
        let snapshot = snapshots[min(sampleCount, snapshots.count - 1)]
        sampleCount += 1
        return snapshot
    }

    func sleep(for interval: TimeInterval) async throws {
        intervals.append(interval)
        try await Task.sleep(for: .seconds(60))
    }

    func hasState(sampleCount expectedSamples: Int, intervalCount: Int) -> Bool {
        sampleCount >= expectedSamples && intervals.count == intervalCount
    }
}

private func makeDiskSnapshot(
    totalBytes: UInt64,
    freeBytes: UInt64
) -> DiskSnapshot {
    let volume = DiskVolume(
        device: "/dev/disk-test",
        name: "Test Disk",
        mountPoint: "/",
        fileSystem: "apfs",
        totalBytes: totalBytes,
        freeBytes: freeBytes
    )
    var snapshot = DiskSnapshot()
    snapshot.volumes = [volume]
    snapshot.primaryVolume = volume
    snapshot.totalUsed = volume.usedBytes
    snapshot.totalCapacity = totalBytes
    return snapshot
}

private func eventually(
    timeout: Duration = .seconds(2),
    predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}
