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
    var messageID: LiveConversationMessage.ID
    let startCharacter: Int
    var text: String
    var highlightedCharacters: Int
    var elapsedDuration: TimeInterval
    var allocatedDuration: TimeInterval

    var endCharacter: Int {
        startCharacter + text.count
    }
}

@MainActor
final class LiveTranslationViewModel: ObservableObject {
    @Published private(set) var conversations: [LiveConversation] = []
    @Published var selectedConversationID: LiveConversation.ID?
    @Published private(set) var incomingDraft = LiveTranscriptDraft(speaker: .other)
    @Published private(set) var outgoingDraft = LiveTranscriptDraft(speaker: .me)
    @Published private(set) var karaokeHighlights: [LiveConversationMessage.ID: Int] = [:]
    @Published private(set) var outgoingDraftKaraokeHighlightedCharacters: Int?
    @Published private(set) var isOnAir = false
    @Published private(set) var isMicrophoneTranslationEnabled = false
    @Published private(set) var statusMessage = "Live 번역 준비 중"
    @Published var listenerVolume: Double {
        didSet {
            let clamped = min(1.0, max(0.0, listenerVolume))
            guard listenerVolume == clamped else {
                listenerVolume = clamped
                return
            }
            audioCoordinator.setListenerVolume(listenerVolume)
            scheduleListenerVolumePersistence()
        }
    }

    private let repository: LiveConversationRepository
    private let audioCoordinator: LiveTranslationAudioCoordinator
    private var loadTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var volumePersistenceTask: Task<Void, Never>?
    private var persistenceGeneration: UInt = 0
    private var volumePersistenceGeneration: UInt = 0
    private var hasLocalChanges = false
    private var persistenceNeedsFlush = false
    private var provisionalConversationID: LiveConversation.ID?
    private var incomingStartTask: Task<Void, Never>?
    private var outgoingStartTask: Task<Void, Never>?
    private var incomingStartGeneration: UInt = 0
    private var outgoingStartGeneration: UInt = 0
    private var wantsIncomingTranslation = false
    private var wantsOutgoingTranslation = false
    private var hasStartedBypass = false
    private var incomingAssembler = LiveTranscriptTurnAssembler(speaker: .other)
    private var outgoingAssembler = LiveTranscriptTurnAssembler(speaker: .me)
    private let outgoingDraftKaraokeID = LiveConversationMessage.ID()
    private var incomingTranscriptRoute = LiveTranscriptLanguageRoute(sourceLanguageCode: "en", targetLanguageCode: "ko")
    private var outgoingTranscriptRoute = LiveTranscriptLanguageRoute(sourceLanguageCode: "ko", targetLanguageCode: "en")
    private var shouldResumeIncomingAfterOutgoing = false
    private var outgoingKaraokeSegments: [LiveKaraokeSegment] = []
    private var pendingOutgoingPlaybackDuration: TimeInterval = 0
    private var lastOutgoingPlaybackDuration: TimeInterval = 0
    private var lastOutgoingBufferedDuration: TimeInterval = 0
    private var lastOutgoingEnqueuedDuration: TimeInterval = 0
    private var lastPlaybackKaraokeAdvanceDate = Date.distantPast
    private var outgoingTurnPlaybackStartDuration: TimeInterval?
    private var outgoingKaraokeTrackedTexts: [LiveConversationMessage.ID: String] = [:]
    private var outgoingTurnDidComplete = false
    private var outgoingKaraokeFallbackTask: Task<Void, Never>?

    init(
        store: LiveConversationStoring = FileLiveConversationStore(),
        audioCoordinator: LiveTranslationAudioCoordinator? = nil
    ) {
        self.repository = LiveConversationRepository(store: store)
        self.audioCoordinator = audioCoordinator ?? LiveTranslationAudioCoordinator()
        self.listenerVolume = UserDefaults.standard.object(forKey: PreferenceKeys.liveListenerVolume) as? Double ?? 1.0
        let provisionalConversation = LiveConversation(title: "Teams 회의")
        self.conversations = [provisionalConversation]
        self.selectedConversationID = provisionalConversation.id
        self.provisionalConversationID = provisionalConversation.id
        configureCoordinator()
        updateTranscriptRoutes(settings: settingsSnapshot())
        loadConversations()
        PendingPersistenceRegistry.shared.registerPreparation { [weak self] in
            self?.stopLiveActivity()
        }
        PendingPersistenceRegistry.shared.register { [weak self] in
            await self?.flushPendingPersistence()
        }
    }

