import AppKit
import SwiftUI
import KCDeepLCore

struct ContentView: View {
    @ObservedObject var viewModel: TranslationViewModel
    @ObservedObject var comparisonViewModel: TranslationComparisonViewModel
    @ObservedObject var liveTranslationViewModel: LiveTranslationViewModel
    @SceneStorage("kc.main.showTools") private var showTools = false
    @AppStorage(PreferenceKeys.mainSourceLanguage) private var sourceLanguageCode = LanguageOption.english.code
    @AppStorage(PreferenceKeys.mainTargetLanguage) private var targetLanguageCode = LanguageOption.korean.code
    @AppStorage(PreferenceKeys.readingFontSize)
    private var readingFontSizeRaw = ReadingFontSize.defaultValue.rawValue
    @State private var selectedMode: TranslationMode = .text
    @State private var pasteBackTarget: PasteBackTarget?

    @AppStorage(PreferenceKeys.translationBackend)
    private var translationBackendRaw = AppDefaults.defaultTranslationBackend.rawValue
    @AppStorage(PreferenceKeys.provider) private var providerRaw = AppDefaults.defaultProvider.rawValue
    @AppStorage(PreferenceKeys.modelID) private var modelID = AppDefaults.defaultModelID
    @AppStorage(PreferenceKeys.codexModelID)
    private var codexModelID = AppDefaults.defaultCodexModelID
    @AppStorage(PreferenceKeys.geminiAPIKey) private var apiKey = ""
    @AppStorage(PreferenceKeys.temperature) private var temperature = 0.2
    @AppStorage(PreferenceKeys.historyEnabled) private var historyEnabled = true
    @AppStorage(PreferenceKeys.autoTranslate) private var autoTranslate = true

    private var provider: LLMProvider {
        LLMProvider(rawValue: providerRaw) ?? .gemini
    }

    private var translationBackend: TranslationBackend {
        TranslationBackend(rawValue: translationBackendRaw)
            ?? AppDefaults.defaultTranslationBackend
    }

    private var activeModelID: String {
        translationBackend == .codexAppServer ? codexModelID : modelID
    }

    private var readingFontSize: CGFloat {
        CGFloat(ReadingFontSize.resolved(readingFontSizeRaw).points)
    }

    private var sourceLanguage: LanguageOption {
        get {
            LanguageOption.sourceLanguages.first { $0.code == sourceLanguageCode } ?? .english
        }
        nonmutating set {
            sourceLanguageCode = newValue.code
        }
    }

    private var targetLanguage: LanguageOption {
        get {
            LanguageOption.targetLanguages.first { $0.code == targetLanguageCode } ?? .korean
        }
        nonmutating set {
            targetLanguageCode = newValue.code
        }
    }

    private var sourceLanguageBinding: Binding<LanguageOption> {
        Binding(get: { sourceLanguage }, set: { sourceLanguage = $0 })
    }

