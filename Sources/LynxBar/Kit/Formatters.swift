import Foundation

/// 数值与单位格式化工具。纯静态方法，线程安全。
enum Formatters {
    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    /// 0.0 ... 1.0 的比例 -> "42.3%"
    static func percent(_ ratio: Double) -> String {
        let clamped = min(max(ratio, 0), 1)
        return percentFormatter.string(from: NSNumber(value: clamped)) ?? "0%"
    }

    /// 字节数 -> "1.2 GB"
    static func bytes(_ value: UInt64) -> String {
        humanReadable(Double(value), base: 1024, suffix: "B")
    }

    /// 每秒字节数 -> "1.2 MB/s"
    static func rate(_ bytesPerSecond: Double) -> String {
        humanReadable(bytesPerSecond, base: 1000, suffix: "B/s")
    }

    /// 图表 hover 使用固定的时分秒密度，避免系统的短时间格式在不同区域设置下
    /// 省略秒数，导致相邻实时样本无法区分。
    static func clockTime(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(
            format: "%02lld:%02lld:%02lld",
            Int64(components.hour ?? 0),
            Int64(components.minute ?? 0),
            Int64(components.second ?? 0)
        )
    }

    private static func humanReadable(_ value: Double, base: Double, suffix: String) -> String {
        let units = ["", "K", "M", "G", "T", "P"]
        var value = value
        var index = 0
        while value >= base && index < units.count - 1 {
            value /= base
            index += 1
        }
        let fractionDigits = value < 10 ? 1 : 0
        return String(format: "%.\(fractionDigits)f %@%@", value, units[index], suffix)
    }

    /// 秒数 -> "3d 4h" / "4h 12m" / "12m"
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// 短区间覆盖率需要保留秒级信息，避免 1m 窗口在采集前 59 秒一直显示成 0m。
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total < 60 { return "\(total)s" }
        if total < 3_600 {
            return "\(total / 60)m \(total % 60)s"
        }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return "\(hours)h \(minutes)m"
    }

    /// IP 地址脱敏截断（IPv6 太长时）。这里原样返回，留作扩展点。
    static func ip(_ string: String) -> String {
        string
    }
}
