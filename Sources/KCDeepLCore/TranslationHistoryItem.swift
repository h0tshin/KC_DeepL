import Foundation

public struct TranslationHistoryItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceText: String
    public let translatedText: String
    public let sourceLanguage: LanguageOption
    public let targetLanguage: LanguageOption
    public let modelID: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        sourceText: String,
        translatedText: String,
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        modelID: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.modelID = modelID
        self.timestamp = timestamp
    }
}
