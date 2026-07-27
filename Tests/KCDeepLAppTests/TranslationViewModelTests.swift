import Foundation
import XCTest
@testable import KCDeepL
import KCDeepLCore

@MainActor
final class TranslationViewModelTests: XCTestCase {
    func testCodexBackendUsesAppServerWithoutAPIKeyAndUpdatesExistingResultFlow() async throws {
        let apiClient = RecordingTranslationClient(output: "unexpected API result")
        let codexClient = RecordingTranslationClient(output: "Codex 번역 결과")
        let historyStore = InMemoryTranslationHistoryStore()
        let viewModel = TranslationViewModel(
            client: apiClient,
            appServerClient: codexClient,
            historyStore: historyStore
        )
        try await Task.sleep(for: .milliseconds(30))
        viewModel.setSourceText("Translate this")

        await viewModel.translate(
            sourceLanguage: .english,
            targetLanguage: .korean,
            provider: .gemini,
            modelID: "gpt-test",
            apiKey: "",
            temperature: 0.2,
            historyEnabled: true,
            backend: .codexAppServer
        )

        XCTAssertEqual(viewModel.translatedText, "Codex 번역 결과")
        let apiRequests = await apiClient.requestsSnapshot()
        let codexRequests = await codexClient.requestsSnapshot()
        XCTAssertEqual(apiRequests.count, 0)
        XCTAssertEqual(codexRequests.map(\.modelID), ["gpt-test"])
        XCTAssertEqual(codexRequests.map(\.apiKey), [""])
        XCTAssertEqual(viewModel.history.map(\.translatedText), ["Codex 번역 결과"])
    }

    func testLLMAPIBackendContinuesToUseAPIClient() async throws {
        let apiClient = RecordingTranslationClient(output: "API 번역 결과")
        let codexClient = RecordingTranslationClient(output: "unexpected Codex result")
        let viewModel = TranslationViewModel(
            client: apiClient,
            appServerClient: codexClient,
            historyStore: InMemoryTranslationHistoryStore()
        )
        try await Task.sleep(for: .milliseconds(30))
        viewModel.setSourceText("Translate this")

        await viewModel.translate(
            sourceLanguage: .english,
            targetLanguage: .korean,
            provider: .gemini,
            modelID: "gemini-test",
            apiKey: "test-key",
            temperature: 0.2,
            historyEnabled: false,
            backend: .llmAPI
        )

        XCTAssertEqual(viewModel.translatedText, "API 번역 결과")
        let apiRequests = await apiClient.requestsSnapshot()
        let codexRequests = await codexClient.requestsSnapshot()
        XCTAssertEqual(apiRequests.map(\.modelID), ["gemini-test"])
        XCTAssertEqual(codexRequests.count, 0)
    }

    func testOlderRequestCannotOverwriteNewerConfigurationResult() async throws {
        let historyStore = InMemoryTranslationHistoryStore()
        let viewModel = TranslationViewModel(
            client: DelayedTranslationClient(),
            historyStore: historyStore
        )
        try await Task.sleep(for: .milliseconds(30))
        viewModel.setSourceText("same source")

        let oldRequest = Task { @MainActor in
            await viewModel.translate(
                sourceLanguage: .english,
                targetLanguage: .korean,
                provider: .gemini,
                modelID: "slow-model",
                apiKey: "test-key",
                temperature: 0.2,
                historyEnabled: true
            )
        }
        try await Task.sleep(for: .milliseconds(15))
        let newRequest = Task { @MainActor in
            await viewModel.translate(
                sourceLanguage: .english,
                targetLanguage: .korean,
                provider: .gemini,
                modelID: "fast-model",
                apiKey: "test-key",
                temperature: 0.2,
                historyEnabled: true
            )
        }

        await newRequest.value
        await oldRequest.value
        try await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(viewModel.translatedText, "new result")
        XCTAssertEqual(viewModel.history.map(\.modelID), ["fast-model"])
        XCTAssertEqual(historyStore.snapshot().map(\.modelID), ["fast-model"])
    }

