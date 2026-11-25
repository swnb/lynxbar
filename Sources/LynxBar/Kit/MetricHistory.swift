import Darwin
import Foundation

enum HistoryRange: String, CaseIterable, Codable, Sendable, Identifiable {
    case minute = "1m"
    case hour = "1h"
    case fiveHours = "5h"
    case day = "1d"
    case week = "1w"

    var id: Self { self }

    var duration: TimeInterval {
        switch self {
        case .minute: return 60
        case .hour: return 60 * 60
        case .fiveHours: return 5 * 60 * 60
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        }
    }
}

enum MetricSeries: String, Codable, Sendable, CaseIterable {
    case cpuUsage
    case memoryUsage
    case diskCapacityUsage
    case networkDownload
    case networkUpload
}

struct MetricPoint: Codable, Sendable, Equatable, Identifiable {
    let timestamp: Date
    let value: Double

    var id: Date { timestamp }
}

struct MetricHistoryResult: Sendable, Equatable {
    let range: HistoryRange
    let points: [MetricPoint]
    let availableDuration: TimeInterval
    let isWarmingUp: Bool

    static func empty(_ range: HistoryRange) -> Self {
        Self(range: range, points: [], availableDuration: 0, isWarmingUp: true)
    }
}

/// 主接口连续采样间的真实字节差。
///
/// 每个方向独立可用：计数回退只让该方向变成 `nil`，不能把未知流量记成 0；
/// 合法的零差值仍保留，用于证明这个采样区间确实没有传输。
struct NetworkTransferDelta: Sendable, Equatable {
    let interfaceName: String
    let start: Date
    let end: Date
    let downloadBytes: UInt64?
    let uploadBytes: UInt64?

    var duration: TimeInterval {
        end.timeIntervalSince(start)
    }

    static func between(
        currentInterfaceName: String?,
        currentIn: UInt64,
        currentOut: UInt64,
        currentAt: Date,
        previousInterfaceName: String?,
        previousIn: UInt64,
        previousOut: UInt64,
        previousAt: Date?
    ) -> Self? {
        guard let currentInterfaceName,
              !currentInterfaceName.isEmpty,
              currentInterfaceName == previousInterfaceName,
              let previousAt,
              currentAt > previousAt else {
            return nil
        }

        let downloadBytes = currentIn >= previousIn ? currentIn - previousIn : nil
        let uploadBytes = currentOut >= previousOut ? currentOut - previousOut : nil
        guard downloadBytes != nil || uploadBytes != nil else { return nil }

        return Self(
            interfaceName: currentInterfaceName,
            start: previousAt,
            end: currentAt,
            downloadBytes: downloadBytes,
            uploadBytes: uploadBytes
        )
    }
}

enum NetworkTransferCoverageStatus: Sendable, Equatable {
    case collecting
    case partial
    case complete
    case unavailable
}

struct NetworkRangeTransferTotals: Sendable, Equatable {
    let range: HistoryRange
    let downloadBytes: UInt64?
    let uploadBytes: UInt64?
    let downloadCoveredDuration: TimeInterval
    let uploadCoveredDuration: TimeInterval
    let status: NetworkTransferCoverageStatus

    static func empty(
        _ range: HistoryRange,
        status: NetworkTransferCoverageStatus = .collecting
    ) -> Self {
        Self(
            range: range,
            downloadBytes: nil,
            uploadBytes: nil,
            downloadCoveredDuration: 0,
            uploadCoveredDuration: 0,
            status: status
        )
    }

    func markingUnavailableWhenEmpty() -> Self {
        guard status == .collecting else { return self }
        return Self(
            range: range,
            downloadBytes: downloadBytes,
            uploadBytes: uploadBytes,
            downloadCoveredDuration: downloadCoveredDuration,
            uploadCoveredDuration: uploadCoveredDuration,
            status: .unavailable
        )
    }
}

enum SamplingPolicy {
    static let historyWriteDebounce: Duration = .seconds(300)

    /// 退出路径等 flush 完成的上限。flush() 正常应在毫秒级完成；这个超时
    /// 只是防止磁盘异常等极端情况卡住 App 无法退出（Task C.2）。
    static let terminationFlushTimeout: Duration = .seconds(3)

