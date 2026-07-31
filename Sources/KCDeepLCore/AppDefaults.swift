import Foundation

public enum PreferenceKeys {
    public static let mainSourceLanguage = "kc.main.sourceLanguage"
    public static let mainTargetLanguage = "kc.main.targetLanguage"
    public static let launchAtLogin = "kc.general.launchAtLogin"
    public static let quickAccessMode = "kc.general.quickAccessMode"
    public static let closeBehavior = "kc.general.closeBehavior"
    public static let selectedTextShortcut = "kc.shortcuts.selectedText"
    public static let rewriteShortcut = "kc.shortcuts.rewriteText"
    public static let screenCaptureShortcut = "kc.shortcuts.screenCapture"
    public static let readingFontSize = "kc.accessibility.readingFontSize"
    public static let speechSpeed = "kc.accessibility.speechSpeed"
    public static let downloadLocation = "kc.files.downloadLocation"
    public static let historyEnabled = "kc.files.historyEnabled"
    public static let fileTranslationEngine = "kc.files.translationEngine"
    public static let fileAPIModelID = "kc.files.apiModelID"
    public static let translationBackend = "kc.advanced.translationBackend"
    public static let provider = "kc.advanced.provider"
    public static let modelID = "kc.advanced.modelID"
    public static let codexModelID = "kc.advanced.codexModelID"
    public static let codexThreadID = "kc.advanced.codexThreadID"
    public static let geminiAPIKey = "kc.advanced.geminiAPIKey"
    public static let autoTranslate = "kc.advanced.autoTranslate"
    public static let temperature = "kc.advanced.temperature"
    public static let liveProvider = "kc.live.provider"
    public static let liveModelID = "kc.live.modelID"
    public static let liveListeningAPIKey = "kc.live.listeningAPIKey"
    public static let liveSpeakingAPIKey = "kc.live.speakingAPIKey"
    public static let liveRemoteMicInput = "kc.live.audio.remoteMicInput"
    public static let liveRemoteSpeakerOutput = "kc.live.audio.remoteSpeakerOutput"
    public static let liveLocalMicInput = "kc.live.audio.localMicInput"
    public static let liveLocalSpeakerOutput = "kc.live.audio.localSpeakerOutput"
    public static let liveLocalTargetLanguage = "kc.live.translation.localTargetLanguage"
    public static let liveRemoteTargetLanguage = "kc.live.translation.remoteTargetLanguage"
    public static let liveLocalTargetEcho = "kc.live.translation.localTargetEcho"
    public static let liveRemoteTargetEcho = "kc.live.translation.remoteTargetEcho"
    public static let livePauseRemoteInputOnStart = "kc.live.translation.pauseRemoteInputOnStart"
    public static let liveListenerVolume = "kc.live.audio.listenerVolume"
}

public enum AppDefaults {
    public static let defaultTranslationBackend = TranslationBackend.llmAPI
    public static let defaultProvider = LLMProvider.gemini
    public static let defaultModelID = "gemini-2.5-flash-lite"
    public static let defaultCodexModelID = ""
    public static let defaultGeminiAPIKey = ""
    public static let defaultFileTranslationEngine = FileTranslationEngine.apple
    public static let defaultFileAPIModelID = defaultModelID
    public static let defaultLiveModelID = "gemini-3.5-live-translate-preview"
    public static let defaultLiveListeningAPIKey = ""

    fileprivate static let legacyLiveAudioDeviceSelections = [
        "1: BlackHole 16ch (16ch, 48000Hz)",
        "2: BlackHole 2ch (2ch, 48000Hz)",
        "3: MacBook Pro 마이크 (1ch, 48000Hz)",
        "4: MacBook Pro 스피커 (2ch, 48000Hz)"
    ]
}

public extension UserDefaults {
    func registerKCDeepLDefaults() {
        register(defaults: [
            PreferenceKeys.mainSourceLanguage: LanguageOption.english.code,
            PreferenceKeys.mainTargetLanguage: LanguageOption.korean.code,
            PreferenceKeys.launchAtLogin: true,
            PreferenceKeys.quickAccessMode: "floating",
            PreferenceKeys.closeBehavior: "background",
            PreferenceKeys.selectedTextShortcut: "⌃⇧1",
            PreferenceKeys.rewriteShortcut: "⌃⇧2",
            PreferenceKeys.screenCaptureShortcut: "⌃⇧3",
            PreferenceKeys.readingFontSize: ReadingFontSize.defaultValue.rawValue,
            PreferenceKeys.speechSpeed: "1.0",
            PreferenceKeys.downloadLocation: "desktop",
            PreferenceKeys.historyEnabled: true,
            PreferenceKeys.fileTranslationEngine: AppDefaults.defaultFileTranslationEngine.rawValue,
            PreferenceKeys.fileAPIModelID: AppDefaults.defaultFileAPIModelID,
            PreferenceKeys.translationBackend: AppDefaults.defaultTranslationBackend.rawValue,
            PreferenceKeys.provider: AppDefaults.defaultProvider.rawValue,
            PreferenceKeys.modelID: AppDefaults.defaultModelID,
            PreferenceKeys.codexModelID: AppDefaults.defaultCodexModelID,
            PreferenceKeys.autoTranslate: true,
            PreferenceKeys.temperature: 0.2,
            PreferenceKeys.liveProvider: AppDefaults.defaultProvider.rawValue,
            PreferenceKeys.liveModelID: AppDefaults.defaultLiveModelID,
            PreferenceKeys.liveRemoteMicInput: "",
            PreferenceKeys.liveRemoteSpeakerOutput: "",
            PreferenceKeys.liveLocalMicInput: "",
            PreferenceKeys.liveLocalSpeakerOutput: "",
            PreferenceKeys.liveLocalTargetLanguage: "en",
            PreferenceKeys.liveRemoteTargetLanguage: "ko",
            PreferenceKeys.liveLocalTargetEcho: false,
            PreferenceKeys.liveRemoteTargetEcho: false,
            PreferenceKeys.livePauseRemoteInputOnStart: true,
            PreferenceKeys.liveListenerVolume: 1.0
        ])

        migrateLegacyLiveDefaults()
    }

    private func migrateLegacyLiveDefaults() {
        [
            PreferenceKeys.liveRemoteMicInput,
            PreferenceKeys.liveRemoteSpeakerOutput,
            PreferenceKeys.liveLocalMicInput,
            PreferenceKeys.liveLocalSpeakerOutput
        ].forEach { key in
            guard let value = string(forKey: key),
                  AppDefaults.legacyLiveAudioDeviceSelections.contains(value)
            else {
                return
            }
            removeObject(forKey: key)
        }
    }
}
