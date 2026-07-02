import XCTest
@testable import KCDeepLCore

final class TranslationPromptBuilderTests: XCTestCase {
    func testPromptPreservesLanguageIntent() {
        let request = TranslationRequest(
            sourceText: "Hello, world.",
            sourceLanguage: .english,
            targetLanguage: .korean,
            provider: .gemini,
            modelID: AppDefaults.defaultModelID,
            apiKey: AppDefaults.defaultGeminiAPIKey
        )

        let prompt = TranslationPromptBuilder.prompt(for: request)

        XCTAssertTrue(prompt.contains("영어"))
        XCTAssertTrue(prompt.contains("한국어"))
        XCTAssertTrue(prompt.contains("Return only the translated text"))
        XCTAssertTrue(prompt.contains("Preserve Markdown or HTML-like formatting markers"))
        XCTAssertTrue(prompt.contains("Hello, world."))
    }

    func testRegisteredDefaultsMatchRequestedGeminiConfiguration() {
        let defaults = UserDefaults(suiteName: "KCDeepLCoreTests-\(UUID().uuidString)")!
        defaults.registerKCDeepLDefaults()

        XCTAssertEqual(defaults.string(forKey: PreferenceKeys.provider), LLMProvider.gemini.rawValue)
        XCTAssertEqual(defaults.string(forKey: PreferenceKeys.modelID), "gemini-2.5-flash-lite")
        XCTAssertEqual(defaults.string(forKey: PreferenceKeys.geminiAPIKey), AppDefaults.defaultGeminiAPIKey)
        XCTAssertTrue(defaults.bool(forKey: PreferenceKeys.autoTranslate))
        XCTAssertEqual(defaults.string(forKey: PreferenceKeys.liveProvider), LLMProvider.gemini.rawValue)
        XCTAssertEqual(defaults.string(forKey: PreferenceKeys.liveModelID), AppDefaults.defaultLiveModelID)
        XCTAssertEqual(defaults.string(forKey: PreferenceKeys.liveListeningAPIKey), AppDefaults.defaultLiveListeningAPIKey)
        XCTAssertEqual(defaults.string(forKey: PreferenceKeys.liveSpeakingAPIKey), AppDefaults.defaultGeminiAPIKey)
        XCTAssertEqual(defaults.string(forKey: PreferenceKeys.liveRemoteMicInput), "2: BlackHole 2ch (2ch, 48000Hz)")
        XCTAssertEqual(defaults.string(forKey: PreferenceKeys.liveRemoteTargetLanguage), "ko")
        XCTAssertTrue(defaults.bool(forKey: PreferenceKeys.livePauseRemoteInputOnStart))
        XCTAssertEqual(defaults.double(forKey: PreferenceKeys.liveListenerVolume), 1.0)
    }
}
