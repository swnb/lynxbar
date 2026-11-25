import AppKit
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(Theme.Font.largeTitle)
                .foregroundStyle(.tint)
            Text("LynxBar").font(.title.bold())
            Text(AppInfo.versionString).foregroundStyle(.secondary)
            Text("macOS menu bar system monitor")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(36)
        .frame(width: 300)
    }
}

@MainActor
final class AboutWindowController: NSWindowController {
    init() {
        let controller = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: controller)
        window.title = NSLocalizedString("About LynxBar", comment: "")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
