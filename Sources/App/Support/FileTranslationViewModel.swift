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
    let renderMode: PDFTranslationRenderMode
    let continueOnError: Bool
    let includeOCR: Bool

    /// Text/Markdown-only policies. They have defaults so existing PDF
    /// callers keep the same configuration surface.
    let preserveMarkdownStructure: Bool
    let translateMarkdownCodeBlocks: Bool
    let textChunkingProfile: TextDocumentChunkingProfile

    init(
        engine: FileTranslationEngine,
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        modelID: String,
        apiKey: String,
        temperature: Double,
        downloadLocation: String,
        explicitlySelectedDestination: URL?,
        allowsPotentiallyIncompleteOCR: Bool,
        compositionPolicy: PDFDocumentCompositionPolicy,
        renderMode: PDFTranslationRenderMode,
        continueOnError: Bool,
        includeOCR: Bool,
        preserveMarkdownStructure: Bool = true,
        translateMarkdownCodeBlocks: Bool = false,
        textChunkingProfile: TextDocumentChunkingProfile = .balanced
    ) {
        self.engine = engine
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.modelID = modelID
        self.apiKey = apiKey
        self.temperature = temperature
        self.downloadLocation = downloadLocation
        self.explicitlySelectedDestination = explicitlySelectedDestination
        self.allowsPotentiallyIncompleteOCR = allowsPotentiallyIncompleteOCR
        self.compositionPolicy = compositionPolicy
        self.renderMode = renderMode
        self.continueOnError = continueOnError
        self.includeOCR = includeOCR
        self.preserveMarkdownStructure = preserveMarkdownStructure
        self.translateMarkdownCodeBlocks = translateMarkdownCodeBlocks
        self.textChunkingProfile = textChunkingProfile
    }
}

enum FileTranslationViewModelError: LocalizedError, Equatable {
    case documentNotLoaded
    case noTranslatableText
    case sourceAndTargetMatch
    case missingModel
    case missingAPIKey
    case wrongEngine
    case appleLanguageModelPreparationTimedOut
    case incompleteOCRRequiresConfirmation
    case destinationDirectoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .documentNotLoaded:
            "먼저 번역할 파일을 선택해 주세요."
        case .noTranslatableText:
            "이 문서에서 번역할 텍스트를 찾지 못했습니다."
        case .sourceAndTargetMatch:
            "원문 언어와 번역 언어가 같습니다. 서로 다른 언어를 선택해 주세요."
        case .missingModel:
            "번역에 사용할 모델을 선택해 주세요."
        case .missingAPIKey:
            "Gemini API 키를 입력해 주세요."
        case .wrongEngine:
            "선택한 번역 엔진으로 이 작업을 시작할 수 없습니다."
        case .appleLanguageModelPreparationTimedOut:
            "Apple 번역 언어 팩 준비가 제한 시간 안에 끝나지 않았습니다. 시스템의 언어 팩 다운로드 상태를 확인한 뒤 다시 시도하거나 다른 엔진을 선택해 주세요."
        case .incompleteOCRRequiresConfirmation:
            "OCR 경고로 일부 이미지 글자가 누락될 수 있습니다. 경고를 확인하고 계속 진행에 동의해 주세요."
        case let .destinationDirectoryUnavailable(path):
            "번역 파일을 저장할 폴더에 쓸 수 없습니다: \(path)"
        }
    }
}

private enum LoadedFileTranslationDocument: Sendable {
    case pdf(PDFDocumentAnalysis)
    case text(TextDocumentAnalysis)

    var kind: SupportedFileDocumentKind {
        switch self {
        case .pdf:
            .pdf
        case let .text(analysis):
            analysis.kind
        }
    }
}

private struct ValidatedFileTranslationInput: Sendable {
    let document: LoadedFileTranslationDocument
    let destinationURL: URL
}

