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

    func testDoesNotSplitDecimalNumbers() {
        let split = LiveConversationSegmenter.splitCompletedSegments(
            in: "We need version 4.0 today. Next"
        )

        XCTAssertEqual(split.completedSegments, ["We need version 4.0 today."])
        XCTAssertEqual(split.remainder, "Next")
    }

    func testKeepsDecimalInsideKoreanSentence() {
        let split = LiveConversationSegmenter.splitCompletedSegments(
            in: "버전 4.0입니다 다음"
        )

        XCTAssertEqual(split.completedSegments, ["버전 4.0입니다"])
        XCTAssertEqual(split.remainder, "다음")
    }

    func testDoesNotTreatImInsideGameAsSentenceEnding() {
        let text = "그는 게임 아이템을 샀다"
        let split = LiveConversationSegmenter.splitCompletedSegments(in: text)

        XCTAssertTrue(split.completedSegments.isEmpty)
        XCTAssertEqual(split.remainder, text)
    }

    func testKeepsTrailingImAsAnUnambiguousEnding() {
        let split = LiveConversationSegmenter.splitCompletedSegments(in: "오늘 휴무임")

        XCTAssertEqual(split.completedSegments, ["오늘 휴무임"])
        XCTAssertEqual(split.remainder, "")
    }

    func testIncludesClosingQuoteInCompletedSegment() {
        let split = LiveConversationSegmenter.splitCompletedSegments(
            in: "그가 \"확인했습니다\" 다음"
        )

        XCTAssertEqual(split.completedSegments, ["그가 \"확인했습니다\""])
        XCTAssertEqual(split.remainder, "다음")
    }

    func testDoesNotSplitCommonTitleAbbreviation() {
        let split = LiveConversationSegmenter.splitCompletedSegments(
            in: "Mr. Smith arrived. Next"
        )

        XCTAssertEqual(split.completedSegments, ["Mr. Smith arrived."])
        XCTAssertEqual(split.remainder, "Next")
    }

    func testHandlesLargeUnpunctuatedTranscript() {
        let text = String(repeating: "가", count: 50_000)
        let split = LiveConversationSegmenter.splitCompletedSegments(in: text)

        XCTAssertTrue(split.completedSegments.isEmpty)
        XCTAssertEqual(split.remainder, text)
    }
}
