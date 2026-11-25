import AppKit

/// 进程图标缓存。
///
/// `NSRunningApplication(processIdentifier:)` 要跨进程查 LaunchServices，
/// `NSWorkspace.icon(forFile:)` 还要读盘走 IconServices。原先这段逻辑在
/// SwiftUI View 的计算属性里，每次 body 求值都重新执行一遍——面板打开时
/// 每个采样周期 × 每一行都要来一遍。这里按 `ProcessProvider.ProcessIdentity`
/// （pid + start time，口径与 `ProcessDisplayNameCache` 一致）缓存结果，含
/// 「查不到」的结果本身——命令行进程之类没有 bundle 图标的，不应该每轮都
/// 白查一遍。
///
/// pid 会被复用：同一 pid 的旧进程退出、新进程复用该 pid 后，start time
/// 不同，产生的是不同的 `ProcessIdentity`，天然不会命中旧缓存条目——不需要
/// 显式失效。`retain(identities:)` 只负责驱逐已经不存在的 identity，避免
/// 缓存随进程反复起停无限增长；`capacity` 是不依赖 `retain(identities:)`
/// 调用链的独立保底（`retain` 只在 `.process` demand 被 acquire——即
/// Overview/CPU/Memory 面板打开——时才会跑；只开 Network 面板、图标经
/// `icon(forPID:)` 惰性加载的场景下，`retain` 可能长期不触发）。
@MainActor
final class ProcessIconCache {
    /// 依赖注入默认使用的共享实例（`ProcessViewModel` 的 `iconCache` 参数
    /// 默认值）。测试如果不显式传入 `iconCache:`，会复用这个进程级单例的
    /// 可变状态；目前测试套件里没有依赖 `.shared` 的默认值做断言（全部显式
    /// 构造独立实例注入），但这是潜在的 flaky 来源——与 `ProcessDisplayNameCache`
    /// 同理，未来新增测试如果需要对具体缓存结果做断言，必须显式构造独立的
    /// `ProcessIconCache` 实例，不要依赖 `.shared`。
    static let shared = ProcessIconCache()

    /// 负缓存（查不到）的存活时间。查不到不等于永远查不到——`load` 默认实现
    /// 基于 `NSRunningApplication`，刚启动的 GUI App 在完成 LaunchServices
    /// 注册前会短暂查询失败（`bundleURL`/`executableURL` 尚不可用），这个
    /// race 通常在数百毫秒到几秒内自愈；如果永久缓存这次 nil，该进程在
    /// LynxBar 重启之前会一直显示通用终端符号而不是真实应用图标——这是缓存
    /// 本身引入的新失败模式，改动前（每轮都真实查询）不存在。
    ///
    /// 取值与 `ProcessDisplayNameCache.negativeCacheTTL` 保持一致（30 秒，
    /// 约为采样节奏的 10-15 倍），理由相同：对真正没有图标的进程（命令行
    /// 工具、后台 daemon）而言，绝大多数采样周期仍然命中负缓存，不会明显
    /// 侵蚀缓存收益；对短暂未注册的 GUI App 而言，30 秒内会被重新加载、
    /// 图标自动恢复。
    ///
    /// 正缓存（真的加载到图标）没有 TTL——`ProcessIdentity` 已经把 pid 复用
    /// 分离成不同的键，同一个 identity 对应的进程图标不会中途改变。
    static let negativeCacheTTL: TimeInterval = 30

    private enum Entry {
        case resolved(NSImage)
        case unresolved(cachedAt: Date)
    }

    private let load: (ProcessProvider.ProcessIdentity) -> NSImage?
    private let identityResolver: (Int32) -> ProcessProvider.ProcessIdentity?
    private let now: () -> Date
    private let capacity: Int
    private var cache: [ProcessProvider.ProcessIdentity: Entry] = [:]

    init(
        capacity: Int = 256,
        load: @escaping (ProcessProvider.ProcessIdentity) -> NSImage? =
            ProcessIconCache.systemLoad,
        identityResolver: @escaping (Int32) -> ProcessProvider.ProcessIdentity? =
            ProcessIconCache.systemIdentity,
        now: @escaping () -> Date = { Date() }
    ) {
        self.capacity = max(1, capacity)
        self.load = load
        self.identityResolver = identityResolver
        self.now = now
    }

