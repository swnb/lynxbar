import XCTest
@testable import LynxBar

final class BatteryProviderTests: XCTestCase {
    func testChargingInternalBatteryMapsPublicPowerSourceFields() throws {
        let snapshot = try XCTUnwrap(BatteryProvider.snapshot(
            from: internalBattery([
                "Current Capacity": 72,
                "Max Capacity": 100,
                "Is Charging": true,
                "Is Charged": false,
                "Power Source State": "AC Power",
                "Time to Full Charge": 45,
                "BatteryHealth": "Good",
                "Name": "InternalBattery-0",
            ]),
            lowPowerModeEnabled: true
        ))

        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.name, "InternalBattery-0")
        XCTAssertEqual(try XCTUnwrap(snapshot.level), 0.72, accuracy: 0.000_1)
        XCTAssertEqual(snapshot.chargeState, .charging)
        XCTAssertEqual(snapshot.powerSource, .ac)
        XCTAssertEqual(snapshot.timeRemaining, 45 * 60)
        XCTAssertEqual(snapshot.health, .good)
        XCTAssertNil(snapshot.healthCondition)
        XCTAssertTrue(snapshot.isLowPowerModeEnabled)
    }

    func testChargedFlagWinsOverChargingAndTimeEstimateIsNotInvented() throws {
        let snapshot = try XCTUnwrap(BatteryProvider.snapshot(
            from: internalBattery([
                "Current Capacity": 100,
                "Max Capacity": 100,
                "Is Charging": false,
                "Is Charged": true,
                "Power Source State": "AC Power",
                "Time to Empty": 0,
            ]),
            lowPowerModeEnabled: false
        ))

        XCTAssertEqual(snapshot.chargeState, .charged)
        XCTAssertNil(snapshot.timeRemaining)
    }

    func testExternalPowerSourceAndAbsentInternalBatteryAreRejected() {
        XCTAssertNil(BatteryProvider.snapshot(
            from: ["Type": "UPS", "Current Capacity": 50, "Max Capacity": 100],
            lowPowerModeEnabled: false
        ))
        XCTAssertNil(BatteryProvider.snapshot(
            from: internalBattery(["Is Present": false]),
            lowPowerModeEnabled: false
        ))
    }

    func testInvalidCapacityAndTimeRemainUnavailable() throws {
        let snapshot = try XCTUnwrap(BatteryProvider.snapshot(
            from: internalBattery([
                "Current Capacity": 120,
                "Max Capacity": 100,
                "Is Charging": false,
                "Power Source State": "Battery Power",
                "Time to Empty": -1,
            ]),
            lowPowerModeEnabled: false
        ))

        XCTAssertNil(snapshot.level)
        XCTAssertEqual(snapshot.chargeState, .discharging)
        XCTAssertEqual(snapshot.powerSource, .battery)
        XCTAssertNil(snapshot.timeRemaining)
    }

    func testHealthConditionIsPreservedWhenServiceIsNeeded() throws {
        let snapshot = try XCTUnwrap(BatteryProvider.snapshot(
            from: internalBattery([
                "Current Capacity": 35,
                "Max Capacity": 100,
                "BatteryHealth": "Poor",
                "BatteryHealthCondition": "Check Battery",
            ]),
            lowPowerModeEnabled: false
        ))

        XCTAssertEqual(snapshot.health, .poor)
        XCTAssertEqual(snapshot.healthCondition, "Check Battery")
    }

    private func internalBattery(_ fields: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [
            "Type": "InternalBattery",
            "Is Present": true,
        ]
        for (key, value) in fields {
            result[key] = value
        }
        return result
    }
}
