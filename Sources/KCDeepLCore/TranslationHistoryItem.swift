import Foundation

public struct TranslationHistoryItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceText: String
    public let translatedText: String
    public let sourceLanguage: LanguageOption
    public let targetLanguage: LanguageOption
    public let backend: TranslationBackend?
    public let provider: LLMProvider?
    public let modelID: String
    public let timestamp: Date

    /// A concise, localized description suitable for showing alongside a
    /// translation in the history UI.
    public var engineSummary: String {
        let engineName: String

        switch backend {
        case .codexAppServer:
            engineName = "Codex App Server"
        case .llmAPI:
            engineName = provider?.displayName ?? "LLM API"
        case nil:
            engineName = provider?.displayName ?? "정보 없음"
        }

        return "엔진: \(engineName) · 모델: \(modelID)"
    }

    public init(
        id: UUID = UUID(),
        sourceText: String,
        translatedText: String,
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        backend: TranslationBackend? = nil,
        provider: LLMProvider? = nil,
        modelID: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.backend = backend
        self.provider = provider
        self.modelID = modelID
        self.timestamp = timestamp
    }
}
