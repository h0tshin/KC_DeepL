import SwiftUI
import KCDeepLCore

struct SettingsView: View {
    @State private var selectedCategory = SettingsCategory.general

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
        .frame(width: 900, height: 660)
        .background(AppTheme.panelBackground)
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "일반"
    case shortcuts = "키보드 단축키"
    case accessibility = "손쉬운 사용"
    case files = "파일 및 번역"
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
                    Label(category.rawValue, systemImage: category.icon)
                        .font(.system(size: 15, weight: .semibold))
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
    @AppStorage(PreferenceKeys.launchAtLogin) private var launchAtLogin = true
    @AppStorage(PreferenceKeys.quickAccessMode) private var quickAccessMode = "floating"
    @AppStorage(PreferenceKeys.closeBehavior) private var closeBehavior = "background"

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            SettingsSection(title: "DeepL 열기") {
                Toggle("기기를 켜면 앱이 자동으로 열립니다", isOn: $launchAtLogin)
            }

            SettingsSection(title: "빠른 액세스 옵션", description: "특정 단축키 또는 부동 DeepL 아이콘 사용 시, 번역 또는 개선된 텍스트가 열릴 위치를 선택합니다.") {
                RadioGroup(
                    selection: $quickAccessMode,
                    items: [
                        RadioItem(id: "floating", title: "작은 플로팅 창에 표시"),
                        RadioItem(id: "app", title: "앱에 표시")
                    ]
                )
            }

            SettingsSection(title: "DeepL 앱 닫기", description: "닫기를 누른 후의 앱 작동 방식을 선택하세요.") {
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
    }
}

private struct ShortcutSettingsPane: View {
    @AppStorage(PreferenceKeys.selectedTextShortcut) private var selectedTextShortcut = "⇧⌘1"
    @AppStorage(PreferenceKeys.rewriteShortcut) private var rewriteShortcut = "⌃⌘C"
    @AppStorage(PreferenceKeys.screenCaptureShortcut) private var screenCaptureShortcut = "⇧⌘2"

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("단축키 설정")
                    .font(.title3.bold())
                Text("단축키를 사용하여 번역 워크플로의 효율을 높입니다. 편집하려면 텍스트 영역을 선택한 후, 함께 사용할 새로운 키 조합을 입력하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ShortcutRow(
                title: "선택한 텍스트 번역",
                description: "텍스트 선택 후 이 단축키를 누르면 KC DeepL 앱에서 번역이 열립니다.",
                shortcut: $selectedTextShortcut
            )

            ShortcutRow(
                title: "선택한 텍스트 다시 쓰기",
                description: "선택한 텍스트를 KC DeepL Write로 즉시 교정할 수 있습니다.",
                shortcut: $rewriteShortcut
            )

            ShortcutRow(
                title: "텍스트 화면 캡처",
                description: "KC DeepL 앱에서 번역하려는 텍스트의 스크린샷을 찍습니다.",
                shortcut: $screenCaptureShortcut,
                note: "OCR 인식은 다음 구현 단계에서 연결됩니다."
            )

            HStack {
                Spacer()
                Button("모두 기본값으로 초기화") {
                    selectedTextShortcut = "⇧⌘1"
                    rewriteShortcut = "⌃⌘C"
                    screenCaptureShortcut = "⇧⌘2"
                }
            }
        }
    }
}

private struct AccessibilitySettingsPane: View {
    @AppStorage(PreferenceKeys.readingFontSize) private var readingFontSize = "large"
    @AppStorage(PreferenceKeys.speechSpeed) private var speechSpeed = "1.0"

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            SettingsSection(title: "글꼴 크기", description: "번역된 텍스트를 쉽게 읽을 수 있도록 원하는 글꼴 크기를 선택하세요.") {
                Text("번역문은 이렇게 표시됩니다.")
                    .font(.system(size: readingFontSize == "large" ? 28 : 22, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 128)
                    .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 5))

                Picker("글꼴 크기 변경", selection: $readingFontSize) {
                    Text("보통").tag("regular")
                    Text("크게").tag("large")
                    Text("매우 크게").tag("extraLarge")
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

            SettingsSection(title: "번역 기록", description: "번역을 자동으로 저장하여 이전 번역을 빠르게 찾고 재사용할 수 있습니다. 기록은 이 기기에 로컬로 암호화하여 저장합니다.") {
                Toggle("번역 기록 켜기", isOn: $historyEnabled)
            }
        }
    }
}

private struct AdvancedSettingsPane: View {
    @AppStorage(PreferenceKeys.provider) private var providerRaw = AppDefaults.defaultProvider.rawValue
    @AppStorage(PreferenceKeys.modelID) private var modelID = AppDefaults.defaultModelID
    @AppStorage(PreferenceKeys.geminiAPIKey) private var apiKey = AppDefaults.defaultGeminiAPIKey
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

    private var currentProvider: LLMProvider {
        LLMProvider(rawValue: providerRaw) ?? .gemini
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            SettingsSection(title: "LLM 번역 모델", description: "텍스트 번역에 사용할 모델 공급자와 세부 모델을 선택합니다.") {
                Picker("공급자", selection: providerBinding) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .frame(width: 320)

                Picker("세부 모델", selection: $modelID) {
                    ForEach(currentProvider.models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .frame(width: 320)

                SecureField("API 키", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 500)

                Toggle("입력 후 자동 번역", isOn: $autoTranslate)

                VStack(alignment: .leading, spacing: 8) {
                    Text("창의성 \(temperature, specifier: "%.1f")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $temperature, in: 0...1, step: 0.1)
                        .frame(maxWidth: 360)
                }
            }

            SettingsSection(title: "차단 목록", description: "KC DeepL 단축키를 사용하고 싶지 않은 앱을 추가합니다. + 또는 -를 클릭하여 앱을 추가하거나 제거할 수 있습니다.") {
                HStack {
                    Label("키체인 접근.app", systemImage: "app.badge")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.separator)
                )

                HStack {
                    Spacer()
                    Button {} label: {
                        Image(systemName: "plus")
                    }
                    Button {} label: {
                        Image(systemName: "minus")
                    }
                }
            }
        }
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
            }
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let description: String
    @Binding var shortcut: String
    var note: String?

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

                TextField("", text: $shortcut)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .frame(width: 180)

                Button {} label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
            }
        }
    }
}
