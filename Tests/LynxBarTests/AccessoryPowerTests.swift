import Foundation
@preconcurrency import GameController
import XCTest
@testable import LynxBar

final class AccessoryPowerModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 30_000)

    func testSameNameDevicesRemainSeparateBySourceAndStableIdentifier() {
        let first = record(
            source: .gameController,
            stableID: "controller-a",
            name: "Controller",
            parts: [part(.main, 0.8)]
        )
        let second = record(
            source: .gameController,
            stableID: "controller-b",
            name: "Controller",
            parts: [part(.main, 0.6)]
        )
        let third = record(
            source: .standardBLE,
            stableID: "controller-a",
            name: "Controller",
            parts: [part(.main, 0.4)]
        )
        let snapshot = AccessoryPowerMerger.merge(
            updates: [
                .gameController: update(.gameController, [first, second]),
                .standardBLE: update(.standardBLE, [third]),
            ],
            now: now
        )

        XCTAssertEqual(snapshot.records.count, 3)
        XCTAssertEqual(Set(snapshot.records.map(\.identity)).count, 3)
    }

    func testMultipartValuesRetainMeaningWithoutFillingMissingPart() {
        let multipart = record(
            source: .standardBLE,
            stableID: "earbuds",
            name: "Battery Device",
            parts: [
                part(.left, 0.51),
                part(.case, 0.72),
            ]
        )
        let snapshot = AccessoryPowerMerger.merge(
            updates: [.standardBLE: update(.standardBLE, [multipart])],
            now: now
        )
        let resolved = try? XCTUnwrap(snapshot.records.first)

        XCTAssertEqual(resolved?.part(.left)?.level, 0.51)
        XCTAssertEqual(resolved?.part(.case)?.level, 0.72)
        XCTAssertNil(resolved?.part(.right))
        XCTAssertNil(resolved?.part(.main))
    }

    func testFreshMultipartRecordDropsOnlyExpiredPart() {
        let record = AccessoryPowerRecord(
            identity: AccessoryPowerIdentity(
                source: .standardBLE,
                stableIdentifier: "multipart-freshness"
            ),
            displayName: "Battery Device",
            availability: .available,
            parts: [
                AccessoryBatteryPart(
                    kind: .left,
                    level: 0.4,
                    chargeState: .unknown,
                    observedAt: now.addingTimeInterval(-181)
                ),
                part(.case, 0.7),
            ],
            observedAt: now,
            staleAfter: 180
        )

        let resolved = AccessoryPowerMerger.validated(record, now: now)

        XCTAssertEqual(resolved.availability, .available)
        XCTAssertNil(resolved.part(.left))
        XCTAssertEqual(resolved.part(.case)?.level, 0.7)
    }

    func testFutureAccessoryObservationDoesNotBecomeCurrent() {
        let future = AccessoryPowerRecord(
            identity: AccessoryPowerIdentity(
                source: .standardBLE,
                stableIdentifier: "future"
            ),
            displayName: "Future Device",
            availability: .available,
            parts: [
                AccessoryBatteryPart(
                    kind: .main,
                    level: 0.5,
                    chargeState: .unknown,
                    observedAt: now.addingTimeInterval(1)
                ),
            ],
            observedAt: now.addingTimeInterval(1),
            staleAfter: 180
        )

        let resolved = AccessoryPowerMerger.validated(future, now: now)

        XCTAssertEqual(resolved.availability, .batteryUnavailable)
        XCTAssertTrue(resolved.parts.isEmpty)
    }

    func testStaleAndInvalidLevelsDropNumericValuesButZeroIsValid() {
        let stale = AccessoryPowerRecord(
            identity: AccessoryPowerIdentity(
                source: .standardBLE,
                stableIdentifier: "stale"
            ),
            displayName: "Stale Device",
            availability: .available,
            parts: [
                AccessoryBatteryPart(
                    kind: .main,
                    level: 0.8,
                    chargeState: .unknown,
                    observedAt: now.addingTimeInterval(-181)
                ),
            ],
            observedAt: now.addingTimeInterval(-181),
            staleAfter: 180
        )
        let invalid = record(
            source: .standardBLE,
            stableID: "invalid",
            name: "Invalid Device",
            parts: [part(.main, 1.1)]
        )
        let zero = record(
            source: .standardBLE,
            stableID: "zero",
            name: "Empty Device",
            parts: [part(.main, 0)]
        )
        let snapshot = AccessoryPowerMerger.merge(
            updates: [
                .standardBLE: update(
                    .standardBLE,
                    [stale, invalid, zero]
                ),
            ],
            now: now
        )
        let byID = Dictionary(
            uniqueKeysWithValues: snapshot.records.map {
                ($0.identity.stableIdentifier, $0)
            }
        )

        XCTAssertEqual(byID["stale"]?.availability, .stale)
        XCTAssertTrue(byID["stale"]?.parts.isEmpty == true)
        XCTAssertEqual(byID["invalid"]?.availability, .batteryUnavailable)
        XCTAssertTrue(byID["invalid"]?.parts.isEmpty == true)
        XCTAssertEqual(byID["zero"]?.availability, .available)
        XCTAssertEqual(byID["zero"]?.part(.main)?.level, 0)
    }

    func testControllerNilBatteryAndDisconnectDoNotBecomeZero() {
        let records = GameControllerAdapter.records(
            from: [
                GameControllerDescriptor(
                    stableIdentifier: "no-battery",
                    displayName: "Controller",
                    batteryLevel: nil,
                    batteryState: .unknown,
                    isConnected: true
                ),
                GameControllerDescriptor(
                    stableIdentifier: "disconnected",
                    displayName: "Controller",
                    batteryLevel: 0.9,
                    batteryState: .charging,
                    isConnected: false
                ),
            ],
            now: now
        )

        XCTAssertEqual(records[0].availability, .batteryUnavailable)
        XCTAssertTrue(records[0].parts.isEmpty)
        XCTAssertEqual(records[1].availability, .disconnected)
        XCTAssertTrue(records[1].parts.isEmpty)
    }

    func testUnavailableSourceCannotLeakAnAvailableCachedRecord() {
        let cached = record(source: .standardBLE, stableID: "cached", name: "Device",
                            parts: [part(.main, 0.8)])
        let snapshot = AccessoryPowerMerger.merge(updates: [.standardBLE:
            AccessoryPowerSourceUpdate(source: .standardBLE,
                availability: .permissionDenied, records: [cached], observedAt: now)], now: now)
        XCTAssertEqual(snapshot.records.first?.availability, .permissionDenied)
        XCTAssertTrue(snapshot.records.first?.parts.isEmpty == true)
        XCTAssertNil(snapshot.preferredMenuBarLevel)
    }

    private func record(
        source: AccessoryPowerSource,
        stableID: String,
        name: String,
        parts: [AccessoryBatteryPart]
    ) -> AccessoryPowerRecord {
        AccessoryPowerRecord(
            identity: AccessoryPowerIdentity(
                source: source,
                stableIdentifier: stableID
            ),
            displayName: name,
            availability: .available,
            parts: parts,
            observedAt: now,
            staleAfter: 180
        )
    }

    private func part(
        _ kind: AccessoryBatteryPartKind,
        _ level: Double
    ) -> AccessoryBatteryPart {
        AccessoryBatteryPart(
            kind: kind,
            level: level,
            chargeState: .unknown,
            observedAt: now
        )
    }

    private func update(
        _ source: AccessoryPowerSource,
        _ records: [AccessoryPowerRecord]
    ) -> AccessoryPowerSourceUpdate {
        AccessoryPowerSourceUpdate(
            source: source,
            availability: .available,
            records: records,
            observedAt: now
        )
    }
}

