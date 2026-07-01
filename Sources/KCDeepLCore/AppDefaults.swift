import Foundation

public enum PreferenceKeys {
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
    public static let provider = "kc.advanced.provider"
    public static let modelID = "kc.advanced.modelID"
    public static let geminiAPIKey = "kc.advanced.geminiAPIKey"
    public static let autoTranslate = "kc.advanced.autoTranslate"
    public static let temperature = "kc.advanced.temperature"
}

public enum AppDefaults {
    public static let defaultProvider = LLMProvider.gemini
    public static let defaultModelID = "gemini-2.5-flash-lite"
    public static let defaultGeminiAPIKey = "[REDACTED-REMOVED]"
}

public extension UserDefaults {
    func registerKCDeepLDefaults() {
        register(defaults: [
            PreferenceKeys.launchAtLogin: true,
            PreferenceKeys.quickAccessMode: "floating",
            PreferenceKeys.closeBehavior: "background",
            PreferenceKeys.selectedTextShortcut: "⌃⇧1",
            PreferenceKeys.rewriteShortcut: "⌃⇧2",
            PreferenceKeys.screenCaptureShortcut: "⌃⇧3",
            PreferenceKeys.readingFontSize: "large",
            PreferenceKeys.speechSpeed: "1.0",
            PreferenceKeys.downloadLocation: "desktop",
            PreferenceKeys.historyEnabled: true,
            PreferenceKeys.provider: AppDefaults.defaultProvider.rawValue,
            PreferenceKeys.modelID: AppDefaults.defaultModelID,
            PreferenceKeys.geminiAPIKey: AppDefaults.defaultGeminiAPIKey,
            PreferenceKeys.autoTranslate: true,
            PreferenceKeys.temperature: 0.2
        ])
    }
}
