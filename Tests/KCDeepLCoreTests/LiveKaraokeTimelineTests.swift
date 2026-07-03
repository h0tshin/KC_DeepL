import XCTest
@testable import KCDeepLCore

final class LiveKaraokeTimelineTests: XCTestCase {
    func testCuePlanQueuesOnlyNewSuffixForCumulativeTranscript() {
        let plan = LiveKaraokeTimeline.cuePlan(
            previousText: "Hello world",
            updatedText: "Hello world again",
            currentHighlight: 5
        )

        XCTAssertEqual(plan.preservedHighlight, 5)
        XCTAssertEqual(plan.trackedText, "Hello world again")
        XCTAssertEqual(plan.cue, LiveKaraokeCue(startCharacter: 11, text: " again"))
        XCTAssertFalse(plan.shouldResetQueuedCues)
    }

    func testCuePlanPreservesCompletedPrefixWhenSuffixArrivesLate() {
        let plan = LiveKaraokeTimeline.cuePlan(
            previousText: "Hello world",
            updatedText: "Hello world again",
            currentHighlight: 11
        )

        XCTAssertEqual(plan.preservedHighlight, 11)
        XCTAssertEqual(plan.cue, LiveKaraokeCue(startCharacter: 11, text: " again"))
    }

    func testCuePlanResetsWhenTranscriptIsRewritten() {
        let plan = LiveKaraokeTimeline.cuePlan(
            previousText: "I did this.",
            updatedText: "I do this.",
            currentHighlight: 6
        )

        XCTAssertEqual(plan.preservedHighlight, 3)
        XCTAssertEqual(plan.cue, LiveKaraokeCue(startCharacter: 3, text: "o this."))
        XCTAssertTrue(plan.shouldResetQueuedCues)
    }

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