@MainActor
final class StandardBLEBatteryContractTests: XCTestCase {
    func testInactiveAdapterCreatesNoCentralScanConnectionOrTimer() {
        let harness = BLEHarness()
        harness.adapter.refresh()
        XCTAssertEqual(harness.client.startCount, 0)
        XCTAssertEqual(harness.client.scanCount, 0)
        XCTAssertTrue(harness.client.connectIDs.isEmpty)
        XCTAssertEqual(harness.scheduler.startCount, 0)
    }
    func testPermissionDeniedAndPoweredOffStopScanningWithoutRecordLeak() {
        let harness = BLEHarness()
        harness.start()
        harness.client.emit(.authorization(.denied))

        XCTAssertEqual(harness.latest?.availability, .permissionDenied)
        XCTAssertEqual(harness.client.stopScanCount, 1)
        XCTAssertEqual(harness.client.disconnectAllCount, 1)
        XCTAssertEqual(harness.scheduler.startCount, 0)

        harness.client.emit(.authorization(.allowed))
        harness.client.emit(.power(.poweredOff))
        XCTAssertEqual(harness.latest?.availability, .bluetoothPoweredOff)
        XCTAssertGreaterThanOrEqual(harness.client.stopScanCount, 2)
        XCTAssertGreaterThanOrEqual(harness.client.disconnectAllCount, 2)
    }