    private var targetLanguageBinding: Binding<LanguageOption> {
        Binding(get: { targetLanguage }, set: { targetLanguage = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if selectedMode == .history {
                        HistoryWorkspace(
                            history: viewModel.history,
                            onDelete: viewModel.deleteHistoryItem,
                            onDeleteAll: viewModel.clearHistory
                        )
                    } else if selectedMode == .write {
                        LiveTranslationWorkspace(
                            showTools: $showTools,
                            viewModel: liveTranslationViewModel
                        )
                    } else {
                        LanguageBar(
                            sourceLanguage: sourceLanguageBinding,
                            targetLanguage: targetLanguageBinding,
                            showTools: $showTools,
                            readingFontSizeRaw: $readingFontSizeRaw,
                            onPaste: pasteClipboardIntoSource,
                            onSwap: {
                                if selectedMode == .comparison {
                                    swapComparisonLanguages()
                                    return
                                }
                                var sourceLanguage = sourceLanguage
                                var targetLanguage = targetLanguage
                                viewModel.swapLanguages(
                                    sourceLanguage: &sourceLanguage,
                                    targetLanguage: &targetLanguage
                                )
                                self.sourceLanguage = sourceLanguage
                                self.targetLanguage = targetLanguage
                            }
                        )

                        if selectedMode == .comparison {
                            TranslationComparisonView(
                                viewModel: comparisonViewModel,
                                sourceText: Binding(
                                    get: { viewModel.sourceText },
                                    set: { viewModel.setSourceText($0) }
                                ),
                                sourceAttributedText: Binding(
                                    get: { viewModel.sourceAttributedText },
                                    set: { viewModel.setSourceAttributedText($0) }
                                ),
                                fontSize: readingFontSize,
                                onCapture: viewModel.beginScreenCaptureMock,
                                onCompare: startTranslationComparison,
                                onCancel: comparisonViewModel.cancelComparison
                            )
                        } else {
                            TranslationWorkspace(
                                sourceText: Binding(
                                    get: { viewModel.sourceText },
                                    set: { viewModel.setSourceText($0) }
                                ),
                                sourceAttributedText: Binding(
                                    get: { viewModel.sourceAttributedText },
                                    set: { viewModel.setSourceAttributedText($0) }
                                ),
                                translatedText: viewModel.translatedText,
                                fontSize: readingFontSize,
                                isTranslating: viewModel.isTranslating,
                                errorMessage: viewModel.errorMessage,
                                pasteBackTarget: pasteBackTarget,
                                onCapture: viewModel.beginScreenCaptureMock,
                                onPasteBack: pasteTranslationBackToSourceApp
                            )

                            BottomStatusBar(statusMessage: viewModel.statusMessage)
                        }
                    }
                }

                if showTools {
                    ToolsPanel(
                        history: viewModel.history,
                        onClose: {
                            withAnimation(.easeOut(duration: 0.16)) {
                                showTools = false
                            }
                        }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(AppTheme.panelBackground)
        .background(TitlebarMenuAccessory().frame(width: 0, height: 0))
        .foregroundStyle(.primary)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                TitlebarModeControls(selectedMode: $selectedMode)
            }
        }
        .toolbarBackground(AppTheme.titlebarBackground, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .onAppear {
            viewModel.setHistoryEnabled(historyEnabled)
            runStartupChecks()
        }
        .onOpenURL(perform: PopClipIntegration.handle)
        .onChange(of: viewModel.sourceText) { _, _ in
            if viewModel.sourceText.isEmpty {
                pasteBackTarget = nil
            }
            comparisonViewModel.resetForInputChange()
            if selectedMode != .comparison {
                scheduleAutoTranslation()
            }
        }
        .onChange(of: sourceLanguage) { _, _ in
            comparisonViewModel.resetForInputChange()
            if selectedMode != .comparison {
                scheduleAutoTranslation()
            }
        }
        .onChange(of: targetLanguage) { _, _ in
            normalizeSourceLanguageForTarget()
            comparisonViewModel.resetForInputChange()
            if selectedMode != .comparison {
                scheduleAutoTranslation()
            }
        }
        .onChange(of: providerRaw) { _, _ in
            if translationBackend == .llmAPI {
                scheduleAutoTranslation()
            }
        }
        .onChange(of: translationBackendRaw) { _, _ in
            runStartupChecks()
            scheduleAutoTranslation()
        }
        .onChange(of: modelID) { _, _ in
            if translationBackend == .llmAPI {
                scheduleAutoTranslation()
            }
        }
        .onChange(of: codexModelID) { _, _ in
            if translationBackend == .codexAppServer {
                runStartupChecks()
                scheduleAutoTranslation()
            }
        }
        .onChange(of: temperature) { _, _ in
            if translationBackend == .llmAPI {
                scheduleAutoTranslation()
            }
        }
        .onChange(of: autoTranslate) { _, _ in
            scheduleAutoTranslation()
        }
        .onChange(of: historyEnabled) { _, enabled in
            viewModel.setHistoryEnabled(enabled)
        }
        .onChange(of: apiKey) { _, _ in
            if translationBackend == .llmAPI {
                runStartupChecks()
                scheduleAutoTranslation()
            }
        }
        .onChange(of: selectedMode) { previousMode, newMode in
            if previousMode == .comparison, newMode != .comparison {
                comparisonViewModel.cancelComparison()
            }
            if newMode == .comparison {
                viewModel.cancelPendingTranslation()
            } else if newMode == .text {
                runStartupChecks()
                scheduleAutoTranslation()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kcDeepLPerformAction)) { notification in
            if let payload = notification.object as? AppCommandPayload {
                handleCommandAction(
                    payload.action,
                    capturedText: payload.capturedText,
                    capturedAttributedText: payload.capturedAttributedText,
                    statusMessage: payload.statusMessage,
                    pasteBackTarget: payload.pasteBackTarget
                )
            } else if let action = notification.object as? AppCommandAction {
                handleCommandAction(action)
            }
        }
        .sheet(item: $viewModel.captureState) { state in
            CaptureMockSheet(state: state) {
                viewModel.completeScreenCaptureMock()
            }
        }
    }

    private func scheduleAutoTranslation() {
        guard selectedMode == .text else {
            return
        }
        viewModel.scheduleAutoTranslation(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            provider: provider,
            modelID: activeModelID,
            apiKey: apiKey,
            temperature: temperature,
            historyEnabled: historyEnabled,
            autoTranslate: autoTranslate,
            backend: translationBackend
        )
    }

    private func runStartupChecks() {
        viewModel.runStartupChecks(
            backend: translationBackend,
            modelID: activeModelID,
            apiKey: apiKey
        )
    }

    private func normalizeSourceLanguageForTarget() {
        guard targetLanguage == .english,
              sourceLanguage != .korean
        else {
            return
        }

        sourceLanguage = .korean
    }

    private func swapComparisonLanguages() {
        var source = sourceLanguage
        var target = targetLanguage
        if source == .autoDetect {
            source = target
            target = target == .korean ? .english : .korean
        } else {
            swap(&source, &target)
        }
        sourceLanguage = source
        targetLanguage = target
        comparisonViewModel.resetForInputChange()
    }

    private func startTranslationComparison() {
        let source = RichTextFormatting.markdown(
            from: viewModel.sourceAttributedText,
            fallback: viewModel.sourceText
        )
        comparisonViewModel.startComparison(
            sourceText: source,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        ) { record in
            viewModel.recordComparisonTranslation(record)
        }
    }

    private func pasteClipboardIntoSource() {
        guard let clipboardText = RichTextFormatting.attributedString(from: NSPasteboard.general),
              !clipboardText.string.isEmpty
        else {
            return
        }

        pasteBackTarget = nil
        viewModel.appendSourceAttributedText(clipboardText)
    }

    private func handleCommandAction(
        _ action: AppCommandAction,
        capturedText: String? = nil,
        capturedAttributedText: NSAttributedString? = nil,
        statusMessage: String? = nil,
        pasteBackTarget: PasteBackTarget? = nil
    ) {
        switch action {
        case .textTranslation:
            selectedMode = .text
            applyCapturedTextIfAvailable(capturedText, attributedText: capturedAttributedText)
            self.pasteBackTarget = pasteBackTarget
        case .writing:
            selectedMode = .write
            self.pasteBackTarget = nil
        case .fileTranslation:
            selectedMode = .files
            self.pasteBackTarget = nil
        case .screenCapture:
            selectedMode = .text
            self.pasteBackTarget = nil
            viewModel.beginScreenCaptureMock()
        }

        if let statusMessage {
            viewModel.statusMessage = statusMessage
        }
    }

    private func applyCapturedTextIfAvailable(_ text: String?, attributedText: NSAttributedString?) {
        if let attributedText,
           !attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.setSourceAttributedText(attributedText)
            return
        }

        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        viewModel.setSourceText(text)
    }

    private func pasteTranslationBackToSourceApp() {
        guard let pasteBackTarget else {
            viewModel.statusMessage = "연결된 입력 위치가 없습니다."
            return
        }

        let translatedText = viewModel.translatedText
        Task { @MainActor in
            viewModel.statusMessage = await pasteBackTarget.paste(translatedText)
        }
    }
}

private enum TranslationMode: String, CaseIterable, Identifiable {
    case text = "텍스트 번역"
    case comparison = "번역비교"
    case write = "Live 번역"
    case files = "파일 번역"
    case history = "기록"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .text:
            "textformat"
        case .comparison:
            "rectangle.3.group"
        case .write:
            "speaker.wave.2"
        case .files:
            "doc.text"
        case .history:
            "clock.arrow.circlepath"
        }
    }
}

