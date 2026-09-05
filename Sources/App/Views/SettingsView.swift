import SwiftUI
import KCDeepLCore

struct SettingsView: View {
    @State private var selectedCategory = SettingsCategory.general
    @StateObject private var codexModelStore: CodexAppServerModelStore

    init(codexClient: CodexAppServerClient) {
        _codexModelStore = StateObject(
            wrappedValue: CodexAppServerModelStore(provider: codexClient)
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selectedCategory: $selectedCategory)

            Divider()

            ScrollView {
                Group {
                    switch selectedCategory {
                    case .general:
                        GeneralSettingsPane()
                    case .shortcuts:
                        ShortcutSettingsPane()
                    case .accessibility:
                        AccessibilitySettingsPane()
                    case .llmTextTranslation:
                        LLMTextTranslationSettingsPane(
                            codexModelStore: codexModelStore
                        )
                    case .llmLiveTranslation:
                        LLMLiveTranslationSettingsPane()
                    case .files:
                        FileHistorySettingsPane()
                    }
                }
                // Keep the same columns in every pane, including those with a scrollbar.
                .frame(width: 536, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .id(selectedCategory)
        }
        .frame(width: 760, height: 520)
        .controlSize(.small)
        .background(AppTheme.panelBackground)
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "일반"
    case shortcuts = "키보드 단축키"
    case accessibility = "손쉬운 사용"
    case llmTextTranslation = "LLM 번역"
    case llmLiveTranslation = "LLM Live"
    case files = "파일 번역"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general:
            "gearshape"
        case .shortcuts:
            "keyboard"
        case .accessibility:
            "figure.stand"
        case .llmTextTranslation:
            "text.bubble"
        case .llmLiveTranslation:
            "speaker.wave.2"
        case .files:
            "textformat"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selectedCategory: SettingsCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsCategory.allCases) { category in
                Button {
                    selectedCategory = category
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: category.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 18, alignment: .center)

                        Text(category.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(
                            selectedCategory == category
                                ? AppTheme.accent
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(category.rawValue)
                .accessibilityAddTraits(selectedCategory == category ? .isSelected : [])
            }

            Spacer()
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .frame(width: 164)
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject private var launchAtLoginController = LaunchAtLoginController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "KC DeepL 번역기") {
                Toggle(
                    "기기를 켜면 앱이 자동으로 열립니다",
                    isOn: Binding(
                        get: { launchAtLoginController.isRequested },
                        set: { launchAtLoginController.setEnabled($0) }
                    )
                )

                if let statusMessage = launchAtLoginController.statusMessage {
                    Label(
                        statusMessage,
                        systemImage: launchAtLoginStatusImage
                    )
                    .font(.caption)
                    .foregroundStyle(launchAtLoginStatusColor)
                }

                if let errorMessage = launchAtLoginController.errorMessage {
                    Label(errorMessage, systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if launchAtLoginController.requiresApproval {
                    Button("로그인 항목 설정 열기") {
                        launchAtLoginController.openSystemSettings()
                    }
                }
            }
        }
        .onAppear {
            launchAtLoginController.refreshStatus()
        }
    }

    private var launchAtLoginStatusImage: String {
        switch launchAtLoginController.status {
        case .enabled:
            "checkmark.circle"
        case .requiresApproval:
            "exclamationmark.triangle"
        case .notRegistered, .notFound:
            "xmark.circle"
        }
    }

    private var launchAtLoginStatusColor: Color {
        switch launchAtLoginController.status {
        case .enabled:
            .secondary
        case .requiresApproval:
            .orange
        case .notRegistered, .notFound:
            .red
        }
    }
}

private struct ShortcutSettingsPane: View {
    @AppStorage(PreferenceKeys.selectedTextShortcut) private var selectedTextShortcut = "⌃⇧1"
    @AppStorage(PreferenceKeys.rewriteShortcut) private var rewriteShortcut = "⌃⇧2"
    @State private var registrationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("단축키 설정")
                    .font(.headline)
                Text("입력 칸을 클릭한 뒤 사용할 키 조합을 누르세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let registrationMessage {
                    Label(registrationMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            ShortcutRow(
                title: "선택한 텍스트 번역",
                description: "텍스트 선택 후 이 단축키를 누르면 KC DeepL 앱에서 번역이 열립니다.",
                shortcut: $selectedTextShortcut,
                defaultShortcut: "⌃⇧1",
                unavailableShortcuts: normalizedShortcuts([rewriteShortcut])
            )

            Divider()

            ShortcutRow(
                title: "Live 번역",
                description: "라이브 번역 화면을 단축키로 즉시 열 수 있습니다.",
                shortcut: $rewriteShortcut,
                defaultShortcut: "⌃⇧2",
                unavailableShortcuts: normalizedShortcuts([selectedTextShortcut])
            )

            HStack {
                Spacer()
                Button("모두 기본값으로 초기화") {
                    selectedTextShortcut = "⌃⇧1"
                    rewriteShortcut = "⌃⇧2"
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .kcDeepLShortcutRegistrationFailed)
        ) { notification in
            registrationMessage = notification.object as? String
        }
    }

    private func normalizedShortcuts(_ values: [String]) -> Set<String> {
        Set(values.compactMap { AppShortcutDescriptor.parse($0)?.displayString })
    }
}

private struct AccessibilitySettingsPane: View {
    @AppStorage(PreferenceKeys.readingFontSize)
    private var readingFontSize = ReadingFontSize.defaultValue.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "글꼴 크기", description: "번역된 텍스트를 쉽게 읽을 수 있도록 원하는 글꼴 크기를 선택하세요.") {
                Text("번역문은 이렇게 표시됩니다.")
                    .font(.system(size: previewFontSize, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 5))

                SettingsPickerRow(title: "글꼴 크기", selection: $readingFontSize) {
                    ForEach(ReadingFontSize.allCases) { size in
                        Text("\(size.points) pt").tag(size.rawValue)
                    }
                }
            }
        }
        .onAppear {
            readingFontSize = ReadingFontSize.resolved(readingFontSize).rawValue
        }
    }