@MainActor
final class FileTranslationViewModel: ObservableObject {
    @Published private(set) var stage: FileTranslationStage = .idle
    @Published private(set) var analysis: PDFDocumentAnalysis?
    @Published private(set) var textAnalysis: TextDocumentAnalysis?
    @Published private(set) var outputURL: URL?
    @Published private(set) var outputData: Data?
    @Published private(set) var textOutput: String?
    @Published private(set) var sourceDocumentVersion: UInt = 0
    @Published private(set) var outputDocumentVersion: UInt = 0
    @Published private(set) var translatedPageCount = 0
    @Published private(set) var skippedPageCount = 0
    @Published private(set) var progress = 0.0
    @Published private(set) var statusMessage = "번역할 PDF, TXT 또는 Markdown 파일을 선택하거나 끌어다 놓으세요."
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
    private var appleLanguageModelWatchdogTask: Task<Void, Never>?
    private var operationGeneration: UInt = 0

    /// Apple Translation can wait indefinitely while the system language pack
    /// is being prepared. A bounded watchdog turns that silent wait into an
    /// actionable error and leaves the user free to retry or switch engines.
    private static let appleLanguageModelPreparationTimeout: Duration = .seconds(120)

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
        appleLanguageModelWatchdogTask?.cancel()
    }

    var sourceData: Data? {
        analysis?.sourceData ?? textAnalysis?.sourceData
    }

    var sourceURL: URL? {
        analysis?.sourceURL ?? textAnalysis?.sourceURL
    }

    var documentKind: SupportedFileDocumentKind? {
        if analysis != nil {
            return .pdf
        }
        return textAnalysis?.kind
    }

    var isTextDocument: Bool {
        textAnalysis != nil
    }

    var isPDFDocument: Bool {
        analysis != nil
    }

    var sourceText: String? {
        textAnalysis?.sourceText
    }

    var translatedText: String? {
        if let textOutput {
            return textOutput
        }

        // The preview is updated while each chunk is translated. If a view
        // appears after the final commit (or a legacy path only populated
        // outputData), decode that committed data so the right pane never
        // remains blank merely because the transient string was unavailable.
        guard textAnalysis != nil, let outputData else {
            return nil
        }
        let encoding: String.Encoding
        switch textAnalysis?.encoding {
        case .utf8, .utf8WithBOM, .none:
            encoding = .utf8
        case .utf16LittleEndian:
            encoding = .utf16LittleEndian
        case .utf16BigEndian:
            encoding = .utf16BigEndian
        case .utf32LittleEndian:
            encoding = .utf32LittleEndian
        case .utf32BigEndian:
            encoding = .utf32BigEndian
        case .isoLatin1:
            encoding = .isoLatin1
        }
        return String(data: outputData, encoding: encoding)
            ?? String(data: outputData, encoding: .utf8)
    }

    var filename: String? {
        sourceURL?.lastPathComponent
    }

    var pageCount: Int {
        analysis?.pageCount ?? 0
    }

    var translatableBlockCount: Int {
        if let analysis {
            return analysis.pages.reduce(0) { $0 + $1.blocks.count }
        }
        return textAnalysis?.translatableSegmentCount ?? 0
    }

    var translationItemCount: Int {
        analysis?.pages.filter { !$0.blocks.isEmpty }.count
            ?? textAnalysis?.chunks.count
            ?? 0
    }

    var isBusy: Bool {
        stage.isBusy
    }

    var requiresIncompleteOCRAcknowledgement: Bool {
        analysis?.pages.contains { page in
            page.warnings.contains(where: \.requiresIncompleteOCRAcknowledgement)
        } ?? false
    }

    var textChunkCount: Int {
        textAnalysis?.chunks.count ?? 0
    }

    func importFile(
        from sourceURL: URL,
        sourceLanguage: LanguageOption,
        includeOCR: Bool = true
    ) {
        cancelCurrentOperation(setCancelledStage: false)
        let generation = nextOperationGeneration()

        analysis = nil
        textAnalysis = nil
        outputURL = nil
        outputData = nil
        textOutput = nil
        warnings = []
        errorMessage = nil
        preflightBlockingMessage = nil
        canUseBestEffortTranslation = false
        progress = 0
        translatedPageCount = 0
        skippedPageCount = 0
        stage = .analyzing
        statusMessage = "파일 형식과 텍스트 구조를 분석하는 중입니다."
        let ocrLanguages = Self.ocrLanguages(for: sourceLanguage)

        operationTask = Task { [weak self] in
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let analyzedDocumentTask = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let sourceData = try Data(
                        contentsOf: sourceURL,
                        options: .mappedIfSafe
                    )
                    let detection = try TextDocumentFileDetector().detect(
                        sourceURL: sourceURL,
                        data: sourceData
                    )
                    switch detection.kind {
                    case .pdf:
                        return LoadedFileTranslationDocument.pdf(
                            try PDFDocumentAnalysisService(
                                ocrLanguages: ocrLanguages,
                                includeOCR: includeOCR
                            ).analyze(sourceURL: sourceURL)
                        )
                    case .plainText, .markdown:
                        return LoadedFileTranslationDocument.text(
                            try TextDocumentAnalyzer().analyze(
                                sourceURL: sourceURL,
                                sourceData: sourceData,
                                detection: detection
                            )
                        )
                    }
                }
                let analyzedDocument = try await withTaskCancellationHandler {
                    try await analyzedDocumentTask.value
                } onCancel: {
                    analyzedDocumentTask.cancel()
                }
                try Task.checkCancellation()

                guard let self, self.operationGeneration == generation else {
                    return
                }
                self.sourceDocumentVersion &+= 1
                self.analysis = nil
                self.textAnalysis = nil
                switch analyzedDocument {
                case let .pdf(pdfAnalysis):
                    self.analysis = pdfAnalysis
                    self.warnings = Self.warningMessages(in: pdfAnalysis)
                    do {
                        try PDFDocumentCompositionService().validateReadiness(
                            analysis: pdfAnalysis
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
                case let .text(textAnalysis):
                    self.textAnalysis = textAnalysis
                    self.warnings = []
                    self.preflightBlockingMessage = nil
                    self.canUseBestEffortTranslation = false
                }
                self.progress = 0
                self.stage = .ready
                switch analyzedDocument {
                case let .pdf(pdfAnalysis):
                    if self.preflightBlockingMessage == nil {
                        self.statusMessage = "\(pdfAnalysis.pageCount)페이지에서 \(pdfAnalysis.pages.reduce(0) { $0 + $1.blocks.count })개 텍스트 영역을 찾았습니다."
                    } else if self.canUseBestEffortTranslation {
                        self.statusMessage = "PDF 분석을 마쳤습니다. 보존 불가 영역은 원문으로 남기고 번역할 수 있습니다."
                    } else {
                        self.statusMessage = "PDF 분석을 마쳤지만 레이아웃 보존 문제를 먼저 해결해야 합니다."
                    }
                case let .text(textAnalysis):
                    let typeName = textAnalysis.kind == .markdown ? "Markdown" : "텍스트"
                    self.statusMessage = "\(typeName)에서 \(textAnalysis.translatableSegmentCount)개 영역, \(textAnalysis.chunks.count)개 번역 청크를 준비했습니다."
                }
                self.operationTask = nil
            } catch is CancellationError {
                guard let self, self.operationGeneration == generation else {
                    return
                }
                self.stage = .cancelled
                self.statusMessage = "파일 분석을 취소했습니다."
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

    func importPDF(
        from sourceURL: URL,
        sourceLanguage: LanguageOption,
        includeOCR: Bool = true
    ) {
        importFile(
            from: sourceURL,
            sourceLanguage: sourceLanguage,
            includeOCR: includeOCR
        )
    }

    func startTranslation(configuration: FileTranslationConfiguration) {
        do {
            let input = try validatedInputs(for: configuration)
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

            switch input.document {
            case let .pdf(analysis):
                beginTranslation(
                    analysis: analysis,
                    destinationURL: input.destinationURL,
                    client: client,
                    sourceLanguage: configuration.sourceLanguage,
                    targetLanguage: configuration.targetLanguage,
                    compositionPolicy: configuration.compositionPolicy,
                    renderMode: configuration.renderMode,
                    continueOnError: configuration.continueOnError
                )
            case let .text(textAnalysis):
                beginTextTranslation(
                    analysis: textAnalysis,
                    destinationURL: input.destinationURL,
                    client: client,
                    sourceLanguage: configuration.sourceLanguage,
                    targetLanguage: configuration.targetLanguage,
                    chunkingProfile: configuration.textChunkingProfile,
                    preserveMarkdownStructure: configuration.preserveMarkdownStructure,
                    translateMarkdownCodeBlocks: configuration.translateMarkdownCodeBlocks,
                    continueOnError: configuration.continueOnError
                )
            }
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
            startAppleLanguageModelWatchdog()
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

        defer {
            appleLanguageModelWatchdogTask?.cancel()
            appleLanguageModelWatchdogTask = nil
        }

        do {
            let input = try validatedInputs(for: configuration)
            pendingAppleConfiguration = nil
            let generation = nextOperationGeneration()
            switch input.document {
            case let .pdf(analysis):
                await performTranslation(
                    analysis: analysis,
                    destinationURL: input.destinationURL,
                    client: client,
                    sourceLanguage: configuration.sourceLanguage,
                    targetLanguage: configuration.targetLanguage,
                    compositionPolicy: configuration.compositionPolicy,
                    renderMode: configuration.renderMode,
                    continueOnError: configuration.continueOnError,
                    generation: generation
                )
            case let .text(textAnalysis):
                await performTextTranslation(
                    analysis: textAnalysis,
                    destinationURL: input.destinationURL,
                    client: client,
                    sourceLanguage: configuration.sourceLanguage,
                    targetLanguage: configuration.targetLanguage,
                    chunkingProfile: configuration.textChunkingProfile,
                    preserveMarkdownStructure: configuration.preserveMarkdownStructure,
                    translateMarkdownCodeBlocks: configuration.translateMarkdownCodeBlocks,
                    continueOnError: configuration.continueOnError,
                    generation: generation
                )
            }
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
        textAnalysis = nil
        outputURL = nil
        outputData = nil
        textOutput = nil
        sourceDocumentVersion &+= 1
        outputDocumentVersion &+= 1
        warnings = []
        errorMessage = nil
        preflightBlockingMessage = nil
        canUseBestEffortTranslation = false
        progress = 0
        translatedPageCount = 0
        skippedPageCount = 0
        stage = .idle
        statusMessage = "번역할 PDF, TXT 또는 Markdown 파일을 선택하거나 끌어다 놓으세요."
    }

    func reportFileSelectionError(_ error: Error) {
        errorMessage = Self.userFacingMessage(for: error)
        if analysis == nil {
            stage = .failed
        }
        statusMessage = "파일을 열지 못했습니다."
    }

    func reportUnsupportedDrop() {
        errorMessage = "PDF, TXT 또는 Markdown 파일만 번역할 수 있습니다."
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
        compositionPolicy: PDFDocumentCompositionPolicy,
        renderMode: PDFTranslationRenderMode,
        continueOnError: Bool
    ) {
        cancelCurrentOperation(setCancelledStage: false)
        let generation = nextOperationGeneration()
        let translatablePages = analysis.pages.filter { !$0.blocks.isEmpty }
        errorMessage = nil
        progress = 0
        translatedPageCount = 0
        skippedPageCount = 0
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
                renderMode: renderMode,
                continueOnError: continueOnError,
                generation: generation
            )
        }
    }

    private func beginTextTranslation(
        analysis: TextDocumentAnalysis,
        destinationURL: URL,
        client: any DocumentPageTranslationClient,
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        chunkingProfile: TextDocumentChunkingProfile,
        preserveMarkdownStructure: Bool,
        translateMarkdownCodeBlocks: Bool,
        continueOnError: Bool
    ) {
        cancelCurrentOperation(setCancelledStage: false)
        let preparedAnalysis = analysis
            .withMarkdownStructurePreserved(preserveMarkdownStructure)
            .withMarkdownCodeBlocksTranslated(translateMarkdownCodeBlocks)
            .rechunked(using: chunkingProfile.configuration)
        let generation = nextOperationGeneration()
        let total = preparedAnalysis.chunks.count
        errorMessage = nil
        progress = 0
        translatedPageCount = 0
        skippedPageCount = 0
        stage = .translating(page: 1, total: total)
        statusMessage = "텍스트를 문맥 단위 청크로 나누는 중입니다. (총 \(total)개)"
        operationTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.performTextTranslation(
                analysis: preparedAnalysis,
                destinationURL: destinationURL,
                client: client,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                chunkingProfile: chunkingProfile,
                preserveMarkdownStructure: preserveMarkdownStructure,
                translateMarkdownCodeBlocks: translateMarkdownCodeBlocks,
                continueOnError: continueOnError,
                generation: generation
            )
        }
    }

    private func performTextTranslation(
        analysis: TextDocumentAnalysis,
        destinationURL: URL,
        client: any DocumentPageTranslationClient,
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        chunkingProfile: TextDocumentChunkingProfile,
        preserveMarkdownStructure: Bool,
        translateMarkdownCodeBlocks: Bool,
        continueOnError: Bool,
        generation: UInt
    ) async {
        errorMessage = nil
        outputURL = nil
        outputData = nil
        textOutput = nil
        outputDocumentVersion &+= 1
        progress = 0
        translatedPageCount = 0
        skippedPageCount = 0

        do {
            let preparedAnalysis = analysis
                .withMarkdownStructurePreserved(preserveMarkdownStructure)
                .withMarkdownCodeBlocksTranslated(translateMarkdownCodeBlocks)
                .rechunked(using: chunkingProfile.configuration)
            guard !preparedAnalysis.chunks.isEmpty else {
                throw TextDocumentTranslationError.noTranslatableText
            }

            var translatedSegments: [String: String] = [:]
            translatedSegments.reserveCapacity(preparedAnalysis.translatableSegmentCount)

            for (offset, chunk) in preparedAnalysis.chunks.enumerated() {
                try Task.checkCancellation()
                guard operationGeneration == generation else {
                    throw CancellationError()
                }

                stage = .translating(
                    page: offset + 1,
                    total: preparedAnalysis.chunks.count
                )
                statusMessage = "텍스트 청크 \(offset + 1)/\(preparedAnalysis.chunks.count) 번역 중 · \(chunk.characterCount)자"
                progress = Double(offset) / Double(max(1, preparedAnalysis.chunks.count + 1))

                let request = try preparedAnalysis.request(
                    for: chunk,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                )
                do {
                    let result = try await client.translatePage(request)
                    let validated = try DocumentPageTranslationValidator.validateAndOrder(
                        result,
                        for: request
                    )
                    for translation in validated.translations {
                        translatedSegments[translation.id] = translation.translatedText
                    }
                    translatedPageCount += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard continueOnError else {
                        throw error
                    }
                    skippedPageCount += 1
                    warnings = Self.deduplicated(
                        warnings + [
                            "텍스트 청크 \(offset + 1) 번역 오류를 건너뛰었습니다: \(Self.userFacingMessage(for: error))"
                        ]
                    )
                    statusMessage = "텍스트 청크 \(offset + 1) 오류를 건너뛰고 계속하는 중입니다."
                }

                do {
                    textOutput = preparedAnalysis.renderedText(
                        translations: translatedSegments,
                        preserveSourceForMissing: true
                    )
                    outputData = try encodedTextData(
                        for: preparedAnalysis,
                        translations: translatedSegments,
                        preserveSourceForMissing: true
                    )
                    outputDocumentVersion &+= 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard continueOnError else {
                        throw error
                    }
                    warnings = Self.deduplicated(
                        warnings + [
                            "텍스트 청크 \(offset + 1) 미리보기 생성 오류를 건너뛰었습니다: \(Self.userFacingMessage(for: error))"
                        ]
                    )
                }
                progress = Double(offset + 1) / Double(max(1, preparedAnalysis.chunks.count + 1))
            }

            try Task.checkCancellation()
            guard operationGeneration == generation else {
                throw CancellationError()
            }

            stage = .composing
            statusMessage = "번역된 텍스트를 원본 인코딩과 구조로 저장하는 중입니다."
            progress = 0.92
            let finalData = try encodedTextData(
                for: preparedAnalysis,
                translations: translatedSegments,
                preserveSourceForMissing: true
            )
            let temporaryURL = Self.temporaryOutputURL(beside: destinationURL)
            var ownsTemporaryFile = false
            defer {
                if ownsTemporaryFile {
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
            }

            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try finalData.write(to: temporaryURL, options: .atomic)
            ownsTemporaryFile = true
            try Task.checkCancellation()
            guard operationGeneration == generation else {
                throw CancellationError()
            }
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            } catch {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    throw PDFDocumentServiceError.destinationAlreadyExists
                }
                throw PDFDocumentServiceError.cannotWriteOutput(error.localizedDescription)
            }
            ownsTemporaryFile = false

            outputURL = destinationURL
            outputData = finalData
            textOutput = preparedAnalysis.renderedText(
                translations: translatedSegments,
                preserveSourceForMissing: true
            )
            outputDocumentVersion &+= 1
            progress = 1
            stage = .completed
            statusMessage = "번역 \(preparedAnalysis.kind.displayName) 파일을 저장했습니다: \(destinationURL.lastPathComponent)"
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

    private func encodedTextData(
        for analysis: TextDocumentAnalysis,
        translations: [String: String],
        preserveSourceForMissing: Bool
    ) throws -> Data {
        do {
            return try analysis.encodedData(
                translations: translations,
                preserveSourceForMissing: preserveSourceForMissing
            )
        } catch TextDocumentTranslationError.cannotEncode {
            // A legacy single-byte file (for example ISO-8859-1) cannot
            // represent Korean, Japanese, or other translated glyphs. Keep
            // the text and structure intact by promoting the output to UTF-8
            // instead of failing the whole document after a long translation.
            warnings = Self.deduplicated(
                warnings + [
                    "원본 인코딩(\(analysis.encoding.rawValue))으로 일부 번역 문자를 저장할 수 없어 UTF-8로 출력했습니다."
                ]
            )
            guard let data = analysis.renderedText(
                translations: translations,
                preserveSourceForMissing: preserveSourceForMissing
            ).data(using: .utf8) else {
                throw TextDocumentTranslationError.cannotEncode("utf8")
            }
            return data
        }
    }

    private func performTranslation(
        analysis: PDFDocumentAnalysis,
        destinationURL: URL,
        client: any DocumentPageTranslationClient,
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        compositionPolicy: PDFDocumentCompositionPolicy,
        renderMode: PDFTranslationRenderMode,
        continueOnError: Bool,
        generation: UInt
    ) async {
        errorMessage = nil
        outputURL = nil
        outputData = nil
        outputDocumentVersion &+= 1
        progress = 0
        translatedPageCount = 0
        skippedPageCount = 0

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
                do {
                    let result = try await client.translatePage(request)
                    let validated = try DocumentPageTranslationValidator.validateAndOrder(
                        result,
                        for: request
                    )

                    for translation in validated.translations {
                        translatedBlocks[translation.id] = translation.translatedText
                    }
                    translatedPageCount += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard continueOnError else {
                        throw error
                    }
                    skippedPageCount += 1
                    warnings = Self.deduplicated(
                            warnings + [
                                "\(page.pageIndex + 1)페이지 번역 오류를 건너뛰었습니다: \(Self.userFacingMessage(for: error))"
                            ]
                        )
                    statusMessage = "\(page.pageIndex + 1)페이지 번역 오류를 건너뛰고 계속하는 중입니다."
                }

                if !translatedBlocks.isEmpty {
                    do {
                        let previewData = try await composePreviewData(
                            analysis: analysis,
                            translations: translatedBlocks,
                            destinationURL: destinationURL,
                            renderMode: renderMode
                        )
                        outputData = previewData
                        outputDocumentVersion &+= 1
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard continueOnError else {
                            throw error
                        }
                        warnings = Self.deduplicated(
                            warnings + [
                                "\(page.pageIndex + 1)페이지 미리보기 합성 오류를 건너뛰었습니다: \(Self.userFacingMessage(for: error))"
                            ]
                        )
                        statusMessage = "미리보기 합성 오류를 건너뛰고 \(page.pageIndex + 1)페이지를 계속하는 중입니다."
                    }
                }

                progress = Double(offset + 1) / Double(max(1, translatablePages.count + 1))
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
                        policy: continueOnError ? .bestEffort : compositionPolicy,
                        renderMode: renderMode,
                        allowMissingTranslations: continueOnError
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
    ) throws -> ValidatedFileTranslationInput {
        let document: LoadedFileTranslationDocument
        if let analysis {
            document = .pdf(analysis)
        } else if let textAnalysis {
            document = .text(textAnalysis)
        } else {
            throw FileTranslationViewModelError.documentNotLoaded
        }
        guard translatableBlockCount > 0 else {
            throw FileTranslationViewModelError.noTranslatableText
        }

        if case let .pdf(analysis) = document {
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
            sourceURL: sourceURLFor(document),
            targetLanguage: configuration.targetLanguage,
            locationRawValue: configuration.downloadLocation,
            explicitlySelectedURL: configuration.explicitlySelectedDestination,
            kind: document.kind
        )
        try validateDestinationDirectory(for: destinationURL)
        return ValidatedFileTranslationInput(
            document: document,
            destinationURL: destinationURL
        )
    }

    private func sourceURLFor(_ document: LoadedFileTranslationDocument) -> URL {
        switch document {
        case let .pdf(analysis):
            analysis.sourceURL
        case let .text(analysis):
            analysis.sourceURL
        }
    }

    private func composePreviewData(
        analysis: PDFDocumentAnalysis,
        translations: [String: String],
        destinationURL: URL,
        renderMode: PDFTranslationRenderMode
    ) async throws -> Data {
        let previewURL = Self.temporaryOutputURL(beside: destinationURL)
        let compositionTask = Task.detached(priority: .userInitiated) {
            defer {
                try? FileManager.default.removeItem(at: previewURL)
            }
            _ = try PDFDocumentCompositionService().compose(
                analysis: analysis,
                translations: translations,
                destinationURL: previewURL,
                policy: .bestEffort,
                renderMode: renderMode,
                allowMissingTranslations: true
            )
            return try Data(contentsOf: previewURL, options: .mappedIfSafe)
        }
        return try await withTaskCancellationHandler {
            try await compositionTask.value
        } onCancel: {
            compositionTask.cancel()
        }
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
        appleLanguageModelWatchdogTask?.cancel()
        appleLanguageModelWatchdogTask = nil
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

    private func startAppleLanguageModelWatchdog() {
        appleLanguageModelWatchdogTask?.cancel()
        appleLanguageModelWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.appleLanguageModelPreparationTimeout)
            } catch {
                return
            }

            guard let self,
                  self.stage.isBusy,
                  self.pendingAppleConfiguration != nil
                      || self.translatedPageCount == 0
            else {
                return
            }

            self.cancelCurrentOperation(setCancelledStage: false)
            let timeout = FileTranslationViewModelError
                .appleLanguageModelPreparationTimedOut
            self.errorMessage = Self.userFacingMessage(for: timeout)
            self.stage = .failed
            self.progress = 0
            self.statusMessage = "Apple 언어 팩 준비가 120초를 초과했습니다. 다시 시도하거나 다른 번역 엔진을 선택해 주세요."
        }
    }

    private func fail(with error: Error) {
        errorMessage = Self.userFacingMessage(for: error)
        stage = .failed
        if outputData == nil {
            statusMessage = "파일 번역을 완료하지 못했습니다."
            progress = 0
        } else {
            statusMessage = "오류가 발생했지만 현재까지 번역된 미리보기는 유지됩니다."
        }
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
