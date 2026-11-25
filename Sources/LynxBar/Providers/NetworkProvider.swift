import Darwin
import Foundation
import SystemConfiguration

/// 网络采集（getifaddrs + SystemConfiguration）。无状态，线程安全。
enum NetworkProvider {
    struct Interface: Sendable, Equatable {
        let name: String
        let ipv4: String?
        let ipv6: String?
        let macAddress: String?
        /// nil 表示这一 tick 没能读到这个接口的字节计数（sysctl 整体失败，或
        /// 恰好漏掉了这个接口），不代表计数确实是 0——调用方不得用 `?? 0` 顶替。
        let inBytes: UInt64?
        let outBytes: UInt64?
        let isPhysical: Bool
        let isUp: Bool
        let isRunning: Bool
        let isPrimary: Bool
    }

    struct RawCounters: Sendable {
        /// nil 表示主接口不存在，或主接口存在但字节计数不可用；两种情况都不能
        /// 显示成 0，也不能被下游拿去当采样基线。
        var totalIn: UInt64?
        var totalOut: UInt64?
        var interfaces: [Interface] = []
        var primaryInterface: Interface?
    }

    static func isPhysicalInterface(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("ue")
    }

    struct ByteCounters: Sendable, Equatable {
        let inBytes: UInt64
        let outBytes: UInt64
    }

