import XCTest
@testable import KCDeepLCore

final class ReadingFontSizeTests: XCTestCase {
    func testIncreasingAndDecreasingMovesBetweenSupportedSizes() {
        let size28 = ReadingFontSize.resolved("28")

        XCTAssertEqual(size28.increased.points, 30)
        XCTAssertEqual(size28.decreased.points, 26)
    }

    func testAdjustmentsClampAtSupportedBounds() {
        let minimum = ReadingFontSize.resolved("16")
        let maximum = ReadingFontSize.resolved("40")

        XCTAssertEqual(minimum.decreased, minimum)
        XCTAssertFalse(minimum.canDecrease)
        XCTAssertEqual(maximum.increased, maximum)
        XCTAssertFalse(maximum.canIncrease)
    }

    func testInvalidAndLegacyStoredValuesResolveSafely() {
        XCTAssertEqual(ReadingFontSize.resolved("unsupported"), .defaultValue)
        XCTAssertEqual(ReadingFontSize.resolved("regular").points, 22)
        XCTAssertEqual(ReadingFontSize.resolved("large").points, 28)
        XCTAssertEqual(ReadingFontSize.resolved("extraLarge").points, 34)
    }

    func testSupportedRangeUsesTwoPointSteps() {
        XCTAssertEqual(
            ReadingFontSize.allCases.map(\.points),
            Array(stride(from: 16, through: 40, by: 2))
        )
    }
}
