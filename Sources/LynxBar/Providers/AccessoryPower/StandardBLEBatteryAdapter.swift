@preconcurrency import CoreBluetooth
import Foundation

enum BLEAuthorizationState: Sendable {
    case notDetermined
    case allowed
    case denied
    case restricted
}

enum BLECentralPowerState: Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

struct BLEPeripheralDescriptor: Sendable {
    let stableIdentifier: String
    let displayName: String
}

enum BLECentralEvent: Sendable {
    case authorization(BLEAuthorizationState)
    case power(BLECentralPowerState)
    case discovered(BLEPeripheralDescriptor)
    case connected(String)
    case services(String, hasBatteryService: Bool)
    case characteristic(String, hasBatteryLevel: Bool)
    case discoveryFailed(String)
    case level(String, Data?)
    case disconnected(String)
    case failed(String)
}

/// 原生 BLE 边界。start 前不得创建 CBCentralManager，stop 必须释放中心与 delegate；
/// 只发现 180F、读取 2A19，避免扩大权限或在需求之外维持扫描/连接。
@MainActor
protocol BLECentralClient: AnyObject {
    var onEvent: (@MainActor (BLECentralEvent) -> Void)? { get set }

    func start()
    func scanForBatteryService()
    func stopScan()
    func connect(_ stableIdentifier: String)
    func discoverBatteryService(_ stableIdentifier: String)
    func discoverBatteryCharacteristic(_ stableIdentifier: String)
    func readBatteryLevel(_ stableIdentifier: String)
    func disconnectAll()
    func stop()
}

@MainActor
protocol BLERefreshScheduler: AnyObject {
    func start(
        interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    )
    func stop()
}

@MainActor
final class FoundationBLERefreshScheduler: BLERefreshScheduler {
    private var timer: Timer?
    private var generation: UInt64 = 0

    func start(
        interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        stop()
        let currentGeneration = generation
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, generation == currentGeneration, timer != nil else { return }
                action()
            }
        }
    }

    func stop() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
    }
}

/// 用户 opt-in 后仍受独立 demand 驱动的标准 BLE Battery Service 适配器。
/// 本模块不读取 Apple 私有缓存、不探测附近 iPhone/iPad 电量，单字节 0...100
/// 映射成 0...1；断连/拒权/off/未知重置立即丢弃旧读数与可读资格。
@MainActor
final class StandardBLEBatteryAdapter: AccessoryPowerAdapter {
    static let batteryServiceUUID = "180F"
    static let batteryLevelUUID = "2A19"
    /// 秒，低频读取保底；无 demand 或未授权/未开蓝牙时没有 timer。
    static let refreshInterval: TimeInterval = 60

    let source: AccessoryPowerSource = .standardBLE

    private let client: BLECentralClient
    private let scheduler: BLERefreshScheduler
    private var receive: (@MainActor (AccessoryPowerSourceUpdate) -> Void)?
    private var authorization: BLEAuthorizationState = .notDetermined
    private var power: BLECentralPowerState = .unknown
    private var descriptors: [String: BLEPeripheralDescriptor] = [:]
    private var records: [String: AccessoryPowerRecord] = [:]
    private var readableIDs = Set<String>()
    private var connectedIDs = Set<String>()
    private var connectingIDs = Set<String>()
    private var batteryServiceIDs = Set<String>()
    private var isRunning = false
    private var isScanning = false
    private var isRefreshScheduled = false
    private var generation: UInt64 = 0

    init(
        client: BLECentralClient = CoreBluetoothCentralClient(),
        scheduler: BLERefreshScheduler = FoundationBLERefreshScheduler()
    ) {
        self.client = client
        self.scheduler = scheduler
    }

    func start(
        receive: @escaping @MainActor (AccessoryPowerSourceUpdate) -> Void
    ) {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        let currentGeneration = generation
        authorization = .notDetermined
        power = .unknown
        self.receive = receive
        client.onEvent = { [weak self] event in
            guard let self, isRunning, generation == currentGeneration else { return }
            handle(event)
        }
        publish(availability: .permissionNotDetermined)
        client.start()
    }

    func refresh() {
        guard isRunning, authorization == .allowed, power == .poweredOn else { return }
        for stableID in readableIDs {
            client.readBatteryLevel(stableID)
        }
        publish(availability: currentAvailability())
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        isScanning = false
        isRefreshScheduled = false
        scheduler.stop()
        client.stopScan()
        client.disconnectAll()
        client.onEvent = nil
        client.stop()
        receive = nil
        descriptors.removeAll()
        records.removeAll()
        readableIDs.removeAll()
        connectedIDs.removeAll()
        connectingIDs.removeAll()
        batteryServiceIDs.removeAll()
    }

