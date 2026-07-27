import XCTest
@testable import KCDeepLCore

final class TranslationHistoryStoreTests: XCTestCase {
    func testFileStoreRoundTripsHistoryItems() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KCDeepLCoreTests-\(UUID().uuidString)")
            .appendingPathComponent("history.json")
        let store = FileTranslationHistoryStore(fileURL: fileURL)
        let item = TranslationHistoryItem(
            sourceText: "**Hello**",
            translatedText: "**안녕하세요**",
            sourceLanguage: .english,
            targetLanguage: .korean,
            backend: .codexAppServer,
            provider: nil,
            modelID: AppDefaults.defaultModelID,
            timestamp: Date(timeIntervalSince1970: 0)
        )

        try store.save([item])

        let loadedItems = try store.load()

        XCTAssertEqual(loadedItems, [item])
        XCTAssertEqual(
            loadedItems.first?.engineSummary,
            "엔진: Codex App Server · 모델: \(AppDefaults.defaultModelID)"
        )
    }

    func testMissingHistoryFileLoadsAsEmptyArray() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KCDeepLCoreTests-\(UUID().uuidString)")
            .appendingPathComponent("missing.json")
        let store = FileTranslationHistoryStore(fileURL: fileURL)

        XCTAssertEqual(try store.load(), [])
    }

    func testLoadsLegacyHistoryWithoutBackendAndProvider() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KCDeepLCoreTests-\(UUID().uuidString)")
            .appendingPathComponent("history.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyJSON = """
        [
          {
            "id": "8A3ACAA8-1D73-4C2B-B4E8-F40C03F19595",
            "sourceText": "Hello",
            "translatedText": "안녕하세요",
            "sourceLanguage": {
              "code": "en",
              "displayName": "영어"
            },
            "targetLanguage": {
              "code": "ko",
              "displayName": "한국어"
            },
            "modelID": "gemini-2.5-flash-lite",
            "timestamp": "1970-01-01T00:00:00Z"
          }
        ]
        """
        try XCTUnwrap(legacyJSON.data(using: .utf8)).write(to: fileURL)

        let loadedItem = try XCTUnwrap(FileTranslationHistoryStore(fileURL: fileURL).load().first)

        XCTAssertNil(loadedItem.backend)
        XCTAssertNil(loadedItem.provider)
        XCTAssertEqual(
            loadedItem.engineSummary,
            "엔진: 정보 없음 · 모델: gemini-2.5-flash-lite"
        )
    }

    func testLLMAPIEngineSummaryUsesProviderName() {
        let item = TranslationHistoryItem(
            sourceText: "Hello",
            translatedText: "안녕하세요",
            sourceLanguage: .english,
            targetLanguage: .korean,
            backend: .llmAPI,
            provider: .gemini,
            modelID: "gemini-2.5-flash"
        )

        XCTAssertEqual(
            item.engineSummary,
            "엔진: Gemini · 모델: gemini-2.5-flash"
        )
    }
}
