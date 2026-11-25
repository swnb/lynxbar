import ServiceManagement

/// 开机自启封装（SMAppService，macOS 13+）。
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters LynxBar as a login item via `SMAppService`, logging non-fatal failures.
    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Unpackaged or unsigned development builds cannot always register with SMAppService.
            Log.app.warning(
                "Failed to update launch-at-login (\(enabled, privacy: .public)): \(error.localizedDescription, privacy: .private)"
            )
        }
    }
}
