import AppKit
import Foundation

@main
enum LynxBarProcessQAHelperMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = LynxBarProcessQAHelperDelegate(arguments: ProcessInfo.processInfo.arguments)
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

@MainActor
private final class LynxBarProcessQAHelperDelegate: NSObject, NSApplicationDelegate {
    private let ignoresNormalTerminate: Bool
    private let heartbeatURL: URL?
    private var heartbeatTimer: Timer?
    private var window: NSWindow?

    init(arguments: [String]) {
        ignoresNormalTerminate = arguments.contains("--ignore-normal-terminate")
        if let index = arguments.firstIndex(of: "--heartbeat-path") {
            let valueIndex = arguments.index(after: index)
            heartbeatURL = valueIndex < arguments.endIndex
                ? URL(fileURLWithPath: arguments[valueIndex])
                : nil
        } else {
            heartbeatURL = nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let label = NSTextField(labelWithString: identityDescription)
        label.alignment = .center
        label.maximumNumberOfLines = 3

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "LynxBar Process QA Helper"
        window.contentView = label
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        writeHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: 0.25,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.writeHeartbeat()
            }
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        ignoresNormalTerminate ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private var identityDescription: String {
        let mode = ignoresNormalTerminate ? "ignore normal terminate" : "normal terminate"
        return "Disposable LynxBar QA helper\nPID \(getpid())\nMode: \(mode)"
    }

    private func writeHeartbeat() {
        guard let heartbeatURL else { return }
        let payload = "\(getpid()) \(Date().timeIntervalSince1970)\n"
        try? Data(payload.utf8).write(to: heartbeatURL, options: .atomic)
    }
}
