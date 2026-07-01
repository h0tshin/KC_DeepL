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
        }
        .commands {
            CommandMenu("KC DeepL") {
                Button("선택한 텍스트 번역") {}
                    .keyboardShortcut("1", modifiers: [.command, .shift])

                Button("텍스트 화면 캡처") {}
                    .keyboardShortcut("2", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
