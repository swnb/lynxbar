import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MonitoringDemandOwner {
    /// LynxBarTests 是 hosted unit test：`xcodebuild test` 会拉起真实的
    /// LynxBar.app 作为宿主进程再把测试包注入进去，所以每次跑测试
    /// `applicationDidFinishLaunching` 都会真的执行一次。用这个判定跳过
    /// 会触碰用户真实数据目录的启动逻辑（历史加载/迁移、退出时 flush）。
    ///
    /// 已实测复核（Task C.2 报告有完整输出）：`xcodebuild test` 跑的宿主
    /// 进程里这个 key 存在（值是空字符串，不是 nil——所以判定必须用
    /// `!= nil`，不能假设是一个非空路径、更不能用 `.isEmpty` 判断）；
    /// `make run` 走的正常启动路径里这个 key 完全不存在。两个方向都有
    /// 实测输出佐证，不是假设。
    ///
    /// 标 `nonisolated`（Task C.3）：`flushHistorySoon()` 是 `nonisolated
    /// static func`（睡眠通知回调本身不在 MainActor 上），需要直接读这个值
    /// 而不跳线程。这个值是初始化一次即不变的 `Bool`，来自进程启动时就固定
    /// 的环境变量快照，跨 actor 读取没有数据竞争。
    nonisolated static let isRunningUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private var statusItem: NSStatusItem?
    private var menuBarPresenter: MenuBarStatusPresenter?
    private var panelHost: PanelHost?
    private var aboutWindowController: AboutWindowController?
#if DEBUG
    private var visualQAWindow: NSWindow?
    // Debug 验收窗口不经过 PanelHost 的开关/切换生命周期,只在窗口存活期间
    // 常驻持有,不必单独释放(进程退出即回收)。
    private var visualQATokens: [DemandToken] = []
#endif

    private let settings: Settings
    private let demandCoordinator: MonitoringDemandCoordinator
    private let cpu: CPUViewModel
    private let memory: MemoryViewModel
    private let disk: DiskViewModel
    private let network: NetworkViewModel
    private let gpu: GPUViewModel
    private let battery: BatteryViewModel
    private let process: ProcessViewModel
    private let thermal: ThermalViewModel
    private let accessoryPower: AccessoryPowerViewModel
    private let aiUsage: AIUsageViewModel
    private let processRemediationCoordinator: RemediationCoordinator
    /// 保持动作验证 bridge 的宿主寿命；sheet 不持有模块 demand token。
    private let processRemediationDemandBridge: RemediationDemandBridge
    private let diskCleanup: DiskCleanupFeature
    // Overview 健康判定需要的常驻信号(design.md:「轻量健康模块可由默认
    // overviewHealth 常驻」);由 AppDelegate 长期持有,不随面板开关释放。
    private var overviewHealthTokens: [DemandToken] = []
    // 系统睡眠前补一次历史落盘(Task C.2);持有 token 只是为了不让编译器
    // 警告未使用返回值,应用生命周期内不需要显式移除。
    private var sleepNotificationObserver: NSObjectProtocol?
    private var appearanceObservation: AnyCancellable?
    // load() 完成前打开面板会 acquire demand、立即触发采样,写入的样本随后会
    // 被异步完成的 load() 覆盖掉——与 overviewHealth/DEBUG QA 采样是同一类
    // 竞态,那两条已经靠"排在 load() 之后的同一个 Task 里"由构造保证
    // (Task C.2);面板由用户点击驱动,没法放进同一个 Task,所以改用这个标志位
    // 在 statusItemClicked() 里短路(Task C.3)。测试宿主下 load() 从不执行,
    // 初值直接取 isRunningUnderXCTest,避免可点击性永远卡在 false。
    private var isHistoryLoaded = AppDelegate.isRunningUnderXCTest

    /// Initializes the shared demand coordinator, monitoring view models, and remediation bridges.
    /// View models are constructed explicitly inside `init()` rather than as inline stored-property
    /// initializers to avoid a Swift 6.1.2 (Xcode 16.4) SILGen crash on default `@Sendable` closures.
    override init() {
        let settings = Settings.shared
        self.settings = settings
        let demandCoordinator = MonitoringDemandCoordinator()
        self.demandCoordinator = demandCoordinator
        self.cpu = CPUViewModel(settings: settings)
        self.memory = MemoryViewModel(settings: settings)
        self.disk = DiskViewModel(settings: settings)
        self.network = NetworkViewModel(settings: settings)
        self.gpu = GPUViewModel(settings: settings)
        self.battery = BatteryViewModel(settings: settings)
        self.process = ProcessViewModel(settings: settings)
        self.thermal = ThermalViewModel(settings: settings)
        self.accessoryPower = AccessoryPowerViewModel(settings: settings)
        self.aiUsage = AIUsageViewModel(settings: settings)
        self.diskCleanup = DiskCleanupFeature(demandCoordinator: demandCoordinator)
        let processBridge = RemediationDemandBridge(demandCoordinator: demandCoordinator)
        self.processRemediationDemandBridge = processBridge
        self.processRemediationCoordinator = RemediationCoordinator(
            onBeginVerification: { [weak processBridge] preparedID, kind in
                await processBridge?.begin(preparedID: preparedID, kind: kind)
            },
            onEndVerification: { [weak processBridge] preparedID in
                await processBridge?.end(preparedID: preparedID)
            }
        )
        super.init()
        demandCoordinator.onDemandChange = { [weak self] module, isDemanded in
            self?.handleDemandChange(module: module, isDemanded: isDemanded)
        }
    }

    /// 把「谁还需要这个模块」的 0↔1 边沿路由到对应 ViewModel 的
    /// start/stop。networkProcessAttribution 没有独立 ViewModel,路由到
    /// NetworkViewModel 上与基础采样正交的 startAttribution/stopAttribution。
    private func handleDemandChange(module: MonitoringModule, isDemanded: Bool) {
        switch module {
        case .cpu:
            isDemanded ? cpu.startSampling() : cpu.stopSampling()
        case .memory:
            isDemanded ? memory.startSampling() : memory.stopSampling()
        case .disk:
            isDemanded ? disk.startSampling() : disk.stopSampling()
        case .network:
            isDemanded ? network.startSampling() : network.stopSampling()
        case .gpu:
            isDemanded ? gpu.startSampling() : gpu.stopSampling()
        case .battery:
            isDemanded ? battery.startSampling() : battery.stopSampling()
        case .process:
            isDemanded ? process.startSampling() : process.stopSampling()
        case .networkProcessAttribution:
            isDemanded ? network.startAttribution() : network.stopAttribution()
        case .thermal:
            isDemanded ? thermal.startSampling() : thermal.stopSampling()
        case .numericTemperature:
            isDemanded ? thermal.numericTemperature.startSampling() : thermal.numericTemperature.stopSampling()
        case .accessoryPower:
            isDemanded ? accessoryPower.startSampling() : accessoryPower.stopSampling()
        case .aiUsage:
            isDemanded ? aiUsage.startSampling() : aiUsage.stopSampling()
        }
    }

    /// Initializes application appearance, status bar presentation, sleep flush observer, and startup history load.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply persisted appearance preference (`.system` by default) before creating windows/panels,
        // and react to live changes in Settings without triggering `@Published` `willSet` stale reads.
        applyAppearance(settings.appearanceMode)
        observeAppearanceChanges()
        setupStatusItem()
        subscribeToSleepNotification()

        // LynxBarTests 是 hosted unit test：跑测试会拉起这个真实的 LynxBar.app
        // 作为宿主进程，applicationDidFinishLaunching 因此每次跑测试都会
        // 真的执行一次。测试宿主不得触碰用户真实数据目录——load() 里的
        // 一次性迁移会改名旧文件、写新文件，跑一次单测就改一次用户数据是
        // 不能接受的（实测复核过：改动前 init() 只同步读盘，测试宿主顶多
        // 读一下；改动后这里会写)。所以测试宿主直接跳过加载/采样启动。
        //
        // 历史归档改为显式异步加载(Task C.2),必须等 load() 完成后才能让
        // overviewHealth 常驻 demand 触发采样启动——否则首批样本会先写进
        // 空归档,随后被异步完成的 load() 覆盖掉。
        //
        // Overview 常驻的健康信号;面板 Tab 的显隐由设置开关控制导航,
        // 不隐式覆盖这份常驻 demand(design.md 的既有约定)。
        if !Self.isRunningUnderXCTest {
            Task {
                await MetricHistoryStore.shared.load()
                isHistoryLoaded = true
                // 菜单发布订阅可以先建立，但 acquire 必须排在 history load 后。
                // XCTest 宿主不进入本分支，因此不会因 compact 默认值启动真实采样。
                menuBarPresenter?.startDemand()
                overviewHealthTokens = MonitoringDemandBinding.overviewHealthModules.map { module in
                    demandCoordinator.acquire(module: module, reason: .overviewHealth, owner: self)
                }

#if DEBUG
                // DEBUG 验收窗口自己也会 acquire demand、立即触发采样，同样
                // 必须排在 load() 之后——否则截图验收路径下也会出现"首个样本
                // 写进空归档、被 load() 覆盖"的问题，跟 overviewHealth 是
                // 同一类 bug（Task C.2 报告曾把这个记录为已知限制，这里顺手
                // 修掉：搬进同一个 Task 只是调整执行时机，不改变任何判断逻辑）。
                if ProcessInfo.processInfo.arguments.contains(
                    "--visual-qa-cleanup"
                ) {
                    // 仅验收参数下临时成为普通前台 App，让 app-scoped 自动化能够读取
                    // 这个窗口；正式菜单栏运行和 Release 仍保持 LSUIElement / accessory。
                    NSApp.setActivationPolicy(.regular)
                    diskCleanup.showWindow()
                    if let root = visualQACleanupRoot() {
                        // 可选 root 仅用于 disposable fixture 的 review-state 截图；
                        // 仍走正式 root policy 与 scanner，不绕过任何安全检查。
                        diskCleanup.viewModel.startScan(at: root)
                    }
                    // Task E.2：DiskCleanup 用的是独立 NSWindowController，没有像
                    // showVisualQAWindow 那样把 NSWindow 暴露出来；不为此改
                    // DiskCleanupWindowController 的公开面，改用标题匹配从
                    // NSApp.windows 里找回来——只用于本次性验收，不是产品逻辑。
                    if let capturePath = visualQACapturePath() {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(600))
                            guard let window = NSApp.windows.first(where: {
                                $0.title == NSLocalizedString(
                                    "LynxBar — Free Up Space Safely",
                                    comment: ""
                                )
                            }) else { return }
                            Self.captureVisualQASnapshot(window: window, to: capturePath)
                        }
                    }
                } else if let selection = visualQASelection() {
                    // 清理窗口和面板 QA 模式互斥，避免两个 key window 竞争输入。
                    NSApp.setActivationPolicy(.regular)
                    showVisualQAWindow(selection: selection)
                }
#endif
            }
        }

        // 用 SMAppService 的实际状态同步设置开关。
        settings.launchAtLogin = LaunchAtLogin.isEnabled
    }

    /// Applies the selected `AppAppearanceMode` to `NSApp` so panels and auxiliary windows update together.
    private func applyAppearance(_ mode: AppAppearanceMode) {
        NSApp?.appearance = mode.nsAppearance
    }

    /// Subscribes to `Settings.$appearanceMode`, consuming the emitted new value directly.
    private func observeAppearanceChanges() {
        appearanceObservation = settings.$appearanceMode
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] mode in
                self?.applyAppearance(mode)
            }
    }

    /// Change A 没有建立任何 NSWorkspace 睡眠通知订阅(已核实全项目无
    /// willSleepNotification / addObserver 用法);这里新增一个,在系统睡眠前
    /// 补一次历史落盘,缩小 5 分钟落盘节流可能丢失的窗口(Task C.2)。
    private func subscribeToSleepNotification() {
        sleepNotificationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { _ in
            Self.flushHistorySoon()
        }
    }

    /// 5 分钟落盘节流意味着定时落盘之间最多丢 5 分钟历史,所以在睡眠前、
    /// 面板关闭这类低成本时机补一次 flush,缩小丢失窗口。flush() 内部有
    /// isDirty 门槛,没有新数据时是廉价的空操作;标 nonisolated 是因为
    /// 睡眠通知回调本身不在 MainActor 上,不需要为了调用这一个方法而跳线程。
    ///
    /// 测试宿主下的安全性本来可以靠间接推理成立(采样从不启动 → record()
    /// 不可达 → isDirty 恒为 false → flush() 是空操作),但
    /// applicationShouldTerminate 已经明确不依赖这条间接推理、直接短路——
    /// 两条路径的安全性不该一条绕一圈证明、另一条不绕,这里补上同样的直接
    /// 保护(Task C.3)。
    private nonisolated static func flushHistorySoon() {
        guard !Self.isRunningUnderXCTest else { return }
        Task {
            do {
                try await MetricHistoryStore.shared.flush()
            } catch {
                Log.history.error(
                    "Failed to flush metric history: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    // MARK: - 菜单栏主图标

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image: NSImage?
            if let custom = NSImage(named: NSImage.Name("MenuBarIcon")),
               !custom.representations.isEmpty {
                custom.isTemplate = true
                custom.accessibilityDescription = "LynxBar"
                image = custom
            } else {
                let fallback = NSImage(
                    systemSymbolName: "speedometer",
                    accessibilityDescription: "LynxBar"
                )
                fallback?.isTemplate = true
                image = fallback
            }
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        menuBarPresenter = MenuBarStatusPresenter(
            statusItem: item,
            settings: settings,
            cpu: cpu,
            memory: memory,
            disk: disk,
            network: network,
            gpu: gpu,
            battery: battery,
            thermal: thermal,
            accessoryPower: accessoryPower,
            aiUsage: aiUsage,
            demandCoordinator: demandCoordinator
        )

        panelHost = PanelHost(statusItem: item, demandCoordinator: demandCoordinator) {
            [
                cpu,
                memory,
                disk,
                network,
                gpu,
                battery,
                process,
                thermal,
                accessoryPower,
                aiUsage,
                processRemediationCoordinator,
                diskCleanup
            ] onSelectionChange in
            NSHostingController(rootView: DashboardView(
                cpu: cpu,
                memory: memory,
                disk: disk,
                network: network,
                gpu: gpu,
                battery: battery,
                process: process,
                thermal: thermal,
                accessoryPower: accessoryPower,
                aiUsage: aiUsage,
                onSelectionChange: onSelectionChange,
                openDiskCleanup: diskCleanup.showWindow
            )
            .environment(\.processRemediationCoordinator, processRemediationCoordinator))
        }
        // 面板关闭是历史落盘节流之外补 flush 的另一个低成本时机(Task C.2)。
        panelHost?.onClose = {
            Self.flushHistorySoon()
        }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else if isHistoryLoaded {
            panelHost?.toggle()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let about = NSMenuItem(title: NSLocalizedString("About LynxBar", comment: ""), action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: NSLocalizedString("Quit LynxBar", comment: ""), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.maxX, y: button.bounds.minY), in: button)
    }

    @objc private func openAbout() {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarPresenter?.invalidate()
        panelHost?.close()
        thermal.stopSampling()
        thermal.numericTemperature.stopSampling()
        accessoryPower.stopSampling()
        aiUsage.stopSampling()
        cpu.stopSampling()
        memory.stopSampling()
        disk.stopSampling()
        network.stopSampling()
        gpu.stopSampling()
        battery.stopSampling()
        process.stopSampling()
        diskCleanup.shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 测试宿主进程里历史归档从未被加载(见 applicationDidFinishLaunching
        // 的判定),archive 一直是空的、isDirty 一直是 false,flush() 本身
        // 已经是空操作；这里额外直接跳过，不依赖那条间接推理，退出路径的
        // 安全性不应该绕一圈去证明。
        guard !Self.isRunningUnderXCTest else {
            return .terminateNow
        }
        Task {
            await Self.flushHistoryThenReply(to: sender)
        }
        return .terminateLater
    }

    /// flush() 卡住(例如磁盘 IO 异常)不能让 App 永远退不出去,所以退出路径的
    /// flush 设超时:谁先完成——flush 本身还是超时——就放行退出,不等另一个
    /// (Task C.2)。
    ///
    /// 注意：这条"卡住后超时放行"路径目前没有自动化测试覆盖——需要能从
    /// 测试侧让 `MetricHistoryStore.persistIfNeeded()` 内部的磁盘 IO 永久
    /// 挂起才能验证，现有代码结构不支持注入这种故障。已用真实环境验证过
    /// "flush 正常完成、立刻放行退出"这条快路径（见 Task C.2 报告的实机
    /// 验证），"真卡住"这条分支只有设计走查支撑，接受这个已知缺口。
    private static func flushHistoryThenReply(to sender: NSApplication) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await CodexBarUsageProvider.shutdownPersistentSessions()
                do {
                    try await MetricHistoryStore.shared.flush()
                } catch {
                    Log.history.error(
                        "Failed to flush metric history during termination: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
            group.addTask {
                try? await Task.sleep(for: SamplingPolicy.terminationFlushTimeout)
            }
            await group.next()
            sender.reply(toApplicationShouldTerminate: true)
            group.cancelAll()
        }
    }

#if DEBUG
    /// 原生验收宿主使用与菜单栏面板完全相同的 DashboardView，仅增加可裁掉的标题栏。
    private func showVisualQAWindow(selection: DashboardSection) {
        // 这个调试窗口不经过 PanelHost 的显隐生命周期，必须自己为要截图的
        // section acquire 一次 panel demand，否则 GPU / Battery / Process /
        // networkProcessAttribution 这些不在 overviewHealth 常驻范围内的模块
        // 会在 QA 截图里静默停在「collecting」——不是功能问题，但会让既有的
        // design-qa 截图基线失真。
        visualQATokens = MonitoringDemandBinding.modules(for: selection).map { module in
            demandCoordinator.acquire(module: module, reason: .panel(selection), owner: self)
        }

        let isRecording = ProcessInfo.processInfo.arguments.contains(
            "--visual-qa-recording"
        )
        let controller = NSHostingController(
            rootView: DashboardView(
                cpu: cpu,
                memory: memory,
                disk: disk,
                network: network,
                gpu: gpu,
                battery: battery,
                process: process,
                thermal: thermal,
                accessoryPower: accessoryPower,
                aiUsage: aiUsage,
                initialSelection: selection,
                openDiskCleanup: diskCleanup.showWindow
            )
            .environment(\.processRemediationCoordinator, processRemediationCoordinator)
            // 高帧率验收期间隔离其他任务的鼠标事件，避免范围切换或滚动
            // 污染逐帧证据；普通 QA 模式仍保留完整交互能力。
            .allowsHitTesting(!isRecording)
            // Task E.2：注入指定 Dynamic Type 字号，用于在真实 420×600 固定
            // 窗口里验收大字号下的布局（截断/重叠）。未指定时落在 .large——
            // 系统默认字号，不影响没有传这个参数的既有 QA 流程。
            //
            // 已知限制（实测记录，不是没验证过）：在当前 macOS 26.5 + 这套
            // Xcode 工具链下，`.dynamicTypeSize()` 对本 App 里 `Font.system(
            // .textStyle)` 渲染出的实际字号没有可观测影响——用这个 QA 窗口在
            // xSmall 和 accessibility5 之间对比过 PNG 自截图（字节级 md5 相同）、
            // 也在独立的 NSHostingView + fittingSize 探测测试里验证过同样结论
            // （两档 fittingSize.width 完全相等），换 `\.sizeCategory` 这个更老
            // 的环境 key 结果一样。怀疑是 macOS 这一版的系统级字号缩放直接读
            // 真实的系统辅助功能「文字大小」偏好、不经过 SwiftUI 环境树，因此
            // 这个 hook 目前在自动化/沙盒场景下是启动即失效的最佳努力实现——
            // 保留是因为语义上是正确写法，一旦平台行为修正或换到会读取真实
            // 系统偏好的宿主环境，不需要再改这里。任务 E.2 报告里有完整记录，
            // 大字号布局验证改成了纯源码层面的静态风险审查。
            .dynamicTypeSize(visualQATextSize() ?? .large)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // QA 只覆盖当前验收窗口，不修改用户系统外观或菜单栏系统语义。
        let appearanceArguments = ProcessInfo.processInfo.arguments
        if let index = appearanceArguments.firstIndex(of: "--visual-qa-appearance"),
           appearanceArguments.indices.contains(index + 1) {
            switch appearanceArguments[index + 1] {
            case "light": window.appearance = NSAppearance(named: .aqua)
            case "dark": window.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
        }
        window.title = "LynxBar V2 QA — \(selection.rawValue)"
        window.contentViewController = controller
        // 固定到全局主坐标系，避免启动者当前所在的外接显示器/Space
        // 把 QA 窗口居中到屏幕外，进而无法进行逐帧录制。
        window.setFrameOrigin(NSPoint(x: 100, y: 100))
        window.isReleasedWhenClosed = false
        if isRecording {
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        visualQAWindow = window

        // Task E.2：非交互 agent 会话里没有 Screen Recording 权限，`screencapture`
        // 会直接报 "could not create image from display"（已实测复核），且这个
        // 权限没有办法在非交互场景下临时授予——也不应该去尝试绕过。这里换一条不
        // 经过 CGWindowServer 截屏 API 的路：等 SwiftUI 完成一帧布局后，让窗口的
        // contentView 把自己缓存进离屏 bitmap 再编码成 PNG。这是 NSView 画自己，
        // 不是"抓取屏幕"，不受该 TCC 门槛限制。
        if let capturePath = visualQACapturePath() {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                Self.captureVisualQASnapshot(window: window, to: capturePath)
            }
        }
    }

    private func visualQACapturePath() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--visual-qa-capture") else {
            return nil
        }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        return arguments[next]
    }

    /// Captures a window snapshot bitmap and writes it as PNG to the QA output path.
    private static func captureVisualQASnapshot(window: NSWindow, to path: String) {
        guard let contentView = window.contentView,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        else { return }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            Log.app.error(
                "Failed to write visual QA snapshot to \(path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func visualQASelection() -> DashboardSection? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--visual-qa") else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return .overview }
        let requestedSection = arguments[next]
        return DashboardSection.allCases.first {
            $0.rawValue.caseInsensitiveCompare(requestedSection) == .orderedSame
        } ?? .overview
    }

    /// `--visual-qa-text-size <name>` 支持的取值,对应 `DynamicTypeSize`
    /// 全部 12 档,大小写不敏感。显式建表而不是拿 `DynamicTypeSize` 的枚举
    /// case 名反推字符串——反推依赖"枚举默认 description 就是 case
    /// 名"这条没有编译期保障的隐式假设，一旦不成立这里会静默匹配不上、
    /// 参数全部失效却没有任何报错，建表更直接也更抗意外。
    private static let visualQATextSizesByName: [String: DynamicTypeSize] = [
        "xsmall": .xSmall,
        "small": .small,
        "medium": .medium,
        "large": .large,
        "xlarge": .xLarge,
        "xxlarge": .xxLarge,
        "xxxlarge": .xxxLarge,
        "accessibility1": .accessibility1,
        "accessibility2": .accessibility2,
        "accessibility3": .accessibility3,
        "accessibility4": .accessibility4,
        "accessibility5": .accessibility5,
    ]

    private func visualQATextSize() -> DynamicTypeSize? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--visual-qa-text-size") else {
            return nil
        }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        return Self.visualQATextSizesByName[arguments[next].lowercased()]
    }

    private func visualQACleanupRoot() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(
            of: "--visual-qa-cleanup-root"
        ) else {
            return nil
        }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        return URL(
            fileURLWithPath: arguments[next],
            isDirectory: true
        )
    }
#endif
}
