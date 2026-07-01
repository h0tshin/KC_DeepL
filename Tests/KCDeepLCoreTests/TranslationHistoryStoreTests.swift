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
            modelID: AppDefaults.defaultModelID,
            timestamp: Date(timeIntervalSince1970: 0)
        )

        try store.save([item])

        XCTAssertEqual(try store.load(), [item])
    }

    func testMissingHistoryFileLoadsAsEmptyArray() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KCDeepLCoreTests-\(UUID().uuidString)")
            .appendingPathComponent("missing.json")
        let store = FileTranslationHistoryStore(fileURL: fileURL)

        XCTAssertEqual(try store.load(), [])
    }
}
