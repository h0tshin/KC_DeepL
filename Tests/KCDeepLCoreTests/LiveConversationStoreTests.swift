import XCTest
@testable import KCDeepLCore

final class LiveConversationStoreTests: XCTestCase {
    func testFileStoreRoundTripsConversationSnapshot() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KCDeepLLiveConversationTests-\(UUID().uuidString)")
        let fileURL = directoryURL.appendingPathComponent("live.json")
        let store = FileLiveConversationStore(fileURL: fileURL)
        let conversationID = UUID()
        let messageID = UUID()
        let snapshot = LiveConversationSnapshot(
            conversations: [
                LiveConversation(
                    id: conversationID,
                    title: "Teams 회의",
                    messages: [
                        LiveConversationMessage(
                            id: messageID,
                            speaker: .other,
                            originalText: "hello",
                            translatedText: "안녕하세요"
                        )
                    ]
                )
            ],
            selectedConversationID: conversationID
        )

        try store.save(snapshot)
        let loaded = try store.load()

        XCTAssertEqual(loaded.selectedConversationID, conversationID)
        XCTAssertEqual(loaded.conversations.first?.id, conversationID)
        XCTAssertEqual(loaded.conversations.first?.messages.first?.id, messageID)
        XCTAssertEqual(loaded.conversations.first?.messages.first?.speaker, .other)
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func testMissingFileReturnsEmptySnapshot() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
            .appendingPathComponent("live.json")
        let store = FileLiveConversationStore(fileURL: fileURL)

        let snapshot = try store.load()

        XCTAssertTrue(snapshot.conversations.isEmpty)
        XCTAssertNil(snapshot.selectedConversationID)
    }
}