    func testAuthorizedPoweredOnScansOnceAndStopTearsDownEverything() {
        let harness = BLEHarness()
        harness.start()
        harness.client.emit(.authorization(.allowed))
        harness.client.emit(.power(.poweredOn))
        harness.client.emit(.power(.poweredOn))

        XCTAssertEqual(harness.client.scanCount, 1)
        XCTAssertEqual(harness.scheduler.startCount, 1)
        XCTAssertEqual(harness.latest?.availability, .scanning)

        harness.adapter.stop()
        XCTAssertEqual(harness.client.stopScanCount, 1)
        XCTAssertEqual(harness.client.disconnectAllCount, 1)
        XCTAssertEqual(harness.client.stopCount, 1)
        XCTAssertEqual(harness.scheduler.stopCount, 1)
    }

    func testNoServiceAndNoCharacteristicRemainUnsupported() {
        let harness = BLEHarness()
        harness.startReady()
        harness.discover(id: "no-service")
        harness.client.emit(.connected("no-service"))
        harness.client.emit(.services(
            "no-service",
            hasBatteryService: false
        ))

        XCTAssertEqual(
            harness.record("no-service")?.availability,
            .unsupported
        )
        harness.client.emit(.characteristic("no-service", hasBatteryLevel: true))
        harness.client.emit(.level("no-service", Data([99])))
        XCTAssertEqual(harness.record("no-service")?.availability, .unsupported)
        XCTAssertTrue(harness.record("no-service")?.parts.isEmpty == true)

        harness.discover(id: "no-characteristic")
        harness.client.emit(.connected("no-characteristic"))
        harness.client.emit(.services(
            "no-characteristic",
            hasBatteryService: true
        ))
        harness.client.emit(.characteristic(
            "no-characteristic",
            hasBatteryLevel: false
        ))

        XCTAssertEqual(
            harness.record("no-characteristic")?.availability,
            .unsupported
        )
        XCTAssertEqual(
            harness.client.discoverCharacteristicIDs,
            ["no-characteristic"]
        )
    }

    func testBatteryLevelValidationDisconnectAndRefreshContract() {
        let harness = BLEHarness()
        harness.startReady()
        harness.discover(id: "battery")
        harness.client.emit(.connected("battery"))
        harness.client.emit(.services("battery", hasBatteryService: true))
        harness.client.emit(.characteristic(
            "battery",
            hasBatteryLevel: true
        ))
        harness.client.emit(.level("battery", Data([75])))

        XCTAssertEqual(harness.record("battery")?.part(.main)?.level, 0.75)
        XCTAssertEqual(harness.latest?.availability, .available)

        harness.client.emit(.level("battery", Data([255])))
        XCTAssertEqual(
            harness.record("battery")?.availability,
            .batteryUnavailable
        )
        XCTAssertTrue(harness.record("battery")?.parts.isEmpty == true)

        harness.client.emit(.level("battery", Data([75, 0])))
        XCTAssertEqual(harness.record("battery")?.availability, .batteryUnavailable)

        harness.client.emit(.level("battery", Data([0])))
        XCTAssertEqual(harness.record("battery")?.part(.main)?.level, 0)
        harness.scheduler.fire()
        XCTAssertTrue(harness.client.readIDs.contains("battery"))

        harness.client.emit(.disconnected("battery"))
        XCTAssertEqual(
            harness.record("battery")?.availability,
            .disconnected
        )
        XCTAssertTrue(harness.record("battery")?.parts.isEmpty == true)
    }

