import AppKit
import KCDeepLCore

@MainActor
final class TranslationViewModel: ObservableObject {
    @Published var sourceText = ""
    @Published var sourceAttributedText = RichTextFormatting.plainAttributedString("")
    @Published var translatedText = ""
    @Published var isTranslating = false
    @Published var statusMessage = "시스템과 API 상태를 확인하는 중입니다."
    @Published var errorMessage: String?
    @Published var captureState: CaptureState?
    @Published private(set) var history: [TranslationHistoryItem] = []

    private let apiClient: TranslationClient
    private let appServerClient: TranslationClient
    private let historyRepository: TranslationHistoryRepository
    private var debouncedTranslationTask: Task<Void, Never>?
    private var activeTranslationTask: Task<Void, Never>?
    private var historyLoadTask: Task<Void, Never>?
    private var historyPersistenceTask: Task<Void, Never>?
    private var historyPersistenceGeneration: UInt = 0
    private var isHistoryLoaded = false
    private var historyMutatedBeforeLoad = false
    private var historyClearedBeforeLoad = false
    private var historyDeletedBeforeLoad: Set<TranslationHistoryItem.ID> = []
    private var historyNeedsPersistence = false
    private var historyPreferenceEnabled = true
    private var requestGeneration: UInt = 0

    init(
        client: TranslationClient = GeminiTranslationClient(),
        appServerClient: TranslationClient? = nil,
        historyStore: TranslationHistoryStoring = FileTranslationHistoryStore()
    ) {
        self.apiClient = client
        self.appServerClient = appServerClient ?? client
        self.historyRepository = TranslationHistoryRepository(store: historyStore)
        loadHistory()
        PendingPersistenceRegistry.shared.registerPreparation { [weak self] in
            self?.prepareForTermination()
        }
        PendingPersistenceRegistry.shared.register { [weak self] in
            await self?.flushPendingHistoryPersistence()
        }
    }

    deinit {
        debouncedTranslationTask?.cancel()
        activeTranslationTask?.cancel()
        historyLoadTask?.cancel()
    }

