import AppKit

/// 进程显示名缓存。
///
/// `NSRunningApplication(processIdentifier:)` 要跨进程查 LaunchServices，
/// 本机枚举出的进程数（数百个）远大于面板实际展示的 Top N（默认 10），
/// 逐个查询会明显占用主线程。这里按 `ProcessProvider.ProcessIdentity`
/// （pid + start time，口径与 `ProcessProvider` 一致）缓存结果，含「查不到」
/// 的结果本身——命令行进程之类查不到 `NSRunningApplication` 的，不应该
/// 每轮都白查一遍。
///
/// pid 会被复用：同一 pid 的旧进程退出、新进程复用该 pid 后，start time
/// 不同，产生的是不同的 `ProcessIdentity`，天然不会命中旧缓存条目——不需要
/// 显式失效。`retain(identities:)` 只负责驱逐已经不存在的 identity，避免
/// 缓存随进程反复起停无限增长；`capacity` 是不依赖 `retain(identities:)`
/// 调用链的独立保底（`NetworkViewModel` 不调用 `retain(identities:)`，见
/// 该文件 `publishProcessAttribution()` 上的注释）。
@MainActor
final class ProcessDisplayNameCache {
    /// 依赖注入默认使用的共享实例（`ProcessViewModel`/`NetworkViewModel`
    /// 的 `nameCache` 参数默认值）。**测试如果不显式传入 `nameCache:`，会
    /// 复用这个进程级单例的可变状态**——多个测试用例之间可能相互污染
    /// （比如某个测试真的解析出的名字，被同一测试进程里跑在它之后的另一个
    /// 测试意外命中缓存）。目前测试套件里没有依赖 `.shared` 的默认值做
    /// 断言（全部显式构造独立实例注入），但这是潜在的 flaky 来源；未来新增
    /// 测试如果需要对具体解析结果做断言，必须显式构造独立的
    /// `ProcessDisplayNameCache` 实例，不要依赖 `.shared`。
    static let shared = ProcessDisplayNameCache()

    /// 负缓存（查不到）的存活时间。查不到不等于永远查不到——`resolve`
    /// 默认实现基于 `NSRunningApplication`，刚启动的 GUI App 在完成
    /// LaunchServices 注册前会短暂查询失败，这个 race 通常在数百毫秒到
    /// 几秒内自愈；如果永久缓存这个 nil，该进程在 LynxBar 重启之前会一直
    /// 显示内核原始名而不是本地化应用名——这是缓存本身引入的新失败模式，
    /// 改动前（每轮都真实查询）不存在。
    ///
    /// 取 30 秒：约为 `ProcessViewModel` 默认采样间隔（`Settings.updateInterval`
    /// 默认 2 秒）与 `NetworkViewModel` 归因间隔（固定 3 秒）的 10-15 倍。
    /// 对真正没有显示名的进程（`kernel_task`、后台 daemon——这类在存活
    /// 进程里占多数）而言，绝大多数采样周期仍然命中缓存，不会明显侵蚀
    /// Top N 优化带来的收益（见 `task-D.1-report.md` 里加 TTL 前后的实测
    /// 对比）；对短暂未注册的 GUI App 而言，30 秒内会被重新解析、显示名
    /// 自动恢复，不需要用户重启 LynxBar。
    ///
    /// 正缓存（真的解析成功）没有 TTL——`ProcessIdentity` 已经把 pid 复用
    /// 的情况分离成不同的键，同一个 identity 对应的进程不会中途改名。
    static let negativeCacheTTL: TimeInterval = 30

    private enum Entry {
        case resolved(String)
        case unresolved(cachedAt: Date)
    }

    private let resolve: (ProcessProvider.ProcessIdentity) -> String?
    private let identityResolver: (Int32) -> ProcessProvider.ProcessIdentity?
    private let now: () -> Date
    private let capacity: Int
    private var cache: [ProcessProvider.ProcessIdentity: Entry] = [:]