    private var previewFontSize: CGFloat {
        CGFloat(ReadingFontSize.resolved(readingFontSize).points)
    }
}

private struct FileHistorySettingsPane: View {
    @AppStorage(PreferenceKeys.downloadLocation) private var downloadLocation = "desktop"
    @AppStorage(PreferenceKeys.historyEnabled) private var historyEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "다운로드 위치", description: "번역 파일을 저장할 위치를 선택합니다.") {
                SettingsPickerRow(title: "저장 위치", selection: $downloadLocation) {
                    Text("데스크탑").tag("desktop")
                    Text("다운로드").tag("downloads")
                    Text("매번 묻기").tag("ask")
                }
            }

            SettingsSection(title: "번역 기록", description: "번역을 자동으로 저장하여 이전 번역을 빠르게 찾고 재사용할 수 있습니다. 기록은 이 기기에 로컬로 저장합니다.") {
                Toggle("번역 기록 켜기", isOn: $historyEnabled)
            }
        }
    }
}

private struct LLMTextTranslationSettingsPane: View {
    @ObservedObject var codexModelStore: CodexAppServerModelStore
    @AppStorage(PreferenceKeys.translationBackend)
    private var translationBackendRaw = AppDefaults.defaultTranslationBackend.rawValue
    @AppStorage(PreferenceKeys.provider) private var providerRaw = AppDefaults.defaultProvider.rawValue
    @AppStorage(PreferenceKeys.modelID) private var modelID = AppDefaults.defaultModelID
    @AppStorage(PreferenceKeys.codexModelID)
    private var codexModelID = AppDefaults.defaultCodexModelID
    @AppStorage(PreferenceKeys.geminiAPIKey) private var apiKey = ""
    @AppStorage(PreferenceKeys.autoTranslate) private var autoTranslate = true
    @AppStorage(PreferenceKeys.temperature) private var temperature = 0.2

