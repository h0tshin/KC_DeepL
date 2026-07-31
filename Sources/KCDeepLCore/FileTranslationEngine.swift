public enum FileTranslationEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case apple
    case codexAppServer
    case geminiAPI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apple:
            "Apple 내장 번역"
        case .codexAppServer:
            "Codex App Server"
        case .geminiAPI:
            "Gemini API"
        }
    }
}
