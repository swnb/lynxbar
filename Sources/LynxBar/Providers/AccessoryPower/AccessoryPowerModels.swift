import Foundation

/// 仅公开 GC 与标准 BLE；不读 Apple 私有缓存，不猜测 iPhone/iPad 电量。
enum AccessoryPowerSource: String, Codable, CaseIterable, Sendable {
    case gameController
    case standardBLE
}

/// 来源与 provider ID 共同去重，跨来源和同名设备保持独立。
struct AccessoryPowerIdentity: Hashable, Codable, Sendable {
    let source: AccessoryPowerSource
    /// 仅用于内存去重，不写日志。GC ID 限连接会话，BLE 来自 CBPeripheral.identifier。
    let stableIdentifier: String
}

/// 未提供的分部保持缺失，不能从 main 或其他分部复制。当前公开 adapter 只提供 main。
enum AccessoryBatteryPartKind: String, Codable, CaseIterable, Sendable {
    case main
    case left
    case right
    case `case`
}

enum AccessoryChargeState: String, Codable, Sendable {
    case charging
    case full
    case discharging
    case unknown
}

enum AccessoryPowerAvailability: String, Codable, Sendable {
    case available
    case batteryUnavailable
    case stale
    case disconnected
    case permissionNotDetermined
    case permissionDenied
    case bluetoothPoweredOff
    case unsupported
    /// 标准服务/特征发现返回错误，区别于设备确实没有标准服务。
    case discoveryFailed
    case optedOut
    case scanning
}

struct AccessoryBatteryPart: Identifiable, Equatable, Sendable {
    var id: AccessoryBatteryPartKind { kind }

    let kind: AccessoryBatteryPartKind
    /// 有限 0...1 比例，0 是实际耗尽；未知通过无 part 表示。
    let level: Double
    /// 仅映射来源公开状态；标准 BLE 电量不提供充电状态，保持 unknown。
    let chargeState: AccessoryChargeState
    /// 实际观察时刻；part 独立过期，不由另一 part 的时间续期。
    let observedAt: Date
}

struct AccessoryPowerRecord: Identifiable, Equatable, Sendable {
    var id: AccessoryPowerIdentity { identity }

    let identity: AccessoryPowerIdentity
    /// UI 标签，永不用于身份或合并。
    let displayName: String
    /// 非 available 时丢弃数值，断连/拒权不展示旧百分比。
    let availability: AccessoryPowerAvailability
    let parts: [AccessoryBatteryPart]
    /// 最近来源观察时刻；无值可 nil，未来时刻不能作为新鲜记录。
    let observedAt: Date?
    /// 秒，正数且有限；聚合为三倍来源间隔（GC 用户间隔，BLE 180s）。
    let staleAfter: TimeInterval

    func part(_ kind: AccessoryBatteryPartKind) -> AccessoryBatteryPart? {
        parts.first { $0.kind == kind }
    }
}

struct AccessoryPowerSnapshot: Equatable, Sendable {
    /// 按名称/来源/ID 稳定排序的会话记录，身份去重不使用名称。
    var records: [AccessoryPowerRecord] = []
    /// 默认 GC 无电量、BLE optedOut；启用状态来自设置和公开权限事件。
    var sourceAvailability: [AccessoryPowerSource: AccessoryPowerAvailability] = [
        .gameController: .batteryUnavailable,
        .standardBLE: .optedOut,
    ]
    /// 最近来源事件或记录时刻，不用于替任何独立 part 续期。
    var observedAt: Date?

    /// 选择排序后首个 available 设备，读数与 observedAt 必须来自同一 part。
    var preferredMenuBarLevel: Double? {
        records.lazy
            .filter { $0.availability == .available }
            .compactMap { record in
                record.part(.main)?.level ?? record.parts.first?.level
            }
            .first
    }

    var preferredMenuBarObservedAt: Date? {
        records.lazy
            .filter { $0.availability == .available }
            .compactMap { record in
                record.part(.main)?.observedAt ?? record.parts.first?.observedAt
            }
            .first
    }
}

struct AccessoryPowerSourceUpdate: Equatable, Sendable {
    /// adapter 的命名空间，接收所有者核对该来源与实例绑定一致。
    let source: AccessoryPowerSource
    /// 来源整体状态；只有 available 允许其 record 展示数值。
    let availability: AccessoryPowerAvailability
    /// 此来源的完整当前会话记录；不携带其他来源的身份。
    let records: [AccessoryPowerRecord]
    /// 来源状态事件时刻，不能作为 record/part 的采样时间替其续期。
    let observedAt: Date
}

