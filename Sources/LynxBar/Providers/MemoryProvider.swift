import Foundation

/// 内存快照。
struct MemorySnapshot: Sendable {
    var total: UInt64 = 0
    var appMemory: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// 容量占用比例（active + wired + compressed）/ total；不是 macOS memory pressure。
    var usage: Double = 0
}

/// 内存采集（Mach `host_statistics64` + sysctl swap）。无状态，线程安全。
enum MemoryProvider {
    static func sample() -> MemorySnapshot {
        var snapshot = MemorySnapshot()
        snapshot.total = readTotalMemory()

        let stats = readVMStatistics()
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pageBytes = UInt64(pageSize)
        snapshot.appMemory = UInt64(stats.active_count) * pageBytes
        snapshot.wired = UInt64(stats.wire_count) * pageBytes
        snapshot.compressed = UInt64(stats.compressor_page_count) * pageBytes
        snapshot.free = UInt64(stats.free_count) * pageBytes
        snapshot.cached = (UInt64(stats.inactive_count) + UInt64(stats.speculative_count)) * pageBytes

        let used = snapshot.appMemory + snapshot.wired + snapshot.compressed
        snapshot.usage = snapshot.total > 0 ? Double(used) / Double(snapshot.total) : 0

        let swap = readSwap()
        snapshot.swapUsed = swap.used
        snapshot.swapTotal = swap.total
        return snapshot
    }

    private static func readTotalMemory() -> UInt64 {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        return total
    }

    private static func readVMStatistics() -> vm_statistics64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : vm_statistics64()
    }

    private static func readSwap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }
}
