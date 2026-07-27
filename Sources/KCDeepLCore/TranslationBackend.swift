public enum TranslationBackend: String, CaseIterable, Codable, Identifiable, Sendable {
    case llmAPI
    case codexAppServer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .llmAPI:
            "LLM API 사용"
        case .codexAppServer:
            "Codex App Server 사용"
        }
    }
}
