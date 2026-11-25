import AppKit
import Foundation
import XCTest
@testable import LynxBar

/// `ProcessIconCache` 的核心承诺与 `ProcessDisplayNameCacheTests.swift`
/// （Task D.1）对 `ProcessDisplayNameCache` 的承诺是同一类：
/// 1. 同一个 `ProcessIdentity` 不重复加载图标（含「查不到」的结果本身）——
///    这是它存在的性能理由。
/// 2. pid 复用后不能把旧进程的图标沿用给新进程。
/// 3. （本任务新增，D.1 没有的维度）`NSImage` 比字符串重得多，缓存需要一个
///    不依赖外部调用的容量上界。
@MainActor
final class ProcessIconCacheTests: XCTestCase {
    // MARK: - 基本承诺：同一 identity 只加载一次

    func testResolvesOnlyOncePerIdentity() {
        var loads = 0
        let identity = ProcessProvider.ProcessIdentity(pid: 42, startTime: 1_000)
        let cache = ProcessIconCache(load: { _ in
            loads += 1
            return NSImage(size: NSSize(width: 1, height: 1))
        })
        _ = cache.icon(for: identity)
        _ = cache.icon(for: identity)
        _ = cache.icon(for: identity)
        XCTAssertEqual(loads, 1, "同一 identity 不应重复加载图标")
    }

    func testMissingIconIsCachedToo() {
        var loads = 0
        let identity = ProcessProvider.ProcessIdentity(pid: 42, startTime: 1_000)
        let cache = ProcessIconCache(load: { _ in
            loads += 1
            return nil
        })
        _ = cache.icon(for: identity)
        _ = cache.icon(for: identity)
        XCTAssertEqual(loads, 1, "查不到也要记住，否则命令行进程每次都白查一遍")
    }

    func testDistinctIdentitiesLoadIndependently() {
        var loaded: [ProcessProvider.ProcessIdentity] = []
        let a = ProcessProvider.ProcessIdentity(pid: 1, startTime: 100)
        let b = ProcessProvider.ProcessIdentity(pid: 2, startTime: 200)
        let cache = ProcessIconCache(load: { identity in
            loaded.append(identity)
            return NSImage(size: NSSize(width: 1, height: 1))
        })
        _ = cache.icon(for: a)
        _ = cache.icon(for: b)
        XCTAssertEqual(loaded, [a, b])
    }

    // MARK: - 负缓存 TTL

    /// 审查发现（与 `ProcessDisplayNameCacheTests.testNegativeCacheRetriesAfterTTLExpires`
    /// 同构的问题）：负缓存不能永久生效。改动前（每轮都真实调用
    /// `NSRunningApplication`/`NSWorkspace.icon(forFile:)`）刚启动的 GUI App
    /// 在完成 LaunchServices 注册前那次查询失败，会在下一轮自愈；如果 nil
    /// 结果被永久缓存，这个自愈能力就丢了——该进程在 LynxBar 重启前会一直显示
    /// 通用终端符号而不是真实应用图标。这里模拟：第一次加载失败（未注册
    /// 完成），`negativeCacheTTL` 窗口内再查仍然应该命中负缓存、不重新加载；
    /// TTL 过期后再查，应该重新加载，这次拿到真实图标（模拟"这时已经注册
    /// 完成"）。
    func testNegativeCacheRetriesAfterTTLExpires() {
        var loads = 0
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = ProcessProvider.ProcessIdentity(pid: 42, startTime: 1_000)
        let registeredIcon = NSImage(size: NSSize(width: 1, height: 1))
        let cache = ProcessIconCache(
            load: { _ in
                loads += 1
                return loads >= 2 ? registeredIcon : nil
            },
            now: { currentTime }
        )

        XCTAssertNil(cache.icon(for: identity))
        XCTAssertEqual(loads, 1)

        // TTL 窗口内再查：不应该重新加载。
        currentTime = currentTime.addingTimeInterval(ProcessIconCache.negativeCacheTTL - 1)
        XCTAssertNil(
            cache.icon(for: identity),
            "负缓存在 TTL 阈值内应该继续命中"
        )
        XCTAssertEqual(loads, 1, "负缓存在 TTL 阈值内不应该重新加载")

        // 超过 TTL：应该重新加载，这次拿到真实图标。
        currentTime = currentTime.addingTimeInterval(2)
        XCTAssertNotNil(
            cache.icon(for: identity),
            "负缓存过期后必须重新加载，让刚完成 LaunchServices 注册的 App 显示正确图标"
        )
        XCTAssertEqual(loads, 2, "负缓存过期后应该重新加载一次")
    }