private struct TitlebarModeControls: View {
    @Binding var selectedMode: TranslationMode

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TranslationMode.allCases) { mode in
                Button {
                    selectedMode = mode
                } label: {
                    Label(mode.rawValue, systemImage: mode.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8)
                        .frame(height: 27)
                        .foregroundStyle(selectedMode == mode ? AppTheme.selectedTitlebarForeground : Color.primary)
                        .background(selectedMode == mode ? AppTheme.selectedTitlebarBackground : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mode.rawValue)
            }
        }
    }
}

private struct MainMenuButton: View {
    var body: some View {
        Menu {
            SettingsLink {
                Label("설정", systemImage: "gearshape")
            }

            Divider()

            Button("번역 기록 열기") {}
            Button("도움말") {}
            Button("피드백 보내기") {}
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 20, weight: .semibold))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .frame(width: 30, height: 30)
        .help("메뉴")
    }
}

private struct TitlebarMenuAccessory: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else {
                return
            }

            context.coordinator.installIfNeeded(on: window)
        }
    }

    @MainActor
    final class Coordinator {
        private let identifier = NSUserInterfaceItemIdentifier("KCDeepLTitlebarMainMenuAccessory")

        func installIfNeeded(on window: NSWindow) {
            configure(window)

            let alreadyInstalled = window.titlebarAccessoryViewControllers.contains {
                $0.view.identifier == identifier
            }

            guard !alreadyInstalled else {
                return
            }

            let hostingView = NSHostingView(
                rootView: HStack(spacing: 0) {
                    MainMenuButton()
                    Spacer(minLength: 0)
                }
                .frame(width: 58, height: 30)
            )
            hostingView.translatesAutoresizingMaskIntoConstraints = false

            let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 58, height: 30))
            containerView.identifier = identifier
            containerView.addSubview(hostingView)

            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])

            let controller = NSTitlebarAccessoryViewController()
            controller.view = containerView
            controller.layoutAttribute = .right
            window.addTitlebarAccessoryViewController(controller)
        }

        private func configure(_ window: NSWindow) {
            window.titlebarAppearsTransparent = true
            window.backgroundColor = AppTheme.titlebarNSColor
            window.toolbar?.showsBaselineSeparator = false
        }
    }
}

