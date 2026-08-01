import Foundation
import XCTest

@testable import KCDeepLCore

final class TextDocumentTranslationTests: XCTestCase {
    func testDetectorUsesMarkdownExtensionAndRejectsCodeAsTranslatableText() throws {
        let source = "# Heading\n\n- First item\n- Second item\n\n```swift\nlet answer = 42\n```\n"
        let url = URL(fileURLWithPath: "/tmp/example.md")
        let data = Data(source.utf8)

        let detection = try TextDocumentFileDetector().detect(
            sourceURL: url,
            data: data
        )
        XCTAssertEqual(detection.kind, .markdown)
        XCTAssertEqual(detection.encoding, .utf8)

        let analysis = try TextDocumentAnalyzer().analyze(
            sourceURL: url,
            sourceData: data,
            detection: detection
        )
        XCTAssertTrue(analysis.segments.contains { $0.kind == .codeBlock })
        XCTAssertFalse(analysis.segments.contains { $0.kind == .codeBlock && $0.translates })

        let translations = Dictionary(
            uniqueKeysWithValues: analysis.translatableSegments.map { ($0.id, "번역") }
        )
        XCTAssertEqual(
            analysis.renderedText(translations: translations),
            "# 번역\n\n- 번역\n- 번역\n\n```swift\nlet answer = 42\n```\n"
        )
    }

    func testMarkdownTablePipesAndAlignmentAreNeverSentToTheModel() throws {
        let source = "| Name | Description |\n| :--- | ---: |\n| Alpha | First value |\n"
        let url = URL(fileURLWithPath: "/tmp/table.md")
        let data = Data(source.utf8)
        let detection = try TextDocumentFileDetector().detect(sourceURL: url, data: data)
        let analysis = try TextDocumentAnalyzer().analyze(
            sourceURL: url,
            sourceData: data,
            detection: detection
        )
        let tableSegments = analysis.segments.filter { $0.kind == .tableCell }
        XCTAssertEqual(tableSegments.map(\.sourceText), ["Name", "Description", "Alpha", "First value"])

        let translated = Dictionary(
            uniqueKeysWithValues: analysis.translatableSegments.map { ($0.id, "번역") }
        )
        XCTAssertEqual(
            analysis.renderedText(translations: translated),
            "| 번역 | 번역 |\n| :--- | ---: |\n| 번역 | 번역 |\n"
        )
    }

    func testUnknownExtensionUsesMarkdownSignals() throws {
        let source = "# Title\n\nThis is a paragraph.\n\n> A quote\n"
        let detection = try TextDocumentFileDetector().detect(
            sourceURL: URL(fileURLWithPath: "/tmp/README"),
            data: Data(source.utf8)
        )
        XCTAssertEqual(detection.kind, .markdown)
        XCTAssertGreaterThanOrEqual(detection.markdownScore, 3)
        XCTAssertLessThan(detection.confidence, 100)
    }

    func testChunkerKeepsEveryRequestWithinCharacterAndTokenBudgets() throws {
        let source = (0..<170)
            .map { "Line \($0): This sentence provides enough context for a stable text translation request." }
            .joined(separator: "\n")
        let url = URL(fileURLWithPath: "/tmp/large.txt")
        let data = Data(source.utf8)
        let detection = try TextDocumentFileDetector().detect(
            sourceURL: url,
            data: data
        )
        let configuration = TextDocumentChunkingConfiguration(
            minimumCharacters: 400,
            targetCharacters: 1_200,
            maximumCharacters: 1_600,
            maximumEstimatedTokens: 900,
            maximumSegments: 20
        )
        let analysis = try TextDocumentAnalyzer(chunking: configuration).analyze(
            sourceURL: url,
            sourceData: data,
            detection: detection
        )

        XCTAssertGreaterThan(analysis.chunks.count, 1)
        for chunk in analysis.chunks {
            XCTAssertLessThanOrEqual(chunk.characterCount, configuration.maximumCharacters)
            XCTAssertLessThanOrEqual(chunk.estimatedTokenCount, configuration.maximumEstimatedTokens)
            XCTAssertLessThanOrEqual(chunk.segmentIDs.count, configuration.maximumSegments)
        }
        XCTAssertEqual(
            Set(analysis.chunks.flatMap(\.segmentIDs)),
            Set(analysis.translatableSegments.map(\.id))
        )
    }

    func testLongLineIsSplitButIdentityReconstructionIsLossless() throws {
        let source = String(repeating: "A long sentence with useful context. ", count: 300)
        let url = URL(fileURLWithPath: "/tmp/long.txt")
        let data = Data(source.utf8)
        let detection = try TextDocumentFileDetector().detect(
            sourceURL: url,
            data: data
        )
        let analysis = try TextDocumentAnalyzer(
            chunking: TextDocumentChunkingConfiguration(
                minimumCharacters: 200,
                targetCharacters: 800,
                maximumCharacters: 1_000,
                maximumEstimatedTokens: 700,
                maximumSegments: 16
            )
        ).analyze(sourceURL: url, sourceData: data, detection: detection)

        XCTAssertGreaterThan(analysis.segments.count, 1)
        let identity = Dictionary(
            uniqueKeysWithValues: analysis.translatableSegments.map { ($0.id, $0.sourceText) }
        )
        XCTAssertEqual(analysis.renderedText(translations: identity), source)
    }

    func testUTF16BOMIsPreservedWhenEncodingTranslatedOutput() throws {
        let text = "First line\r\nSecond line"
        let body = text.data(using: .utf16LittleEndian)!
        var sourceData = Data([0xFF, 0xFE])
        sourceData.append(body)
        let url = URL(fileURLWithPath: "/tmp/utf16.txt")
        let detection = try TextDocumentFileDetector().detect(
            sourceURL: url,
            data: sourceData
        )
        XCTAssertEqual(detection.encoding, .utf16LittleEndian)
        let analysis = try TextDocumentAnalyzer().analyze(
            sourceURL: url,
            sourceData: sourceData,
            detection: detection
        )
        let translations = Dictionary(
            uniqueKeysWithValues: analysis.translatableSegments.map { ($0.id, "번역") }
        )
        let encoded = try analysis.encodedData(translations: translations)
        XCTAssertEqual(Array(encoded.prefix(2)), [0xFF, 0xFE])
        XCTAssertEqual(
            String(data: Data(encoded.dropFirst(2)), encoding: .utf16LittleEndian),
            "번역\r\n번역"
        )
    }
}
