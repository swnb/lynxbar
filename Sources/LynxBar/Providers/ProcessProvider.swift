import Foundation

/// 进程采集（libproc）。无状态，线程安全。
enum ProcessProvider {
    /// 进程身份。仅用 pid 不足以识别 —— pid 会被复用，
    /// 沿用旧进程的 CPU 时间基线会算出错误的差值（且因 current < previous
    /// 而静默变成 0%，把「不知道」显示成「空闲」）。
    /// 口径与 design.md 既定的「PID + start time」一致。
    struct ProcessIdentity: Hashable, Sendable {
        let pid: Int32
        /// 进程启动时刻（秒）。来自 `proc_bsdinfo.pbi_start_tvsec`。
        let startTime: UInt64
    }

    struct RawProcess: Sendable {
        let identity: ProcessIdentity
        let name: String
        let cpuTimeNs: UInt64
        let prevCpuTimeNs: UInt64?
        let memoryBytes: UInt64
        /// 动作精确身份；存量测试/网络显示可省略，不能用秒级缓存 identity 伪造。
        let actionIdentity: ProcessKernelIdentity?

        init(identity: ProcessIdentity, name: String, cpuTimeNs: UInt64, prevCpuTimeNs: UInt64?,
             memoryBytes: UInt64, actionIdentity: ProcessKernelIdentity? = nil) {
            self.identity = identity
            self.name = name
            self.cpuTimeNs = cpuTimeNs
            self.prevCpuTimeNs = prevCpuTimeNs
            self.memoryBytes = memoryBytes
            self.actionIdentity = actionIdentity
        }
    }

    /// 计算单个进程在 `elapsed` 秒内的 CPU 占用（0...1）。
    ///
    /// 无基线（进程首次出现）返回 nil —— 此时 `current` 是进程自启动以来的
    /// 全部 CPU 时间，当作本次窗口的用量会得到 100%，是错的。
    static func cpuUsage(
        current: UInt64,
        previous: UInt64?,
        elapsed: TimeInterval,
        cores: Int
    ) -> Double? {
        guard let previous, elapsed.isFinite, elapsed > 0, cores > 0 else { return nil }
        let delta = current > previous ? current - previous : 0
        let capacity = elapsed * 1_000_000_000 * Double(cores)
        guard capacity > 0 else { return nil }
        return min(max(Double(delta) / capacity, 0), 1)
    }

    /// 枚举全部进程，返回原始数据及最新 CPU 时间表（供下次差值）。
    static func sample(
        previous: [ProcessIdentity: UInt64]
    ) -> (raw: [RawProcess], cpuTimes: [ProcessIdentity: UInt64]) {
        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return ([], [:]) }

        var pids = [Int32](repeating: 0, count: Int(pidCount))
        let written = proc_listallpids(&pids, pidCount)
        guard written > 0 else { return ([], [:]) }

        var raw: [RawProcess] = []
        raw.reserveCapacity(Int(written))
        var cpuTimes: [ProcessIdentity: UInt64] = [:]
        cpuTimes.reserveCapacity(Int(written))

        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)

        for index in 0..<Int(written) {
            let pid = pids[index]
            guard pid > 0 else { continue }

            var bsdInfo = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdSize) == bsdSize else { continue }
            // start time 读不到（内核字段本身就是 0）时只能跳过这个进程本次采样，
            // 不能退化成仅用 pid 当身份 —— 那等于放弃了 PID 复用防护，
            // 见 design.md 风险矩阵「PID 重用」条目的剩余风险描述。
            guard bsdInfo.pbi_start_tvsec > 0 else { continue }

            var taskInfo = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskSize) > 0 else { continue }

            let identity = ProcessIdentity(pid: pid, startTime: bsdInfo.pbi_start_tvsec)

            let name = withUnsafePointer(to: &bsdInfo.pbi_name) { namePtr -> String in
                namePtr.withMemoryRebound(to: CChar.self, capacity: 33) {
                    String(cString: $0)
                }
            }
            let cpuTime = UInt64(taskInfo.pti_total_user &+ taskInfo.pti_total_system)
            let memoryBytes = UInt64(taskInfo.pti_resident_size)
            let previousTime = previous[identity]

            raw.append(RawProcess(
                identity: identity,
                name: name.isEmpty ? "pid \(pid)" : name,
                cpuTimeNs: cpuTime,
                prevCpuTimeNs: previousTime,
                memoryBytes: memoryBytes,
                actionIdentity: kernelIdentity(pid: pid, bsdInfo: &bsdInfo, name: name)
            ))
            cpuTimes[identity] = cpuTime
        }
        return (raw, cpuTimes)
    }
    /// 只读动作边界：必须拿到完整 BSD 结构，缺失/权限失败返回 nil。
    static func identity(for pid: Int32) -> ProcessKernelIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafePointer(to: &info.pbi_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 33) { String(cString: $0) }
        }
        return kernelIdentity(pid: pid, bsdInfo: &info, name: name)
    }

    private static func kernelIdentity(pid: Int32, bsdInfo: inout proc_bsdinfo, name: String) -> ProcessKernelIdentity? {
        guard bsdInfo.pbi_start_tvsec > 0, bsdInfo.pbi_start_tvusec < 1_000_000 else { return nil }
        return ProcessKernelIdentity(pid: pid,
            startTime: ProcessStartTime(seconds: bsdInfo.pbi_start_tvsec, microseconds: bsdInfo.pbi_start_tvusec),
            ownerUID: bsdInfo.pbi_uid, parentPID: Int32(bsdInfo.pbi_ppid), name: name)
    }

}
