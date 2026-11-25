import XCTest
@testable import LynxBar

final class ProcessSamplingTests: XCTestCase {
    func testFirstSampleHasNoBaselineAndYieldsUnknownUsage() {
        let usage = ProcessProvider.cpuUsage(
            current: 900_000_000_000,
            previous: nil,
            elapsed: 2,
            cores: 8
        )
        XCTAssertNil(usage, "无基线时必须是未知，不能把进程生命周期总时长当作本次占用")
    }

    func testSecondSampleComputesDeltaAgainstMeasuredElapsed() {
        // 8 核、2 秒窗口 => 满载分母为 16e9 ns。用掉 4e9 ns 即 25%。
        let usage = ProcessProvider.cpuUsage(
            current: 5_000_000_000,
            previous: 1_000_000_000,
            elapsed: 2,
            cores: 8
        )
        XCTAssertEqual(try XCTUnwrap(usage), 0.25, accuracy: 0.0001)
    }

    func testMeasuredElapsedIsUsedInsteadOfConfiguredInterval() {
        // 同样的 tick 差，实测经过 2.4 秒时占用应低于按 2.0 秒计算的结果。
        let assumed = ProcessProvider.cpuUsage(
            current: 5_000_000_000, previous: 1_000_000_000, elapsed: 2.0, cores: 8
        )
        let measured = ProcessProvider.cpuUsage(
            current: 5_000_000_000, previous: 1_000_000_000, elapsed: 2.4, cores: 8
        )
        XCTAssertLessThan(try XCTUnwrap(measured), try XCTUnwrap(assumed))
    }

    func testCounterGoingBackwardsYieldsZeroNotNegative() {
        let usage = ProcessProvider.cpuUsage(
            current: 1_000_000_000,
            previous: 5_000_000_000,
            elapsed: 2,
            cores: 8
        )
        XCTAssertEqual(try XCTUnwrap(usage), 0, accuracy: 0.0001)
    }

    func testNonPositiveElapsedYieldsUnknown() {
        XCTAssertNil(ProcessProvider.cpuUsage(
            current: 5_000_000_000, previous: 1_000_000_000, elapsed: 0, cores: 8
        ))
        XCTAssertNil(ProcessProvider.cpuUsage(
            current: 5_000_000_000, previous: 1_000_000_000, elapsed: -1, cores: 8
        ))
    }

    func testUsageIsClampedToOne() {
        let usage = ProcessProvider.cpuUsage(
            current: 999_000_000_000, previous: 0, elapsed: 2, cores: 8
        )
        XCTAssertEqual(try XCTUnwrap(usage), 1.0, accuracy: 0.0001)
    }

    func testRecycledPIDIsTreatedAsUnknownNotIdle() {
        // 同一个 pid，但 start time 不同 —— 是另一个进程，旧基线不适用。
        let old = ProcessProvider.ProcessIdentity(pid: 501, startTime: 1_785_000_000)
        let new = ProcessProvider.ProcessIdentity(pid: 501, startTime: 1_785_999_999)
        let baseline: [ProcessProvider.ProcessIdentity: UInt64] = [old: 900_000_000_000]

        let usage = ProcessProvider.cpuUsage(
            current: 1_000_000,
            previous: baseline[new],
            elapsed: 2,
            cores: 8
        )
        XCTAssertNil(usage, "pid 复用后必须是未知，不能因为 current < previous 就报 0%")
    }

    func testSamePIDWithSameStartTimeKeepsItsBaseline() {
        let identity = ProcessProvider.ProcessIdentity(pid: 501, startTime: 1_785_000_000)
        let baseline: [ProcessProvider.ProcessIdentity: UInt64] = [identity: 1_000_000_000]

        let usage = ProcessProvider.cpuUsage(
            current: 5_000_000_000,
            previous: baseline[identity],
            elapsed: 2,
            cores: 8
        )
        XCTAssertEqual(try XCTUnwrap(usage), 0.25, accuracy: 0.0001)
    }

    func testIdentityDistinguishesOnStartTimeAlone() {
        let a = ProcessProvider.ProcessIdentity(pid: 501, startTime: 1)
        let b = ProcessProvider.ProcessIdentity(pid: 501, startTime: 2)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.hashValue, b.hashValue)
    }
}
