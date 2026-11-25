import Foundation

/// 进程行的 CPU 文本、排序与 accessibility 文案。纯函数集合，不依赖 SwiftUI，
/// 供 `ProcessListView`、`OverviewView` 等多处 View 共用，避免各处各自维护一份
/// 「未知占用不得显示为 0」的分支（B.1 审查指出的重复正是这样悄悄分叉的）。
enum ProcessRowFormatter {
    /// CPU 占用文本。未知占用（`cpuUsage == nil`）固定回退到 "—"，
    /// 不能回退成 `Formatters.percent(0)` —— 那等于把「不知道」显示成「空闲」。
    static func cpuText(for process: DisplayProcess) -> String {
        process.cpuUsage.map { Formatters.percent($0) }
            ?? NSLocalizedString("—", comment: "未知的进程 CPU 占用")
    }

    /// 按 CPU 占用从高到低排序；未知占用一律排在已知占用之后（含 0% 已知值）。
    static func sortedByCPU(_ processes: [DisplayProcess]) -> [DisplayProcess] {
        processes.sorted { ($0.cpuUsage ?? -1) > ($1.cpuUsage ?? -1) }
    }

    /// 同屏展示 CPU 与内存两列的行（`DualMetricProcessRow`、`CompactProcessRow`）
    /// 共用的 accessibility label。
    static func accessibilityLabel(for process: DisplayProcess) -> String {
        String(
            format: NSLocalizedString("%@, CPU %@, memory %@", comment: ""),
            process.name,
            cpuText(for: process),
            Formatters.bytes(process.memoryBytes)
        )
    }

    /// 单指标行（`ProcessRow` / `ProcessListView.Metric`）的展示值：
    /// CPU 走未知安全文本，Memory 直接走字节格式化（内存值不存在「未知」态）。
    static func displayValue(for process: DisplayProcess, metric: ProcessListView.Metric) -> String {
        switch metric {
        case .cpu: return cpuText(for: process)
        case .memory: return Formatters.bytes(process.memoryBytes)
        }
    }

    /// 单指标行的 accessibility label，格式与两列行不同（"<name>, <metric> <value>"），
    /// 因此不能直接复用上面的 `accessibilityLabel(for:)`。
    static func accessibilityLabel(
        for process: DisplayProcess,
        metric: ProcessListView.Metric
    ) -> String {
        "\(process.name), \(NSLocalizedString(metric.rawValue, comment: "")) " +
            displayValue(for: process, metric: metric)
    }
}
