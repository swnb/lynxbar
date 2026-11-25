import XCTest
@testable import LynxBar

final class GPUProviderTests: XCTestCase {
    func testPerformanceStatisticsNormalizeRecognizedPercentages() throws {
        let sample = try XCTUnwrap(GPUProvider.performanceSample(from: [
            "PerformanceStatistics": [
                "Device Utilization %": 69,
                "Renderer Utilization %": 67.5,
                "Tiler Utilization %": 12,
                "In use system memory (driver)": 1_048_576,
            ],
        ]))

        XCTAssertEqual(try XCTUnwrap(sample.usage), 0.69, accuracy: 0.000_1)
        XCTAssertEqual(try XCTUnwrap(sample.rendererUsage), 0.675, accuracy: 0.000_1)
        XCTAssertEqual(try XCTUnwrap(sample.tilerUsage), 0.12, accuracy: 0.000_1)
        XCTAssertEqual(sample.driverMemoryBytes, 1_048_576)
    }

    func testPerformanceStatisticsAcceptValidZero() throws {
        let sample = try XCTUnwrap(GPUProvider.performanceSample(from: [
            "PerformanceStatistics": ["Device Utilization %": 0],
        ]))

        XCTAssertEqual(sample.usage, 0)
    }

    func testPerformanceStatisticsRejectInvalidAndUnknownValues() {
        XCTAssertNil(GPUProvider.performanceSample(from: [
            "PerformanceStatistics": [
                "Device Utilization %": 101,
                "Renderer Utilization %": -1,
                "Tiler Utilization %": Double.nan,
                "In use system memory (driver)": Double(UInt64.max),
            ],
        ]))
        XCTAssertNil(GPUProvider.performanceSample(from: [
            "PerformanceStatistics": [
                "In use system memory (driver)": -50,
            ],
        ]))
        XCTAssertNil(GPUProvider.performanceSample(from: [
            "PerformanceStatistics": ["Some Future Key": 42],
        ]))
        XCTAssertNil(GPUProvider.performanceSample(from: [:]))
    }
}
