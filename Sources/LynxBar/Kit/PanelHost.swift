import AppKit

/// 无边框、可成为 key 窗口的弹出面板（用于接收键盘事件、Esc 关闭等）。
private final class StatusBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 管理某个 `NSStatusItem` 点击后弹出的下拉面板。
///
/// 用 `NSPanel` 手动定位（而非 `NSPopover`），避免 NSPopover 在状态栏 +
/// 多显示器场景下的坐标系问题，确保：
/// - 面板紧贴菜单栏图标正下方、水平居中；
/// - 只出现在图标所在的屏幕（多显示器场景正确）；
/// - 点击面板外部自动关闭。
@MainActor
final class PanelHost: NSObject, MonitoringDemandOwner {
    private weak var statusItem: NSStatusItem?
    private let makeContent: @MainActor (@escaping (DashboardSection) -> Void) -> NSViewController
    private var panel: StatusBarPanel?
    private var globalMonitor: Any?
    /// CALayer 的颜色是静态快照，不会随 NSAppearance 自动切换；用它监听
    /// contentView 的 effectiveAppearance，外观变化时手动刷新背景色。
    private var appearanceObservation: NSKeyValueObservation?

    private let cornerRadius: CGFloat = Theme.Radius.panel

    private let demandCoordinator: MonitoringDemandCoordinator
    private var sectionTokens: [DemandToken] = []
    private var currentSelection: DashboardSection = .overview

    /// 面板从可见变为关闭时触发一次。Task C.2 用它在历史落盘的 5 分钟节流
    /// 之外补一次低成本 flush；默认 nil，不设置时行为与之前完全一致。
    var onClose: (() -> Void)?

    init(
        statusItem: NSStatusItem,
        demandCoordinator: MonitoringDemandCoordinator,
        content: @escaping @MainActor (@escaping (DashboardSection) -> Void) -> NSViewController
    ) {
        self.statusItem = statusItem
        self.demandCoordinator = demandCoordinator
        self.makeContent = content
        super.init()
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func close() {
        let wasVisible = panel != nil
        panel?.orderOut(nil)
        panel = nil
        statusItem?.button?.highlight(false)
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        appearanceObservation = nil
        // 面板不可见即不再需要任何 panel(section) demand；下次打开时
        // DashboardView 总是从 .overview 的 @State 重新开始，这里同步复位，
        // 保证下次 show() 按 .overview 重新 acquire，而不是沿用上次关闭前的
        // section（那个 section 对应的 view 已经被丢弃）。
        releaseSectionTokens()
        currentSelection = .overview
        if wasVisible {
            onClose?()
        }
    }

    private func show() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }

        acquireSectionTokens(for: currentSelection)
        let viewController = makeContent { [weak self] section in
            self?.updateSelection(section)
        }
        let size = measureSize(for: viewController)

        let panel = StatusBarPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = viewController
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false

        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = cornerRadius
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
            contentView.layer?.borderWidth = 0.5
            applyPanelChrome(to: contentView)
            // observe(_:changeHandler:) 的闭包类型不携带 MainActor 隔离信息，编译器
            // 因此把它当成 nonisolated 上下文；effectiveAppearance 的变化实际总是在
            // 主线程上投递（AppKit 外观切换走主线程 UI 更新），用 assumeIsolated 显式
            // 断言，而不是 nonisolated(unsafe) 那种没有运行时校验的逃生舱。
            appearanceObservation = contentView.observe(\.effectiveAppearance) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    self?.applyPanelChrome(to: view)
                }
            }
        }

        position(panel: panel, button: button, buttonWindow: buttonWindow, size: size)
        self.panel = panel

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        button.highlight(true)
        installMonitor()
    }

    /// 在 view 自身的有效外观下解析面板背景（降低透明度时回退纯色）与 0.5pt 精密外框边。
    private func applyPanelChrome(to view: NSView) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            if Theme.shouldReduceTransparency {
                view.layer?.backgroundColor = Theme.panelBackground.cgColor
            } else {
                view.layer?.backgroundColor = NSColor.clear.cgColor
            }
            view.layer?.borderColor = Theme.nsPanelBorder.cgColor
        }
    }

    /// 测量内容期望尺寸（由 DashboardView 的 frame 固定宽高）。
    private func measureSize(for viewController: NSViewController) -> NSSize {
        let view = viewController.view
        view.layoutSubtreeIfNeeded()
        var size = view.fittingSize
        if size.width < 200 { size.width = 200 }
        if size.height < 200 { size.height = 200 }
        return size
    }

    /// 计算 panel 在屏幕上的位置：顶部居中对齐 button 底边，并约束在当前屏内。
    private func position(panel: NSPanel, button: NSButton, buttonWindow: NSWindow, size: NSSize) {
        // button frame 转到屏幕坐标（左下原点，y 向上为正）。
        let buttonOnScreen = buttonWindow.convertToScreen(button.frame)
        let anchorX = buttonOnScreen.midX
        // button 底边 ≈ 菜单栏下沿。
        let anchorBottomY = buttonOnScreen.minY

        // 用 button 所在的屏幕，确保多显示器下面板不跑到别的屏。
        let screen = buttonWindow.screen ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame

        var originX = anchorX - size.width / 2
        var originY = anchorBottomY - size.height

        // 水平：约束在屏内可见区域。
        originX = max(visible.minX, min(originX, visible.maxX - size.width))
        // 垂直：若超出屏底则上移到可见。
        if originY < visible.minY {
            originY = visible.minY
        }

        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    private func installMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    /// DashboardView 上报 section 切换时的回调。SwiftUI 可能为同一个可见
    /// section 反复重建 view 并重复上报（这也是不能用 View 结构体做 owner
    /// 的原因），因此这里对未变化的 section 直接短路，不做无意义的
    /// 释放再 acquire（那会触发一次不必要的 stop+restart）。
    ///
    /// 面板已经关闭（`panel == nil`）时也直接忽略：一个已关闭面板对应的
    /// 旧 DashboardView 理论上不应该还能回调到这里，但防御性地拦一次，
    /// 避免任何时序缝隙让已关闭面板重新产生 demand。
    private func updateSelection(_ section: DashboardSection) {
        guard panel != nil else { return }
        guard section != currentSelection else { return }
        currentSelection = section
        acquireSectionTokens(for: section)
    }

    private func acquireSectionTokens(for section: DashboardSection) {
        releaseSectionTokens()
        sectionTokens = MonitoringDemandBinding.modules(for: section).map { module in
            demandCoordinator.acquire(module: module, reason: .panel(section), owner: self)
        }
    }

    private func releaseSectionTokens() {
        sectionTokens.forEach { $0.cancel() }
        sectionTokens = []
    }
}
