import AppKit
import SwiftUI

@MainActor
final class DiskCleanupWindowController: NSWindowController,
    NSWindowDelegate {
    private let viewModel: DiskCleanupViewModel

    init(viewModel: DiskCleanupViewModel) {
        self.viewModel = viewModel
        let hostingController = NSHostingController(
            rootView: DiskCleanupView(viewModel: viewModel)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
            ],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString(
            "LynxBar — Free Up Space Safely",
            comment: ""
        )
        window.contentViewController = hostingController
        // NSHostingController 在首轮 SwiftUI layout 前的 fitting size 可能接近零；
        // 赋值后重新固定初始内容尺寸，避免首次打开只得到 1×0 的窗口。
        window.setContentSize(NSSize(width: 720, height: 560))
        window.minSize = NSSize(width: 640, height: 500)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.cancelActiveWork()
    }
}
