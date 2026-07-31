import AppKit
import Foundation
import KCDeepLCore

enum FileTranslationStage: Equatable {
    case idle
    case analyzing
    case ready
    case waitingForApple
    case translating(page: Int, total: Int)
    case composing
    case completed
    case cancelled
    case failed

    var isBusy: Bool {
        switch self {
        case .analyzing, .waitingForApple, .translating, .composing:
            true
        case .idle, .ready, .completed, .cancelled, .failed:
            false
        }
    }
}

struct FileTranslationConfiguration: Equatable, Sendable {
    let engine: FileTranslationEngine
    let sourceLanguage: LanguageOption
    let targetLanguage: LanguageOption
    let modelID: String
    let apiKey: String
    let temperature: Double
    let downloadLocation: String
    let explicitlySelectedDestination: URL?
    let allowsPotentiallyIncompleteOCR: Bool
    let compositionPolicy: PDFDocumentCompositionPolicy
}

enum FileTranslationViewModelError: LocalizedError, Equatable {
    case documentNotLoaded
    case noTranslatableText
    case sourceAndTargetMatch
    case missingModel
    case missingAPIKey
    case wrongEngine
    case incompleteOCRRequiresConfirmation
    case destinationDirectoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .documentNotLoaded:
            "먼저 번역할 PDF 파일을 선택해 주세요."
        case .noTranslatableText:
            "이 PDF에서 번역할 텍스트를 찾지 못했습니다. OCR 경고를 확인해 주세요."
        case .sourceAndTargetMatch:
            "원문 언어와 번역 언어가 같습니다. 서로 다른 언어를 선택해 주세요."
        case .missingModel:
            "번역에 사용할 모델을 선택해 주세요."
        case .missingAPIKey:
            "Gemini API 키를 입력해 주세요."
        case .wrongEngine:
            "선택한 번역 엔진으로 이 작업을 시작할 수 없습니다."
        case .incompleteOCRRequiresConfirmation:
            "OCR 경고로 일부 이미지 글자가 누락될 수 있습니다. 경고를 확인하고 계속 진행에 동의해 주세요."
        case let .destinationDirectoryUnavailable(path):
            "번역 PDF를 저장할 폴더에 쓸 수 없습니다: \(path)"
        }
    }
}

@MainActor
final class FileTranslationViewModel: ObservableObject {
    @Published private(set) var stage: FileTranslationStage = .idle
    @Published private(set) var analysis: PDFDocumentAnalysis?
    @Published private(set) var outputURL: URL?
    @Published private(set) var outputData: Data?
    @Published private(set) var sourceDocumentVersion: UInt = 0
    @Published private(set) var outputDocumentVersion: UInt = 0
    @Published private(set) var progress = 0.0
    @Published private(set) var statusMessage = "PDF 파일을 선택하거나 끌어다 놓으세요."
    @Published private(set) var errorMessage: String?
    @Published private(set) var preflightBlockingMessage: String?
    @Published private(set) var canUseBestEffortTranslation = false
    @Published private(set) var warnings: [String] = []
    @Published private(set) var codexModels: [CodexAppServerModel] = []
    @Published private(set) var isLoadingCodexModels = false
    @Published private(set) var codexModelErrorMessage: String?
    @Published private(set) var appleRequestGeneration: UInt = 0
    @Published private(set) var appleCancellationGeneration: UInt = 0
    private(set) var pendingAppleConfiguration: FileTranslationConfiguration?

    private let apiClient: any TranslationClient
    private let appServerClient: any TranslationClient
    private let codexModelProvider: any CodexAppServerModelProviding
    private let outputURLResolver: FileTranslationOutputURLResolver
    private var operationTask: Task<Void, Never>?
    private var operationGeneration: UInt = 0

    init(
        apiClient: any TranslationClient = GeminiTranslationClient(requestTimeout: 120),
        appServerClient: any TranslationClient,
        codexModelProvider: any CodexAppServerModelProviding,
        outputURLResolver: FileTranslationOutputURLResolver = FileTranslationOutputURLResolver()
    ) {
        self.apiClient = apiClient
        self.appServerClient = appServerClient
        self.codexModelProvider = codexModelProvider
        self.outputURLResolver = outputURLResolver
    }

