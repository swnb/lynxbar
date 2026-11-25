import Foundation
import XCTest
@testable import LynxBar

/// `ProcessDisplayNameCache` 的核心承诺有两条：
/// 1. 同一个 `ProcessIdentity` 不重复查 `NSRunningApplication`（含「查不到」
///    的结果本身）——这是它存在的性能理由。
/// 2. pid 复用后不能把旧进程的名字沿用给新进程——`ProcessSamplingTests.swift`
///    里 `testRecycledPIDIsTreatedAsUnknownNotIdle` 是同一类问题在
///    `ProcessProvider.cpuUsage` 层面的对应测试，这里是显示名层面的。
@MainActor
final class ProcessDisplayNameCacheTests: XCTestCase {
    func testResolvesOnlyOncePerIdentity() {
        var lookups = 0
        let identity = ProcessProvider.ProcessIdentity(pid: 42, startTime: 1_000)
        let cache = ProcessDisplayNameCache(resolve: { _ in
            lookups += 1
            return "Resolved"
        })
        _ = cache.name(for: identity, fallback: "raw")
        _ = cache.name(for: identity, fallback: "raw")
        _ = cache.name(for: identity, fallback: "raw")
        XCTAssertEqual(lookups, 1, "同一 identity 不应重复查询 LaunchServices")
    }

    func testFallsBackToRawNameWhenLookupFails() {
        let identity = ProcessProvider.ProcessIdentity(pid: 42, startTime: 1_000)
        let cache = ProcessDisplayNameCache(resolve: { _ in nil })
        XCTAssertEqual(cache.name(for: identity, fallback: "kernel_task"), "kernel_task")
    }

    func testFailedLookupIsAlsoCached() {
        var lookups = 0
        let identity = ProcessProvider.ProcessIdentity(pid: 42, startTime: 1_000)
        let cache = ProcessDisplayNameCache(resolve: { _ in
            lookups += 1
            return nil
        })
        _ = cache.name(for: identity, fallback: "raw")
        _ = cache.name(for: identity, fallback: "raw")
        XCTAssertEqual(lookups, 1, "查不到也要记住，否则命令行进程每次都白查一遍")
    }

    func testEvictsIdentitiesAbsentFromLatestSample() {
        var lookups = 0
        let identity = ProcessProvider.ProcessIdentity(pid: 42, startTime: 1_000)
        let other = ProcessProvider.ProcessIdentity(pid: 99, startTime: 2_000)
        let cache = ProcessDisplayNameCache(resolve: { _ in
            lookups += 1
            return "Resolved"
        })
        _ = cache.name(for: identity, fallback: "raw")
        cache.retain(identities: [other])
        _ = cache.name(for: identity, fallback: "raw")
        XCTAssertEqual(lookups, 2, "不在最新存活集合里的 identity 必须被驱逐，重新查询")
    }

    /// Important 1（D.1 审查发现）：负缓存不能永久生效。改动前（每轮都
    /// 真实调用 `NSRunningApplication`）刚启动的 GUI App 在完成
    /// LaunchServices 注册前那次查询失败，会在下一轮自愈；如果 nil 结果被
    /// 永久缓存，这个自愈能力就丢了——该进程在 LynxBar 重启前会一直显示内核
    /// 原始名。这里模拟：第一次查询失败（未注册完成），`negativeCacheTTL`
    /// 窗口内再查仍然应该命中负缓存、不重新解析；TTL 过期后再查，应该
    /// 重新解析，这次拿到真实名字（模拟"这时已经注册完成"）。
    func testNegativeCacheRetriesAfterTTLExpires() {
        var lookups = 0
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = ProcessProvider.ProcessIdentity(pid: 42, startTime: 1_000)
        let cache = ProcessDisplayNameCache(
            resolve: { _ in
                lookups += 1
                return lookups >= 2 ? "Now Registered" : nil
            },
            now: { currentTime }
        )

        XCTAssertEqual(cache.name(for: identity, fallback: "raw"), "raw")
        XCTAssertEqual(lookups, 1)

        // TTL 窗口内再查：不应该重新解析。
        currentTime = currentTime.addingTimeInterval(ProcessDisplayNameCache.negativeCacheTTL - 1)
        XCTAssertEqual(
            cache.name(for: identity, fallback: "raw"), "raw",
            "负缓存在 TTL 阈值内应该继续命中"
        )
        XCTAssertEqual(lookups, 1, "负缓存在 TTL 阈值内不应该重新查询")

        // 超过 TTL：应该重新解析，这次拿到真实名字。
        currentTime = currentTime.addingTimeInterval(2)
        XCTAssertEqual(
            cache.name(for: identity, fallback: "raw"), "Now Registered",
            "负缓存过期后必须重新查询，让刚完成 LaunchServices 注册的 App 显示正确名字"
        )
        XCTAssertEqual(lookups, 2, "负缓存过期后应该重新查询一次")
    }

