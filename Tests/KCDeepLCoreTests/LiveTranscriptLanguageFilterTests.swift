import XCTest
@testable import KCDeepLCore

final class LiveTranscriptLanguageFilterTests: XCTestCase {
    private let koreanToEnglish = LiveTranscriptLanguageRoute(
        sourceLanguageCode: "ko",
        targetLanguageCode: "en"
    )

    func testAcceptsExpectedSourceLanguage() {
        XCTAssertTrue(
            LiveTranscriptLanguageFilter.accepts(
                field: .original,
                text: "이거 뭐야?",
                languageCode: "ko-KR",
                route: koreanToEnglish
            )
        )
    }

    func testRejectsTargetLanguageAsSourceTranscript() {
        XCTAssertFalse(
            LiveTranscriptLanguageFilter.accepts(
                field: .original,
                text: "What is this?",
                languageCode: "en-US",
                route: koreanToEnglish
            )
        )
    }

    func testRejectsEnglishLookingSourceWithoutLanguageCodeForKoreanRoute() {
        XCTAssertFalse(
            LiveTranscriptLanguageFilter.accepts(
                field: .original,
                text: "The pattern is in the speech bubble.",
                languageCode: nil,
                route: koreanToEnglish
            )
        )
    }

    func testAcceptsLanguageNeutralSourceWithoutLanguageCode() {
        XCTAssertTrue(
            LiveTranscriptLanguageFilter.accepts(
                field: .original,
                text: "4.0",
                languageCode: nil,
                route: koreanToEnglish
            )
        )
    }

    func testAcceptsExpectedTargetLanguage() {
        XCTAssertTrue(
            LiveTranscriptLanguageFilter.accepts(
                field: .translation,
                text: "What is this?",
                languageCode: "en",
                route: koreanToEnglish
            )
        )
    }

    func testRejectsSourceLanguageAsTargetTranscript() {
        XCTAssertFalse(
            LiveTranscriptLanguageFilter.accepts(
                field: .translation,
                text: "이거 뭐야?",
                languageCode: "ko",
                route: koreanToEnglish
            )
        )
    }
}
