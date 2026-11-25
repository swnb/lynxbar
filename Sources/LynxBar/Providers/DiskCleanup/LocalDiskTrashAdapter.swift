import Foundation

/// 唯一直接调用 Apple Trash API 的 production 类型。
///
/// `FileManager.trashItem` 是同步系统调用：取消只在进入调用前生效；一旦开始，
/// 必须等待真实返回并记录结果，不能向上层伪报回滚。
struct LocalDiskTrashAdapter: DiskTrashMoving {
    func moveToTrash(_ url: URL) async throws -> URL {
        try Task.checkCancellation()
        let operation = Task.detached(priority: .userInitiated) {
            var resultingURL: NSURL?
            try FileManager().trashItem(
                at: url,
                resultingItemURL: &resultingURL
            )
            guard let resultingURL else {
                throw DiskCleanupError.sourceUnavailable
            }
            return resultingURL as URL
        }
        return try await operation.value
    }
}

