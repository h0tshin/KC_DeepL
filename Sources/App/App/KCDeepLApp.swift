import SwiftUI
import KCDeepLCore

@main
struct KCDeepLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        UserDefaults.standard.registerKCDeepLDefaults()
    }

    var body: some Scene {
        WindowGroup("KC DeepL", id: "main") {
            ContentView()
                .frame(minWidth: 980, minHeight: 600)
                .background(AppCommandBridge())
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandMenu("KC DeepL") {
                Button("텍스트 번역") {
                    AppActionDispatcher.shared.perform(.textTranslation)
                }
                .keyboardShortcut("1", modifiers: [.control, .shift])

                Button("글쓰기") {
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
        }
    }
}