    private func handle(_ event: BLECentralEvent) {
        guard isRunning else { return }
        switch event {
        case .authorization(let next):
            authorization = next
            switch next {
            case .notDetermined:
                suspend(availability: .permissionNotDetermined)
                publish(availability: .permissionNotDetermined)
            case .denied, .restricted:
                suspend(availability: .permissionDenied)
                publish(availability: .permissionDenied)
            case .allowed:
                startScanningIfReady()
            }

        case .power(let next):
            power = next
            if authorization == .denied || authorization == .restricted {
                suspend(availability: .permissionDenied)
                publish(availability: .permissionDenied)
                return
            }
            switch next {
            case .poweredOn:
                startScanningIfReady()
            case .poweredOff:
                suspend(availability: .bluetoothPoweredOff)
                publish(availability: .bluetoothPoweredOff)
            case .unauthorized:
                suspend(availability: .permissionDenied)
                publish(availability: .permissionDenied)
            case .unsupported:
                suspend(availability: .unsupported)
                publish(availability: .unsupported)
            case .unknown, .resetting:
                suspend(availability: .batteryUnavailable)
                publish(availability: .scanning)
            }

        case .discovered(let descriptor):
            guard canRead, !connectedIDs.contains(descriptor.stableIdentifier),
                  !connectingIDs.contains(descriptor.stableIdentifier) else { return }
            descriptors[descriptor.stableIdentifier] = descriptor
            records[descriptor.stableIdentifier] = record(
                descriptor: descriptor,
                availability: .batteryUnavailable,
                parts: [],
                observedAt: Date()
            )
            connectingIDs.insert(descriptor.stableIdentifier)
            client.connect(descriptor.stableIdentifier)
            publish(availability: currentAvailability())

        case .connected(let stableID):
            guard canRead, connectingIDs.remove(stableID) != nil else { return }
            connectedIDs.insert(stableID)
            client.discoverBatteryService(stableID)

        case .services(let stableID, let hasBatteryService):
            guard canRead, connectedIDs.contains(stableID) else { return }
            if hasBatteryService {
                batteryServiceIDs.insert(stableID)
                client.discoverBatteryCharacteristic(stableID)
            } else {
                batteryServiceIDs.remove(stableID)
                readableIDs.remove(stableID)
                setUnavailable(.unsupported, stableID: stableID)
            }

        case .characteristic(let stableID, let hasBatteryLevel):
            guard canRead, connectedIDs.contains(stableID),
                  batteryServiceIDs.contains(stableID) else { return }
            if hasBatteryLevel {
                readableIDs.insert(stableID)
                client.readBatteryLevel(stableID)
            } else {
                readableIDs.remove(stableID)
                setUnavailable(.unsupported, stableID: stableID)
            }

        case .level(let stableID, let data):
            guard canRead, readableIDs.contains(stableID) else { return }
            applyBatteryLevel(data, stableID: stableID)

        case .discoveryFailed(let stableID):
            guard canRead, connectedIDs.contains(stableID) else { return }
            readableIDs.remove(stableID)
            batteryServiceIDs.remove(stableID)
            setUnavailable(.discoveryFailed, stableID: stableID)

        case .disconnected(let stableID), .failed(let stableID):
            guard canRead else { return }
            readableIDs.remove(stableID)
            connectedIDs.remove(stableID)
            connectingIDs.remove(stableID)
            batteryServiceIDs.remove(stableID)
            setUnavailable(.disconnected, stableID: stableID)
        }
    }

    private var canRead: Bool {
        isRunning && authorization == .allowed && power == .poweredOn
    }

    private func suspend(availability: AccessoryPowerAvailability) {
        client.stopScan()
        client.disconnectAll()
        isScanning = false
        scheduler.stop()
        isRefreshScheduled = false
        connectedIDs.removeAll()
        connectingIDs.removeAll()
        batteryServiceIDs.removeAll()
        markAll(availability)
    }

    private func startScanningIfReady() {
        guard authorization == .allowed, power == .poweredOn else { return }
        if !isScanning {
            isScanning = true
            client.scanForBatteryService()
        }
        if !isRefreshScheduled {
            isRefreshScheduled = true
            scheduler.start(interval: Self.refreshInterval) { [weak self] in
                self?.refresh()
            }
        }
        publish(availability: currentAvailability())
    }

