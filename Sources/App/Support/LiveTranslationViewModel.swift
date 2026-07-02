import Foundation
import KCDeepLCore

struct LiveTranscriptDraft: Equatable {
    var speaker: LiveConversationSpeaker
    var originalText = ""
    var translatedText = ""
    var updatedAt = Date()

    var isEmpty: Bool {
        originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func reset() {
        originalText = ""
        translatedText = ""
        updatedAt = Date()
    }
}

@MainActor
final class LiveTranslationViewModel: ObservableObject {
    @Published private(set) var conversations: [LiveConversation] = []
    @Published var selectedConversationID: LiveConversation.ID?
    @Published private(set) var incomingDraft = LiveTranscriptDraft(speaker: .other)
    @Published private(set) var outgoingDraft = LiveTranscriptDraft(speaker: .me)
    @Published private(set) var isOnAir = false
    @Published private(set) var isMicrophoneTranslationEnabled = false
    @Published private(set) var statusMessage = "Live 번역 준비 중"
    @Published var listenerVolume: Double {
        didSet {
            listenerVolume = min(1.0, max(0.0, listenerVolume))
            UserDefaults.standard.set(listenerVolume, forKey: PreferenceKeys.liveListenerVolume)
            audioCoordinator.setListenerVolume(listenerVolume)
        }
    }

    private let store: LiveConversationStoring
    private let audioCoordinator: LiveTranslationAudioCoordinator
    private var hasStartedBypass = false

    init(
        store: LiveConversationStoring = FileLiveConversationStore(),
        audioCoordinator: LiveTranslationAudioCoordinator? = nil
    ) {
        self.store = store
        self.audioCoordinator = audioCoordinator ?? LiveTranslationAudioCoordinator()
        self.listenerVolume = UserDefaults.standard.object(forKey: PreferenceKeys.liveListenerVolume) as? Double ?? 1.0
        configureCoordinator()
        loadConversations()
    }

    deinit {
        Task { @MainActor [audioCoordinator] in
            audioCoordinator.stopAll()
        }
    }

    var selectedConversation: LiveConversation? {
        guard let selectedConversationID else {
            return conversations.first
        }
        return conversations.first { $0.id == selectedConversationID }
    }

    var selectedConversationTitle: String {
        selectedConversation?.title ?? "새 대화"
    }

    func appear() {
        guard !hasStartedBypass else {
            return
        }

        hasStartedBypass = true
        startDefaultBypass()
    }

    func newConversation() {
        let nextIndex = conversations.count + 1
        let conversation = LiveConversation(title: "새 대화 \(nextIndex)")
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        resetDrafts()
        persist(status: "새 대화를 만들었습니다.")
    }

    func selectConversation(_ id: LiveConversation.ID?) {
        selectedConversationID = id
        resetDrafts()
        persist(status: "대화를 전환했습니다.")
    }

    func updateSelectedTitle(_ title: String) {
        guard let index = selectedConversationIndex else {
            return
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[index].title = trimmed.isEmpty ? "새 대화" : trimmed
        conversations[index].updatedAt = Date()
        persist(status: "대화방 이름을 저장했습니다.")
    }

    func setOnAir(_ enabled: Bool) {
        if enabled {
            Task {
                await startIncomingTranslation()
            }
        } else {
            isOnAir = false
            audioCoordinator.stopIncomingTranslation()
            startSpeakerBypass()
        }
    }

    func setMicrophoneTranslationEnabled(_ enabled: Bool) {
        if enabled {
            Task {
                await startOutgoingTranslation()
            }
        } else {
            isMicrophoneTranslationEnabled = false
            audioCoordinator.stopOutgoingTranslation()
            startMicBypass()
        }
    }

    func refreshBypassRoutes() {
        guard !isOnAir else {
            return
        }
        audioCoordinator.stopSpeakerBypass()
        audioCoordinator.stopMicBypass()
        startDefaultBypass()
    }

    private var selectedConversationIndex: Int? {
        guard let selectedConversationID else {
            return conversations.indices.first
        }
        return conversations.firstIndex { $0.id == selectedConversationID }
    }

    private func configureCoordinator() {
        audioCoordinator.onEvent = { [weak self] direction, event in
            self?.handle(event: event, direction: direction)
        }
        audioCoordinator.onLog = { [weak self] message in
            self?.statusMessage = message
        }
    }

    private func loadConversations() {
        do {
            let snapshot = try store.load()
            conversations = snapshot.conversations.isEmpty
                ? [LiveConversation(title: "Teams 회의")]
                : snapshot.conversations
            selectedConversationID = snapshot.selectedConversationID ?? conversations.first?.id
            persist(status: "Live 번역 준비 완료")
        } catch {
            conversations = [LiveConversation(title: "Teams 회의")]
            selectedConversationID = conversations.first?.id
            statusMessage = "Live 대화 기록을 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func startDefaultBypass() {
        startSpeakerBypass()
        startMicBypass()
    }

    private func startSpeakerBypass() {
        do {
            try audioCoordinator.startSpeakerBypass(settings: settingsSnapshot())
            statusMessage = "스피커 By Pass"
        } catch {
            statusMessage = "스피커 By Pass 실패: \(error.localizedDescription)"
        }
    }

    private func startMicBypass() {
        do {
            try audioCoordinator.startMicBypass(settings: settingsSnapshot())
            statusMessage = "마이크 By Pass"
        } catch {
            statusMessage = "마이크 By Pass 실패: \(error.localizedDescription)"
        }
    }

    private func startIncomingTranslation() async {
        let settings = settingsSnapshot()
        guard !settings.listeningCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "수화용 Gemini Live API 키를 설정해 주세요."
            return
        }

        do {
            statusMessage = "On Air 연결 중"
            try await audioCoordinator.startIncomingTranslation(settings: settings)
            isOnAir = true
            statusMessage = "On Air"
        } catch {
            isOnAir = false
            statusMessage = "On Air 실패: \(error.localizedDescription)"
            startSpeakerBypass()
        }
    }

    private func startOutgoingTranslation() async {
        let settings = settingsSnapshot()
        guard !settings.speakingCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "발화용 Gemini Live API 키를 설정해 주세요."
            return
        }

        do {
            statusMessage = "마이크 통역 연결 중"
            try await audioCoordinator.startOutgoingTranslation(settings: settings)
            isMicrophoneTranslationEnabled = true
            statusMessage = "마이크 통역 중"
        } catch {
            isMicrophoneTranslationEnabled = false
            statusMessage = "마이크 통역 실패: \(error.localizedDescription)"
            startMicBypass()
        }
    }

