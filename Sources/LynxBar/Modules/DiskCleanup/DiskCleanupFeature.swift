import AppKit

@MainActor
final class DiskCleanupFeature {
    let viewModel: DiskCleanupViewModel
    // 保持存活：RemediationCoordinator 持有的 onBeginVerification/
    // onEndVerification 闭包只弱引用它，没有别的强引用会让它撑到验证发生时。
    private let remediationDemandBridge: RemediationDemandBridge
    private lazy var windowController = DiskCleanupWindowController(
        viewModel: viewModel
    )

    init(demandCoordinator: MonitoringDemandCoordinator) {
        let reader = LocalDiskReadAdapter()
        let ledger = SessionActionLedger()
        let remediationDemandBridge = RemediationDemandBridge(
            demandCoordinator: demandCoordinator
        )
        let coordinator = RemediationCoordinator(
            onBeginVerification: { [weak remediationDemandBridge] preparedID, kind in
                await remediationDemandBridge?.begin(preparedID: preparedID, kind: kind)
            },
            onEndVerification: { [weak remediationDemandBridge] preparedID in
                await remediationDemandBridge?.end(preparedID: preparedID)
            }
        )
        let scanner = DiskCleanupScanner(reader: reader)
        let executor = DiskCleanupExecutor(
            reader: reader,
            trash: LocalDiskTrashAdapter(),
            ledger: ledger
        )
        self.remediationDemandBridge = remediationDemandBridge
        self.viewModel = DiskCleanupViewModel(
            scanner: scanner,
            reader: reader,
            executor: executor,
            coordinator: coordinator,
            directoryPicker: LocalDiskCleanupDirectoryPicker(),
            fileRevealer: LocalDiskCleanupFileRevealer()
        )
    }

    func showWindow() {
        windowController.present()
    }

    func shutdown() {
        viewModel.cancelActiveWork()
        windowController.close()
    }
}
