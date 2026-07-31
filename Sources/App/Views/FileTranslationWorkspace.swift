import AppKit
import PDFKit
import SwiftUI
import Translation
import UniformTypeIdentifiers
import KCDeepLCore

struct FileTranslationWorkspace: View {
    @ObservedObject var viewModel: FileTranslationViewModel
    @Binding var sourceLanguage: LanguageOption
    @Binding var targetLanguage: LanguageOption

    @AppStorage(PreferenceKeys.fileTranslationEngine)
    private var engineRawValue = AppDefaults.defaultFileTranslationEngine.rawValue
    @AppStorage(PreferenceKeys.fileAPIModelID)
    private var apiModelID = AppDefaults.defaultFileAPIModelID
    @AppStorage(PreferenceKeys.codexModelID)
    private var codexModelID = AppDefaults.defaultCodexModelID
    // File contents can be sensitive, so this workflow never persists its API key.
    @State private var apiKey = ""
    @AppStorage(PreferenceKeys.temperature) private var temperature = 0.2
    @AppStorage(PreferenceKeys.downloadLocation) private var downloadLocation = "desktop"

    @State private var isShowingImporter = false
    @State private var isDropTargeted = false
    @State private var previewSelection = FilePreviewSelection.source
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

    private var activeModelID: String {
        engine == .codexAppServer ? codexModelID : apiModelID
    }

    private var canStartTranslation: Bool {
        hasRunnableDocumentAndEngine
            && viewModel.preflightBlockingMessage == nil
            && (!viewModel.requiresIncompleteOCRAcknowledgement
                || allowsPotentiallyIncompleteOCR)
    }

