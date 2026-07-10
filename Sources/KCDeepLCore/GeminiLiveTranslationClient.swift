import Foundation

public enum GeminiLiveTranslationError: Error, Equatable, LocalizedError {
    case missingCredential
    case invalidEndpoint
    case socketMessageEncodingFailed
    case socketMessageDecodingFailed
    case setupTimedOut
    case eventBufferOverflow
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
        case .setupTimedOut:
            "Gemini Live API 초기 연결 시간을 초과했습니다."
        case .eventBufferOverflow:
            "Gemini Live API 응답 처리가 늦어 연결을 안전하게 종료했습니다."
        case .serverError(let message):
            "Gemini Live API 오류: \(message)"
        }
    }
}

public enum GeminiLiveCredential: Equatable, Sendable {
    case apiKey(String)
    case ephemeralToken(String)

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("AQ.") || trimmed.hasPrefix("auth_tokens/") {
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

public struct GeminiLiveTranslationConfiguration: Equatable, Sendable {
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

public enum GeminiLiveTranslationEvent: Equatable, Sendable {
    case setupComplete
    case inputTranscript(text: String, languageCode: String?)
    case outputTranscript(text: String, languageCode: String?)
    case audio(Data)
    case turnComplete
    case interrupted
    case error(String)
}

public protocol GeminiLiveTranslationConnecting: Sendable {
    func connect(configuration: GeminiLiveTranslationConfiguration) async throws -> GeminiLiveTranslationSession
}

public final class GeminiLiveTranslationWebSocketClient: GeminiLiveTranslationConnecting, @unchecked Sendable {
    private let urlSession: URLSession
    private let setupTimeoutNanoseconds: UInt64

    public init(
        urlSession: URLSession = .shared,
        setupTimeout: TimeInterval = 10.0
    ) {
        self.urlSession = urlSession
        let clampedTimeout = min(300.0, max(0.1, setupTimeout))
        self.setupTimeoutNanoseconds = UInt64(clampedTimeout * 1_000_000_000)
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
            encoder: JSONEncoder()
        )
        task.resume()
        do {
            try await waitForSetupCompletion(session)
            try Task.checkCancellation()
            session.startReceiving()
            return session
        } catch {
            session.close()
            throw error
        }
    }

    private func waitForSetupCompletion(_ session: GeminiLiveTranslationSession) async throws {
        enum SetupRaceResult {
            case completed
            case timedOut
        }

        let timeoutNanoseconds = setupTimeoutNanoseconds
        try await withThrowingTaskGroup(of: SetupRaceResult.self) { group in
            group.addTask {
                try await session.sendSetupAndWaitForCompletion()
                return .completed
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timedOut
            }

            do {
                guard let result = try await group.next() else {
                    throw GeminiLiveTranslationError.setupTimedOut
                }
                group.cancelAll()

                if case .timedOut = result {
                    session.close()
                    throw GeminiLiveTranslationError.setupTimedOut
                }
            } catch {
                group.cancelAll()
                session.close()
                throw error
            }
        }
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

final class GeminiLiveEventChannel: @unchecked Sendable {
    let stream: AsyncThrowingStream<GeminiLiveTranslationEvent, Error>

    private let continuation: AsyncThrowingStream<GeminiLiveTranslationEvent, Error>.Continuation

    init(
        capacity: Int,
        onTermination: @escaping @Sendable () -> Void = {}
    ) {
        var capturedContinuation: AsyncThrowingStream<GeminiLiveTranslationEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<GeminiLiveTranslationEvent, Error>(
            bufferingPolicy: .bufferingOldest(max(1, capacity))
        ) { continuation in
            capturedContinuation = continuation
        }
        let continuation = capturedContinuation!
        continuation.onTermination = { @Sendable _ in
            onTermination()
        }

        self.stream = stream
        self.continuation = continuation
    }

    /// A full buffer is terminal rather than lossy. In particular, a control
    /// event such as interruption or turn-complete is never silently discarded.
    func yield(_ event: GeminiLiveTranslationEvent) throws {
        switch continuation.yield(event) {
        case .enqueued:
            return
        case .dropped:
            continuation.finish(throwing: GeminiLiveTranslationError.eventBufferOverflow)
            throw GeminiLiveTranslationError.eventBufferOverflow
        case .terminated:
            throw CancellationError()
        @unknown default:
            continuation.finish(throwing: GeminiLiveTranslationError.eventBufferOverflow)
            throw GeminiLiveTranslationError.eventBufferOverflow
        }
    }

    func finish() {
        continuation.finish()
    }

    func finish(throwing error: Error) {
        continuation.finish(throwing: error)
    }
}

public final class GeminiLiveTranslationSession: @unchecked Sendable {
    public let events: AsyncThrowingStream<GeminiLiveTranslationEvent, Error>

    private static let eventBufferCapacity = 128

    private let task: URLSessionWebSocketTask
    private let configuration: GeminiLiveTranslationConfiguration
    private let encoder: JSONEncoder
    private let eventChannel: GeminiLiveEventChannel
    private let stateLock = NSLock()
    private var receiveTask: Task<Void, Never>?
    private var isClosed = false

    init(
        task: URLSessionWebSocketTask,
        configuration: GeminiLiveTranslationConfiguration,
        encoder: JSONEncoder
    ) {
        self.task = task
        self.configuration = configuration
        self.encoder = encoder

        let eventChannel = GeminiLiveEventChannel(
            capacity: Self.eventBufferCapacity,
            onTermination: { [task] in
                task.cancel(with: .goingAway, reason: nil)
            }
        )
        self.eventChannel = eventChannel
        self.events = eventChannel.stream
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
        let message = try GeminiLiveTranslationMessageFactory.audioMessageData(data, encoder: encoder)
        guard let json = String(data: message, encoding: .utf8) else {
            throw GeminiLiveTranslationError.socketMessageEncodingFailed
        }
        try await task.send(.string(json))
    }

    public func sendAudioStreamEnd() async throws {
        let message = try GeminiLiveTranslationMessageFactory.audioStreamEndMessageData(encoder: encoder)
        guard let json = String(data: message, encoding: .utf8) else {
            throw GeminiLiveTranslationError.socketMessageEncodingFailed
        }
        try await task.send(.string(json))
    }

    public func close() {
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return
        }
        isClosed = true
        let taskToCancel = receiveTask
        receiveTask = nil
        stateLock.unlock()

        taskToCancel?.cancel()
        task.cancel(with: .goingAway, reason: nil)
        eventChannel.finish()
    }

    func startReceiving() {
        stateLock.lock()
        guard !isClosed, receiveTask == nil else {
            stateLock.unlock()
            return
        }

        let webSocketTask = task
        let eventChannel = eventChannel
        receiveTask = Task { [webSocketTask, eventChannel] in
            while !Task.isCancelled {
                do {
                    let message = try await webSocketTask.receive()
                    let data = try Self.data(from: message)

                    let events = try GeminiLiveTranslationResponseParser.events(from: data)
                    for event in events {
                        try eventChannel.yield(event)
                    }
                } catch {
                    if Task.isCancelled {
                        eventChannel.finish()
                    } else {
                        eventChannel.finish(throwing: error)
                        webSocketTask.cancel(with: .goingAway, reason: nil)
                    }
                    break
                }
            }
        }
        stateLock.unlock()
    }

    private func waitForSetupComplete() async throws {
        while true {
            let message = try await task.receive()
            let data = try Self.data(from: message)

            let events = try GeminiLiveTranslationResponseParser.events(from: data)
            let didCompleteSetup = events.contains(.setupComplete)
            for event in events {
                if case .error(let message) = event {
                    throw GeminiLiveTranslationError.serverError(message)
                } else if event != .setupComplete {
                    try eventChannel.yield(event)
                }
            }

            if didCompleteSetup {
                return
            }
        }
    }

    private static func data(from message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case .data(let value):
            return value
        case .string(let value):
            guard let data = value.data(using: .utf8) else {
                throw GeminiLiveTranslationError.socketMessageDecodingFailed
            }
            return data
        @unknown default:
            throw GeminiLiveTranslationError.socketMessageDecodingFailed
        }
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

    static func audioMessageData(
        _ data: Data,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        let message = RealtimeAudioMessage(
            realtimeInput: RealtimeAudioInput(
                audio: InlineAudio(data: data.base64EncodedString(), mimeType: "audio/pcm;rate=16000")
            )
        )
        do {
            return try encoder.encode(message)
        } catch {
            throw GeminiLiveTranslationError.socketMessageEncodingFailed
        }
    }

    static func audioStreamEndMessageData(
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        let message = AudioStreamEndMessage(realtimeInput: AudioStreamEndInput(audioStreamEnd: true))
        do {
            return try encoder.encode(message)
        } catch {
            throw GeminiLiveTranslationError.socketMessageEncodingFailed
        }
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
