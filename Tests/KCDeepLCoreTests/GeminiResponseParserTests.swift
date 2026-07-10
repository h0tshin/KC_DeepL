import XCTest
@testable import KCDeepLCore

final class GeminiResponseParserTests: XCTestCase {
    func testExtractsTextFromInteractionsResponse() throws {
        let json = #"{"output_text":"안녕하세요"}"#.data(using: .utf8)!

        let text = try GeminiResponseParser.extractText(from: json)

        XCTAssertEqual(text, "안녕하세요")
    }

    func testExtractsTextFromGenerateContentResponse() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "번역 결과" }
                ]
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let text = try GeminiResponseParser.extractText(from: json)

        XCTAssertEqual(text, "번역 결과")
    }

    func testThrowsForEmptyResponse() {
        let json = #"{"candidates":[]}"#.data(using: .utf8)!

        XCTAssertThrowsError(try GeminiResponseParser.extractText(from: json)) { error in
            XCTAssertEqual(error as? TranslationClientError, .emptyResponse)
        }
    }

    func testRejectsTruncatedCandidateEvenWhenPartialTextExists() {
        let json = """
        {
          "candidates": [
            {
              "content": { "parts": [{ "text": "부분 번역" }] },
              "finishReason": "MAX_TOKENS"
            }
          ]
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try GeminiResponseParser.extractText(from: json)) { error in
            XCTAssertEqual(error as? TranslationClientError, .responseTruncated)
        }
    }

    func testRejectsCandidateBlockedForSafety() {
        let json = """
        {
          "candidates": [
            { "finishReason": "SAFETY" }
          ]
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try GeminiResponseParser.extractText(from: json)) { error in
            XCTAssertEqual(error as? TranslationClientError, .responseBlocked("SAFETY"))
        }
    }

    func testRejectsPromptFeedbackBlockReason() {
        let json = """
        {
          "promptFeedback": {
            "blockReason": "PROHIBITED_CONTENT"
          }
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try GeminiResponseParser.extractText(from: json)) { error in
            XCTAssertEqual(
                error as? TranslationClientError,
                .responseBlocked("PROHIBITED_CONTENT")
            )
        }
    }
}
