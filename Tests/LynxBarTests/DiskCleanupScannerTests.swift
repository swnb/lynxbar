import XCTest
@testable import LynxBar

final class DiskCleanupScannerTests: XCTestCase {
    func testScannerReturnsCandidatesAndHonestExclusionCounts() async throws {
        let root = TestDiskFactory.root()
        let observations = [
            TestDiskFactory.observation(
                root: root,
                name: "large.bin",
                inode: 100,
                bytes: 2_000_000_000
            ),
            TestDiskFactory.observation(
                root: root,
                name: "old.bin",
                inode: 101,
                bytes: 200_000_000,
                ageDays: 120
            ),
            TestDiskFactory.observation(
                root: root,
                name: "small.bin",
                inode: 102,
                bytes: 1_000
            ),
            TestDiskFactory.observation(
                root: root,
                name: "shared.bin",
                inode: 103,
                bytes: 2_000_000_000,
                links: 2
            ),
        ]
        let reader = FakeDiskReader(root: root, observations: observations)
        let scanner = DiskCleanupScanner(reader: reader)

        let result = try await completedResult(
            from: scanner.events(for: DiskScanRequest(
                rootURL: root.canonicalURL,
                requestedAt: TestDiskFactory.now
            ))
        )

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(
            Set(result.candidates.map(\.rule)),
            Set([.large, .oldAndLarge])
        )
        XCTAssertEqual(result.exclusionCounts[.belowThreshold], 1)
        XCTAssertEqual(result.exclusionCounts[.hardLinked], 1)
        XCTAssertEqual(result.observedEntries, 4)
    }

