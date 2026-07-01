import Foundation
import KCDeepLCore

@MainActor
final class TranslationViewModel: ObservableObject {
    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var isTranslating = false
    @Published var statusMessage = "로그인되었으며 DeepL Pro 플랜을 이용 중입니다. 콘텐츠가 안전하게 보호됩니다."
    @Published var errorMessage: String?
    @Published var captureState: CaptureState?
    @Published private(set) var history: [TranslationHistoryItem] = []

    private let client: TranslationClient

    init(client: TranslationClient = GeminiTranslationClient()) {
        self.client = client
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
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translatedText = ""
            errorMessage = nil
            statusMessage = "번역할 텍스트를 입력하거나 붙여넣으세요."
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
            sourceText: sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            provider: provider,
            modelID: modelID,
            apiKey: apiKey,
            temperature: temperature
        )

        do {
            let output = try await client.translate(request)
            translatedText = output
            statusMessage = "번역 완료: \(modelID)"

            if historyEnabled {
                history.insert(
                    TranslationHistoryItem(
                        sourceText: sourceText,
                        translatedText: output,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        modelID: modelID
                    ),
                    at: 0
                )
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            statusMessage = "번역 실패"
        }

        isTranslating = false
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
}

struct CaptureState: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}
