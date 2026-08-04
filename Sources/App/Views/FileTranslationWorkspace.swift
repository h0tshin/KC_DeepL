import AppKit
import PDFKit
import SwiftUI
import Translation
import UniformTypeIdentifiers
import KCDeepLCore

enum FileWorkspaceMode: Equatable {
    case translation
    case conversion
}

struct FileTranslationWorkspace: View {
    @ObservedObject var viewModel: FileTranslationViewModel
    @ObservedObject var conversionViewModel: DocumentConversionViewModel
    @Binding var sourceLanguage: LanguageOption
    @Binding var targetLanguage: LanguageOption
    var mode: FileWorkspaceMode = .translation

    @AppStorage(PreferenceKeys.fileTranslationEngine)
    private var engineRawValue = AppDefaults.defaultFileTranslationEngine.rawValue
    @AppStorage(PreferenceKeys.fileAPIModelID)
    private var apiModelID = AppDefaults.defaultFileAPIModelID
    @AppStorage(PreferenceKeys.codexModelID)
    private var codexModelID = AppDefaults.defaultCodexModelID
    // File translation uses the same key that is managed in Settings. Keeping
    // one source of truth prevents a successful text translation from using a
    // different (or empty) key than the main translation workflow.
    @AppStorage(PreferenceKeys.geminiAPIKey) private var apiKey = ""
    @AppStorage(PreferenceKeys.temperature) private var temperature = 0.2
    @AppStorage(PreferenceKeys.downloadLocation) private var downloadLocation = "desktop"
    @AppStorage(PreferenceKeys.fileTranslationRenderMode)
    private var renderModeRawValue = PDFTranslationRenderMode.preserveOriginalWithLayer.rawValue
    @AppStorage(PreferenceKeys.fileTranslationContinueOnError)
    private var continueOnError = true
    @AppStorage(PreferenceKeys.fileTranslationIncludeOCR)
    private var includeOCR = true
    @AppStorage(PreferenceKeys.fileTranslationPreserveMarkdown)
    private var preserveMarkdownStructure = true
    @AppStorage(PreferenceKeys.fileTranslationTranslateCode)
    private var translateMarkdownCodeBlocks = false
    @AppStorage(PreferenceKeys.fileTranslationTextChunkProfile)
    private var textChunkingProfileRawValue = TextDocumentChunkingProfile.balanced.rawValue

    @State private var isShowingImporter = false
    @State private var isDropTargeted = false
    @State private var allowsPotentiallyIncompleteOCR = false

    private var engine: FileTranslationEngine {
        get {
            FileTranslationEngine(rawValue: engineRawValue)
                ?? AppDefaults.defaultFileTranslationEngine
        }
        nonmutating set {
            engineRawValue = newValue.rawValue
        }
    }

    private var engineBinding: Binding<FileTranslationEngine> {
        Binding(get: { engine }, set: { engine = $0 })
    }

    private var renderMode: PDFTranslationRenderMode {
        get {
            PDFTranslationRenderMode(rawValue: renderModeRawValue)
                ?? .preserveOriginalWithLayer
        }
        nonmutating set {
            renderModeRawValue = newValue.rawValue
        }
    }

    private var renderModeBinding: Binding<PDFTranslationRenderMode> {
        Binding(get: { renderMode }, set: { renderMode = $0 })
    }

    private var textChunkingProfile: TextDocumentChunkingProfile {
        get {
            TextDocumentChunkingProfile(rawValue: textChunkingProfileRawValue)
                ?? .balanced
        }
        nonmutating set {
            textChunkingProfileRawValue = newValue.rawValue
        }
    }

    private var textChunkingProfileBinding: Binding<TextDocumentChunkingProfile> {
        Binding(get: { textChunkingProfile }, set: { textChunkingProfile = $0 })
    }

    private var activeDocumentKind: SupportedFileDocumentKind {
        viewModel.documentKind ?? .pdf
    }

    private var isConversionMode: Bool {
        mode == .conversion
    }

    private var importContentTypes: [UTType] {
        if isConversionMode {
            return [.pdf]
        }
        return [
            .pdf,
            .plainText,
            UTType(filenameExtension: "md") ?? .plainText
        ]
    }

    private var isAnyFileOperationBusy: Bool {
        viewModel.isBusy || conversionViewModel.isBusy
    }

