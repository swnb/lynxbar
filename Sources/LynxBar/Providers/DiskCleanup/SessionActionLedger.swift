import Foundation

/// 仅保留当前进程的逐项事实；没有编码或持久化入口。
actor SessionActionLedger {
    private var entriesByPlan: [UUID: [DiskCleanupItemResult]] = [:]

    func append(_ result: DiskCleanupItemResult, planID: UUID) {
        entriesByPlan[planID, default: []].append(result)
    }

    func entries(for planID: UUID) -> [DiskCleanupItemResult] {
        entriesByPlan[planID] ?? []
    }

    func clear(planID: UUID) {
        entriesByPlan.removeValue(forKey: planID)
    }

    func clearAll() {
        entriesByPlan.removeAll(keepingCapacity: false)
    }
}
