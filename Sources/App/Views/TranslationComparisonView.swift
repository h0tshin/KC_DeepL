import AppKit
import SwiftUI

struct TranslationComparisonView: View {
    @ObservedObject var viewModel: TranslationComparisonViewModel
    @Binding var sourceText: String
    @Binding var sourceAttributedText: NSAttributedString
    let fontSize: CGFloat
    let onCompare: () -> Void
    let onCancel: () -> Void

    @State private var sourceIsFocused = false

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                SourceEditorPane(
                    text: $sourceText,
                    attributedText: $sourceAttributedText,
                    width: proxy.size.width / 2,
                    fontSize: fontSize,
                    isFocused: sourceIsFocused
                )
                .onHover { sourceIsFocused = $0 }

                VStack(spacing: 0) {
                    selectedResult

                    Divider().opacity(0.35)

                    comparisonControls
                }
                .frame(width: proxy.size.width / 2)
                .background(AppTheme.panelBackground)
                .overlay {
                    Rectangle()
                        .stroke(AppTheme.panelBorder, lineWidth: 1)
                        .padding(1)
                }
            }
        }
    }

    private var selectedResult: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(viewModel.selectedModel.displayName)
                            .font(.system(size: 15, weight: .bold))
                            .lineLimit(1)

                        Spacer(minLength: 12)

                        Text("Codex App Server · \(viewModel.selectedModel.modelID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)

                    resultContent
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let translatedText = viewModel.selectedState.translatedText {
                Button {
                    RichTextFormatting.writeMarkdown(
                        translatedText,
                        to: NSPasteboard.general
                    )
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                .help("선택한 비교 결과 복사")
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var resultContent: some View {
        switch viewModel.selectedState {
        case .idle:
            comparisonPlaceholder(
                title: "비교 결과가 이곳에 표시됩니다",
                detail: "번역 비교 버튼을 누르면 7개 Codex 모델을 순서대로 실행합니다.",
                icon: "rectangle.3.group"
            )

        case .queued:
            comparisonPlaceholder(
                title: "번역 대기 중",
                detail: "앞선 모델의 번역이 끝나면 자동으로 시작합니다.",
                icon: "clock"
            )

        case .translating:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("이 모델로 번역 중입니다.")
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.vertical, 20)

        case let .completed(text):
            MarkdownText(text: text, fontSize: fontSize)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

        case .unavailable:
            comparisonPlaceholder(
                title: "현재 App Server에서 사용할 수 없는 모델입니다",
                detail: viewModel.selectedModel.modelID,
                icon: "nosign"
            )

        case .cancelled:
            comparisonPlaceholder(
                title: "번역이 취소되었습니다",
                detail: "번역 비교를 다시 실행하면 새 결과를 받을 수 있습니다.",
                icon: "xmark.circle"
            )
        }
    }

    private var comparisonControls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.statusMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text("\(viewModel.finishedCount)/\(CodexComparisonModel.allCases.count) 처리 · \(viewModel.completedCount) 성공")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(action: viewModel.isRunning ? onCancel : onCompare) {
                Label(
                    viewModel.isRunning ? "비교 중지" : "번역 비교",
                    systemImage: viewModel.isRunning ? "stop.fill" : "rectangle.3.group"
                )
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 10)
                .frame(height: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isRunning ? .orange : AppTheme.accent)
            .disabled(
                !viewModel.isRunning
                    && sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 62)
        .background(AppTheme.elevatedBackground)
    }

    private func comparisonPlaceholder(
        title: String,
        detail: String,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 20)
    }
}

struct TranslationComparisonModelPicker: View {
    @ObservedObject var viewModel: TranslationComparisonViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(CodexComparisonModel.allCases) { model in
                    Button {
                        viewModel.selectedModel = model
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: stateIcon(for: viewModel.states[model] ?? .idle))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(stateColor(for: viewModel.states[model] ?? .idle))

                            Text(model.tabTitle)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 9)
                        .frame(height: 29)
                        .foregroundStyle(
                            viewModel.selectedModel == model
                                ? AppTheme.selectedTitlebarForeground
                                : Color.primary
                        )
                        .background(
                            viewModel.selectedModel == model
                                ? AppTheme.selectedTitlebarBackground
                                : AppTheme.controlBackground
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(model.displayName)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 50)
        .background(AppTheme.toolbarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.panelBorder)
                .frame(height: 1)
        }
    }

    private func stateIcon(for state: TranslationComparisonState) -> String {
        switch state {
        case .idle:
            "circle"
        case .queued:
            "clock"
        case .translating:
            "ellipsis.circle"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .unavailable:
            "nosign"
        case .cancelled:
            "xmark.circle"
        }
    }

    private func stateColor(for state: TranslationComparisonState) -> Color {
        switch state {
        case .completed:
            AppTheme.success
        case .failed:
            .orange
        case .unavailable, .cancelled:
            .secondary
        case .translating:
            AppTheme.accent
        case .idle, .queued:
            Color.secondary.opacity(0.65)
        }
    }
}
