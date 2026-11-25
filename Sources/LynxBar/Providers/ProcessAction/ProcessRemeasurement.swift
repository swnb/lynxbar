import Foundation

enum ProcessTargetPostActionStatus: String, Codable, Sendable {
    case exited, stillRunning, pidReused, unknown
}
/// 独立于请求返回值的资源读数；未知不映射成“已退出”或“已缓解”。
struct ProcessResourceRemeasurement: Equatable, Sendable {
    let targetStatus: ProcessTargetPostActionStatus
    let memoryUsage: Double
    let swapUsedBytes: UInt64
    let cpuUsage: Double?
}
struct ProcessPostActionReport: Equatable, Sendable {
    let resources: ProcessResourceRemeasurement
    let currentContext: ProcessRemediationContext
    let applicationExited: Bool
    let systemIssueResolved: Bool
}
protocol ProcessResourceRemeasuring: Sendable {
    func measure(preparedTarget: ProcessActionTarget) async -> ProcessResourceRemeasurement
}
struct SystemProcessResourceRemeasurer: ProcessResourceRemeasuring {
    private let identityReader: any ProcessIdentityReading
    private let waiter: any ProcessActionWaiting
    init(identityReader: any ProcessIdentityReading = LibprocProcessIdentityReader(),
         waiter: any ProcessActionWaiting = SystemProcessActionWaiter()) {
        self.identityReader = identityReader
        self.waiter = waiter
    }
    func measure(preparedTarget: ProcessActionTarget) async -> ProcessResourceRemeasurement {
        let first = await Task.detached { CPUProvider.sample(previous: .empty) }.value
        await waiter.wait(for: .milliseconds(250))
        async let memory = Task.detached { MemoryProvider.sample() }.value
        async let cpu = Task.detached { CPUProvider.sample(previous: first.previous) }.value
        let status: ProcessTargetPostActionStatus
        switch await identityReader.status(for: preparedTarget.process.pid) {
        case .exited: status = .exited
        case .unavailable: status = .unknown
        case let .identified(identity):
            status = identity.sampleKey == preparedTarget.process.sampleKey ? .stillRunning : .pidReused
        }
        let memoryResult = await memory
        let cpuResult = await cpu
        return ProcessResourceRemeasurement(targetStatus: status, memoryUsage: memoryResult.usage,
            swapUsedBytes: memoryResult.swapUsed,
            cpuUsage: first.previous == .empty || cpuResult.previous == .empty ? nil : cpuResult.usage)
    }
}
enum ProcessPostActionReporter {
    static func report(resources: ProcessResourceRemeasurement, initialContext: ProcessRemediationContext,
                       currentContext: ProcessRemediationContext) -> ProcessPostActionReport {
        let memoryIssue = initialContext.memoryPressure == .warning || initialContext.memoryPressure == .critical
        let memoryResolved = !memoryIssue || currentContext.memoryPressure == .normal
        let cpuResolved = !initialContext.hasSustainedCPUIssue || (currentContext.hasCompleteCPUWindow && !currentContext.hasSustainedCPUIssue)
        return ProcessPostActionReport(resources: resources, currentContext: currentContext,
            applicationExited: resources.targetStatus == .exited || resources.targetStatus == .pidReused,
            systemIssueResolved: memoryResolved && cpuResolved)
    }
}
