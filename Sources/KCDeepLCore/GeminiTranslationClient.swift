import Foundation

public enum TranslationClientError: Error, Equatable, LocalizedError {
    case emptyInput
    case missingAPIKey
    case invalidURL
    case badStatus(Int, String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            "번역할 텍스트를 입력해 주세요."
        case .missingAPIKey:
            "Gemini API 키가 설정되어 있지 않습니다."
        case .invalidURL:
            "Gemini API 주소를 만들 수 없습니다."
        case let .badStatus(code, message):
            "Gemini API 요청 실패 (\(code)): \(message)"
        case .emptyResponse:
            "Gemini 응답에서 번역문을 찾을 수 없습니다."
        }
    }
}

public protocol TranslationClient {
    func translate(_ request: TranslationRequest) async throws -> String
}

public final class GeminiTranslationClient: TranslationClient {
    private let session: URLSession
    private let baseURL = URL(string: "https://generativelanguage.googleapis.com")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func translate(_ request: TranslationRequest) async throws -> String {
        let trimmedText = request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw TranslationClientError.emptyInput
        }

        guard !request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationClientError.missingAPIKey
        }

        return try await performGenerateContentRequest(request)
    }

    private func performGenerateContentRequest(_ request: TranslationRequest) async throws -> String {
        guard let endpoint = URL(string: "\(baseURL.absoluteString)/v1beta/models/\(request.modelID):generateContent") else {
            throw TranslationClientError.invalidURL
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(request.apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body = GeminiGenerateContentRequest(
            contents: [
                GeminiContent(
                    role: "user",
                    parts: [GeminiPart(text: TranslationPromptBuilder.prompt(for: request))]
                )
            ],
            generationConfig: GeminiGenerationConfig(
                temperature: request.temperature,
                maxOutputTokens: 8192
            )
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        return try await send(urlRequest)
    }

    private func send(_ request: URLRequest) async throws -> String {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationClientError.emptyResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "No response body"
            throw TranslationClientError.badStatus(httpResponse.statusCode, message)
        }

        return try GeminiResponseParser.extractText(from: data)
    }
}

private struct GeminiGenerateContentRequest: Encodable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig
}

private struct GeminiContent: Encodable {
    let role: String
    let parts: [GeminiPart]
}

private struct GeminiPart: Encodable {
    let text: String
}

private struct GeminiGenerationConfig: Encodable {
    let temperature: Double
    let maxOutputTokens: Int
}
