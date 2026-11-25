import Foundation

/// 两个排行观察集的应用归组器；连续性仅在同一主 GUI 实例连续进入前3，且
/// 每帧都达到实质阈值时积累。省略/跌榜/重启会立即清零，不从历史中拼接次数。
struct ProcessContributionTracker: Sendable {
    private var leadingCPUCounts: [String: Int] = [:]
    private var leadingMemoryCounts: [String: Int] = [:]

    mutating func update(
        observations: [ProcessContributionObservation],
        leadingCount: Int = 3,
        observedAt: Date = Date(),
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> [ApplicationContribution] {
        let groups = Dictionary(grouping: observations, by: groupIdentifier)
        let aggregates = groups.map { key, members in
            Aggregate(
                key: key,
                displayName: displayName(for: members),
                processCount: members.count,
                cpuUsage: members.reduce(0) { $0 + finiteUsage($1.cpuUsage) },
                memoryBytes: members.reduce(0) {
                    saturatingBytes($0, $1.memoryBytes)
                },
                actionTarget: mainActionTarget(in: members)
            )
        }

        let cpuLeaders = Set(
            aggregates
                .filter { $0.cpuUsage >= ProcessRemediationSuggestionPolicy.minimumCPUContribution }
                .sorted { $0.cpuUsage > $1.cpuUsage }
                .prefix(max(0, leadingCount))
                .map(\.leaderKey)
        )
        let memoryLeaders = Set(
            aggregates
                .filter { $0.memoryBytes >= ProcessRemediationSuggestionPolicy.minimumResidentBytes
                    && physicalMemoryBytes > 0
                    && Double($0.memoryBytes) >= Double(physicalMemoryBytes) * ProcessRemediationSuggestionPolicy.minimumMemoryFraction }
                .sorted { $0.memoryBytes > $1.memoryBytes }
                .prefix(max(0, leadingCount))
                .map(\.leaderKey)
        )
        leadingCPUCounts = nextCounts(previous: leadingCPUCounts, leaders: cpuLeaders)
        leadingMemoryCounts = nextCounts(previous: leadingMemoryCounts, leaders: memoryLeaders)

        return aggregates
            .map { aggregate in
                ApplicationContribution(
                    id: aggregate.key,
                    displayName: aggregate.displayName,
                    processCount: aggregate.processCount,
                    cpuUsage: aggregate.cpuUsage,
                    memoryBytes: aggregate.memoryBytes,
                    repeatedLeadingCPUCount: leadingCPUCounts[aggregate.leaderKey] ?? 0,
                    repeatedLeadingMemoryCount: leadingMemoryCounts[aggregate.leaderKey] ?? 0,
                    actionTarget: aggregate.actionTarget,
                    observedAt: observedAt
                )
            }
            .sorted {
                $0.memoryBytes > $1.memoryBytes
            }
    }

    private func groupIdentifier(_ observation: ProcessContributionObservation) -> String {
        if let stableIdentifier = observation.target?.application.stableIdentifier {
            return stableIdentifier
        }
        return "process:\(observation.fallbackIdentity.sampleKey.pid):"
            + "\(observation.fallbackIdentity.startTime.seconds):"
            + "\(observation.fallbackIdentity.startTime.microseconds)"
    }

    private func displayName(
        for observations: [ProcessContributionObservation]
    ) -> String {
        observations.compactMap(\.target?.application.localizedName).first
            ?? observations.first?.fallbackIdentity.name
            ?? ""
    }

    private func mainActionTarget(
        in observations: [ProcessContributionObservation]
    ) -> ProcessActionTarget? {
        observations
            .compactMap(\.target)
            .sorted { lhs, rhs in
                if lhs.application.activationPolicy != rhs.application.activationPolicy {
                    return lhs.application.activationPolicy == .regular
                }
                return lhs.process.parentPID < rhs.process.parentPID
            }
            .first
    }

    private func nextCounts(
        previous: [String: Int],
        leaders: Set<String>
    ) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: leaders.map { key in
            (key, min(previous[key] ?? 0, Int.max - 1) + 1)
        })
    }

    private func finiteUsage(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return max(0, value)
    }

    private func saturatingBytes(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private struct Aggregate {
        let key: String
        let displayName: String
        let processCount: Int
        let cpuUsage: Double
        let memoryBytes: UInt64
        let actionTarget: ProcessActionTarget?
        var leaderKey: String {
            guard let process = actionTarget?.process else { return key }
            return "\(key):\(process.pid):\(process.startTime.seconds):\(process.startTime.microseconds)"
        }
    }
}