    func testHistoryLoadedDuringTranslationIsMergedInsteadOfOverwritingLocalResult() async throws {
        let existingItem = TranslationHistoryItem(
            sourceText: "existing",
            translatedText: "기존",
            sourceLanguage: .english,
            targetLanguage: .korean,
            modelID: "existing-model"
        )
        let historyStore = InMemoryTranslationHistoryStore(
            items: [existingItem],
            loadDelay: 0.15
        )
        let viewModel = TranslationViewModel(
            client: DelayedTranslationClient(),
            historyStore: historyStore
        )
        viewModel.setSourceText("new source")

        await viewModel.translate(
            sourceLanguage: .english,
            targetLanguage: .korean,
            provider: .gemini,
            modelID: "fast-model",
            apiKey: "test-key",
            temperature: 0.2,
            historyEnabled: true
        )
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(Set(viewModel.history.map(\.modelID)), ["existing-model", "fast-model"])
        XCTAssertEqual(Set(historyStore.snapshot().map(\.modelID)), ["existing-model", "fast-model"])
    }

    func testDisablingHistoryDuringRequestPreventsPersistence() async throws {
        let historyStore = InMemoryTranslationHistoryStore()
        let viewModel = TranslationViewModel(
            client: DelayedTranslationClient(),
            historyStore: historyStore
        )
        try await Task.sleep(for: .milliseconds(30))
        viewModel.setSourceText("private source")

        let request = Task { @MainActor in
            await viewModel.translate(
                sourceLanguage: .english,
                targetLanguage: .korean,
                provider: .gemini,
                modelID: "slow-model",
                apiKey: "test-key",
                temperature: 0.2,
                historyEnabled: true
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        viewModel.setHistoryEnabled(false)
        await request.value
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(viewModel.translatedText, "old result")
        XCTAssertTrue(viewModel.history.isEmpty)
        XCTAssertTrue(historyStore.snapshot().isEmpty)
    }

    func testTerminationFlushWaitsForInitialLoadBeforeSavingMergedHistory() async throws {
        let existingItem = TranslationHistoryItem(
            sourceText: "existing",
            translatedText: "기존",
            sourceLanguage: .english,
            targetLanguage: .korean,
            modelID: "existing-model"
        )
        let historyStore = InMemoryTranslationHistoryStore(
            items: [existingItem],
            loadDelay: 0.2
        )
        let viewModel = TranslationViewModel(
            client: DelayedTranslationClient(),
            historyStore: historyStore
        )
        viewModel.setSourceText("new source")

        await viewModel.translate(
            sourceLanguage: .english,
            targetLanguage: .korean,
            provider: .gemini,
            modelID: "fast-model",
            apiKey: "test-key",
            temperature: 0.2,
            historyEnabled: true
        )
        await PendingPersistenceRegistry.shared.flushAll()

        XCTAssertEqual(Set(historyStore.snapshot().map(\.modelID)), ["existing-model", "fast-model"])
    }
}

private actor RecordingTranslationClient: TranslationClient {
    private let output: String
    private var requests: [TranslationRequest] = []

    init(output: String) {
        self.output = output
    }

    func translate(_ request: TranslationRequest) async throws -> String {
        requests.append(request)
        return output
    }

    func requestsSnapshot() -> [TranslationRequest] {
        requests
    }
}

private final class DelayedTranslationClient: TranslationClient, @unchecked Sendable {
    func translate(_ request: TranslationRequest) async throws -> String {
        if request.modelID == "slow-model" {
            try? await Task.sleep(for: .milliseconds(180))
            return "old result"
        }
        try? await Task.sleep(for: .milliseconds(10))
        return "new result"
    }
}

private final class InMemoryTranslationHistoryStore: TranslationHistoryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let loadDelay: TimeInterval
    private var items: [TranslationHistoryItem]

    init(items: [TranslationHistoryItem] = [], loadDelay: TimeInterval = 0) {
        self.items = items
        self.loadDelay = loadDelay
    }

    func load() throws -> [TranslationHistoryItem] {
        if loadDelay > 0 {
            Thread.sleep(forTimeInterval: loadDelay)
        }
        return snapshot()
    }

    func save(_ items: [TranslationHistoryItem]) throws {
        lock.lock()
        self.items = items
        lock.unlock()
    }

    func snapshot() -> [TranslationHistoryItem] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
