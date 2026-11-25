import Foundation

/// 按采样时间保留最近一段窗口的数据。
///
/// 使用时间戳而不是“样本数 × 当前刷新间隔”推算窗口，避免用户在运行时切换
/// 刷新间隔后，趋势突然只代表数秒或混入超过窗口边界的旧样本。
struct RecentSampleWindow {
    private struct Sample {
        let timestamp: Date
        let value: Double
    }

    private let duration: TimeInterval
    private var samples: [Sample] = []

    init(duration: TimeInterval = 60) {
        self.duration = duration
    }

    /// 追加样本并返回仍位于窗口内的值，顺序保持从旧到新。
    mutating func append(_ value: Double, at timestamp: Date = Date()) -> [Double] {
        samples.append(Sample(timestamp: timestamp, value: value))
        return values(at: timestamp)
    }

    /// 为需要真实时间轴的图表返回带 timestamp 的同一窗口数据。
    mutating func appendPoints(
        _ value: Double,
        at timestamp: Date = Date()
    ) -> [MetricPoint] {
        samples.append(Sample(timestamp: timestamp, value: value))
        return points(at: timestamp)
    }

    /// 在没有新有效样本时也裁剪窗口；调用方可更新 unavailable 状态而不追加伪 0。
    mutating func values(at timestamp: Date = Date()) -> [Double] {
        trim(at: timestamp)
        return samples.map(\.value)
    }

    mutating func points(at timestamp: Date = Date()) -> [MetricPoint] {
        trim(at: timestamp)
        return samples.map {
            MetricPoint(timestamp: $0.timestamp, value: $0.value)
        }
    }

    private mutating func trim(at timestamp: Date) {
        let cutoff = timestamp.addingTimeInterval(-duration)
        if let firstValid = samples.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstValid > samples.startIndex {
                samples.removeFirst(firstValid)
            }
        } else {
            samples.removeAll(keepingCapacity: true)
        }
    }
}