    func testLateValuesCannotReviveDisconnectedDeniedPoweredOffOrResetDevice() {
        for event in [BLECentralEvent.disconnected("battery"),
                      .authorization(.denied), .power(.poweredOff), .power(.resetting)] {
            let harness = BLEHarness()
            harness.startReady()
            harness.makeReadable(id: "battery")
            harness.client.emit(.level("battery", Data([50])))
            XCTAssertEqual(harness.record("battery")?.part(.main)?.level, 0.5)
            harness.client.emit(event)
            let unavailable = harness.record("battery")
            harness.client.emit(.level("battery", Data([99])))
            harness.client.emit(.characteristic("battery", hasBatteryLevel: true))
            harness.client.emit(.level("battery", Data([99])))
            XCTAssertEqual(harness.record("battery"), unavailable)
            XCTAssertTrue(harness.record("battery")?.parts.isEmpty == true)
            harness.adapter.stop()
        }
    }

    func testDiscoveryFailureIsDistinctAndRemovesReadQualification() {
        let harness = BLEHarness()
        harness.startReady()
        harness.makeReadable(id: "battery")
        harness.client.emit(.level("battery", Data([50])))
        harness.client.emit(.discoveryFailed("battery"))
        XCTAssertEqual(harness.record("battery")?.availability, .discoveryFailed)
        harness.client.emit(.level("battery", Data([99])))
        XCTAssertTrue(harness.record("battery")?.parts.isEmpty == true)
        harness.adapter.stop()
    }

    func testStopRejectsCapturedCallbackAndScheduledRefresh() {
        let harness = BLEHarness()
        harness.startReady()
        harness.makeReadable(id: "battery")
        harness.client.emit(.level("battery", Data([50])))
        let callback = harness.client.onEvent
        let before = harness.latest
        let reads = harness.client.readIDs.count
        harness.adapter.stop()
        callback?(.level("battery", Data([99])))
        harness.scheduler.fire()
        XCTAssertEqual(harness.latest, before)
        XCTAssertEqual(harness.client.readIDs.count, reads)
    }

    func testDeniedAuthorizationRemainsTheReasonWhenPowerStateChanges() {
        let harness = BLEHarness()
        harness.startReady()
        harness.client.emit(.authorization(.denied))
        harness.client.emit(.power(.poweredOff))
        XCTAssertEqual(harness.latest?.availability, .permissionDenied)
        harness.client.emit(.power(.poweredOn))
        XCTAssertEqual(harness.latest?.availability, .permissionDenied)
        XCTAssertEqual(harness.client.scanCount, 1)
        harness.adapter.stop()
    }
}

@MainActor
final class AccessoryPowerViewModelTests: XCTestCase {
    func testBLERemainsOffWithoutOptInAndStopsWithDemand() {
        let suiteName = "LynxBarTests.Accessory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        let controller = FakeAccessoryAdapter(source: .gameController)
        let ble = FakeAccessoryAdapter(source: .standardBLE)
        let viewModel = AccessoryPowerViewModel(
            settings: settings,
            gameControllerAdapter: controller,
            standardBLEAdapter: ble,
            sleeper: { _ in try await Task.sleep(for: .seconds(60)) }
        )

        XCTAssertEqual(controller.startCount, 0)
        XCTAssertEqual(ble.startCount, 0)

        viewModel.startSampling()
        viewModel.startSampling()
        XCTAssertEqual(controller.startCount, 1)
        XCTAssertEqual(ble.startCount, 0)

        settings.standardBLEBatteryEnabled = true
        XCTAssertEqual(ble.startCount, 1)

        settings.standardBLEBatteryEnabled = false
        XCTAssertEqual(ble.stopCount, 1)
        XCTAssertEqual(viewModel.snapshot.sourceAvailability[.standardBLE], .optedOut)
        settings.standardBLEBatteryEnabled = true
        XCTAssertEqual(ble.startCount, 2)

        viewModel.stopSampling()
        XCTAssertEqual(controller.stopCount, 1)
        XCTAssertEqual(ble.stopCount, 2)

        settings.standardBLEBatteryEnabled = false
        settings.standardBLEBatteryEnabled = true
        XCTAssertEqual(ble.startCount, 2)
    }

