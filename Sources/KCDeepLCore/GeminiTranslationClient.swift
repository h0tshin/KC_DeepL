import Foundation

public enum TranslationClientError: Error, Equatable, LocalizedError, Sendable {
    case emptyInput
    case missingAPIKey
    case invalidModelID
    case invalidURL
    case badStatus(Int, String)
    case emptyResponse
    case responseTruncated
    case responseBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            "번역할 텍스트를 입력해 주세요."
        case .missingAPIKey:
            "Gemini API 키가 설정되어 있지 않습니다."
        case .invalidModelID:
            "Gemini 모델 ID가 올바르지 않습니다."
        case .invalidURL:
            "Gemini API 주소를 만들 수 없습니다."
        case let .badStatus(code, message):
            "Gemini API 요청 실패 (\(code)): \(message)"
        case .emptyResponse:
            "Gemini 응답에서 번역문을 찾을 수 없습니다."
        case .responseTruncated:
            "Gemini 응답이 최대 출력 길이에 도달해 번역이 잘렸습니다."
        case .responseBlocked(let reason):
            "Gemini가 번역 응답을 차단했습니다 (\(reason))."
        }
    }
}

public protocol TranslationClient: Sendable {
    func translate(_ request: TranslationRequest) async throws -> String
}

public final class GeminiTranslationClient: TranslationClient, @unchecked Sendable {
    private static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com")!
    // Every selectable stable Gemini 2.5 text model supports this output limit.
    // It prevents a dense PDF page from being truncated while remaining only a cap.
    private static let maximumOutputTokens = 65_536

    private let session: URLSession
    private let baseURL: URL
    private let requestTimeout: TimeInterval
    private let retryPolicy: GeminiTranslationRetryPolicy
    private let sleep: GeminiTranslationSleep

    public convenience init(
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 30
    ) {
        self.init(
            session: session,
            baseURL: Self.defaultBaseURL,
            requestTimeout: requestTimeout,
            retryPolicy: .standard,
            sleep: Self.defaultSleep
        )
    }

    init(
        session: URLSession,
        baseURL: URL,
        requestTimeout: TimeInterval,
        retryPolicy: GeminiTranslationRetryPolicy,
        sleep: @escaping GeminiTranslationSleep = GeminiTranslationClient.defaultSleep
    ) {
        self.session = session
        self.baseURL = baseURL
        self.requestTimeout = max(1, requestTimeout)
        self.retryPolicy = retryPolicy
        self.sleep = sleep
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
        let endpoint = try endpointURL(modelID: request.modelID)

        var urlRequest = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(
            request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            forHTTPHeaderField: "x-goog-api-key"
        )

        let body = GeminiGenerateContentRequest(
            systemInstruction: GeminiContent(
                role: nil,
                parts: [GeminiPart(text: TranslationPromptBuilder.systemInstruction(for: request))]
            ),
            contents: [
                GeminiContent(
                    role: "user",
                    parts: [GeminiPart(text: request.sourceText)]
                )
            ],
            generationConfig: GeminiGenerationConfig(
                temperature: request.temperature,
                maxOutputTokens: Self.maximumOutputTokens
            )
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        return try await send(urlRequest)
    }

    private func endpointURL(modelID: String) throws -> URL {
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidModelID(modelID) else {
            throw TranslationClientError.invalidModelID
        }
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host != nil
        else {
            throw TranslationClientError.invalidURL
        }

        return baseURL
            .appendingPathComponent("v1beta", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("\(modelID):generateContent", isDirectory: false)
    }

    private static func isValidModelID(_ modelID: String) -> Bool {
        guard (1...128).contains(modelID.count),
              let firstScalar = modelID.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(firstScalar)
        else {
            return false
        }

        let allowedCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._"))
        return modelID.unicodeScalars.allSatisfy(allowedCharacters.contains)
    }

    private func send(_ request: URLRequest) async throws -> String {
        var retryCount = 0

        while true {
            try Task.checkCancellation()

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw TranslationClientError.emptyResponse
                }

                if (200..<300).contains(httpResponse.statusCode) {
                    return try GeminiResponseParser.extractText(from: data)
                }

                guard retryCount < retryPolicy.maxRetryCount,
                      retryPolicy.isRetryable(statusCode: httpResponse.statusCode)
                else {
                    throw TranslationClientError.badStatus(
                        httpResponse.statusCode,
                        GeminiAPIErrorMessage.message(from: data)
                    )
                }

                let delay = retryPolicy.delay(
                    after: httpResponse,
                    retryAttempt: retryCount
                )
                retryCount += 1
                try await sleep(delay)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                throw CancellationError()
            }
        }
    }

