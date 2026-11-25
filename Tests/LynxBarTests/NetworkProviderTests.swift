import XCTest
@testable import LynxBar

final class NetworkProviderTests: XCTestCase {
    func testPreferredActivePhysicalInterfaceWins() {
        let en0 = interface(name: "en0", ipv4: "192.168.1.4", physical: true)
        let en5 = interface(name: "en5", ipv4: "10.0.0.8", physical: true)
        let utun = interface(name: "utun4", ipv4: "10.8.0.2", physical: false)

        let selected = NetworkProvider.selectPrimaryInterface(
            [en0, en5, utun],
            preferredName: "en5"
        )

        XCTAssertEqual(selected?.name, "en5")
    }

    func testVirtualOrInactiveInterfaceIsNeverPromoted() {
        let utun = interface(name: "utun4", ipv4: "10.8.0.2", physical: false)
        let inactive = interface(
            name: "en0",
            ipv4: "192.168.1.4",
            physical: true,
            isRunning: false
        )

        XCTAssertNil(
            NetworkProvider.selectPrimaryInterface(
                [utun, inactive],
                preferredName: "utun4"
            )
        )
    }

    func testMACFormattingIsUppercaseAndRejectsInvalidLength() {
        XCTAssertEqual(
            NetworkProvider.formatMAC(bytes: [0x3c, 0x22, 0xfb, 0x8a, 0x41, 0x0d]),
            "3C:22:FB:8A:41:0D"
        )
        XCTAssertNil(NetworkProvider.formatMAC(bytes: [0, 1, 2]))
        XCTAssertNil(NetworkProvider.formatMAC(bytes: [0, 0, 0, 0, 0, 0]))
    }

    /// 回归锁：`mapInterfaceByteCounters` 必须原样转发 64 位值，不能悄悄截断到 32 位
    /// （曾经历过 `NET_RT_IFLIST2` 路径高位恒为零的真实事故）。用手工构造的、高 32
    /// 位非零的 `ifmibdata` 值单测——不依赖任何真实网卡状态，CI 上也会跑，弥补
    /// `testByteCountersExceedThirtyTwoBitsWhenNetstatDoes` 依赖真机长开机时长、
    /// 在全新 CI runner 上永远 skip 的短板。
    func testMapInterfaceByteCountersPreservesFullSixtyFourBits() throws {
        let synthesizedIn: UInt64 = 0x0000_0002_fcf3_413a // 量级对齐本机 en0 实测值
        let synthesizedOut: UInt64 = 0x0000_0001_0000_002a
        let record = makeIfmibdata(name: "en0", inBytes: synthesizedIn, outBytes: synthesizedOut)

        let mapped = try XCTUnwrap(NetworkProvider.mapInterfaceByteCounters(record))

        XCTAssertEqual(mapped.name, "en0")
        XCTAssertEqual(mapped.counters.inBytes, synthesizedIn)
        XCTAssertEqual(mapped.counters.outBytes, synthesizedOut)
        let threshold = UInt64(UInt32.max)
        XCTAssertGreaterThan(mapped.counters.inBytes, threshold)
        XCTAssertGreaterThan(mapped.counters.outBytes, threshold)
    }

    func testMapInterfaceByteCountersRejectsEmptyName() {
        // ifmibdata() 全零初始化，接口名整体是空字节——不应该产出一条"名字是空
        // 字符串"的记录。
        XCTAssertNil(NetworkProvider.mapInterfaceByteCounters(ifmibdata()))
    }

    func testByteCountersCoverPhysicalInterfaces() throws {
        let counters = NetworkProvider.interfaceByteCounters()
        let physical = counters.keys.filter { NetworkProvider.isPhysicalInterface($0) }
        try XCTSkipIf(physical.isEmpty, "本机没有物理网卡，跳过")
        XCTAssertFalse(physical.isEmpty)
    }

    func testByteCountersAreMonotonicAcrossTwoReads() throws {
        let first = NetworkProvider.interfaceByteCounters()
        let second = NetworkProvider.interfaceByteCounters()
        for (name, initial) in first {
            guard let later = second[name] else { continue }
            XCTAssertGreaterThanOrEqual(later.inBytes, initial.inBytes, "\(name) 入向计数倒退")
            XCTAssertGreaterThanOrEqual(later.outBytes, initial.outBytes, "\(name) 出向计数倒退")
        }
    }

