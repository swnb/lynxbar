import Foundation

enum MemoryPressureLevel: String, Codable, Sendable {
    case unknown
    case normal
    case warning
    case critical
}

enum HealthSeverity: Int, Codable, Sendable, Comparable {
    case collecting
    case healthy
    case attention
    case critical

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum HealthIssueKind: String, Codable, Sendable {
    case sustainedCPU
    case criticalCPU
    case memoryPressureWarning
    case memoryPressureCritical
    case lowDisk
    case criticalDisk
    case networkUnavailable
    case thermalFair
    case thermalSerious
    case thermalCritical
}

struct HealthIssue: Identifiable, Codable, Sendable, Equatable {
    let kind: HealthIssueKind
    let severity: HealthSeverity
    let measuredValue: Double?

    var id: HealthIssueKind { kind }
}

struct SystemHealthInput: Sendable {
    var cpuHistory: [MetricPoint]
    var memoryPressure: MemoryPressureLevel
    var diskFreeBytes: UInt64?
    var diskTotalBytes: UInt64?
    var hasPrimaryNetwork: Bool?
    var now: Date
    /// 仅公开 ProcessInfo 热状态可影响健康严重度；数值温度仅供上下文，不能
    /// 推算该状态。默认 unknown 保持已有调用者与缺少通知订阅时的语义。
    var thermalState: SystemThermalState = .unknown
}

struct SystemHealthSummary: Sendable, Equatable {
    let severity: HealthSeverity
    let issues: [HealthIssue]
}

enum SystemHealthEvaluator {
    static let cpuWindow: TimeInterval = 30
    static let cpuAttentionThreshold = 0.85
    static let cpuCriticalThreshold = 0.95
    static let diskAttentionFraction = 0.15
    static let diskCriticalFraction = 0.05
    static let diskAttentionBytes: UInt64 = 30 * 1_000_000_000
    static let diskCriticalBytes: UInt64 = 10 * 1_000_000_000

    static func evaluate(_ input: SystemHealthInput) -> SystemHealthSummary {
        var issues: [HealthIssue] = []

        if let cpu = sustainedCPUAverage(input.cpuHistory, now: input.now) {
            if cpu >= cpuCriticalThreshold {
                issues.append(HealthIssue(
                    kind: .criticalCPU,
                    severity: .critical,
                    measuredValue: cpu
                ))
            } else if cpu >= cpuAttentionThreshold {
                issues.append(HealthIssue(
                    kind: .sustainedCPU,
                    severity: .attention,
                    measuredValue: cpu
                ))
            }
        }

        switch input.memoryPressure {
        case .warning:
            issues.append(HealthIssue(
                kind: .memoryPressureWarning,
                severity: .attention,
                measuredValue: nil
            ))
        case .critical:
            issues.append(HealthIssue(
                kind: .memoryPressureCritical,
                severity: .critical,
                measuredValue: nil
            ))
        case .unknown, .normal:
            break
        }

        if let free = input.diskFreeBytes,
           let total = input.diskTotalBytes,
           total > 0 {
            let fraction = Double(free) / Double(total)
            if fraction <= diskCriticalFraction || free <= diskCriticalBytes {
                issues.append(HealthIssue(
                    kind: .criticalDisk,
                    severity: .critical,
                    measuredValue: Double(free)
                ))
            } else if fraction <= diskAttentionFraction || free <= diskAttentionBytes {
                issues.append(HealthIssue(
                    kind: .lowDisk,
                    severity: .attention,
                    measuredValue: Double(free)
                ))
            }
        }

        if input.hasPrimaryNetwork == false {
            issues.append(HealthIssue(
                kind: .networkUnavailable,
                severity: .attention,
                measuredValue: nil
            ))
        }

        switch input.thermalState {
        case .fair:
            issues.append(HealthIssue(kind: .thermalFair, severity: .attention, measuredValue: nil))
        case .serious:
            issues.append(HealthIssue(kind: .thermalSerious, severity: .attention, measuredValue: nil))
        case .critical:
            issues.append(HealthIssue(kind: .thermalCritical, severity: .critical, measuredValue: nil))
        case .unknown, .nominal:
            break
        }

        issues.sort {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.kind.rawValue < $1.kind.rawValue
        }

        let isReady = !input.cpuHistory.isEmpty
            && input.memoryPressure != .unknown
            && input.diskTotalBytes != nil
            && input.hasPrimaryNetwork != nil
        let severity = issues.first?.severity ?? (isReady ? .healthy : .collecting)
        return SystemHealthSummary(severity: severity, issues: issues)
    }

    private static func sustainedCPUAverage(_ samples: [MetricPoint], now: Date) -> Double? {
        let cutoff = now.addingTimeInterval(-cpuWindow)
        let window = samples
            .filter { $0.timestamp >= cutoff && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = window.first,
              let last = window.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= cpuWindow * 0.9 else {
            return nil
        }
        return window.map(\.value).reduce(0, +) / Double(window.count)
    }
}
