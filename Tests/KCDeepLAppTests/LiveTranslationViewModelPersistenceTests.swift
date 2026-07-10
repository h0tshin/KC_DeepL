import Foundation
import XCTest
@testable import KCDeepL
import KCDeepLCore

@MainActor
final class LiveTranslationViewModelPersistenceTests: XCTestCase {
    func testLiveAudioSettingsReadCredentialsFromUserDefaults() throws {
        let suiteName = "LiveTranslationAudioSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("listening-key", forKey: PreferenceKeys.liveListeningAPIKey)
        defaults.set("speaking-key", forKey: PreferenceKeys.liveSpeakingAPIKey)

        let settings = LiveTranslationAudioSettings.fromDefaults(defaults)

        XCTAssertEqual(settings.listeningCredential, "listening-key")
        XCTAssertEqual(settings.speakingCredential, "speaking-key")
    }

    func testPendingTitleSaveSurvivesViewModelDeinitialization() async throws {
        let conversation = LiveConversation(title: "Original")
        let store = InMemoryLiveConversationStore(
            snapshot: LiveConversationSnapshot(
                conversations: [conversation],
                selectedConversationID: conversation.id
            )
        )
        var viewModel: LiveTranslationViewModel? = LiveTranslationViewModel(
            store: store
        )
        try await Task.sleep(for: .milliseconds(50))

        viewModel?.updateSelectedTitle("Updated")
        weak let releasedViewModel = viewModel
        viewModel = nil
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertNil(releasedViewModel)
        XCTAssertEqual(store.currentSnapshot().conversations.first?.title, "Updated")
    }

    func testTerminationFlushWaitsForInitialLoadBeforeSavingMergedConversations() async throws {
        let existingConversation = LiveConversation(title: "Existing")
        let store = InMemoryLiveConversationStore(
            snapshot: LiveConversationSnapshot(
                conversations: [existingConversation],
                selectedConversationID: existingConversation.id
            ),
            loadDelay: 0.2
        )
        let viewModel = LiveTranslationViewModel(
            store: store
        )

        viewModel.newConversation()
        await PendingPersistenceRegistry.shared.flushAll()

        let titles = Set(store.currentSnapshot().conversations.map(\.title))
        XCTAssertEqual(titles, ["Existing", "새 대화 1"])
    }
}

private final class InMemoryLiveConversationStore: LiveConversationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let loadDelay: TimeInterval
    private var snapshot: LiveConversationSnapshot

    init(snapshot: LiveConversationSnapshot, loadDelay: TimeInterval = 0) {
        self.snapshot = snapshot
        self.loadDelay = loadDelay
    }

    func load() throws -> LiveConversationSnapshot {
        let loadedSnapshot = currentSnapshot()
        if loadDelay > 0 {
            Thread.sleep(forTimeInterval: loadDelay)
        }
        return loadedSnapshot
    }

    func save(_ snapshot: LiveConversationSnapshot) throws {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    func currentSnapshot() -> LiveConversationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}