    private var providerBinding: Binding<LLMProvider> {
        Binding {
            LLMProvider(rawValue: providerRaw) ?? .gemini
        } set: { provider in
            providerRaw = provider.rawValue
            if !provider.models.contains(where: { $0.id == modelID }) {
                modelID = provider.models.first?.id ?? modelID
            }
        }
    }

    private var backendBinding: Binding<TranslationBackend> {
        Binding {
            TranslationBackend(rawValue: translationBackendRaw)
                ?? AppDefaults.defaultTranslationBackend
        } set: { backend in
            translationBackendRaw = backend.rawValue
        }
    }

    private var currentBackend: TranslationBackend {
        TranslationBackend(rawValue: translationBackendRaw)
            ?? AppDefaults.defaultTranslationBackend
    }

    private var currentProvider: LLMProvider {
        LLMProvider(rawValue: providerRaw) ?? .gemini
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(
                title: "LLM 번역 모델",
                description: "텍스트 번역 요청을 처리할 방식과 모델을 선택합니다."
            ) {
                SettingsPickerRow(
                    title: "번역 방식",
                    selection: backendBinding
                ) {
                    ForEach(TranslationBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }

                if currentBackend == .codexAppServer {
                    codexAppServerSettings
                } else {
                    llmAPISettings
                }

                Toggle("입력 후 자동 번역", isOn: $autoTranslate)
            }
        }
        .task(id: currentBackend) {
            guard currentBackend == .codexAppServer else {
                return
            }
            await codexModelStore.refresh()
            normalizeCodexModelSelection()
        }
        .onChange(of: codexModelStore.models) { _, _ in
            normalizeCodexModelSelection()
        }
    }

