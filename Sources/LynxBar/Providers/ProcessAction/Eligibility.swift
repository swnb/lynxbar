import Foundation

/// 第一版只接受当前用户、身份完整且非受保护的 GUI app；拒绝系统桌面角色，
/// 名称与 bundle ID 双重名单避免未打包/元数据缺失绕过。没有 signal 动作出口。
struct ProcessActionEligibilityPolicy: Sendable {
    let currentUID: UInt32
    let lynxBarPID: Int32
    let lynxBarBundleIdentifier: String

    private let protectedBundleIdentifiers: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.windowmanager",
    ]

    private let protectedProcessNames: Set<String> = [
        "ControlCenter",
        "Dock",
        "Finder",
        "WindowServer",
        "loginwindow",
        "SystemUIServer",
    ]

    init(
        currentUID: UInt32 = getuid(),
        lynxBarPID: Int32 = getpid(),
        lynxBarBundleIdentifier: String = Bundle.main.bundleIdentifier
            ?? "com.swnb.LynxBar"
    ) {
        self.currentUID = currentUID
        self.lynxBarPID = lynxBarPID
        self.lynxBarBundleIdentifier = lynxBarBundleIdentifier
    }

    func evaluate(_ target: ProcessActionTarget) -> ProcessActionEligibility {
        if target.process.pid == lynxBarPID
            || target.application.bundleIdentifier == lynxBarBundleIdentifier {
            return .ineligible(.selfProcess)
        }
        if target.process.ownerUID == 0 {
            return .ineligible(.rootOwned)
        }
        if target.process.ownerUID != currentUID {
            return .ineligible(.otherUser)
        }
        if target.application.isTerminated {
            return .ineligible(.applicationTerminated)
        }
        guard target.process.pid > 0, target.process.startTime.seconds > 0,
              target.process.startTime.microseconds < 1_000_000,
              target.application.pid == target.process.pid,
              target.application.stableIdentifier != nil else {
            return .ineligible(.identityIncomplete)
        }
        guard target.application.activationPolicy == .regular
                || target.application.activationPolicy == .accessory else {
            return .ineligible(.commandLineOnly)
        }

        let bundleIdentifier = target.application.bundleIdentifier?.lowercased()
        if let bundleIdentifier,
           protectedBundleIdentifiers.contains(bundleIdentifier) {
            return .ineligible(.protectedSystemRole)
        }
        if protectedProcessNames.contains(target.process.name)
            || protectedProcessNames.contains(target.application.localizedName ?? "") {
            return .ineligible(.protectedSystemRole)
        }
        return .eligible
    }
}

enum ProcessRemediationSuggestionPolicy {
    /// 产品默认阈值：整机 CPU 容量的5%；驻留内存至少512MiB且至少物理内存的5%。
    /// 两个条件在连续两轮观察中均应成立；排名只提供贡献证据，系统异常另行判断。
    static let minimumCPUContribution = 0.05
    static let minimumResidentBytes: UInt64 = 512 * 1_024 * 1_024
    static let minimumMemoryFraction = 0.05
    /// 高排名只说明值得检查。只有系统上下文异常且同一应用连续贡献时，
    /// 才提升为可由用户发起的正常退出建议。
    static func level(
        for contribution: ApplicationContribution,
        context: ProcessRemediationContext
    ) -> ProcessSuggestionLevel {
        let repeatedMemoryContributor = contribution.repeatedLeadingMemoryCount >= 2
            && contribution.memoryBytes >= minimumResidentBytes
            && context.physicalMemoryBytes > 0
            && Double(contribution.memoryBytes) >= Double(context.physicalMemoryBytes) * minimumMemoryFraction
        let repeatedCPUContributor = contribution.repeatedLeadingCPUCount >= 2
            && contribution.cpuUsage >= minimumCPUContribution
        let elevatedMemoryContext = context.memoryPressure == .warning
            || context.memoryPressure == .critical

        if (elevatedMemoryContext && repeatedMemoryContributor)
            || (context.hasSustainedCPUIssue && repeatedCPUContributor) {
            return .normalQuit
        }
        return .inspect
    }
}
