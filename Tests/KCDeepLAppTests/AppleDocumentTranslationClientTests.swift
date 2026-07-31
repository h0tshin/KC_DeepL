import Foundation
import KCDeepLCore
import XCTest
@testable import KCDeepL

#if canImport(Translation)
import Translation
#endif

final class AppleDocumentTranslationClientTests: XCTestCase {
    func testResponseMapperRestoresSourceBlockOrder() throws {
        let request = makeRequest()
        let responses = [
            AppleDocumentTranslationResponseValue(
                clientIdentifier: "block-c",
                translatedText: "셋"
            ),
            AppleDocumentTranslationResponseValue(
                clientIdentifier: "block-a",
                translatedText: "하나"
            ),
            AppleDocumentTranslationResponseValue(
                clientIdentifier: "block-b",
                translatedText: "둘"
            )
        ]

        let result = try AppleDocumentTranslationResponseMapper.map(
            responses,
            for: request
        )

        XCTAssertEqual(result.pageIndex, 4)
        XCTAssertEqual(result.translations.map(\.id), ["block-a", "block-b", "block-c"])
        XCTAssertEqual(result.translations.map(\.translatedText), ["하나", "둘", "셋"])
    }

    func testResponseMapperRejectsResponseWithoutClientIdentifier() {
        let responses = [
            AppleDocumentTranslationResponseValue(
                clientIdentifier: nil,
                translatedText: "하나"
            )
        ]

        XCTAssertThrowsError(
            try AppleDocumentTranslationResponseMapper.map(
                responses,
                for: makeRequest(blockCount: 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? AppleDocumentTranslationError,
                .missingResponseIdentifier(responseIndex: 0)
            )
        }
    }

    func testResponseMapperRejectsDuplicateIdentifiersThroughCoreValidator() {
        let responses = [
            AppleDocumentTranslationResponseValue(
                clientIdentifier: "block-a",
                translatedText: "하나"
            ),
            AppleDocumentTranslationResponseValue(
                clientIdentifier: "block-a",
                translatedText: "중복"
            )
        ]

        XCTAssertThrowsError(
            try AppleDocumentTranslationResponseMapper.map(
                responses,
                for: makeRequest(blockCount: 2)
            )
        ) { error in
            XCTAssertEqual(
                error as? DocumentPageTranslationError,
                .duplicateTranslationID("block-a")
            )
        }
    }

    func testResponseMapperRejectsMissingIdentifierThroughCoreValidator() {
        let responses = [
            AppleDocumentTranslationResponseValue(
                clientIdentifier: "block-a",
                translatedText: "하나"
            )
        ]

        XCTAssertThrowsError(
            try AppleDocumentTranslationResponseMapper.map(
                responses,
                for: makeRequest(blockCount: 2)
            )
        ) { error in
            XCTAssertEqual(
                error as? DocumentPageTranslationError,
                .missingTranslationIDs(["block-b"])
            )
        }
    }

    func testResponseMapperRejectsUnknownIdentifierThroughCoreValidator() {
        let responses = [
            AppleDocumentTranslationResponseValue(
                clientIdentifier: "block-a",
                translatedText: "하나"
            ),
            AppleDocumentTranslationResponseValue(
                clientIdentifier: "other",
                translatedText: "알 수 없음"
            )
        ]

        XCTAssertThrowsError(
            try AppleDocumentTranslationResponseMapper.map(
                responses,
                for: makeRequest(blockCount: 2)
            )
        ) { error in
            XCTAssertEqual(
                error as? DocumentPageTranslationError,
                .unknownTranslationIDs(["other"])
            )
        }
    }

    func testResponseMapperRejectsWhitespaceOnlyTranslation() {
        let responses = [
            AppleDocumentTranslationResponseValue(
                clientIdentifier: "block-a",
                translatedText: "  \n "
            )
        ]

        XCTAssertThrowsError(
            try AppleDocumentTranslationResponseMapper.map(
                responses,
                for: makeRequest(blockCount: 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? DocumentPageTranslationError,
                .emptyTranslation("block-a")
            )
        }
    }

    func testLanguageMapperUsesNilForAutomaticSourceDetection() throws {
        let language = try AppleDocumentTranslationLanguageMapper.language(
            for: .autoDetect,
            role: .source
        )

        XCTAssertNil(language)
    }

    func testLanguageMapperRejectsAutomaticTargetDetection() {
        XCTAssertThrowsError(
            try AppleDocumentTranslationLanguageMapper.language(
                for: .autoDetect,
                role: .target
            )
        ) { error in
            XCTAssertEqual(
                error as? AppleDocumentTranslationError,
                .targetLanguageMustBeExplicit
            )
        }
    }

    func testLanguageMapperPreservesSimplifiedChineseScriptAndRegion() throws {
        let language = try XCTUnwrap(
            AppleDocumentTranslationLanguageMapper.language(
                for: .chineseSimplified,
                role: .target
            )
        )

        XCTAssertEqual(language.languageCode, .chinese)
        XCTAssertEqual(language.script, .hanSimplified)
        XCTAssertEqual(language.region, .chinaMainland)
    }

    func testLanguageMapperPreservesTraditionalChineseScriptAndRegion() throws {
        let language = try XCTUnwrap(
            AppleDocumentTranslationLanguageMapper.language(
                for: .chineseTraditional,
                role: .target
            )
        )

        XCTAssertEqual(language.languageCode, .chinese)
        XCTAssertEqual(language.script, .hanTraditional)
        XCTAssertEqual(language.region, .taiwan)
    }

    func testLanguageMapperRejectsMalformedLanguageCode() {
        let malformed = LanguageOption(code: "not a language", displayName: "Invalid")

        XCTAssertThrowsError(
            try AppleDocumentTranslationLanguageMapper.language(
                for: malformed,
                role: .source
            )
        ) { error in
            XCTAssertEqual(
                error as? AppleDocumentTranslationError,
                .invalidLanguageCode("not a language")
            )
        }
    }

    func testDownloadPreflightMessageExplainsSystemApproval() {
        let preflight = AppleDocumentTranslationPreflight(
            availability: .downloadRequired,
            sourceLanguageCode: "en",
            targetLanguageCode: "ko"
        )

        XCTAssertTrue(preflight.message.contains("다운로드 승인"))
    }

#if canImport(Translation)
    func testEmptyPagePreflightDoesNotRequireLanguagePacks() async throws {
        guard #available(macOS 15.0, *) else { return }

        let request = DocumentPageTranslationRequest(
            pageIndex: 0,
            blocks: [],
            sourceLanguage: .autoDetect,
            targetLanguage: .korean
        )

        let preflight = try await AppleDocumentTranslationClient.preflight(
            for: request
        )

        XCTAssertEqual(preflight.availability, .notRequired)
    }

    func testConfigurationUsesAutomaticSourceAndExplicitTargetWithoutLanguagePacks() throws {
        guard #available(macOS 15.0, *) else { return }

        let configuration = try AppleDocumentTranslationClient.configuration(
            sourceLanguage: .autoDetect,
            targetLanguage: .chineseTraditional
        )

        XCTAssertNil(configuration.source)
        XCTAssertEqual(configuration.target?.languageCode, .chinese)
        XCTAssertEqual(configuration.target?.script, .hanTraditional)
        XCTAssertEqual(configuration.target?.region, .taiwan)
    }
#endif

    private func makeRequest(blockCount: Int = 3) -> DocumentPageTranslationRequest {
        let allBlocks = [
            DocumentPageTextBlock(id: "block-a", text: "One"),
            DocumentPageTextBlock(id: "block-b", text: "Two"),
            DocumentPageTextBlock(id: "block-c", text: "Three")
        ]
        return DocumentPageTranslationRequest(
            pageIndex: 4,
            blocks: Array(allBlocks.prefix(blockCount)),
            sourceLanguage: .english,
            targetLanguage: .korean
        )
    }
}
