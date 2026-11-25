import Foundation
import Darwin

/// 单个挂载卷的容量信息。
struct DiskVolume: Sendable, Identifiable {
    /// 物理设备路径，如 `/dev/disk3s1s1`。
    let device: String
    /// 系统本地化卷名；根卷通常为 “Macintosh HD”。
    let name: String
    /// 挂载点，如 `/`。
    let mountPoint: String
    /// 文件系统类型，如 `apfs`。
    let fileSystem: String
    let totalBytes: UInt64
    let freeBytes: UInt64
    var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }
    var usage: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    var id: String { mountPoint }
}

struct DiskSnapshot: Sendable {
    var volumes: [DiskVolume] = []
    /// 用户可行动的主存储口径始终来自根挂载卷，避免 APFS 共享容器重复相加。
    var primaryVolume: DiskVolume?
    var totalUsed: UInt64 = 0
    var totalCapacity: UInt64 = 0
    var usage: Double { totalCapacity > 0 ? Double(totalUsed) / Double(totalCapacity) : 0 }
}

/// 磁盘容量采集（getmntinfo）。无状态，线程安全。
enum DiskProvider {
    /// 真实文件系统白名单；排除 devfs / autofs / 虚拟挂载等。
    private static let realFileSystems: Set<String> = [
        "apfs", "hfs", "msdos", "exfat", "ntfs", "ufsd_NTFS", "apfs_mutex",
    ]

    static func sample() -> DiskSnapshot {
        var snapshot = DiskSnapshot()
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_WAIT)
        guard count > 0, let buffer else { return snapshot }

        // 明细只按设备路径去重；摘要在循环后固定选择根卷，避免 APFS 共享容量相加。
        var seenDevices = Set<String>()
        for index in 0..<Int(count) {
            let info = buffer[index]
            let fileSystem = cString(from: info.f_fstypename, capacity: 16)
            guard realFileSystems.contains(fileSystem) else { continue }

            let device = cString(from: info.f_mntfromname, capacity: 1024)
            guard !device.isEmpty, !seenDevices.contains(device) else { continue }
            seenDevices.insert(device)

            let mountPoint = cString(from: info.f_mntonname, capacity: 1024)
            let blockSize = UInt64(info.f_bsize)
            let total = UInt64(info.f_blocks) * blockSize
            let free = UInt64(info.f_bavail) * blockSize

            let volume = DiskVolume(
                device: device,
                name: FileManager.default.displayName(atPath: mountPoint),
                mountPoint: mountPoint,
                fileSystem: fileSystem,
                totalBytes: total,
                freeBytes: free
            )
            snapshot.volumes.append(volume)
        }
        snapshot.volumes.sort { $0.mountPoint < $1.mountPoint }
        snapshot.primaryVolume = snapshot.volumes.first { $0.mountPoint == "/" }
            ?? snapshot.volumes.first
        snapshot.totalCapacity = snapshot.primaryVolume?.totalBytes ?? 0
        snapshot.totalUsed = snapshot.primaryVolume?.usedBytes ?? 0
        return snapshot
    }

    /// 读取 statfs 固定长度字符数组字段为 String。字段是 let，用传值 + 指针重绑定。
    private static func cString<T>(from field: T, capacity: Int) -> String {
        withUnsafePointer(to: field) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }
}
