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
        XCTAssertEqual(viewModel.history.first?.backend, .codexAppServer)
        XCTAssertNil(viewModel.history.first?.provider)
        XCTAssertEqual(
            viewModel.history.first?.engineSummary,
            "엔진: Codex App Server · 모델: gpt-test"
        )
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
            historyEnabled: true,
            backend: .llmAPI
        )

        XCTAssertEqual(viewModel.translatedText, "API 번역 결과")
        let apiRequests = await apiClient.requestsSnapshot()
        let codexRequests = await codexClient.requestsSnapshot()
        XCTAssertEqual(apiRequests.map(\.modelID), ["gemini-test"])
        XCTAssertEqual(codexRequests.count, 0)
        XCTAssertEqual(viewModel.history.first?.backend, .llmAPI)
        XCTAssertEqual(viewModel.history.first?.provider, .gemini)
        XCTAssertEqual(
            viewModel.history.first?.engineSummary,
            "엔진: Gemini · 모델: gemini-test"
        )
    }

    func testAppleResultIsShownImmediatelyThenLLMResultBecomesActive() async throws {
        let viewModel = TranslationViewModel(
            client: DelayedTranslationClient(),
            historyStore: InMemoryTranslationHistoryStore()
        )
        try await Task.sleep(for: .milliseconds(30))
        viewModel.setSourceText("Translate this")

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
        let pending = try XCTUnwrap(viewModel.pendingAppleTranslation)
        viewModel.reportAppleTranslationResult(
            "Apple 번역 결과",
            generation: pending.generation
        )

        XCTAssertEqual(viewModel.translatedText, "Apple 번역 결과")
        XCTAssertEqual(viewModel.selectedTranslationEngine, .apple)
        XCTAssertTrue(viewModel.isLLMTranslating)

        await request.value

        XCTAssertEqual(viewModel.translatedText, "old result")
        XCTAssertEqual(viewModel.selectedTranslationEngine, .llm)
        XCTAssertEqual(viewModel.appleTranslatedText, "Apple 번역 결과")

        viewModel.selectTranslationEngine(.apple)
        XCTAssertEqual(viewModel.translatedText, "Apple 번역 결과")
    }

    func testLLMCompletionDoesNotKeepLLMWaitingWhileAppleIsStillPending() async throws {
        let viewModel = TranslationViewModel(
            client: DelayedTranslationClient(),
            historyStore: InMemoryTranslationHistoryStore()
        )
        try await Task.sleep(for: .milliseconds(30))
        viewModel.setSourceText("Translate this")

        let request = Task { @MainActor in
            await viewModel.translate(
                sourceLanguage: .english,
                targetLanguage: .korean,
                provider: .gemini,
                modelID: "fast-model",
                apiKey: "test-key",
                temperature: 0.2,
                historyEnabled: false
            )
        }

        try await Task.sleep(for: .milliseconds(30))
        await request.value

        XCTAssertEqual(viewModel.translatedText, "new result")
        XCTAssertFalse(viewModel.isLLMTranslating)
        XCTAssertTrue(viewModel.isAppleTranslating)
        XCTAssertTrue(viewModel.isTranslating)
    }

    func testAppleFailureKeepsWaitingForTheLLMResult() async throws {
        let viewModel = TranslationViewModel(
            client: DelayedTranslationClient(),
            historyStore: InMemoryTranslationHistoryStore()
        )
        try await Task.sleep(for: .milliseconds(30))
        viewModel.setSourceText("Translate this")

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
        let pending = try XCTUnwrap(viewModel.pendingAppleTranslation)
        viewModel.reportAppleTranslationFailure(
            AppleDocumentTranslationError.operatingSystemUnsupported,
            generation: pending.generation
        )

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            viewModel.appleErrorMessage,
            AppleDocumentTranslationError.operatingSystemUnsupported.errorDescription
        )
        XCTAssertTrue(viewModel.isLLMTranslating)
        XCTAssertEqual(viewModel.translatedText, "")

        await request.value

        XCTAssertEqual(viewModel.translatedText, "old result")
        XCTAssertEqual(viewModel.selectedTranslationEngine, .llm)
    }

    func testStaleAppleResponseCannotOverwriteANewRequest() async throws {
        let viewModel = TranslationViewModel(
            client: DelayedTranslationClient(),
            historyStore: InMemoryTranslationHistoryStore()
        )
        try await Task.sleep(for: .milliseconds(30))
        viewModel.setSourceText("first source")

        let firstRequest = Task { @MainActor in
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
        let firstPending = try XCTUnwrap(viewModel.pendingAppleTranslation)

        viewModel.setSourceText("second source")
        let secondRequest = Task { @MainActor in
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

        try await Task.sleep(for: .milliseconds(20))
        viewModel.reportAppleTranslationResult(
            "오래된 Apple 결과",
            generation: firstPending.generation
        )

        await secondRequest.value
        await firstRequest.value

        XCTAssertEqual(viewModel.translatedText, "new result")
        XCTAssertEqual(viewModel.selectedTranslationEngine, .llm)
        XCTAssertEqual(viewModel.appleTranslatedText, "")
    }

    func testComparisonTranslationRecordsCodexEngineMetadata() async throws {
        let viewModel = TranslationViewModel(
            client: RecordingTranslationClient(output: ""),
            historyStore: InMemoryTranslationHistoryStore()
        )
        try await Task.sleep(for: .milliseconds(30))
        viewModel.setHistoryEnabled(true)

        viewModel.recordComparisonTranslation(
            CompletedComparisonTranslation(
                sourceText: "Complete source",
                translatedText: "전체 번역",
                sourceLanguage: .english,
                targetLanguage: .korean,
                modelID: "gpt-5.6-sol"
            )
        )

        XCTAssertEqual(viewModel.history.count, 1)
        XCTAssertEqual(viewModel.history.first?.sourceText, "Complete source")
        XCTAssertEqual(viewModel.history.first?.translatedText, "전체 번역")
        XCTAssertEqual(viewModel.history.first?.backend, .codexAppServer)
        XCTAssertEqual(
            viewModel.history.first?.engineSummary,
            "엔진: Codex App Server · 모델: gpt-5.6-sol"
        )
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