    private var activeModelID: String {
        engine == .codexAppServer ? codexModelID : apiModelID
    }

    private var canStartTranslation: Bool {
        hasRunnableDocumentAndEngine
            && (viewModel.preflightBlockingMessage == nil
                || viewModel.canUseBestEffortTranslation)
            && (!viewModel.requiresIncompleteOCRAcknowledgement
                || allowsPotentiallyIncompleteOCR
                || continueOnError)
    }

    private var hasRunnableDocumentAndEngine: Bool {
        viewModel.documentKind != nil
            && viewModel.translatableBlockCount > 0
            && !viewModel.isBusy
            && !conversionViewModel.isBusy
            && (sourceLanguage == .autoDetect || sourceLanguage != targetLanguage)
            && isEngineReady
    }

    private var shouldOfferBestEffortTranslation: Bool {
        viewModel.canUseBestEffortTranslation
            || (viewModel.preflightBlockingMessage == nil
                && viewModel.requiresIncompleteOCRAcknowledgement
                && !allowsPotentiallyIncompleteOCR)
    }

    private var canStartBestEffortTranslation: Bool {
        hasRunnableDocumentAndEngine
            && (viewModel.preflightBlockingMessage == nil
                || viewModel.canUseBestEffortTranslation)
    }

    private var isEngineReady: Bool {
        switch engine {
        case .apple:
            if #available(macOS 15.0, *) {
                return true
            }
            return false
        case .codexAppServer:
            return viewModel.codexModels.contains {
                $0.model == codexModelID
            }
        case .geminiAPI:
            return !apiModelID.isEmpty
                && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isConversionMode {
                HStack {
                    Text("PDF -> PPT / DOC 변환")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(height: 42)
                .background(AppTheme.panelBackground)

                Divider()
            }

            if !isConversionMode {
                languageToolbar
                Divider()
            }

            HSplitView {
                previewPane
                    .frame(minWidth: 570, maxWidth: .infinity, maxHeight: .infinity)

                inspectorPane
                    .frame(minWidth: 310, idealWidth: 340, maxWidth: 380, maxHeight: .infinity)
            }

            Divider()
            statusBar
        }
        .background(AppTheme.panelBackground)
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: importContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if !isAnyFileOperationBusy, let url = urls.first {
                    importDocument(url)
                }
            case .failure(let error):
                viewModel.reportFileSelectionError(error)
            }
        }
        .task(id: engine) {
            guard !isConversionMode, engine == .codexAppServer else {
                return
            }
            await viewModel.refreshCodexModels()
            normalizeCodexModelSelection()
        }
        .onChange(of: viewModel.codexModels) { _, _ in
            normalizeCodexModelSelection()
        }
        .onChange(of: viewModel.sourceDocumentVersion) { _, _ in
            allowsPotentiallyIncompleteOCR = false
        }
        .onChange(of: includeOCR) { _, _ in
            reanalyzeForOCRSetting()
        }
        .onAppear {
            normalizeEngineAvailability()
        }
    }

    private var languageToolbar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(LanguageOption.sourceLanguages) { language in
                    Button(language.displayName) {
                        sourceLanguage = language
                    }
                }
            } label: {
                LanguageSelectionLabel(language: sourceLanguage)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 160)

            Button(action: swapLanguages) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 6))
            .help("언어 바꾸기")

            Menu {
                ForEach(LanguageOption.targetLanguages) { language in
                    Button(language.displayName) {
                        targetLanguage = language
                    }
                }
            } label: {
                LanguageSelectionLabel(language: targetLanguage)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 160)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(AppTheme.toolbarBackground)
        .disabled(isAnyFileOperationBusy)
    }

    @ViewBuilder
    private var previewPane: some View {
        if viewModel.documentKind != nil {
            VStack(spacing: 0) {
                HStack {
                    Label(
                        "문서 미리보기",
                        systemImage: isConversionMode ? "doc.richtext" : "rectangle.split.2x1"
                    )
                        .font(.headline)

                    Spacer()

                    Text(documentStatsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        viewModel.clearDocument()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("문서 닫기")
                    .disabled(isAnyFileOperationBusy)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)

                Divider()

                Group {
                    if isConversionMode {
                        sourcePreview
                    } else {
                        HSplitView {
                            sourcePreview
                            translatedPreview
                        }
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard !isAnyFileOperationBusy else {
                        return false
                    }
                    guard let supportedURL = urls.first(where: isSupportedDocument) else {
                        viewModel.reportUnsupportedDrop()
                        return false
                    }
                    importDocument(supportedURL)
                    return true
                } isTargeted: { isTargeted in
                    isDropTargeted = isTargeted
                }
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(AppTheme.accent, style: StrokeStyle(lineWidth: 3, dash: [8]))
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
            }
        } else {
            FileDropZone(
                isTargeted: isDropTargeted,
                isAnalyzing: viewModel.stage == .analyzing,
                isConversionMode: isConversionMode,
                onChoose: { isShowingImporter = true }
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard !isAnyFileOperationBusy else {
                    return false
                }
                guard let supportedURL = urls.first(where: isSupportedDocument) else {
                    viewModel.reportUnsupportedDrop()
                    return false
                }
                importDocument(supportedURL)
                return true
            } isTargeted: { isTargeted in
                isDropTargeted = isTargeted
            }
        }
    }

    @ViewBuilder
    private var sourcePreview: some View {
        if viewModel.isTextDocument,
           let sourceText = viewModel.sourceText {
            textPreview(
                title: "원본",
                subtitle: "원문 \(activeDocumentKind.displayName)",
                text: sourceText,
                isTranslated: false
            )
        } else if let sourceData = viewModel.sourceData {
            documentPreview(
                title: "원본",
                subtitle: "원문 PDF",
                data: sourceData,
                version: viewModel.sourceDocumentVersion,
                isTranslated: false
            )
        } else {
            ContentUnavailableView(
                "원본 문서를 불러올 수 없습니다",
                systemImage: "doc.richtext",
                description: Text("문서를 닫은 뒤 다시 선택해 주세요.")
            )
        }
    }

    @ViewBuilder
    private var translatedPreview: some View {
        if viewModel.isTextDocument {
            textPreview(
                title: "번역본",
                subtitle: translatedTextPreviewSubtitle,
                text: viewModel.translatedText,
                isTranslated: true
            )
        } else {
            documentPreview(
                title: "번역본",
                subtitle: translatedPreviewSubtitle,
                data: viewModel.outputData,
                version: viewModel.outputDocumentVersion,
                isTranslated: true
            )
        }
    }

    private var translatedPreviewSubtitle: String {
        if viewModel.outputData == nil {
            return "번역을 시작하면 페이지별로 표시됩니다"
        }
        return "\(viewModel.translatedPageCount)/\(max(1, viewModel.pageCount))페이지 번역됨"
    }

    private var translatedTextPreviewSubtitle: String {
        if viewModel.translatedText == nil {
            return "번역을 시작하면 청크별로 표시됩니다"
        }
        return "\(viewModel.translatedPageCount)/\(max(1, viewModel.textChunkCount))청크 번역됨"
    }

    private var documentStatsText: String {
        if viewModel.isTextDocument {
            return "\(activeDocumentKind.displayName) · \(viewModel.translatableBlockCount)개 영역 · \(viewModel.textChunkCount)개 청크"
        }
        return "\(viewModel.pageCount)페이지 · \(viewModel.translatableBlockCount)개 텍스트 영역"
    }

    private func textPreview(
        title: String,
        subtitle: String,
        text: String?,
        isTranslated: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if isTranslated, viewModel.skippedPageCount > 0 {
                    Text("\(viewModel.skippedPageCount)청크 건너뜀")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            Group {
                if let text {
                    ScrollView([.vertical, .horizontal]) {
                        Text(text)
                            .font(AppFont.monospacedSwiftUIFont(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(18)
                            // Recreate the text view for each committed
                            // preview version. This avoids SwiftUI retaining
                            // the initial nil-result branch of a large
                            // HSplitView child after the first chunk arrives.
                            .id(isTranslated
                                ? "translated-(viewModel.outputDocumentVersion)"
                                : "source-(viewModel.sourceDocumentVersion)")
                    }
                } else {
                    ContentUnavailableView(
                        "번역본이 아직 없습니다",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("청크 번역이 끝날 때마다 이 영역이 갱신됩니다.")
                    )
                }
            }
            .overlay {
                if isTranslated, viewModel.isBusy {
                    VStack(spacing: 8) {
                        ProgressView(value: viewModel.progress)
                            .progressViewStyle(.linear)
                        Text(viewModel.statusMessage)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .padding(12)
                    .frame(maxWidth: 260)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func documentPreview(
        title: String,
        subtitle: String,
        data: Data?,
        version: UInt,
        isTranslated: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if isTranslated, viewModel.skippedPageCount > 0 {
                    Text("\(viewModel.skippedPageCount)페이지 건너뜀")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            Group {
                if let data {
                    PDFPreview(data: data, version: version)
                } else {
                    ContentUnavailableView(
                        "번역본이 아직 없습니다",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("페이지 번역이 끝날 때마다 이 영역이 갱신됩니다.")
                    )
                }
            }
            .overlay {
                if isTranslated, viewModel.isBusy {
                    VStack(spacing: 8) {
                        ProgressView(value: viewModel.progress)
                            .progressViewStyle(.linear)
                        Text(viewModel.statusMessage)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .padding(12)
                    .frame(maxWidth: 260)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let filename = viewModel.filename {
                    documentSummary(filename: filename)
                }

                if isConversionMode {
                    DocumentConversionSection(
                        conversionViewModel: conversionViewModel,
                        fileTranslationViewModel: viewModel,
                        downloadLocation: $downloadLocation
                    )
                } else {
                    if viewModel.preflightBlockingMessage != nil
                        || viewModel.requiresIncompleteOCRAcknowledgement {
                        readinessSection
                    }

                    engineSettings
                        .disabled(isAnyFileOperationBusy)
                    outputSettings
                        .disabled(isAnyFileOperationBusy)

                    if let errorMessage = viewModel.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    actionSection

                    if !viewModel.warnings.isEmpty {
                        warningSection
                    }
                }
            }
            .padding(20)
        }
        .background(AppTheme.elevatedBackground.opacity(0.42))
    }

    private func documentSummary(filename: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(filename, systemImage: "doc.richtext")
                .font(.headline)
                .lineLimit(2)
            Text(isConversionMode ? conversionSummary : renderModeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var conversionSummary: String {
        "PDF의 텍스트·이미지·도형을 편집 가능한 파워포인트 또는 워드 문서로 변환합니다."
    }

    private var renderModeSummary: String {
        if viewModel.isTextDocument {
            if activeDocumentKind == .markdown {
                return preserveMarkdownStructure
                    ? "Markdown 구조와 코드 펜스를 보존하고, 본문만 안정적인 청크로 번역합니다."
                    : "Markdown 기호도 번역 입력에 포함합니다. 구조 보존이 필요하면 옵션을 켜세요."
            }
            return "원본 인코딩과 줄 끝을 유지하면서 텍스트를 문맥 단위 청크로 번역합니다."
        }
        switch renderMode {
        case .replaceText:
            return "원본 텍스트를 번역문으로 교체하는 콘텐츠 재구성 방식으로 저장합니다."
        case .preserveOriginalWithLayer:
            return "원본 페이지를 보존하고 번역 레이어를 추가해 이미지와 배치를 안정적으로 유지합니다."
        case .hybrid:
            return "네이티브 텍스트는 교체하고 OCR·이미지 영역은 번역 레이어로 보완합니다."
        }
    }

    private var engineSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("번역 엔진")
                .font(.headline)

            Picker("엔진", selection: engineBinding) {
                ForEach(FileTranslationEngine.allCases) { candidate in
                    Text(engineTitle(candidate)).tag(candidate)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            switch engine {
            case .apple:
                appleEngineSettings
            case .codexAppServer:
                codexEngineSettings
            case .geminiAPI:
                geminiEngineSettings
            }
        }
    }

    @ViewBuilder
    private var appleEngineSettings: some View {
        if #available(macOS 15.0, *) {
            Label("기기에서 처리 · 첫 사용 시 언어 모델 다운로드", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Apple 내장 번역은 macOS 15 이상에서 사용할 수 있습니다.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var codexEngineSettings: some View {
        if viewModel.isLoadingCodexModels && viewModel.codexModels.isEmpty {
            ProgressView("Codex 모델을 불러오는 중입니다.")
                .controlSize(.small)
        } else if viewModel.codexModels.isEmpty {
            Text("사용 가능한 Codex 모델을 찾지 못했습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("모델", selection: $codexModelID) {
                ForEach(viewModel.codexModels) { model in
                    Text(model.displayName).tag(model.model)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }

        HStack {
            Text("현재 Mac의 Codex 로그인 사용")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("새로고침") {
                Task {
                    await viewModel.refreshCodexModels()
                    normalizeCodexModelSelection()
                }
            }
            .controlSize(.small)
            .disabled(viewModel.isLoadingCodexModels)
        }

        if let modelError = viewModel.codexModelErrorMessage {
            Text(modelError)
                .font(.caption)
                .foregroundStyle(.orange)
        }

        Text("번역한 페이지 내용과 결과는 KC DeepL의 Codex 번역 작업 기록에 남을 수 있습니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var geminiEngineSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("모델", selection: $apiModelID) {
                ForEach(LLMProvider.gemini.models) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            SecureField("설정에 저장된 Gemini API 키", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            Text("페이지 내용은 선택한 Gemini 모델로 전송됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("이 키는 설정 화면과 공유되며, 파일 번역도 설정에 저장된 키를 사용합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var outputSettings: some View {
        if viewModel.isTextDocument {
            textOutputSettings
        } else {
            pdfOutputSettings
        }
    }

    private var textOutputSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("문서 구조")
                .font(.headline)

            Toggle("Markdown 구조(헤딩·목록·표) 보존", isOn: $preserveMarkdownStructure)
                .toggleStyle(.checkbox)

            Text("마크다운 기호와 줄 끝은 모델에 보내지 않고 원본 위치에 다시 붙입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if activeDocumentKind == .markdown {
                Toggle("코드 블록도 번역", isOn: $translateMarkdownCodeBlocks)
                    .toggleStyle(.checkbox)
                Text(
                    translateMarkdownCodeBlocks
                        ? "코드 펜스 자체는 보존하고 내부 줄만 번역합니다. 변수·문법이 있는 코드는 기본값(끔)을 권장합니다."
                        : "``` 또는 ~~~ 코드 블록은 원문 그대로 보존합니다."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("청크 전략")
                .font(.headline)

            Picker("청크 전략", selection: textChunkingProfileBinding) {
                ForEach(TextDocumentChunkingProfile.allCases) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Text(textChunkingProfile.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(textChunkingProfile.configuration.description)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle(
                "번역 오류가 나도 해당 청크를 원문으로 남기고 계속",
                isOn: $continueOnError
            )
                .toggleStyle(.checkbox)

            Text("청크 단위로 재시도하며, 실패한 부분만 원문으로 남깁니다. 이미 완료된 결과는 롤백하지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("저장 위치")
                .font(.headline)
            Picker("위치", selection: $downloadLocation) {
                Text("데스크탑").tag(FileTranslationOutputLocation.desktop.rawValue)
                Text("다운로드").tag(FileTranslationOutputLocation.downloads.rawValue)
                Text("매번 묻기").tag(FileTranslationOutputLocation.ask.rawValue)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            Text("원본 파일은 절대 덮어쓰지 않습니다. UTF-8/UTF-16 BOM과 줄 끝 형식도 보존합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pdfOutputSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("텍스트 인식")
                .font(.headline)

            Toggle("이미지 영역 OCR 포함", isOn: $includeOCR)
                .toggleStyle(.checkbox)

            Text(
                includeOCR
                    ? "네이티브 PDF 텍스트와 이미지 안의 글자를 함께 분석합니다."
                    : "PDF에 포함된 네이티브 텍스트만 분석합니다. OCR을 실행하지 않으므로 이미지 안의 글자는 번역하지 않습니다."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("번역 결과")
                .font(.headline)

            Picker("결과 방식", selection: renderModeBinding) {
                ForEach(PDFTranslationRenderMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Text(renderMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "레이아웃·번역 오류가 나도 건너뛰고 계속",
                isOn: $continueOnError
            )
            .toggleStyle(.checkbox)

            Text("문제가 난 페이지나 영역은 원문으로 남기고, 나머지 페이지의 번역과 미리보기를 계속합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("저장 위치")
                .font(.headline)

            Picker("위치", selection: $downloadLocation) {
                Text("데스크탑").tag(FileTranslationOutputLocation.desktop.rawValue)
                Text("다운로드").tag(FileTranslationOutputLocation.downloads.rawValue)
                Text("매번 묻기").tag(FileTranslationOutputLocation.ask.rawValue)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Text("원본 파일은 절대 덮어쓰지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("원본 파일은 절대 덮어쓰지 않으며, 선택한 결과 방식에 따라 PDF 내부 텍스트 검색 결과가 달라질 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("주석을 숨기는 뷰어·인쇄 설정이나 VoiceOver에서는 원문이 보이거나 함께 읽힐 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var warningSection: some View {
        DisclosureGroup("세부 경고 \(viewModel.warnings.count)개") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(
                    Array(viewModel.warnings.enumerated()),
                    id: \.offset
                ) { _, warning in
                    Text("• \(warning)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.caption)
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("번역 전 확인", systemImage: "checklist")
                .font(.headline)

            if let blocker = viewModel.preflightBlockingMessage {
                Label(
                    blocker,
                    systemImage: viewModel.canUseBestEffortTranslation
                        ? "exclamationmark.triangle.fill"
                        : "xmark.octagon.fill"
                )
                    .font(.caption)
                    .foregroundStyle(
                        viewModel.canUseBestEffortTranslation
                            ? Color.orange
                            : Color.red
                    )
                    .fixedSize(horizontal: false, vertical: true)
                if viewModel.canUseBestEffortTranslation {
                    Text("무시하고 번역하면 안전하게 덮을 수 없는 문장은 원문으로 남기고 나머지만 번역합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if viewModel.requiresIncompleteOCRAcknowledgement {
                Toggle(
                    "이미지 안의 글자가 일부 누락될 수 있음을 확인하고 계속",
                    isOn: $allowsPotentiallyIncompleteOCR
                )
                .toggleStyle(.checkbox)
                .font(.caption)
            }
        }
        .padding(12)
        .background(
            AppTheme.controlBackground,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.isBusy {
                ProgressView(value: viewModel.progress) {
                    Text(viewModel.statusMessage)
                        .font(.caption)
                }
                Button("취소", role: .cancel) {
                    viewModel.cancelTranslation()
                }
                .frame(maxWidth: .infinity)
                Text(progressCountText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    startTranslation(bestEffort: false)
                } label: {
                    Label(
                        startButtonTitle,
                        systemImage: "character.book.closed"
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canStartTranslation)

                if shouldOfferBestEffortTranslation {
                    Button {
                        startTranslation(bestEffort: true)
                    } label: {
                        Label(
                            "무시하고 번역",
                            systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.large)
                    .disabled(!canStartBestEffortTranslation)

                    Text(bestEffortDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let outputURL = viewModel.outputURL {
                HStack {
                    Button("번역본 열기") {
                        NSWorkspace.shared.open(outputURL)
                    }
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var startButtonTitle: String {
        let name = viewModel.isTextDocument
            ? "파일 번역 시작"
            : "PDF 번역 시작"
        return continueOnError ? "\(name) (오류 건너뛰기)" : name
    }

    private var progressCountText: String {
        let unit = viewModel.isTextDocument ? "청크" : "페이지"
        return "번역 완료 \(viewModel.translatedPageCount)\(unit) · 건너뜀 \(viewModel.skippedPageCount)\(unit)"
    }

    private var bestEffortDetail: String {
        if viewModel.isTextDocument {
            return "실패한 청크는 원문으로 남기고 나머지 청크를 계속 저장합니다."
        }
        return "누락 가능한 이미지 글자와 보존 불가 영역을 건너뛴 PDF를 생성합니다. 암호·서명·손상 문서와 저장 오류는 우회하지 않습니다."
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(isConversionMode ? conversionViewModel.statusMessage : viewModel.statusMessage)
                .lineLimit(1)
            Spacer()
            if isConversionMode {
                if conversionViewModel.stage == .completed {
                    Text("Office 문서 저장 완료")
                        .foregroundStyle(AppTheme.success)
                }
            } else {
                if viewModel.translatedPageCount > 0 || viewModel.skippedPageCount > 0 {
                    Text("완료 \(viewModel.translatedPageCount) · 건너뜀 \(viewModel.skippedPageCount)")
                        .foregroundStyle(.secondary)
                }
                if viewModel.stage == .completed {
                    Text(viewModel.isTextDocument ? "출력 텍스트 구조 보존 완료" : "출력 PDF 구조 재검증 완료")
                        .foregroundStyle(AppTheme.success)
                }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(AppTheme.elevatedBackground)
    }

    private var statusIcon: String {
        if isConversionMode {
            switch conversionViewModel.stage {
            case .completed:
                return "checkmark.circle.fill"
            case .failed:
                return "exclamationmark.triangle.fill"
            case .cancelled:
                return "xmark.circle"
            case .preparing, .converting, .validating:
                return "arrow.triangle.2.circlepath"
            case .idle:
                return "circle.fill"
            }
        }
        switch viewModel.stage {
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .cancelled:
            return "xmark.circle"
        case .analyzing, .waitingForApple, .translating, .composing:
            return "arrow.triangle.2.circlepath"
        case .idle, .ready:
            return "circle.fill"
        }
    }

    private var statusColor: Color {
        if isConversionMode {
            switch conversionViewModel.stage {
            case .completed:
                return AppTheme.success
            case .failed:
                return .orange
            default:
                return .secondary
            }
        }
        switch viewModel.stage {
        case .completed:
            return AppTheme.success
        case .failed:
            return .orange
        default:
            return .secondary
        }
    }

    private func startTranslation(bestEffort: Bool) {
        let explicitDestination: URL?
        if downloadLocation == FileTranslationOutputLocation.ask.rawValue {
            guard let sourceURL = viewModel.sourceURL,
                  let selectedURL = FileTranslationPanel.chooseDestination(
                    sourceURL: sourceURL,
                    targetLanguage: targetLanguage,
                    kind: activeDocumentKind
                  )
            else {
                return
            }
            explicitDestination = selectedURL
        } else {
            explicitDestination = nil
        }

        let configuration = FileTranslationConfiguration(
            engine: engine,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            modelID: activeModelID,
            apiKey: apiKey,
            temperature: temperature,
            downloadLocation: downloadLocation,
            explicitlySelectedDestination: explicitDestination,
            allowsPotentiallyIncompleteOCR: bestEffort
                || allowsPotentiallyIncompleteOCR
                || continueOnError,
            compositionPolicy: bestEffort || continueOnError ? .bestEffort : .strict,
            renderMode: renderMode,
            continueOnError: continueOnError,
            includeOCR: includeOCR,
            preserveMarkdownStructure: preserveMarkdownStructure,
            translateMarkdownCodeBlocks: translateMarkdownCodeBlocks,
            textChunkingProfile: textChunkingProfile
        )

        if engine == .apple {
            viewModel.requestAppleTranslation(configuration: configuration)
        } else {
            viewModel.startTranslation(configuration: configuration)
        }
    }

    private func importDocument(_ url: URL) {
        viewModel.importFile(
            from: url,
            sourceLanguage: sourceLanguage,
            includeOCR: includeOCR
        )
    }

    private func reanalyzeForOCRSetting() {
        guard let sourceURL = viewModel.sourceURL,
              !viewModel.isBusy,
              !conversionViewModel.isBusy else {
            return
        }
        guard viewModel.isPDFDocument else {
            return
        }
        viewModel.reanalyzeSelectedPDF(
            from: sourceURL,
            sourceLanguage: sourceLanguage,
            includeOCR: includeOCR
        )
    }

    private func isSupportedDocument(_ url: URL) -> Bool {
        if isConversionMode {
            return url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
        }
        if url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame {
            return true
        }
        return SupportedFileDocumentKind.kind(forFileExtension: url.pathExtension)?.isTextBased == true
            || url.pathExtension.isEmpty
    }

    private func swapLanguages() {
        if sourceLanguage == .autoDetect {
            sourceLanguage = targetLanguage
            targetLanguage = targetLanguage == .korean ? .english : .korean
        } else {
            swap(&sourceLanguage, &targetLanguage)
        }
    }

    private func engineTitle(_ candidate: FileTranslationEngine) -> String {
        if candidate == .apple {
            if #available(macOS 15.0, *) {
                return candidate.displayName
            }
            return "\(candidate.displayName) (macOS 15+)"
        }
        return candidate.displayName
    }

    private func normalizeCodexModelSelection() {
        guard !viewModel.codexModels.isEmpty,
              !viewModel.codexModels.contains(where: { $0.model == codexModelID })
        else {
            return
        }
        codexModelID = viewModel.codexModels.first(where: \.isDefault)?.model
            ?? viewModel.codexModels[0].model
    }

    private func normalizeEngineAvailability() {
        guard engine == .apple else {
            return
        }
        if #available(macOS 15.0, *) {
            return
        }
        engine = .codexAppServer
    }
}

private struct LanguageSelectionLabel: View {
    let language: LanguageOption

    var body: some View {
        HStack(spacing: 7) {
            Text(language.displayName)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct FileDropZone: View {
    let isTargeted: Bool
    let isAnalyzing: Bool
    let isConversionMode: Bool
    let onChoose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            if isAnalyzing {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(isTargeted ? AppTheme.accent : .secondary)
            }

            VStack(spacing: 7) {
                Text(isAnalyzing
                    ? "파일을 분석하는 중입니다"
                    : isConversionMode
                        ? "PDF 파일을 여기에 놓으세요"
                        : "PDF·TXT·Markdown 파일을 여기에 놓으세요")
                    .font(.title2.bold())
                Text(isConversionMode
                    ? "페이지 배치를 유지한 편집 가능한 Office 문서로 변환합니다."
                    : "PDF는 페이지 위치를, 텍스트 파일은 구조와 줄 순서를 보존해 번역합니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button("파일 선택", action: onChoose)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAnalyzing)

            Label(
                isConversionMode ? "지원 형식: PDF" : "지원 형식: PDF · TXT · MD",
                systemImage: "checkmark.seal"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(isTargeted ? AppTheme.accent.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    isTargeted ? AppTheme.accent : AppTheme.panelBorder,
                    style: StrokeStyle(lineWidth: isTargeted ? 3 : 1, dash: [9])
                )
        )
        .padding(32)
    }
}

private struct PDFPreview: NSViewRepresentable {
    let data: Data
    let version: UInt

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = AppTheme.panelNSColor
        updateDocument(in: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        updateDocument(in: view, coordinator: context.coordinator)
    }

    private func updateDocument(in view: PDFView, coordinator: Coordinator) {
        guard coordinator.dataVersion != version else {
            return
        }
        coordinator.dataVersion = version
        view.document = PDFDocument(data: data)
    }

    final class Coordinator {
        var dataVersion: UInt?
    }
}

@available(macOS 15.0, *)
struct AppleFileTranslationTaskHost: View {
    @ObservedObject var viewModel: FileTranslationViewModel
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .onAppear {
                // The host is mounted with the main window. If a request was
                // queued before SwiftUI registered the change observer, make
                // sure the pending configuration is still installed.
                configureForPendingRequest()
            }
            .onChange(of: viewModel.appleRequestGeneration) { _, _ in
                configureForPendingRequest()
            }
            .onChange(of: viewModel.appleCancellationGeneration) { _, _ in
                guard viewModel.pendingAppleConfiguration == nil else {
                    return
                }
                configuration = nil
            }
            .translationTask(configuration) { session in
                let client = AppleDocumentTranslationClient(
                    session: session,
                    progressHandler: { [weak viewModel] progress in
                        viewModel?.reportAppleTranslationProgress(progress.message)
                    }
                )
                await viewModel.performPendingAppleTranslation(using: client)
                if !Task.isCancelled {
                    configuration = nil
                }
            }
    }

    private func configureForPendingRequest() {
        guard let pending = viewModel.pendingAppleConfiguration else {
            configuration = nil
            return
        }

        let requested: TranslationSession.Configuration
        do {
            requested = try AppleDocumentTranslationClient.configuration(
                sourceLanguage: pending.sourceLanguage,
                targetLanguage: pending.targetLanguage
            )
        } catch {
            configuration = nil
            viewModel.reportTranslationError(error)
            return
        }

        if configuration == requested {
            configuration?.invalidate()
        } else {
            configuration = requested
        }
    }
}

private enum FileTranslationPanel {
    @MainActor
    static func chooseDestination(
        sourceURL: URL,
        targetLanguage: LanguageOption,
        kind: SupportedFileDocumentKind
    ) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType(for: kind)]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = (
            try? FileTranslationOutputURLResolver().suggestedFilename(
                for: sourceURL,
                targetLanguage: targetLanguage,
                kind: kind
            )
        ) ?? "translated.\(kind.defaultOutputExtension)"
        panel.message = "원본 파일과 다른 이름으로 번역본을 저장합니다."
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func contentType(for kind: SupportedFileDocumentKind) -> UTType {
        switch kind {
        case .pdf:
            .pdf
        case .plainText:
            .plainText
        case .markdown:
            UTType(filenameExtension: "md") ?? .plainText
        }
    }
}
