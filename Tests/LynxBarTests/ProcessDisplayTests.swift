import XCTest
@testable import LynxBar

final class ProcessDisplayTests: XCTestCase {
    private func makeProcess(cpuUsage: Double?) -> DisplayProcess {
        DisplayProcess(pid: 4242, name: "probe", cpuUsage: cpuUsage, memoryBytes: 1_024)
    }

    func testUnknownUsageRendersAsDashNotZeroPercent() {
        let text = ProcessRowFormatter.cpuText(for: makeProcess(cpuUsage: nil))
        XCTAssertFalse(
            text.contains("0"),
            "未知占用被渲染成含 0 的文本（实际为「\(text)」）—— 「不知道」不得显示为 0"
        )
    }

    func testKnownUsageStillRendersPercentage() {
        let text = ProcessRowFormatter.cpuText(for: makeProcess(cpuUsage: 0.25))
        XCTAssertTrue(text.contains("25"), "已知占用应正常显示百分比，实际为「\(text)」")
    }

    func testUnknownUsageSortsAfterKnownUsage() {
        let rows = [
            makeProcess(cpuUsage: nil),
            makeProcess(cpuUsage: 0.10),
            makeProcess(cpuUsage: nil),
            makeProcess(cpuUsage: 0.90),
        ]
        let sorted = ProcessRowFormatter.sortedByCPU(rows)
        XCTAssertEqual(sorted.prefix(2).compactMap(\.cpuUsage), [0.90, 0.10])
        XCTAssertTrue(sorted.suffix(2).allSatisfy { $0.cpuUsage == nil })
    }

    func testAccessibilityLabelDoesNotAnnounceUnknownAsZero() {
        let label = ProcessRowFormatter.accessibilityLabel(for: makeProcess(cpuUsage: nil))
        XCTAssertFalse(
            label.contains("0%"),
            "VoiceOver 会把未知占用读成 0%（实际为「\(label)」）"
        )
    }

    /// `ProcessRow`（单指标行，CPU/Memory 面板可切换展示）用的是另一种
    /// accessibility label 拼法（"<name>, <metric> <value>"），不经过上面的
    /// `accessibilityLabel(for:)`。这条路径能独立于上面的测试重新引入 0%，
    /// 必须单独锁定。
    func testMetricAccessibilityLabelDoesNotAnnounceUnknownCPUAsZero() {
        let label = ProcessRowFormatter.accessibilityLabel(
            for: makeProcess(cpuUsage: nil),
            metric: .cpu
        )
        XCTAssertFalse(
            label.contains("0%"),
            "单指标行的 accessibility label 把未知 CPU 占用读成 0%（实际为「\(label)」）"
        )
    }
}