    /// 返回 `identity` 对应的图标；查不到时返回 nil（调用方回退到系统符号，
    /// 同时把「查不到」这个结果本身缓存下来，直到 `negativeCacheTTL` 过期
    /// 才重试）。调用方已经知道完整身份（pid + start time）时走这个入口——
    /// `DisplayProcess` 自带 identity 的场景（CPU/Memory/Overview 榜单）
    /// 都从这里查。
    func icon(for identity: ProcessProvider.ProcessIdentity) -> NSImage? {
        if let entry = cache[identity] {
            switch entry {
            case let .resolved(icon):
                return icon
            case let .unresolved(cachedAt):
                if now().timeIntervalSince(cachedAt) < Self.negativeCacheTTL {
                    return nil
                }
                // 负缓存已过期，落到下面按未命中处理，重新加载一次。
            }
        }
        // 超限时整体清空而不是只驱逐最旧的一部分（LRU）：正常路径下
        // `retain(identities:)` 已经把稳态缓存条目数摁在「当前存活且近期
        // 渲染过」的进程集合，远小于 256（本机实测存活进程总数~100 出头，
        // Top N 默认 10——即使把全部存活进程的图标都缓存下来也到不了
        // capacity），触发这条分支本身就意味着 retain() 没有正常运行（比如
        // 长时间只开 Network 面板）这种边缘场景。触发时的代价是"下一次访问
        // 缓存里原有条目要重新加载一次"，是一次性、自愈的抖动，不是每周期
        // 都要付的稳态成本。为这个边缘场景引入 LRU 需要额外的访问顺序簿记，
        // 换来的收益（避免偶发的几次重新加载）撑不起这份复杂度——YAGNI。
        if cache.count >= capacity { cache.removeAll() }
        guard let icon = load(identity) else {
            cache[identity] = .unresolved(cachedAt: now())
            return nil
        }
        cache[identity] = .resolved(icon)
        return icon
    }

    /// 只有裸 pid、没有 start time 时的入口。Network 面板的进程流量数据来自
    /// nettop 的 CSV 输出，只有 pid，没有 start time，因此每次调用都要重新
    /// 解析一次 identity（不能把 identity 本身缓存起来——那样就退化回
    /// 「pid → identity」的裸 pid 缓存，会在 pid 复用时把旧身份沿用给新
    /// 进程）；identity 解析不出来（进程已经不在）时直接返回 nil，不写入缓存。
    func icon(forPID pid: Int32) -> NSImage? {
        guard let identity = identityResolver(pid) else { return nil }
        return icon(for: identity)
    }

    /// 只保留仍然存活的 identity；不在 `identities` 内的一律驱逐。
    ///
    /// 调用方应传入本轮采样到的全部存活集合（不只是 Top N），这样暂时跌出
    /// Top N、但还活着的进程不会白白丢失已缓存的图标，下次重新进入 Top N
    /// 时也不用再读一次盘。
    func retain(identities: Set<ProcessProvider.ProcessIdentity>) {
        cache = cache.filter { identities.contains($0.key) }
    }

    /// `nonisolated`：不访问任何 `self`/MainActor 隔离状态，纯粹是对入参
    /// identity 的系统查询。标 `nonisolated` 是为了能作为 `init` 默认参数值
    /// ——原因与 `ProcessDisplayNameCache.systemResolve` 相同：`load` 属性的
    /// 类型是不带 `@MainActor` 的裸闭包类型，如果这个静态方法保持隐式的
    /// `@MainActor` 隔离，编译器会拒绝把它转成裸闭包类型。
    private nonisolated static func systemLoad(
        _ identity: ProcessProvider.ProcessIdentity
    ) -> NSImage? {
        guard let application = NSRunningApplication(processIdentifier: identity.pid),
              let url = application.bundleURL ?? application.executableURL else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
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
