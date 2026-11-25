import Foundation

/// CPU 采样结果。`previous` 保存原始 tick 数据，用于下次计算使用率差值。
struct CPUSnapshot: Sendable {
    /// 总体 CPU 使用率（0.0 ... 1.0）。
    var usage: Double = 0
    /// 各逻辑核心使用率（0.0 ... 1.0）。
    var perCoreUsage: [Double] = []
    /// Load average（1 / 5 / 15 分钟）。
    var loadAverage: (one: Double, five: Double, fifteen: Double) = (0, 0, 0)
    /// 系统运行时间（秒）。
    var uptime: TimeInterval = 0
    /// 用于下次差值计算的原始 tick 快照。
    var previous: CPUProvider.Raw = .empty
}

/// CPU 使用率采集（Mach API）。无状态，所有方法线程安全。
enum CPUProvider {
    /// 每核心的原始 tick 计数（user / system / nice / idle）。
    struct Raw: Sendable, Equatable {
        var ticksPerCore: [[UInt64]]
        var timestamp: Date

        static let empty = Raw(ticksPerCore: [], timestamp: .distantPast)
    }

    /// 采集一次 CPU 快照。传入上一次的 `Raw` 以计算使用率差值；
    /// 首次传入空快照时返回的使用率为 0。
    static func sample(previous: Raw) -> CPUSnapshot {
        var snapshot = CPUSnapshot()
        snapshot.previous = readPerCoreTicks()
        snapshot.loadAverage = readLoadAverage()
        snapshot.uptime = readUptime()

        // 计算「上一次 -> 现在」的增量使用率。
        if previous != .empty {
            snapshot.perCoreUsage = perCoreUsage(previous: previous, current: snapshot.previous)
            snapshot.usage = averageUsage(previous: previous, current: snapshot.previous)
        }
        return snapshot
    }

    private static func perCoreUsage(previous: Raw, current: Raw) -> [Double] {
        guard previous.ticksPerCore.count == current.ticksPerCore.count else {
            return Array(repeating: 0, count: current.ticksPerCore.count)
        }
        return zip(previous.ticksPerCore, current.ticksPerCore).map { oldTicks, newTicks in
            usageRatio(old: oldTicks, new: newTicks)
        }
    }

    private static func averageUsage(previous: Raw, current: Raw) -> Double {
        let cores = perCoreUsage(previous: previous, current: current)
        guard !cores.isEmpty else { return 0 }
        return cores.reduce(0, +) / Double(cores.count)
    }

    private static func usageRatio(old: [UInt64], new: [UInt64]) -> Double {
        guard old.count == new.count, old.count == 4 else { return 0 }
        let user = diff(old[0], new[0])
        let system = diff(old[1], new[1])
        let nice = diff(old[2], new[2])
        let idle = diff(old[3], new[3])
        let total = user + system + nice + idle
        guard total > 0 else { return 0 }
        return Double(total - idle) / Double(total)
    }

    private static func diff(_ a: UInt64, _ b: UInt64) -> UInt64 {
        b >= a ? b - a : 0
    }

    // MARK: - 底层读取

    private static func readPerCoreTicks() -> Raw {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t!
        var numCPUInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )
        guard result == KERN_SUCCESS, let info = cpuInfo else { return .empty }

        let stride = Int(CPU_STATE_MAX)
        var ticksPerCore: [[UInt64]] = []
        for index in 0..<Int(numCPUs) {
            let base = stride * index
            ticksPerCore.append([
                UInt64(info[base + Int(CPU_STATE_USER)]),
                UInt64(info[base + Int(CPU_STATE_SYSTEM)]),
                UInt64(info[base + Int(CPU_STATE_NICE)]),
                UInt64(info[base + Int(CPU_STATE_IDLE)]),
            ])
        }

        let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)

        return Raw(ticksPerCore: ticksPerCore, timestamp: Date())
    }

    private static func readLoadAverage() -> (Double, Double, Double) {
        var loads = [Double](repeating: 0, count: 3)
        let count = getloadavg(&loads, 3)
        guard count == 3 else { return (0, 0, 0) }
        return (loads[0], loads[1], loads[2])
    }

    private static func readUptime() -> TimeInterval {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        let result = sysctl(&mib, 2, &bootTime, &size, nil, 0)
        guard result == 0 else { return 0 }
        let bootDate = Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
        return max(0, Date().timeIntervalSince(bootDate))
    }
}