    static func liveInterval(_ requested: TimeInterval) -> TimeInterval {
        [1, 2, 5, 10].contains(requested) ? requested : 2
    }

    static func diskCapacityInterval(_ cadence: DiskCapacityCadence) -> TimeInterval {
        cadence.rawValue
    }
}

private enum HistoryTier: String, Codable, Sendable, CaseIterable {
    case fifteenSeconds
    case oneMinute
    case fiveMinutes
    case thirtyMinutes

    var bucketWidth: TimeInterval {
        switch self {
        case .fifteenSeconds: return 15
        case .oneMinute: return 60
        case .fiveMinutes: return 5 * 60
        case .thirtyMinutes: return 30 * 60
        }
    }

    var retention: TimeInterval {
        switch self {
        case .fifteenSeconds: return 60 * 60
        case .oneMinute: return 5 * 60 * 60
        case .fiveMinutes: return 24 * 60 * 60
        case .thirtyMinutes: return 7 * 24 * 60 * 60
        }
    }

    static func tier(for range: HistoryRange) -> Self? {
        switch range {
        case .minute: return nil
        case .hour: return .fifteenSeconds
        case .fiveHours: return .oneMinute
        case .day: return .fiveMinutes
        case .week: return .thirtyMinutes
        }
    }
}

private struct AggregateBucket: Codable, Sendable, Equatable {
    let timestamp: Date
    var sum: Double
    var count: Int

    var average: Double { count > 0 ? sum / Double(count) : 0 }
}

private struct SeriesArchive: Codable, Sendable, Equatable {
    var tiers: [HistoryTier: [AggregateBucket]] = [:]
}

private struct NetworkTransferBucket: Codable, Sendable, Equatable {
    let timestamp: Date
    var downloadBytes: UInt64
    var uploadBytes: UInt64
    var downloadCoveredDuration: TimeInterval
    var uploadCoveredDuration: TimeInterval
}

/// 纯值归档模型。每条样本只进入真实时间桶；不插值、不补点。
///
/// `live` 有意不参与 Codable：重新启动后 1m 视图必须重新 warm up，
/// 不能把持久化聚合数据伪装成秒级实时历史。
struct MetricHistoryArchive: Codable, Sendable, Equatable {
    private static let currentSchemaVersion = 2
    private static let liveRetention: TimeInterval = 5 * 60
    private static let transferBucketWidth: TimeInterval = 15
    private static let transferRetention: TimeInterval = 24 * 60 * 60

    private var schemaVersion = currentSchemaVersion
    private var series: [MetricSeries: SeriesArchive] = [:]
    private var live: [MetricSeries: [MetricPoint]] = [:]
    private var networkTransferBuckets: [NetworkTransferBucket] = []
    private var liveNetworkTransfers: [NetworkTransferDelta] = []

    init() {}

