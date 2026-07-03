import Foundation

public enum GeminiLiveTranslationError: Error, Equatable, LocalizedError {
    case missingCredential
    case invalidEndpoint
    case socketMessageEncodingFailed
    case socketMessageDecodingFailed
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            "Gemini Live API 인증 값이 설정되어 있지 않습니다."
        case .invalidEndpoint:
            "Gemini Live API WebSocket 주소를 만들 수 없습니다."
        case .socketMessageEncodingFailed:
            "Gemini Live API 메시지를 만들 수 없습니다."
        case .socketMessageDecodingFailed:
            "Gemini Live API 응답을 해석할 수 없습니다."
        case .serverError(let message):
            "Gemini Live API 오류: \(message)"
        }
    }
}

public enum GeminiLiveCredential: Equatable {
    case apiKey(String)
    case ephemeralToken(String)

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("AQ.") {
            self = .ephemeralToken(trimmed)
        } else {
            self = .apiKey(trimmed)
        }
    }

    var value: String {
        switch self {
        case .apiKey(let value), .ephemeralToken(let value):
            value
        }
    }
}

public struct GeminiLiveTranslationConfiguration: Equatable {
    public let modelID: String
    public let credential: GeminiLiveCredential
    public let targetLanguageCode: String
    public let echoTargetLanguage: Bool

    public init(
        modelID: String,
        credential: GeminiLiveCredential,
        targetLanguageCode: String,
        echoTargetLanguage: Bool
    ) {
        self.modelID = modelID
        self.credential = credential
        self.targetLanguageCode = targetLanguageCode
        self.echoTargetLanguage = echoTargetLanguage
    }
}

public enum GeminiLiveTranslationEvent: Equatable {
    case setupComplete
    case inputTranscript(text: String, languageCode: String?)
    case outputTranscript(text: String, languageCode: String?)
    case audio(Data)
    case turnComplete
    case interrupted
    case error(String)
}

public protocol GeminiLiveTranslationConnecting {
    func connect(configuration: GeminiLiveTranslationConfiguration) async throws -> GeminiLiveTranslationSession
}

public final class GeminiLiveTranslationWebSocketClient: GeminiLiveTranslationConnecting {
    private let urlSession: URLSession
    private let encoder: JSONEncoder

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        self.encoder = JSONEncoder()
    }

    public func connect(configuration: GeminiLiveTranslationConfiguration) async throws -> GeminiLiveTranslationSession {
        guard !configuration.credential.value.isEmpty else {
            throw GeminiLiveTranslationError.missingCredential
        }

        let url = try endpointURL(for: configuration.credential)
        let task = urlSession.webSocketTask(with: url)
        let session = GeminiLiveTranslationSession(
            task: task,
            configuration: configuration,
            encoder: encoder
        )
        task.resume()
        try await session.sendSetupAndWaitForCompletion()
        session.startReceiving()
        return session
    }

    private func endpointURL(for credential: GeminiLiveCredential) throws -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "generativelanguage.googleapis.com"

        switch credential {
        case .apiKey(let key):
            components.path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
            components.queryItems = [URLQueryItem(name: "key", value: key)]
        case .ephemeralToken(let token):
            components.path = "/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained"
            components.queryItems = [URLQueryItem(name: "access_token", value: token)]
        }

        guard let url = components.url else {
            throw GeminiLiveTranslationError.invalidEndpoint
        }

        return url
    }
}

public final class GeminiLiveTranslationSession {
    public let events: AsyncThrowingStream<GeminiLiveTranslationEvent, Error>

    private let task: URLSessionWebSocketTask
    private let configuration: GeminiLiveTranslationConfiguration
    private let encoder: JSONEncoder
    private let continuation: AsyncThrowingStream<GeminiLiveTranslationEvent, Error>.Continuation
    private var receiveTask: Task<Void, Never>?