    @ViewBuilder
    private var codexAppServerSettings: some View {
        if codexModelStore.models.isEmpty {
            HStack(spacing: 10) {
                if codexModelStore.isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Codex 모델 목록을 불러오는 중입니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("선택할 수 있는 Codex 모델이 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("다시 불러오기") {
                    Task {
                        await codexModelStore.refresh()
                        normalizeCodexModelSelection()
                    }
                }
                .disabled(codexModelStore.isLoading)
            }
        } else {
            SettingsPickerRow(
                title: "Codex 모델",
                selection: $codexModelID
            ) {
                ForEach(codexModelStore.models) { model in
                    Text(model.displayName).tag(model.model)
                }
            }

            HStack(spacing: 10) {
                if codexModelStore.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("모델 목록 새로고침") {
                    Task {
                        await codexModelStore.refresh()
                        normalizeCodexModelSelection()
                    }
                }
                .disabled(codexModelStore.isLoading)
            }
        }

        if let selectedModel = codexModelStore.models.first(
            where: { $0.model == codexModelID }
        ), !selectedModel.description.isEmpty {
            Text(selectedModel.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let errorMessage = codexModelStore.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        Text(
            "현재 Mac의 Codex 로그인으로 요청하며, 모든 번역은 Codex 작업 ‘\(CodexAppServerClient.fixedThreadName)’에서 처리됩니다. 앱의 로컬 번역 기록을 꺼도 이 Codex 작업 기록은 별도로 남습니다."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var llmAPISettings: some View {
        SettingsPickerRow(title: "공급자", selection: providerBinding) {
            Text(LLMProvider.gemini.displayName).tag(LLMProvider.gemini)
            if currentProvider != .gemini {
                Text("\(currentProvider.displayName) (미지원)")
                    .tag(currentProvider)
                    .disabled(true)
            }
        }

        SettingsPickerRow(title: "세부모델", selection: $modelID) {
            ForEach(currentProvider.models) { model in
                Text(model.displayName).tag(model.id)
            }
        }

        SettingsSecureFieldRow(
            title: "번역 API",
            text: $apiKey
        )

        Text("API 키는 이 Mac의 앱 설정에 저장됩니다.")
            .font(.caption)
            .foregroundStyle(.secondary)

        HStack(spacing: 12) {
            SettingsRowTitle("창의성")
            Slider(value: $temperature, in: 0...1, step: 0.1)
                .accessibilityLabel("창의성")
            Text("\(temperature, specifier: "%.1f")")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func normalizeCodexModelSelection() {
        guard !codexModelStore.models.isEmpty,
              !codexModelStore.models.contains(where: { $0.model == codexModelID }),
              let fallback = codexModelStore.defaultModel
        else {
            return
        }
        codexModelID = fallback.model
    }
}

private struct LLMLiveTranslationSettingsPane: View {
    @AppStorage(PreferenceKeys.liveProvider) private var liveProviderRaw = AppDefaults.defaultProvider.rawValue
    @AppStorage(PreferenceKeys.liveModelID) private var liveModelID = AppDefaults.defaultLiveModelID
    @AppStorage(PreferenceKeys.liveListeningAPIKey) private var listeningAPIKey = ""
    @AppStorage(PreferenceKeys.liveSpeakingAPIKey) private var speakingAPIKey = ""
    @AppStorage(PreferenceKeys.liveRemoteMicInput) private var remoteMicInput = ""
    @AppStorage(PreferenceKeys.liveRemoteSpeakerOutput) private var remoteSpeakerOutput = ""
    @AppStorage(PreferenceKeys.liveLocalMicInput) private var localMicInput = ""
    @AppStorage(PreferenceKeys.liveLocalSpeakerOutput) private var localSpeakerOutput = ""
    @AppStorage(PreferenceKeys.liveLocalTargetLanguage) private var localTargetLanguage = "en"
    @AppStorage(PreferenceKeys.liveRemoteTargetLanguage) private var remoteTargetLanguage = "ko"
    @AppStorage(PreferenceKeys.liveLocalTargetEcho) private var localTargetEcho = false
    @AppStorage(PreferenceKeys.liveRemoteTargetEcho) private var remoteTargetEcho = false
    @AppStorage(PreferenceKeys.livePauseRemoteInputOnStart) private var pauseRemoteInputOnStart = true
    @AppStorage(PreferenceKeys.liveListenerVolume) private var listenerVolume = 1.0
    @State private var inputDeviceOptions: [String] = []
    @State private var outputDeviceOptions: [String] = []

    private let liveModelOptions = [
        LiveModelOption(id: AppDefaults.defaultLiveModelID, title: "Gemini 3.5 Live Translate")
    ]

    private var liveProviderBinding: Binding<LLMProvider> {
        Binding {
            LLMProvider(rawValue: liveProviderRaw) ?? .gemini
        } set: { provider in
            liveProviderRaw = provider.rawValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "LLM 라이브 번역 모델", description: "실시간 음성 번역에 사용할 모델과 양방향 API 키를 설정합니다.") {
                SettingsPickerRow(title: "공급자", selection: liveProviderBinding) {
                    Text(LLMProvider.gemini.displayName).tag(LLMProvider.gemini)
                }

                SettingsPickerRow(title: "세부모델", selection: $liveModelID) {
                    ForEach(liveModelOptions) { model in
                        Text(model.title).tag(model.id)
                    }
                }

                SettingsSecureFieldRow(
                    title: "수화용 API",
                    text: $listeningAPIKey
                )
                SettingsSecureFieldRow(
                    title: "발화용 API",
                    text: $speakingAPIKey
                )

                Text("API 키는 이 Mac의 앱 설정에 저장됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(title: "오디오 장치") {
                AudioRoutingPicker(title: "상대방 마이크 입력", selection: $remoteMicInput, options: inputDeviceOptions)
                AudioRoutingPicker(title: "상대방 스피커 출력", selection: $remoteSpeakerOutput, options: outputDeviceOptions)
                AudioRoutingPicker(title: "말하는 마이크 입력", selection: $localMicInput, options: inputDeviceOptions)
                AudioRoutingPicker(title: "듣리는 스피커 출력", selection: $localSpeakerOutput, options: outputDeviceOptions)
            }

            SettingsSection(title: "언어와 재생") {
                HStack(alignment: .top, spacing: 16) {
                    SettingsTextFieldRow(title: "상대방 언어", text: $localTargetLanguage)
                    SettingsTextFieldRow(title: "발화자 언어", text: $remoteTargetLanguage)
                }

                Toggle("내 target 언어 echo", isOn: $localTargetEcho)
                Toggle("상대방 target 언어 echo", isOn: $remoteTargetEcho)
                Toggle("대화 시작 중에는 상대방 입력 잠시 중지", isOn: $pauseRemoteInputOnStart)

                HStack(spacing: 12) {
                    SettingsRowTitle("듣는 볼륨")
                    Slider(value: $listenerVolume, in: 0...1)
                        .accessibilityLabel("듣는 볼륨")
                    Text("\(Int(listenerVolume * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .onAppear(perform: refreshAudioDeviceOptions)
    }

    private func refreshAudioDeviceOptions() {
        remoteMicInput = LiveAudioDeviceRegistry.normalizedInputDeviceLabel(
            selection: remoteMicInput,
            preferredNames: ["BlackHole 2ch", "BlackHole"]
        )
        localMicInput = LiveAudioDeviceRegistry.normalizedInputDeviceLabel(
            selection: localMicInput,
            preferredNames: ["MacBook Pro 마이크", "Built-in Microphone"]
        )
        remoteSpeakerOutput = LiveAudioDeviceRegistry.normalizedOutputDeviceLabel(
            selection: remoteSpeakerOutput,
            preferredNames: ["BlackHole 16ch", "BlackHole 2ch", "BlackHole"]
        )
        localSpeakerOutput = LiveAudioDeviceRegistry.normalizedOutputDeviceLabel(
            selection: localSpeakerOutput,
            preferredNames: ["MacBook Pro 스피커", "External Headphones", "Headphones"]
        )

        inputDeviceOptions = LiveAudioDeviceRegistry.inputDeviceLabels()
        outputDeviceOptions = LiveAudioDeviceRegistry.outputDeviceLabels()
    }
}

private struct LiveModelOption: Identifiable {
    let id: String
    let title: String
}

private struct AudioRoutingPicker: View {
    let title: String
    @Binding var selection: String
    let options: [String]

    var body: some View {
        SettingsPickerRow(title: title, selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .help(selection)
    }
}

private struct SettingsPickerRow<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowTitle(title)

            Group {
                if #available(macOS 26.0, *) {
                    picker.buttonSizing(.flexible)
                } else {
                    picker
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            content
        }
        .labelsHidden()
    }
}

private struct SettingsSecureFieldRow: View {
    let title: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowTitle(title)

            SecureField(title, text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 0, maxWidth: .infinity)
        }
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(title, text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 0, maxWidth: .infinity)
        }
    }
}

private struct SettingsRowTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 112, alignment: .leading)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    var description: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let description: String
    @Binding var shortcut: String
    let defaultShortcut: String
    let unavailableShortcuts: Set<String>
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.headline)

                Spacer(minLength: 12)

                ShortcutRecorder(
                    shortcut: $shortcut,
                    unavailableShortcuts: unavailableShortcuts,
                    onValidationError: { validationMessage = $0 }
                )
                .frame(width: 180)

                Button {
                    shortcut = defaultShortcut
                    validationMessage = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 20, height: 24)
                }
                .buttonStyle(.plain)
                .help("기본 단축키로 복원")
                .accessibilityLabel("\(title) 단축키 기본값으로 초기화")
            }

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
