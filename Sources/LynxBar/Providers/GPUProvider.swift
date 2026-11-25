import Foundation
import IOKit
import Metal

struct GPUDeviceSnapshot: Identifiable, Sendable, Equatable {
    let id: UInt64
    let name: String
    let hasUnifiedMemory: Bool
    let recommendedMaxWorkingSetBytes: UInt64
}

struct GPUPerformanceSample: Sendable, Equatable {
    let usage: Double?
    let rendererUsage: Double?
    let tilerUsage: Double?
    let driverMemoryBytes: UInt64?
}

enum GPUAvailability: Sendable, Equatable {
    case available
    case noDevice
}

struct GPUSnapshot: Sendable, Equatable {
    var availability: GPUAvailability = .noDevice
    var devices: [GPUDeviceSnapshot] = []
    var usage: Double?
    var rendererUsage: Double?
    var tilerUsage: Double?
    var driverMemoryBytes: UInt64?
}

/// GPU 设备信息来自公开 Metal API；系统级利用率来自 IOAccelerator 的兼容性字段。
///
/// `PerformanceStatistics` 并非 Apple 承诺跨版本稳定的公开监控接口，因此任何
/// 缺失、类型变化或越界值都必须降级为 `nil`，不能把“不知道”显示成 0%。
enum GPUProvider {
    private static let utilizationKeys = [
        "Device Utilization %",
        "GPU Activity(%)",
        "GPU Core Utilization",
    ]

    static func sample() -> GPUSnapshot {
        let devices = MTLCopyAllDevices().map { device in
            GPUDeviceSnapshot(
                id: device.registryID,
                name: device.name,
                hasUnifiedMemory: device.hasUnifiedMemory,
                recommendedMaxWorkingSetBytes: device.recommendedMaxWorkingSetSize
            )
        }
        guard !devices.isEmpty else { return GPUSnapshot() }

        let samples = acceleratorProperties().compactMap(performanceSample(from:))
        let activeSample = samples
            .filter { $0.usage != nil }
            .max { ($0.usage ?? 0) < ($1.usage ?? 0) }
            ?? samples.first

        return GPUSnapshot(
            availability: .available,
            devices: devices,
            usage: activeSample?.usage,
            rendererUsage: activeSample?.rendererUsage,
            tilerUsage: activeSample?.tilerUsage,
            driverMemoryBytes: activeSample?.driverMemoryBytes
        )
    }

    /// 单独保留纯映射入口，便于用不同机型的注册表 fixture 锁定兼容边界。
    static func performanceSample(from properties: [String: Any]) -> GPUPerformanceSample? {
        guard let statistics = properties["PerformanceStatistics"] as? [String: Any] else {
            return nil
        }

        let usage = utilizationKeys.lazy
            .compactMap { normalizedPercent(statistics[$0]) }
            .first
        let renderer = normalizedPercent(statistics["Renderer Utilization %"])
        let tiler = normalizedPercent(statistics["Tiler Utilization %"])
        let memory = unsignedInteger(statistics["In use system memory (driver)"])

        guard usage != nil || renderer != nil || tiler != nil || memory != nil else {
            return nil
        }
        return GPUPerformanceSample(
            usage: usage,
            rendererUsage: renderer,
            tilerUsage: tiler,
            driverMemoryBytes: memory
        )
    }

    private static func acceleratorProperties() -> [[String: Any]] {
        guard let matching = IOServiceMatching("IOAccelerator") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        ) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [[String: Any]] = []
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            var unmanagedProperties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(
                service,
                &unmanagedProperties,
                kCFAllocatorDefault,
                0
            ) == KERN_SUCCESS,
               let properties = unmanagedProperties?.takeRetainedValue()
                    as? [String: Any] {
                result.append(properties)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }

    private static func normalizedPercent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let percent = number.doubleValue
        guard percent.isFinite, (0...100).contains(percent) else { return nil }
        return percent / 100
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let rawValue = number.doubleValue
        guard rawValue.isFinite,
              rawValue >= 0,
              // Double(UInt64.max) 会舍入到 2^64；使用严格小于避免转换陷阱。
              rawValue < Double(UInt64.max) else {
            return nil
        }
        return UInt64(rawValue)
    }
}
