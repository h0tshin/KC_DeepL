import XCTest
@testable import KCDeepLCore

final class LiveConversationSegmenterTests: XCTestCase {
    func testSplitsPhysicalTerminators() {
        let split = LiveConversationSegmenter.splitCompletedSegments(
            in: "확인했습니다. 다음에 얘기해요... 아직"
        )

        XCTAssertEqual(split.completedSegments, ["확인했습니다.", "다음에 얘기해요..."])
        XCTAssertEqual(split.remainder, "아직")
    }

    func testSplitsPoliteKoreanEndings() {
        let split = LiveConversationSegmenter.splitCompletedSegments(
            in: "확인했습니다 좋은 생각이네요 내일 뵙지요 진행 중"
        )

        XCTAssertEqual(split.completedSegments, ["확인했습니다", "좋은 생각이네요", "내일 뵙지요"])
        XCTAssertEqual(split.remainder, "진행 중")
    }

    func testKeepsWeakTrailingEndingUntilSeparatorArrives() {
        let split = LiveConversationSegmenter.splitCompletedSegments(in: "좋아")

        XCTAssertTrue(split.completedSegments.isEmpty)
        XCTAssertEqual(split.remainder, "좋아")
    }

    func testSplitsWeakEndingWithSeparator() {
        let split = LiveConversationSegmenter.splitCompletedSegments(in: "알았어 다음")

        XCTAssertEqual(split.completedSegments, ["알았어"])
        XCTAssertEqual(split.remainder, "다음")
    }
}
