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

    init(speaker: LiveConversationSpeaker) {
        self.speaker = speaker
    }

    init(_ draft: LiveTranscriptAssemblyDraft) {
        self.speaker = draft.speaker
        self.originalText = draft.originalText
        self.translatedText = draft.translatedText
        self.updatedAt = Date()
    }

    mutating func reset() {
        originalText = ""
        translatedText = ""
        updatedAt = Date()
    }
}

private struct LiveKaraokeSegment: Equatable {
    let messageID: LiveConversationMessage.ID
    var text: String
    var highlightedCharacters: Int
}

@MainActor
final class LiveTranslationViewModel: ObservableObject {
    @Published private(set) var conversations: [LiveConversation] = []
    @Published var selectedConversationID: LiveConversation.ID?
    @Published private(set) var incomingDraft = LiveTranscriptDraft(speaker: .other)
    @Published private(set) var outgoingDraft = LiveTranscriptDraft(speaker: .me)
    @Published private(set) var karaokeHighlights: [LiveConversationMessage.ID: Int] = [:]
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
    private var incomingAssembler = LiveTranscriptTurnAssembler(speaker: .other)
    private var outgoingAssembler = LiveTranscriptTurnAssembler(speaker: .me)
    private var outgoingKaraokeSegments: [LiveKaraokeSegment] = []
    private var pendingOutgoingPlaybackDuration: TimeInterval = 0
    private var lastOutgoingPlaybackDuration: TimeInterval = 0
    private var lastOutgoingBufferedDuration: TimeInterval = 0
    private var outgoingKaraokeCharacterCarry: Double = 0
    private var outgoingTurnDidComplete = false
    private var outgoingTurnCompletionTask: Task<Void, Never>?

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
        resetOutgoingKaraoke(clearHighlights: true)
        persist(status: "새 대화를 만들었습니다.")
    }

    func selectConversation(_ id: LiveConversation.ID?) {
        selectedConversationID = id
        resetDrafts()
        resetOutgoingKaraoke(clearHighlights: true)
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
            resetOutgoingKaraoke(clearHighlights: false)
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
        audioCoordinator.onPlaybackProgress = { [weak self] direction, progress in
            self?.handlePlaybackProgress(progress, direction: direction)
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
            resetOutgoingKaraoke(clearHighlights: false)
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
            if direction == .outgoing {
                markOutgoingTurnActive()
            }
            updateDraft(direction: direction, field: .original, text: text)
        case .outputTranscript(let text, _):
            if direction == .outgoing {
                markOutgoingTurnActive()
            }
            updateDraft(direction: direction, field: .translation, text: text)
        case .turnComplete:
            finishDraft(direction: direction)
            if direction == .outgoing {
                markOutgoingTurnComplete()
            }
        case .interrupted:
            if direction == .incoming {
                resetAssembler(for: .incoming)
            } else {
                resetAssembler(for: .outgoing)
                resetOutgoingKaraoke(clearHighlights: false)
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
        let assemblyField = assemblyField(for: field)
        let changes: [LiveTranscriptAssemblyChange]

        if speaker == .other {
            changes = incomingAssembler.update(field: assemblyField, text: text)
            incomingDraft = LiveTranscriptDraft(incomingAssembler.draft)
        } else {
            changes = outgoingAssembler.update(field: assemblyField, text: text)
            outgoingDraft = LiveTranscriptDraft(outgoingAssembler.draft)
        }

        applyAssemblyChanges(changes)
    }

    private func finishDraft(direction: LiveTranslationAudioDirection) {
        let speaker: LiveConversationSpeaker = direction == .incoming ? .other : .me
        let changes: [LiveTranscriptAssemblyChange]

        if speaker == .other {
            changes = incomingAssembler.finish()
            incomingDraft = LiveTranscriptDraft(incomingAssembler.draft)
        } else {
            changes = outgoingAssembler.finish()
            outgoingDraft = LiveTranscriptDraft(outgoingAssembler.draft)
        }

        applyAssemblyChanges(changes)
    }

    private func resetDrafts() {
        incomingAssembler.reset()
        outgoingAssembler.reset()
        incomingDraft.reset()
        outgoingDraft.reset()
    }

    private func resetAssembler(for direction: LiveTranslationAudioDirection) {
        if direction == .incoming {
            incomingAssembler.reset()
            incomingDraft.reset()
        } else {
            outgoingAssembler.reset()
            outgoingDraft.reset()
        }
    }

    private func assemblyField(for field: DraftField) -> LiveTranscriptAssemblyField {
        switch field {
        case .original:
            .original
        case .translation:
            .translation
        }
    }

    private func applyAssemblyChanges(_ changes: [LiveTranscriptAssemblyChange]) {
        guard !changes.isEmpty,
              let conversationIndex = selectedConversationIndex
        else {
            return
        }

        for change in changes {
            switch change {
            case .append(let message):
                conversations[conversationIndex].messages.append(message)
                updateKaraokeTrackingIfNeeded(for: message)
            case .update(let message):
                if let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == message.id }) {
                    conversations[conversationIndex].messages[messageIndex] = message
                } else {
                    conversations[conversationIndex].messages.append(message)
                }
                updateKaraokeTrackingIfNeeded(for: message)
            }
        }

        conversations[conversationIndex].updatedAt = Date()
        persist(status: "대화를 기록했습니다.")
    }

    private func updateKaraokeTrackingIfNeeded(for message: LiveConversationMessage) {
        guard message.speaker == .me else {
            return
        }
        enqueueOutgoingKaraokeSegment(messageID: message.id, text: message.translatedText)
    }

    private func handlePlaybackProgress(
        _ progress: LiveAudioPlaybackProgress,
        direction: LiveTranslationAudioDirection
    ) {
        guard direction == .outgoing else {
            return
        }

        lastOutgoingBufferedDuration = progress.bufferedDuration
        guard progress.enqueuedFrames > 0 || progress.playedFrames > 0 else {
            lastOutgoingPlaybackDuration = 0
            return
        }

        let playedDuration = progress.playedDuration
        guard playedDuration >= lastOutgoingPlaybackDuration else {
            lastOutgoingPlaybackDuration = playedDuration
            return
        }

        let delta = min(playedDuration - lastOutgoingPlaybackDuration, 1.0)
        lastOutgoingPlaybackDuration = playedDuration

        if delta > 0 {
            advanceOutgoingKaraoke(by: delta)
        }

        if progress.isDrained && outgoingTurnDidComplete {
            completeOutgoingKaraokeQueue()
        }
    }

    private func markOutgoingTurnActive() {
        outgoingTurnDidComplete = false
        outgoingTurnCompletionTask?.cancel()
        outgoingTurnCompletionTask = nil
    }

    private func markOutgoingTurnComplete() {
        outgoingTurnDidComplete = true
        outgoingTurnCompletionTask?.cancel()

        let delay = max(0.35, lastOutgoingBufferedDuration + 0.35)
        outgoingTurnCompletionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self,
                  self.outgoingTurnDidComplete
            else {
                return
            }
            self.completeOutgoingKaraokeQueue()
        }
    }

    private func enqueueOutgoingKaraokeSegment(messageID: LiveConversationMessage.ID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let existingHighlight = min(karaokeHighlights[messageID] ?? 0, trimmed.count)
        if let index = outgoingKaraokeSegments.firstIndex(where: { $0.messageID == messageID }) {
            outgoingKaraokeSegments[index].text = trimmed
            outgoingKaraokeSegments[index].highlightedCharacters = min(
                outgoingKaraokeSegments[index].highlightedCharacters,
                trimmed.count
            )
        } else if existingHighlight < trimmed.count {
            outgoingKaraokeSegments.append(
                LiveKaraokeSegment(
                    messageID: messageID,
                    text: trimmed,
                    highlightedCharacters: existingHighlight
                )
            )
        }

        karaokeHighlights[messageID] = existingHighlight

        if pendingOutgoingPlaybackDuration > 0 {
            let pendingDuration = pendingOutgoingPlaybackDuration
            pendingOutgoingPlaybackDuration = 0
            advanceOutgoingKaraoke(by: pendingDuration)
        }
    }

    private func advanceOutgoingKaraoke(by duration: TimeInterval) {
        var remainingDuration = max(0, duration)
        var consumedTextInThisAdvance = false

        while remainingDuration > 0 {
            guard !outgoingKaraokeSegments.isEmpty else {
                if !consumedTextInThisAdvance {
                    pendingOutgoingPlaybackDuration = min(8.0, pendingOutgoingPlaybackDuration + remainingDuration)
                }
                return
            }

            var segment = outgoingKaraokeSegments[0]
            let totalCharacters = segment.text.count
            let remainingCharacters = totalCharacters - segment.highlightedCharacters

            guard remainingCharacters > 0 else {
                karaokeHighlights[segment.messageID] = totalCharacters
                outgoingKaraokeSegments.removeFirst()
                outgoingKaraokeCharacterCarry = 0
                continue
            }

            let rate = karaokeCharactersPerSecond(for: segment.text)
            let characterBudget = remainingDuration * rate + outgoingKaraokeCharacterCarry
            let wholeCharacters = Int(characterBudget)
            outgoingKaraokeCharacterCarry = characterBudget - Double(wholeCharacters)

            guard wholeCharacters > 0 else {
                return
            }

            let highlightedCharacters = min(wholeCharacters, remainingCharacters)
            segment.highlightedCharacters += highlightedCharacters
            karaokeHighlights[segment.messageID] = segment.highlightedCharacters
            consumedTextInThisAdvance = true

            let consumedDuration = Double(highlightedCharacters) / rate
            remainingDuration = max(0, remainingDuration - consumedDuration)

            if segment.highlightedCharacters >= totalCharacters {
                karaokeHighlights[segment.messageID] = totalCharacters
                outgoingKaraokeSegments.removeFirst()
                outgoingKaraokeCharacterCarry = 0
            } else {
                outgoingKaraokeSegments[0] = segment
                return
            }
        }
    }

    private func completeOutgoingKaraokeQueue() {
        for segment in outgoingKaraokeSegments {
            karaokeHighlights[segment.messageID] = segment.text.count
        }
        outgoingKaraokeSegments.removeAll()
        pendingOutgoingPlaybackDuration = 0
        outgoingKaraokeCharacterCarry = 0
        outgoingTurnDidComplete = false
        outgoingTurnCompletionTask?.cancel()
        outgoingTurnCompletionTask = nil
    }

    private func resetOutgoingKaraoke(clearHighlights: Bool) {
        outgoingKaraokeSegments.removeAll()
        pendingOutgoingPlaybackDuration = 0
        lastOutgoingPlaybackDuration = 0
        lastOutgoingBufferedDuration = 0
        outgoingKaraokeCharacterCarry = 0
        outgoingTurnDidComplete = false
        outgoingTurnCompletionTask?.cancel()
        outgoingTurnCompletionTask = nil
        if clearHighlights {
            karaokeHighlights = [:]
        }
    }

    private func karaokeCharactersPerSecond(for text: String) -> Double {
        let characters = text.filter { !$0.isWhitespace && !$0.isNewline }
        guard !characters.isEmpty else {
            return 10.0
        }

        let cjkCount = characters.filter { character in
            character.unicodeScalars.contains { scalar in
                (0xAC00...0xD7AF).contains(Int(scalar.value))
                    || (0x3040...0x30FF).contains(Int(scalar.value))
                    || (0x4E00...0x9FFF).contains(Int(scalar.value))
            }
        }.count
        let cjkRatio = Double(cjkCount) / Double(characters.count)
        return (8.0 * cjkRatio) + (13.5 * (1.0 - cjkRatio))
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
