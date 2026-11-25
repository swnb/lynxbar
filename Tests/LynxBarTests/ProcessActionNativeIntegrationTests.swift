import AppKit
import XCTest
@testable import LynxBar

final class ProcessActionNativeIntegrationTests: XCTestCase {
    private var launchedApplications: [NSRunningApplication] = []
    private var heartbeatURLs: [URL] = []

    override func tearDown() async throws {
        // 仅回收本测试刚启动、可重建的 QA helper；绝不枚举或操作其他应用。
        for application in launchedApplications where !application.isTerminated {
            _ = application.forceTerminate()
        }
        launchedApplications.removeAll()
        for url in heartbeatURLs { try? FileManager.default.removeItem(at: url) }
        heartbeatURLs.removeAll()
        try await super.tearDown()
    }

    func testDisposableHelperExitsNormallyThroughProductionProvider() async throws {
        try requireNativeGate()
        let application = try await launchHelper(ignoringNormalTerminate: false)
        let target = try await currentTarget(for: application)
        let provider = ProcessActionProvider()

        let result = await provider.requestNormalQuit(target)

        XCTAssertEqual(result.outcome, .exited)
        XCTAssertEqual(result.requestAccepted, true)
        XCTAssertNil(ProcessProvider.identity(for: application.processIdentifier))
    }

    func testDisposableHelperForceQuitRequiresFailedNormalPermit() async throws {
        try requireNativeGate()
        let application = try await launchHelper(ignoringNormalTerminate: true)
        let target = try await currentTarget(for: application)
        let provider = ProcessActionProvider(maximumPollCount: 5)

        let forged = ProcessForceQuitPermit(id: UUID(), targetKey: target.process.sampleKey,
                                             expiresAt: Date().addingTimeInterval(30))
        let unauthorized = await provider.requestForceQuit(target, permit: forged)
        XCTAssertEqual(unauthorized.outcome, .forceNotAuthorized)
        XCTAssertNotNil(ProcessProvider.identity(for: application.processIdentifier))

        let normal = await provider.requestNormalQuit(target)
        XCTAssertTrue(normal.outcome == .refused || normal.outcome == .timedOut)
        let permit = try XCTUnwrap(normal.forceQuitPermit)

        let force = await provider.requestForceQuit(target, permit: permit)

        XCTAssertEqual(force.outcome, .exited)
        XCTAssertNil(ProcessProvider.identity(for: application.processIdentifier))
        let repeated = await provider.requestForceQuit(target, permit: permit)
        XCTAssertEqual(repeated.outcome, .forceNotAuthorized)
    }

    private func requireNativeGate() throws {
#if STATS_PROCESS_QA_NATIVE
        return
#else
        throw XCTSkip(
            "Build with STATS_PROCESS_QA_NATIVE to run disposable helper integration."
        )
#endif
    }

    private func launchHelper(
        ignoringNormalTerminate: Bool
    ) async throws -> NSRunningApplication {
        // Hosted unit tests live inside LynxBar.app/Contents/PlugIns; Bundle.main
        // points at the host app, whose parent is the shared Debug products dir.
        let productsURL = Bundle.main.bundleURL.deletingLastPathComponent()
        let helperURL = productsURL.appendingPathComponent(
            "LynxBar Process QA Helper.app",
            isDirectory: true
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: helperURL.path),
            "QA helper must be built as a test-only dependency"
        )

        let heartbeatURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lynxbar-process-helper-\(UUID().uuidString).heartbeat")
        heartbeatURLs.append(heartbeatURL)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = [
            "--heartbeat-path",
            heartbeatURL.path,
        ] + (ignoringNormalTerminate ? ["--ignore-normal-terminate"] : [])
        let application = try await NSWorkspace.shared.openApplication(
            at: helperURL,
            configuration: configuration
        )
        launchedApplications.append(application)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: heartbeatURL.path),
               ProcessProvider.identity(for: application.processIdentifier) != nil {
                return application
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("QA helper did not publish heartbeat and process identity")
        return application
    }

    private func currentTarget(
        for application: NSRunningApplication
    ) async throws -> ProcessActionTarget {
        let provider = ProcessActionProvider()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let target = await provider.currentTarget(pid: application.processIdentifier) {
                return target
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(
            domain: "LynxBarProcessQA",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "QA helper identity unavailable"]
        )
    }
}
