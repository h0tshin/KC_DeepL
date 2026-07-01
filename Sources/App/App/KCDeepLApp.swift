import AppKit
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

        MenuBarExtra {
            MenuBarActionsView()
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .accessibilityLabel("KC DeepL")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarActionsView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("텍스트 번역") {
            perform(.textTranslation)
        }
        .keyboardShortcut("1", modifiers: [.control, .shift])

        Button("글쓰기") {
            perform(.writing)
        }
        .keyboardShortcut("2", modifiers: [.control, .shift])

        Button("파일 번역") {
            perform(.fileTranslation)
        }

        Button("화면 캡처") {
            perform(.screenCapture)
        }
        .keyboardShortcut("3", modifiers: [.control, .shift])

        Divider()

        SettingsLink {
            Text("환경설정...")
        }

        Button("KC DeepL 종료") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
        .onAppear {
            let openWindow = openWindow
            AppActionDispatcher.shared.openMainWindow = {
                openWindow(id: "main")
            }
        }
    }

    private func perform(_ action: AppCommandAction) {
        AppActionDispatcher.shared.perform(action)
    }
}
