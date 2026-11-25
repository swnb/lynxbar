import Foundation

/// 数值来源边界，无 helper 或权限扩张。stop 后晚到 sample 由所有者拒绝。
/// 声明不可用的适配器不创建循环；Go 需硬件矩阵与 allowlist，默认 No-Go。
protocol TemperatureSensorAdapter: Sendable {
    var source: TemperatureSensorSource { get }
    var declaredAvailability: TemperatureSensorAvailability { get }

    func sample(at now: Date) async -> TemperatureSensorSnapshot
}

/// 无系统读取，明确返回空值；无法取得合法温度时不模拟温度。
struct UnavailableTemperatureSensorAdapter: TemperatureSensorAdapter {
    let source: TemperatureSensorSource = .unavailable
    let declaredAvailability: TemperatureSensorAvailability = .unavailable

    func sample(at now: Date) async -> TemperatureSensorSnapshot {
        .unavailable
    }
}

struct TemperatureSensorPolicy: Equatable, Sendable {
    /// Adapter-owned stable IDs are explicitly allowlisted after a hardware/source
    /// feasibility matrix. Unknown registry keys never become user-facing sensors.
    let allowlistedGroups: [String: TemperatureSensorGroup]
    /// 摄氏范围，默认 0...125；异常值被拒绝而非裁剪。
    let validCelsiusRange: ClosedRange<Double>
    /// 秒，默认 15；要求正数且有限，未来及过期值被丢弃。
    let staleAfter: TimeInterval

    init(
        allowlistedGroups: [String: TemperatureSensorGroup],
        validCelsiusRange: ClosedRange<Double> = 0...125,
        staleAfter: TimeInterval = 15
    ) {
        self.allowlistedGroups = allowlistedGroups
        self.validCelsiusRange = validCelsiusRange
        self.staleAfter = staleAfter
    }
}

enum TemperatureSensorAggregator {
    static func aggregate(
        source: TemperatureSensorSource,
        samples: [TemperatureSensorSample],
        policy: TemperatureSensorPolicy,
        now: Date
    ) -> TemperatureSensorSnapshot {
        guard source != .unavailable else { return .unavailable }
        guard policy.staleAfter.isFinite, policy.staleAfter > 0 else {
            return TemperatureSensorSnapshot(source: source, availability: .unavailable)
        }

        // 同一 sensor 的重复事件只保留最新一次；最新异常不能靠旧值重新变为可用。
        let latestByIdentity = Dictionary(samples.map { ($0.identity, $0) },
            uniquingKeysWith: { $0.observedAt >= $1.observedAt ? $0 : $1 })
        var validByGroup: [TemperatureSensorGroup: [TemperatureSensorSample]] = [:]
        for sample in latestByIdentity.values {
            guard sample.identity.source == source,
                  let group = policy.allowlistedGroups[sample.identity.stableID],
                  sample.celsius.isFinite,
                  policy.validCelsiusRange.contains(sample.celsius) else {
                continue
            }
            validByGroup[group, default: []].append(sample)
        }

        guard validByGroup.values.contains(where: { !$0.isEmpty }) else {
            return TemperatureSensorSnapshot(
                source: source,
                availability: .unavailable,
                aggregates: [],
                observedAt: nil
            )
        }

        let freshByGroup = validByGroup.mapValues { samples in
            samples.filter {
                let age = now.timeIntervalSince($0.observedAt)
                return age >= 0 && age <= policy.staleAfter
            }
        }
        guard freshByGroup.values.contains(where: { !$0.isEmpty }) else {
            let newestExpired = validByGroup.values
                .flatMap { $0 }
                .filter {
                    now.timeIntervalSince($0.observedAt) > policy.staleAfter
                }
                .map(\.observedAt)
                .max()
            // Stale samples keep provenance and time, but discard numeric values so
            // no old temperature can look current in CPU/GPU/menu-bar surfaces.
            return TemperatureSensorSnapshot(
                source: source,
                availability: newestExpired != nil ? .stale : .unavailable,
                aggregates: [],
                observedAt: newestExpired
            )
        }

        let aggregates: [TemperatureSensorAggregate] =
            TemperatureSensorGroup.allCases.compactMap { group in
            guard let groupSamples = freshByGroup[group], !groupSamples.isEmpty,
                  let hottest = groupSamples.max(by: { $0.celsius < $1.celsius }) else {
                return nil
            }
            return TemperatureSensorAggregate(
                group: group,
                hottestCelsius: hottest.celsius,
                sensorCount: groupSamples.count,
                observedAt: groupSamples.map(\.observedAt).max() ?? hottest.observedAt,
                source: source
            )
        }
        return TemperatureSensorSnapshot(
            source: source,
            availability: aggregates.isEmpty ? .unavailable : .available,
            aggregates: aggregates,
            // 快照时间只能来自本次真正发布的 fresh 聚合，未来/陈旧/被拒绝组
            // 的时间不得替有效 CPU/GPU 数值续期或令快照来自“未来”。
            observedAt: aggregates.map(\.observedAt).max()
        )
    }
}
