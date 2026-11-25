import Foundation

/// 进程级网络归因使用系统 `nettop` 的外部接口累计计数。
///
/// Darwin 的公开 `libproc` 资源结构不包含网络字节，因此这里把系统工具
/// 隔离成一个严格、可降级的边界：输出格式不兼容时宁可报告 unavailable，
/// 也不能把缺失数据伪装成当前进程没有流量。
enum NetworkProcessProvider {
    struct Counter: Sendable, Equatable {
        let pid: Int32
        let processName: String
        let receivedBytes: UInt64
        let sentBytes: UInt64
    }

    struct Usage: Sendable, Equatable, Identifiable {
        let pid: Int32
        let name: String
        let downloadBytesPerSecond: Double
        let uploadBytesPerSecond: Double

        var id: Int32 { pid }
        var totalBytesPerSecond: Double {
            downloadBytesPerSecond + uploadBytesPerSecond
        }

        func replacingName(with displayName: String) -> Self {
            Self(
                pid: pid,
                name: displayName,
                downloadBytesPerSecond: downloadBytesPerSecond,
                uploadBytesPerSecond: uploadBytesPerSecond
            )
        }
    }

    enum Snapshot: Sendable, Equatable {
        case success([Counter])
        case unavailable
    }

    /// Samples cumulative per-process external network byte counters using `/usr/bin/nettop`.
    static func sample() -> Snapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = [
            "-P",
            "-L", "1",
            "-J", "bytes_in,bytes_out",
            "-n",
            "-x",
            "-t", "external",
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            // 先持续排空 stdout，再等待退出，避免进程很多时管道容量造成互等。
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8),
                  let counters = parseCSV(text) else {
                Log.network.warning(
                    "nettop process attribution unavailable (exit status \(process.terminationStatus, privacy: .public))"
                )
                return .unavailable
            }
            return .success(counters)
        } catch {
            Log.network.error(
                "Failed to run nettop for process attribution: \(error.localizedDescription, privacy: .private)"
            )
            return .unavailable
        }
    }

    /// 解析 `nettop -L` 的 CSV。首列标题为空，数据形如
    /// `Google Chrome H.123,1024,512,`；进程名可能包含逗号和引号。
    static func parseCSV(_ text: String) -> [Counter]? {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let headerLine = lines.first,
              let headers = parseCSVLine(headerLine),
              let receivedIndex = headers.firstIndex(of: "bytes_in"),
              let sentIndex = headers.firstIndex(of: "bytes_out") else {
            return nil
        }

        var countersByPID: [Int32: Counter] = [:]
        for line in lines.dropFirst() {
            guard let fields = parseCSVLine(line),
                  fields.indices.contains(receivedIndex),
                  fields.indices.contains(sentIndex),
                  let identity = parseIdentity(fields[0]),
                  let received = UInt64(fields[receivedIndex]),
                  let sent = UInt64(fields[sentIndex]) else {
                continue
            }
            countersByPID[identity.pid] = Counter(
                pid: identity.pid,
                processName: identity.name,
                receivedBytes: received,
                sentBytes: sent
            )
        }

        guard !countersByPID.isEmpty else { return nil }
        return countersByPID.values.sorted { $0.pid < $1.pid }
    }

    static func rates(
        current: [Counter],
        previous: [Int32: Counter],
        elapsed: TimeInterval
    ) -> [Usage] {
        guard elapsed.isFinite, elapsed > 0 else { return [] }

        return current.compactMap { counter -> Usage? in
            guard let baseline = previous[counter.pid],
                  baseline.processName == counter.processName else {
                return nil
            }

            let receivedDelta = counter.receivedBytes >= baseline.receivedBytes
                ? counter.receivedBytes - baseline.receivedBytes
                : 0
            let sentDelta = counter.sentBytes >= baseline.sentBytes
                ? counter.sentBytes - baseline.sentBytes
                : 0
            guard receivedDelta > 0 || sentDelta > 0 else { return nil }

            return Usage(
                pid: counter.pid,
                name: counter.processName,
                downloadBytesPerSecond: Double(receivedDelta) / elapsed,
                uploadBytesPerSecond: Double(sentDelta) / elapsed
            )
        }
        .sorted {
            if $0.totalBytesPerSecond != $1.totalBytesPerSecond {
                return $0.totalBytesPerSecond > $1.totalBytesPerSecond
            }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.pid < $1.pid
        }
    }

    static func countersByPID(_ counters: [Counter]) -> [Int32: Counter] {
        Dictionary(counters.map { ($0.pid, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private static func parseIdentity(_ field: String) -> (name: String, pid: Int32)? {
        let value = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = value.lastIndex(of: "."),
              separator > value.startIndex,
              let pid = Int32(value[value.index(after: separator)...]),
              pid > 0 else {
            return nil
        }
        let name = String(value[..<separator])
        guard !name.isEmpty else { return nil }
        return (name, pid)
    }

    private static func parseCSVLine(_ line: Substring) -> [String]? {
        let characters = Array(line)
        var fields: [String] = []
        var current = ""
        var isQuoted = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if isQuoted,
                   index + 1 < characters.count,
                   characters[index + 1] == "\"" {
                    current.append("\"")
                    index += 2
                    continue
                }
                isQuoted.toggle()
            } else if character == ",", !isQuoted {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }

        guard !isQuoted else { return nil }
        fields.append(current)
        return fields
    }
}

enum NetworkProcessAttributionAvailability: Sendable, Equatable {
    case collecting
    case ready
    case unavailable
}

/// 把节流、失败恢复和成功快照时间集中为纯状态机，避免 ViewModel 中出现
/// “失败后用错误间隔算速率”或重叠启动 `nettop` 的隐蔽分支。
struct NetworkProcessAttributionTracker: Sendable {
    private(set) var availability: NetworkProcessAttributionAvailability = .collecting
    private(set) var usages: [NetworkProcessProvider.Usage] = []
    private(set) var isAttemptInFlight = false

    private var previousCounters: [Int32: NetworkProcessProvider.Counter] = [:]
    private var lastAttemptAt: Date?
    private var lastSuccessAt: Date?

    mutating func beginAttempt(
        at timestamp: Date,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard !isAttemptInFlight else { return false }
        if let lastAttemptAt,
           timestamp.timeIntervalSince(lastAttemptAt) < minimumInterval {
            return false
        }
        lastAttemptAt = timestamp
        isAttemptInFlight = true
        return true
    }

    mutating func finish(
        _ snapshot: NetworkProcessProvider.Snapshot,
        at timestamp: Date
    ) {
        isAttemptInFlight = false

        switch snapshot {
        case let .success(counters):
            if let lastSuccessAt {
                usages = NetworkProcessProvider.rates(
                    current: counters,
                    previous: previousCounters,
                    elapsed: timestamp.timeIntervalSince(lastSuccessAt)
                )
                availability = .ready
            } else {
                usages = []
                availability = .collecting
            }
            previousCounters = NetworkProcessProvider.countersByPID(counters)
            lastSuccessAt = timestamp
        case .unavailable:
            usages = []
            availability = .unavailable
        }
    }

    mutating func cancelAttempt() {
        isAttemptInFlight = false
    }
}
