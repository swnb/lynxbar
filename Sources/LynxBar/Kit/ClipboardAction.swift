import AppKit
import Foundation

enum ClipboardAction {
    /// 把副作用隔离为 writer，确保 XCTest 能验证“精确复制”与空值保护。
    static func copy(_ value: String, using writer: (String) -> Bool) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return writer(value)
    }

    @MainActor
    static func copyToPasteboard(_ value: String) -> Bool {
        copy(value) { exactValue in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(exactValue, forType: .string)
        }
    }
}