    func testStoppedAndOptedOutSourcesCannotPublishLateValues() throws {
        let suite = "LynxBarTests.Accessory.Late.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        settings.standardBLEBatteryEnabled = true
        let controller = FakeAccessoryAdapter(source: .gameController)
        let ble = FakeAccessoryAdapter(source: .standardBLE)
        let viewModel = AccessoryPowerViewModel(settings: settings,
            gameControllerAdapter: controller, standardBLEAdapter: ble,
            sleeper: { _ in try await Task.sleep(for: .seconds(60)) })
        viewModel.startSampling()
        let lateBLE = try XCTUnwrap(ble.callbacks.first)
        let lateController = try XCTUnwrap(controller.callbacks.first)
        settings.standardBLEBatteryEnabled = false
        lateBLE(update(source: .standardBLE, stableID: "late",
            observedAt: Date(), staleAfter: 180))
        XCTAssertTrue(viewModel.snapshot.records.isEmpty)
        XCTAssertEqual(viewModel.snapshot.sourceAvailability[.standardBLE], .optedOut)
        viewModel.stopSampling()
        let before = viewModel.snapshot
        lateController(update(source: .gameController, stableID: "late",
            observedAt: Date(), staleAfter: 15))
        XCTAssertEqual(viewModel.snapshot, before)
    }

    func testCancelledSleepCannotRefreshAfterStop() async {
        let suite = "LynxBarTests.Accessory.Sleep.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = FakeAccessoryAdapter(source: .gameController)
        let gate = AccessorySleepGate()
        let viewModel = AccessoryPowerViewModel(settings: Settings(defaults: defaults),
            gameControllerAdapter: controller,
            standardBLEAdapter: FakeAccessoryAdapter(source: .standardBLE),
            sleeper: { _ in await gate.sleep() })
        viewModel.startSampling()
        for _ in 0..<100 {
            if await gate.isSleeping { break }
            await Task.yield()
        }
        let wasSleeping = await gate.isSleeping
        XCTAssertTrue(wasSleeping)
        viewModel.stopSampling()
        await gate.resume()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.refreshCount, 0)
    }

    func testFreshnessUsesThreeConfiguredSourceIntervals() throws {
        let suiteName = "LynxBarTests.Accessory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        settings.updateInterval = 10
        settings.standardBLEBatteryEnabled = true
        let controller = FakeAccessoryAdapter(source: .gameController)
        let ble = FakeAccessoryAdapter(source: .standardBLE)
        let viewModel = AccessoryPowerViewModel(
            settings: settings,
            gameControllerAdapter: controller,
            standardBLEAdapter: ble,
            sleeper: { _ in try await Task.sleep(for: .seconds(60)) }
        )
        viewModel.startSampling()
        defer { viewModel.stopSampling() }

        let now = Date()
        controller.emit(update(
            source: .gameController,
            stableID: "controller",
            observedAt: now,
            staleAfter: 15
        ))
        ble.emit(update(
            source: .standardBLE,
            stableID: "ble-device",
            observedAt: now,
            staleAfter: 1
        ))

        let byID = Dictionary(
            uniqueKeysWithValues: viewModel.snapshot.records.map {
                ($0.identity.stableIdentifier, $0)
            }
        )
        XCTAssertEqual(
            try XCTUnwrap(byID["controller"]).staleAfter,
            30
        )
        XCTAssertEqual(
            try XCTUnwrap(byID["ble-device"]).staleAfter,
            StandardBLEBatteryAdapter.refreshInterval * 3
        )
    }

    func testFutureDatedAdapterValueIsNotPublishedAsCurrent() throws {
        let suiteName = "LynxBarTests.Accessory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        let controller = FakeAccessoryAdapter(source: .gameController)
        let viewModel = AccessoryPowerViewModel(
            settings: settings,
            gameControllerAdapter: controller,
            standardBLEAdapter: FakeAccessoryAdapter(source: .standardBLE),
            sleeper: { _ in try await Task.sleep(for: .seconds(60)) }
        )
        viewModel.startSampling()
        defer { viewModel.stopSampling() }

        controller.emit(update(
            source: .gameController,
            stableID: "future",
            observedAt: Date().addingTimeInterval(60),
            staleAfter: 15
        ))

        let record = try XCTUnwrap(viewModel.snapshot.records.first)
        XCTAssertEqual(record.availability, .batteryUnavailable)
        XCTAssertTrue(record.parts.isEmpty)
    }

    private func update(
        source: AccessoryPowerSource,
        stableID: String,
        observedAt: Date,
        staleAfter: TimeInterval
    ) -> AccessoryPowerSourceUpdate {
        AccessoryPowerSourceUpdate(
            source: source,
            availability: .available,
            records: [
                AccessoryPowerRecord(
                    identity: AccessoryPowerIdentity(
                        source: source,
                        stableIdentifier: stableID
                    ),
                    displayName: stableID,
                    availability: .available,
                    parts: [
                        AccessoryBatteryPart(
                            kind: .main,
                            level: 0.5,
                            chargeState: .unknown,
                            observedAt: observedAt
                        ),
                    ],
                    observedAt: observedAt,
                    staleAfter: staleAfter
                ),
            ],
            observedAt: observedAt
        )
    }
}

