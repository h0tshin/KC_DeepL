import Foundation
import KCDeepLCore

enum LiveTranslationAudioDirection {
    case incoming
    case outgoing
}

struct LiveTranslationAudioSettings {
    let modelID: String
    let listeningCredential: String
    let speakingCredential: String
    let remoteMicInput: String
    let remoteSpeakerOutput: String
    let localMicInput: String
    let localSpeakerOutput: String
    let localTargetLanguage: String
    let remoteTargetLanguage: String
    let localTargetEcho: Bool
    let remoteTargetEcho: Bool
    let pauseRemoteInputOnStart: Bool
    let listenerVolume: Double

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> LiveTranslationAudioSettings {
        LiveTranslationAudioSettings(
            modelID: defaults.string(forKey: PreferenceKeys.liveModelID) ?? AppDefaults.defaultLiveModelID,
            listeningCredential: defaults.string(forKey: PreferenceKeys.liveListeningAPIKey) ?? "",
            speakingCredential: defaults.string(forKey: PreferenceKeys.liveSpeakingAPIKey) ?? "",
            remoteMicInput: defaults.string(forKey: PreferenceKeys.liveRemoteMicInput) ?? "",
            remoteSpeakerOutput: defaults.string(forKey: PreferenceKeys.liveRemoteSpeakerOutput) ?? "",
            localMicInput: defaults.string(forKey: PreferenceKeys.liveLocalMicInput) ?? "",
            localSpeakerOutput: defaults.string(forKey: PreferenceKeys.liveLocalSpeakerOutput) ?? "",
            localTargetLanguage: defaults.string(forKey: PreferenceKeys.liveLocalTargetLanguage) ?? "en",
            remoteTargetLanguage: defaults.string(forKey: PreferenceKeys.liveRemoteTargetLanguage) ?? "ko",
            localTargetEcho: defaults.bool(forKey: PreferenceKeys.liveLocalTargetEcho),
            remoteTargetEcho: defaults.bool(forKey: PreferenceKeys.liveRemoteTargetEcho),
            pauseRemoteInputOnStart: defaults.bool(forKey: PreferenceKeys.livePauseRemoteInputOnStart),
            listenerVolume: defaults.object(forKey: PreferenceKeys.liveListenerVolume) as? Double ?? 1.0
        )
    }
}

private final class LiveAudioChunkSender: @unchecked Sendable {
    /// Translation capture currently emits one chunk every 100 ms. Keeping the
    /// newest ten chunks bounds queued audio to roughly one second. When the
    /// network is slower than capture, the oldest unsent chunk is dropped so a
    /// recovered connection resumes with current speech instead of stale audio.
    private static let maximumBufferedChunks = 10

    private let continuation: AsyncStream<Data>.Continuation
    private let pumpTask: Task<Void, Never>

    init(
        session: GeminiLiveTranslationSession,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        var capturedContinuation: AsyncStream<Data>.Continuation?
        let stream = AsyncStream<Data>(
            bufferingPolicy: .bufferingNewest(Self.maximumBufferedChunks)
        ) { continuation in
            capturedContinuation = continuation
        }
        let continuation = capturedContinuation!

        self.continuation = continuation
        self.pumpTask = Task {
            do {
                for await data in stream {
                    try Task.checkCancellation()
                    try await session.sendAudioChunk(data)
                }
            } catch {
                continuation.finish()
                if !Task.isCancelled {
                    onFailure(error)
                }
            }
        }
    }

    @discardableResult
    func enqueue(_ data: Data) -> Bool {
        switch continuation.yield(data) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            return false
        @unknown default:
            return false
        }
    }

    func cancel() {
        continuation.finish()
        pumpTask.cancel()
    }
}

@MainActor
final class LiveTranslationAudioCoordinator {
    var onEvent: ((LiveTranslationAudioDirection, GeminiLiveTranslationEvent) -> Void)?
    var onPlaybackProgress: ((LiveTranslationAudioDirection, LiveAudioPlaybackProgress) -> Void)?
    var onLog: ((String) -> Void)?