    private var hasRunnableDocumentAndEngine: Bool {
        viewModel.analysis != nil
            && viewModel.translatableBlockCount > 0
            && !viewModel.isBusy
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
            fileToolbar
            Divider()

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
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    importPDF(url)
                }
            case .failure(let error):
                viewModel.reportFileSelectionError(error)
            }
        }
        .task(id: engine) {
            guard engine == .codexAppServer else {
                return
            }
            await viewModel.refreshCodexModels()
            normalizeCodexModelSelection()
        }
        .onChange(of: viewModel.codexModels) { _, _ in
            normalizeCodexModelSelection()
        }
        .onChange(of: viewModel.outputURL) { _, outputURL in
            if outputURL != nil {
                previewSelection = .translated
            }
        }
        .onChange(of: viewModel.sourceDocumentVersion) { _, _ in
            allowsPotentiallyIncompleteOCR = false
        }
        .onAppear {
            normalizeEngineAvailability()
        }
    }

    private var fileToolbar: some View {
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

            Spacer()

            Picker("번역 엔진", selection: engineBinding) {
                ForEach(FileTranslationEngine.allCases) { candidate in
                    Text(engineTitle(candidate)).tag(candidate)
                }
            }
            .labelsHidden()
            .frame(width: 210)

            Button("PDF 선택", systemImage: "doc.badge.plus") {
                isShowingImporter = true
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(AppTheme.toolbarBackground)
        .disabled(viewModel.isBusy)
    }

    @ViewBuilder
    private var previewPane: some View {
        if let sourceData = viewModel.sourceData {
            VStack(spacing: 0) {
                HStack {
                    Picker("미리보기", selection: $previewSelection) {
                        Text("원본").tag(FilePreviewSelection.source)
                        Text("번역본").tag(FilePreviewSelection.translated)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)

                    Spacer()

                    Text("\(viewModel.pageCount)페이지 · \(viewModel.translatableBlockCount)개 텍스트 영역")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        viewModel.clearDocument()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("문서 닫기")
                    .disabled(viewModel.isBusy)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)

                Divider()

                Group {
                    if previewSelection == .translated,
                       let translatedData = viewModel.outputData {
                        PDFPreview(
                            data: translatedData,
                            version: viewModel.outputDocumentVersion
                        )
                    } else {
                        PDFPreview(
                            data: sourceData,
                            version: viewModel.sourceDocumentVersion
                        )
                    }
                }
                .overlay {
                    if previewSelection == .translated, viewModel.outputData == nil {
                        ContentUnavailableView(
                            "번역본이 아직 없습니다",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("번역을 완료하면 원본 위치에 배치된 결과를 미리 볼 수 있습니다.")
                        )
                        .background(.ultraThinMaterial)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard !viewModel.isBusy else {
                        return false
                    }
                    guard let pdfURL = urls.first(where: isPDF) else {
                        viewModel.reportUnsupportedDrop()
                        return false
                    }
                    importPDF(pdfURL)
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
            PDFDropZone(
                isTargeted: isDropTargeted,
                isAnalyzing: viewModel.stage == .analyzing,
                onChoose: { isShowingImporter = true }
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard !viewModel.isBusy else {
                    return false
                }
                guard let pdfURL = urls.first(where: isPDF) else {
                    viewModel.reportUnsupportedDrop()
                    return false
                }
                importPDF(pdfURL)
                return true
            } isTargeted: { isTargeted in
                isDropTargeted = isTargeted
            }
        }
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let filename = viewModel.filename {
                    documentSummary(filename: filename)
                }

                if viewModel.preflightBlockingMessage != nil
                    || viewModel.requiresIncompleteOCRAcknowledgement {
                    readinessSection
                }

                engineSettings
                    .disabled(viewModel.isBusy)
                outputSettings
                    .disabled(viewModel.isBusy)

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
            .padding(20)
        }
        .background(AppTheme.elevatedBackground.opacity(0.42))
    }

    private func documentSummary(filename: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(filename, systemImage: "doc.richtext")
                .font(.headline)
                .lineLimit(2)
            Text("원본 content stream 위에 마스크와 번역 레이어를 추가하며, 저장 후 PDF 구조를 다시 검증합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

            SecureField("Gemini API 키", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            Text("페이지 내용은 선택한 Gemini 모델로 전송됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("API 키는 이 화면의 메모리에만 유지되며 앱 설정에 저장하지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var outputSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            Text("페이지 레이아웃 보존을 위해 번역 레이어를 추가하므로 원문 텍스트 데이터는 PDF 내부 검색에 남을 수 있습니다.")
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
            } else {
                Button {
                    startTranslation(bestEffort: false)
                } label: {
                    Label("PDF 번역 시작", systemImage: "character.book.closed")
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

                    Text("누락 가능한 이미지 글자와 보존 불가 영역을 건너뛴 PDF를 생성합니다. 암호·서명·손상 문서와 저장 오류는 우회하지 않습니다.")
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

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(viewModel.statusMessage)
                .lineLimit(1)
            Spacer()
            if viewModel.stage == .completed {
                Text("출력 PDF 구조 재검증 완료")
                    .foregroundStyle(AppTheme.success)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(AppTheme.elevatedBackground)
    }

    private var statusIcon: String {
        switch viewModel.stage {
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .cancelled:
            "xmark.circle"
        case .analyzing, .waitingForApple, .translating, .composing:
            "arrow.triangle.2.circlepath"
        case .idle, .ready:
            "circle.fill"
        }
    }

    private var statusColor: Color {
        switch viewModel.stage {
        case .completed:
            AppTheme.success
        case .failed:
            .orange
        default:
            .secondary
        }
    }

    private func startTranslation(bestEffort: Bool) {
        let explicitDestination: URL?
        if downloadLocation == FileTranslationOutputLocation.ask.rawValue {
            guard let sourceURL = viewModel.sourceURL,
                  let selectedURL = FileTranslationPanel.chooseDestination(
                    sourceURL: sourceURL,
                    targetLanguage: targetLanguage
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
                || allowsPotentiallyIncompleteOCR,
            compositionPolicy: bestEffort ? .bestEffort : .strict
        )

        if engine == .apple {
            viewModel.requestAppleTranslation(configuration: configuration)
        } else {
            viewModel.startTranslation(configuration: configuration)
        }
    }

    private func importPDF(_ url: URL) {
        previewSelection = .source
        viewModel.importPDF(from: url, sourceLanguage: sourceLanguage)
    }

    private func isPDF(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
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

private enum FilePreviewSelection: String, Hashable {
    case source
    case translated
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

private struct PDFDropZone: View {
    let isTargeted: Bool
    let isAnalyzing: Bool
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
                Text(isAnalyzing ? "PDF를 분석하는 중입니다" : "PDF를 여기에 놓으세요")
                    .font(.title2.bold())
                Text("페이지별 문맥과 원래 텍스트 위치를 보존해 번역합니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button("PDF 파일 선택", action: onChoose)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAnalyzing)

            Label("지원 형식: PDF", systemImage: "checkmark.seal")
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
        targetLanguage: LanguageOption
    ) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = (
            try? FileTranslationOutputURLResolver().suggestedFilename(
                for: sourceURL,
                targetLanguage: targetLanguage
            )
        ) ?? "translated.pdf"
        panel.message = "원본 PDF와 다른 이름으로 번역본을 저장합니다."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