    /// 显式实现而非交给编译器合成：下面 DEBUG 专用的调用/求值计数字段
    /// 不该参与相等性判断，否则 `==` 在 Debug / Release 构建下语义不一致。
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.series == rhs.series
            && lhs.live == rhs.live
            && lhs.networkTransferBuckets == rhs.networkTransferBuckets
            && lhs.liveNetworkTransfers == rhs.liveNetworkTransfers
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case series
        case networkTransferBuckets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported history schema \(version)"
            )
        }
        schemaVersion = version
        series = try container.decode([MetricSeries: SeriesArchive].self, forKey: .series)
        networkTransferBuckets = try container.decodeIfPresent(
            [NetworkTransferBucket].self,
            forKey: .networkTransferBuckets
        ) ?? []
        live = [:]
        liveNetworkTransfers = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(series, forKey: .series)
        try container.encode(networkTransferBuckets, forKey: .networkTransferBuckets)
    }

    #if DEBUG
    /// `dropExpiredPrefix` 被调用的次数。用于测试验证每一处调用点都真的在
    /// 走这个 helper——如果某处被内联改写绕过（比如换回 `removeAll`），
    /// 就算产出的数据完全正确，调用次数也会比预期少，从而被测出来。
    private(set) var dropExpiredPrefixCallCount = 0
    /// `dropExpiredPrefix` 循环体每执行一次（即每评估一次 `timestamp`）就计数一次。
    /// 用于测试验证摊还复杂度不随数组长度增长。
    private(set) var dropExpiredPrefixEvaluationCount = 0
    #endif

    /// 时间戳单调递增，过期元素恒在头部；只裁头，避免每次写入都全量扫描。
    ///
    /// 返回值是循环体对 `timestamp` 闭包的求值次数。Swift 的 `#if` 不能
    /// 拼在参数列表中间（试过、编译器拒绝），所以计数不走「多传两个 inout
    /// 参数」，而是让函数无条件算好、返回给调用方，由调用方在 `#if DEBUG`
    /// 里决定要不要累加进实例计数器；Release 下调用方直接丢弃返回值，
    /// 多出来的只是循环体内一次寄存器级的整数自增，可忽略不计。
    ///
    /// 两个计数器（见上）是 `MetricHistoryArchive` 的实例属性而不是
    /// `static`：这是值类型，每个实例天然有自己独立的存储，不会和其他
    /// 测试构造的 archive 实例共享可变状态（测试宿主里可能有已 cancel
    /// 但未 await 的采样任务残留一次 in-flight 写入，实例隔离让这类残留
    /// 不会跨实例污染计数）。
    @discardableResult
    private static func dropExpiredPrefix<T>(
        _ items: inout [T],
        cutoff: Date,
        timestamp: (T) -> Date
    ) -> Int {
        var expired = 0
        var evaluations = 0
        while expired < items.count {
            evaluations += 1
            guard timestamp(items[expired]) < cutoff else { break }
            expired += 1
        }
        if expired > 0 {
            items.removeFirst(expired)
        }
        return evaluations
    }

    mutating func record(_ metric: MetricSeries, value: Double, at timestamp: Date) {
        guard value.isFinite else { return }

        live[metric, default: []].append(MetricPoint(timestamp: timestamp, value: value))
        #if DEBUG
        dropExpiredPrefixCallCount += 1
        dropExpiredPrefixEvaluationCount += Self.dropExpiredPrefix(
            &live[metric]!,
            cutoff: timestamp.addingTimeInterval(-Self.liveRetention),
            timestamp: \.timestamp
        )
        #else
        Self.dropExpiredPrefix(
            &live[metric]!,
            cutoff: timestamp.addingTimeInterval(-Self.liveRetention),
            timestamp: \.timestamp
        )
        #endif

        var metricArchive = series[metric] ?? SeriesArchive()
        for tier in HistoryTier.allCases {
            var buckets = metricArchive.tiers[tier] ?? []
            let bucketTime = floor(timestamp.timeIntervalSince1970 / tier.bucketWidth) * tier.bucketWidth
            let bucketDate = Date(timeIntervalSince1970: bucketTime)

            if let last = buckets.indices.last, buckets[last].timestamp == bucketDate {
                buckets[last].sum += value
                buckets[last].count += 1
            } else {
                buckets.append(AggregateBucket(timestamp: bucketDate, sum: value, count: 1))
            }

            let cutoff = timestamp.addingTimeInterval(-tier.retention)
            #if DEBUG
            dropExpiredPrefixCallCount += 1
            dropExpiredPrefixEvaluationCount += Self.dropExpiredPrefix(
                &buckets,
                cutoff: cutoff,
                timestamp: \.timestamp
            )
            #else
            Self.dropExpiredPrefix(&buckets, cutoff: cutoff, timestamp: \.timestamp)
            #endif
            metricArchive.tiers[tier] = buckets
        }
        series[metric] = metricArchive
    }

    mutating func recordNetworkTransfer(_ delta: NetworkTransferDelta) {
        guard delta.duration.isFinite, delta.duration > 0 else { return }

        liveNetworkTransfers.append(delta)
        #if DEBUG
        dropExpiredPrefixCallCount += 1
        dropExpiredPrefixEvaluationCount += Self.dropExpiredPrefix(
            &liveNetworkTransfers,
            cutoff: delta.end.addingTimeInterval(-Self.liveRetention),
            timestamp: \.end
        )
        #else
        Self.dropExpiredPrefix(
            &liveNetworkTransfers,
            cutoff: delta.end.addingTimeInterval(-Self.liveRetention),
            timestamp: \.end
        )
        #endif

        let bucketTime = floor(
            delta.end.timeIntervalSince1970 / Self.transferBucketWidth
        ) * Self.transferBucketWidth
        let bucketDate = Date(timeIntervalSince1970: bucketTime)

        if let last = networkTransferBuckets.indices.last,
           networkTransferBuckets[last].timestamp == bucketDate {
            Self.add(delta, to: &networkTransferBuckets[last])
        } else {
            var bucket = NetworkTransferBucket(
                timestamp: bucketDate,
                downloadBytes: 0,
                uploadBytes: 0,
                downloadCoveredDuration: 0,
                uploadCoveredDuration: 0
            )
            Self.add(delta, to: &bucket)
            networkTransferBuckets.append(bucket)
        }

        let cutoff = delta.end.addingTimeInterval(-Self.transferRetention)
        #if DEBUG
        dropExpiredPrefixCallCount += 1
        dropExpiredPrefixEvaluationCount += Self.dropExpiredPrefix(
            &networkTransferBuckets,
            cutoff: cutoff,
            timestamp: \.timestamp
        )
        #else
        Self.dropExpiredPrefix(&networkTransferBuckets, cutoff: cutoff, timestamp: \.timestamp)
        #endif
    }

    func query(_ metric: MetricSeries, range: HistoryRange, now: Date) -> MetricHistoryResult {
        let cutoff = now.addingTimeInterval(-range.duration)
        let points: [MetricPoint]

        if let tier = HistoryTier.tier(for: range) {
            points = (series[metric]?.tiers[tier] ?? [])
                .lazy
                .filter { $0.timestamp >= cutoff && $0.timestamp <= now }
                .map { MetricPoint(timestamp: $0.timestamp, value: $0.average) }
        } else {
            points = (live[metric] ?? []).filter {
                $0.timestamp >= cutoff && $0.timestamp <= now
            }
        }

        let available = points.first.map {
            min(range.duration, max(0, now.timeIntervalSince($0.timestamp)))
        } ?? 0

        return MetricHistoryResult(
            range: range,
            points: points,
            availableDuration: available,
            isWarmingUp: available < range.duration * 0.9
        )
    }

    func queryNetworkTransfers(
        range: HistoryRange,
        now: Date
    ) -> NetworkRangeTransferTotals {
        let cutoff = now.addingTimeInterval(-range.duration)
        let downloadBytes: UInt64?
        let uploadBytes: UInt64?
        let downloadCoverage: TimeInterval
        let uploadCoverage: TimeInterval

        if range == .minute {
            let deltas = liveNetworkTransfers.filter {
                $0.end > cutoff && $0.end <= now
            }
            (downloadBytes, downloadCoverage) = Self.sumDirection(
                deltas.compactMap { delta in
                    delta.downloadBytes.map { ($0, delta.duration) }
                }
            )
            (uploadBytes, uploadCoverage) = Self.sumDirection(
                deltas.compactMap { delta in
                    delta.uploadBytes.map { ($0, delta.duration) }
                }
            )
        } else {
            // 字节差归属其结束时间所在的 15 秒桶。左边界最多包含一个边界桶，
            // 比从 1/5 分钟平均速率积分更可控，同时把持久化规模限制在约 5760 桶。
            let bucketCutoff = floor(
                cutoff.timeIntervalSince1970 / Self.transferBucketWidth
            ) * Self.transferBucketWidth
            let buckets = networkTransferBuckets.filter {
                $0.timestamp.timeIntervalSince1970 >= bucketCutoff
                    && $0.timestamp <= now
            }
            (downloadBytes, downloadCoverage) = Self.sumDirection(
                buckets.compactMap { bucket in
                    bucket.downloadCoveredDuration > 0
                        ? (bucket.downloadBytes, bucket.downloadCoveredDuration)
                        : nil
                }
            )
            (uploadBytes, uploadCoverage) = Self.sumDirection(
                buckets.compactMap { bucket in
                    bucket.uploadCoveredDuration > 0
                        ? (bucket.uploadBytes, bucket.uploadCoveredDuration)
                        : nil
                }
            )
        }

        let boundedDownloadCoverage = min(range.duration, downloadCoverage)
        let boundedUploadCoverage = min(range.duration, uploadCoverage)
        let hasCoverage = boundedDownloadCoverage > 0 || boundedUploadCoverage > 0
        let completeThreshold = range.duration * 0.9
        let status: NetworkTransferCoverageStatus
        if boundedDownloadCoverage >= completeThreshold,
           boundedUploadCoverage >= completeThreshold {
            status = .complete
        } else if hasCoverage {
            status = .partial
        } else {
            status = .collecting
        }

        return NetworkRangeTransferTotals(
            range: range,
            downloadBytes: downloadBytes,
            uploadBytes: uploadBytes,
            downloadCoveredDuration: boundedDownloadCoverage,
            uploadCoveredDuration: boundedUploadCoverage,
            status: status
        )
    }

    func persistedBucketCount(for metric: MetricSeries, range: HistoryRange) -> Int {
        guard let tier = HistoryTier.tier(for: range) else { return 0 }
        return series[metric]?.tiers[tier]?.count ?? 0
    }

    func persistedNetworkTransferBucketCount() -> Int {
        networkTransferBuckets.count
    }

    private static func add(
        _ delta: NetworkTransferDelta,
        to bucket: inout NetworkTransferBucket
    ) {
        if let downloadBytes = delta.downloadBytes {
            let addition = bucket.downloadBytes.addingReportingOverflow(downloadBytes)
            if !addition.overflow {
                bucket.downloadBytes = addition.partialValue
                bucket.downloadCoveredDuration += delta.duration
            }
        }
        if let uploadBytes = delta.uploadBytes {
            let addition = bucket.uploadBytes.addingReportingOverflow(uploadBytes)
            if !addition.overflow {
                bucket.uploadBytes = addition.partialValue
                bucket.uploadCoveredDuration += delta.duration
            }
        }
    }

    private static func sumDirection(
        _ values: [(bytes: UInt64, duration: TimeInterval)]
    ) -> (bytes: UInt64?, duration: TimeInterval) {
        guard !values.isEmpty else { return (nil, 0) }
        var total: UInt64 = 0
        var duration: TimeInterval = 0
        for value in values {
            let addition = total.addingReportingOverflow(value.bytes)
            guard !addition.overflow else { return (nil, 0) }
            total = addition.partialValue
            duration += value.duration
        }
        return (total, duration)
    }
}

