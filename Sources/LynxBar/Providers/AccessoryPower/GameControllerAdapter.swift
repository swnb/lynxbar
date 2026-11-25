@preconcurrency import GameController
import Foundation

enum GameControllerBatteryState: Sendable {
    case unknown
    case discharging
    case charging
    case full
}

/// 公开 GCController 的纯映射输入。nil/越界 batteryLevel 无值，isConnected=false 丢弃旧值。
struct GameControllerDescriptor: Sendable {
    let stableIdentifier: String
    let displayName: String
    let batteryLevel: Double?
    let batteryState: GameControllerBatteryState
    let isConnected: Bool
}

/// 仅使用 GCController.controllers()/battery，无蓝牙扫描或私有设备缓存。
/// 采样节奏归聚合所有者；无 demand 时 receive=nil，refresh 不读控制器。
@MainActor
final class GameControllerAdapter: AccessoryPowerAdapter {
    let source: AccessoryPowerSource = .gameController

    private var receive: (@MainActor (AccessoryPowerSourceUpdate) -> Void)?
    private var stableIDs: [ObjectIdentifier: String] = [:]
    // 保留会话对象防止 ObjectIdentifier 被释放后复用；stop 清空，ID 不持久化。
    private var knownControllers: [ObjectIdentifier: GCController] = [:]
    private var previousRecords: [String: AccessoryPowerRecord] = [:]
    private let controllers: @MainActor () -> [GCController]

    init(
        controllers: @escaping @MainActor () -> [GCController] = {
            GCController.controllers()
        }
    ) {
        self.controllers = controllers
    }

    func start(
        receive: @escaping @MainActor (AccessoryPowerSourceUpdate) -> Void
    ) {
        guard self.receive == nil else { return }
        self.receive = receive
        refresh()
    }

    func refresh() {
        guard let receive else { return }
        let now = Date()
        let connected = controllers()
        let descriptors = connected.map { controller in
            let objectID = ObjectIdentifier(controller)
            knownControllers[objectID] = controller
            let stableID = stableIDs[objectID] ?? UUID().uuidString
            stableIDs[objectID] = stableID
            return GameControllerDescriptor(
                stableIdentifier: stableID,
                displayName: controller.vendorName
                    ?? NSLocalizedString("Game Controller", comment: ""),
                batteryLevel: controller.battery.map {
                    Double($0.batteryLevel)
                },
                batteryState: controller.battery.map {
                    Self.state(from: $0.batteryState)
                } ?? .unknown,
                isConnected: true
            )
        }
        let freshRecords = Self.records(from: descriptors, now: now)
        let currentIDs = Set(freshRecords.map { $0.identity.stableIdentifier })
        let disconnected = previousRecords.values
            .filter { !currentIDs.contains($0.identity.stableIdentifier) }
            .map { previous in
                AccessoryPowerRecord(identity: previous.identity,
                    displayName: previous.displayName, availability: .disconnected,
                    parts: [], observedAt: previous.availability == .disconnected
                        ? previous.observedAt : now,
                    staleAfter: previous.staleAfter)
            }
        let records = freshRecords + disconnected
        previousRecords = Dictionary(uniqueKeysWithValues: records.map {
            ($0.identity.stableIdentifier, $0)
        })
        receive(AccessoryPowerSourceUpdate(
            source: source,
            availability: records.contains { $0.availability == .available }
                ? .available
                : .batteryUnavailable,
            records: records,
            observedAt: now
        ))
    }

    func stop() {
        receive = nil
        stableIDs.removeAll()
        knownControllers.removeAll()
        previousRecords.removeAll()
    }

    nonisolated static func records(
        from descriptors: [GameControllerDescriptor],
        now: Date,
        staleAfter: TimeInterval = 15
    ) -> [AccessoryPowerRecord] {
        descriptors.map { descriptor in
            let identity = AccessoryPowerIdentity(
                source: .gameController,
                stableIdentifier: descriptor.stableIdentifier
            )
            guard descriptor.isConnected else {
                return AccessoryPowerRecord(
                    identity: identity,
                    displayName: descriptor.displayName,
                    availability: .disconnected,
                    parts: [],
                    observedAt: now,
                    staleAfter: staleAfter
                )
            }
            guard let level = descriptor.batteryLevel,
                  level.isFinite,
                  (0...1).contains(level) else {
                return AccessoryPowerRecord(
                    identity: identity,
                    displayName: descriptor.displayName,
                    availability: .batteryUnavailable,
                    parts: [],
                    observedAt: now,
                    staleAfter: staleAfter
                )
            }
            return AccessoryPowerRecord(
                identity: identity,
                displayName: descriptor.displayName,
                availability: .available,
                parts: [
                    AccessoryBatteryPart(
                        kind: .main,
                        level: level,
                        chargeState: chargeState(from: descriptor.batteryState),
                        observedAt: now
                    ),
                ],
                observedAt: now,
                staleAfter: staleAfter
            )
        }
    }

    private static func state(
        from state: GCDeviceBattery.State
    ) -> GameControllerBatteryState {
        switch state {
        case .discharging: return .discharging
        case .charging: return .charging
        case .full: return .full
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

    nonisolated private static func chargeState(
        from state: GameControllerBatteryState
    ) -> AccessoryChargeState {
        switch state {
        case .discharging: return .discharging
        case .charging: return .charging
        case .full: return .full
        case .unknown: return .unknown
        }
    }
}