    /// 回归锁：曾经历过 `NET_RT_IFLIST2` 这条路径本身就把 `ifi_ibytes` 截到 32 位的
    /// 真实事故（高位恒为零，即便 struct 类型是 UInt64）。用系统自带 `netstat -ib`
    /// 独立对照 —— 只要它显示某接口的计数已经超过 2^32，我们的读数就必须同样超过，
    /// 否则说明又发生了同类截断。本机没有这样的接口时跳过，而不是假通过。
    func testByteCountersExceedThirtyTwoBitsWhenNetstatDoes() throws {
        let netstatCounters = netstatByteCounters() ?? [:]
        let threshold = UInt64(UInt32.max)
        let overflowing = netstatCounters.filter {
            $0.value.inBytes > threshold || $0.value.outBytes > threshold
        }
        try XCTSkipIf(
            overflowing.isEmpty,
            "netstat -ib 不可用，或本机当前没有累计流量超过 2^32 的接口，跳过"
        )

        let counters = NetworkProvider.interfaceByteCounters()
        for (name, reference) in overflowing {
            guard let ours = counters[name] else {
                XCTFail("netstat 显示 \(name) 已超过 2^32，但 interfaceByteCounters() 没有这个接口")
                continue
            }
            if reference.inBytes > threshold {
                XCTAssertGreaterThan(ours.inBytes, threshold, "\(name) 入向已超 2^32，但读数被截断")
            }
            if reference.outBytes > threshold {
                XCTAssertGreaterThan(ours.outBytes, threshold, "\(name) 出向已超 2^32，但读数被截断")
            }
        }
    }

    private func interface(
        name: String,
        ipv4: String?,
        physical: Bool,
        isRunning: Bool = true
    ) -> NetworkProvider.Interface {
        NetworkProvider.Interface(
            name: name,
            ipv4: ipv4,
            ipv6: nil,
            macAddress: nil,
            inBytes: 0,
            outBytes: 0,
            isPhysical: physical,
            isUp: true,
            isRunning: isRunning,
            isPrimary: false
        )
    }

    /// 手工构造一条 `ifmibdata` 记录：`ifmd_name` 是定长 C 数组（Swift 里导入成
    /// tuple），按字节写入接口名；其余字段走 `ifmibdata()` 的全零默认值。
    private func makeIfmibdata(name: String, inBytes: UInt64, outBytes: UInt64) -> ifmibdata {
        var record = ifmibdata()
        withUnsafeMutableBytes(of: &record.ifmd_name) { raw in
            for (index, byte) in Array(name.utf8).enumerated() where index < raw.count {
                raw[index] = byte
            }
        }
        record.ifmd_data.ifi_ibytes = inBytes
        record.ifmd_data.ifi_obytes = outBytes
        return record
    }

    /// 跑系统自带 `netstat -ib`，解析每个接口的 Link 层字节计数，供交叉验证用。
    private func netstatByteCounters() -> [String: (inBytes: UInt64, outBytes: UInt64)]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-ib"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return parseNetstatLinkRows(text)
        } catch {
            return nil
        }
    }

    /// 解析 `netstat -ib` 每个接口的 `<Link#N>` 汇总行。没有链路层地址的接口
    /// （lo0 / utun* / gif0 等）Address 列整体缺失，字段数会在 10 / 11 间浮动——
    /// 用"取末尾 7 个固定列"定位 Ibytes / Obytes，不依赖固定下标，避免被这种浮动错位。
    private func parseNetstatLinkRows(
        _ text: String
    ) -> [String: (inBytes: UInt64, outBytes: UInt64)] {
        var result: [String: (inBytes: UInt64, outBytes: UInt64)] = [:]
        let lines = text.split(whereSeparator: \.isNewline).dropFirst()
        for line in lines {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 10, fields[2].contains("Link") else { continue }
            let tail = Array(fields.suffix(7)) // Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
            guard tail.count == 7,
                  let inBytes = UInt64(tail[2]),
                  let outBytes = UInt64(tail[5]) else { continue }
            var name = fields[0]
            if name.hasSuffix("*") { name.removeLast() }
            result[name] = (inBytes, outBytes)
        }
        return result
    }
}
