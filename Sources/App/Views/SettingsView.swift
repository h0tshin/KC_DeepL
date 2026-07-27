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
                    case .advanced:
                        AdvancedSettingsPane()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 34)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 1100, height: 720)
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
    case advanced = "고급"

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
        case .advanced:
            "slider.horizontal.3"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selectedCategory: SettingsCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(SettingsCategory.allCases) { category in
                Button {
                    selectedCategory = category
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: category.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 24, alignment: .center)

                        Text(category.rawValue)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13)
                        .frame(height: 48)
                        .background(
                            selectedCategory == category
                                ? AppTheme.accent
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.top, 60)
        .padding(.horizontal, 34)
        .frame(width: 230)
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject private var launchAtLoginController = LaunchAtLoginController.shared
    @AppStorage(PreferenceKeys.quickAccessMode) private var quickAccessMode = "floating"
    @AppStorage(PreferenceKeys.closeBehavior) private var closeBehavior = "background"

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
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

            SettingsSection(title: "빠른 액세스 옵션", description: "특정 단축키 또는 부동 KC DeepL 아이콘 사용 시, 번역 또는 개선된 텍스트가 열릴 위치를 선택합니다.") {
                RadioGroup(
                    selection: $quickAccessMode,
                    items: [
                        RadioItem(id: "floating", title: "작은 플로팅 창에 표시"),
                        RadioItem(id: "app", title: "앱에 표시")
                    ]
                )
            }

            SettingsSection(title: "KC DeepL 앱 닫기", description: "닫기를 누른 후의 앱 작동 방식을 선택하세요.") {
                RadioGroup(
                    selection: $closeBehavior,
                    items: [
                        RadioItem(id: "background", title: "단축키로 활성화할 수 있도록 백그라운드에 유지"),
                        RadioItem(id: "quit", title: "앱을 종료"),
                        RadioItem(id: "menuBar", title: "메뉴 막대에 유지")
                    ]
                )
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
    @AppStorage(PreferenceKeys.screenCaptureShortcut) private var screenCaptureShortcut = "⌃⇧3"
    @State private var registrationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("단축키 설정")
                    .font(.title3.bold())
                Text("단축키를 사용하여 번역 워크플로의 효율을 높입니다. 편집하려면 텍스트 영역을 선택한 후, 함께 사용할 새로운 키 조합을 입력하세요.")
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
                unavailableShortcuts: normalizedShortcuts([
                    rewriteShortcut,
                    screenCaptureShortcut
                ])
            )

            ShortcutRow(
                title: "Live 번역",
                description: "라이브 번역 화면을 단축키로 즉시 열 수 있습니다.",
                shortcut: $rewriteShortcut,
                defaultShortcut: "⌃⇧2",
                unavailableShortcuts: normalizedShortcuts([
                    selectedTextShortcut,
                    screenCaptureShortcut
                ])
            )

            ShortcutRow(
                title: "텍스트 화면 캡처",
                description: "KC DeepL 앱에서 번역하려는 텍스트의 스크린샷을 찍습니다.",
                shortcut: $screenCaptureShortcut,
                defaultShortcut: "⌃⇧3",
                unavailableShortcuts: normalizedShortcuts([
                    selectedTextShortcut,
                    rewriteShortcut
                ]),
                note: "OCR 인식은 다음 구현 단계에서 연결됩니다."
            )

            HStack {
                Spacer()
                Button("모두 기본값으로 초기화") {
                    selectedTextShortcut = "⌃⇧1"
                    rewriteShortcut = "⌃⇧2"
                    screenCaptureShortcut = "⌃⇧3"
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
    @AppStorage(PreferenceKeys.speechSpeed) private var speechSpeed = "1.0"

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            SettingsSection(title: "글꼴 크기", description: "번역된 텍스트를 쉽게 읽을 수 있도록 원하는 글꼴 크기를 선택하세요.") {
                Text("번역문은 이렇게 표시됩니다.")
                    .font(.system(size: previewFontSize, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 128)
                    .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 5))

                Picker("글꼴 크기 변경", selection: $readingFontSize) {
                    ForEach(ReadingFontSize.allCases) { size in
                        Text("\(size.points) pt").tag(size.rawValue)
                    }
                }
                .frame(width: 260)
            }

            SettingsSection(title: "음성 속도", description: "음성 텍스트 속도를 조절하세요. 천천히 들으며 정확히 이해하거나, 빠르게 재생하여 시간을 절약할 수 있습니다.") {
                Image(systemName: "speaker.wave.2")
                    .font(.title2)
                    .foregroundStyle(AppTheme.accent)
                    .padding(8)
                    .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 6))

                Picker("음성 속도 변경", selection: $speechSpeed) {
                    Text("0.75 (느림)").tag("0.75")
                    Text("1.0 (보통)").tag("1.0")
                    Text("1.25 (빠름)").tag("1.25")
                }
                .frame(width: 260)
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
        VStack(alignment: .leading, spacing: 30) {
            SettingsSection(title: "다운로드 위치", description: "번역 파일을 저장할 위치를 선택합니다.") {
                Picker("위치", selection: $downloadLocation) {
                    Text("데스크탑").tag("desktop")
                    Text("다운로드").tag("downloads")
                    Text("매번 묻기").tag("ask")
                }
                .frame(width: 240)
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
        VStack(alignment: .leading, spacing: 30) {
            SettingsSection(
                title: "LLM 번역 모델",
                description: "텍스트 번역 요청을 처리할 방식과 모델을 선택합니다."
            ) {
                SettingsPickerRow(
                    title: "번역 방식",
                    selection: backendBinding,
                    width: 320
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
                selection: $codexModelID,
                width: 320
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
        SettingsPickerRow(title: "공급자", selection: providerBinding, width: 320) {
            ForEach(LLMProvider.allCases) { provider in
                Text(provider.displayName).tag(provider)
            }
        }

        SettingsPickerRow(title: "세부모델", selection: $modelID, width: 320) {
            ForEach(currentProvider.models) { model in
                Text(model.displayName).tag(model.id)
            }
        }

        SettingsSecureFieldRow(
            title: "번역 API",
            text: $apiKey,
            width: 500
        )

        Text("API 키는 이 Mac의 앱 설정에 저장됩니다.")
            .font(.caption)
            .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 8) {
            Text("창의성 \(temperature, specifier: "%.1f")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $temperature, in: 0...1, step: 0.1)
                .frame(maxWidth: 360)
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
        VStack(alignment: .leading, spacing: 30) {
            SettingsSection(title: "LLM 라이브 번역 모델", description: "실시간 음성 번역에 사용할 모델과 양방향 API 키를 설정합니다.") {
                SettingsPickerRow(title: "공급자", selection: liveProviderBinding, width: 320) {
                    Text(LLMProvider.gemini.displayName).tag(LLMProvider.gemini)
                }

                SettingsPickerRow(title: "세부모델", selection: $liveModelID, width: 320) {
                    ForEach(liveModelOptions) { model in
                        Text(model.title).tag(model.id)
                    }
                }

                SettingsSecureFieldRow(
                    title: "수화용 API",
                    text: $listeningAPIKey,
                    width: 620
                )
                SettingsSecureFieldRow(
                    title: "발화용 API",
                    text: $speakingAPIKey,
                    width: 620
                )

                Text("API 키는 이 Mac의 앱 설정에 저장됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(title: "Audio Routing") {
                AudioRoutingPicker(title: "상대방 마이크 입력", selection: $remoteMicInput, options: inputDeviceOptions)
                AudioRoutingPicker(title: "상대방 스피커 출력", selection: $remoteSpeakerOutput, options: outputDeviceOptions)
                AudioRoutingPicker(title: "말하는 마이크 입력", selection: $localMicInput, options: inputDeviceOptions)
                AudioRoutingPicker(title: "듣리는 스피커 출력", selection: $localSpeakerOutput, options: outputDeviceOptions)
            }

            SettingsSection(title: "Translation") {
                SettingsTextFieldRow(title: "상대방 언어", text: $localTargetLanguage, width: 230)
                SettingsTextFieldRow(title: "발화자 언어", text: $remoteTargetLanguage, width: 230)

                Toggle("내 target 언어 echo", isOn: $localTargetEcho)
                Toggle("상대방 target 언어 echo", isOn: $remoteTargetEcho)
                Toggle("대화 시작 중에는 상대방 입력 잠시 중지", isOn: $pauseRemoteInputOnStart)

                VStack(alignment: .leading, spacing: 8) {
                    Text("듣는 볼륨 \(Int(listenerVolume * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $listenerVolume, in: 0...1)
                        .frame(maxWidth: 360)
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

private struct AdvancedSettingsPane: View {
    var body: some View {
        Text("kc.Shin")
            .font(.system(size: 34, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .frame(minHeight: 560)
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
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 150, alignment: .leading)

            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 640)
        }
    }
}

private struct SettingsPickerRow<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    var width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 16) {
            SettingsRowTitle(title)

            Picker(title, selection: $selection) {
                content
            }
            .labelsHidden()
            .frame(width: width, alignment: .leading)
        }
    }
}

private struct SettingsSecureFieldRow: View {
    let title: String
    @Binding var text: String
    var width: CGFloat

    var body: some View {
        HStack(spacing: 16) {
            SettingsRowTitle(title)

            SecureField(title, text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    @Binding var text: String
    var width: CGFloat

    var body: some View {
        HStack(spacing: 16) {
            SettingsRowTitle(title)

            TextField(title, text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
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
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 150, alignment: .leading)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    var description: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.bold())

                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
    }
}

private struct RadioItem: Identifiable {
    let id: String
    let title: String
}

private struct RadioGroup: View {
    @Binding var selection: String
    let items: [RadioItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                Button {
                    selection = item.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selection == item.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selection == item.id ? AppTheme.accent : .secondary)
                        Text(item.title)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityValue(selection == item.id ? "선택됨" : "선택 안 됨")
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
    var note: String?
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().opacity(0.35)

            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title3.bold())
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let note {
                        Text(note)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 5))
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    ShortcutRecorder(
                        shortcut: $shortcut,
                        unavailableShortcuts: unavailableShortcuts,
                        onValidationError: { validationMessage = $0 }
                    )
                    .frame(width: 180)

                    if let validationMessage {
                        Text(validationMessage)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else {
                        Text("클릭한 뒤 새 조합을 누르세요")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    shortcut = defaultShortcut
                    validationMessage = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title) 단축키 기본값으로 초기화")
            }
        }
    }
}
