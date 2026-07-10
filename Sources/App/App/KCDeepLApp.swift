import SwiftUI
import KCDeepLCore

@main
struct KCDeepLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var translationViewModel: TranslationViewModel
    @StateObject private var liveTranslationViewModel: LiveTranslationViewModel

    init() {
        UserDefaults.standard.registerKCDeepLDefaults()
        _translationViewModel = StateObject(wrappedValue: TranslationViewModel())
        _liveTranslationViewModel = StateObject(wrappedValue: LiveTranslationViewModel())
    }

    var body: some Scene {
        WindowGroup("KC DeepL", id: "main") {
            ContentView(
                viewModel: translationViewModel,
                liveTranslationViewModel: liveTranslationViewModel
            )
                .frame(minWidth: 980, minHeight: 600)
                .background(AppCommandBridge())
                .preferredColorScheme(.dark)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("KC DeepL") {
                Button("텍스트 번역") {
                    AppActionDispatcher.shared.perform(.textTranslation)
                }
                .keyboardShortcut("1", modifiers: [.control, .shift])

                Button("Live 번역") {
                    AppActionDispatcher.shared.perform(.writing)
                }
                .keyboardShortcut("2", modifiers: [.control, .shift])

                Button("화면 캡처") {
                    AppActionDispatcher.shared.perform(.screenCapture)
                }
                .keyboardShortcut("3", modifiers: [.control, .shift])
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }
}
