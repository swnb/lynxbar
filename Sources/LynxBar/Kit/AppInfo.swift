import Foundation

/// App 版本信息。
enum AppInfo {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        let format = String(localized: "Version %@ (%@)")
        return String(format: format, version, build)
    }
}
