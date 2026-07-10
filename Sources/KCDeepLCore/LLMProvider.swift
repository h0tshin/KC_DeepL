import Foundation

public enum LLMProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case gemini
    case chatGPT
    case claude
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemini:
            "Gemini"
        case .chatGPT:
            "ChatGPT"
        case .claude:
            "Claude"
        case .custom:
            "Custom"
        }
    }

    public var models: [LLMModel] {
        switch self {
        case .gemini:
            [
                LLMModel(id: "gemini-2.5-flash-lite", displayName: "Gemini 2.5 Flash-Lite", provider: self),
                LLMModel(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", provider: self),
                LLMModel(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", provider: self)
            ]
        case .chatGPT:
            [
                LLMModel(id: "gpt-5.1", displayName: "GPT-5.1", provider: self),
                LLMModel(id: "gpt-4.1-mini", displayName: "GPT-4.1 mini", provider: self)
            ]
        case .claude:
            [
                LLMModel(id: "claude-sonnet-4.5", displayName: "Claude Sonnet 4.5", provider: self),
                LLMModel(id: "claude-opus-4.1", displayName: "Claude Opus 4.1", provider: self)
            ]
        case .custom:
            [
                LLMModel(id: "custom-model", displayName: "Custom model", provider: self)
            ]
        }
    }
}

public struct LLMModel: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let provider: LLMProvider

    public init(id: String, displayName: String, provider: LLMProvider) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
    }
}
