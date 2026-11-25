import XCTest
@testable import LynxBar

final class SystemHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testShortCPUSpikeDoesNotTriggerSustainedRule() {
        let input = healthyInput(cpu: points(value: 0.99, duration: 10))
        let summary = SystemHealthEvaluator.evaluate(input)

        XCTAssertEqual(summary.severity, .healthy)
        XCTAssertFalse(summary.issues.contains { $0.kind == .sustainedCPU })
    }

    func testThirtySecondHighCPUTriggersAttention() {
        let input = healthyInput(cpu: points(value: 0.86, duration: 30))
        let summary = SystemHealthEvaluator.evaluate(input)

        XCTAssertEqual(summary.severity, .attention)
        XCTAssertEqual(summary.issues.first?.kind, .sustainedCPU)
    }

    func testCriticalMemoryPressureWinsOverAttention() {
        var input = healthyInput(cpu: points(value: 0.86, duration: 30))
        input.memoryPressure = .critical
        let summary = SystemHealthEvaluator.evaluate(input)

        XCTAssertEqual(summary.severity, .critical)
        XCTAssertEqual(summary.issues.first?.kind, .memoryPressureCritical)
    }

    func testDiskAbsoluteAndFractionThresholds() {
        var attention = healthyInput(cpu: points(value: 0.2, duration: 30))
        attention.diskTotalBytes = 500 * 1_000_000_000
        attention.diskFreeBytes = 30 * 1_000_000_000
        XCTAssertEqual(SystemHealthEvaluator.evaluate(attention).issues.first?.kind, .lowDisk)

        var critical = attention
        critical.diskFreeBytes = 10 * 1_000_000_000
        XCTAssertEqual(
            SystemHealthEvaluator.evaluate(critical).issues.first?.kind,
            .criticalDisk
        )
    }

    func testUnknownSignalsRemainCollecting() {
        let summary = SystemHealthEvaluator.evaluate(SystemHealthInput(
            cpuHistory: [],
            memoryPressure: .unknown,
            diskFreeBytes: nil,
            diskTotalBytes: nil,
            hasPrimaryNetwork: nil,
            now: now
        ))

        XCTAssertEqual(summary.severity, .collecting)
        XCTAssertTrue(summary.issues.isEmpty)
    }

    func testPublicThermalStatesDetermineHealthWithoutNumericTemperature() {
        for (state, kind, severity) in [
            (SystemThermalState.fair, HealthIssueKind.thermalFair, HealthSeverity.attention),
            (.serious, .thermalSerious, .attention),
            (.critical, .thermalCritical, .critical),
        ] {
            var input = healthyInput(cpu: points(value: 0.2, duration: 30))
            input.thermalState = state
            let summary = SystemHealthEvaluator.evaluate(input)
            XCTAssertEqual(summary.severity, severity)
            XCTAssertEqual(summary.issues.map(\.kind), [kind])
            XCTAssertNil(summary.issues.first?.measuredValue)
        }
    }

    func testUnknownOrNominalThermalStateDoesNotCreateAnIssue() {
        for state in [SystemThermalState.unknown, .nominal] {
            var input = healthyInput(cpu: points(value: 0.2, duration: 30))
            input.thermalState = state
            XCTAssertTrue(SystemHealthEvaluator.evaluate(input).issues.isEmpty)
        }
    }

    private func healthyInput(cpu: [MetricPoint]) -> SystemHealthInput {
        SystemHealthInput(
            cpuHistory: cpu,
            memoryPressure: .normal,
            diskFreeBytes: 200 * 1_000_000_000,
            diskTotalBytes: 500 * 1_000_000_000,
            hasPrimaryNetwork: true,
            now: now
        )
    }

    private func points(value: Double, duration: Int) -> [MetricPoint] {
        stride(from: duration, through: 0, by: -2).map {
            MetricPoint(timestamp: now.addingTimeInterval(Double(-$0)), value: value)
        }
    }
}
