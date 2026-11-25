import XCTest
@testable import LynxBar

@MainActor
final class GPUAndBatteryModuleTests: XCTestCase {
    func testModuleVisibilityDefaultsAndPersistence() {
        let suiteName = "LynxBarTests.GPUBatterySettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.gpuEnabled)
        XCTAssertTrue(settings.batteryEnabled)

        settings.gpuEnabled = false
        settings.batteryEnabled = false

        let restored = Settings(defaults: defaults)
        XCTAssertFalse(restored.gpuEnabled)
        XCTAssertFalse(restored.batteryEnabled)
    }

    func testGPUHistoryKeepsValidZeroAndPrunesWithoutFabricatingUnavailableSample() {
        let settings = isolatedSettings()
        let viewModel = GPUViewModel(settings: settings)
        let anchor = Date(timeIntervalSince1970: 10_000)

        viewModel.apply(
            GPUSnapshot(availability: .available, devices: [], usage: 0),
            at: anchor.addingTimeInterval(-59)
        )
        XCTAssertEqual(viewModel.history, [0])

        viewModel.apply(
            GPUSnapshot(availability: .available, devices: [], usage: nil),
            at: anchor.addingTimeInterval(2)
        )
        XCTAssertTrue(viewModel.history.isEmpty)
        XCTAssertNil(viewModel.snapshot.usage)
    }

    func testBatteryUnavailableSnapshotDoesNotFabricateCharge() {
        let settings = isolatedSettings()
        let viewModel = BatteryViewModel(settings: settings)
        let anchor = Date(timeIntervalSince1970: 20_000)

        viewModel.apply(
            BatterySnapshot(availability: .available, level: 0.64),
            at: anchor
        )
        viewModel.apply(BatterySnapshot(), at: anchor.addingTimeInterval(1))

        XCTAssertEqual(viewModel.snapshot.availability, .noInternalBattery)
        XCTAssertNil(viewModel.snapshot.level)
    }

    func testDashboardDefinesGPUAndBatteryDestinations() {
        XCTAssertTrue(DashboardSection.allCases.contains(.gpu))
        XCTAssertTrue(DashboardSection.allCases.contains(.battery))
        XCTAssertFalse(DashboardSection.gpu.systemName.isEmpty)
        XCTAssertFalse(DashboardSection.battery.systemName.isEmpty)
    }

    func testLiveProvidersReturnInternallyConsistentSnapshots() {
        let gpu = GPUProvider.sample()
        if gpu.availability == .available {
            XCTAssertFalse(gpu.devices.isEmpty)
        } else {
            XCTAssertTrue(gpu.devices.isEmpty)
            XCTAssertNil(gpu.usage)
        }
        if let usage = gpu.usage {
            XCTAssertTrue((0...1).contains(usage))
        }

        let battery = BatteryProvider.sample()
        if battery.availability == .available {
            if let level = battery.level {
                XCTAssertTrue((0...1).contains(level))
            }
        } else {
            XCTAssertNil(battery.level)
        }

        print(
            "Live GPU devices=\(gpu.devices.map(\.name)), usage=\(String(describing: gpu.usage)); "
                + "battery=\(battery.availability), level=\(String(describing: battery.level))"
        )
    }

    private func isolatedSettings() -> Settings {
        let suiteName = "LynxBarTests.GPUBatteryViewModel.\(UUID().uuidString)"
        return Settings(defaults: UserDefaults(suiteName: suiteName)!)
    }
}