    private static let defaultSleep: GeminiTranslationSleep = { delay in
        try Task.checkCancellation()
        guard delay > 0 else {
            return
        }

        let nanoseconds = UInt64(min(delay, 60) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

typealias GeminiTranslationSleep = @Sendable (TimeInterval) async throws -> Void

struct GeminiTranslationRetryPolicy: Sendable {
    static let standard = GeminiTranslationRetryPolicy(
        maxRetryCount: 2,
        initialDelay: 0.25,
        maximumDelay: 5
    )

    let maxRetryCount: Int
    let initialDelay: TimeInterval
    let maximumDelay: TimeInterval

    init(
        maxRetryCount: Int,
        initialDelay: TimeInterval,
        maximumDelay: TimeInterval
    ) {
        self.maxRetryCount = max(0, maxRetryCount)
        self.initialDelay = max(0, initialDelay)
        self.maximumDelay = max(0, maximumDelay)
    }

    func isRetryable(statusCode: Int) -> Bool {
        statusCode == 429 || [500, 502, 503, 504].contains(statusCode)
    }

    func delay(
        after response: HTTPURLResponse,
        retryAttempt: Int,
        now: Date = Date()
    ) -> TimeInterval {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
           let serverDelay = retryAfterDelay(retryAfter, now: now) {
            return min(maximumDelay, max(0, serverDelay))
        }

        let exponentialDelay = initialDelay * pow(2, Double(max(0, retryAttempt)))
        return min(maximumDelay, exponentialDelay)
    }

    private func retryAfterDelay(_ value: String, now: Date) -> TimeInterval? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(value), seconds.isFinite {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)?.timeIntervalSince(now)
    }
}

private enum GeminiAPIErrorMessage {
    private static let maximumCharacterCount = 1_024

    static func message(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(GoogleAPIErrorEnvelope.self, from: data) {
            let status = normalized(envelope.error.status ?? "")
            let message = normalized(envelope.error.message ?? "")

            if !status.isEmpty, !message.isEmpty {
                if message.range(of: status, options: [.anchored, .caseInsensitive]) != nil {
                    return bounded(message)
                }
                return bounded("\(status): \(message)")
            }
            if !message.isEmpty {
                return bounded(message)
            }
            if !status.isEmpty {
                return bounded(status)
            }
        }

        guard let body = String(data: data, encoding: .utf8) else {
            return "No response body"
        }
        let normalizedBody = normalized(body)
        return normalizedBody.isEmpty ? "No response body" : bounded(normalizedBody)
    }

    private static func normalized(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func bounded(_ value: String) -> String {
        guard value.count > maximumCharacterCount else {
            return value
        }
        return String(value.prefix(maximumCharacterCount)) + "…"
    }

    private struct GoogleAPIErrorEnvelope: Decodable {
        let error: GoogleAPIError
    }

    private struct GoogleAPIError: Decodable {
        let message: String?
        let status: String?
    }
}

private struct GeminiGenerateContentRequest: Encodable {
    let systemInstruction: GeminiContent
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig
}

private struct GeminiContent: Encodable {
    let role: String?
    let parts: [GeminiPart]
}

private struct GeminiPart: Encodable {
    let text: String
}

private struct GeminiGenerationConfig: Encodable {
    let temperature: Double
    let maxOutputTokens: Int
}