    deinit {
        loadTask?.cancel()
        incomingStartTask?.cancel()
        outgoingStartTask?.cancel()
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

    func disappear() {
        stopLiveActivity()
    }

    func newConversation() {
        discardUnusedProvisionalConversation()
        let nextIndex = conversations.count + 1
        let conversation = LiveConversation(title: "새 대화 \(nextIndex)")
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        resetDrafts()
        resetOutgoingKaraoke(clearHighlights: true)
        persist(status: "새 대화를 만들었습니다.")
    }

    func deleteSelectedConversation() {
        guard let index = selectedConversationIndex,
              conversations.indices.contains(index)
        else {
            statusMessage = "삭제할 대화를 선택해 주세요."
            return
        }

        let deletedTitle = conversations[index].title
        stopLiveActivity()
        conversations.remove(at: index)

        if conversations.isEmpty {
            let replacement = LiveConversation(title: "새 대화")
            conversations = [replacement]
            selectedConversationID = replacement.id
            provisionalConversationID = replacement.id
        } else {
            let nextIndex = min(index, conversations.count - 1)
            selectedConversationID = conversations[nextIndex].id
            provisionalConversationID = nil
        }

        resetDrafts()
        resetOutgoingKaraoke(clearHighlights: true)
        persist(status: "'\(deletedTitle)' 대화를 삭제했습니다.")
        statusMessage = "'\(deletedTitle)' 대화를 삭제했습니다."
    }

    func saveSelectedConversationCSV(to url: URL) {
        guard let conversation = selectedConversation else {
            statusMessage = "저장할 대화를 선택해 주세요."
            return
        }

        do {
            try LiveConversationCSVExporter.write(conversation, to: url)
            statusMessage = "대화를 CSV 파일로 저장했습니다: \(url.lastPathComponent)"
        } catch {
            statusMessage = "대화 CSV 저장에 실패했습니다: \(error.localizedDescription)"
        }
    }

    private func stopLiveActivity() {
        if !incomingDraft.isEmpty {
            finishDraft(direction: .incoming)
        }
        if !outgoingDraft.isEmpty {
            finishDraft(direction: .outgoing)
        }

        hasStartedBypass = false
        wantsIncomingTranslation = false
        wantsOutgoingTranslation = false
        shouldResumeIncomingAfterOutgoing = false
        incomingStartTask?.cancel()
        incomingStartTask = nil
        outgoingStartTask?.cancel()
        outgoingStartTask = nil
        incomingStartGeneration &+= 1
        outgoingStartGeneration &+= 1
        isOnAir = false
        isMicrophoneTranslationEnabled = false
        audioCoordinator.stopAll()
        resetOutgoingKaraoke(clearHighlights: false)
        statusMessage = "Live 번역 대기 중"
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
        persist(status: "대화방 이름을 저장했습니다.", delayNanoseconds: 350_000_000)
    }

    func setOnAir(_ enabled: Bool) {
        wantsIncomingTranslation = enabled
        if enabled {
            beginIncomingTranslation()
        } else {
            incomingStartTask?.cancel()
            incomingStartTask = nil
            incomingStartGeneration &+= 1
            isOnAir = false
            shouldResumeIncomingAfterOutgoing = false
            audioCoordinator.stopIncomingTranslation()
            startSpeakerBypass()
        }
    }

    func toggleIncomingTranslation() {
        setOnAir(!wantsIncomingTranslation)
    }

    func setMicrophoneTranslationEnabled(_ enabled: Bool) {
        wantsOutgoingTranslation = enabled
        if enabled {
            beginOutgoingTranslation()
        } else {
            outgoingStartTask?.cancel()
            outgoingStartTask = nil
            outgoingStartGeneration &+= 1
            isMicrophoneTranslationEnabled = false
            audioCoordinator.stopOutgoingTranslation()
            resetOutgoingKaraoke(clearHighlights: false)
            startMicBypass()
            resumeIncomingAfterOutgoingIfNeeded()
        }
    }

    func toggleOutgoingTranslation() {
        setMicrophoneTranslationEnabled(!wantsOutgoingTranslation)
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
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self, repository] in
            do {
                let snapshot = try await repository.load()
                guard let self,
                      !Task.isCancelled
                else {
                    return
                }

                if self.hasLocalChanges {
                    self.discardUnusedProvisionalConversation()
                    let localIDs = Set(self.conversations.map(\.id))
                    self.conversations.append(
                        contentsOf: snapshot.conversations.filter { !localIDs.contains($0.id) }
                    )
                    if self.selectedConversationID == nil {
                        self.selectedConversationID = snapshot.selectedConversationID ?? self.conversations.first?.id
                    }
                    self.provisionalConversationID = nil
                    self.persist(status: "Live 번역 준비 완료")
                } else if snapshot.conversations.isEmpty {
                    if self.conversations.isEmpty {
                        self.conversations = [LiveConversation(title: "Teams 회의")]
                    }
                    self.selectedConversationID = self.conversations.first?.id
                    self.provisionalConversationID = nil
                    self.persist(status: "Live 번역 준비 완료")
                } else {
                    self.conversations = snapshot.conversations
                    self.selectedConversationID = snapshot.selectedConversationID ?? self.conversations.first?.id
                    self.provisionalConversationID = nil
                    self.statusMessage = "Live 번역 준비 완료"
                }
                self.loadTask = nil
            } catch {
                guard let self,
                      !Task.isCancelled
                else {
                    return
                }
                if self.hasLocalChanges {
                    self.statusMessage = "기존 Live 대화 기록을 불러오지 못해 현재 대화만 유지합니다: \(error.localizedDescription)"
                    self.loadTask = nil
                    return
                }
                if self.conversations.isEmpty {
                    self.conversations = [LiveConversation(title: "Teams 회의")]
                }
                self.selectedConversationID = self.conversations.first?.id
                self.provisionalConversationID = nil
                self.statusMessage = "Live 대화 기록을 불러오지 못했습니다: \(error.localizedDescription)"
                self.loadTask = nil
            }
        }
    }

    private func discardUnusedProvisionalConversation() {
        guard let provisionalConversationID,
              let index = conversations.firstIndex(where: { $0.id == provisionalConversationID })
        else {
            self.provisionalConversationID = nil
            return
        }

        let conversation = conversations[index]
        if conversation.title == "Teams 회의", conversation.messages.isEmpty {
            conversations.remove(at: index)
            if selectedConversationID == provisionalConversationID {
                selectedConversationID = nil
            }
        }
        self.provisionalConversationID = nil
    }

    private func startDefaultBypass() {
        startSpeakerBypass()
        startMicBypass()
    }

    private func startSpeakerBypass(
        statusOnSuccess: String = "스피커 By Pass",
        failurePrefix: String = "스피커 By Pass 실패"
    ) {
        do {
            try audioCoordinator.startSpeakerBypass(settings: settingsSnapshot())
            statusMessage = statusOnSuccess
        } catch {
            statusMessage = "\(failurePrefix): \(Self.userFacingErrorMessage(error))"
        }
    }

    private func startMicBypass(
        statusOnSuccess: String = "마이크 By Pass",
        failurePrefix: String = "마이크 By Pass 실패"
    ) {
        do {
            try audioCoordinator.startMicBypass(settings: settingsSnapshot())
            statusMessage = statusOnSuccess
        } catch {
            statusMessage = "\(failurePrefix): \(Self.userFacingErrorMessage(error))"
        }
    }

    private func beginIncomingTranslation() {
        incomingStartTask?.cancel()
        incomingStartGeneration &+= 1
        let generation = incomingStartGeneration
        incomingStartTask = Task { @MainActor [weak self] in
            await self?.startIncomingTranslation(generation: generation)
        }
    }

    private func beginOutgoingTranslation() {
        outgoingStartTask?.cancel()
        outgoingStartGeneration &+= 1
        let generation = outgoingStartGeneration
        outgoingStartTask = Task { @MainActor [weak self] in
            await self?.startOutgoingTranslation(generation: generation)
        }
    }

    private func startIncomingTranslation(generation: UInt) async {
        guard wantsIncomingTranslation,
              generation == incomingStartGeneration,
              !Task.isCancelled
        else {
            return
        }

        let settings = settingsSnapshot()
        guard !settings.listeningCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "수화용 Gemini Live API 키를 설정해 주세요."
            wantsIncomingTranslation = false
            incomingStartTask = nil
            return
        }

        do {
            statusMessage = "On Air 연결 중"
            updateTranscriptRoutes(settings: settings)
            resetAssembler(for: .incoming)
            try await audioCoordinator.startIncomingTranslation(settings: settings)
            guard wantsIncomingTranslation,
                  generation == incomingStartGeneration,
                  !Task.isCancelled
            else {
                return
            }
            isOnAir = true
            statusMessage = "On Air"
            incomingStartTask = nil
        } catch is CancellationError {
            return
        } catch {
            guard wantsIncomingTranslation,
                  generation == incomingStartGeneration
            else {
                return
            }
            wantsIncomingTranslation = false
            isOnAir = false
            let failureMessage = "On Air 실패: \(Self.userFacingErrorMessage(error))"
            startSpeakerBypass(
                statusOnSuccess: "\(failureMessage) · 스피커 By Pass로 복귀",
                failurePrefix: "\(failureMessage) · 스피커 By Pass 실패"
            )
            incomingStartTask = nil
        }
    }

    private func startOutgoingTranslation(generation: UInt) async {
        guard wantsOutgoingTranslation,
              generation == outgoingStartGeneration,
              !Task.isCancelled
        else {
            return
        }

        let settings = settingsSnapshot()
        guard !settings.speakingCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "발화용 Gemini Live API 키를 설정해 주세요."
            wantsOutgoingTranslation = false
            outgoingStartTask = nil
            return
        }

        do {
            statusMessage = "마이크 통역 연결 중"
            updateTranscriptRoutes(settings: settings)
            resetAssembler(for: .outgoing)
            resetOutgoingKaraoke(clearHighlights: false)
            pauseIncomingForOutgoingIfNeeded(settings: settings)
            try await audioCoordinator.startOutgoingTranslation(settings: settings)
            guard wantsOutgoingTranslation,
                  generation == outgoingStartGeneration,
                  !Task.isCancelled
            else {
                return
            }
            isMicrophoneTranslationEnabled = true
            statusMessage = "마이크 통역 중"
            outgoingStartTask = nil
        } catch is CancellationError {
            return
        } catch {
            guard wantsOutgoingTranslation,
                  generation == outgoingStartGeneration
            else {
                return
            }
            wantsOutgoingTranslation = false
            isMicrophoneTranslationEnabled = false
            let failureMessage = "마이크 통역 실패: \(Self.userFacingErrorMessage(error))"
            startMicBypass(
                statusOnSuccess: "\(failureMessage) · 마이크 By Pass로 복귀",
                failurePrefix: "\(failureMessage) · 마이크 By Pass 실패"
            )
            resumeIncomingAfterOutgoingIfNeeded()
            outgoingStartTask = nil
        }
    }

    private static func userFacingErrorMessage(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }
        return error.localizedDescription
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
            pauseRemoteInputOnStart: settings.pauseRemoteInputOnStart,
            listenerVolume: listenerVolume
        )
        return settings
    }

    private func pauseIncomingForOutgoingIfNeeded(settings: LiveTranslationAudioSettings) {
        guard settings.pauseRemoteInputOnStart,
              isOnAir
        else {
            return
        }

        incomingStartTask?.cancel()
        incomingStartTask = nil
        incomingStartGeneration &+= 1
        audioCoordinator.stopIncomingTranslation()
        isOnAir = false
        shouldResumeIncomingAfterOutgoing = true
    }

    private func resumeIncomingAfterOutgoingIfNeeded() {
        guard shouldResumeIncomingAfterOutgoing else {
            return
        }

        shouldResumeIncomingAfterOutgoing = false
        guard wantsIncomingTranslation else {
            return
        }
        beginIncomingTranslation()
    }

    private func normalizedLanguageCode(_ code: String, fallback: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func updateTranscriptRoutes(settings: LiveTranslationAudioSettings) {
        incomingTranscriptRoute = LiveTranscriptLanguageRoute(
            sourceLanguageCode: settings.localTargetLanguage,
            targetLanguageCode: settings.remoteTargetLanguage
        )
        outgoingTranscriptRoute = LiveTranscriptLanguageRoute(
            sourceLanguageCode: settings.remoteTargetLanguage,
            targetLanguageCode: settings.localTargetLanguage
        )
    }

    private func handle(event: GeminiLiveTranslationEvent, direction: LiveTranslationAudioDirection) {
        switch event {
        case .inputTranscript(let text, let languageCode):
            if direction == .outgoing {
                markOutgoingTurnActive()
            }
            updateDraft(
                direction: direction,
                field: .original,
                text: text,
                languageCode: languageCode
            )
        case .outputTranscript(let text, let languageCode):
            if direction == .outgoing {
                markOutgoingTurnActive()
            }
            updateDraft(
                direction: direction,
                field: .translation,
                text: text,
                languageCode: languageCode
            )
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
            handleConnectionFailure(message, direction: direction)
        case .setupComplete, .audio:
            break
        }
    }

    private func handleConnectionFailure(
        _ message: String,
        direction: LiveTranslationAudioDirection
    ) {
        let failureMessage = "Live API 오류: \(message)"
        switch direction {
        case .incoming:
            wantsIncomingTranslation = false
            incomingStartTask?.cancel()
            incomingStartTask = nil
            incomingStartGeneration &+= 1
            isOnAir = false
            shouldResumeIncomingAfterOutgoing = false
            audioCoordinator.stopIncomingTranslation()
            startSpeakerBypass(
                statusOnSuccess: "\(failureMessage) · 스피커 By Pass로 복귀",
                failurePrefix: "\(failureMessage) · 스피커 By Pass 실패"
            )
        case .outgoing:
            wantsOutgoingTranslation = false
            outgoingStartTask?.cancel()
            outgoingStartTask = nil
            outgoingStartGeneration &+= 1
            isMicrophoneTranslationEnabled = false
            audioCoordinator.stopOutgoingTranslation()
            resetOutgoingKaraoke(clearHighlights: false)
            startMicBypass(
                statusOnSuccess: "\(failureMessage) · 마이크 By Pass로 복귀",
                failurePrefix: "\(failureMessage) · 마이크 By Pass 실패"
            )
            resumeIncomingAfterOutgoingIfNeeded()
        }
    }

    private enum DraftField {
        case original
        case translation
    }

    private enum KaraokeAdvanceSource {
        case playback
        case fallback
    }

    private func updateDraft(
        direction: LiveTranslationAudioDirection,
        field: DraftField,
        text: String,
        languageCode: String?
    ) {
        let speaker: LiveConversationSpeaker = direction == .incoming ? .other : .me
        let assemblyField = assemblyField(for: field)
        guard LiveTranscriptLanguageFilter.accepts(
            field: assemblyField,
            text: text,
            languageCode: languageCode,
            route: transcriptRoute(for: direction)
        ) else {
            return
        }

        let changes: [LiveTranscriptAssemblyChange]

        if speaker == .other {
            changes = incomingAssembler.update(field: assemblyField, text: text)
            incomingDraft = LiveTranscriptDraft(incomingAssembler.draft)
        } else {
            changes = outgoingAssembler.update(field: assemblyField, text: text)
            outgoingDraft = LiveTranscriptDraft(outgoingAssembler.draft)
            if assemblyField == .translation {
                enqueueOutgoingDraftKaraokeIfNeeded()
            }
        }

        applyAssemblyChanges(changes)
    }

    private func transcriptRoute(for direction: LiveTranslationAudioDirection) -> LiveTranscriptLanguageRoute {
        direction == .incoming ? incomingTranscriptRoute : outgoingTranscriptRoute
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
        resetOutgoingDraftKaraoke()
    }

    private func resetAssembler(for direction: LiveTranslationAudioDirection) {
        if direction == .incoming {
            incomingAssembler.reset()
            incomingDraft.reset()
        } else {
            outgoingAssembler.reset()
            outgoingDraft.reset()
            resetOutgoingDraftKaraoke()
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
        persist(status: "대화를 기록했습니다.", delayNanoseconds: 200_000_000)
    }

    private func updateKaraokeTrackingIfNeeded(for message: LiveConversationMessage) {
        guard message.speaker == .me else {
            return
        }
        transferOutgoingDraftKaraokeIfNeeded(to: message)
        enqueueOutgoingKaraokeSegment(messageID: message.id, text: message.translatedText)
    }

    private func enqueueOutgoingDraftKaraokeIfNeeded() {
        enqueueOutgoingKaraokeSegment(
            messageID: outgoingDraftKaraokeID,
            text: outgoingDraft.translatedText
        )
    }

    private func transferOutgoingDraftKaraokeIfNeeded(to message: LiveConversationMessage) {
        let draftText = outgoingKaraokeTrackedTexts[outgoingDraftKaraokeID] ?? ""
        guard !draftText.isEmpty,
              !message.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        let messageText = message.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard messageText == draftText || draftText.hasPrefix(messageText) || messageText.hasPrefix(draftText) else {
            return
        }

        outgoingKaraokeTrackedTexts[message.id] = String(draftText.prefix(messageText.count))
        setOutgoingKaraokeHighlight(
            for: message.id,
            to: min(outgoingDraftKaraokeHighlightedCharacters ?? 0, messageText.count)
        )

        for index in outgoingKaraokeSegments.indices where outgoingKaraokeSegments[index].messageID == outgoingDraftKaraokeID {
            outgoingKaraokeSegments[index].messageID = message.id
        }

        resetOutgoingDraftKaraoke()
    }

    private func setOutgoingKaraokeHighlight(
        for messageID: LiveConversationMessage.ID,
        to highlightedCharacters: Int
    ) {
        let clamped = max(0, highlightedCharacters)
        if messageID == outgoingDraftKaraokeID {
            outgoingDraftKaraokeHighlightedCharacters = clamped
        } else {
            karaokeHighlights[messageID] = clamped
        }
    }

    private func currentOutgoingKaraokeHighlight(for messageID: LiveConversationMessage.ID) -> Int {
        if messageID == outgoingDraftKaraokeID {
            return outgoingDraftKaraokeHighlightedCharacters ?? 0
        }
        return karaokeHighlights[messageID] ?? 0
    }

    private func resetOutgoingDraftKaraoke() {
        outgoingDraftKaraokeHighlightedCharacters = nil
        outgoingKaraokeTrackedTexts.removeValue(forKey: outgoingDraftKaraokeID)
        outgoingKaraokeSegments.removeAll { $0.messageID == outgoingDraftKaraokeID }
    }

    private func handlePlaybackProgress(
        _ progress: LiveAudioPlaybackProgress,
        direction: LiveTranslationAudioDirection
    ) {
        guard direction == .outgoing else {
            return
        }

        lastOutgoingBufferedDuration = progress.bufferedDuration
        lastOutgoingEnqueuedDuration = progress.enqueuedDuration
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
            advanceOutgoingKaraoke(by: delta, source: .playback)
        }

        if progress.isDrained && outgoingTurnDidComplete {
            startOutgoingKaraokeFallbackIfNeeded()
        }
    }

    private func markOutgoingTurnActive() {
        if outgoingTurnPlaybackStartDuration == nil {
            outgoingTurnPlaybackStartDuration = max(0, lastOutgoingPlaybackDuration - pendingOutgoingPlaybackDuration)
        }
        outgoingTurnDidComplete = false
    }

    private func markOutgoingTurnComplete() {
        outgoingTurnDidComplete = true
        retimeOutgoingKaraokeSegmentsToCurrentAudio()
        startOutgoingKaraokeFallbackIfNeeded()
    }

    private func enqueueOutgoingKaraokeSegment(messageID: LiveConversationMessage.ID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let plan = LiveKaraokeTimeline.cuePlan(
            previousText: outgoingKaraokeTrackedTexts[messageID] ?? "",
            updatedText: trimmed,
            currentHighlight: currentOutgoingKaraokeHighlight(for: messageID)
        )

        if plan.shouldResetQueuedCues {
            outgoingKaraokeSegments.removeAll { $0.messageID == messageID }
        }

        outgoingKaraokeTrackedTexts[messageID] = plan.trackedText
        setOutgoingKaraokeHighlight(for: messageID, to: plan.preservedHighlight)

        if let cue = plan.cue {
            outgoingKaraokeSegments.append(
                LiveKaraokeSegment(
                    messageID: messageID,
                    startCharacter: cue.startCharacter,
                    text: cue.text,
                    highlightedCharacters: 0,
                    elapsedDuration: 0,
                    allocatedDuration: LiveKaraokeTimeline.estimatedSpeechDuration(for: cue.text)
                )
            )
        }

        if pendingOutgoingPlaybackDuration > 0 {
            let pendingDuration = pendingOutgoingPlaybackDuration
            pendingOutgoingPlaybackDuration = 0
            advanceOutgoingKaraoke(by: pendingDuration, source: .playback)
        }
        startOutgoingKaraokeFallbackIfNeeded()
    }

    private func advanceOutgoingKaraoke(
        by duration: TimeInterval,
        source: KaraokeAdvanceSource
    ) {
        if source == .playback {
            lastPlaybackKaraokeAdvanceDate = Date()
        }

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
                setOutgoingKaraokeHighlight(for: segment.messageID, to: segment.endCharacter)
                outgoingKaraokeSegments.removeFirst()
                continue
            }

            let remainingSegmentDuration = max(0, segment.allocatedDuration - segment.elapsedDuration)
            guard remainingSegmentDuration > 0 else {
                segment.highlightedCharacters = totalCharacters
                setOutgoingKaraokeHighlight(for: segment.messageID, to: segment.endCharacter)
                outgoingKaraokeSegments.removeFirst()
                continue
            }

            let consumedDuration = min(remainingDuration, remainingSegmentDuration)
            segment.elapsedDuration += consumedDuration
            segment.highlightedCharacters = max(
                segment.highlightedCharacters,
                LiveKaraokeTimeline.highlightedCharacters(
                    in: segment.text,
                    elapsedDuration: segment.elapsedDuration,
                    totalDuration: segment.allocatedDuration
                )
            )
            setOutgoingKaraokeHighlight(
                for: segment.messageID,
                to: segment.startCharacter + segment.highlightedCharacters
            )
            consumedTextInThisAdvance = true
            remainingDuration = max(0, remainingDuration - consumedDuration)

            if segment.highlightedCharacters >= totalCharacters
                || segment.elapsedDuration >= segment.allocatedDuration {
                setOutgoingKaraokeHighlight(for: segment.messageID, to: segment.endCharacter)
                outgoingKaraokeSegments.removeFirst()
            } else {
                outgoingKaraokeSegments[0] = segment
                return
            }
        }
    }

    private func retimeOutgoingKaraokeSegmentsToCurrentAudio() {
        guard !outgoingKaraokeSegments.isEmpty else {
            return
        }

        let turnStart = outgoingTurnPlaybackStartDuration
            ?? max(0, lastOutgoingPlaybackDuration - pendingOutgoingPlaybackDuration)
        let totalAudioDuration = max(0, lastOutgoingEnqueuedDuration - turnStart)
        let playedAudioDuration = max(0, lastOutgoingPlaybackDuration - turnStart)
        let remainingAudioDuration = max(0, totalAudioDuration - playedAudioDuration)
        guard remainingAudioDuration > 0.05 else {
            return
        }

        let weights = outgoingKaraokeSegments.map { segment in
            max(
                1.0,
                LiveKaraokeTimeline.speechWeight(for: String(segment.text.dropFirst(segment.highlightedCharacters)))
            )
        }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else {
            return
        }

        for index in outgoingKaraokeSegments.indices {
            let remainingSegmentDuration = max(0.08, remainingAudioDuration * weights[index] / totalWeight)
            outgoingKaraokeSegments[index].allocatedDuration =
            outgoingKaraokeSegments[index].elapsedDuration + remainingSegmentDuration
        }
    }

    private func startOutgoingKaraokeFallbackIfNeeded() {
        guard outgoingKaraokeFallbackTask == nil,
              !outgoingKaraokeSegments.isEmpty
        else {
            return
        }

        outgoingKaraokeFallbackTask = Task { @MainActor [weak self] in
            var lastTick = Date()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self,
                      !Task.isCancelled,
                      !self.outgoingKaraokeSegments.isEmpty
                else {
                    break
                }

                let now = Date()
                let elapsed = min(0.12, max(0, now.timeIntervalSince(lastTick)))
                lastTick = now

                if now.timeIntervalSince(self.lastPlaybackKaraokeAdvanceDate) > 0.18 {
                    self.advanceOutgoingKaraoke(by: elapsed, source: .fallback)
                }
            }

            self?.outgoingKaraokeFallbackTask = nil
        }
    }

    private func cancelOutgoingKaraokeFallback() {
        outgoingKaraokeFallbackTask?.cancel()
        outgoingKaraokeFallbackTask = nil
    }

    private func completeOutgoingKaraokeQueue() {
        for segment in outgoingKaraokeSegments {
            setOutgoingKaraokeHighlight(for: segment.messageID, to: segment.endCharacter)
        }
        outgoingKaraokeSegments.removeAll()
        pendingOutgoingPlaybackDuration = 0
        outgoingTurnPlaybackStartDuration = nil
        outgoingTurnDidComplete = false
        cancelOutgoingKaraokeFallback()
    }

    private func resetOutgoingKaraoke(clearHighlights: Bool) {
        cancelOutgoingKaraokeFallback()
        outgoingKaraokeSegments.removeAll()
        pendingOutgoingPlaybackDuration = 0
        lastOutgoingPlaybackDuration = 0
        lastOutgoingBufferedDuration = 0
        lastOutgoingEnqueuedDuration = 0
        lastPlaybackKaraokeAdvanceDate = Date.distantPast
        outgoingTurnPlaybackStartDuration = nil
        outgoingDraftKaraokeHighlightedCharacters = nil
        outgoingKaraokeTrackedTexts.removeAll()
        outgoingTurnDidComplete = false
        if clearHighlights {
            karaokeHighlights = [:]
        }
    }

    private func persist(status _: String, delayNanoseconds: UInt64 = 120_000_000) {
        hasLocalChanges = true
        persistenceNeedsFlush = true
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        let snapshot = LiveConversationSnapshot(
            conversations: conversations,
            selectedConversationID: selectedConversationID
        )

        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self, repository] in
            do {
                if delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
                try Task.checkCancellation()
                try await repository.save(snapshot)
                guard let self,
                      !Task.isCancelled,
                      self.persistenceGeneration == generation
                else {
                    return
                }
                self.persistenceNeedsFlush = false
                self.persistenceTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.persistenceGeneration == generation
                else {
                    return
                }
                self.statusMessage = "Live 대화 기록 저장 실패: \(error.localizedDescription)"
                self.persistenceTask = nil
            }
        }
    }

    private func scheduleListenerVolumePersistence() {
        let volume = listenerVolume
        volumePersistenceGeneration &+= 1
        let generation = volumePersistenceGeneration
        volumePersistenceTask?.cancel()
        volumePersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                try Task.checkCancellation()
                UserDefaults.standard.set(volume, forKey: PreferenceKeys.liveListenerVolume)
                guard let self,
                      self.volumePersistenceGeneration == generation
                else {
                    return
                }
                self.volumePersistenceTask = nil
            } catch {
                return
            }
        }
    }

    private func flushPendingPersistence() async {
        if let loadTask {
            await loadTask.value
        }

        while persistenceNeedsFlush {
            let generation = persistenceGeneration
            let pendingTask = persistenceTask
            pendingTask?.cancel()
            if let pendingTask {
                await pendingTask.value
            }

            let snapshot = LiveConversationSnapshot(
                conversations: conversations,
                selectedConversationID: selectedConversationID
            )
            do {
                try await repository.save(snapshot)
            } catch {
                statusMessage = "Live 대화 기록 저장 실패: \(error.localizedDescription)"
                return
            }

            guard persistenceGeneration == generation else {
                continue
            }
            persistenceNeedsFlush = false
            persistenceTask = nil
        }

        while let pendingTask = volumePersistenceTask {
            let generation = volumePersistenceGeneration
            pendingTask.cancel()
            await pendingTask.value
            UserDefaults.standard.set(listenerVolume, forKey: PreferenceKeys.liveListenerVolume)
            guard volumePersistenceGeneration == generation else {
                continue
            }
            volumePersistenceTask = nil
        }
    }
}

private actor LiveConversationRepository {
    private let store: any LiveConversationStoring

    init(store: any LiveConversationStoring) {
        self.store = store
    }

    func load() throws -> LiveConversationSnapshot {
        try store.load()
    }

    func save(_ snapshot: LiveConversationSnapshot) throws {
        try store.save(snapshot)
    }
}
