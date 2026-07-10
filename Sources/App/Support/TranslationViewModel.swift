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

    private let client: TranslationClient
    private let historyRepository: TranslationHistoryRepository
    private var debouncedTranslationTask: Task<Void, Never>?
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
        historyStore: TranslationHistoryStoring = FileTranslationHistoryStore()
    ) {
        self.client = client
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
        historyLoadTask?.cancel()
    }

    func translate(
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        provider: LLMProvider,
        modelID: String,
        apiKey: String,
        temperature: Double,
        historyEnabled: Bool
    ) async {
        historyPreferenceEnabled = historyEnabled
        let generation = nextRequestGeneration()
        let translationText = RichTextFormatting.markdown(
            from: sourceAttributedText,
            fallback: sourceText
        )
        await translateSnapshot(
            translationText,
            expectedSourceText: sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            provider: provider,
            modelID: modelID,
            apiKey: apiKey,
            temperature: temperature,
            historyEnabled: historyEnabled,
            generation: generation
        )
    }

    func scheduleAutoTranslation(
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        provider: LLMProvider,
        modelID: String,
        apiKey: String,
        temperature: Double,
        historyEnabled: Bool,
        autoTranslate: Bool
    ) {
        historyPreferenceEnabled = historyEnabled
        let generation = nextRequestGeneration()
        isTranslating = false

        let expectedSourceText = sourceText
        guard !expectedSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translatedText = ""
            errorMessage = nil
            runStartupChecks(apiKey: apiKey)
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
                generation: generation
            )
        }
    }

    func runStartupChecks(apiKey: String) {
        let defaults = UserDefaults.standard
        let provider = LLMProvider(rawValue: defaults.string(forKey: PreferenceKeys.provider) ?? "") ?? .gemini
        let modelID = defaults.string(forKey: PreferenceKeys.modelID) ?? AppDefaults.defaultModelID

        if provider == .gemini && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusMessage = "Gemini API 키를 설정해 주세요."
        } else if modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusMessage = "번역 모델을 선택해 주세요."
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
        generation: UInt
    ) async {
        guard isCurrentRequest(generation, expectedSourceText: expectedSourceText) else {
            return
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translatedText = ""
            errorMessage = nil
            runStartupChecks(apiKey: apiKey)
            return
        }

        guard provider == .gemini else {
            errorMessage = nil
            isTranslating = false
            translatedText = "현재 목업에서는 Gemini 번역 호출만 연결되어 있습니다. \(provider.displayName) 연동은 고급 설정 설계 범위에 포함되어 있습니다."
            statusMessage = "선택한 공급자의 실제 호출은 다음 구현 단계에서 연결됩니다."
            return
        }

        isTranslating = true
        errorMessage = nil
        statusMessage = "\(modelID)로 번역 중입니다."

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
            let output = try await client.translate(request)
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
        requestGeneration &+= 1
        return requestGeneration
    }

    private func prepareForTermination() {
        debouncedTranslationTask?.cancel()
        debouncedTranslationTask = nil
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