    // MARK: - 核心陷阱：pid 复用

    /// 核心陷阱测试：pid 会被复用。`ProcessProvider.ProcessIdentity` 用
    /// pid + start time 区分「同一个 pid 的不同进程」。如果缓存退化成按裸
    /// pid 存储，这里会错误地把旧进程的图标返回给新进程 identity——因为
    /// 查找会命中同一个 pid 键。
    func testPIDReuseWithDifferentStartTimeIsNotServedStaleIcon() {
        let oldProcess = ProcessProvider.ProcessIdentity(pid: 42, startTime: 1_000)
        let newProcess = ProcessProvider.ProcessIdentity(pid: 42, startTime: 2_000)
        var loaded: [ProcessProvider.ProcessIdentity] = []
        let cache = ProcessIconCache(load: { identity in
            loaded.append(identity)
            return NSImage(size: NSSize(width: 1, height: 1))
        })

        _ = cache.icon(for: oldProcess)
        _ = cache.icon(for: newProcess)
        XCTAssertEqual(
            loaded, [oldProcess, newProcess],
            "pid 复用后（start time 变化）必须重新加载新进程的图标，不能沿用旧进程缓存里同 pid 的旧条目"
        )
        // 反过来查旧 identity，不应该再触发加载——证明两条记录是独立缓存的，
        // 不是新查询覆盖了旧键。
        _ = cache.icon(for: oldProcess)
        XCTAssertEqual(loaded, [oldProcess, newProcess], "旧 identity 应该仍然命中它自己的缓存条目")
    }

    // MARK: - 驱逐：retain(identities:)

    func testEvictsIdentitiesAbsentFromLatestSample() {
        var loads = 0
        let identity = ProcessProvider.ProcessIdentity(pid: 42, startTime: 1_000)
        let other = ProcessProvider.ProcessIdentity(pid: 99, startTime: 2_000)
        let cache = ProcessIconCache(load: { _ in
            loads += 1
            return NSImage(size: NSSize(width: 1, height: 1))
        })
        _ = cache.icon(for: identity)
        cache.retain(identities: [other])
        _ = cache.icon(for: identity)
        XCTAssertEqual(loads, 2, "不在最新存活集合里的 identity 必须被驱逐，重新加载")
    }

    // MARK: - 容量上界

    /// `retain(identities:)` 由 `ProcessViewModel` 采样循环调用，只在
    /// Overview/CPU/Memory 面板打开时才会跑；如果用户只开 Network 面板
    /// （图标经 `icon(forPID:)` 惰性加载），`retain` 可能长期不触发。容量
    /// 上界是不依赖外部调用的兜底：超出容量时整体清空，保证缓存条目数有
    /// 一个硬上限。如果这道保护被去掉，即使插入远超容量的不同 identity，
    /// 早先缓存的条目也会一直命中、不重新加载——这个测试直接锁住「超限后
    /// 必须清空重来」。
    func testCacheClearsWhenExceedingCapacity() {
        var loaded: [ProcessProvider.ProcessIdentity] = []
        let a = ProcessProvider.ProcessIdentity(pid: 1, startTime: 100)
        let b = ProcessProvider.ProcessIdentity(pid: 2, startTime: 200)
        let c = ProcessProvider.ProcessIdentity(pid: 3, startTime: 300)
        let cache = ProcessIconCache(capacity: 2, load: { identity in
            loaded.append(identity)
            return NSImage(size: NSSize(width: 1, height: 1))
        })

        _ = cache.icon(for: a)
        _ = cache.icon(for: b)
        XCTAssertEqual(loaded, [a, b], "容量未超限前，A/B 各自只应该加载一次")

        // 第 3 个不同 identity 超出容量上限（2），应整体清空后再加载 C。
        _ = cache.icon(for: c)
        XCTAssertEqual(loaded, [a, b, c])

        // A 应该已经随清空被驱逐，必须重新加载。
        _ = cache.icon(for: a)
        XCTAssertEqual(
            loaded, [a, b, c, a],
            "超出容量后必须整体清空缓存，之前缓存的 identity 需要重新加载，否则容量上限形同虚设"
        )
    }