enum AccessoryPowerMerger {
    static func merge(
        updates: [AccessoryPowerSource: AccessoryPowerSourceUpdate],
        now: Date
    ) -> AccessoryPowerSnapshot {
        var recordsByIdentity: [AccessoryPowerIdentity: AccessoryPowerRecord] = [:]
        /// 默认 GC 无电量、BLE optedOut；启用状态来自设置和公开权限事件。
    var sourceAvailability: [
            AccessoryPowerSource: AccessoryPowerAvailability
        ] = [:]
        var newest: Date?

        for source in AccessoryPowerSource.allCases {
            guard let update = updates[source] else {
                sourceAvailability[source] = source == .standardBLE
                    ? .optedOut
                    : .batteryUnavailable
                continue
            }
            sourceAvailability[source] = update.availability
            newest = maxDate(newest, update.observedAt)

            for rawRecord in update.records where rawRecord.identity.source == source {
                // 来源整体不可用时，即使 adapter 错带一个 available 缓存记录也不
                // 能穿过聚合边界展示百分比；record 独立的无值原因仍保留。
                let eligibleRecord: AccessoryPowerRecord
                if update.availability != .available, rawRecord.availability == .available {
                    eligibleRecord = AccessoryPowerRecord(identity: rawRecord.identity,
                        displayName: rawRecord.displayName, availability: update.availability,
                        parts: [], observedAt: rawRecord.observedAt,
                        staleAfter: rawRecord.staleAfter)
                } else {
                    eligibleRecord = rawRecord
                }
                let record = validated(eligibleRecord, now: now)
                // Identity is source + provider identifier. Display name is never
                // a merge key, so same-name controllers remain independent.
                recordsByIdentity[record.identity] = record
                newest = maxDate(newest, record.observedAt)
            }
        }

        return AccessoryPowerSnapshot(
            records: recordsByIdentity.values.sorted {
                if $0.displayName != $1.displayName {
                    return $0.displayName.localizedStandardCompare($1.displayName)
                        == .orderedAscending
                }
                if $0.identity.source != $1.identity.source {
                    return $0.identity.source.rawValue
                        < $1.identity.source.rawValue
                }
                return $0.identity.stableIdentifier
                    < $1.identity.stableIdentifier
            },
            sourceAvailability: sourceAvailability,
            observedAt: newest
        )
    }

    static func validated(
        _ record: AccessoryPowerRecord,
        now: Date
    ) -> AccessoryPowerRecord {
        let validParts = record.parts.filter {
            let age = now.timeIntervalSince($0.observedAt)
            return $0.level.isFinite && (0...1).contains($0.level)
                && record.staleAfter.isFinite && record.staleAfter > 0
                && age >= 0
                && age <= record.staleAfter
        }
        guard record.availability == .available,
              let observedAt = record.observedAt,
              record.staleAfter.isFinite, record.staleAfter > 0,
              now.timeIntervalSince(observedAt) >= 0,
              now.timeIntervalSince(observedAt) <= record.staleAfter,
              !validParts.isEmpty else {
            /// 非 available 时丢弃数值，断连/拒权不展示旧百分比。
    let availability: AccessoryPowerAvailability
            let hasExpiredNumericPart = record.parts.contains {
                $0.level.isFinite
                    && (0...1).contains($0.level)
                    && record.staleAfter.isFinite && record.staleAfter > 0
                    && now.timeIntervalSince($0.observedAt) > record.staleAfter
            }
            if record.availability == .available,
               (hasExpiredNumericPart
                    || record.observedAt.map {
                        now.timeIntervalSince($0) > record.staleAfter
                    } == true) {
                availability = .stale
            } else if record.availability == .available {
                availability = .batteryUnavailable
            } else {
                availability = record.availability
            }
            return AccessoryPowerRecord(
                identity: record.identity,
                displayName: record.displayName,
                availability: availability,
                parts: [],
                observedAt: record.observedAt,
                staleAfter: record.staleAfter
            )
        }

        // Each part keeps its own meaning. Missing left/right/case values stay
        // absent and are never copied from main or another part.
        let byKind = Dictionary(
            validParts.map { ($0.kind, $0) },
            uniquingKeysWith: {
                $0.observedAt >= $1.observedAt ? $0 : $1
            }
        )
        return AccessoryPowerRecord(
            identity: record.identity,
            displayName: record.displayName,
            availability: .available,
            parts: AccessoryBatteryPartKind.allCases.compactMap { byKind[$0] },
            observedAt: observedAt,
            staleAfter: record.staleAfter
        )
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return max(lhs, rhs)
        case let (lhs?, nil): return lhs
        case let (nil, rhs?): return rhs
        case (nil, nil): return nil
        }
    }
}
