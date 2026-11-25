import Foundation
import XCTest
@testable import LynxBar

final class RecentSampleWindowTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testDenseToSparseIntervalKeepsAllSamplesInsideSixtySeconds() {
        var window = RecentSampleWindow()

        for second in 0 ... 59 {
            _ = window.append(
                Double(second),
                at: origin.addingTimeInterval(Double(second))
            )
        }

        let values = window.append(69, at: origin.addingTimeInterval(69))

        XCTAssertEqual(values.first, 9)
        XCTAssertEqual(values.last, 69)
        XCTAssertEqual(values.count, 52)
    }

    func testSparseToDenseIntervalDropsOnlySamplesOutsideSixtySeconds() {
        var window = RecentSampleWindow()

        for second in stride(from: 0, through: 50, by: 10) {
            _ = window.append(
                Double(second),
                at: origin.addingTimeInterval(Double(second))
            )
        }

        _ = window.append(51, at: origin.addingTimeInterval(51))
        let values = window.append(61, at: origin.addingTimeInterval(61))

        XCTAssertEqual(values, [10, 20, 30, 40, 50, 51, 61])
    }

    func testSampleOnBoundaryIsRetainedAndOlderSampleIsRemoved() {
        var window = RecentSampleWindow()

        _ = window.append(0, at: origin)
        let onBoundary = window.append(60, at: origin.addingTimeInterval(60))
        let pastBoundary = window.append(60.001, at: origin.addingTimeInterval(60.001))

        XCTAssertEqual(onBoundary, [0, 60])
        XCTAssertEqual(pastBoundary, [60, 60.001])
    }
}
