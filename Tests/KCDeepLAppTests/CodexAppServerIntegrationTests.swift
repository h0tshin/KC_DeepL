import Foundation
import XCTest
@testable import KCDeepL
import KCDeepLCore

final class CodexAppServerIntegrationTests: XCTestCase {
    func testInstalledAppServerListsModelsAndTranslates() async throws {
        guard ProcessInfo.processInfo.environment["KCDEEPL_RUN_CODEX_INTEGRATION"] == "1" else {
            throw XCTSkip("실제 Codex App Server 스모크 테스트는 명시적으로 실행할 때만 동작합니다.")
        }

        let suiteName = "KCDeepL.CodexIntegration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("통합 테스트용 UserDefaults를 만들 수 없습니다.")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KCDeepL-CodexIntegration-\(UUID().uuidString)")
        let client = CodexAppServerClient(
            threadIDStore: UserDefaultsCodexThreadIDStore(defaults: defaults),
            workingDirectory: workingDirectory,
            requestTimeout: 30,
            turnTimeout: 120,
            threadRetentionPolicy: .ephemeral
        )

        do {
            let models = try await client.availableModels()
            let model = try XCTUnwrap(
                models.first(where: \.isDefault) ?? models.first
            )
            let output = try await client.translate(
                TranslationRequest(
                    sourceText: "Hello, this is a translation smoke test.",
                    sourceLanguage: .english,
                    targetLanguage: .korean,
                    provider: .gemini,
                    modelID: model.model,
                    apiKey: ""
                )
            )

            XCTAssertFalse(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertNotEqual(output, "Hello, this is a translation smoke test.")

            let pageAdapter = TranslationClientDocumentPageAdapter(
                client: client,
                provider: .chatGPT,
                modelID: model.model,
                apiKey: ""
            )
            let pageResult = try await pageAdapter.translatePage(
                DocumentPageTranslationRequest(
                    pageIndex: 0,
                    blocks: [
                        DocumentPageTextBlock(id: "title", text: "Annual report"),
                        DocumentPageTextBlock(
                            id: "body",
                            text: "Revenue increased this year."
                        )
                    ],
                    sourceLanguage: .english,
                    targetLanguage: .korean
                )
            )
            XCTAssertEqual(pageResult.translations.map(\.id), ["title", "body"])
            XCTAssertTrue(
                pageResult.translations.allSatisfy {
                    !$0.translatedText.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                }
            )
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    func testLunaTranslatesFixturePDFsPageByPage() async throws {
        guard ProcessInfo.processInfo.environment["KCDEEPL_RUN_CODEX_INTEGRATION"] == "1" else {
            throw XCTSkip("실제 Codex App Server PDF 테스트는 명시적으로 실행할 때만 동작합니다.")
        }

        let suiteName = "KCDeepL.CodexLunaPDF.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KCDeepL-CodexLunaPDF-\(UUID().uuidString)")
        let client = CodexAppServerClient(
            threadIDStore: UserDefaultsCodexThreadIDStore(defaults: defaults),
            workingDirectory: workingDirectory,
            requestTimeout: 30,
            turnTimeout: 240,
            threadRetentionPolicy: .ephemeral
        )
        defer { Task { await client.shutdown() } }

        let models = try await client.availableModels()
        print("Codex models:", models.map { "\($0.model)=\($0.displayName)" }.joined(separator: ", "))
        let luna = try XCTUnwrap(
            models.first(where: { $0.model == "gpt-5.6-luna" }),
            "gpt-5.6-luna 모델이 현재 App Server에 없습니다."
        )
        print("Using Codex model:", luna.model, luna.displayName)

        let outputDirectory = URL(fileURLWithPath: "/Users/h0tshin/Documents/KC_DeepL/output/pdf", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let allSourceURLs = [
            URL(fileURLWithPath: "/Users/h0tshin/Downloads/Plex_Fiix_Positioning_SalesTalk.pdf"),
            URL(fileURLWithPath: "/Users/h0tshin/Downloads/Plex Public Cloud _ FAQ.PDF")
        ]
        let environment = ProcessInfo.processInfo.environment
        let sourceURLs: [URL]
        if environment["KCDEEPL_ONLY_FIRST"] == "1" {
            sourceURLs = Array(allSourceURLs.prefix(1))
        } else if environment["KCDEEPL_ONLY_FAQ"] == "1" {
            sourceURLs = Array(allSourceURLs.dropFirst())
        } else {
            sourceURLs = allSourceURLs
        }
        let pageLimit = ProcessInfo.processInfo.environment["KCDEEPL_MAX_PAGES"].flatMap(Int.init)
        let pageClient = TranslationClientDocumentPageAdapter(
            client: client,
            provider: .chatGPT,
            modelID: luna.model,
            apiKey: "",
            temperature: 0.2
        )
        let analysisService = PDFDocumentAnalysisService(ocrLanguages: ["en-US"])
        let compositionService = PDFDocumentCompositionService()

        for sourceURL in sourceURLs {
            let analysis = try analysisService.analyze(sourceURL: sourceURL)
            let preflight = "Preflight \(sourceURL.lastPathComponent): pages=\(analysis.pageCount), lines=\(analysis.translatableLineCount), warnings=\(analysis.warnings.map(\.message))\n"
            FileHandle.standardError.write(Data(preflight.utf8))
            for page in analysis.pages {
                for warning in page.warnings {
                    FileHandle.standardError.write(Data("warning page=\(page.pageIndex) \(warning)\n".utf8))
                    if case let .complexBackground(_, lineID) = warning,
                       let line = page.lines.first(where: { $0.id == lineID }) {
                        FileHandle.standardError.write(Data("complex text=\(line.text.debugDescription) bounds=\(line.bounds) source=\(line.extractionSource)\n".utf8))
                    }
                }
            }
            // The requested "무시하고 번역" mode is the deliberate fallback for
            // OCR text detected over logos or rasterized artwork. Native text
            // and every safely maskable line still translate normally; unsafe
            // image regions remain untouched instead of aborting the document.
            try compositionService.validateReadiness(
                analysis: analysis,
                policy: .bestEffort
            )
            print(
                "Analyzed \(sourceURL.lastPathComponent): pages=\(analysis.pageCount), lines=\(analysis.translatableLineCount), blocks=\(analysis.pages.reduce(0) { $0 + $1.blocks.count }), warnings=\(analysis.warnings.count)"
            )

            var translations: [String: String] = [:]
            translations.reserveCapacity(analysis.translatableLineCount)
            for page in analysis.pages
            where !page.blocks.isEmpty
                && (pageLimit == nil || page.pageIndex < pageLimit!) {
                let request = DocumentPageTranslationRequest(
                    pageIndex: page.pageIndex,
                    blocks: page.blocks.map {
                        DocumentPageTextBlock(id: $0.id, text: $0.text)
                    },
                    sourceLanguage: .english,
                    targetLanguage: .korean
                )
                print(
                    "Translating \(sourceURL.lastPathComponent) page \(page.pageIndex + 1)/\(analysis.pageCount) blocks=\(request.blocks.count)"
                )
                let result = try await pageClient.translatePage(request)
                for translation in result.translations {
                    translations[translation.id] = translation.translatedText
                }
            }

            let destinationURL = outputDirectory.appendingPathComponent(
                "\(sourceURL.deletingPathExtension().lastPathComponent).ko.gpt-5.6-luna.pdf"
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            let result = try compositionService.compose(
                analysis: analysis,
                translations: translations,
                destinationURL: destinationURL,
                policy: .bestEffort
            )
            XCTAssertEqual(result.pageCount, analysis.pageCount)
            XCTAssertGreaterThan(result.translatedLineCount, 0)
            XCTAssertLessThanOrEqual(result.translatedLineCount, analysis.translatableLineCount)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
            print("Created", destinationURL.path)
        }
    }
}