    init(
        capacity: Int = 256,
        resolve: @escaping (ProcessProvider.ProcessIdentity) -> String? =
            ProcessDisplayNameCache.systemResolve,
        identityResolver: @escaping (Int32) -> ProcessProvider.ProcessIdentity? =
            ProcessDisplayNameCache.systemIdentity,
        now: @escaping () -> Date = { Date() }
    ) {
        self.capacity = max(1, capacity)
        self.resolve = resolve
        self.identityResolver = identityResolver
        self.now = now
    }

    /// 返回 `identity` 对应的显示名；查不到时返回 `fallback`（同时把「查不到」
    /// 这个结果本身缓存下来，直到 `negativeCacheTTL` 过期才重试）。调用方
    /// 已经知道完整身份（pid + start time）时走这个入口——`ProcessViewModel`
    /// 的采样结果自带 `identity`，是这里。
    func name(for identity: ProcessProvider.ProcessIdentity, fallback: String) -> String {
        if let entry = cache[identity] {
            switch entry {
            case let .resolved(name):
                return name
            case let .unresolved(cachedAt):
                if now().timeIntervalSince(cachedAt) < Self.negativeCacheTTL {
                    return fallback
                }
                // 负缓存已过期，落到下面按未命中处理，重新解析一次。
            }
        }
        // 容量硬上限：不依赖 retain(identities:) 是否被调用过，独立兜住
        // 无限增长（NetworkViewModel 不调用 retain(identities:)，理由见
        // NetworkViewModel.swift）。
        if cache.count >= capacity {
            cache.removeAll()
        }
        guard let resolved = resolve(identity) else {
            cache[identity] = .unresolved(cachedAt: now())
            return fallback
        }
        cache[identity] = .resolved(resolved)
        return resolved
    }

    /// 只有裸 pid、没有 start time 时的入口。`NetworkViewModel` 的进程流量
    /// 数据来自 nettop 的 CSV 输出，只有 pid，没有 start time，因此每次调用
    /// 都要重新解析一次 identity（不能把 identity 本身缓存起来——那样就退化
    /// 回「pid → identity」的裸 pid 缓存，会在 pid 复用时把旧身份沿用给新
    /// 进程）；identity 解析不出来（进程已经不在）时直接回退，不写入缓存。
    func name(forPID pid: Int32, fallback: String) -> String {
        guard let identity = identityResolver(pid) else { return fallback }
        return name(for: identity, fallback: fallback)
    }

    /// 只保留仍然存活的 identity；不在 `identities` 内的一律驱逐。
    ///
    /// 调用方应传入本轮采样到的全部存活集合（不只是 Top N），这样暂时跌出
    /// Top N、但还活着的进程不会白白丢失已缓存的名字，下次重新进入 Top N
    /// 时也不用再查一次 LaunchServices。
    func retain(identities: Set<ProcessProvider.ProcessIdentity>) {
        cache = cache.filter { identities.contains($0.key) }
    }

    /// `nonisolated`：不访问任何 `self`/MainActor 隔离状态，纯粹是对入参
    /// pid 的系统查询。标 `nonisolated` 是为了能作为 `init` 默认参数值——
    /// 存量属性 `resolve` 的类型是不带 `@MainActor` 的裸闭包类型，如果这个
    /// 静态方法保持隐式的 `@MainActor` 隔离（类级别标注会让所有成员默认
    /// 隔离），编译器会拒绝把它转成裸闭包类型（"loses global actor
    /// 'MainActor'"）。
    private nonisolated static func systemResolve(
        _ identity: ProcessProvider.ProcessIdentity
    ) -> String? {
        guard let name = NSRunningApplication(
            processIdentifier: identity.pid
        )?.localizedName else {
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 从裸 pid 解析 `ProcessIdentity`，用的是与 `ProcessProvider.sample()`
    /// 相同的 libproc 调用（`proc_pidinfo` 查 `pbi_start_tvsec`）。只在
    /// Top N 上调用：一次本地 `proc_pidinfo` 远比跨进程的 LaunchServices
    /// 查询便宜，成本可以忽略。
    private nonisolated static func systemIdentity(_ pid: Int32) -> ProcessProvider.ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) > 0,
              info.pbi_start_tvsec > 0 else {
            return nil
        }
        return ProcessProvider.ProcessIdentity(pid: pid, startTime: info.pbi_start_tvsec)
    }
}
