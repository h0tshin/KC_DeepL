import AppKit
import SwiftUI
import KCDeepLCore

struct ContentView: View {
    @StateObject private var viewModel = TranslationViewModel()
    @SceneStorage("kc.main.showTools") private var showTools = false
    @State private var sourceLanguage = LanguageOption.autoDetect
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
                    LanguageBar(
                        sourceLanguage: $sourceLanguage,
                        targetLanguage: $targetLanguage,
                        showTools: $showTools,
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

                if showTools {
                    ToolsPanel(history: viewModel.history)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(AppTheme.panelBackground)
        .foregroundStyle(.primary)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                TitlebarModeControls(selectedMode: $selectedMode)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Circle()
                    .fill(Color(nsColor: NSColor.systemBlue))
                    .frame(width: 26, height: 26)
                    .overlay(Text("H").font(.system(size: 13, weight: .bold)))
                    .help("계정")

                MainMenuButton()
            }
        }
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
}

private enum TranslationMode: String, CaseIterable, Identifiable {
    case text = "텍스트 번역"
    case write = "DeepL Write"
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
                        .background(
                            selectedMode == mode
                                ? Color(nsColor: NSColor.controlAccentColor).opacity(0.24)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
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

private struct LanguageBar: View {
    @Binding var sourceLanguage: LanguageOption
    @Binding var targetLanguage: LanguageOption
    @Binding var showTools: Bool
    let onSwap: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 16) {
                Picker("", selection: $sourceLanguage) {
                    ForEach(LanguageOption.sourceLanguages) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)

                Button(action: onSwap) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .compactIconButton()
                .help("언어 전환")

                Picker("", selection: $targetLanguage) {
                    ForEach(LanguageOption.targetLanguages) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
            }

            HStack {
                Spacer()

                Button {
                    showTools.toggle()
                } label: {
                    Label("툴바", systemImage: "sidebar.right")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("오른쪽 도구 패널")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(AppTheme.elevatedBackground)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.35)
        }
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

                Rectangle()
                    .fill(AppTheme.separator)
                    .frame(width: 1)

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

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 26, weight: .regular))
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(20)

            if text.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    Text("번역하려는 텍스트를 입력하거나 붙여넣기 하세요")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: min(width - 64, 520), alignment: .leading)

                    Text("또는 텍스트를 선택하고 ⇧⌘1를 눌러 빠르게 번역할 수 있습니다")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 28)
                .padding(.leading, 28)
                .allowsHitTesting(false)
            }

            VStack {
                Spacer()

                if text.isEmpty {
                    FileDropMock()
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 54)
                }

                HStack(spacing: 8) {
                    Spacer()

                    Button(action: copySourceText) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(text.isEmpty)
                    .help("원문 복사")

                    Button(action: onCapture) {
                        Image(systemName: "selection.pin.in.out")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                            .foregroundStyle(.white.opacity(0.8))
                    )
                    .help("텍스트 화면 캡처")
                }
                .padding(24)
            }
        }
        .background(AppTheme.panelBackground)
        .overlay {
            Rectangle()
                .stroke(isFocused ? AppTheme.accent : Color.clear, lineWidth: 2)
                .padding(1)
        }
    }

    private func copySourceText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        ZStack {
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
                        Text(translatedText)
                            .font(.system(size: 25))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(28)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(AppTheme.panelBackground.opacity(0.94))
        .overlay {
            Rectangle()
                .stroke(isFocused ? AppTheme.accent : Color.clear, lineWidth: 2)
                .padding(1)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "sidebar.right")
                Spacer()
            }
            .font(.title3)

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
                .fill(AppTheme.separator)
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