@MainActor
private final class BLEHarness {
    let client = FakeBLECentralClient()
    let scheduler = FakeBLERefreshScheduler()
    let adapter: StandardBLEBatteryAdapter
    private(set) var latest: AccessoryPowerSourceUpdate?

    init() {
        adapter = StandardBLEBatteryAdapter(
            client: client,
            scheduler: scheduler
        )
    }

    func start() {
        adapter.start { [weak self] update in
            self?.latest = update
        }
    }

    func startReady() {
        start()
        client.emit(.authorization(.allowed))
        client.emit(.power(.poweredOn))
    }

    func discover(id: String) {
        client.emit(.discovered(BLEPeripheralDescriptor(
            stableIdentifier: id,
            displayName: "Battery Device"
        )))
    }

    func makeReadable(id: String) {
        discover(id: id)
        client.emit(.connected(id))
        client.emit(.services(id, hasBatteryService: true))
        client.emit(.characteristic(id, hasBatteryLevel: true))
    }

    func record(_ id: String) -> AccessoryPowerRecord? {
        latest?.records.first {
            $0.identity.stableIdentifier == id
        }
    }
}

@MainActor
private final class FakeBLECentralClient: BLECentralClient {
    var onEvent: (@MainActor (BLECentralEvent) -> Void)?
    var startCount = 0
    var scanCount = 0
    var stopScanCount = 0
    var connectIDs: [String] = []
    var discoverServiceIDs: [String] = []
    var discoverCharacteristicIDs: [String] = []
    var readIDs: [String] = []
    var disconnectAllCount = 0
    var stopCount = 0

    func start() { startCount += 1 }
    func scanForBatteryService() { scanCount += 1 }
    func stopScan() { stopScanCount += 1 }
    func connect(_ stableIdentifier: String) {
        connectIDs.append(stableIdentifier)
    }
    func discoverBatteryService(_ stableIdentifier: String) {
        discoverServiceIDs.append(stableIdentifier)
    }
    func discoverBatteryCharacteristic(_ stableIdentifier: String) {
        discoverCharacteristicIDs.append(stableIdentifier)
    }
    func readBatteryLevel(_ stableIdentifier: String) {
        readIDs.append(stableIdentifier)
    }
    func disconnectAll() { disconnectAllCount += 1 }
    func stop() { stopCount += 1 }

    func emit(_ event: BLECentralEvent) {
        onEvent?(event)
    }
}

@MainActor
private final class FakeBLERefreshScheduler: BLERefreshScheduler {
    var startCount = 0
    var stopCount = 0
    private var action: (@MainActor () -> Void)?

    func start(
        interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        startCount += 1
        self.action = action
    }

    func stop() {
        stopCount += 1
        action = nil
    }

    func fire() {
        action?()
    }
}

@MainActor
private final class FakeAccessoryAdapter: AccessoryPowerAdapter {
    let source: AccessoryPowerSource
    var startCount = 0
    var refreshCount = 0
    var stopCount = 0
    private var receive: (@MainActor (AccessoryPowerSourceUpdate) -> Void)?
    var callbacks: [@MainActor (AccessoryPowerSourceUpdate) -> Void] = []

    init(source: AccessoryPowerSource) {
        self.source = source
    }