    private func settingsSnapshot() -> LiveTranslationAudioSettings {
        var settings = LiveTranslationAudioSettings.fromDefaults()
        settings = LiveTranslationAudioSettings(
            modelID: settings.modelID.isEmpty ? AppDefaults.defaultLiveModelID : settings.modelID,
            listeningCredential: settings.listeningCredential,
            speakingCredential: settings.speakingCredential,
            remoteMicInput: settings.remoteMicInput,
            remoteSpeakerOutput: settings.remoteSpeakerOutput,
            localMicInput: settings.localMicInput,
            localSpeakerOutput: settings.localSpeakerOutput,
            localTargetLanguage: normalizedLanguageCode(settings.localTargetLanguage, fallback: "en"),
            remoteTargetLanguage: normalizedLanguageCode(settings.remoteTargetLanguage, fallback: "ko"),
            localTargetEcho: settings.localTargetEcho,
            remoteTargetEcho: settings.remoteTargetEcho,
            listenerVolume: listenerVolume
        )
        return settings
    }

    private func normalizedLanguageCode(_ code: String, fallback: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func handle(event: GeminiLiveTranslationEvent, direction: LiveTranslationAudioDirection) {
        switch event {
        case .inputTranscript(let text, _):
            updateDraft(direction: direction, field: .original, text: text)
        case .outputTranscript(let text, _):
            updateDraft(direction: direction, field: .translation, text: text)
        case .turnComplete:
            commitDraft(direction: direction)
        case .interrupted:
            if direction == .incoming {
                incomingDraft.reset()
            } else {
                outgoingDraft.reset()
            }
        case .error(let message):
            statusMessage = "Live API 오류: \(message)"
        case .setupComplete, .audio:
            break
        }
    }

    private enum DraftField {
        case original
        case translation
    }

    private func updateDraft(direction: LiveTranslationAudioDirection, field: DraftField, text: String) {
        let speaker: LiveConversationSpeaker = direction == .incoming ? .other : .me
        if speaker == .other {
            update(&incomingDraft, field: field, text: text)
        } else {
            update(&outgoingDraft, field: field, text: text)
        }
    }

    private func update(_ draft: inout LiveTranscriptDraft, field: DraftField, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        switch field {
        case .original:
            draft.originalText = mergedTranscript(current: draft.originalText, incoming: trimmed)
        case .translation:
            draft.translatedText = mergedTranscript(current: draft.translatedText, incoming: trimmed)
        }
        draft.updatedAt = Date()
    }

    private func commitDraft(direction: LiveTranslationAudioDirection) {
        let speaker: LiveConversationSpeaker = direction == .incoming ? .other : .me
        let draft = speaker == .other ? incomingDraft : outgoingDraft
        guard !draft.isEmpty,
              let index = selectedConversationIndex
        else {
            return
        }

        conversations[index].messages.append(
            LiveConversationMessage(
                speaker: speaker,
                originalText: draft.originalText,
                translatedText: draft.translatedText
            )
        )
        conversations[index].updatedAt = Date()

        if speaker == .other {
            incomingDraft.reset()
        } else {
            outgoingDraft.reset()
        }

        persist(status: "대화를 기록했습니다.")
    }

    private func resetDrafts() {
        incomingDraft.reset()
        outgoingDraft.reset()
    }

    private func mergedTranscript(current: String, incoming: String) -> String {
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !incoming.isEmpty else {
            return current
        }
        guard !current.isEmpty else {
            return incoming
        }
        if incoming == current || current.hasSuffix(incoming) {
            return current
        }
        if incoming.hasPrefix(current) {
            return incoming
        }

        return "\(current) \(incoming)"
    }

    private func persist(status: String) {
        do {
            try store.save(
                LiveConversationSnapshot(
                    conversations: conversations,
                    selectedConversationID: selectedConversationID
                )
            )
            statusMessage = status
        } catch {
            statusMessage = "Live 대화 기록 저장 실패: \(error.localizedDescription)"
        }
    }
}
