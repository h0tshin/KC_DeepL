import Foundation
import KCDeepLCore

@MainActor
final class TranslationViewModel: ObservableObject {
    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var isTranslating = false
    @Published var statusMessage = "시스템과 API 상태를 확인하는 중입니다."
    @Published var errorMessage: String?
    @Published var captureState: CaptureState?
    @Published private(set) var history: [TranslationHistoryItem] = []

    private let client: TranslationClient
    private let historyStore: TranslationHistoryStoring
    private var debouncedTranslationTask: Task<Void, Never>?

    init(
        client: TranslationClient = GeminiTranslationClient(),
        historyStore: TranslationHistoryStoring = FileTranslationHistoryStore()
    ) {
        self.client = client
        self.historyStore = historyStore
        loadHistory()
        runStartupChecks()
    }

    deinit {
        debouncedTranslationTask?.cancel()
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
        await translateSnapshot(
            sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            provider: provider,
            modelID: modelID,
            apiKey: apiKey,
            temperature: temperature,
            historyEnabled: historyEnabled
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
        debouncedTranslationTask?.cancel()
        isTranslating = false

        let pendingText = sourceText
        guard !pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translatedText = ""
            errorMessage = nil
            runStartupChecks()
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

            await self?.translateSnapshot(
                pendingText,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                provider: provider,
                modelID: modelID,
                apiKey: apiKey,
                temperature: temperature,
                historyEnabled: historyEnabled
            )
        }
    }

    func runStartupChecks() {
        let defaults = UserDefaults.standard
        let provider = LLMProvider(rawValue: defaults.string(forKey: PreferenceKeys.provider) ?? "") ?? .gemini
        let modelID = defaults.string(forKey: PreferenceKeys.modelID) ?? AppDefaults.defaultModelID
        let apiKey = defaults.string(forKey: PreferenceKeys.geminiAPIKey) ?? AppDefaults.defaultGeminiAPIKey

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
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        provider: LLMProvider,
        modelID: String,
        apiKey: String,
        temperature: Double,
        historyEnabled: Bool
    ) async {
        guard sourceText == text else {
            return
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translatedText = ""
            errorMessage = nil
            runStartupChecks()
            return
        }

        guard provider == .gemini else {
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
            guard sourceText == text, !Task.isCancelled else {
                return
            }

            translatedText = output
            statusMessage = "번역 완료: \(modelID)"

            if historyEnabled {
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
            if sourceText == text {
                statusMessage = "입력 중입니다. 1초 후 자동 번역합니다."
            }
        } catch {
            guard sourceText == text else {
                return
            }

            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            statusMessage = "번역 실패"
        }

        if sourceText == text {
            isTranslating = false
        }
    }

    func swapLanguages(sourceLanguage: inout LanguageOption, targetLanguage: inout LanguageOption) {
        guard sourceLanguage != .autoDetect else {
            sourceLanguage = targetLanguage
            targetLanguage = .korean
            return
        }

        swap(&sourceLanguage, &targetLanguage)
        swap(&sourceText, &translatedText)
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
        sourceText = sourceText.isEmpty ? capturedMarker : "\(sourceText)\n\n\(capturedMarker)"
        captureState = nil
        statusMessage = "캡처가 입력 영역에 첨부되었습니다. OCR은 to-be 기능입니다."
    }

    func deleteHistoryItem(id: TranslationHistoryItem.ID) {
        history.removeAll { $0.id == id }
        persistHistory(successMessage: "선택한 번역 기록을 삭제했습니다.")
    }

    func clearHistory() {
        history.removeAll()
        persistHistory(successMessage: "번역 기록을 모두 삭제했습니다.")
    }

    private func loadHistory() {
        do {
            history = try historyStore.load()
        } catch {
            history = []
            statusMessage = "번역 기록을 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func appendHistoryItem(_ item: TranslationHistoryItem) {
        history.insert(item, at: 0)
        persistHistory(successMessage: "번역 완료: \(item.modelID)")
    }

    private func persistHistory(successMessage: String) {
        do {
            try historyStore.save(history)
            statusMessage = successMessage
        } catch {
            statusMessage = "번역 기록 저장 실패: \(error.localizedDescription)"
        }
    }
}

struct CaptureState: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}