    private let client: GeminiLiveTranslationConnecting
    private var speakerBypass: LiveBypassAudioStream?
    private var micBypass: LiveBypassAudioStream?
    private var incomingSession: GeminiLiveTranslationSession?
    private var outgoingSession: GeminiLiveTranslationSession?
    private var incomingInput: LivePCMInputStream?
    private var outgoingInput: LivePCMInputStream?
    private var incomingOutput: LivePCMOutputQueue?
    private var outgoingOutput: LivePCMOutputQueue?
    private var incomingReceiveTask: Task<Void, Never>?
    private var outgoingReceiveTask: Task<Void, Never>?
    private var incomingSender: LiveAudioChunkSender?
    private var outgoingSender: LiveAudioChunkSender?
    private var incomingGeneration: UInt64 = 0
    private var outgoingGeneration: UInt64 = 0

    init(client: GeminiLiveTranslationConnecting = GeminiLiveTranslationWebSocketClient()) {
        self.client = client
    }

    func startSpeakerBypass(settings: LiveTranslationAudioSettings) throws {
        stopIncomingTranslation()
        if speakerBypass != nil {
            return
        }

        let inputDevice = LiveAudioDeviceRegistry.resolveDevice(
            selection: settings.remoteMicInput,
            direction: .input,
            preferredNames: ["BlackHole 2ch", "BlackHole"]
        )
        let outputDevice = LiveAudioDeviceRegistry.resolveDevice(
            selection: settings.localSpeakerOutput,
            direction: .output,
            preferredNames: ["MacBook Pro 스피커", "External Headphones", "Headphones"]
        )
        let stream = LiveBypassAudioStream(
            inputDevice: inputDevice,
            outputDevice: outputDevice,
            gain: settings.listenerVolume
        )
        try stream.start()
        speakerBypass = stream
        onLog?("스피커 By Pass: \(inputDevice.name) -> \(outputDevice.name)")
    }

    func stopSpeakerBypass() {
        speakerBypass?.stop()
        speakerBypass = nil
    }

    func startMicBypass(settings: LiveTranslationAudioSettings) throws {
        stopOutgoingTranslation()
        if micBypass != nil {
            return
        }

        let inputDevice = LiveAudioDeviceRegistry.resolveDevice(
            selection: settings.localMicInput,
            direction: .input,
            preferredNames: ["MacBook Pro 마이크", "Built-in Microphone"]
        )
        let outputDevice = LiveAudioDeviceRegistry.resolveDevice(
            selection: settings.remoteSpeakerOutput,
            direction: .output,
            preferredNames: ["BlackHole 16ch", "BlackHole 2ch", "BlackHole"]
        )
        let stream = LiveBypassAudioStream(inputDevice: inputDevice, outputDevice: outputDevice)
        try stream.start()
        micBypass = stream
        onLog?("마이크 By Pass: \(inputDevice.name) -> \(outputDevice.name)")
    }

    func stopMicBypass() {
        micBypass?.stop()
        micBypass = nil
    }