    /// Important 2（D.1 审查发现）：容量硬上限，不依赖 `retain(identities:)`
    /// 是否被调用过。`NetworkViewModel` 不调用 `retain(identities:)`（见
    /// `NetworkViewModel.publishProcessAttribution()` 上的注释），如果没有
    /// 这道独立保护，长时间只用 Network 面板会让缓存无限增长。这里直接把
    /// `capacity` 设成 2，插入第 3 个不同 identity 应该触发整体清空——与
    /// `ProcessIconCacheTests.testCacheClearsWhenExceedingCapacity`（D.2）
    /// 同构。
    func testCacheClearsWhenExceedingCapacity() {
        var resolved: [ProcessProvider.ProcessIdentity] = []
        let a = ProcessProvider.ProcessIdentity(pid: 1, startTime: 100)
        let b = ProcessProvider.ProcessIdentity(pid: 2, startTime: 200)
        let c = ProcessProvider.ProcessIdentity(pid: 3, startTime: 300)
        let cache = ProcessDisplayNameCache(capacity: 2, resolve: { identity in
            resolved.append(identity)
            return "Resolved"
        })

        _ = cache.name(for: a, fallback: "raw")
        _ = cache.name(for: b, fallback: "raw")
        XCTAssertEqual(resolved, [a, b], "容量未超限前，A/B 各自只应该解析一次")

        // 第 3 个不同 identity 超出容量上限（2），应整体清空后再解析 C。
        _ = cache.name(for: c, fallback: "raw")
        XCTAssertEqual(resolved, [a, b, c])

        // A 应该已经随清空被驱逐，必须重新解析。
        _ = cache.name(for: a, fallback: "raw")
        XCTAssertEqual(
            resolved, [a, b, c, a],
            "超出容量后必须整体清空缓存，之前缓存的 identity 需要重新解析，否则容量上限形同虚设"
        )
    }

    /// 核心陷阱测试：pid 会被复用。`ProcessProvider.ProcessIdentity` 用
    /// pid + start time 区分「同一个 pid 的不同进程」（口径与 `ProcessProvider`
    /// 一致，见 `ProcessSamplingTests.testRecycledPIDIsTreatedAsUnknownNotIdle`）。
    /// 如果缓存退化成按裸 pid 存储（B.3 之前的旧设计），这里会错误地把
    /// "Old App" 返回给新进程 identity——因为查找会命中同一个 pid 键。
    func testPIDReuseWithDifferentStartTimeIsNotServedStaleName() {
        let oldProcess = ProcessProvider.ProcessIdentity(pid: 42, startTime: 1_000)
        let newProcess = ProcessProvider.ProcessIdentity(pid: 42, startTime: 2_000)
        let names: [ProcessProvider.ProcessIdentity: String] = [
            oldProcess: "Old App",
            newProcess: "New App",
        ]
        let cache = ProcessDisplayNameCache(resolve: { identity in names[identity] })

        XCTAssertEqual(cache.name(for: oldProcess, fallback: "raw"), "Old App")
        // pid 42 被复用：新进程 start time 不同，绝不能拿到 "Old App"。
        XCTAssertEqual(
            cache.name(for: newProcess, fallback: "raw"), "New App",
            "pid 复用后（start time 变化）必须解析出新进程的名字，不能沿用旧进程缓存"
        )
        // 反过来查旧 identity，仍应得到旧名字——证明两条记录是独立缓存的，
        // 不是新查询覆盖了旧键。
        XCTAssertEqual(cache.name(for: oldProcess, fallback: "raw"), "Old App")
    }