    deinit {
        operationTask?.cancel()
    }

    var sourceData: Data? {
        analysis?.sourceData
    }

    var sourceURL: URL? {
        analysis?.sourceURL
    }

    var filename: String? {
        sourceURL?.lastPathComponent
    }

    var pageCount: Int {
        analysis?.pageCount ?? 0
    }

    var translatableBlockCount: Int {
        analysis?.pages.reduce(0) { $0 + $1.blocks.count } ?? 0
    }

    var isBusy: Bool {
        stage.isBusy
    }

    var requiresIncompleteOCRAcknowledgement: Bool {
        analysis?.pages.contains { page in
            page.warnings.contains(where: \.requiresIncompleteOCRAcknowledgement)
        } ?? false
    }

    func importPDF(from sourceURL: URL, sourceLanguage: LanguageOption) {
        cancelCurrentOperation(setCancelledStage: false)
        let generation = nextOperationGeneration()

        analysis = nil
        outputURL = nil
        outputData = nil
        warnings = []
        errorMessage = nil
        preflightBlockingMessage = nil
        canUseBestEffortTranslation = false
        progress = 0
        stage = .analyzing
        statusMessage = "PDF 페이지와 텍스트 위치를 분석하는 중입니다."

        operationTask = Task { [weak self] in
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let ocrLanguages = Self.ocrLanguages(for: sourceLanguage)
                let analysisTask = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try PDFDocumentAnalysisService(
                        ocrLanguages: ocrLanguages
                    ).analyze(sourceURL: sourceURL)
                }
                let analyzedDocument = try await withTaskCancellationHandler {
                    try await analysisTask.value
                } onCancel: {
                    analysisTask.cancel()
                }
                try Task.checkCancellation()

                guard let self, self.operationGeneration == generation else {
                    return
                }
                self.sourceDocumentVersion &+= 1
                self.analysis = analyzedDocument
                self.warnings = Self.warningMessages(in: analyzedDocument)
                do {
                    try PDFDocumentCompositionService().validateReadiness(
                        analysis: analyzedDocument
                    )
                    self.preflightBlockingMessage = nil
                    self.canUseBestEffortTranslation = false
                } catch {
                    self.preflightBlockingMessage = Self.userFacingMessage(
                        for: error
                    )
                    self.canUseBestEffortTranslation = Self
                        .isBestEffortEligible(error)
                }
                self.progress = 0
                self.stage = .ready
                if self.preflightBlockingMessage == nil {
                    self.statusMessage = "\(analyzedDocument.pageCount)페이지에서 \(analyzedDocument.pages.reduce(0) { $0 + $1.blocks.count })개 텍스트 영역을 찾았습니다."
                } else if self.canUseBestEffortTranslation {
                    self.statusMessage = "PDF 분석을 마쳤습니다. 보존 불가 영역은 원문으로 남기고 번역할 수 있습니다."
                } else {
                    self.statusMessage = "PDF 분석을 마쳤지만 레이아웃 보존 문제를 먼저 해결해야 합니다."
                }
                self.operationTask = nil
            } catch is CancellationError {
                guard let self, self.operationGeneration == generation else {
                    return
                }
                self.stage = .cancelled
                self.statusMessage = "PDF 분석을 취소했습니다."
                self.operationTask = nil
            } catch {
                guard let self, self.operationGeneration == generation else {
                    return
                }
                self.fail(with: error)
                self.operationTask = nil
            }
        }
    }

    func startTranslation(configuration: FileTranslationConfiguration) {
        do {
            let (analysis, destinationURL) = try validatedInputs(for: configuration)
            let client: TranslationClientDocumentPageAdapter

            switch configuration.engine {
            case .codexAppServer:
                client = TranslationClientDocumentPageAdapter(
                    client: appServerClient,
                    provider: .chatGPT,
                    modelID: configuration.modelID,
                    apiKey: "",
                    temperature: configuration.temperature
                )
            case .geminiAPI:
                client = TranslationClientDocumentPageAdapter(
                    client: apiClient,
                    provider: .gemini,
                    modelID: configuration.modelID,
                    apiKey: configuration.apiKey,
                    temperature: configuration.temperature
                )
            case .apple:
                throw FileTranslationViewModelError.wrongEngine
            }

            beginTranslation(
                analysis: analysis,
                destinationURL: destinationURL,
                client: client,
                sourceLanguage: configuration.sourceLanguage,
                targetLanguage: configuration.targetLanguage,
                compositionPolicy: configuration.compositionPolicy
            )
        } catch {
            fail(with: error)
        }
    }

    func requestAppleTranslation(configuration: FileTranslationConfiguration) {
        do {
            _ = try validatedInputs(for: configuration)
            guard configuration.engine == .apple else {
                throw FileTranslationViewModelError.wrongEngine
            }

            cancelCurrentOperation(setCancelledStage: false)
            pendingAppleConfiguration = configuration
            appleRequestGeneration &+= 1
            errorMessage = nil
            progress = 0
            stage = .waitingForApple
            statusMessage = "Apple 번역 언어 모델을 준비하는 중입니다."
        } catch {
            fail(with: error)
        }
    }

    func performPendingAppleTranslation(
        using client: any DocumentPageTranslationClient
    ) async {
        guard let configuration = pendingAppleConfiguration else {
            return
        }

        do {
            let (analysis, destinationURL) = try validatedInputs(for: configuration)
            pendingAppleConfiguration = nil
            let generation = nextOperationGeneration()
            await performTranslation(
                analysis: analysis,
                destinationURL: destinationURL,
                client: client,
                sourceLanguage: configuration.sourceLanguage,
                targetLanguage: configuration.targetLanguage,
                compositionPolicy: configuration.compositionPolicy,
                generation: generation
            )
        } catch is CancellationError {
            stage = .cancelled
            statusMessage = "파일 번역을 취소했습니다."
        } catch {
            fail(with: error)
        }
    }

    func cancelTranslation() {
        cancelCurrentOperation(setCancelledStage: true)
    }

    func clearDocument() {
        cancelCurrentOperation(setCancelledStage: false)
        analysis = nil
        outputURL = nil
        outputData = nil
        sourceDocumentVersion &+= 1
        outputDocumentVersion &+= 1
        warnings = []
        errorMessage = nil
        preflightBlockingMessage = nil
        canUseBestEffortTranslation = false
        progress = 0
        stage = .idle
        statusMessage = "PDF 파일을 선택하거나 끌어다 놓으세요."
    }

    func reportFileSelectionError(_ error: Error) {
        errorMessage = Self.userFacingMessage(for: error)
        if analysis == nil {
            stage = .failed
        }
        statusMessage = "PDF 파일을 열지 못했습니다."
    }

    func reportUnsupportedDrop() {
        errorMessage = "PDF 파일만 번역할 수 있습니다."
        if analysis == nil {
            stage = .failed
        }
        statusMessage = "지원하지 않는 파일 형식입니다."
    }

    func reportTranslationError(_ error: Error) {
        fail(with: error)
    }

    func reportAppleTranslationProgress(_ message: String) {
        guard stage.isBusy else {
            return
        }
        statusMessage = message
    }

    func refreshCodexModels() async {
        guard !isLoadingCodexModels else {
            return
        }

        isLoadingCodexModels = true
        codexModelErrorMessage = nil
        defer { isLoadingCodexModels = false }

        do {
            codexModels = try await codexModelProvider.availableModels()
        } catch is CancellationError {
            return
        } catch {
            codexModelErrorMessage = Self.userFacingMessage(for: error)
        }
    }

    private func beginTranslation(
        analysis: PDFDocumentAnalysis,
        destinationURL: URL,
        client: any DocumentPageTranslationClient,
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        compositionPolicy: PDFDocumentCompositionPolicy
    ) {
        cancelCurrentOperation(setCancelledStage: false)
        let generation = nextOperationGeneration()
        let translatablePages = analysis.pages.filter { !$0.blocks.isEmpty }
        errorMessage = nil
        progress = 0
        stage = .translating(page: 1, total: translatablePages.count)
        let firstPageNumber = (translatablePages.first?.pageIndex ?? 0) + 1
        statusMessage = "\(firstPageNumber)페이지를 문맥 단위로 번역하는 중입니다."
        operationTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.performTranslation(
                analysis: analysis,
                destinationURL: destinationURL,
                client: client,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                compositionPolicy: compositionPolicy,
                generation: generation
            )
        }
    }

    private func performTranslation(
        analysis: PDFDocumentAnalysis,
        destinationURL: URL,
        client: any DocumentPageTranslationClient,
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        compositionPolicy: PDFDocumentCompositionPolicy,
        generation: UInt
    ) async {
        errorMessage = nil
        outputURL = nil
        outputData = nil
        outputDocumentVersion &+= 1
        progress = 0

        do {
            let translatablePages = analysis.pages.filter { !$0.blocks.isEmpty }
            guard !translatablePages.isEmpty else {
                throw FileTranslationViewModelError.noTranslatableText
            }

            var translatedBlocks: [String: String] = [:]
            translatedBlocks.reserveCapacity(translatableBlockCount)

            for (offset, page) in translatablePages.enumerated() {
                try Task.checkCancellation()
                guard operationGeneration == generation else {
                    throw CancellationError()
                }

                stage = .translating(page: offset + 1, total: translatablePages.count)
                statusMessage = "\(page.pageIndex + 1)페이지를 문맥 단위로 번역하는 중입니다."
                progress = Double(offset) / Double(max(1, translatablePages.count + 1))

                let request = DocumentPageTranslationRequest(
                    pageIndex: page.pageIndex,
                    blocks: page.blocks.map {
                        DocumentPageTextBlock(id: $0.id, text: $0.text)
                    },
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                )
                let result = try await client.translatePage(request)
                let validated = try DocumentPageTranslationValidator.validateAndOrder(
                    result,
                    for: request
                )

                for translation in validated.translations {
                    translatedBlocks[translation.id] = translation.translatedText
                }
            }

            try Task.checkCancellation()
            guard operationGeneration == generation else {
                throw CancellationError()
            }

            stage = .composing
            statusMessage = compositionPolicy == .bestEffort
                ? "보존할 수 없는 영역은 원문으로 남기고 PDF를 만드는 중입니다."
                : "원본 레이아웃에 번역문을 맞춰 PDF를 만드는 중입니다."
            progress = 0.9

            let temporaryURL = Self.temporaryOutputURL(beside: destinationURL)
            var ownsTemporaryFile = false
            defer {
                if ownsTemporaryFile {
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
            }

            let compositionTask = Task.detached(priority: .userInitiated) {
                var didCreateTemporaryFile = false
                do {
                    try Task.checkCancellation()
                    try FileManager.default.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let composition = try PDFDocumentCompositionService().compose(
                        analysis: analysis,
                        translations: translatedBlocks,
                        destinationURL: temporaryURL,
                        policy: compositionPolicy
                    )
                    didCreateTemporaryFile = true
                    try Task.checkCancellation()
                    let data = try Data(
                        contentsOf: temporaryURL,
                        options: .mappedIfSafe
                    )
                    try Task.checkCancellation()
                    return (composition, data)
                } catch {
                    if didCreateTemporaryFile {
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }
                    throw error
                }
            }
            let (composition, data) = try await withTaskCancellationHandler {
                try await compositionTask.value
            } onCancel: {
                compositionTask.cancel()
            }
            ownsTemporaryFile = true

            try Task.checkCancellation()
            guard operationGeneration == generation else {
                throw CancellationError()
            }

            // This synchronous MainActor section is the sole final commit. No
            // cancellation or newer operation can interleave between the last
            // generation check and the move, and committed paths are never
            // rollback-deleted where another process could have replaced them.
            do {
                try FileManager.default.moveItem(
                    at: temporaryURL,
                    to: destinationURL
                )
            } catch {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    throw PDFDocumentServiceError.destinationAlreadyExists
                }
                throw PDFDocumentServiceError.cannotWriteOutput(
                    error.localizedDescription
                )
            }
            ownsTemporaryFile = false

            warnings = Self.deduplicated(
                warnings + composition.warnings.map(\.message)
            )
            outputURL = destinationURL
            outputData = data
            outputDocumentVersion &+= 1
            progress = 1
            stage = .completed
            statusMessage = "번역 PDF를 저장했습니다: \(destinationURL.lastPathComponent)"
            operationTask = nil
        } catch is CancellationError {
            guard operationGeneration == generation else {
                return
            }
            stage = .cancelled
            statusMessage = "파일 번역을 취소했습니다."
            operationTask = nil
        } catch {
            guard operationGeneration == generation else {
                return
            }
            fail(with: error)
            operationTask = nil
        }
    }

    private func validatedInputs(
        for configuration: FileTranslationConfiguration
    ) throws -> (PDFDocumentAnalysis, URL) {
        guard let analysis else {
            throw FileTranslationViewModelError.documentNotLoaded
        }
        guard translatableBlockCount > 0 else {
            throw FileTranslationViewModelError.noTranslatableText
        }
        try PDFDocumentCompositionService().validateReadiness(
            analysis: analysis,
            policy: configuration.compositionPolicy
        )
        guard !requiresIncompleteOCRAcknowledgement
                || configuration.allowsPotentiallyIncompleteOCR
                || configuration.compositionPolicy == .bestEffort
        else {
            throw FileTranslationViewModelError.incompleteOCRRequiresConfirmation
        }
        guard configuration.sourceLanguage == .autoDetect
                || configuration.sourceLanguage != configuration.targetLanguage
        else {
            throw FileTranslationViewModelError.sourceAndTargetMatch
        }

        switch configuration.engine {
        case .apple:
            break
        case .codexAppServer:
            guard !configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FileTranslationViewModelError.missingModel
            }
        case .geminiAPI:
            guard !configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FileTranslationViewModelError.missingModel
            }
            guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FileTranslationViewModelError.missingAPIKey
            }
        }

        let destinationURL = try outputURLResolver.resolve(
            sourceURL: analysis.sourceURL,
            targetLanguage: configuration.targetLanguage,
            locationRawValue: configuration.downloadLocation,
            explicitlySelectedURL: configuration.explicitlySelectedDestination
        )
        try validateDestinationDirectory(for: destinationURL)
        return (analysis, destinationURL)
    }

    private static func isBestEffortEligible(_ error: Error) -> Bool {
        guard let error = error as? PDFDocumentServiceError else {
            return false
        }
        switch error {
        case .backgroundCannotBePreserved,
             .unsupportedOverlappingLink,
             .unsupportedOverlappingAnnotation:
            return true
        default:
            return false
        }
    }

    private func validateDestinationDirectory(for destinationURL: URL) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw FileTranslationViewModelError
                .destinationDirectoryUnavailable(directoryURL.path)
        }

        let probeURL = directoryURL.appendingPathComponent(
            ".kcdeepl-write-probe-\(UUID().uuidString)",
            isDirectory: false
        )
        var ownsProbe = false
        defer {
            if ownsProbe {
                try? FileManager.default.removeItem(at: probeURL)
            }
        }

        do {
            // This zero-byte UUID file verifies current parent-directory access
            // without touching the requested destination or any existing file.
            try Data().write(to: probeURL, options: .withoutOverwriting)
            ownsProbe = true
            try FileManager.default.removeItem(at: probeURL)
            ownsProbe = false
        } catch {
            throw FileTranslationViewModelError
                .destinationDirectoryUnavailable(directoryURL.path)
        }

        // This is a pre-engine snapshot, not a promise against later TOCTOU.
        // Composition still uses its owned UUID temporary file, validates it,
        // and atomically moves it without overwriting the final destination.
    }

    private func cancelCurrentOperation(setCancelledStage: Bool) {
        operationGeneration &+= 1
        operationTask?.cancel()
        operationTask = nil
        pendingAppleConfiguration = nil
        appleCancellationGeneration &+= 1

        if setCancelledStage, stage.isBusy {
            stage = .cancelled
            statusMessage = "파일 번역을 취소했습니다."
        }
    }

    private func nextOperationGeneration() -> UInt {
        operationGeneration &+= 1
        return operationGeneration
    }

    private func fail(with error: Error) {
        errorMessage = Self.userFacingMessage(for: error)
        stage = .failed
        statusMessage = "파일 번역을 완료하지 못했습니다."
        progress = 0
    }

    static func warningMessages(in analysis: PDFDocumentAnalysis) -> [String] {
        var uniqueWarnings: [PDFDocumentWarning] = []
        for warning in analysis.warnings
            + analysis.pages.flatMap(\.warnings)
        where !uniqueWarnings.contains(warning) {
            uniqueWarnings.append(warning)
        }

        var hybridUnavailablePages = Set<Int>()
        var complexBackgroundPages = Set<Int>()
        var complexBackgroundCount = 0
        var unavailableBackgroundPages = Set<Int>()
        var unavailableBackgroundCount = 0
        var remainingMessages: [String] = []

        for warning in uniqueWarnings {
            switch warning {
            case let .hybridOCRUnavailable(pageIndex):
                hybridUnavailablePages.insert(pageIndex)
            case let .complexBackground(pageIndex, _):
                complexBackgroundPages.insert(pageIndex)
                complexBackgroundCount += 1
            case let .backgroundSamplingUnavailable(pageIndex, _):
                unavailableBackgroundPages.insert(pageIndex)
                unavailableBackgroundCount += 1
            default:
                remainingMessages.append(warning.message)
            }
        }

        var messages: [String] = []
        if !hybridUnavailablePages.isEmpty {
            messages.append(
                "\(formattedPages(hybridUnavailablePages, pageCount: analysis.pageCount))에서 이미지 영역 OCR을 사용할 수 없습니다. 일반 PDF 텍스트는 번역하지만 이미지 안의 글자는 누락될 수 있습니다."
            )
        }
        if complexBackgroundCount > 0 {
            messages.append(
                "\(formattedPages(complexBackgroundPages, pageCount: analysis.pageCount))의 텍스트 영역 \(complexBackgroundCount)개는 배경이 복잡해 원본 레이아웃을 안전하게 보존할 수 없습니다."
            )
        }
        if unavailableBackgroundCount > 0 {
            messages.append(
                "\(formattedPages(unavailableBackgroundPages, pageCount: analysis.pageCount))의 텍스트 영역 \(unavailableBackgroundCount)개는 배경을 안전하게 분석하지 못했습니다."
            )
        }
        return deduplicated(messages + remainingMessages)
    }

    private static func formattedPages(
        _ zeroBasedPages: Set<Int>,
        pageCount: Int
    ) -> String {
        let pages = zeroBasedPages.map { $0 + 1 }.sorted()
        if pages.count == pageCount, pageCount > 0 {
            return "전체 \(pageCount)페이지"
        }

        var ranges: [String] = []
        var rangeStart: Int?
        var previous: Int?
        for page in pages {
            if let previous, page != previous + 1 {
                if let rangeStart {
                    ranges.append(
                        rangeStart == previous
                            ? "\(rangeStart)"
                            : "\(rangeStart)–\(previous)"
                    )
                }
                rangeStart = page
            } else if rangeStart == nil {
                rangeStart = page
            }
            previous = page
        }
        if let rangeStart, let previous {
            ranges.append(
                rangeStart == previous
                    ? "\(rangeStart)"
                    : "\(rangeStart)–\(previous)"
            )
        }
        return "\(ranges.joined(separator: ", "))페이지"
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func userFacingMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func temporaryOutputURL(beside destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".kcdeepl-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("pdf")
    }

    private static func ocrLanguages(for language: LanguageOption) -> [String] {
        switch language.code {
        case "ko":
            ["ko-KR"]
        case "en":
            ["en-US"]
        case "ja":
            ["ja-JP"]
        case "zh-CN":
            ["zh-Hans"]
        case "zh-TW":
            ["zh-Hant"]
        case "fr":
            ["fr-FR"]
        case "de":
            ["de-DE"]
        case "es":
            ["es-ES"]
        default:
            []
        }
    }
}
