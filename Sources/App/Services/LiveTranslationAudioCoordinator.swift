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
    let listenerVolume: Double

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> LiveTranslationAudioSettings {
        LiveTranslationAudioSettings(
            modelID: defaults.string(forKey: PreferenceKeys.liveModelID) ?? AppDefaults.defaultLiveModelID,
            listeningCredential: defaults.string(forKey: PreferenceKeys.liveListeningAPIKey) ?? AppDefaults.defaultLiveListeningAPIKey,
            speakingCredential: defaults.string(forKey: PreferenceKeys.liveSpeakingAPIKey) ?? AppDefaults.defaultGeminiAPIKey,
            remoteMicInput: defaults.string(forKey: PreferenceKeys.liveRemoteMicInput) ?? "",
            remoteSpeakerOutput: defaults.string(forKey: PreferenceKeys.liveRemoteSpeakerOutput) ?? "",
            localMicInput: defaults.string(forKey: PreferenceKeys.liveLocalMicInput) ?? "",
            localSpeakerOutput: defaults.string(forKey: PreferenceKeys.liveLocalSpeakerOutput) ?? "",
            localTargetLanguage: defaults.string(forKey: PreferenceKeys.liveLocalTargetLanguage) ?? "en",
            remoteTargetLanguage: defaults.string(forKey: PreferenceKeys.liveRemoteTargetLanguage) ?? "ko",
            localTargetEcho: defaults.bool(forKey: PreferenceKeys.liveLocalTargetEcho),
            remoteTargetEcho: defaults.bool(forKey: PreferenceKeys.liveRemoteTargetEcho),
            listenerVolume: defaults.object(forKey: PreferenceKeys.liveListenerVolume) as? Double ?? 1.0
        )
    }
}

actor LiveAudioChunkSender {
    private let session: GeminiLiveTranslationSession
    private var isClosed = false

    init(session: GeminiLiveTranslationSession) {
        self.session = session
    }

    func send(_ data: Data) async {
        guard !isClosed else {
            return
        }

        do {
            try await session.sendAudioChunk(data)
        } catch {
            isClosed = true
        }
    }

    func finish() async {
        guard !isClosed else {
            return
        }

        isClosed = true
        try? await session.sendAudioStreamEnd()
    }
}

@MainActor
final class LiveTranslationAudioCoordinator {
    var onEvent: ((LiveTranslationAudioDirection, GeminiLiveTranslationEvent) -> Void)?
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
        let output = LivePCMOutputQueue(
            device: outputDevice,
            sampleRate: 24_000,
            channelCount: 1,
            gain: settings.listenerVolume
        )
        try output.start()

        let sender = LiveAudioChunkSender(session: session)
        let input = LivePCMInputStream(device: inputDevice, sampleRate: 16_000, channelCount: 1) { data in
            Task {
                await sender.send(data)
            }
        }
        try input.start()

        incomingSession = session
        incomingOutput = output
        incomingInput = input
        incomingSender = sender
        incomingReceiveTask = receiveEvents(from: session, output: output, direction: .incoming)
        onLog?("On Air 수신: \(inputDevice.name) -> \(outputDevice.name)")
    }

    func stopIncomingTranslation() {
        incomingInput?.stop()
        incomingInput = nil
        let sender = incomingSender
        incomingSender = nil
        Task {
            await sender?.finish()
        }
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
        let output = LivePCMOutputQueue(device: outputDevice, sampleRate: 24_000, channelCount: 1)
        try output.start()

        let sender = LiveAudioChunkSender(session: session)
        let input = LivePCMInputStream(device: inputDevice, sampleRate: 16_000, channelCount: 1) { data in
            Task {
                await sender.send(data)
            }
        }
        try input.start()

        outgoingSession = session
        outgoingOutput = output
        outgoingInput = input
        outgoingSender = sender
        outgoingReceiveTask = receiveEvents(from: session, output: output, direction: .outgoing)
        onLog?("마이크 통역: \(inputDevice.name) -> \(outputDevice.name)")
    }

    func stopOutgoingTranslation() {
        outgoingInput?.stop()
        outgoingInput = nil
        let sender = outgoingSender
        outgoingSender = nil
        Task {
            await sender?.finish()
        }
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
        direction: LiveTranslationAudioDirection
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await event in session.events {
                    if case .audio(let data) = event {
                        output.enqueue(data)
                    } else if case .interrupted = event {
                        output.reset()
                    }

                    await MainActor.run {
                        self?.onEvent?(direction, event)
                    }
                }
            } catch {
                guard !Task.isCancelled,
                      !Self.isCancellation(error)
                else {
                    return
                }

                await MainActor.run {
                    self?.onLog?("Live API 연결 실패: \(Self.userFacingErrorMessage(error))")
                }
            }
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
