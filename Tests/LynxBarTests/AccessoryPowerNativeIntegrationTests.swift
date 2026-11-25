import GameController
import XCTest
@testable import LynxBar

@MainActor
final class AccessoryPowerNativeIntegrationTests: XCTestCase {
    func testCurrentMachineCompatibleControllerBatteryWhenAvailable() throws {
        guard ProcessInfo.processInfo.environment[
            "STATS_RUN_ACCESSORY_NATIVE_INTEGRATION"
        ] == "1" else {
            throw XCTSkip(
                "Set STATS_RUN_ACCESSORY_NATIVE_INTEGRATION=1 only with a disposable compatible controller"
            )
        }
        let controllers = GCController.controllers()
        guard !controllers.isEmpty else {
            throw XCTSkip("No connected GCController is available on this machine")
        }
        guard let controller = controllers.first(where: { $0.battery != nil }),
              let battery = controller.battery else {
            throw XCTSkip("Connected controllers do not expose GCController.battery")
        }

        let records = GameControllerAdapter.records(
            from: [
                GameControllerDescriptor(
                    stableIdentifier: "native-controller-session",
                    displayName: "Native Controller",
                    batteryLevel: Double(battery.batteryLevel),
                    batteryState: mappedState(battery.batteryState),
                    isConnected: true
                ),
            ],
            now: Date()
        )
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.identity.source, .gameController)
        XCTAssertEqual(record.availability, .available)
        XCTAssertNotNil(record.part(.main))
    }

    private func mappedState(
        _ state: GCDeviceBattery.State
    ) -> GameControllerBatteryState {
        switch state {
        case .unknown: return .unknown
        case .discharging: return .discharging
        case .charging: return .charging
        case .full: return .full
        @unknown default: return .unknown
        }
    }
}
