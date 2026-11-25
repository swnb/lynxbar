import Foundation

/// libproc 启动时刻的精确字段，单位为秒与微秒（0..<1_000_000）。动作身份
/// 使用这两个字段；存量 CPU/图标缓存仍沿用自己的秒级键，避免迁移破坏差值。
struct ProcessStartTime: Hashable, Codable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64
}

struct ProcessSampleKey: Hashable, Codable, Sendable {
    let pid: Int32
    let startTime: ProcessStartTime
}

/// 动作边界的内核身份；UID 决定所有权，parent PID 仅用于说明依赖关系。
struct ProcessKernelIdentity: Hashable, Codable, Sendable {
    let pid: Int32
    let startTime: ProcessStartTime
    let ownerUID: UInt32
    let parentPID: Int32
    let name: String
    var sampleKey: ProcessSampleKey { ProcessSampleKey(pid: pid, startTime: startTime) }
}

enum RunningApplicationActivationPolicy: String, Codable, Sendable {
    case regular, accessory, prohibited, unknown
}

/// MainActor 上取得的 GUI 应用元数据值；绝不持有可执行动作的 AppKit 对象。
struct RunningApplicationSnapshot: Hashable, Codable, Sendable {
    let pid: Int32
    let bundleIdentifier: String?
    let localizedName: String?
    let bundleURL: URL?
    let executableURL: URL?
    let activationPolicy: RunningApplicationActivationPolicy
    let isTerminated: Bool
    var stableIdentifier: String? {
        if let value = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return "bundle:\(value.lowercased())"
        }
        return executableURL.map { "executable:\($0.standardizedFileURL.path)" }
    }
}

/// 预览和执行均绑定同一内核实例及 app 身份；parent PID 可在父进程退出时改变，
/// 因而不是动作身份的一部分。AppKit 对象只在最终同步检查中获取并保留。
struct ProcessActionTarget: Hashable, Codable, Sendable {
    let process: ProcessKernelIdentity
    let application: RunningApplicationSnapshot
    func matchesActionIdentity(_ other: Self) -> Bool {
        process.sampleKey == other.process.sampleKey
            && process.ownerUID == other.process.ownerUID
            && process.name == other.process.name
            && application.pid == other.application.pid
            && application.stableIdentifier == other.application.stableIdentifier
            && application.executableURL?.standardizedFileURL == other.application.executableURL?.standardizedFileURL
    }
}

enum ProcessActionIneligibilityReason: String, Codable, Sendable {
    case selfProcess, rootOwned, otherUser, commandLineOnly, identityIncomplete
    case protectedSystemRole, applicationTerminated, applicationIdentityChanged
}

enum ProcessActionEligibility: Equatable, Sendable {
    case eligible
    case ineligible(ProcessActionIneligibilityReason)
    var isEligible: Bool { self == .eligible }
}

enum ProcessActionKind: String, Codable, Sendable { case normalQuit, forceQuit }
enum ProcessActionOutcome: Equatable, Sendable {
    case exited, refused, timedOut, stale, unknown
    case ineligible(ProcessActionIneligibilityReason)
    case forceNotAuthorized
}

/// 只由执行器在正常退出拒绝/超时后签发。必须单次消费，30 秒后失效；UI
/// 还需以独立 force 风险确认取得 coordinator permit，两种 permit 不可互换。
struct ProcessForceQuitPermit: Hashable, Sendable {
    let id: UUID
    let targetKey: ProcessSampleKey
    let expiresAt: Date
}

struct ProcessActionResult: Equatable, Sendable {
    let kind: ProcessActionKind
    let outcome: ProcessActionOutcome
    /// 请求被接受与实例消失是两个独立事实，不能把 true 映射为已退出。
    let requestAccepted: Bool?
    let forceQuitPermit: ProcessForceQuitPermit?
}

enum ProcessSuggestionLevel: String, Codable, Sendable { case inspect, normalQuit }

/// 系统证据来自既有健康判定器。CPU 为完整 30 秒持续问题；swap 仅作说明，
/// 不把容量使用率或非零 swap 单独当成内存压力。physicalMemoryBytes 是阈值分母。
struct ProcessRemediationContext: Equatable, Sendable {
    let memoryPressure: MemoryPressureLevel
    let swapUsedBytes: UInt64
    let hasSustainedCPUIssue: Bool
    let physicalMemoryBytes: UInt64
    /// CPU 问题消失必须有完整最近窗口支持，缺数据不能当作恢复健康。
    let hasCompleteCPUWindow: Bool
    init(memoryPressure: MemoryPressureLevel, swapUsedBytes: UInt64, hasSustainedCPUIssue: Bool,
         physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory, hasCompleteCPUWindow: Bool = true) {
        self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes
        self.hasSustainedCPUIssue = hasSustainedCPUIssue
        self.physicalMemoryBytes = physicalMemoryBytes
        self.hasCompleteCPUWindow = hasCompleteCPUWindow
    }
    static let inspectionOnly = Self(memoryPressure: .unknown, swapUsedBytes: 0, hasSustainedCPUIssue: false, hasCompleteCPUWindow: false)
    static func current(cpuHistory: [MetricPoint], memoryPressure: MemoryPressureLevel,
                        swapUsedBytes: UInt64, now: Date = Date()) -> Self {
        let summary = SystemHealthEvaluator.evaluate(SystemHealthInput(
            cpuHistory: cpuHistory, memoryPressure: memoryPressure, diskFreeBytes: nil,
            diskTotalBytes: nil, hasPrimaryNetwork: nil, now: now
        ))
        let window = cpuHistory.filter { $0.timestamp <= now && $0.timestamp >= now.addingTimeInterval(-SystemHealthEvaluator.cpuWindow) }
        let complete = window.map(\.timestamp).max().flatMap { last in
            window.map(\.timestamp).min().map { last.timeIntervalSince($0) >= SystemHealthEvaluator.cpuWindow * 0.9 }
        } ?? false
        return Self(memoryPressure: memoryPressure, swapUsedBytes: swapUsedBytes,
                    hasSustainedCPUIssue: summary.issues.contains { $0.kind == .sustainedCPU || $0.kind == .criticalCPU },
                    hasCompleteCPUWindow: complete)
    }
    /// swap 的微小变化不使确认失效；问题类型/严重度变化则要求重新预览。
    func matchesIssueEvidence(_ other: Self) -> Bool {
        memoryPressure == other.memoryPressure && hasSustainedCPUIssue == other.hasSustainedCPUIssue
    }
}

struct ProcessContributionObservation: Hashable, Sendable {
    let target: ProcessActionTarget?
    let fallbackIdentity: ProcessKernelIdentity
    /// 整机容量比例 0...1，nil 表示没有差值基线。
    let cpuUsage: Double?
    let memoryBytes: UInt64
}

/// 仅聚合 CPU Top N ∪ Memory Top N 的观察集，绝不声称应用所有子进程总量。
/// 连续计数按精确目标实例隔离，应用重启不会继承旧实例的建议资格。
struct ApplicationContribution: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let processCount: Int
    let cpuUsage: Double
    let memoryBytes: UInt64
    let repeatedLeadingCPUCount: Int
    let repeatedLeadingMemoryCount: Int
    let actionTarget: ProcessActionTarget?
    let observedAt: Date
}
