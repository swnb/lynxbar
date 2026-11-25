import XCTest
@testable import LynxBar

final class MetricHistoryTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 2_000_000_000)

    func testMinuteRangeUsesRealBoundaryAndReportsWarmup() {
        var archive = MetricHistoryArchive()
        archive.record(.cpuUsage, value: 0.2, at: anchor.addingTimeInterval(-61))
        archive.record(.cpuUsage, value: 0.4, at: anchor.addingTimeInterval(-30))
        archive.record(.cpuUsage, value: 0.6, at: anchor)

        let result = archive.query(.cpuUsage, range: .minute, now: anchor)

        XCTAssertEqual(result.points.map(\.value), [0.4, 0.6])
        XCTAssertEqual(result.availableDuration, 30, accuracy: 0.001)
        XCTAssertTrue(result.isWarmingUp)
    }

    func testHourRangeAggregatesIntoFifteenSecondBuckets() {
        var archive = MetricHistoryArchive()
        archive.record(.memoryUsage, value: 0.2, at: anchor.addingTimeInterval(-20))
        archive.record(.memoryUsage, value: 0.6, at: anchor.addingTimeInterval(-19))
        archive.record(.memoryUsage, value: 0.8, at: anchor.addingTimeInterval(-1))

        let result = archive.query(.memoryUsage, range: .hour, now: anchor)

        XCTAssertEqual(result.points.count, 2)
        XCTAssertEqual(result.points[0].value, 0.4, accuracy: 0.001)
        XCTAssertEqual(result.points[1].value, 0.8, accuracy: 0.001)
    }

    func testEveryPersistedTierIsBoundedByRetention() {
        var archive = MetricHistoryArchive()
        for minute in 0...(8 * 24 * 60) {
            archive.record(
                .networkDownload,
                value: Double(minute),
                at: anchor.addingTimeInterval(Double(minute * 60))
            )
        }

        XCTAssertLessThanOrEqual(
            archive.persistedBucketCount(for: .networkDownload, range: .hour),
            241
        )
        XCTAssertLessThanOrEqual(
            archive.persistedBucketCount(for: .networkDownload, range: .fiveHours),
            301
        )
        XCTAssertLessThanOrEqual(
            archive.persistedBucketCount(for: .networkDownload, range: .day),
            289
        )
        XCTAssertLessThanOrEqual(
            archive.persistedBucketCount(for: .networkDownload, range: .week),
            337
        )
    }

    func testCodableRoundTripDoesNotRestoreLiveMinuteHistory() throws {
        var archive = MetricHistoryArchive()
        archive.record(.cpuUsage, value: 0.5, at: anchor)

        let data = try JSONEncoder().encode(archive)
        let restored = try JSONDecoder().decode(MetricHistoryArchive.self, from: data)

        XCTAssertTrue(restored.query(.cpuUsage, range: .minute, now: anchor).points.isEmpty)
        XCTAssertEqual(
            restored.query(.cpuUsage, range: .hour, now: anchor).points.map(\.value),
            [0.5]
        )
    }

    func testStorePersistsAndRestoresAggregates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.plist")
        let store = MetricHistoryStore(fileURL: url)
        await store.load()

        await store.record(.diskCapacityUsage, value: 0.74, at: anchor)
        try await store.flush()

        let restored = MetricHistoryStore(fileURL: url)
        await restored.load()
        let result = await restored.query(.diskCapacityUsage, range: .day, now: anchor)
        XCTAssertEqual(result.points.map(\.value), [0.74])
    }

    func testCorruptArchiveFallsBackToWarmup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.plist")
        try Data("not json".utf8).write(to: url)

        let store = MetricHistoryStore(fileURL: url)
        await store.load()
        let result = await store.query(.cpuUsage, range: .hour, now: anchor)

        XCTAssertTrue(result.points.isEmpty)
        XCTAssertTrue(result.isWarmingUp)
    }

    func testNetworkTransferDeltaUsesRealElapsedTimeAndDirectionRollback() throws {
        let delta = try XCTUnwrap(
            NetworkTransferDelta.between(
                currentInterfaceName: "en0",
                currentIn: 1_500,
                currentOut: 900,
                currentAt: anchor,
                previousInterfaceName: "en0",
                previousIn: 1_000,
                previousOut: 1_000,
                previousAt: anchor.addingTimeInterval(-2)
            )
        )

        XCTAssertEqual(delta.interfaceName, "en0")
        XCTAssertEqual(delta.duration, 2, accuracy: 0.001)
        XCTAssertEqual(delta.downloadBytes, 500)
        XCTAssertNil(delta.uploadBytes)
    }

    func testNetworkTransferDeltaRejectsFirstBaselineAndInterfaceChange() {
        XCTAssertNil(
            NetworkTransferDelta.between(
                currentInterfaceName: "en0",
                currentIn: 100,
                currentOut: 100,
                currentAt: anchor,
                previousInterfaceName: nil,
                previousIn: 0,
                previousOut: 0,
                previousAt: nil
            )
        )
        XCTAssertNil(
            NetworkTransferDelta.between(
                currentInterfaceName: "en5",
                currentIn: 100,
                currentOut: 100,
                currentAt: anchor,
                previousInterfaceName: "en0",
                previousIn: 50,
                previousOut: 50,
                previousAt: anchor.addingTimeInterval(-2)
            )
        )
    }

    func testMinuteNetworkTransferTotalsSumBytesAndCoverage() {
        var archive = MetricHistoryArchive()
        archive.recordNetworkTransfer(transfer(
            startOffset: -5,
            endOffset: -3,
            download: 100,
            upload: 40
        ))
        archive.recordNetworkTransfer(transfer(
            startOffset: -3,
            endOffset: 0,
            download: 0,
            upload: 60
        ))

        let result = archive.queryNetworkTransfers(range: .minute, now: anchor)

        XCTAssertEqual(result.downloadBytes, 100)
        XCTAssertEqual(result.uploadBytes, 100)
        XCTAssertEqual(result.downloadCoveredDuration, 5, accuracy: 0.001)
        XCTAssertEqual(result.uploadCoveredDuration, 5, accuracy: 0.001)
        XCTAssertEqual(result.status, .partial)
    }

    func testNetworkTransferCoverageBecomesCompleteAtNinetyPercent() {
        var archive = MetricHistoryArchive()
        for second in 0..<54 {
            archive.recordNetworkTransfer(transfer(
                startOffset: TimeInterval(-54 + second),
                endOffset: TimeInterval(-53 + second),
                download: 1,
                upload: 2
            ))
        }

        let result = archive.queryNetworkTransfers(range: .minute, now: anchor)

        XCTAssertEqual(result.downloadBytes, 54)
        XCTAssertEqual(result.uploadBytes, 108)
        XCTAssertEqual(result.status, .complete)
    }

    func testPersistedNetworkTransferSumRoundTripsWithoutChangingAverageSeries() throws {
        var archive = MetricHistoryArchive()
        archive.record(.networkDownload, value: 10, at: anchor.addingTimeInterval(-2))
        archive.record(.networkDownload, value: 30, at: anchor.addingTimeInterval(-1))
        archive.recordNetworkTransfer(transfer(
            startOffset: -2,
            endOffset: 0,
            download: 4_096,
            upload: 512
        ))

        let data = try JSONEncoder().encode(archive)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(root["networkTransferBuckets"])
        XCTAssertNotNil(root["series"])

        let restored = try JSONDecoder().decode(MetricHistoryArchive.self, from: data)
        let rate = restored.query(.networkDownload, range: .hour, now: anchor)
        let totals = restored.queryNetworkTransfers(range: .hour, now: anchor)

        XCTAssertEqual(rate.points.map(\.value), [20])
        XCTAssertEqual(totals.downloadBytes, 4_096)
        XCTAssertEqual(totals.uploadBytes, 512)
    }

    func testOldSchemaTwoArchiveDefaultsTransferHistoryToCollecting() throws {
        // `MetricSeries` 不是 String/Int CodingKey，Swift 的 Dictionary Codable
        // 会把空字典编码成空数组；fixture 必须复刻真实旧归档形状。
        let data = Data(#"{"schemaVersion":2,"series":[]}"#.utf8)
        let archive = try JSONDecoder().decode(MetricHistoryArchive.self, from: data)

        XCTAssertEqual(
            archive.queryNetworkTransfers(range: .hour, now: anchor),
            .empty(.hour)
        )
    }

    func testPersistedNetworkTransferBucketsStayBoundedToOneDay() {
        var archive = MetricHistoryArchive()
        for sample in 0...(25 * 60 * 4) {
            let end = TimeInterval(sample * 15)
            archive.recordNetworkTransfer(NetworkTransferDelta(
                interfaceName: "en0",
                start: anchor.addingTimeInterval(end - 15),
                end: anchor.addingTimeInterval(end),
                downloadBytes: 1,
                uploadBytes: 1
            ))
        }

        XCTAssertLessThanOrEqual(archive.persistedNetworkTransferBucketCount(), 5_761)
    }

    func testRetentionBoundsAreUnchangedAfterOptimization() {
        var archive = MetricHistoryArchive()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<20_000 {
            archive.record(
                .cpuUsage,
                value: 0.5,
                at: start.addingTimeInterval(Double(index) * 2)
            )
        }
        // 15 秒桶保留 1 小时 => 至多 240 个。
        XCTAssertLessThanOrEqual(
            archive.persistedBucketCount(for: .cpuUsage, range: .hour),
            240
        )
        // 30 分钟桶保留 7 天 => 至多 336 个。
        XCTAssertLessThanOrEqual(
            archive.persistedBucketCount(for: .cpuUsage, range: .week),
            336
        )
    }

    func testRetentionCutoffIsStrictlyLessThanAtExactBoundary() {
        // 上面的上界断言测不出「多裁了」——只会让计数更小，一样满足 <=。
        // 这里精确构造 cutoff 与某个桶时间戳恰好相等的边界，验证保留的是
        // 原本 `<` 的语义（恰好等于 cutoff 不算过期），而不是被静默改成 `<=`。
        var archive = MetricHistoryArchive()
        let base = Date(timeIntervalSince1970: 0)
        archive.record(.cpuUsage, value: 0.1, at: base)
        // cutoff = (base + 3600) - 3600 = base，与第一个桶的时间戳恰好相等。
        archive.record(.cpuUsage, value: 0.2, at: base.addingTimeInterval(3600))

        XCTAssertEqual(archive.persistedBucketCount(for: .cpuUsage, range: .hour), 2)
    }

    #if DEBUG
    func testRecordCallsDropExpiredPrefixForEveryTrimSite() {
        // record() 应该恰好触发 5 次 dropExpiredPrefix：live 数组 1 次 +
        // 4 个 tier 各 1 次。任何一个调用点被内联改写绕过 helper（哪怕改写
        // 后产出的数据完全正确），这个数字都会比 5 小，从而被测出来——
        // 这条 evaluationsPerRecord 之类的求值次数断言测不出来，因为绕过
        // 的调用点根本不会给求值计数器贡献任何数字，总数反而看起来更小。
        var archive = MetricHistoryArchive()
        let before = archive.dropExpiredPrefixCallCount
        archive.record(.cpuUsage, value: 0.5, at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(archive.dropExpiredPrefixCallCount - before, 5)
    }

    func testRecordNetworkTransferCallsDropExpiredPrefixForEveryTrimSite() {
        // recordNetworkTransfer() 应该恰好触发 2 次：liveNetworkTransfers +
        // networkTransferBuckets 各 1 次。理由同上。
        var archive = MetricHistoryArchive()
        let before = archive.dropExpiredPrefixCallCount
        archive.recordNetworkTransfer(NetworkTransferDelta(
            interfaceName: "en0",
            start: Date(timeIntervalSince1970: 1_700_000_000 - 1),
            end: Date(timeIntervalSince1970: 1_700_000_000),
            downloadBytes: 1,
            uploadBytes: 1
        ))
        XCTAssertEqual(archive.dropExpiredPrefixCallCount - before, 2)
    }

    func testRecordSteadyStateTrimmingEvaluationsStayAmortizedConstant() {
        var archive = MetricHistoryArchive()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // 先灌满到稳态：写入间隔 2 秒，40000 秒覆盖最短两层（1 小时 / 5 小时）的
        // 保留期，让它们进入「每次都有旧桶过期」的稳态；长的两层此时仍在增长，
        // 但增长阶段的裁剪只窥视头部一个未过期元素就退出，同样是 O(1)。
        for index in 0..<20_000 {
            archive.record(
                .cpuUsage,
                value: 0.5,
                at: start.addingTimeInterval(Double(index) * 2)
            )
        }

        let steadyStart = start.addingTimeInterval(40_000)
        let evaluationsBefore = archive.dropExpiredPrefixEvaluationCount
        let steadySteps = 5_000
        for index in 0..<steadySteps {
            archive.record(
                .cpuUsage,
                value: 0.5,
                at: steadyStart.addingTimeInterval(Double(index) * 2)
            )
        }
        let evaluationsPerRecord =
            Double(archive.dropExpiredPrefixEvaluationCount - evaluationsBefore) / Double(steadySteps)

        // 每次 record() 对 live 数组 + 4 个 tier 各调用一次 dropExpiredPrefix。
        // O(1) 摊还下，稳态每次求值次数应停留在个位数附近（每层探到第一个未
        // 过期元素就退出）；如果退化回全量扫描，会顶到数组长度量级（最长一
        // 层上限 336），所以阈值给到远低于该量级、但留够裕度的 20。
        XCTAssertLessThan(evaluationsPerRecord, 20)
    }

    func testRecordNetworkTransferSteadyStateTrimmingEvaluationsStayAmortizedConstant() {
        var archive = MetricHistoryArchive()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // 15 秒一个桶，24 小时保留 => 上限约 5760 个；先灌到上限附近进入稳态。
        let priorSamples = 8_000
        for sample in 0..<priorSamples {
            let end = TimeInterval(sample * 15)
            archive.recordNetworkTransfer(NetworkTransferDelta(
                interfaceName: "en0",
                start: start.addingTimeInterval(end - 15),
                end: start.addingTimeInterval(end),
                downloadBytes: 1,
                uploadBytes: 1
            ))
        }

        let steadyStartOffset = TimeInterval(priorSamples * 15)
        let evaluationsBefore = archive.dropExpiredPrefixEvaluationCount
        let steadySteps = 2_000
        for sample in 0..<steadySteps {
            let end = steadyStartOffset + TimeInterval(sample * 15)
            archive.recordNetworkTransfer(NetworkTransferDelta(
                interfaceName: "en0",
                start: start.addingTimeInterval(end - 15),
                end: start.addingTimeInterval(end),
                downloadBytes: 1,
                uploadBytes: 1
            ))
        }
        let evaluationsPerRecord =
            Double(archive.dropExpiredPrefixEvaluationCount - evaluationsBefore) / Double(steadySteps)

        // 每次 recordNetworkTransfer() 对 liveNetworkTransfers + networkTransferBuckets
        // 各调用一次 dropExpiredPrefix。全量扫描会顶到桶上限量级（约 5760），
        // O(1) 摊还应停留在个位数附近，阈值同样留足裕度。
        XCTAssertLessThan(evaluationsPerRecord, 20)
    }
    #endif

    private func transfer(
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        download: UInt64?,
        upload: UInt64?
    ) -> NetworkTransferDelta {
        NetworkTransferDelta(
            interfaceName: "en0",
            start: anchor.addingTimeInterval(startOffset),
            end: anchor.addingTimeInterval(endOffset),
            downloadBytes: download,
            uploadBytes: upload
        )
    }
}