    /// `name(forPID:fallback:)` 是 `NetworkViewModel` 专用入口：nettop 的
    /// CSV 输出只有裸 pid，没有 start time，因此每次调用都要重新解析一次
    /// identity（不能把 pid→identity 本身缓存起来，否则又退化回裸 pid 缓存，
    /// 在 pid 复用时失去保护）；identity 不变时，名字解析仍然只做一次。
    func testNameForPIDReResolvesIdentityEveryCallButNameOnlyOncePerIdentity() {
        var identityLookups = 0
        var nameLookups = 0
        var currentStartTime: UInt64 = 1_000
        let cache = ProcessDisplayNameCache(
            resolve: { _ in
                nameLookups += 1
                return "Resolved"
            },
            identityResolver: { pid in
                identityLookups += 1
                return ProcessProvider.ProcessIdentity(pid: pid, startTime: currentStartTime)
            }
        )

        _ = cache.name(forPID: 42, fallback: "raw")
        _ = cache.name(forPID: 42, fallback: "raw")
        XCTAssertEqual(identityLookups, 2, "每次都要重新查 identity，才能发现 pid 是否已被复用")
        XCTAssertEqual(nameLookups, 1, "identity 没变就不该重复解析名字")

        currentStartTime = 2_000 // 模拟 pid 42 被复用给了新进程
        _ = cache.name(forPID: 42, fallback: "raw")
        XCTAssertEqual(identityLookups, 3)
        XCTAssertEqual(nameLookups, 2, "start time 变了说明是新进程，必须重新解析名字，不能沿用旧缓存")
    }

    func testNameForPIDFallsBackWhenIdentityResolutionFails() {
        var nameLookups = 0
        let cache = ProcessDisplayNameCache(
            resolve: { _ in
                nameLookups += 1
                return "Resolved"
            },
            identityResolver: { _ in nil }
        )

        XCTAssertEqual(cache.name(forPID: 42, fallback: "raw"), "raw")
        XCTAssertEqual(nameLookups, 0, "identity 都解析不出来时不该继续查名字")
    }

    /// 对真实 libproc 调用的冒烟测试：用测试宿主进程自己的 pid（保证此刻真实
    /// 存活），验证 `identityResolver` 默认实现（`proc_pidinfo` 查
    /// `pbi_start_tvsec`）确实接对了系统调用——如果常量或结构体字段用错，
    /// 这里会解析失败或返回错误的 pid。
    func testIdentityForPIDResolvesCurrentProcess() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var resolvedIdentity: ProcessProvider.ProcessIdentity?
        // identityResolver 用默认实现（真实 proc_pidinfo 调用）；resolve 换成
        // 探针，捕获默认 identityResolver 解析出的 identity 供断言。
        let cache = ProcessDisplayNameCache(resolve: { identity in
            resolvedIdentity = identity
            return nil
        })
        _ = cache.name(forPID: selfPID, fallback: "raw")

        let identity = try? XCTUnwrap(resolvedIdentity)
        XCTAssertEqual(identity?.pid, selfPID, "应该解析出测试宿主进程自己的 pid")
        XCTAssertNotNil(identity, "测试宿主进程此刻必然存活，identity 解析不应失败")
    }
}
