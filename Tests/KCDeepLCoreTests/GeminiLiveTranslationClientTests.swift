import XCTest
@testable import KCDeepLCore

final class GeminiLiveTranslationClientTests: XCTestCase {
    func testSetupMessageMatchesLiveTranslationContract() throws {
        let configuration = GeminiLiveTranslationConfiguration(
            modelID: AppDefaults.defaultLiveModelID,
            credential: GeminiLiveCredential(rawValue: "test-key"),
            targetLanguageCode: "ko",
            echoTargetLanguage: true
        )

        let data = try GeminiLiveTranslationMessageFactory.setupMessageData(configuration: configuration)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let setup = try XCTUnwrap(object["setup"] as? [String: Any])
        let generationConfig = try XCTUnwrap(setup["generationConfig"] as? [String: Any])
        let translationConfig = try XCTUnwrap(generationConfig["translationConfig"] as? [String: Any])

        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.5-live-translate-preview")
        XCTAssertEqual(generationConfig["responseModalities"] as? [String], ["AUDIO"])
        XCTAssertNil(generationConfig["inputAudioTranscription"])
        XCTAssertNil(generationConfig["outputAudioTranscription"])
        XCTAssertNotNil(setup["inputAudioTranscription"] as? [String: Any])
        XCTAssertNotNil(setup["outputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(translationConfig["targetLanguageCode"] as? String, "ko")
        XCTAssertEqual(translationConfig["echoTargetLanguage"] as? Bool, true)
    }

    func testAudioMessageUsesSixteenKilohertzPcmMimeType() throws {
        let pcm = Data([0x00, 0x01, 0x02, 0x03])
        let data = GeminiLiveTranslationMessageFactory.audioMessageData(pcm)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let realtimeInput = try XCTUnwrap(object["realtimeInput"] as? [String: Any])
        let audio = try XCTUnwrap(realtimeInput["audio"] as? [String: Any])

        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(audio["data"] as? String, pcm.base64EncodedString())
    }

    func testResponseParserExtractsTranscriptAudioAndTurnComplete() throws {
        let audio = Data([0x11, 0x22, 0x33])
        let json = """
        {
          "serverContent": {
            "inputTranscription": { "text": "hello", "languageCode": "en" },
            "outputTranscription": { "text": "안녕하세요", "languageCode": "ko" },
            "modelTurn": {
              "parts": [
                {
                  "inlineData": {
                    "mimeType": "audio/pcm;rate=24000",
                    "data": "\(audio.base64EncodedString())"
                  }
                }
              ]
            },
            "turnComplete": true
          }
        }
        """.data(using: .utf8)!

        let events = try GeminiLiveTranslationResponseParser.events(from: json)

        XCTAssertEqual(
            events,
            [
                .inputTranscript(text: "hello", languageCode: "en"),
                .outputTranscript(text: "안녕하세요", languageCode: "ko"),
                .audio(audio),
                .turnComplete
            ]
        )
    }

    func testResponseParserExtractsSetupComplete() throws {
        let json = """
        {
          "setupComplete": {}
        }
        """.data(using: .utf8)!

        let events = try GeminiLiveTranslationResponseParser.events(from: json)

        XCTAssertEqual(events, [.setupComplete])
    }

    func testCredentialInfersEphemeralTokenEndpointMode() {
        XCTAssertEqual(GeminiLiveCredential(rawValue: "AQ.token"), .ephemeralToken("AQ.token"))
        XCTAssertEqual(GeminiLiveCredential(rawValue: "AIza-test"), .apiKey("AIza-test"))
    }
}
