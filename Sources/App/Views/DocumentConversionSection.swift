import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DocumentConversionSection: View {
    @ObservedObject var conversionViewModel: DocumentConversionViewModel
    @ObservedObject var fileTranslationViewModel: FileTranslationViewModel
    @Binding var downloadLocation: String

    private var isPDF: Bool {
        guard let sourceURL = fileTranslationViewModel.sourceURL else {
            return false
        }
        return sourceURL.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
    }

    private var isBlockedByTranslation: Bool {
        fileTranslationViewModel.isBusy
    }

    private var sourceGeneration: UInt {
        fileTranslationViewModel.selectedFileSnapshot?.selectionGeneration
            ?? fileTranslationViewModel.sourceDocumentVersion
    }

    private var formatBinding: Binding<DocumentConversionFormat> {
        Binding(
            get: { conversionViewModel.selectedFormat },
            set: { conversionViewModel.selectFormat($0) }
        )
    }

    private var optionsDisabled: Bool {
        isBlockedByTranslation || conversionViewModel.isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("문서 변환", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
                .font(.headline)

            if !isPDF {
                Label(
                    "PDF에서만 사용할 수 있습니다.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text("변환 형식")
                .font(.headline)

            Picker("변환 형식", selection: formatBinding) {
                ForEach(DocumentConversionFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("변환 형식")
            .accessibilityValue(conversionViewModel.selectedFormat.displayName)
            .disabled(optionsDisabled)

            if conversionViewModel.selectedFormat == .pptx {
                presentationOptions
            } else {
                wordOptions
            }

            Text("저장 위치")
                .font(.headline)

            Picker("위치", selection: $downloadLocation) {
                Text("데스크탑").tag(FileTranslationOutputLocation.desktop.rawValue)
                Text("다운로드").tag(FileTranslationOutputLocation.downloads.rawValue)
                Text("매번 묻기").tag(FileTranslationOutputLocation.ask.rawValue)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Text("원본 PDF는 절대 덮어쓰지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("편집 가능한 텍스트·도형을 복원하고, PDF의 투명도·마스크가 복합적인 영역은 페이지 RGBA 이미지로 보존합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if conversionViewModel.isBusy {
                ProgressView(value: conversionViewModel.progress) {
                    HStack(spacing: 6) {
                        Text(conversionViewModel.statusMessage)
                        Spacer(minLength: 4)
                        Text("\(Int((conversionViewModel.progress * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .accessibilityLabel("문서 변환 진행률")
                .accessibilityValue("\(Int(conversionViewModel.progress * 100))퍼센트")

                Button("변환 취소", role: .cancel) {
                    conversionViewModel.cancelConversion()
                }
                .frame(maxWidth: .infinity)
                .accessibilityHint("실행 중인 변환만 취소합니다.")
            } else {
                Button {
                    startConversion()
                } label: {
                    Label("변환 시작", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isPDF || isBlockedByTranslation)
                .accessibilityLabel("변환 시작")
                .accessibilityHint("선택한 PDF를 현재 형식으로 저장합니다.")
            }

            if let errorMessage = conversionViewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let outputURL = conversionViewModel.outputURL {
                HStack(spacing: 8) {
                    Button("변환 문서 열기") {
                        NSWorkspace.shared.open(outputURL)
                    }
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    }
                }
                .controlSize(.small)
            }
            if let reportURL = conversionViewModel.reportURL {
                Button("품질 보고서 보기") {
                    NSWorkspace.shared.open(reportURL)
                }
                .controlSize(.small)
            }
            if !conversionViewModel.warnings.isEmpty {
                Text("품질 보고서에 변환 경고 \(conversionViewModel.warnings.count)개를 기록했습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func startConversion() {
        guard let sourceURL = fileTranslationViewModel.sourceURL,
              isPDF
        else { return }
        let explicitDestination: URL?
        if downloadLocation == FileTranslationOutputLocation.ask.rawValue {
            guard let selected = DocumentConversionPanel.chooseDestination(
                sourceURL: sourceURL,
                format: conversionViewModel.selectedFormat
            ) else {
                return
            }
            explicitDestination = selected
        } else {
            explicitDestination = nil
        }
        conversionViewModel.start(
            sourceURL: sourceURL,
            sourceGeneration: sourceGeneration,
            format: conversionViewModel.selectedFormat,
            downloadLocation: downloadLocation,
            explicitlySelectedDestination: explicitDestination
        )
    }

    private var presentationOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("PPT 변환 옵션", systemImage: "rectangle.on.rectangle.angled")
                .font(.headline)

            Text("템플릿화 우선")
                .font(.subheadline.weight(.medium))
            Picker(
                "템플릿화 우선",
                selection: presentationBinding(\.templatePriority)
            ) {
                ForEach(DocumentTemplatePriority.allCases) { priority in
                    Text(priority.displayName).tag(priority)
                }
            }
            .labelsHidden()

            Text(conversionViewModel.options.presentation.templatePriority.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("글상자 병합 범위")
                .font(.subheadline.weight(.medium))
            Picker(
                "글상자 병합 범위",
                selection: presentationBinding(\.textBoxMergeLevel)
            ) {
                ForEach(PresentationTextBoxMergeLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .labelsHidden()

            Text(conversionViewModel.options.presentation.textBoxMergeLevel.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("이미지 통합/분할 단계")
                .font(.subheadline.weight(.medium))
            Picker(
                "이미지 통합/분할",
                selection: presentationBinding(\.imageGroupingLevel)
            ) {
                ForEach(DocumentImageGroupingLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .labelsHidden()

            Text(conversionViewModel.options.presentation.imageGroupingLevel.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "선·도형을 편집 가능한 PPT 도형으로 복원",
                isOn: presentationBinding(\.preserveNativeVectors)
            )
            .toggleStyle(.checkbox)

            Toggle(
                "투명도·마스크 이미지도 네이티브 그림으로 보존",
                isOn: presentationBinding(\.preserveAlphaMasks)
            )
            .toggleStyle(.checkbox)
        }
        .disabled(optionsDisabled)
    }

    private var wordOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("DOC 변환 옵션", systemImage: "doc.text")
                .font(.headline)

            Text("꼬리말 사용")
                .font(.subheadline.weight(.medium))
            Picker(
                "꼬리말 사용",
                selection: wordBinding(\.templatePriority)
            ) {
                ForEach(DocumentTemplatePriority.allCases) { priority in
                    Text(priority.wordDisplayName).tag(priority)
                }
            }
            .labelsHidden()

            Text(conversionViewModel.options.word.templatePriority.wordDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("글상자 사용 여부")
                .font(.subheadline.weight(.medium))
            Picker(
                "글상자 사용 여부",
                selection: wordBinding(\.textRepresentation)
            ) {
                ForEach(WordTextRepresentation.allCases) { representation in
                    Text(representation.displayName).tag(representation)
                }
            }
            .labelsHidden()

            Text(conversionViewModel.options.word.textRepresentation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if conversionViewModel.options.word.textRepresentation == .documentText {
                Text("글상자 허용 범위")
                    .font(.subheadline.weight(.medium))
                Picker(
                    "글상자 허용 범위",
                    selection: wordBinding(\.textBoxAllowance)
                ) {
                    ForEach(WordTextBoxAllowance.allCases) { allowance in
                        Text(allowance.displayName).tag(allowance)
                    }
                }
                .labelsHidden()

                Text(conversionViewModel.options.word.textBoxAllowance.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("이미지 통합/분할 단계")
                .font(.subheadline.weight(.medium))
            Picker(
                "이미지 통합/분할",
                selection: wordBinding(\.imageGroupingLevel)
            ) {
                ForEach(DocumentImageGroupingLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .labelsHidden()

            Text(conversionViewModel.options.word.imageGroupingLevel.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "선·도형을 편집 가능한 Word 도형으로 복원",
                isOn: wordBinding(\.preserveNativeVectors)
            )
            .toggleStyle(.checkbox)

            Toggle(
                "투명도·마스크 이미지도 네이티브 그림으로 보존",
                isOn: wordBinding(\.preserveAlphaMasks)
            )
            .toggleStyle(.checkbox)
        }
        .disabled(optionsDisabled)
    }

    private func presentationBinding<Value>(
        _ keyPath: WritableKeyPath<PresentationConversionOptions, Value>
    ) -> Binding<Value> {
        Binding(
            get: { conversionViewModel.options.presentation[keyPath: keyPath] },
            set: { newValue in
                var options = conversionViewModel.options.presentation
                options[keyPath: keyPath] = newValue
                conversionViewModel.updatePresentationOptions(options)
            }
        )
    }

    private func wordBinding<Value>(
        _ keyPath: WritableKeyPath<WordConversionOptions, Value>
    ) -> Binding<Value> {
        Binding(
            get: { conversionViewModel.options.word[keyPath: keyPath] },
            set: { newValue in
                var options = conversionViewModel.options.word
                options[keyPath: keyPath] = newValue
                conversionViewModel.updateWordOptions(options)
            }
        )
    }
}
private enum DocumentConversionPanel {
    @MainActor
    static func chooseDestination(
        sourceURL: URL,
        format: DocumentConversionFormat
    ) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = (
            try? DocumentConversionOutputURLResolver().suggestedFilename(
                for: sourceURL,
                format: format
            )
        ) ?? "converted.\(format.fileExtension)"
        panel.message = "원본 PDF와 다른 이름으로 Office 문서를 저장합니다."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