actor MetricHistoryStore {
    static let shared = MetricHistoryStore()

    private let fileURL: URL?
    private var archive: MetricHistoryArchive
    private var isDirty = false
    private var isLoaded = false
    private var pendingSave: Task<Void, Never>?

    init(fileURL: URL? = MetricHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.archive = MetricHistoryArchive()
    }

    /// 显式加载，替代原先 init 里的同步读盘 + 解码。
    ///
    /// `MetricHistoryStore.shared` 会通过多个 ViewModel 初始化参数默认值
    /// （`historyStore: MetricHistoryStore = .shared`）在 AppDelegate 构造
    /// stored property 时被首次触发，发生在主线程的 App 启动路径上；本机
    /// 实测归档文件已达 1.1 MB，同步读盘 + 解码会阻塞主线程。调用方必须
    /// 等 load() 完成后再启动采样，否则首批样本会先写进空归档，随后被
    /// 这里加载的内容覆盖掉。
    ///
    /// 只在首次调用时生效：重复调用是 no-op，不会用磁盘内容覆盖已经在
    /// 内存里的状态（这也是迁移只做一次的保证之一）。
    func load() async {
        guard let fileURL, !isLoaded else { return }
        isLoaded = true

        do {
            let data = try Data(contentsOf: fileURL)
            do {
                archive = try PropertyListDecoder().decode(MetricHistoryArchive.self, from: data)
            } catch {
                Log.history.error(
                    "Failed to decode metric history archive at \(fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
                )
                preserveUnreadableFile(at: fileURL)
            }
            return
        } catch where !Self.isMissingFileError(error) {
            Log.history.error(
                "Failed to read metric history archive at \(fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            return
        } catch {
            // Expected on first launch before a history archive exists.
        }

        migrateLegacyArchiveIfPresent(besideNewFile: fileURL)
    }

    /// 新格式文件不存在时，一次性尝试从旧版 JSON 归档（history-v2.json）
    /// 迁移，避免旧用户的历史无声消失。迁移成功后旧文件改名保留（不删），
    /// 新文件写入磁盘；下次启动 load() 会在上面的分支里直接读到新文件，
    /// 不会再走到这里，因此迁移只发生一次。
    private func migrateLegacyArchiveIfPresent(besideNewFile newFileURL: URL) {
        let legacyURL = newFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("history-v2.json", isDirectory: false)
        let legacyData: Data
        do {
            legacyData = try Data(contentsOf: legacyURL)
        } catch where !Self.isMissingFileError(error) {
            Log.history.warning(
                "Failed to read legacy history archive at \(legacyURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            return
        } catch {
            return
        }

        let migrated: MetricHistoryArchive
        do {
            migrated = try JSONDecoder().decode(MetricHistoryArchive.self, from: legacyData)
        } catch {
            Log.history.error(
                "Failed to decode legacy history archive at \(legacyURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            preserveUnreadableFile(at: legacyURL)
            return
        }

        archive = migrated
        isDirty = true
        do {
            try persistIfNeeded()
        } catch {
            // 新文件没写成功：不动旧文件，留着 isDirty 状态给下次启动重试迁移。
            Log.history.error(
                "Failed to persist migrated history archive: \(error.localizedDescription, privacy: .private)"
            )
            return
        }

        let backup = legacyURL.appendingPathExtension("migrated")
        Self.removeBackupIfPresent(at: backup)
        do {
            try FileManager.default.moveItem(at: legacyURL, to: backup)
        } catch {
            Log.history.warning(
                "Failed to rename migrated history archive to \(backup.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    /// 无法解析的文件不静默丢弃：改名保留一份并记录诊断日志，再从空归档开始。
    private func preserveUnreadableFile(at fileURL: URL) {
        let backup = fileURL.appendingPathExtension("corrupt")
        Self.removeBackupIfPresent(at: backup)
        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
        } catch {
            Log.history.warning(
                "Failed to preserve unreadable history archive at \(backup.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
        }
        archive = MetricHistoryArchive()
    }

    func record(_ metric: MetricSeries, value: Double, at timestamp: Date = Date()) {
        archive.record(metric, value: value, at: timestamp)
        isDirty = true
        scheduleSaveIfNeeded()
    }

    func recordNetworkTransfer(_ delta: NetworkTransferDelta) {
        archive.recordNetworkTransfer(delta)
        isDirty = true
        scheduleSaveIfNeeded()
    }

    func query(
        _ metric: MetricSeries,
        range: HistoryRange,
        now: Date = Date()
    ) -> MetricHistoryResult {
        archive.query(metric, range: range, now: now)
    }

    func queryNetworkTransfers(
        range: HistoryRange,
        now: Date = Date()
    ) -> NetworkRangeTransferTotals {
        archive.queryNetworkTransfers(range: range, now: now)
    }

    func flush() throws {
        pendingSave?.cancel()
        pendingSave = nil
        try persistIfNeeded()
    }

    private func scheduleSaveIfNeeded() {
        guard pendingSave == nil, fileURL != nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: SamplingPolicy.historyWriteDebounce)
            guard !Task.isCancelled else { return }
            await self?.persistScheduledSave()
        }
    }

    /// Persists debounced history updates after the write timer completes, logging any I/O failure.
    private func persistScheduledSave() {
        pendingSave = nil
        do {
            try persistIfNeeded()
        } catch {
            Log.history.error(
                "Failed to persist scheduled metric history: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func persistIfNeeded() throws {
        guard isDirty, let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(archive)
        try data.write(to: fileURL, options: .atomic)
        isDirty = false
    }

    /// Returns `true` when an I/O error indicates the target file simply does not exist yet.
    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError)
            || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
    }

    /// Removes a stale backup file if present, logging unexpected errors while ignoring missing files.
    private static func removeBackupIfPresent(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch where !isMissingFileError(error) {
            Log.history.warning(
                "Failed to remove stale history backup at \(url.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
        } catch {
            // Expected when no prior backup file exists.
        }
    }

    private static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("LynxBar", isDirectory: true)
            .appendingPathComponent("history-v3.plist", isDirectory: false)
    }
}
