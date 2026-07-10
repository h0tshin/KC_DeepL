import Foundation

public struct TranslationRequest: Equatable, Sendable {
    public let sourceText: String
    public let sourceLanguage: LanguageOption
    public let targetLanguage: LanguageOption
    public let provider: LLMProvider
    public let modelID: String
    public let apiKey: String
    public let temperature: Double

    public init(
        sourceText: String,
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        provider: LLMProvider,
        modelID: String,
        apiKey: String,
        temperature: Double = 0.2
    ) {
        self.sourceText = sourceText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.provider = provider
        self.modelID = modelID
        self.apiKey = apiKey
        self.temperature = temperature
    }
}