    private func applyBatteryLevel(
        _ data: Data?,
        stableID: String
    ) {
        guard let descriptor = descriptors[stableID],
              data?.count == 1,
              let rawLevel = data?.first,
              rawLevel <= 100 else {
            setUnavailable(.batteryUnavailable, stableID: stableID)
            return
        }
        let now = Date()
        let part = AccessoryBatteryPart(
            kind: .main,
            level: Double(rawLevel) / 100,
            chargeState: .unknown,
            observedAt: now
        )
        records[stableID] = record(
            descriptor: descriptor,
            availability: .available,
            parts: [part],
            observedAt: now
        )
        publish(availability: .available)
    }

    private func setUnavailable(
        _ availability: AccessoryPowerAvailability,
        stableID: String
    ) {
        guard let descriptor = descriptors[stableID] else {
            publish(availability: availability)
            return
        }
        records[stableID] = record(
            descriptor: descriptor,
            availability: availability,
            parts: [],
            observedAt: Date()
        )
        publish(availability: currentAvailability())
    }

    private func markAll(_ availability: AccessoryPowerAvailability) {
        for descriptor in descriptors.values {
            records[descriptor.stableIdentifier] = record(
                descriptor: descriptor,
                availability: availability,
                parts: [],
                observedAt: Date()
            )
        }
        readableIDs.removeAll()
    }

    private func record(
        descriptor: BLEPeripheralDescriptor,
        availability: AccessoryPowerAvailability,
        parts: [AccessoryBatteryPart],
        observedAt: Date
    ) -> AccessoryPowerRecord {
        AccessoryPowerRecord(
            identity: AccessoryPowerIdentity(
                source: .standardBLE,
                stableIdentifier: descriptor.stableIdentifier
            ),
            displayName: descriptor.displayName,
            availability: availability,
            parts: parts,
            observedAt: observedAt,
            staleAfter: Self.refreshInterval * 3
        )
    }

    private func currentAvailability() -> AccessoryPowerAvailability {
        if records.values.contains(where: { $0.availability == .available }) {
            return .available
        }
        if records.values.contains(where: { $0.availability == .unsupported }) {
            return .unsupported
        }
        if records.values.contains(where: { $0.availability == .discoveryFailed }) {
            return .discoveryFailed
        }
        if records.values.contains(where: { $0.availability == .disconnected }) {
            return .disconnected
        }
        if isScanning { return .scanning }
        switch authorization {
        case .notDetermined: return .permissionNotDetermined
        case .denied, .restricted: return .permissionDenied
        case .allowed:
            return power == .poweredOff ? .bluetoothPoweredOff : .scanning
        }
    }

    private func publish(availability: AccessoryPowerAvailability) {
        receive?(AccessoryPowerSourceUpdate(
            source: .standardBLE,
            availability: availability,
            records: Array(records.values),
            observedAt: Date()
        ))
    }
}

/// CBCentralManager 延迟到 start 创建（初始化对象本身无权限请求）。系统 delegate
/// 可能晚到，所有回调均核对当前 central/peripheral 对象，stop 清空 delegate 引用。
@MainActor
final class CoreBluetoothCentralClient: NSObject, BLECentralClient {
    var onEvent: (@MainActor (BLECentralEvent) -> Void)?

    private var central: CBCentralManager?
    private var peripherals: [String: CBPeripheral] = [:]
    private var batteryCharacteristics: [String: CBCharacteristic] = [:]