    init(
        task: URLSessionWebSocketTask,
        configuration: GeminiLiveTranslationConfiguration,
        encoder: JSONEncoder
    ) {
        self.task = task
        self.configuration = configuration
        self.encoder = encoder

        let streamPair = Self.makeEventStream()
        self.events = streamPair.stream
        self.continuation = streamPair.continuation
    }

    deinit {
        close()
    }

    func sendSetupAndWaitForCompletion() async throws {
        let data = try GeminiLiveTranslationMessageFactory.setupMessageData(
            configuration: configuration,
            encoder: encoder
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw GeminiLiveTranslationError.socketMessageEncodingFailed
        }
        try await task.send(.string(json))
        try await waitForSetupComplete()
    }

    public func sendAudioChunk(_ data: Data) async throws {
        let message = GeminiLiveTranslationMessageFactory.audioMessageData(data, encoder: encoder)
        guard let json = String(data: message, encoding: .utf8) else {
            throw GeminiLiveTranslationError.socketMessageEncodingFailed
        }
        try await task.send(.string(json))
    }

    public func sendAudioStreamEnd() async throws {
        let message = GeminiLiveTranslationMessageFactory.audioStreamEndMessageData(encoder: encoder)
        guard let json = String(data: message, encoding: .utf8) else {
            throw GeminiLiveTranslationError.socketMessageEncodingFailed
        }
        try await task.send(.string(json))
    }

    public func close() {
        receiveTask?.cancel()
        receiveTask = nil
        task.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }

    func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    let data: Data
                    switch message {
                    case .data(let value):
                        data = value
                    case .string(let value):
                        guard let stringData = value.data(using: .utf8) else {
                            throw GeminiLiveTranslationError.socketMessageDecodingFailed
                        }
                        data = stringData
                    @unknown default:
                        throw GeminiLiveTranslationError.socketMessageDecodingFailed
                    }

                    let events = try GeminiLiveTranslationResponseParser.events(from: data)
                    for event in events {
                        continuation.yield(event)
                    }
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                    break
                }
            }
        }
    }

    private func waitForSetupComplete() async throws {
        while true {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .data(let value):
                data = value
            case .string(let value):
                guard let stringData = value.data(using: .utf8) else {
                    throw GeminiLiveTranslationError.socketMessageDecodingFailed
                }
                data = stringData
            @unknown default:
                throw GeminiLiveTranslationError.socketMessageDecodingFailed
            }

            let events = try GeminiLiveTranslationResponseParser.events(from: data)
            for event in events {
                if case .error(let message) = event {
                    throw GeminiLiveTranslationError.serverError(message)
                }
            }

            if events.contains(.setupComplete) {
                return
            }

            for event in events {
                continuation.yield(event)
            }
        }
    }

    private static func makeEventStream() -> (
        stream: AsyncThrowingStream<GeminiLiveTranslationEvent, Error>,
        continuation: AsyncThrowingStream<GeminiLiveTranslationEvent, Error>.Continuation
    ) {
        var capturedContinuation: AsyncThrowingStream<GeminiLiveTranslationEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<GeminiLiveTranslationEvent, Error> { continuation in
            capturedContinuation = continuation
        }
        return (stream, capturedContinuation!)
    }
}

enum GeminiLiveTranslationMessageFactory {
    static func setupMessageData(
        configuration: GeminiLiveTranslationConfiguration,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        let message = SetupMessage(
            setup: Setup(
                model: "models/\(configuration.modelID)",
                inputAudioTranscription: EmptyObject(),
                outputAudioTranscription: EmptyObject(),
                generationConfig: GenerationConfig(
                    responseModalities: ["AUDIO"],
                    translationConfig: TranslationConfig(
                        targetLanguageCode: configuration.targetLanguageCode,
                        echoTargetLanguage: configuration.echoTargetLanguage
                    )
                )
            )
        )
        return try encoder.encode(message)
    }

    static func audioMessageData(_ data: Data, encoder: JSONEncoder = JSONEncoder()) -> Data {
        let message = RealtimeAudioMessage(
            realtimeInput: RealtimeAudioInput(
                audio: InlineAudio(data: data.base64EncodedString(), mimeType: "audio/pcm;rate=16000")
            )
        )
        return (try? encoder.encode(message)) ?? Data()
    }