private struct LanguageBar: View {
    @Binding var sourceLanguage: LanguageOption
    @Binding var targetLanguage: LanguageOption
    @Binding var showTools: Bool
    @Binding var readingFontSizeRaw: String
    let onPaste: () -> Void
    let onSwap: () -> Void

    var body: some View {
        ZStack {
            HStack {
                Button(action: onPaste) {
                    Label("붙여넣기", systemImage: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .contentShape(Rectangle())
                .help("클립보드 내용을 원문에 붙여넣기")

                Spacer()
            }

            HStack(spacing: 16) {
                LanguageMenu(
                    selection: $sourceLanguage,
                    languages: LanguageOption.sourceLanguages,
                    help: "출발 언어 선택"
                )

                Button(action: onSwap) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("언어 전환")

                LanguageMenu(
                    selection: $targetLanguage,
                    languages: LanguageOption.targetLanguages,
                    help: "도착 언어 선택"
                )
            }

            HStack {
                Spacer()

                FontSizeControl(readingFontSizeRaw: $readingFontSizeRaw)

                if !showTools {
                    ToolPanelToggleButton {
                        withAnimation(.easeOut(duration: 0.16)) {
                            showTools = true
                        }
                    }
                }
            }
            .padding(.trailing, 10)
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(AppTheme.toolbarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.panelBorder)
                .frame(height: 1)
        }
    }
}

private struct LanguageMenu: View {
    @Binding var selection: LanguageOption
    let languages: [LanguageOption]
    let help: String

    var body: some View {
        Menu {
            ForEach(languages) { language in
                Button {
                    selection = language
                } label: {
                    if selection == language {
                        Label(language.displayName, systemImage: "checkmark")
                    } else {
                        Text(language.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection.displayName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 180, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ToolPanelToggleButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.right")
                .resizable()
                .scaledToFit()
                .padding(1)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("툴바")
    }
}

private struct TranslationWorkspace: View {
    @Binding var sourceText: String
    @Binding var sourceAttributedText: NSAttributedString
    let translatedText: String
    let fontSize: CGFloat
    let isTranslating: Bool
    let errorMessage: String?
    let pasteBackTarget: PasteBackTarget?
    let onCapture: () -> Void
    let onPasteBack: () -> Void
    @State private var focusedPane: WorkspacePane?

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                SourceEditorPane(
                    text: $sourceText,
                    attributedText: $sourceAttributedText,
                    width: proxy.size.width / 2,
                    fontSize: fontSize,
                    isFocused: focusedPane == .source,
                    onCapture: onCapture
                )
                .onHover { isHovering in
                    focusedPane = isHovering ? .source : nil
                }

                ResultPane(
                    translatedText: translatedText,
                    fontSize: fontSize,
                    isTranslating: isTranslating,
                    errorMessage: errorMessage,
                    isFocused: focusedPane == .result,
                    showsPasteBackButton: pasteBackTarget != nil,
                    onPasteBack: onPasteBack
                )
                .onHover { isHovering in
                    focusedPane = isHovering ? .result : nil
                }
            }
        }
    }
}

private enum WorkspacePane {
    case source
    case result
}

struct SourceEditorPane: View {
    @Binding var text: String
    @Binding var attributedText: NSAttributedString
    let width: CGFloat
    let fontSize: CGFloat
    let isFocused: Bool
    let onCapture: () -> Void

    private var hasFormatting: Bool {
        RichTextFormatting.hasFormatting(attributedText) || MarkdownFormatting.containsFormatting(in: text)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RichTextEditor(
                text: $text,
                attributedText: $attributedText,
                fontSize: fontSize
            )
                .padding(20)

            if text.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    Text("번역하려는 텍스트를 입력하거나 붙여넣기 하세요")
                        .font(.system(size: fontSize + 4, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: min(width - 64, 520), alignment: .leading)

                    Text("또는 텍스트를 선택하고 ⌃⇧1를 눌러 빠르게 번역할 수 있습니다")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 28)
                .padding(.leading, 28)
                .allowsHitTesting(false)
            }

            if !text.isEmpty {
                HStack {
                    Spacer()

                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("전체 삭제")
                }
                .padding(.top, 12)
                .padding(.trailing, 16)
            }

            VStack {
                Spacer()

                if text.isEmpty {
                    FileDropMock()
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 54)
                }

                HStack(spacing: 8) {
                    if hasFormatting {
                        Button {
                            text = MarkdownFormatting.stripFormatting(from: text)
                        } label: {
                            Image(systemName: "textformat")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                        .help("서식 지우기")
                    }

                    Spacer()

                    if !text.isEmpty {
                        Text("\(text.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 42, alignment: .trailing)
                    }

                    Button(action: copySourceText) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 34, height: 34)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(text.isEmpty)
                    .help("원문 복사")

                    Button(action: onCapture) {
                        Image(systemName: "selection.pin.in.out")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 34, height: 34)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                            .foregroundStyle(Color.gray.opacity(0.82))
                    )
                    .help("텍스트 화면 캡처")
                }
                .padding(24)
            }
        }
        .background(AppTheme.panelBackground)
        .overlay {
            Rectangle()
                .stroke(isFocused ? AppTheme.accent : AppTheme.panelBorder, lineWidth: isFocused ? 2 : 1)
                .padding(1)
        }
    }

    private func copySourceText() {
        RichTextFormatting.write(attributedText, to: NSPasteboard.general)
    }
}

private struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var attributedText: NSAttributedString
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            attributedText: $attributedText,
            fontSize: fontSize
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor
        ]
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        context.coordinator.apply(
            attributedText,
            fontSize: fontSize,
            to: textView
        )

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        context.coordinator.apply(
            attributedText,
            fontSize: fontSize,
            to: textView
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        @Binding private var attributedText: NSAttributedString
        private var isApplyingProgrammaticUpdate = false
        private var displayScale: CGFloat

        init(
            text: Binding<String>,
            attributedText: Binding<NSAttributedString>,
            fontSize: CGFloat
        ) {
            _text = text
            _attributedText = attributedText
            displayScale = Self.displayScale(for: fontSize)
        }

        func apply(
            _ attributed: NSAttributedString,
            fontSize: CGFloat,
            to textView: NSTextView
        ) {
            guard !isApplyingProgrammaticUpdate else {
                return
            }

            displayScale = Self.displayScale(for: fontSize)
            let normalized = RichTextFormatting.normalize(attributed)
            let displayed = RichTextFormatting.scaledFontSizes(
                in: normalized,
                by: displayScale
            )

            isApplyingProgrammaticUpdate = true
            if !textView.attributedString().isEqual(to: displayed) {
                let selectedRanges = clampedSelectionRanges(
                    textView.selectedRanges,
                    textLength: displayed.length
                )
                textView.textStorage?.setAttributedString(displayed)
                textView.selectedRanges = selectedRanges
            }
            textView.font = NSFont.systemFont(ofSize: fontSize)
            textView.textColor = .labelColor
            textView.typingAttributes = [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.labelColor
            ]
            isApplyingProgrammaticUpdate = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticUpdate else {
                return
            }

            guard let textView = notification.object as? NSTextView else {
                return
            }

            let stored = RichTextFormatting.scaledFontSizes(
                in: textView.attributedString(),
                by: 1 / displayScale,
                fallbackFontSize: fontSizeForDisplayScale
            )
            let normalized = RichTextFormatting.normalize(stored)
            text = normalized.string
            attributedText = normalized
        }

        private var fontSizeForDisplayScale: CGFloat {
            RichTextFormatting.defaultFontSize * displayScale
        }

        private static func displayScale(for fontSize: CGFloat) -> CGFloat {
            max(0.1, fontSize / RichTextFormatting.defaultFontSize)
        }

        private func clampedSelectionRanges(_ ranges: [NSValue], textLength: Int) -> [NSValue] {
            ranges.map { value in
                let range = value.rangeValue
                let location = min(range.location, textLength)
                let length = min(range.length, max(0, textLength - location))
                return NSValue(range: NSRange(location: location, length: length))
            }
        }
    }
}