    func start(
        receive: @escaping @MainActor (AccessoryPowerSourceUpdate) -> Void
    ) {
        startCount += 1
        self.receive = receive
        callbacks.append(receive)
    }

    func refresh() {
        refreshCount += 1
    }

    func stop() {
        stopCount += 1
        receive = nil
    }

    func emit(_ update: AccessoryPowerSourceUpdate) {
        receive?(update)
    }
}

@MainActor
private final class ControllerListBox {
    var controllers: [GCController]

    init(_ controllers: [GCController]) {
        self.controllers = controllers
    }
}

@MainActor
final class GameControllerLifecycleTests: XCTestCase {
    func testControllerDisconnectKeepsSessionIdentityAndDropsNumericValue() throws {
        let controller = GCController()
        let box = ControllerListBox([controller])
        let adapter = GameControllerAdapter(controllers: { box.controllers })
        var latest: AccessoryPowerSourceUpdate?
        adapter.start { latest = $0 }
        let initial = try XCTUnwrap(latest?.records.first)
        box.controllers = []
        adapter.refresh()
        let disconnected = try XCTUnwrap(latest?.records.first)
        XCTAssertEqual(disconnected.identity, initial.identity)
        XCTAssertEqual(disconnected.availability, .disconnected)
        XCTAssertTrue(disconnected.parts.isEmpty)
        box.controllers = [controller]
        adapter.refresh()
        XCTAssertEqual(latest?.records.first?.identity, initial.identity)
        adapter.stop()
        adapter.start { latest = $0 }
        XCTAssertNotEqual(latest?.records.first?.identity, initial.identity)
        adapter.stop()
    }
}

private actor AccessorySleepGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isSleeping: Bool { continuation != nil }

    func sleep() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class AccessoryPowerRowPresentationTests: XCTestCase {
    func testDifferentPartChargeStatesRemainVisibleAndAccessible() {
        let now = Date()
        let record = AccessoryPowerRecord(identity: AccessoryPowerIdentity(
            source: .standardBLE, stableIdentifier: "multipart-presentation"),
            displayName: "Battery Device", availability: .available, parts: [
                AccessoryBatteryPart(kind: .left, level: 0.31,
                    chargeState: .charging, observedAt: now),
                AccessoryBatteryPart(kind: .right, level: 0.62,
                    chargeState: .discharging, observedAt: now),
                AccessoryBatteryPart(kind: .case, level: 1,
                    chargeState: .full, observedAt: now),
                AccessoryBatteryPart(kind: .main, level: 0.5,
                    chargeState: .unknown, observedAt: now),
            ], observedAt: now, staleAfter: 180)
        let row = AccessoryPowerRow(record: record)
        for (part, percentage, state) in [
            ("Left", 0.31, "Charging"), ("Right", 0.62, "Discharging"),
            ("Case", 1.0, "Full"), ("Main", 0.5, "Charge state unknown"),
        ] {
            let partLabel = NSLocalizedString(part, comment: "")
            let stateLabel = NSLocalizedString(state, comment: "")
            let value = Formatters.percent(percentage)
            XCTAssertTrue(row.partsLabel.contains("\(partLabel) \(value) · \(stateLabel)"))
            XCTAssertTrue(row.accessibilityLabel.contains("\(partLabel), \(value), \(stateLabel)"))
        }
        XCTAssertTrue(row.accessibilityLabel.contains(
            NSLocalizedString("Standard BLE Battery Service", comment: "")))
    }

    func testUnavailablePresentationDoesNotExposeCachedPercentages() {
        let now = Date()
        let record = AccessoryPowerRecord(identity: AccessoryPowerIdentity(
            source: .standardBLE, stableIdentifier: "unavailable-presentation"),
            displayName: "Battery Device", availability: .disconnected, parts: [
                AccessoryBatteryPart(kind: .main, level: 0.87,
                    chargeState: .charging, observedAt: now),
            ], observedAt: now, staleAfter: 180)
        let row = AccessoryPowerRow(record: record)
        XCTAssertEqual(row.partsLabel, NSLocalizedString("Disconnected", comment: ""))
        XCTAssertFalse(row.partsLabel.contains(Formatters.percent(0.87)))
        XCTAssertFalse(row.accessibilityLabel.contains(Formatters.percent(0.87)))
    }
}
