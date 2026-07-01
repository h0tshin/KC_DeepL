import AppKit
import SwiftUI
import KCDeepLCore

struct ContentView: View {
    @StateObject private var viewModel = TranslationViewModel()
    @SceneStorage("kc.main.showTools") private var showTools = false
    @State private var sourceLanguage = LanguageOption.english
    @State private var targetLanguage = LanguageOption.korean
    @State private var selectedMode: TranslationMode = .text

    @AppStorage(PreferenceKeys.provider) private var providerRaw = AppDefaults.defaultProvider.rawValue
    @AppStorage(PreferenceKeys.modelID) private var modelID = AppDefaults.defaultModelID
    @AppStorage(PreferenceKeys.geminiAPIKey) private var apiKey = AppDefaults.defaultGeminiAPIKey
    @AppStorage(PreferenceKeys.temperature) private var temperature = 0.2
    @AppStorage(PreferenceKeys.historyEnabled) private var historyEnabled = true
    @AppStorage(PreferenceKeys.autoTranslate) private var autoTranslate = true

    private var provider: LLMProvider {
        LLMProvider(rawValue: providerRaw) ?? .gemini
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
                    } else {
                        LanguageBar(
                            sourceLanguage: $sourceLanguage,
                            targetLanguage: $targetLanguage,
                            showTools: $showTools,
                            onPaste: pasteClipboardIntoSource,
                            onSwap: {
                                viewModel.swapLanguages(
                                    sourceLanguage: &sourceLanguage,
                                    targetLanguage: &targetLanguage
                                )
                            }
                        )

                        TranslationWorkspace(
                            sourceText: $viewModel.sourceText,
                            translatedText: viewModel.translatedText,
                            isTranslating: viewModel.isTranslating,
                            errorMessage: viewModel.errorMessage,
                            onCapture: viewModel.beginScreenCaptureMock
                        )

                        BottomStatusBar(statusMessage: viewModel.statusMessage)
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
            viewModel.runStartupChecks()
        }
        .onChange(of: viewModel.sourceText) { _, _ in
            scheduleAutoTranslation()
        }
        .onChange(of: sourceLanguage) { _, _ in
            scheduleAutoTranslation()
        }
        .onChange(of: targetLanguage) { _, _ in
            normalizeSourceLanguageForTarget()
            scheduleAutoTranslation()
        }
        .onChange(of: providerRaw) { _, _ in
            scheduleAutoTranslation()
        }
        .onChange(of: modelID) { _, _ in
            scheduleAutoTranslation()
        }
        .onChange(of: apiKey) { _, _ in
            viewModel.runStartupChecks()
            scheduleAutoTranslation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kcDeepLPerformAction)) { notification in
            if let payload = notification.object as? AppCommandPayload {
                handleCommandAction(
                    payload.action,
                    capturedText: payload.capturedText,
                    statusMessage: payload.statusMessage
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
        viewModel.scheduleAutoTranslation(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            provider: provider,
            modelID: modelID,
            apiKey: apiKey,
            temperature: temperature,
            historyEnabled: historyEnabled,
            autoTranslate: autoTranslate
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

    private func pasteClipboardIntoSource() {
        guard let clipboardText = NSPasteboard.general.string(forType: .string),
              !clipboardText.isEmpty
        else {
            return
        }

        viewModel.sourceText = viewModel.sourceText.isEmpty
            ? clipboardText
            : "\(viewModel.sourceText)\n\(clipboardText)"
    }

    private func handleCommandAction(
        _ action: AppCommandAction,
        capturedText: String? = nil,
        statusMessage: String? = nil
    ) {
        switch action {
        case .textTranslation:
            selectedMode = .text
            applyCapturedTextIfAvailable(capturedText)
        case .writing:
            selectedMode = .write
            applyCapturedTextIfAvailable(capturedText)
        case .fileTranslation:
            selectedMode = .files
        case .screenCapture:
            selectedMode = .text
            viewModel.beginScreenCaptureMock()
        }

        if let statusMessage {
            viewModel.statusMessage = statusMessage
        }
    }

    private func applyCapturedTextIfAvailable(_ text: String?) {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        viewModel.sourceText = text
    }
}

private enum TranslationMode: String, CaseIterable, Identifiable {
    case text = "텍스트 번역"
    case write = "글 작성"
    case files = "파일 번역"
    case history = "기록"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .text:
            "textformat"
        case .write:
            "pencil"
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
    let translatedText: String
    let isTranslating: Bool
    let errorMessage: String?
    let onCapture: () -> Void
    @State private var focusedPane: WorkspacePane?

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                SourceEditorPane(
                    text: $sourceText,
                    width: proxy.size.width / 2,
                    isFocused: focusedPane == .source,
                    onCapture: onCapture
                )
                .onHover { isHovering in
                    focusedPane = isHovering ? .source : nil
                }

                ResultPane(
                    translatedText: translatedText,
                    isTranslating: isTranslating,
                    errorMessage: errorMessage,
                    isFocused: focusedPane == .result
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

private struct SourceEditorPane: View {
    @Binding var text: String
    let width: CGFloat
    let isFocused: Bool
    let onCapture: () -> Void

    private var hasFormatting: Bool {
        MarkdownFormatting.containsFormatting(in: text)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PlainTextEditor(text: $text)
                .padding(20)

            if text.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    Text("번역하려는 텍스트를 입력하거나 붙여넣기 하세요")
                        .font(.system(size: 30, weight: .regular))
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.systemFont(ofSize: 26)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        MarkdownStyler.apply(to: textView)

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

        if textView.string != text {
            textView.string = text
        }

        textView.font = NSFont.systemFont(ofSize: 26)
        textView.textColor = .labelColor
        MarkdownStyler.apply(to: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            text = textView.string
            MarkdownStyler.apply(to: textView)
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

private enum MarkdownStyler {
    static func apply(to textView: NSTextView) {
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        guard fullRange.length > 0 else {
            return
        }

        let selectedRanges = textView.selectedRanges
        let storage = textView.textStorage
        storage?.beginEditing()
        storage?.setAttributes(
            [
                .font: NSFont.systemFont(ofSize: 26),
                .foregroundColor: NSColor.labelColor
            ],
            range: fullRange
        )

        apply(pattern: #"(?m)^#{1,3}\s+(.+)$"#, to: textView, font: .boldSystemFont(ofSize: 28))
        apply(pattern: #"\*\*(.*?)\*\*"#, to: textView, font: .boldSystemFont(ofSize: 26))
        apply(pattern: #"__(.*?)__"#, to: textView, font: .boldSystemFont(ofSize: 26))
        apply(pattern: #"`([^`]+)`"#, to: textView, font: .monospacedSystemFont(ofSize: 24, weight: .regular))
        storage?.endEditing()
        textView.selectedRanges = selectedRanges
    }

    private static func apply(pattern: String, to textView: NSTextView, font: NSFont) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return
        }

        let text = textView.string as NSString
        let range = NSRange(location: 0, length: text.length)
        let matches = expression.matches(in: textView.string, range: range)

        for match in matches {
            textView.textStorage?.addAttribute(.font, value: font, range: match.range)
        }
    }
}

private struct MarkdownText: View {
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
        (try? AttributedString(markdown: text))
            ?? AttributedString(text)
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
    let isTranslating: Bool
    let errorMessage: String?
    let isFocused: Bool

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
                        MarkdownText(text: translatedText, fontSize: 25)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(28)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: copyResultText) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            .disabled(translatedText.isEmpty)
            .padding(24)
            .help("번역 결과 복사")
        }
        .background(AppTheme.panelBackground)
        .overlay {
            Rectangle()
                .stroke(isFocused ? AppTheme.accent : AppTheme.panelBorder, lineWidth: isFocused ? 2 : 1)
                .padding(1)
        }
    }

    private func copyResultText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)
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
                Text(item.relativeTimestamp)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

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

            MarkdownText(text: text, fontSize: 14, weight: .semibold, lineLimit: 3)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                ToolPanelToggleButton(action: onClose)
                Spacer()
            }

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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.translatedText)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(2)
                        Text(item.modelID)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 7))
                }
            }

            Spacer()
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