private enum MarkdownFormatting {
    static func containsFormatting(in text: String) -> Bool {
        text.range(of: #"(^|\s)(#{1,6}\s|[-*]\s|\d+\.\s|>\s)|(\*\*|__|`|\[.+\]\(.+\))"#, options: .regularExpression) != nil
    }

    static func stripFormatting(from text: String) -> String {
        var stripped = text
        let replacements: [(String, String)] = [
            (#"(?m)^#{1,6}\s*"#, ""),
            (#"\*\*(.*?)\*\*"#, "$1"),
            (#"__(.*?)__"#, "$1"),
            (#"\*(.*?)\*"#, "$1"),
            (#"`([^`]+)`"#, "$1"),
            (#"\[(.*?)\]\((.*?)\)"#, "$1"),
            (#"(?m)^>\s*"#, ""),
            (#"(?m)^\s*[-*]\s+"#, ""),
            (#"(?m)^\s*\d+\.\s+"#, "")
        ]

        for (pattern, template) in replacements {
            stripped = stripped.replacingOccurrences(
                of: pattern,
                with: template,
                options: .regularExpression
            )
        }

        return stripped
    }
}

struct MarkdownText: View {
    let text: String
    var fontSize: CGFloat
    var weight: Font.Weight = .regular
    var lineLimit: Int?

    var body: some View {
        Text(attributedText)
            .font(.system(size: fontSize, weight: weight))
            .lineSpacing(6)
            .lineLimit(lineLimit)
    }

    private var attributedText: AttributedString {
        RichTextFormatting.displayAttributedString(markdown: text)
    }
}

private struct FileDropMock: View {
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: -2) {
                ForEach(["docx", "pptx", "pdf", "txt", "html"], id: \.self) { ext in
                    VStack(spacing: 0) {
                        Image(systemName: "doc")
                            .font(.system(size: 18))
                        Text(ext)
                            .font(.system(size: 8, weight: .bold))
                    }
                    .frame(width: 28, height: 32)
                }
            }

            Text("전체 파일을 번역하려면, 여기에 파일을 드래그하여 놓으세요")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ResultPane: View {
    let translatedText: String
    let fontSize: CGFloat
    let isTranslating: Bool
    let errorMessage: String?
    let isFocused: Bool
    let showsPasteBackButton: Bool
    let onPasteBack: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isTranslating {
                        ProgressView("번역 중")
                            .controlSize(.small)
                            .padding()
                    } else if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .padding()
                    } else if translatedText.isEmpty {
                        Text("번역 결과가 이곳에 표시됩니다")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 220)
                    } else {
                        MarkdownText(text: translatedText, fontSize: fontSize)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(28)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                if showsPasteBackButton && !translatedText.isEmpty {
                    Button(action: onPasteBack) {
                        Label("연결하여 붙여넣기", systemImage: "arrow.turn.down.left")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                    }
                    .buttonStyle(.plain)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                    .help("번역 결과를 원래 입력 위치에 붙여넣기")
                }

                Button(action: copyResultText) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                .disabled(translatedText.isEmpty)
                .help("번역 결과 복사")
            }
            .padding(24)
        }
        .background(AppTheme.panelBackground)
        .overlay {
            Rectangle()
                .stroke(isFocused ? AppTheme.accent : AppTheme.panelBorder, lineWidth: isFocused ? 2 : 1)
                .padding(1)
        }
    }

    private func copyResultText() {
        RichTextFormatting.writeMarkdown(translatedText, to: NSPasteboard.general)
    }
}

private struct HistoryWorkspace: View {
    let history: [TranslationHistoryItem]
    let onDelete: (TranslationHistoryItem.ID) -> Void
    let onDeleteAll: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()

                Button(action: onDeleteAll) {
                    Label("기록 삭제", systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(nsColor: NSColor.systemCyan))
                .disabled(history.isEmpty)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            if history.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)

                    Text("아직 저장된 번역 기록이 없습니다")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(history) { item in
                            HistoryCard(item: item) {
                                onDelete(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.panelBackground)
    }
}

private struct HistoryCard: View {
    let item: TranslationHistoryItem
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.relativeTimestamp)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Label(item.engineSummary, systemImage: "cpu")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(nsColor: NSColor.systemCyan))
                .help("기록 삭제")
            }

            HistoryTextBlock(
                label: "출발 언어",
                language: item.sourceLanguage.displayName,
                text: item.sourceText
            )

            Divider().opacity(0.22)

            HistoryTextBlock(
                label: "도착 언어",
                language: item.targetLanguage.displayName,
                text: item.translatedText
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.controlBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(AppTheme.separator)
        }
    }
}

private struct HistoryTextBlock: View {
    let label: String
    let language: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("\(label):")
                    .font(.system(size: 13, weight: .bold))
                Text(language)
                    .font(.system(size: 13, weight: .bold))
                Text("\(text.count)자")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            MarkdownText(text: text, fontSize: 14, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension TranslationHistoryItem {
    var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }
}

private struct BottomStatusBar: View {
    let statusMessage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)

            Text(statusMessage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(AppTheme.elevatedBackground)
        .overlay(alignment: .top) {
            Divider().opacity(0.35)
        }
    }

    private var statusIcon: String {
        statusMessage.contains("실패") || statusMessage.contains("키를 설정") || statusMessage.contains("모델을 선택")
            ? "exclamationmark.triangle.fill"
            : "checkmark.circle.fill"
    }

    private var statusColor: Color {
        statusIcon == "exclamationmark.triangle.fill" ? .orange : AppTheme.success
    }
}

private struct ToolsPanel: View {
    let history: [TranslationHistoryItem]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ToolPanelToggleButton(action: onClose)
                Spacer()
            }
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("편집 도구")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ToolRow(title: "격식/비격식", icon: "text.badge.checkmark", isDisabled: true)

                    Text("사용자 지정")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ToolRow(title: "스타일 프로필 0/1", icon: "square.grid.2x2", hasToggle: true)
                    ToolRow(title: "용어집 0/1", icon: "book", hasToggle: true)
                    ToolRow(title: "스타일 규칙", icon: "quote.opening", hasToggle: true)

                    Divider().opacity(0.25)

                    Text("최근 기록")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if history.isEmpty {
                        Text("아직 저장된 번역이 없습니다.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(history.prefix(3)) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.translatedText)
                                    .font(.system(size: 12, weight: .semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(item.engineSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
        .padding(20)
        .frame(width: 280)
        .background(AppTheme.panelBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AppTheme.panelBorder)
                .frame(width: 1)
        }
    }
}

private struct ToolRow: View {
    let title: String
    let icon: String
    var hasToggle = false
    var isDisabled = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if hasToggle {
                Toggle("", isOn: .constant(false))
                    .labelsHidden()
                    .controlSize(.mini)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(AppTheme.controlBackground.opacity(isDisabled ? 0.25 : 1), in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(isDisabled ? .tertiary : .primary)
    }
}

private struct CaptureMockSheet: View {
    let state: CaptureState
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(state.title, systemImage: "selection.pin.in.out")
                    .font(.title3.bold())
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .compactIconButton()
            }

            Text(state.message)
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.18))

                RoundedRectangle(cornerRadius: 7)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(28)

                Text("선택 영역 미리보기")
                    .foregroundStyle(.secondary)
            }
            .frame(height: 220)

            HStack {
                Spacer()

                Button("취소") {
                    dismiss()
                }

                Button("캡처 완료") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