    func translate(
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        provider: LLMProvider,
        modelID: String,
        apiKey: String,
        temperature: Double,
        historyEnabled: Bool,
        backend: TranslationBackend = .llmAPI
    ) async {
        historyPreferenceEnabled = historyEnabled
        let generation = nextRequestGeneration()
        let translationText = RichTextFormatting.markdown(
            from: sourceAttributedText,
            fallback: sourceText
        )
        let expectedSourceText = sourceText
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.translateSnapshot(
                translationText,
                expectedSourceText: expectedSourceText,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                provider: provider,
                modelID: modelID,
                apiKey: apiKey,
                temperature: temperature,
                historyEnabled: historyEnabled,
                backend: backend,
                generation: generation
            )
        }
        activeTranslationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if requestGeneration == generation {
            activeTranslationTask = nil
        }
    }

    func scheduleAutoTranslation(
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        provider: LLMProvider,
        modelID: String,
        apiKey: String,
        temperature: Double,
        historyEnabled: Bool,
        autoTranslate: Bool,
        backend: TranslationBackend = .llmAPI
    ) {
        historyPreferenceEnabled = historyEnabled
        let generation = nextRequestGeneration()
        isTranslating = false

        let expectedSourceText = sourceText
        guard !expectedSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translatedText = ""
            errorMessage = nil
            runStartupChecks(
                backend: backend,
                modelID: modelID,
                apiKey: apiKey
            )
            return
        }

        guard autoTranslate else {
            statusMessage = "자동 번역이 꺼져 있습니다."
            return
        }

        statusMessage = "입력 중입니다. 1초 후 자동 번역합니다."

        debouncedTranslationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }

            guard let self,
                  self.isCurrentRequest(generation, expectedSourceText: expectedSourceText)
            else {
                return
            }
            let pendingText = RichTextFormatting.markdown(
                from: self.sourceAttributedText,
                fallback: expectedSourceText
            )
            await self.translateSnapshot(
                pendingText,
                expectedSourceText: expectedSourceText,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                provider: provider,
                modelID: modelID,
                apiKey: apiKey,
                temperature: temperature,
                historyEnabled: historyEnabled,
                backend: backend,
                generation: generation
            )
        }
    }

    func runStartupChecks(apiKey: String) {
        let defaults = UserDefaults.standard
        let backend = TranslationBackend(
            rawValue: defaults.string(forKey: PreferenceKeys.translationBackend) ?? ""
        ) ?? AppDefaults.defaultTranslationBackend
        let provider = LLMProvider(rawValue: defaults.string(forKey: PreferenceKeys.provider) ?? "") ?? .gemini
        let modelID = backend == .codexAppServer
            ? defaults.string(forKey: PreferenceKeys.codexModelID) ?? AppDefaults.defaultCodexModelID
            : defaults.string(forKey: PreferenceKeys.modelID) ?? AppDefaults.defaultModelID

        runStartupChecks(
            backend: backend,
            provider: provider,
            modelID: modelID,
            apiKey: apiKey
        )
    }

    func runStartupChecks(
        backend: TranslationBackend,
        modelID: String,
        apiKey: String
    ) {
        let defaults = UserDefaults.standard
        let provider = LLMProvider(
            rawValue: defaults.string(forKey: PreferenceKeys.provider) ?? ""
        ) ?? .gemini
        runStartupChecks(
            backend: backend,
            provider: provider,
            modelID: modelID,
            apiKey: apiKey
        )
    }

    private func runStartupChecks(
        backend: TranslationBackend,
        provider: LLMProvider,
        modelID: String,
        apiKey: String
    ) {
        if backend == .llmAPI,
           provider == .gemini,
           apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusMessage = "Gemini API 키를 설정해 주세요."
        } else if modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusMessage = "번역 모델을 선택해 주세요."
        } else if backend == .codexAppServer {
            statusMessage = "Codex App Server로 번역할 준비가 되었습니다."
        } else {
            statusMessage = "사용할 준비가 되었습니다."
        }
    }

    private func translateSnapshot(
        _ text: String,
        expectedSourceText: String,
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        provider: LLMProvider,
        modelID: String,
        apiKey: String,
        temperature: Double,
        historyEnabled: Bool,
        backend: TranslationBackend,
        generation: UInt
    ) async {
        guard isCurrentRequest(generation, expectedSourceText: expectedSourceText) else {
            return
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translatedText = ""
            errorMessage = nil
            runStartupChecks(
                backend: backend,
                modelID: modelID,
                apiKey: apiKey
            )
            return
        }

        guard backend == .codexAppServer || provider == .gemini else {
            errorMessage = nil
            isTranslating = false
            translatedText = "현재 목업에서는 Gemini 번역 호출만 연결되어 있습니다. \(provider.displayName) 연동은 고급 설정 설계 범위에 포함되어 있습니다."
            statusMessage = "선택한 공급자의 실제 호출은 다음 구현 단계에서 연결됩니다."
            return
        }

        isTranslating = true
        errorMessage = nil
        statusMessage = backend == .codexAppServer
            ? "Codex App Server (\(modelID))로 번역 중입니다."
            : "\(modelID)로 번역 중입니다."

        let request = TranslationRequest(
            sourceText: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            provider: provider,
            modelID: modelID,
            apiKey: apiKey,
            temperature: temperature
        )

        do {
            let selectedClient = backend == .codexAppServer
                ? appServerClient
                : apiClient
            let output = try await selectedClient.translate(request)
            guard isCurrentRequest(generation, expectedSourceText: expectedSourceText),
                  !Task.isCancelled
            else {
                return
            }

            translatedText = output
            statusMessage = "번역 완료: \(modelID)"

            if historyPreferenceEnabled {
                appendHistoryItem(
                    TranslationHistoryItem(
                        sourceText: text,
                        translatedText: output,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        backend: backend,
                        provider: backend == .llmAPI ? provider : nil,
                        modelID: modelID
                    )
                )
            }
        } catch is CancellationError {
            if isCurrentRequest(generation, expectedSourceText: expectedSourceText) {
                statusMessage = "입력 중입니다. 1초 후 자동 번역합니다."
            }
        } catch {
            guard isCurrentRequest(generation, expectedSourceText: expectedSourceText) else {
                return
            }

            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            statusMessage = "번역 실패"
        }

        if isCurrentRequest(generation, expectedSourceText: expectedSourceText) {
            isTranslating = false
        }
    }

    private func nextRequestGeneration() -> UInt {
        debouncedTranslationTask?.cancel()
        debouncedTranslationTask = nil
        activeTranslationTask?.cancel()
        activeTranslationTask = nil
        requestGeneration &+= 1
        return requestGeneration
    }

    private func prepareForTermination() {
        debouncedTranslationTask?.cancel()
        debouncedTranslationTask = nil
        activeTranslationTask?.cancel()
        activeTranslationTask = nil
        requestGeneration &+= 1
        isTranslating = false
    }

    private func isCurrentRequest(_ generation: UInt, expectedSourceText: String) -> Bool {
        generation == requestGeneration && sourceText == expectedSourceText
    }

    func setSourceText(_ text: String) {
        sourceText = text
        sourceAttributedText = RichTextFormatting.plainAttributedString(text)
    }

    func setSourceAttributedText(_ attributedText: NSAttributedString) {
        let normalized = RichTextFormatting.normalize(attributedText)
        sourceText = normalized.string
        sourceAttributedText = normalized
    }

    func appendSourceAttributedText(_ attributedText: NSAttributedString) {
        guard !attributedText.string.isEmpty else {
            return
        }

        if sourceAttributedText.length == 0 {
            setSourceAttributedText(attributedText)
            return
        }

        let mutable = NSMutableAttributedString(attributedString: sourceAttributedText)
        mutable.append(RichTextFormatting.plainAttributedString("\n"))
        mutable.append(RichTextFormatting.normalize(attributedText))
        setSourceAttributedText(mutable)
    }

    func clearSourceText() {
        setSourceText("")
    }

    func setHistoryEnabled(_ enabled: Bool) {
        historyPreferenceEnabled = enabled
    }

    func cancelPendingTranslation() {
        _ = nextRequestGeneration()
        isTranslating = false
    }

    func recordComparisonTranslation(_ record: CompletedComparisonTranslation) {
        guard historyPreferenceEnabled else {
            return
        }

        appendHistoryItem(
            TranslationHistoryItem(
                sourceText: record.sourceText,
                translatedText: record.translatedText,
                sourceLanguage: record.sourceLanguage,
                targetLanguage: record.targetLanguage,
                backend: .codexAppServer,
                provider: nil,
                modelID: record.modelID
            )
        )
    }

    func swapLanguages(sourceLanguage: inout LanguageOption, targetLanguage: inout LanguageOption) {
        guard sourceLanguage != .autoDetect else {
            sourceLanguage = targetLanguage
            targetLanguage = targetLanguage == .korean ? .english : .korean
            moveTranslatedTextToSource()
            return
        }

        swap(&sourceLanguage, &targetLanguage)
        swap(&sourceText, &translatedText)
        sourceAttributedText = RichTextFormatting.plainAttributedString(sourceText)
    }

    private func moveTranslatedTextToSource() {
        guard !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        setSourceText(translatedText)
        translatedText = ""
    }

    func beginScreenCaptureMock() {
        captureState = CaptureState(
            title: "텍스트 화면 캡처",
            message: "캡처 영역 선택까지 준비되었습니다. OCR 인식과 자동 삽입은 다음 단계 기능입니다."
        )
        statusMessage = "화면 캡처 영역 선택 대기 중"
    }

    func completeScreenCaptureMock() {
        let capturedMarker = "[캡처된 화면 영역]\nOCR 텍스트 인식은 다음 구현 단계에서 Vision 프레임워크로 연결됩니다."
        setSourceText(sourceText.isEmpty ? capturedMarker : "\(sourceText)\n\n\(capturedMarker)")
        captureState = nil
        statusMessage = "캡처가 입력 영역에 첨부되었습니다. OCR은 to-be 기능입니다."
    }

    func deleteHistoryItem(id: TranslationHistoryItem.ID) {
        if !isHistoryLoaded {
            historyMutatedBeforeLoad = true
            historyDeletedBeforeLoad.insert(id)
        }
        history.removeAll { $0.id == id }
        historyNeedsPersistence = true
        persistHistory(successMessage: "선택한 번역 기록을 삭제했습니다.")
    }

    func clearHistory() {
        if !isHistoryLoaded {
            historyMutatedBeforeLoad = true
            historyClearedBeforeLoad = true
            historyDeletedBeforeLoad.removeAll()
        }
        history.removeAll()
        historyNeedsPersistence = true
        persistHistory(successMessage: "번역 기록을 모두 삭제했습니다.")
    }

    private func loadHistory() {
        historyLoadTask?.cancel()
        historyLoadTask = Task { @MainActor [weak self, historyRepository] in
            do {
                let loadedHistory = try await historyRepository.load()
                guard let self, !Task.isCancelled else {
                    return
                }
                if self.historyMutatedBeforeLoad {
                    if !self.historyClearedBeforeLoad {
                        let localIDs = Set(self.history.map(\.id))
                        self.history.append(contentsOf: loadedHistory.filter {
                            !localIDs.contains($0.id)
                                && !self.historyDeletedBeforeLoad.contains($0.id)
                        })
                    }
                    self.isHistoryLoaded = true
                    self.persistHistory(successMessage: "")
                } else {
                    self.history = loadedHistory
                    self.isHistoryLoaded = true
                }
                self.historyLoadTask = nil
            } catch {
                guard let self, !Task.isCancelled else {
                    return
                }
                self.isHistoryLoaded = true
                if self.historyMutatedBeforeLoad {
                    self.persistHistory(successMessage: "")
                } else {
                    self.history = []
                }
                self.statusMessage = "번역 기록을 불러오지 못했습니다: \(error.localizedDescription)"
                self.historyLoadTask = nil
            }
        }
    }

    private func appendHistoryItem(_ item: TranslationHistoryItem) {
        if !isHistoryLoaded {
            historyMutatedBeforeLoad = true
        }
        history.insert(item, at: 0)
        historyNeedsPersistence = true
        persistHistory(successMessage: "번역 완료: \(item.modelID)")
    }

    private func persistHistory(successMessage _: String) {
        guard isHistoryLoaded else {
            return
        }
        historyPersistenceGeneration &+= 1
        let generation = historyPersistenceGeneration
        let snapshot = history

        historyPersistenceTask?.cancel()
        historyPersistenceTask = Task { @MainActor [weak self, historyRepository] in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
                try Task.checkCancellation()
                try await historyRepository.save(snapshot)
                guard let self,
                      !Task.isCancelled,
                      self.historyPersistenceGeneration == generation
                else {
                    return
                }
                self.historyNeedsPersistence = false
                self.historyPersistenceTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.historyPersistenceGeneration == generation
                else {
                    return
                }
                self.statusMessage = "번역 기록 저장 실패: \(error.localizedDescription)"
                self.historyPersistenceTask = nil
            }
        }
    }

    private func flushPendingHistoryPersistence() async {
        if let historyLoadTask {
            await historyLoadTask.value
        }

        while historyNeedsPersistence {
            let generation = historyPersistenceGeneration
            let pendingTask = historyPersistenceTask
            pendingTask?.cancel()
            if let pendingTask {
                await pendingTask.value
            }

            let snapshot = history
            do {
                try await historyRepository.save(snapshot)
            } catch {
                statusMessage = "번역 기록 저장 실패: \(error.localizedDescription)"
                return
            }

            guard historyPersistenceGeneration == generation else {
                continue
            }
            historyNeedsPersistence = false
            historyPersistenceTask = nil
        }
    }
}

private actor TranslationHistoryRepository {
    private let store: any TranslationHistoryStoring

    init(store: any TranslationHistoryStoring) {
        self.store = store
    }

    func load() throws -> [TranslationHistoryItem] {
        try store.load()
    }

    func save(_ items: [TranslationHistoryItem]) throws {
        try store.save(items)
    }
}

struct CaptureState: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}
