import XCTest
@testable import KCDeepLCore

final class LiveKaraokeTimelineTests: XCTestCase {
    func testHighlightsCharactersByElapsedAudioRatio() {
        XCTAssertEqual(
            LiveKaraokeTimeline.highlightedCharacters(
                in: "abcdefghij",
                elapsedDuration: 1.0,
                totalDuration: 2.0
            ),
            5
        )
    }

    func testClampsHighlightToTextLength() {
        XCTAssertEqual(
            LiveKaraokeTimeline.highlightedCharacters(
                in: "abc",
                elapsedDuration: 3.0,
                totalDuration: 1.0
            ),
            3
        )
    }

    func testEstimatesEnglishSpeechFasterThanKoreanForSameCharacterCount() {
        let englishDuration = LiveKaraokeTimeline.estimatedSpeechDuration(for: "abcdefghij")
        let koreanDuration = LiveKaraokeTimeline.estimatedSpeechDuration(for: "가나다라마바사아자차")

        XCTAssertLessThan(englishDuration, koreanDuration)
    }
}
