import AppKit
import SwiftUI

/// Displays the LynxBar application icon, version, and product summary in the About window.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("LynxBar").font(Theme.Font.title.bold())
            Text(AppInfo.versionString).foregroundStyle(.secondary)
            Text("macOS menu bar system monitor")
                .font(Theme.Font.callout)
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
