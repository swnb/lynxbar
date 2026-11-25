import XCTest
@testable import LynxBar

final class ProcessActionModelTests: XCTestCase {
    func testLibprocMappingRetainsCurrentPIDUIDAndExactStartFields() throws {
        let identity = try XCTUnwrap(ProcessProvider.identity(for: getpid()))
        XCTAssertEqual(identity.pid, getpid())
        XCTAssertEqual(identity.ownerUID, getuid())
        XCTAssertGreaterThan(identity.startTime.seconds, 0)
        XCTAssertLessThan(identity.startTime.microseconds, 1_000_000)
        XCTAssertNil(ProcessProvider.identity(for: -1))
    }
    func testMemoryLeadersNeedSubstantialBytesInEveryConsecutiveObservation() {
        let target = processTestTarget()
        var tracker = ProcessContributionTracker()
        let small = ProcessContributionObservation(target: target, fallbackIdentity: target.process,
                                                  cpuUsage: nil, memoryBytes: 1_024)
        _ = tracker.update(observations: [small], physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024)
        let substantial = ProcessContributionObservation(target: target, fallbackIdentity: target.process,
            cpuUsage: nil, memoryBytes: 1_024 * 1_024 * 1_024)
        let first = tracker.update(observations: [substantial], physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024)[0]
        XCTAssertEqual(first.repeatedLeadingMemoryCount, 1)
        let second = tracker.update(observations: [substantial], physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024)[0]
        XCTAssertEqual(second.repeatedLeadingMemoryCount, 2)
    }
    func testIdentityIncludesMicrosecondsUIDAndApplicationButNotParent() {
        let a = processTestTarget()
        let micro = processTestTarget(microseconds: 2)
        XCTAssertFalse(a.matchesActionIdentity(micro))
        XCTAssertFalse(a.matchesActionIdentity(processTestTarget(uid: 999)))
        let changedParent = ProcessActionTarget(process: ProcessKernelIdentity(pid: a.process.pid,
            startTime: a.process.startTime, ownerUID: a.process.ownerUID, parentPID: 999, name: a.process.name), application: a.application)
        XCTAssertTrue(a.matchesActionIdentity(changedParent))
    }
    func testEligibilityRejectsSelfRootOtherUserCommandLineAndProtectedRole() {
        let policy = ProcessActionEligibilityPolicy(currentUID: 501, lynxBarPID: 12, lynxBarBundleIdentifier: "test.stats")
        XCTAssertEqual(policy.evaluate(processTestTarget()), .eligible)
        XCTAssertEqual(policy.evaluate(processTestTarget(pid: 12)), .ineligible(.selfProcess))
        XCTAssertEqual(policy.evaluate(processTestTarget(uid: 0)), .ineligible(.rootOwned))
        XCTAssertEqual(policy.evaluate(processTestTarget(uid: 502)), .ineligible(.otherUser))
        XCTAssertEqual(policy.evaluate(processTestTarget(policy: .prohibited)), .ineligible(.commandLineOnly))
        XCTAssertEqual(policy.evaluate(processTestTarget(bundle: "com.apple.dock")), .ineligible(.protectedSystemRole))
    }
    func testUnknownZeroAndNearZeroCPUDoNotBecomeLeaders() {
        for usage in [nil, 0, 0.001, 0.049] as [Double?] {
            var tracker = ProcessContributionTracker()
            let target = processTestTarget()
            let observation = ProcessContributionObservation(target: target, fallbackIdentity: target.process,
                                                            cpuUsage: usage, memoryBytes: 100)
            _ = tracker.update(observations: [observation], physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024)
            let contribution = tracker.update(observations: [observation], physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024)[0]
            XCTAssertEqual(contribution.repeatedLeadingCPUCount, 0)
            XCTAssertEqual(ProcessRemediationSuggestionPolicy.level(for: contribution,
                context: ProcessRemediationContext(memoryPressure: .normal, swapUsedBytes: 0, hasSustainedCPUIssue: true)), .inspect)
        }
    }
    func testSuggestionsNeedBothRepeatedSubstantialContributionAndSystemIssue() {
        let target = processTestTarget()
        var tracker = ProcessContributionTracker()
        let observation = ProcessContributionObservation(target: target, fallbackIdentity: target.process,
            cpuUsage: 0.1, memoryBytes: 1_024 * 1_024 * 1_024)
        let first = tracker.update(observations: [observation], physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024)[0]
        let second = tracker.update(observations: [observation], physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024)[0]
        let pressure = ProcessRemediationContext(memoryPressure: .warning, swapUsedBytes: 99,
            hasSustainedCPUIssue: false, physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(ProcessRemediationSuggestionPolicy.level(for: first, context: pressure), .inspect)
        XCTAssertEqual(ProcessRemediationSuggestionPolicy.level(for: second, context: pressure), .normalQuit)
        XCTAssertEqual(ProcessRemediationSuggestionPolicy.level(for: second,
            context: ProcessRemediationContext(memoryPressure: .normal, swapUsedBytes: 99, hasSustainedCPUIssue: false)), .inspect)
        let restarted = processTestTarget(microseconds: 2)
        let third = tracker.update(observations: [ProcessContributionObservation(target: restarted,
            fallbackIdentity: restarted.process, cpuUsage: 0.1, memoryBytes: observation.memoryBytes)])[0]
        XCTAssertEqual(third.repeatedLeadingCPUCount, 1)
    }
    func testTargetExitAndSystemRecoveryAreIndependentAndUnknownStaysUnknown() {
        let initial = ProcessRemediationContext(memoryPressure: .critical, swapUsedBytes: 10, hasSustainedCPUIssue: true)
        let unavailable = ProcessRemediationContext(memoryPressure: .unknown, swapUsedBytes: 0,
            hasSustainedCPUIssue: false, hasCompleteCPUWindow: false)
        let report = ProcessPostActionReporter.report(resources: ProcessResourceRemeasurement(targetStatus: .unknown,
            memoryUsage: 0, swapUsedBytes: 0, cpuUsage: nil), initialContext: initial, currentContext: unavailable)
        XCTAssertFalse(report.applicationExited)
        XCTAssertFalse(report.systemIssueResolved)
        let exited = ProcessPostActionReporter.report(resources: ProcessResourceRemeasurement(targetStatus: .exited,
            memoryUsage: 0.8, swapUsedBytes: 10, cpuUsage: 0.8), initialContext: initial, currentContext: initial)
        XCTAssertTrue(exited.applicationExited)
        XCTAssertFalse(exited.systemIssueResolved)
    }
    func testReplacingNamePreservesActionEvidence() {
        let target = processTestTarget()
        let contribution = processTestContribution(target: target)
        let display = DisplayProcess(pid: target.process.pid, name: "raw", cpuUsage: nil, memoryBytes: 1,
            identity: .init(pid: target.process.pid, startTime: target.process.startTime.seconds),
            actionTarget: target, contribution: contribution).replacingName(with: "renamed")
        XCTAssertEqual(display.actionTarget, target)
        XCTAssertEqual(display.contribution, contribution)
        XCTAssertNil(display.cpuUsage)
    }
}

func processTestTarget(pid: Int32 = 4001, microseconds: UInt64 = 1, uid: UInt32 = 501,
                       policy: RunningApplicationActivationPolicy = .regular, bundle: String = "test.helper") -> ProcessActionTarget {
    ProcessActionTarget(process: ProcessKernelIdentity(pid: pid, startTime: .init(seconds: 1000, microseconds: microseconds),
        ownerUID: uid, parentPID: 1, name: "helper"), application: RunningApplicationSnapshot(pid: pid,
        bundleIdentifier: bundle, localizedName: "Helper", bundleURL: URL(fileURLWithPath: "/tmp/Helper.app"),
        executableURL: URL(fileURLWithPath: "/tmp/Helper.app/Contents/MacOS/Helper"), activationPolicy: policy, isTerminated: false))
}
func processTestContribution(target: ProcessActionTarget, observedAt: Date = Date()) -> ApplicationContribution {
    ApplicationContribution(id: target.application.stableIdentifier!, displayName: "Helper", processCount: 1,
        cpuUsage: 0.1, memoryBytes: 1_024 * 1_024 * 1_024, repeatedLeadingCPUCount: 2,
        repeatedLeadingMemoryCount: 2, actionTarget: target, observedAt: observedAt)
}
