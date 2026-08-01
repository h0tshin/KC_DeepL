import Foundation
import XCTest

import KCDeepLCore
@testable import KCDeepL

@MainActor
final class TextFileTranslationViewModelTests: XCTestCase {
    func testMarkdownIsTranslatedByMultipleChunksAndRebuiltWithoutChangingCode() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KCDeepL-TextTranslation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("guide.md")
        let body = (0..<110)
            .map { "## Section \($0)\nThis paragraph contains enough context to exercise the adaptive text chunker and preserve Markdown structure." }
            .joined(separator: "\n\n")
        let source = "# Guide\n\n\(body)\n\n```swift\nlet answer = 42\n```\n"
        try Data(source.utf8).write(to: sourceURL)

        let client = PrefixXMLTranslationClient()
        let viewModel = FileTranslationViewModel(
            apiClient: client,
            appServerClient: client,
            codexModelProvider: EmptyCodexModelProvider()
        )
        viewModel.importFile(from: sourceURL, sourceLanguage: .english)
        try await waitUntil(timeout: .seconds(10)) {
            viewModel.stage == .ready || viewModel.stage == .failed
        }
        XCTAssertEqual(viewModel.stage, .ready, viewModel.errorMessage ?? "")
        XCTAssertEqual(viewModel.documentKind, .markdown)
        XCTAssertGreaterThan(viewModel.textChunkCount, 1)

        let destinationURL = directory.appendingPathComponent("guide.ko.md")
        viewModel.startTranslation(
            configuration: FileTranslationConfiguration(
                engine: .geminiAPI,
                sourceLanguage: .english,
                targetLanguage: .korean,
                modelID: "test-model",
                apiKey: "test-key",
                temperature: 0.2,
                downloadLocation: FileTranslationOutputLocation.ask.rawValue,
                explicitlySelectedDestination: destinationURL,
                allowsPotentiallyIncompleteOCR: true,
                compositionPolicy: .strict,
                renderMode: .preserveOriginalWithLayer,
                continueOnError: false,
                includeOCR: false,
                preserveMarkdownStructure: true,
                translateMarkdownCodeBlocks: false,
                textChunkingProfile: .responsive
            )
        )
        try await waitUntil(timeout: .seconds(10)) {
            viewModel.stage == .completed || viewModel.stage == .failed
        }

        XCTAssertEqual(viewModel.stage, .completed, viewModel.errorMessage ?? "")
        XCTAssertEqual(viewModel.outputURL, destinationURL)
        XCTAssertTrue(viewModel.translatedText?.contains("[ko] Guide") == true)
        XCTAssertTrue(viewModel.translatedText?.contains("[ko] Section 0") == true)
        let output = try String(contentsOf: destinationURL, encoding: .utf8)
        XCTAssertTrue(output.contains("[ko] Guide"))
        XCTAssertTrue(output.contains("[ko] Section 0"))
        XCTAssertTrue(output.contains("```swift\nlet answer = 42\n```"))
        XCTAssertNotEqual(output, source)
        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), source)
        let requestCount = await client.requestCount()
        XCTAssertGreaterThan(requestCount, 1)
    }

    private func waitUntil(
        timeout: Duration,
        condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("condition timed out")
                return
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor PrefixXMLTranslationClient: TranslationClient {
    private var calls = 0

    func translate(_ request: TranslationRequest) async throws -> String {
        calls += 1
        let sourceSegments = try DocumentPageTranslationEnvelope.parse(request.sourceText)
        let segments = sourceSegments.map { segment in
            "<kc_segment id=\"\(escape(segment.id))\">\(escape("[ko] \(segment.translatedText)"))</kc_segment>"
        }.joined()
        return "<kc_page_translation version=\"1\">\(segments)</kc_page_translation>"
    }

    func requestCount() -> Int {
        calls
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private actor EmptyCodexModelProvider: CodexAppServerModelProviding {
    func availableModels() async throws -> [CodexAppServerModel] {
        []
    }
}
