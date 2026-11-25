import AppKit
import XCTest
@testable import LynxBar

/// `PanelHost` 是「面板可见性 + 当前 section」demand 的唯一宿主（不能用
/// SwiftUI View 结构体做 owner，见 `MonitoringDemand.swift` 的纪律注释）。
/// 这里直接用真实 `NSStatusItem` 驱动它，验证开关和 section 切换不会
/// 泄漏或累加 demand —— 这是 Task A.3 最容易悄悄写错的地方。
@MainActor
final class PanelHostTests: XCTestCase {
    func testRepeatedOpenCloseDoesNotAccumulateDemand() {
        let demandCoordinator = MonitoringDemandCoordinator()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let host = PanelHost(statusItem: item, demandCoordinator: demandCoordinator) { _ in
            NSViewController()
        }

        for _ in 0..<20 {
            host.toggle() // show
            host.toggle() // close
        }

        for module in MonitoringModule.allCases {
            XCTAssertEqual(
                demandCoordinator.demandCount(for: module), 0,
                "\(module) 在 20 次开关后 demand 计数应归零"
            )
        }
    }

    func testShowingPanelAcquiresOverviewModulesAndClosingReleasesThem() {
        let demandCoordinator = MonitoringDemandCoordinator()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let host = PanelHost(statusItem: item, demandCoordinator: demandCoordinator) { _ in
            NSViewController()
        }

        host.toggle()
        for module in MonitoringDemandBinding.modules(for: .overview) {
            XCTAssertEqual(demandCoordinator.demandCount(for: module), 1)
        }

        host.toggle()
        for module in MonitoringModule.allCases {
            XCTAssertEqual(demandCoordinator.demandCount(for: module), 0)
        }
    }

    func testSectionSwitchReleasesModulesExclusiveToThePreviousSection() {
        let demandCoordinator = MonitoringDemandCoordinator()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        var reportSelection: ((DashboardSection) -> Void)?
        let host = PanelHost(statusItem: item, demandCoordinator: demandCoordinator) { onChange in
            reportSelection = onChange
            return NSViewController()
        }

        host.toggle() // 打开，默认 .overview
        reportSelection?(.gpu)

        for module in MonitoringDemandBinding.modules(for: .overview)
        where !MonitoringDemandBinding.modules(for: .gpu).contains(module) {
            XCTAssertEqual(
                demandCoordinator.demandCount(for: module), 0,
                "\(module) 只属于旧 section，切换后必须释放"
            )
        }
        XCTAssertEqual(demandCoordinator.demandCount(for: .gpu), 1)

        host.toggle() // 关闭
        XCTAssertEqual(demandCoordinator.demandCount(for: .gpu), 0)
    }

    /// SwiftUI 会为同一个可见 section 反复重建 view 并重复上报；重复上报
    /// 同一个 section 不应触发额外的 release+acquire（那会造成不必要的
    /// stop+restart）。这里断言的是「多次上报同一值前后计数不变」——如果
    /// `updateSelection` 没有 short-circuit，count 不会变成 2（幂等键仍会
    /// 吸收），但会有一次不必要的 stop/restart 边沿，用计数断言无法直接看到
    /// 边沿，因此改由 `PanelHostTests` 的兄弟测试
    /// （`MonitoringDemandBindingTests`/`RemediationCoordinatorTests`）覆盖
    /// 边沿语义，这里只保证重复上报不会让计数偏离预期值。
    func testRepeatedReportOfTheSameSectionDoesNotDriftDemandCount() {
        let demandCoordinator = MonitoringDemandCoordinator()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        var reportSelection: ((DashboardSection) -> Void)?
        let host = PanelHost(statusItem: item, demandCoordinator: demandCoordinator) { onChange in
            reportSelection = onChange
            return NSViewController()
        }

        host.toggle()
        reportSelection?(.overview)
        reportSelection?(.overview)
        reportSelection?(.overview)

        for module in MonitoringDemandBinding.modules(for: .overview) {
            XCTAssertEqual(demandCoordinator.demandCount(for: module), 1)
        }
    }

    /// Task C.2：面板关闭是历史落盘节流之外补 flush 的低成本时机之一，
    /// `onClose` 是这条路径唯一的接线点。这里锁住两件事：面板真正从可见
    /// 变关闭时必须触发一次；面板本来就没打开时调用 `close()`（例如 App
    /// 退出时的收尾调用）不该凭空触发一次多余的回调。
    func testOnCloseFiresOnlyWhenPanelTransitionsFromVisibleToClosed() {
        let demandCoordinator = MonitoringDemandCoordinator()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let host = PanelHost(statusItem: item, demandCoordinator: demandCoordinator) { _ in
            NSViewController()
        }
        var closeCount = 0
        host.onClose = { closeCount += 1 }

        host.close()
        XCTAssertEqual(closeCount, 0, "面板本来就未打开,close() 不应触发 onClose")

        host.toggle() // 打开
        XCTAssertEqual(closeCount, 0)
        host.toggle() // 关闭
        XCTAssertEqual(closeCount, 1, "面板从可见变关闭必须触发一次 onClose")

        host.toggle() // 再次打开
        host.toggle() // 再次关闭
        XCTAssertEqual(closeCount, 2, "每次真正的关闭都应各触发一次,不该漏计或多计")
    }
}
