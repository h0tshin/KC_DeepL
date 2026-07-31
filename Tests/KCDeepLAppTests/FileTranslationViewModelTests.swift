import AppKit
import Foundation
import KCDeepLCore
import PDFKit
import XCTest

@testable import KCDeepL

@MainActor
final class FileTranslationViewModelTests: XCTestCase {
    func testWarningMessagesGroupPageLevelHybridOCRFailures() {
        let pageBounds = CGRect(x: 0, y: 0, width: 960, height: 540)
        let pages = (0..<14).map { pageIndex in
            PDFPageAnalysis(
                id: "page-\(pageIndex)",
                pageIndex: pageIndex,
                mediaBox: pageBounds,
                cropBox: pageBounds,
                bleedBox: pageBounds,
                trimBox: pageBounds,
                artBox: pageBounds,
                rotation: 0,
                lines: [],
                blocks: [],
                warnings: [.hybridOCRUnavailable(pageIndex: pageIndex)]
            )
        }
        let analysis = PDFDocumentAnalysis(
            sourceURL: URL(fileURLWithPath: "/tmp/grouped-warnings.pdf"),
            sourceData: Data("%PDF-1.7".utf8),
            pageCount: pages.count,
            pages: pages,
            warnings: pages.flatMap(\.warnings)
        )

        let messages = FileTranslationViewModel.warningMessages(in: analysis)

        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("전체 14페이지"))
        XCTAssertTrue(messages[0].contains("이미지 영역 OCR"))
    }

    func testImportAnalyzesDigitalPDFAndPublishesReadyState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.pdf")
        let sourceData = try makeDigitalPDF(
            at: sourceURL,
            pages: ["First page", "Second page"]
        )
        let provider = CodexModelProviderStub(models: Self.codexModels)
        let viewModel = makeViewModel(codexModelProvider: provider)

        viewModel.importPDF(from: sourceURL, sourceLanguage: .english)

        XCTAssertEqual(viewModel.stage, .analyzing)
        XCTAssertNil(viewModel.analysis)
        try await waitUntilTerminalImportState(viewModel)

        XCTAssertEqual(viewModel.stage, .ready, viewModel.errorMessage ?? "")
        let analysis = try XCTUnwrap(viewModel.analysis)
        XCTAssertEqual(analysis.sourceURL, sourceURL.standardizedFileURL)
        XCTAssertEqual(analysis.sourceData, sourceData)
        XCTAssertEqual(analysis.pageCount, 2)
        XCTAssertEqual(analysis.pages.map(\.sourceText), ["First page", "Second page"])
        XCTAssertEqual(viewModel.pageCount, 2)
        XCTAssertEqual(viewModel.translatableBlockCount, 2)
        XCTAssertEqual(viewModel.sourceDocumentVersion, 1)
        XCTAssertEqual(viewModel.progress, 0)
        XCTAssertNil(viewModel.outputURL)
        XCTAssertNil(viewModel.outputData)
        XCTAssertTrue(viewModel.statusMessage.contains("2페이지"))
        XCTAssertTrue(viewModel.statusMessage.contains("2개 텍스트 영역"))

        await viewModel.refreshCodexModels()

        let providerCallCount = await provider.callCount()
        XCTAssertEqual(providerCallCount, 1)
        XCTAssertEqual(viewModel.codexModels, Self.codexModels)
        XCTAssertFalse(viewModel.isLoadingCodexModels)
        XCTAssertNil(viewModel.codexModelErrorMessage)
    }

    func testGeminiAndCodexRouteToTheirOwnClientsOnePageAtATime() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("routing-source.pdf")
        let sourceData = try makeDigitalPDF(
            at: sourceURL,
            pages: ["First page", "Second page"]
        )
        let geminiClient = StableXMLTranslationClient(prefix: "G")
        let codexClient = StableXMLTranslationClient(prefix: "C")
        let viewModel = makeViewModel(
            apiClient: geminiClient,
            appServerClient: codexClient
        )
        viewModel.importPDF(from: sourceURL, sourceLanguage: .english)
        try await waitUntilTerminalImportState(viewModel)
        XCTAssertEqual(viewModel.stage, .ready, viewModel.errorMessage ?? "")

        let geminiDestination = directory.appendingPathComponent("gemini.pdf")
        viewModel.startTranslation(
            configuration: makeConfiguration(
                engine: .geminiAPI,
                modelID: "gemini-test-model",
                apiKey: "gemini-test-key",
                temperature: 0.15,
                destinationURL: geminiDestination
            )
        )
        try await waitUntilTranslationFinishes(
            viewModel,
            expectedDestination: geminiDestination
        )

        XCTAssertEqual(viewModel.stage, .completed, viewModel.errorMessage ?? "")
        XCTAssertEqual(viewModel.outputURL, geminiDestination)
        XCTAssertEqual(viewModel.outputData, try Data(contentsOf: geminiDestination))
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        XCTAssertNotEqual(sourceURL.standardizedFileURL, geminiDestination.standardizedFileURL)
        assertTranslatedPDF(at: geminiDestination, pageCount: 2, contents: ["G1", "G2"])

        let geminiSnapshot = await geminiClient.snapshot()
        let codexCountAfterGemini = await codexClient.requestCount()
        XCTAssertEqual(geminiSnapshot.requests.count, 2)
        XCTAssertEqual(geminiSnapshot.maximumConcurrentRequests, 1)
        XCTAssertEqual(codexCountAfterGemini, 0)
        XCTAssertEqual(geminiSnapshot.requests.map(\.provider), [.gemini, .gemini])
        XCTAssertEqual(
            geminiSnapshot.requests.map(\.modelID),
            ["gemini-test-model", "gemini-test-model"]
        )
        XCTAssertEqual(
            geminiSnapshot.requests.map(\.apiKey),
            ["gemini-test-key", "gemini-test-key"]
        )
        XCTAssertEqual(geminiSnapshot.requests.map(\.temperature), [0.15, 0.15])
        XCTAssertTrue(geminiSnapshot.requests[0].sourceText.contains("First page"))
        XCTAssertFalse(geminiSnapshot.requests[0].sourceText.contains("Second page"))
        XCTAssertTrue(geminiSnapshot.requests[1].sourceText.contains("Second page"))
        XCTAssertFalse(geminiSnapshot.requests[1].sourceText.contains("First page"))

        let codexDestination = directory.appendingPathComponent("codex.pdf")
        viewModel.startTranslation(
            configuration: makeConfiguration(
                engine: .codexAppServer,
                modelID: "gpt-test-model",
                apiKey: "must-not-be-forwarded",
                temperature: 0.4,
                destinationURL: codexDestination
            )
        )
        try await waitUntilTranslationFinishes(
            viewModel,
            expectedDestination: codexDestination
        )

        XCTAssertEqual(viewModel.stage, .completed, viewModel.errorMessage ?? "")
        XCTAssertEqual(viewModel.outputURL, codexDestination)
        XCTAssertEqual(viewModel.outputData, try Data(contentsOf: codexDestination))
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        assertTranslatedPDF(at: codexDestination, pageCount: 2, contents: ["C1", "C2"])

        let codexSnapshot = await codexClient.snapshot()
        XCTAssertEqual(codexSnapshot.requests.count, 2)
        XCTAssertEqual(codexSnapshot.maximumConcurrentRequests, 1)
        XCTAssertEqual(codexSnapshot.requests.map(\.provider), [.chatGPT, .chatGPT])
        XCTAssertEqual(
            codexSnapshot.requests.map(\.modelID),
            ["gpt-test-model", "gpt-test-model"]
        )
        XCTAssertEqual(codexSnapshot.requests.map(\.apiKey), ["", ""])
        XCTAssertEqual(codexSnapshot.requests.map(\.temperature), [0.4, 0.4])
        XCTAssertTrue(codexSnapshot.requests[0].sourceText.contains("First page"))
        XCTAssertTrue(codexSnapshot.requests[1].sourceText.contains("Second page"))
    }

    func testGeminiConfigurationRejectsMissingModelAndAPIKeyBeforeCallingClient() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("configuration-source.pdf")
        try makeDigitalPDF(at: sourceURL, pages: ["Configuration"])
        let geminiClient = StableXMLTranslationClient(prefix: "G")
        let viewModel = makeViewModel(apiClient: geminiClient)
        viewModel.importPDF(from: sourceURL, sourceLanguage: .english)
        try await waitUntilTerminalImportState(viewModel)
        XCTAssertEqual(viewModel.stage, .ready, viewModel.errorMessage ?? "")

        let destination = directory.appendingPathComponent("invalid.pdf")
        viewModel.startTranslation(
            configuration: makeConfiguration(
                engine: .geminiAPI,
                modelID: " \n ",
                apiKey: "key",
                destinationURL: destination
            )
        )

        XCTAssertEqual(viewModel.stage, .failed)
        XCTAssertEqual(
            viewModel.errorMessage,
            FileTranslationViewModelError.missingModel.errorDescription
        )

        viewModel.startTranslation(
            configuration: makeConfiguration(
                engine: .geminiAPI,
                modelID: "gemini-test-model",
                apiKey: " \t ",
                destinationURL: destination
            )
        )

        let requestCount = await geminiClient.requestCount()
        XCTAssertEqual(viewModel.stage, .failed)
        XCTAssertEqual(
            viewModel.errorMessage,
            FileTranslationViewModelError.missingAPIKey.errorDescription
        )
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(viewModel.outputURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testNonzeroMediaBoxOriginRejectsEveryRotationBeforeCallingEngine() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let geminiClient = StableXMLTranslationClient(prefix: "G")
        let mediaBox = CGRect(x: 1, y: 2, width: 600, height: 800)

        for rotation in [0, 90, 180, 270] {
            let sourceURL = directory.appendingPathComponent(
                "nonzero-media-\(rotation).pdf"
            )
            let sourceData = try makeDigitalPDF(
                at: sourceURL,
                pages: ["Media origin"],
                rotations: [rotation],
                mediaBoxes: [mediaBox]
            )
            try replaceFirstASCII(
                in: sourceURL,
                matching: "/MediaBox [0 0 600 800]",
                with: "/MediaBox [1 2 601 802]"
            )
            let guardedSourceData = try Data(contentsOf: sourceURL)
            let viewModel = makeViewModel(apiClient: geminiClient)
            viewModel.importPDF(from: sourceURL, sourceLanguage: .english)
            try await waitUntilTerminalImportState(viewModel)
            XCTAssertEqual(viewModel.stage, .ready, viewModel.errorMessage ?? "")

            let destination = directory.appendingPathComponent(
                "nonzero-media-output-\(rotation).pdf"
            )
            viewModel.startTranslation(
                configuration: makeConfiguration(
                    engine: .geminiAPI,
                    modelID: "gemini-test-model",
                    apiKey: "key",
                    destinationURL: destination
                )
            )

            let expectedError = PDFDocumentServiceError
                .nonzeroMediaBoxOriginUnsupported(
                    pageIndex: 0,
                    minX: mediaBox.minX,
                    minY: mediaBox.minY
                )
            XCTAssertEqual(viewModel.stage, .failed)
            XCTAssertEqual(viewModel.errorMessage, expectedError.errorDescription)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: destination.path)
            )
            XCTAssertNil(viewModel.outputURL)
            XCTAssertNil(viewModel.outputData)
            XCTAssertNotEqual(guardedSourceData, sourceData)
            XCTAssertEqual(try Data(contentsOf: sourceURL), guardedSourceData)
        }

        let requestCount = await geminiClient.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testUnsupportedRotationRejectsBeforeCallingTranslationEngine() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("rotation-45.pdf")
        let sourceData = try makeDigitalPDF(
            at: sourceURL,
            pages: ["Malformed rotation"],
            rotations: [90]
        )
        try replaceFirstASCII(
            in: sourceURL,
            matching: "/Rotate 90",
            with: "/Rotate 45"
        )
        let malformedSourceData = try Data(contentsOf: sourceURL)
        let geminiClient = StableXMLTranslationClient(prefix: "G")
        let viewModel = makeViewModel(apiClient: geminiClient)
        viewModel.importPDF(from: sourceURL, sourceLanguage: .english)
        try await waitUntilTerminalImportState(viewModel)
        XCTAssertEqual(viewModel.stage, .ready, viewModel.errorMessage ?? "")

        let destination = directory.appendingPathComponent("rotation-output.pdf")
        viewModel.startTranslation(
            configuration: makeConfiguration(
                engine: .geminiAPI,
                modelID: "gemini-test-model",
                apiKey: "key",
                destinationURL: destination
            )
        )

        let expectedError = PDFDocumentServiceError.unsupportedPageRotation(
            pageIndex: 0,
            rotation: 45
        )
        let requestCount = await geminiClient.requestCount()
        XCTAssertEqual(viewModel.stage, .failed)
        XCTAssertEqual(viewModel.errorMessage, expectedError.errorDescription)
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(viewModel.outputURL)
        XCTAssertNil(viewModel.outputData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNotEqual(malformedSourceData, sourceData)
        XCTAssertEqual(try Data(contentsOf: sourceURL), malformedSourceData)
    }

    func testMissingDestinationDirectoryFailsBeforeCallingTranslationEngine() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.pdf")
        try makeDigitalPDF(at: sourceURL, pages: ["Destination probe"])
        let geminiClient = StableXMLTranslationClient(prefix: "G")
        let viewModel = makeViewModel(apiClient: geminiClient)
        viewModel.importPDF(from: sourceURL, sourceLanguage: .english)
        try await waitUntilTerminalImportState(viewModel)
        XCTAssertEqual(viewModel.stage, .ready, viewModel.errorMessage ?? "")

        let missingDirectory = directory
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        let destination = missingDirectory.appendingPathComponent("output.pdf")
        viewModel.startTranslation(
            configuration: makeConfiguration(
                engine: .geminiAPI,
                modelID: "gemini-test-model",
                apiKey: "key",
                destinationURL: destination
            )
        )

        let requestCount = await geminiClient.requestCount()
        XCTAssertEqual(viewModel.stage, .failed)
        XCTAssertEqual(
            viewModel.errorMessage,
            FileTranslationViewModelError
                .destinationDirectoryUnavailable(missingDirectory.path)
                .errorDescription
        )
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(viewModel.outputURL)
        XCTAssertNil(viewModel.outputData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missingDirectory.path)
        )
    }

    func testPotentiallyIncompleteOCRRequiresExplicitAcknowledgement() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("ocr-warning-source.pdf")
        try makeDigitalPDF(at: sourceURL, pages: ["Visible text", ""])
        let geminiClient = StableXMLTranslationClient(prefix: "G")
        let viewModel = makeViewModel(apiClient: geminiClient)
        viewModel.importPDF(from: sourceURL, sourceLanguage: .english)
        try await waitUntilTerminalImportState(viewModel)

        XCTAssertEqual(viewModel.stage, .ready, viewModel.errorMessage ?? "")
        XCTAssertTrue(viewModel.requiresIncompleteOCRAcknowledgement)

        let blockedDestination = directory.appendingPathComponent("blocked.pdf")
        viewModel.startTranslation(
            configuration: makeConfiguration(
                engine: .geminiAPI,
                modelID: "gemini-test-model",
                apiKey: "key",
                destinationURL: blockedDestination,
                allowsPotentiallyIncompleteOCR: false
            )
        )

        XCTAssertEqual(viewModel.stage, .failed)
        XCTAssertEqual(
            viewModel.errorMessage,
            FileTranslationViewModelError
                .incompleteOCRRequiresConfirmation
                .errorDescription
        )
        let blockedRequestCount = await geminiClient.requestCount()
        XCTAssertEqual(blockedRequestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blockedDestination.path))

        let acceptedDestination = directory.appendingPathComponent("accepted.pdf")
        viewModel.startTranslation(
            configuration: makeConfiguration(
                engine: .geminiAPI,
                modelID: "gemini-test-model",
                apiKey: "key",
                destinationURL: acceptedDestination,
                allowsPotentiallyIncompleteOCR: false,
                compositionPolicy: .bestEffort
            )
        )
        try await waitUntilTranslationFinishes(
            viewModel,
            expectedDestination: acceptedDestination
        )

        XCTAssertEqual(viewModel.stage, .completed, viewModel.errorMessage ?? "")
        let acceptedRequestCount = await geminiClient.requestCount()
        XCTAssertEqual(acceptedRequestCount, 1)
    }

    func testImportingReplacementDocumentIgnoresLateCancelledTranslation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstSourceURL = directory.appendingPathComponent("first.pdf")
        let replacementURL = directory.appendingPathComponent("replacement.pdf")
        try makeDigitalPDF(at: firstSourceURL, pages: ["First document"])
        let replacementData = try makeDigitalPDF(
            at: replacementURL,
            pages: ["Replacement document"]
        )
        let delayedClient = DelayedXMLTranslationClient(prefix: "Late")
        addTeardownBlock {
            await delayedClient.release()
        }
        let viewModel = makeViewModel(apiClient: delayedClient)
        viewModel.importPDF(from: firstSourceURL, sourceLanguage: .english)
        try await waitUntilTerminalImportState(viewModel)
        XCTAssertEqual(viewModel.stage, .ready, viewModel.errorMessage ?? "")

        let obsoleteDestination = directory.appendingPathComponent("obsolete.pdf")
        viewModel.startTranslation(
            configuration: makeConfiguration(
                engine: .geminiAPI,
                modelID: "gemini-test-model",
                apiKey: "key",
                destinationURL: obsoleteDestination
            )
        )
        await delayedClient.waitUntilStarted()
        XCTAssertEqual(viewModel.stage, .translating(page: 1, total: 1))

        viewModel.importPDF(from: replacementURL, sourceLanguage: .english)
        try await waitUntilTerminalImportState(viewModel)
        XCTAssertEqual(viewModel.stage, .ready, viewModel.errorMessage ?? "")
        XCTAssertEqual(viewModel.sourceURL, replacementURL.standardizedFileURL)

        await delayedClient.release()
        await delayedClient.waitUntilFinished()
        await allowCancelledOperationToSettle()

        XCTAssertEqual(viewModel.stage, .ready)
        XCTAssertEqual(viewModel.sourceURL, replacementURL.standardizedFileURL)
        XCTAssertEqual(viewModel.sourceData, replacementData)
        XCTAssertNil(viewModel.outputURL)
        XCTAssertNil(viewModel.outputData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: obsoleteDestination.path))
    }

    func testCancellationDuringCompositionLeavesNoDestinationFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("composition-source.pdf")
        try makeDigitalPDF(
            at: sourceURL,
            pages: (1...8).map { "Page \($0)" }
        )
        let geminiClient = StableXMLTranslationClient(prefix: "T")
        let viewModel = makeViewModel(apiClient: geminiClient)
        viewModel.importPDF(from: sourceURL, sourceLanguage: .english)
        try await waitUntilTerminalImportState(viewModel)
        XCTAssertEqual(viewModel.stage, .ready, viewModel.errorMessage ?? "")

        let destination = directory.appendingPathComponent("cancelled.pdf")
        viewModel.startTranslation(
            configuration: makeConfiguration(
                engine: .geminiAPI,
                modelID: "gemini-test-model",
                apiKey: "key",
                destinationURL: destination
            )
        )
        try await waitUntil(timeout: .seconds(2)) {
            viewModel.stage == .composing
                || viewModel.stage == .completed
                || viewModel.stage == .failed
        }
        guard viewModel.stage == .composing else {
            return XCTFail(
                "Expected to cancel during composition, reached \(viewModel.stage): "
                    + (viewModel.errorMessage ?? "no error")
            )
        }

        viewModel.cancelTranslation()
        XCTAssertEqual(viewModel.stage, .cancelled)
        await allowCancelledOperationToSettle(milliseconds: 150)

        XCTAssertEqual(viewModel.stage, .cancelled)
        XCTAssertNil(viewModel.outputURL)
        XCTAssertNil(viewModel.outputData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

private extension FileTranslationViewModelTests {
    static let codexModels = [
        CodexAppServerModel(
            id: "model-id",
            model: "gpt-test-model",
            displayName: "GPT Test",
            description: "Test model",
            isDefault: true
        )
    ]

    func makeViewModel(
        apiClient: any TranslationClient = StableXMLTranslationClient(prefix: "API"),
        appServerClient: any TranslationClient = StableXMLTranslationClient(prefix: "Codex"),
        codexModelProvider: (any CodexAppServerModelProviding)? = nil
    ) -> FileTranslationViewModel {
        FileTranslationViewModel(
            apiClient: apiClient,
            appServerClient: appServerClient,
            codexModelProvider: codexModelProvider ?? CodexModelProviderStub(
                models: Self.codexModels
            )
        )
    }

    func makeConfiguration(
        engine: FileTranslationEngine,
        modelID: String,
        apiKey: String,
        temperature: Double = 0.2,
        destinationURL: URL,
        allowsPotentiallyIncompleteOCR: Bool = true,
        compositionPolicy: PDFDocumentCompositionPolicy = .strict
    ) -> FileTranslationConfiguration {
        FileTranslationConfiguration(
            engine: engine,
            sourceLanguage: .english,
            targetLanguage: .korean,
            modelID: modelID,
            apiKey: apiKey,
            temperature: temperature,
            downloadLocation: FileTranslationOutputLocation.ask.rawValue,
            explicitlySelectedDestination: destinationURL,
            allowsPotentiallyIncompleteOCR: allowsPotentiallyIncompleteOCR,
            compositionPolicy: compositionPolicy
        )
    }

    func waitUntilTerminalImportState(
        _ viewModel: FileTranslationViewModel
    ) async throws {
        // Hybrid Vision OCR intentionally examines image regions on every page.
        // Multi-page imports can exceed the generic two-second UI-state timeout
        // on loaded CI hosts even though the operation is progressing normally.
        try await waitUntil(timeout: .seconds(15)) {
            viewModel.stage == .ready || viewModel.stage == .failed
        }
    }

    func waitUntilTranslationFinishes(
        _ viewModel: FileTranslationViewModel,
        expectedDestination: URL
    ) async throws {
        try await waitUntil(timeout: .seconds(3)) {
            viewModel.stage == .failed
                || (viewModel.stage == .completed
                    && viewModel.outputURL == expectedDestination)
        }
    }

    func waitUntil(
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !condition() {
            guard clock.now < deadline else {
                throw FileTranslationViewModelTestError.conditionTimedOut
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func allowCancelledOperationToSettle(milliseconds: UInt64 = 20) async {
        for _ in 0..<4 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FileTranslationViewModelTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    @discardableResult
    func makeDigitalPDF(
        at url: URL,
        pages: [String],
        rotations: [Int] = [],
        mediaBoxes: [CGRect] = []
    ) throws -> Data {
        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else {
            throw FileTranslationViewModelTestError.cannotCreatePDF
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 600, height: 800)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else {
            throw FileTranslationViewModelTestError.cannotCreatePDF
        }

        for (pageIndex, pageText) in pages.enumerated() {
            let pageMediaBox = mediaBoxes.indices.contains(pageIndex)
                ? mediaBoxes[pageIndex]
                : mediaBox
            let pageInfo: CFDictionary?
            if mediaBoxes.indices.contains(pageIndex) {
                var encodedMediaBox = pageMediaBox
                let mediaBoxData = Data(
                    bytes: &encodedMediaBox,
                    count: MemoryLayout<CGRect>.size
                )
                pageInfo = [kCGPDFContextMediaBox: mediaBoxData] as CFDictionary
            } else {
                pageInfo = nil
            }
            context.beginPDFPage(pageInfo)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(pageMediaBox)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(
                cgContext: context,
                flipped: false
            )
            (pageText as NSString).draw(
                at: CGPoint(x: 50, y: 700),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 18),
                    .foregroundColor: NSColor.black
                ]
            )
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        guard let document = PDFDocument(data: mutableData as Data)
        else {
            throw FileTranslationViewModelTestError.cannotCreatePDF
        }
        for (pageIndex, rotation) in rotations.enumerated()
        where pageIndex < document.pageCount {
            document.page(at: pageIndex)?.rotation = rotation
        }
        guard let data = document.dataRepresentation() else {
            throw FileTranslationViewModelTestError.cannotCreatePDF
        }
        try data.write(to: url, options: .atomic)
        return data
    }

    func replaceFirstASCII(
        in url: URL,
        matching source: String,
        with replacement: String
    ) throws {
        let sourceData = Data(source.utf8)
        let replacementData = Data(replacement.utf8)
        guard sourceData.count == replacementData.count else {
            throw FileTranslationViewModelTestError.cannotCreatePDF
        }
        var data = try Data(contentsOf: url)
        guard let range = data.range(of: sourceData) else {
            throw FileTranslationViewModelTestError.cannotCreatePDF
        }
        data.replaceSubrange(range, with: replacementData)
        try data.write(to: url, options: .atomic)
    }

    func assertTranslatedPDF(
        at url: URL,
        pageCount: Int,
        contents: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let document = PDFDocument(url: url) else {
            return XCTFail("Could not open translated PDF", file: file, line: line)
        }
        XCTAssertEqual(document.pageCount, pageCount, file: file, line: line)
        let translatedContents = Set<String>(
            (0..<document.pageCount).flatMap { pageIndex -> [String] in
                guard let page = document.page(at: pageIndex) else {
                    return []
                }
                return page.annotations.compactMap { annotation -> String? in
                    guard annotation.userName?.hasPrefix("KCDeepL Translation:") == true else {
                        return nil
                    }
                    return annotation.contents
                }
            }
        )
        XCTAssertEqual(translatedContents, contents, file: file, line: line)
    }
}

private actor StableXMLTranslationClient: TranslationClient {
    struct Snapshot: Sendable {
        let requests: [TranslationRequest]
        let maximumConcurrentRequests: Int
    }

    private let prefix: String
    private var requests: [TranslationRequest] = []
    private var activeRequestCount = 0
    private var maximumConcurrentRequests = 0

    init(prefix: String) {
        self.prefix = prefix
    }

    func translate(_ request: TranslationRequest) async throws -> String {
        requests.append(request)
        activeRequestCount += 1
        maximumConcurrentRequests = max(
            maximumConcurrentRequests,
            activeRequestCount
        )
        defer { activeRequestCount -= 1 }

        await Task.yield()
        let ids = try XMLSegmentIDs.parse(request.sourceText)
        let translatedText = "\(prefix)\(requests.count)"
        return XMLSegmentIDs.response(ids: ids, translatedText: translatedText)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            requests: requests,
            maximumConcurrentRequests: maximumConcurrentRequests
        )
    }

    func requestCount() -> Int {
        requests.count
    }
}

private actor DelayedXMLTranslationClient: TranslationClient {
    private let prefix: String
    private var request: TranslationRequest?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var isFinished = false

    init(prefix: String) {
        self.prefix = prefix
    }

    func translate(_ request: TranslationRequest) async throws -> String {
        self.request = request
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        let ids = try XMLSegmentIDs.parse(request.sourceText)
        let response = XMLSegmentIDs.response(
            ids: ids,
            translatedText: prefix
        )
        isFinished = true
        let completionWaiters = finishedWaiters
        finishedWaiters.removeAll()
        completionWaiters.forEach { $0.resume() }
        return response
    }

    func waitUntilStarted() async {
        if request != nil {
            return
        }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitUntilFinished() async {
        if isFinished {
            return
        }
        await withCheckedContinuation { continuation in
            finishedWaiters.append(continuation)
        }
    }
}

private actor CodexModelProviderStub: CodexAppServerModelProviding {
    private let models: [CodexAppServerModel]
    private var calls = 0

    init(models: [CodexAppServerModel]) {
        self.models = models
    }

    func availableModels() async throws -> [CodexAppServerModel] {
        calls += 1
        return models
    }

    func callCount() -> Int {
        calls
    }
}

private enum XMLSegmentIDs {
    static func parse(_ xml: String) throws -> [String] {
        guard let data = xml.data(using: .utf8) else {
            throw FileTranslationViewModelTestError.invalidXML
        }
        let delegate = SegmentIDParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !delegate.ids.isEmpty else {
            throw FileTranslationViewModelTestError.invalidXML
        }
        return delegate.ids
    }

    static func response(ids: [String], translatedText: String) -> String {
        let segments = ids.map {
            "<kc_segment id=\"\(escape($0))\">\(escape(translatedText))</kc_segment>"
        }.joined()
        return "<kc_page_translation version=\"1\">\(segments)</kc_page_translation>"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class SegmentIDParserDelegate: NSObject, XMLParserDelegate {
    private(set) var ids: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "kc_segment", let id = attributeDict["id"] {
            ids.append(id)
        }
    }
}

private enum FileTranslationViewModelTestError: Error {
    case cannotCreatePDF
    case conditionTimedOut
    case invalidXML
}