    func start() {
        guard central == nil else { return }
        onEvent?(.authorization(Self.authorization(CBManager.authorization)))
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func scanForBatteryService() {
        central?.scanForPeripherals(
            withServices: [CBUUID(string: StandardBLEBatteryAdapter.batteryServiceUUID)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScan() {
        central?.stopScan()
    }

    func connect(_ stableIdentifier: String) {
        guard let peripheral = peripherals[stableIdentifier] else { return }
        central?.connect(peripheral)
    }

    func discoverBatteryService(_ stableIdentifier: String) {
        peripherals[stableIdentifier]?.discoverServices([
            CBUUID(string: StandardBLEBatteryAdapter.batteryServiceUUID),
        ])
    }

    func discoverBatteryCharacteristic(_ stableIdentifier: String) {
        guard let peripheral = peripherals[stableIdentifier],
              let service = peripheral.services?.first(where: {
                  $0.uuid == CBUUID(
                    string: StandardBLEBatteryAdapter.batteryServiceUUID
                  )
              }) else {
            onEvent?(.services(stableIdentifier, hasBatteryService: false))
            return
        }
        peripheral.discoverCharacteristics([
            CBUUID(string: StandardBLEBatteryAdapter.batteryLevelUUID),
        ], for: service)
    }

    func readBatteryLevel(_ stableIdentifier: String) {
        guard let peripheral = peripherals[stableIdentifier],
              let characteristic = batteryCharacteristics[stableIdentifier] else {
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func disconnectAll() {
        guard let central else { return }
        for peripheral in peripherals.values {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func stop() {
        central?.delegate = nil
        central = nil
        for peripheral in peripherals.values { peripheral.delegate = nil }
        peripherals.removeAll()
        batteryCharacteristics.removeAll()
    }

    private func isCurrent(_ peripheral: CBPeripheral) -> Bool {
        central != nil && peripherals[peripheral.identifier.uuidString] === peripheral
    }

    private static func authorization(
        _ authorization: CBManagerAuthorization
    ) -> BLEAuthorizationState {
        switch authorization {
        case .notDetermined: return .notDetermined
        case .allowedAlways: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }

    private static func power(
        _ state: CBManagerState
    ) -> BLECentralPowerState {
        switch state {
        case .unknown: return .unknown
        case .resetting: return .resetting
        case .unsupported: return .unsupported
        case .unauthorized: return .unauthorized
        case .poweredOff: return .poweredOff
        case .poweredOn: return .poweredOn
        @unknown default: return .unknown
        }
    }
}

extension CoreBluetoothCentralClient: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { return }
        onEvent?(.authorization(Self.authorization(CBManager.authorization)))
        onEvent?(.power(Self.power(central.state)))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard self.central === central else { return }
        let stableID = peripheral.identifier.uuidString
        peripherals[stableID] = peripheral
        peripheral.delegate = self
        onEvent?(.discovered(BLEPeripheralDescriptor(
            stableIdentifier: stableID,
            displayName: peripheral.name
                ?? NSLocalizedString("BLE Battery Device", comment: "")
        )))
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        guard self.central === central, isCurrent(peripheral) else { return }
        onEvent?(.connected(peripheral.identifier.uuidString))
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central, isCurrent(peripheral) else { return }
        batteryCharacteristics.removeValue(forKey: peripheral.identifier.uuidString)
        onEvent?(.failed(peripheral.identifier.uuidString))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central, isCurrent(peripheral) else { return }
        batteryCharacteristics.removeValue(forKey: peripheral.identifier.uuidString)
        onEvent?(.disconnected(peripheral.identifier.uuidString))
    }
}

extension CoreBluetoothCentralClient: @preconcurrency CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard isCurrent(peripheral) else { return }
        let stableID = peripheral.identifier.uuidString
        guard error == nil else {
            batteryCharacteristics.removeValue(forKey: stableID)
            onEvent?(.discoveryFailed(stableID))
            return
        }
        let found = error == nil && peripheral.services?.contains {
            $0.uuid == CBUUID(
                string: StandardBLEBatteryAdapter.batteryServiceUUID
            )
        } == true
        onEvent?(.services(stableID, hasBatteryService: found))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard isCurrent(peripheral),
              service.uuid == CBUUID(string: StandardBLEBatteryAdapter.batteryServiceUUID) else {
            return
        }
        let stableID = peripheral.identifier.uuidString
        guard error == nil else {
            batteryCharacteristics.removeValue(forKey: stableID)
            onEvent?(.discoveryFailed(stableID))
            return
        }
        let characteristic = error == nil
            ? service.characteristics?.first(where: {
                $0.uuid == CBUUID(
                    string: StandardBLEBatteryAdapter.batteryLevelUUID
                )
            })
            : nil
        if let characteristic {
            batteryCharacteristics[stableID] = characteristic
        }
        onEvent?(.characteristic(
            stableID,
            hasBatteryLevel: characteristic != nil
        ))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isCurrent(peripheral),
              batteryCharacteristics[peripheral.identifier.uuidString] === characteristic else {
            return
        }
        onEvent?(.level(
            peripheral.identifier.uuidString,
            error == nil ? characteristic.value : nil
        ))
    }
}
