import AppKit
import SwiftUI
import XCTest
@testable import LynxBar

@MainActor
final class DiskCleanupWindowTests: XCTestCase {
    func testDedicatedWindowUsesStableInjectedSessionOwner() throws {
        let fixture = makeFixture()
        let controller = DiskCleanupWindowController(
            viewModel: fixture.viewModel
        )
        let window = try XCTUnwrap(controller.window)
        let host = try XCTUnwrap(
            window.contentViewController as? NSHostingController<DiskCleanupView>
        )

        XCTAssertTrue(host.rootView.viewModel === fixture.viewModel)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size.width, 720)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size.height, 560)
        XCTAssertEqual(window.minSize, NSSize(width: 640, height: 500))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.isReleasedWhenClosed)
    }

    func testClosingWindowCancelsAnActiveScan() {
        let fixture = makeFixture(observationDelayNanoseconds: 1_000_000_000)
        let controller = DiskCleanupWindowController(
            viewModel: fixture.viewModel
        )
        fixture.viewModel.startScan(at: fixture.root.canonicalURL)
        XCTAssertEqual(fixture.viewModel.phase, .scanning)

        controller.windowWillClose(
            Notification(name: NSWindow.willCloseNotification)
        )

        XCTAssertEqual(fixture.viewModel.phase, .cancelled)
        XCTAssertEqual(
            fixture.viewModel.cancellationContext,
            .scan(observedEntries: 0)
        )
    }

    private func makeFixture(
        observationDelayNanoseconds: UInt64 = 0
    ) -> (
        viewModel: DiskCleanupViewModel,
        root: DiskScanRoot
    ) {
        let root = TestDiskFactory.root()
        let observation = TestDiskFactory.observation(
            root: root,
            name: "window.bin",
            inode: 950,
            bytes: 2_000_000_000
        )
        let reader = FakeDiskReader(
            root: root,
            observations: [observation],
            observationDelayNanoseconds: observationDelayNanoseconds
        )
        let executor = DiskCleanupExecutor(
            reader: reader,
            trash: FakeDiskTrashMover(),
            ledger: SessionActionLedger(),
            now: { TestDiskFactory.now }
        )
        return (
            DiskCleanupViewModel(
                scanner: DiskCleanupScanner(reader: reader),
                reader: reader,
                executor: executor,
                coordinator: RemediationCoordinator(),
                directoryPicker: WindowTestDirectoryPicker(),
                fileRevealer: FakeDiskCleanupFileRevealer(),
                now: { TestDiskFactory.now }
            ),
            root
        )
    }
}

@MainActor
private final class WindowTestDirectoryPicker:
    DiskCleanupDirectoryPicking {
    func chooseDirectory() async -> URL? {
        nil
    }
}