    static func audioStreamEndMessageData(encoder: JSONEncoder = JSONEncoder()) -> Data {
        let message = AudioStreamEndMessage(realtimeInput: AudioStreamEndInput(audioStreamEnd: true))
        return (try? encoder.encode(message)) ?? Data()
    }

    private struct SetupMessage: Encodable {
        let setup: Setup
    }

    private struct Setup: Encodable {
        let model: String
        let inputAudioTranscription: EmptyObject
        let outputAudioTranscription: EmptyObject
        let generationConfig: GenerationConfig
    }

    private struct GenerationConfig: Encodable {
        let responseModalities: [String]
        let translationConfig: TranslationConfig
    }

    private struct EmptyObject: Encodable {}

    private struct TranslationConfig: Encodable {
        let targetLanguageCode: String
        let echoTargetLanguage: Bool
    }

    private struct RealtimeAudioMessage: Encodable {
        let realtimeInput: RealtimeAudioInput
    }

    private struct RealtimeAudioInput: Encodable {
        let audio: InlineAudio
    }

    private struct InlineAudio: Encodable {
        let data: String
        let mimeType: String
    }

    private struct AudioStreamEndMessage: Encodable {
        let realtimeInput: AudioStreamEndInput
    }

    private struct AudioStreamEndInput: Encodable {
        let audioStreamEnd: Bool
    }
}

enum GeminiLiveTranslationResponseParser {
    static func events(from data: Data) throws -> [GeminiLiveTranslationEvent] {
        guard data.contains(where: { !Self.isASCIIWhitespace($0) }) else {
            return []
        }

        let response = try JSONDecoder().decode(ServerMessage.self, from: data)
        var events: [GeminiLiveTranslationEvent] = []

        if response.setupComplete != nil {
            events.append(.setupComplete)
        }

        if let error = response.error {
            events.append(.error(error.displayMessage))
        }

        guard let content = response.serverContent else {
            return events
        }

        if let inputTranscription = content.inputTranscription,
           let text = inputTranscription.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            events.append(.inputTranscript(text: text, languageCode: inputTranscription.languageCode))
        }

        if let outputTranscription = content.outputTranscription,
           let text = outputTranscription.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            events.append(.outputTranscript(text: text, languageCode: outputTranscription.languageCode))
        }

        if let parts = content.modelTurn?.parts {
            for part in parts {
                guard let inlineData = part.inlineData,
                      let encodedData = inlineData.data,
                      let audio = Data(base64Encoded: encodedData)
                else {
                    continue
                }
                events.append(.audio(audio))
            }
        }

        if content.interrupted == true {
            events.append(.interrupted)
        }

        if content.turnComplete == true {
            events.append(.turnComplete)
        }

        return events
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
    }

    private struct ServerMessage: Decodable {
        let setupComplete: SetupComplete?
        let serverContent: ServerContent?
        let error: ServerError?
    }

    private struct SetupComplete: Decodable {}

    private struct ServerError: Decodable {
        let message: String?
        let status: String?
        let code: Int?

        var displayMessage: String {
            if let message,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }

            if let status,
               !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return status
            }

            if let code {
                return "code \(code)"
            }

            return "알 수 없는 Live API 오류"
        }
    }

    private struct ServerContent: Decodable {
        let inputTranscription: Transcription?
        let outputTranscription: Transcription?
        let modelTurn: ModelTurn?
        let turnComplete: Bool?
        let interrupted: Bool?
    }

    private struct Transcription: Decodable {
        let text: String?
        let languageCode: String?
    }

    private struct ModelTurn: Decodable {
        let parts: [Part]?
    }

    private struct Part: Decodable {
        let inlineData: InlineData?
    }

    private struct InlineData: Decodable {
        let data: String?
        let mimeType: String?
    }
}