    func testEmptyDirectoryCompletesWithNoCandidates() async throws {
        let root = TestDiskFactory.root()
        let reader = FakeDiskReader(root: root, observations: [])
        let scanner = DiskCleanupScanner(reader: reader)

        let result = try await completedResult(
            from: scanner.events(for: DiskScanRequest(
                rootURL: root.canonicalURL,
                requestedAt: TestDiskFactory.now
            ))
        )

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.observedEntries, 0)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.exclusionCounts.isEmpty)
    }

    func testLiveEnumerationDoesNotTraverseDirectorySymlinkEscape()
        async throws {
        let manager = FileManager()
        let fixture = manager.temporaryDirectory.appendingPathComponent(
            "lynxbar-cleanup-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = fixture.appendingPathComponent("home", isDirectory: true)
        let rootURL = home.appendingPathComponent(
            "Downloads",
            isDirectory: true
        )
        let outside = fixture.appendingPathComponent(
            "outside",
            isDirectory: true
        )
        try manager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try Data("outside candidate".utf8).write(
            to: outside.appendingPathComponent("outside.bin")
        )
        try manager.createSymbolicLink(
            at: rootURL.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        defer { try? manager.removeItem(at: fixture) }

        let reader = LocalDiskReadAdapter(homeURL: home)
        let scanner = DiskCleanupScanner(reader: reader)
        let result = try await completedResult(
            from: scanner.events(for: DiskScanRequest(
                rootURL: rootURL,
                policy: policy(
                    largeFileBytes: 1,
                    oldFileMinimumBytes: 1
                ),
                requestedAt: TestDiskFactory.now
            ))
        )

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.exclusionCounts[.symbolicLink], 1)
        XCTAssertEqual(result.observedEntries, 1)
    }

    func testScannerEnforcesMetadataConcurrencyBudget() async throws {
        let root = TestDiskFactory.root()
        let observations = (0..<16).map {
            TestDiskFactory.observation(
                root: root,
                name: "file-\($0).bin",
                inode: UInt64(200 + $0),
                bytes: 2_000_000_000
            )
        }
        let reader = FakeDiskReader(
            root: root,
            observations: observations,
            observationDelayNanoseconds: 10_000_000
        )
        let policy = policy(maximumConcurrentMetadataReads: 3)
        let scanner = DiskCleanupScanner(reader: reader)

        _ = try await completedResult(from: scanner.events(for: DiskScanRequest(
            rootURL: root.canonicalURL,
            policy: policy,
            requestedAt: TestDiskFactory.now
        )))

        let peak = await reader.peakObservationCount()
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 3)
    }

    func testScannerStopsAtEntryLimitWithoutPretendingCompletion() async throws {
        let root = TestDiskFactory.root()
        let observations = (0..<10).map {
            TestDiskFactory.observation(
                root: root,
                name: "file-\($0).bin",
                inode: UInt64(300 + $0),
                bytes: 2_000_000_000
            )
        }
        let reader = FakeDiskReader(root: root, observations: observations)
        let scanner = DiskCleanupScanner(reader: reader)

        let result = try await completedResult(
            from: scanner.events(for: DiskScanRequest(
                rootURL: root.canonicalURL,
                policy: policy(maximumEntries: 2),
                requestedAt: TestDiskFactory.now
            ))
        )

        XCTAssertEqual(result.status, .partialEntryLimit)
        XCTAssertEqual(result.observedEntries, 2)
        XCTAssertEqual(result.candidates.count, 2)
    }

    func testScannerDeadlineProducesPartialResult() async throws {
        let root = TestDiskFactory.root()
        let observations = (0..<10).map {
            TestDiskFactory.observation(
                root: root,
                name: "file-\($0).bin",
                inode: UInt64(400 + $0),
                bytes: 2_000_000_000
            )
        }
        let reader = FakeDiskReader(root: root, observations: observations)
        let scanner = DiskCleanupScanner(
            reader: reader,
            clock: IncrementingDiskClock(step: 1)
        )

        let result = try await completedResult(
            from: scanner.events(for: DiskScanRequest(
                rootURL: root.canonicalURL,
                policy: policy(maximumDuration: 2),
                requestedAt: TestDiskFactory.now
            ))
        )

        XCTAssertEqual(result.status, .partialDeadline)
        XCTAssertLessThan(result.observedEntries, observations.count)
    }

    func testCancellingConsumerStopsSchedulingNewMetadataWork() async throws {
        let root = TestDiskFactory.root()
        let observations = (0..<100).map {
            TestDiskFactory.observation(
                root: root,
                name: "file-\($0).bin",
                inode: UInt64(500 + $0),
                bytes: 2_000_000_000
            )
        }
        let reader = FakeDiskReader(
            root: root,
            observations: observations,
            observationDelayNanoseconds: 100_000_000
        )
        let scanner = DiskCleanupScanner(
            reader: reader
        )
        let events = scanner.events(for: DiskScanRequest(
            rootURL: root.canonicalURL,
            policy: policy(maximumConcurrentMetadataReads: 2),
            requestedAt: TestDiskFactory.now
        ))
        let consumer = Task {
            do {
                for try await _ in events {}
            } catch {}
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel()
        await consumer.value
        try await Task.sleep(nanoseconds: 20_000_000)

        let observed = await reader.observationCount()
        XCTAssertLessThanOrEqual(observed, 2)
    }

    func testExplicitCancellationReturnsHonestCancelledSummary()
        async throws {
        let root = TestDiskFactory.root()
        let observations = (0..<100).map {
            TestDiskFactory.observation(
                root: root,
                name: "file-\($0).bin",
                inode: UInt64(700 + $0),
                bytes: 2_000_000_000
            )
        }
        let reader = FakeDiskReader(
            root: root,
            observations: observations,
            observationDelayNanoseconds: 100_000_000
        )
        let cancellation = DiskScanCancellation()
        let scanner = DiskCleanupScanner(reader: reader)
        let request = DiskScanRequest(
            rootURL: root.canonicalURL,
            policy: policy(maximumConcurrentMetadataReads: 2),
            requestedAt: TestDiskFactory.now,
            cancellation: cancellation
        )
        let events = scanner.events(for: request)
        let resultTask = Task { @Sendable () async throws
            -> DiskScanResult in
            for try await event in events {
                if case .completed(let result) = event {
                    return result
                }
            }
            throw DiskCleanupError.enumerationFailed
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        cancellation.cancel()
        let result = try await resultTask.value

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertLessThanOrEqual(result.observedEntries, 2)
        XCTAssertTrue(result.candidates.isEmpty)
        let observed = await reader.observationCount()
        XCTAssertLessThanOrEqual(observed, 2)
    }

    private func completedResult(
        from events: AsyncThrowingStream<DiskScanEvent, Error>
    ) async throws -> DiskScanResult {
        for try await event in events {
            if case .completed(let result) = event {
                return result
            }
        }
        throw DiskCleanupError.enumerationFailed
    }

    private func policy(
        largeFileBytes: UInt64 = 1_000_000_000,
        oldFileMinimumBytes: UInt64 = 100_000_000,
        maximumEntries: Int = 100_000,
        maximumDuration: TimeInterval = 60,
        maximumConcurrentMetadataReads: Int = 4
    ) -> DiskScanPolicy {
        DiskScanPolicy(
            version: 1,
            largeFileBytes: largeFileBytes,
            oldFileMinimumBytes: oldFileMinimumBytes,
            oldFileMinimumAge: 90 * 24 * 60 * 60,
            maximumEntries: maximumEntries,
            maximumDuration: maximumDuration,
            maximumConcurrentMetadataReads:
                maximumConcurrentMetadataReads,
            progressEntryInterval: 1,
            progressTimeInterval: 0.01
        )
    }
}