    // MARK: - 裸 pid 入口：icon(forPID:)

    /// `icon(forPID:)` 是 Network 面板专用入口：`NetworkProcessProvider.Usage`
    /// 的数据来自 nettop 的 CSV 输出，只有裸 pid，没有 start time，因此每次
    /// 调用都要重新解析一次 identity（不能把 pid→identity 本身缓存起来，否则
    /// 又退化回裸 pid 缓存，在 pid 复用时失去保护）；identity 不变时，图标
    /// 加载仍然只做一次。
    func testIconForPIDReResolvesIdentityEveryCallButIconOnlyOncePerIdentity() {
        var identityLookups = 0
        var iconLoads = 0
        var currentStartTime: UInt64 = 1_000
        let cache = ProcessIconCache(
            load: { _ in
                iconLoads += 1
                return NSImage(size: NSSize(width: 1, height: 1))
            },
            identityResolver: { pid in
                identityLookups += 1
                return ProcessProvider.ProcessIdentity(pid: pid, startTime: currentStartTime)
            }
        )

        _ = cache.icon(forPID: 42)
        _ = cache.icon(forPID: 42)
        XCTAssertEqual(identityLookups, 2, "每次都要重新查 identity，才能发现 pid 是否已被复用")
        XCTAssertEqual(iconLoads, 1, "identity 没变就不该重复加载图标")

        currentStartTime = 2_000 // 模拟 pid 42 被复用给了新进程
        _ = cache.icon(forPID: 42)
        XCTAssertEqual(identityLookups, 3)
        XCTAssertEqual(iconLoads, 2, "start time 变了说明是新进程，必须重新加载图标，不能沿用旧缓存")
    }

    func testIconForPIDReturnsNilWhenIdentityResolutionFails() {
        var iconLoads = 0
        let cache = ProcessIconCache(
            load: { _ in
                iconLoads += 1
                return NSImage(size: NSSize(width: 1, height: 1))
            },
            identityResolver: { _ in nil }
        )

        XCTAssertNil(cache.icon(forPID: 42))
        XCTAssertEqual(iconLoads, 0, "identity 都解析不出来时不该继续加载图标")
    }

    /// 对真实 libproc 调用的冒烟测试：用测试宿主进程自己的 pid（保证此刻真实
    /// 存活），验证 `identityResolver` 默认实现（`proc_pidinfo` 查
    /// `pbi_start_tvsec`）确实接对了系统调用——如果常量或结构体字段用错，
    /// 这里会解析失败或返回错误的 pid。
    func testIdentityForPIDResolvesCurrentProcess() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var resolvedIdentity: ProcessProvider.ProcessIdentity?
        // identityResolver 用默认实现（真实 proc_pidinfo 调用）；load 换成
        // 探针，捕获默认 identityResolver 解析出的 identity 供断言。
        let cache = ProcessIconCache(load: { identity in
            resolvedIdentity = identity
            return nil
        })
        _ = cache.icon(forPID: selfPID)

        let identity = try? XCTUnwrap(resolvedIdentity)
        XCTAssertEqual(identity?.pid, selfPID, "应该解析出测试宿主进程自己的 pid")
        XCTAssertNotNil(identity, "测试宿主进程此刻必然存活，identity 解析不应失败")
    }
}