    /// 从单条 `ifmibdata` 记录里取出接口名与 64 位字节计数。
    ///
    /// 纯函数，不做系统调用，只做内存布局层面的字段提取——可以用手工构造的
    /// `ifmibdata` 值单测（含高 32 位非零的场景），不依赖任何真实网卡状态。
    static func mapInterfaceByteCounters(
        _ record: ifmibdata
    ) -> (name: String, counters: ByteCounters)? {
        var record = record
        let name = withUnsafePointer(to: &record.ifmd_name) { pointer -> String in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(IFNAMSIZ)) {
                String(cString: $0)
            }
        }
        guard !name.isEmpty else { return nil }
        return (
            name,
            ByteCounters(
                inBytes: record.ifmd_data.ifi_ibytes,
                outBytes: record.ifmd_data.ifi_obytes
            )
        )
    }

    /// 通过 `net.link.generic.ifdata.<index>.general` 读取 64 位接口字节计数。
    ///
    /// `getifaddrs` 的 `ifa_data` 是 `if_data`，其 `ifi_ibytes` / `ifi_obytes`
    /// 只有 32 位，超过 4 GiB 会回绕。`NET_RT_IFLIST2` 看似提供 `if_data64`，
    /// 但本机实测其 `ifi_ibytes` 高 32 位恒为零（en0 入向已过 4 GiB 两圈仍只返回
    /// 低位），只有 `IFMIB_IFDATA` 这条路径给出真正的 64 位值。
    /// 地址、MAC 和 flags 仍走 getifaddrs，这里只负责字节数。
    static func interfaceByteCounters() -> [String: ByteCounters] {
        var countMib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        var count: Int32 = 0
        var countSize = MemoryLayout<Int32>.size
        guard sysctl(&countMib, 5, &count, &countSize, nil, 0) == 0, count > 0 else {
            return [:]
        }

        var result: [String: ByteCounters] = [:]
        // 接口索引从 1 开始；两次调用之间接口可能增减，取不到的直接跳过。
        for index in 1...count {
            var mib: [Int32] = [
                CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL,
            ]
            var data = ifmibdata()
            var size = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, 6, &data, &size, nil, 0) == 0,
                  let mapped = mapInterfaceByteCounters(data) else { continue }
            result[mapped.name] = mapped.counters
        }
        return result
    }

    /// 读取当前主接口的累计流量、地址和 MAC。
    ///
    /// 旧实现累加所有 `en* / ue*`，在 Wi-Fi + USB 网卡或服务切换时可能重复。
    /// V2 优先采用系统默认 IPv4 路由的接口，只在查询失败时确定性回退。
    static func readCounters() -> RawCounters {
        var firstAddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddr) == 0, let start = firstAddr else {
            return RawCounters()
        }
        defer { freeifaddrs(start) }

        let byteCounters = interfaceByteCounters()
        var byName: [String: Accumulator] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let name = current.pointee.ifa_name.map { String(cString: $0) } ?? ""
            guard !name.isEmpty, name != "lo0", let addr = current.pointee.ifa_addr else {
                continue
            }

            var entry = byName[name] ?? Accumulator()
            let flags = current.pointee.ifa_flags
            entry.isUp = (flags & UInt32(IFF_UP)) != 0
            entry.isRunning = (flags & UInt32(IFF_RUNNING)) != 0

            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                entry.macAddress = macAddress(from: addr)
            case AF_INET:
                entry.ipv4 = ipv4String(from: addr)
            case AF_INET6:
                let address = ipv6String(from: addr)
                if entry.ipv6 == nil || !(address?.hasPrefix("fe80:") ?? true) {
                    entry.ipv6 = address
                }
            default:
                break
            }
            byName[name] = entry
        }

        let provisional = byName.map { name, entry in
            Interface(
                name: name,
                ipv4: entry.ipv4,
                ipv6: entry.ipv6,
                macAddress: entry.macAddress,
                inBytes: byteCounters[name]?.inBytes,
                outBytes: byteCounters[name]?.outBytes,
                isPhysical: isPhysicalInterface(name),
                isUp: entry.isUp,
                isRunning: entry.isRunning,
                isPrimary: false
            )
        }
        let selected = selectPrimaryInterface(
            provisional,
            preferredName: systemPrimaryInterfaceName()
        )
        let interfaces = provisional
            .map { interface in
                Interface(
                    name: interface.name,
                    ipv4: interface.ipv4,
                    ipv6: interface.ipv6,
                    macAddress: interface.macAddress,
                    inBytes: interface.inBytes,
                    outBytes: interface.outBytes,
                    isPhysical: interface.isPhysical,
                    isUp: interface.isUp,
                    isRunning: interface.isRunning,
                    isPrimary: interface.name == selected?.name
                )
            }
            .sorted {
                if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
                if $0.isPhysical != $1.isPhysical { return $0.isPhysical }
                return $0.name < $1.name
            }

        let primary = interfaces.first(where: \.isPrimary)
        return RawCounters(
            totalIn: primary?.inBytes,
            totalOut: primary?.outBytes,
            interfaces: interfaces,
            primaryInterface: primary
        )
    }

    static func selectPrimaryInterface(
        _ interfaces: [Interface],
        preferredName: String?
    ) -> Interface? {
        let eligible = interfaces.filter {
            $0.isPhysical
                && $0.isUp
                && $0.isRunning
                && ($0.ipv4 != nil || $0.ipv6 != nil)
        }
        if let preferredName,
           let preferred = eligible.first(where: { $0.name == preferredName }) {
            return preferred
        }
        return eligible.sorted { $0.name < $1.name }.first
    }

    static func formatMAC(bytes: [UInt8]) -> String? {
        guard bytes.count == 6, bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// 通过外部服务查询公网 IP（HTTPS）。任一成功即返回；全部失败返回 nil。
    static func fetchPublicIP() async -> String? {
        for source in publicIPSources {
            if let ip = await tryFetch(urlString: source) { return ip }
        }
        Log.network.warning("All public IP lookup endpoints failed")
        return nil
    }

    private static let publicIPSources = [
        "https://api.ipify.org",
        "https://ifconfig.me/ip",
        "https://icanhazip.com",
    ]

    private static func systemPrimaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(
            kCFAllocatorDefault,
            "LynxBar.NetworkProvider" as CFString,
            nil,
            nil
        ) else {
            return nil
        }
        let key = "State:/Network/Global/IPv4" as CFString
        guard let dictionary = SCDynamicStoreCopyValue(store, key) as? [String: Any] else {
            return nil
        }
        return dictionary["PrimaryInterface"] as? String
    }

    /// Queries a single HTTPS endpoint for the caller's public IP, validating syntax without logging the IP or response body.
    private static func tryFetch(urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                isIPAddress(value) else {
                Log.network.debug(
                    "Public IP lookup returned invalid payload from \(url.host ?? "unknown", privacy: .public)"
                )
                return nil
            }
            return value
        } catch {
            Log.network.debug(
                "Public IP lookup failed for \(url.host ?? "unknown", privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    private struct Accumulator: Sendable {
        var ipv4: String?
        var ipv6: String?
        var macAddress: String?
        var isUp = false
        var isRunning = false
    }

    private static func macAddress(from addr: UnsafeMutablePointer<sockaddr>) -> String? {
        addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { pointer in
            var link = pointer.pointee
            let nameLength = Int(link.sdl_nlen)
            let addressLength = Int(link.sdl_alen)
            guard addressLength == 6 else { return nil }
            return withUnsafePointer(to: &link.sdl_data) { dataPointer in
                dataPointer.withMemoryRebound(
                    to: UInt8.self,
                    capacity: nameLength + addressLength
                ) { bytes in
                    formatMAC(bytes: (0..<addressLength).map { bytes[nameLength + $0] })
                }
            }
        }
    }

    private static func ipv4String(from addr: UnsafeMutablePointer<sockaddr>) -> String? {
        let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var address = sin.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }

    private static func ipv6String(from addr: UnsafeMutablePointer<sockaddr>) -> String? {
        let sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
        var address = sin6.sin6_addr
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }
}