    func startIncomingTranslation(settings: LiveTranslationAudioSettings) async throws {
        stopSpeakerBypass()
        stopIncomingTranslation()
        let generation = incomingGeneration

        let inputDevice = LiveAudioDeviceRegistry.resolveDevice(
            selection: settings.remoteMicInput,
            direction: .input,
            preferredNames: ["BlackHole 2ch", "BlackHole"]
        )
        let outputDevice = LiveAudioDeviceRegistry.resolveDevice(
            selection: settings.localSpeakerOutput,
            direction: .output,
            preferredNames: ["MacBook Pro 스피커", "External Headphones", "Headphones"]
        )

        let session = try await client.connect(
            configuration: GeminiLiveTranslationConfiguration(
                modelID: settings.modelID,
                credential: GeminiLiveCredential(rawValue: settings.listeningCredential),
                targetLanguageCode: settings.remoteTargetLanguage,
                echoTargetLanguage: settings.remoteTargetEcho
            )
        )

        var output: LivePCMOutputQueue?
        var input: LivePCMInputStream?
        var sender: LiveAudioChunkSender?
        var committed = false
        defer {
            if !committed {
                input?.stop()
                sender?.cancel()
                output?.stop()
                session.close()
            }
        }

        guard generation == incomingGeneration,
              !Task.isCancelled
        else {
            throw CancellationError()
        }

        let createdOutput = LivePCMOutputQueue(
            device: outputDevice,
            sampleRate: 24_000,
            channelCount: 1,
            gain: settings.listenerVolume
        )
        output = createdOutput
        createdOutput.onPlaybackProgress = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self,
                      self.incomingGeneration == generation
                else {
                    return
                }
                self.onPlaybackProgress?(.incoming, progress)
            }
        }
        try createdOutput.start()

        let createdSender = LiveAudioChunkSender(session: session) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleTerminalFailure(
                    direction: .incoming,
                    generation: generation,
                    message: Self.userFacingErrorMessage(error)
                )
            }
        }
        sender = createdSender
        let createdInput = LivePCMInputStream(device: inputDevice, sampleRate: 16_000, channelCount: 1) { data in
            _ = createdSender.enqueue(data)
        }
        input = createdInput
        try createdInput.start()

        guard generation == incomingGeneration,
              !Task.isCancelled
        else {
            throw CancellationError()
        }

        incomingSession = session
        incomingOutput = createdOutput
        incomingInput = createdInput
        incomingSender = createdSender
        incomingReceiveTask = receiveEvents(
            from: session,
            output: createdOutput,
            direction: .incoming,
            generation: generation
        )
        committed = true
        onLog?("On Air 수신: \(inputDevice.name) -> \(outputDevice.name)")
    }

    func stopIncomingTranslation() {
        incomingGeneration &+= 1
        incomingInput?.stop()
        incomingInput = nil
        incomingSender?.cancel()
        incomingSender = nil
        incomingReceiveTask?.cancel()
        incomingReceiveTask = nil
        incomingSession?.close()
        incomingSession = nil
        incomingOutput?.stop()
        incomingOutput = nil
    }

    func startOutgoingTranslation(settings: LiveTranslationAudioSettings) async throws {
        stopMicBypass()
        stopOutgoingTranslation()
        let generation = outgoingGeneration

        let inputDevice = LiveAudioDeviceRegistry.resolveDevice(
            selection: settings.localMicInput,
            direction: .input,
            preferredNames: ["MacBook Pro 마이크", "Built-in Microphone"]
        )
        let outputDevice = LiveAudioDeviceRegistry.resolveDevice(
            selection: settings.remoteSpeakerOutput,
            direction: .output,
            preferredNames: ["BlackHole 16ch", "BlackHole 2ch", "BlackHole"]
        )

        let session = try await client.connect(
            configuration: GeminiLiveTranslationConfiguration(
                modelID: settings.modelID,
                credential: GeminiLiveCredential(rawValue: settings.speakingCredential),
                targetLanguageCode: settings.localTargetLanguage,
                echoTargetLanguage: settings.localTargetEcho
            )
        )

        var output: LivePCMOutputQueue?
        var input: LivePCMInputStream?
        var sender: LiveAudioChunkSender?
        var committed = false
        defer {
            if !committed {
                input?.stop()
                sender?.cancel()
                output?.stop()
                session.close()
            }
        }

        guard generation == outgoingGeneration,
              !Task.isCancelled
        else {
            throw CancellationError()
        }

        let createdOutput = LivePCMOutputQueue(device: outputDevice, sampleRate: 24_000, channelCount: 1)
        output = createdOutput
        createdOutput.onPlaybackProgress = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self,
                      self.outgoingGeneration == generation
                else {
                    return
                }
                self.onPlaybackProgress?(.outgoing, progress)
            }
        }
        try createdOutput.start()

        let createdSender = LiveAudioChunkSender(session: session) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleTerminalFailure(
                    direction: .outgoing,
                    generation: generation,
                    message: Self.userFacingErrorMessage(error)
                )
            }
        }
        sender = createdSender
        let createdInput = LivePCMInputStream(device: inputDevice, sampleRate: 16_000, channelCount: 1) { data in
            _ = createdSender.enqueue(data)
        }
        input = createdInput
        try createdInput.start()

        guard generation == outgoingGeneration,
              !Task.isCancelled
        else {
            throw CancellationError()
        }

        outgoingSession = session
        outgoingOutput = createdOutput
        outgoingInput = createdInput
        outgoingSender = createdSender
        outgoingReceiveTask = receiveEvents(
            from: session,
            output: createdOutput,
            direction: .outgoing,
            generation: generation
        )
        committed = true
        onLog?("마이크 통역: \(inputDevice.name) -> \(outputDevice.name)")
    }

    func stopOutgoingTranslation() {
        outgoingGeneration &+= 1
        outgoingInput?.stop()
        outgoingInput = nil
        outgoingSender?.cancel()
        outgoingSender = nil
        outgoingReceiveTask?.cancel()
        outgoingReceiveTask = nil
        outgoingSession?.close()
        outgoingSession = nil
        outgoingOutput?.stop()
        outgoingOutput = nil
    }

    func setListenerVolume(_ volume: Double) {
        speakerBypass?.setGain(volume)
        incomingOutput?.setGain(volume)
    }

    func stopAll() {
        stopSpeakerBypass()
        stopMicBypass()
        stopIncomingTranslation()
        stopOutgoingTranslation()
    }

    private func receiveEvents(
        from session: GeminiLiveTranslationSession,
        output: LivePCMOutputQueue,
        direction: LiveTranslationAudioDirection,
        generation: UInt64
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            do {
                for try await event in session.events {
                    guard let self,
                          self.isCurrent(generation: generation, direction: direction)
                    else {
                        return
                    }

                    if case .error(let message) = event {
                        self.handleTerminalFailure(
                            direction: direction,
                            generation: generation,
                            message: message
                        )
                        return
                    } else if case .audio(let data) = event {
                        output.enqueue(data)
                    } else if case .interrupted = event {
                        output.reset()
                    }

                    self.onEvent?(direction, event)
                }

                guard !Task.isCancelled,
                      let self,
                      self.isCurrent(generation: generation, direction: direction)
                else {
                    return
                }
                self.handleTerminalFailure(
                    direction: direction,
                    generation: generation,
                    message: "Live API 연결이 종료되었습니다."
                )
            } catch {
                guard !Task.isCancelled,
                      !Self.isCancellation(error)
                else {
                    return
                }

                guard let self,
                      self.isCurrent(generation: generation, direction: direction)
                else {
                    return
                }
                self.handleTerminalFailure(
                    direction: direction,
                    generation: generation,
                    message: Self.userFacingErrorMessage(error)
                )
            }
        }
    }

    private func handleTerminalFailure(
        direction: LiveTranslationAudioDirection,
        generation: UInt64,
        message: String
    ) {
        guard isCurrent(generation: generation, direction: direction) else {
            return
        }

        onEvent?(direction, .error(message))
        guard isCurrent(generation: generation, direction: direction) else {
            return
        }
        onLog?("Live API 연결 실패: \(message)")

        // Remove the currently executing receive task before teardown so the
        // stop path does not cancel itself. A concurrent sender failure uses
        // the same generation guard and becomes a no-op after teardown.
        switch direction {
        case .incoming:
            incomingReceiveTask = nil
            stopIncomingTranslation()
        case .outgoing:
            outgoingReceiveTask = nil
            stopOutgoingTranslation()
        }
    }

    private func isCurrent(
        generation: UInt64,
        direction: LiveTranslationAudioDirection
    ) -> Bool {
        switch direction {
        case .incoming:
            generation == incomingGeneration
        case .outgoing:
            generation == outgoingGeneration
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func userFacingErrorMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("expired")
            || message.localizedCaseInsensitiveContains("unauthorized")
            || message.localizedCaseInsensitiveContains("forbidden")
            || message.localizedCaseInsensitiveContains("401")
            || message.localizedCaseInsensitiveContains("403") {
            return "인증 값이 만료되었거나 유효하지 않습니다. 설정의 수화용/발화용 API 키를 확인해 주세요."
        }
        return message
    }
}
