import XCTest
@testable import LynxBar

@MainActor
final class MonitoringDemandTests: XCTestCase {
    private final class Owner: MonitoringDemandOwner {
        var token: DemandToken?
    }

    func testFirstAcquireStartsModuleExactlyOnce() {
        var events: [(MonitoringModule, Bool)] = []
        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { events.append(($0, $1)) }
        let owner = Owner()

        _ = coordinator.acquire(module: .gpu, reason: .panel(.gpu), owner: owner)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].0, .gpu)
        XCTAssertTrue(events[0].1)
    }

    func testSecondConsumerDoesNotStartASecondLoop() {
        var startCount = 0
        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { _, isDemanded in if isDemanded { startCount += 1 } }
        let panelOwner = Owner()
        let menuBarOwner = Owner()

        let a = coordinator.acquire(module: .cpu, reason: .panel(.cpu), owner: panelOwner)
        let b = coordinator.acquire(module: .cpu, reason: .menuBar, owner: menuBarOwner)

        XCTAssertEqual(startCount, 1, "两个消费者只能有一个 sampler loop")
        XCTAssertEqual(coordinator.demandCount(for: .cpu), 2)
        withExtendedLifetime((a, b)) {}
    }

    func testModuleStopsOnlyWhenLastTokenReleased() {
        var events: [Bool] = []
        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { _, isDemanded in events.append(isDemanded) }
        let panelOwner = Owner()
        let menuBarOwner = Owner()

        let panelToken = coordinator.acquire(module: .cpu, reason: .panel(.cpu), owner: panelOwner)
        let menuBarToken = coordinator.acquire(module: .cpu, reason: .menuBar, owner: menuBarOwner)

        panelToken.cancel()
        XCTAssertEqual(events, [true], "还有 menu bar 在用，不能停")
        XCTAssertEqual(coordinator.demandCount(for: .cpu), 1)

        menuBarToken.cancel()
        XCTAssertEqual(events, [true, false], "最后一个 token 释放才停")
        XCTAssertEqual(coordinator.demandCount(for: .cpu), 0)
    }

    func testRepeatedAcquireForSameOwnerAndReasonIsIdempotent() {
        let coordinator = MonitoringDemandCoordinator()
        let owner = Owner()

        let first = coordinator.acquire(module: .memory, reason: .overviewHealth, owner: owner)
        let second = coordinator.acquire(module: .memory, reason: .overviewHealth, owner: owner)
        let third = coordinator.acquire(module: .memory, reason: .overviewHealth, owner: owner)

        XCTAssertEqual(
            coordinator.demandCount(for: .memory), 1,
            "同 owner + reason 重复 acquire 不得累加 —— SwiftUI 会反复重建 view"
        )
        withExtendedLifetime((first, second, third)) {}
    }

    func testDemandSurvivesUntilEveryIssuedTokenIsReleased() {
        var events: [Bool] = []
        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { _, isDemanded in events.append(isDemanded) }
        let owner = Owner()

        let first = coordinator.acquire(module: .memory, reason: .overviewHealth, owner: owner)
        let second = coordinator.acquire(module: .memory, reason: .overviewHealth, owner: owner)

        first.cancel()
        XCTAssertEqual(events, [true], "幂等 acquire 发出的每个 token 都是真实凭证，释放一个不能让 demand 消失")
        XCTAssertEqual(coordinator.demandCount(for: .memory), 1)

        second.cancel()
        XCTAssertEqual(events, [true, false], "同一 key 名下的 token 都释放完才停")
        XCTAssertEqual(coordinator.demandCount(for: .memory), 0)
    }

    func testReacquireIntoSamePropertyDoesNotSilentlyDropDemand() async {
        // 复现调用方最自然的用法：新 token 覆盖同一个属性（正是注释里提到的
        // 「SwiftUI 反复重建 view」场景）。第一个 token 在覆盖的瞬间失去最后一个
        // 强引用而 deinit，如果幂等 acquire 返回的是不计数的空壳，这次析构会把
        // demand 错误地清零，而调用方手里还留着一个（其实是空壳的）非 nil token。
        var events: [Bool] = []
        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { _, isDemanded in events.append(isDemanded) }
        let owner = Owner()

        var storedToken = coordinator.acquire(module: .memory, reason: .overviewHealth, owner: owner)
        storedToken = coordinator.acquire(module: .memory, reason: .overviewHealth, owner: owner)

        // 给第一个 token 的异步析构 / 释放留出机会。
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            coordinator.demandCount(for: .memory), 1,
            "第一个 token 析构不得让 demand 消失 —— 第二个 token 仍持有自己那一份"
        )
        XCTAssertEqual(events, [true], "不应观测到虚假的 stop")
        withExtendedLifetime(storedToken) {}
    }

    func testDistinctReasonsFromSameOwnerCountSeparately() {
        let coordinator = MonitoringDemandCoordinator()
        let owner = Owner()

        _ = coordinator.acquire(module: .disk, reason: .panel(.disk), owner: owner)
        _ = coordinator.acquire(module: .disk, reason: .overviewHealth, owner: owner)

        XCTAssertEqual(coordinator.demandCount(for: .disk), 2)
    }

    func testSameOwnerAndReasonDemandsMultipleModulesIndependently() {
        // design.md ~458 行：overviewHealth 同时需求 CPU、memory pressure、Disk、Network。
        // 幂等键必须包含 module，否则同一个 owner + reason 请求不同模块时会被误判成重复。
        let coordinator = MonitoringDemandCoordinator()
        let owner = Owner()

        _ = coordinator.acquire(module: .cpu, reason: .overviewHealth, owner: owner)
        _ = coordinator.acquire(module: .memory, reason: .overviewHealth, owner: owner)
        _ = coordinator.acquire(module: .disk, reason: .overviewHealth, owner: owner)
        _ = coordinator.acquire(module: .network, reason: .overviewHealth, owner: owner)

        XCTAssertEqual(coordinator.demandCount(for: .cpu), 1)
        XCTAssertEqual(coordinator.demandCount(for: .memory), 1)
        XCTAssertEqual(coordinator.demandCount(for: .disk), 1)
        XCTAssertEqual(coordinator.demandCount(for: .network), 1)
    }

    func testCancelIsIdempotent() {
        var events: [Bool] = []
        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { _, isDemanded in events.append(isDemanded) }
        let owner = Owner()

        let token = coordinator.acquire(module: .battery, reason: .panel(.battery), owner: owner)
        token.cancel()
        token.cancel()
        token.cancel()

        XCTAssertEqual(events, [true, false], "重复 cancel 不得产生多次 stop")
    }

    func testOwnerDeallocationEventuallyReleasesDemand() async {
        var events: [Bool] = []
        let coordinator = MonitoringDemandCoordinator()
        coordinator.onDemandChange = { _, isDemanded in events.append(isDemanded) }

        do {
            let owner = Owner()
            owner.token = coordinator.acquire(module: .gpu, reason: .panel(.gpu), owner: owner)
            XCTAssertEqual(coordinator.demandCount(for: .gpu), 1)
        }
        // owner 连同它持有的 token 一起随作用域析构；spec 用的是 "eventually"，允许异步释放。
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(coordinator.demandCount(for: .gpu), 0)
        XCTAssertEqual(events, [true, false])
    }

    func testUnrelatedModulesDoNotInterfere() {
        let coordinator = MonitoringDemandCoordinator()
        let owner = Owner()

        let cpuToken = coordinator.acquire(module: .cpu, reason: .panel(.cpu), owner: owner)
        _ = coordinator.acquire(module: .gpu, reason: .panel(.gpu), owner: owner)
        cpuToken.cancel()

        XCTAssertEqual(coordinator.demandCount(for: .cpu), 0)
        XCTAssertEqual(coordinator.demandCount(for: .gpu), 1)
    }
}
