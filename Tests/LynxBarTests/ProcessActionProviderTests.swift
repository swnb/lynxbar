import XCTest
@testable import LynxBar

@MainActor
final class ProcessActionProviderTests: XCTestCase {
    private let policy = ProcessActionEligibilityPolicy(currentUID: 501, lynxBarPID: 12, lynxBarBundleIdentifier: "test.stats")

    func testFinalSynchronousControllerCheckRejectsEvidenceChangedDuringIdentityRead() {
        let target = processTestTarget()
        let handle = ProcessTestApplicationHandle(snapshot: target.application)
        let state = ProcessTestEvidenceState()
        let controller = SystemRunningApplicationController(applicationLookup: { _ in handle }, identityLookup: { _ in
            state.isCurrent = false
            return target.process
        })
        let result = controller.requestQuit(target: target, kind: .normalQuit, policy: policy,
                                             evidenceIsCurrent: { state.isCurrent })
        XCTAssertEqual(result, .stale)
        XCTAssertEqual(handle.normalRequests, 0)
    }
    func testFinalRequestRetainsInspectedObjectWhenPIDIsReplacedDuringIdentityRead() {
        let target = processTestTarget()
        let original = ProcessTestApplicationHandle(snapshot: target.application)
        let replacement = ProcessTestApplicationHandle(snapshot: processTestTarget(microseconds: 2).application)
        var current: any RunningApplicationHandle = original
        var lookups = 0
        let controller = SystemRunningApplicationController(applicationLookup: { _ in
            lookups += 1
            return current
        }, identityLookup: { _ in
            current = replacement
            return target.process
        })
        XCTAssertEqual(controller.requestQuit(target: target, kind: .normalQuit, policy: policy), .accepted(true))
        XCTAssertEqual(lookups, 1)
        XCTAssertEqual(original.normalRequests, 1)
        XCTAssertEqual(replacement.normalRequests, 0)
    }
    func testControllerRejectsPIDReuseAndFreshOwnershipWithoutSendingRequest() {
        let target = processTestTarget()
        for current in [processTestTarget(microseconds: 2), processTestTarget(uid: 999)] {
            let handle = ProcessTestApplicationHandle(snapshot: current.application)
            let controller = SystemRunningApplicationController(applicationLookup: { _ in handle }, identityLookup: { _ in current.process })
            XCTAssertEqual(controller.requestQuit(target: target, kind: .normalQuit, policy: policy), .stale)
            XCTAssertEqual(handle.normalRequests, 0)
        }
        let protected = processTestTarget(bundle: "com.apple.dock")
        let handle = ProcessTestApplicationHandle(snapshot: protected.application)
        let controller = SystemRunningApplicationController(applicationLookup: { _ in handle }, identityLookup: { _ in protected.process })
        XCTAssertEqual(controller.requestQuit(target: protected, kind: .normalQuit, policy: policy), .ineligible(.protectedSystemRole))
        XCTAssertEqual(handle.normalRequests, 0)
    }
    func testAcceptanceDoesNotEqualExitAndTimeoutIssuesSingleUseForcePermit() async throws {
        let target = processTestTarget()
        let controller = ProcessTestController(target: target)
        let reader = ProcessTestIdentityReader(status: .identified(target.process))
        let provider = ProcessActionProvider(identityReader: reader, applicationController: controller,
            waiter: ProcessTestWaiter(), eligibilityPolicy: policy, maximumPollCount: 1)
        let normal = await provider.requestNormalQuit(target)
        XCTAssertEqual(normal.outcome, .timedOut)
        XCTAssertEqual(normal.requestAccepted, true)
        let permit = try XCTUnwrap(normal.forceQuitPermit)
        let force = await provider.requestForceQuit(target, permit: permit)
        XCTAssertEqual(force.outcome, .timedOut)
        let repeatResult = await provider.requestForceQuit(target, permit: permit)
        XCTAssertEqual(repeatResult.outcome, .forceNotAuthorized)
        XCTAssertEqual(controller.forceRequests, 1)
    }
    func testUnavailableIdentityNeverVerifiesExitOrOffersForce() async {
        let target = processTestTarget()
        let provider = ProcessActionProvider(identityReader: ProcessTestIdentityReader(status: .unavailable),
            applicationController: ProcessTestController(target: target), waiter: ProcessTestWaiter(),
            eligibilityPolicy: policy, maximumPollCount: 1)
        let result = await provider.requestNormalQuit(target)
        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertNil(result.forceQuitPermit)
    }
    func testKnownExitIsVerifiedAndNormalRefusalDoesNotForceAutomatically() async throws {
        let target = processTestTarget()
        let controller = ProcessTestController(target: target)
        let provider = ProcessActionProvider(identityReader: ProcessTestIdentityReader(status: .exited),
            applicationController: controller, waiter: ProcessTestWaiter(), eligibilityPolicy: policy)
        let exited = await provider.requestNormalQuit(target)
        XCTAssertEqual(exited.outcome, .exited)
        XCTAssertNil(exited.forceQuitPermit)
        controller.accepts = false
        let refused = await provider.requestNormalQuit(target)
        XCTAssertEqual(refused.outcome, .refused)
        XCTAssertNotNil(refused.forceQuitPermit)
        XCTAssertEqual(controller.forceRequests, 0)
    }
    func testForcePermitExpiresAndFreshPIDReuseIsRejected() async throws {
        let target = processTestTarget()
        let controller = ProcessTestController(target: target)
        controller.accepts = false
        let clock = ProcessTestClock(Date(timeIntervalSince1970: 100))
        let provider = ProcessActionProvider(identityReader: ProcessTestIdentityReader(status: .identified(target.process)),
            applicationController: controller, waiter: ProcessTestWaiter(), eligibilityPolicy: policy, now: { clock.value() })
        let normal = await provider.requestNormalQuit(target)
        let permit = try XCTUnwrap(normal.forceQuitPermit)
        clock.advance(31)
        let expired = await provider.requestForceQuit(target, permit: permit)
        XCTAssertEqual(expired.outcome, .forceNotAuthorized)
        XCTAssertEqual(controller.forceRequests, 0)
        let next = await provider.requestNormalQuit(target)
        controller.target = processTestTarget(microseconds: 2)
        let stale = await provider.requestForceQuit(target, permit: try XCTUnwrap(next.forceQuitPermit))
        XCTAssertEqual(stale.outcome, .stale)
        XCTAssertEqual(controller.forceRequests, 0)
    }
}
@MainActor
private final class ProcessTestApplicationHandle: RunningApplicationHandle {
    let snapshot: RunningApplicationSnapshot
    var normalRequests = 0
    var forceRequests = 0
    init(snapshot: RunningApplicationSnapshot) { self.snapshot = snapshot }
    func requestQuit(force: Bool) -> Bool {
        if force { forceRequests += 1 } else { normalRequests += 1 }
        return true
    }
}
@MainActor
final class ProcessTestController: RunningApplicationControlling {
    var target: ProcessActionTarget
    var accepts = true
    var normalRequests = 0
    var forceRequests = 0
    init(target: ProcessActionTarget) { self.target = target }
    func snapshot(for pid: Int32) -> RunningApplicationSnapshot? { target.application }
    func requestQuit(target prepared: ProcessActionTarget, kind: ProcessActionKind, policy: ProcessActionEligibilityPolicy) -> ProcessQuitRequestResult {
        guard prepared.matchesActionIdentity(target) else { return .stale }
        if case let .ineligible(reason) = policy.evaluate(target) { return .ineligible(reason) }
        if kind == .forceQuit { forceRequests += 1 } else { normalRequests += 1 }
        return .accepted(accepts)
    }
}
struct ProcessTestIdentityReader: ProcessIdentityReading {
    let status: ProcessIdentityStatus
    func identity(for pid: Int32) async -> ProcessKernelIdentity? {
        if case let .identified(identity) = status { return identity }
        return nil
    }
    func status(for pid: Int32) async -> ProcessIdentityStatus { status }
}
struct ProcessTestWaiter: ProcessActionWaiting { func wait(for interval: Duration) async {} }
final class ProcessTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func value() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(interval) }
}

@MainActor
private final class ProcessTestEvidenceState {
    var isCurrent = true
}
