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

    private var provider: LLMProvider {
        LLMProvider(rawValue: providerRaw) ?? .gemini
    }

    var body: some View {
        VStack(spacing: 0) {
            TopModeBar(selectedMode: $selectedMode, showTools: $showTools)

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    LanguageBar(
                        sourceLanguage: $sourceLanguage,
                        targetLanguage: $targetLanguage,
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
                        onTranslate: runTranslation,
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
        .sheet(item: $viewModel.captureState) { state in
            CaptureMockSheet(state: state) {
                viewModel.completeScreenCaptureMock()
            }
        }
    }

    private func runTranslation() {
        Task {
            await viewModel.translate(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                provider: provider,
                modelID: modelID,
                apiKey: apiKey,
                temperature: temperature,
                historyEnabled: historyEnabled
            )
        }
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

private struct TopModeBar: View {
    @Binding var selectedMode: TranslationMode
    @Binding var showTools: Bool

    var body: some View {
        HStack(spacing: 10) {
            ForEach(TranslationMode.allCases) { mode in
                Button {
                    selectedMode = mode
                } label: {
                    Label(mode.rawValue, systemImage: mode.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(
                            selectedMode == mode
                                ? Color(nsColor: NSColor.controlAccentColor).opacity(0.25)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .help(mode.rawValue)
            }

            Spacer()

            Button {
                showTools.toggle()
            } label: {
                Label("툴바", systemImage: "sidebar.right")
                    .labelStyle(.iconOnly)
            }
            .compactIconButton()
            .help("오른쪽 도구 패널")

            Circle()
                .fill(Color(nsColor: NSColor.systemBlue))
                .frame(width: 30, height: 30)
                .overlay(Text("H").font(.system(size: 15, weight: .bold)))

            MainMenuButton()
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Color.black.opacity(0.68))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.25)
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
    let onSwap: () -> Void

    var body: some View {
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

            Spacer()
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
    let onTranslate: () -> Void
    let onCapture: () -> Void

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                SourceEditorPane(
                    text: $sourceText,
                    width: proxy.size.width / 2,
                    onTranslate: onTranslate,
                    onCapture: onCapture
                )

                Rectangle()
                    .fill(AppTheme.separator)
                    .frame(width: 1)

                ResultPane(
                    translatedText: translatedText,
                    isTranslating: isTranslating,
                    errorMessage: errorMessage
                )
            }
        }
    }
}

private struct SourceEditorPane: View {
    @Binding var text: String
    let width: CGFloat
    let onTranslate: () -> Void
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

                HStack {
                    FileDropMock()
                    Spacer()

                    Button(action: onCapture) {
                        Image(systemName: "selection.pin.in.out")
                            .font(.system(size: 20, weight: .medium))
                            .padding(9)
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

                HStack {
                    Button(action: onTranslate) {
                        Label("번역", systemImage: "arrow.right.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])

                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
        }
        .background(AppTheme.panelBackground)
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
                        VStack(spacing: 6) {
                            Text("DeepL로 더 빠르게 번역해 보세요.")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)

                            Text("작동 방식 자세히 보기")
                                .font(.system(size: 13))
                                .underline()
                                .foregroundStyle(.primary)
                        }
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
    }
}

private struct BottomStatusBar: View {
    let statusMessage: String

    var body: some View {
        HStack(spacing: 10) {
            Button {} label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .compactIconButton()
            .disabled(true)

            Button {} label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .compactIconButton()
            .disabled(true)

            Spacer()

            Image(systemName: "shield.checkered")
                .foregroundStyle(AppTheme.success)

            Text(statusMessage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Image(systemName: "textformat.size")
            Image(systemName: "waveform")
            Image(systemName: "keyboard")
            Image(systemName: "questionmark.circle")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(AppTheme.elevatedBackground)
        .overlay(alignment: .top) {
            Divider().opacity(0.35)
        }
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
