import SwiftUI
import KCDeepLCore

@main
struct KCDeepLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var translationViewModel: TranslationViewModel
    @StateObject private var translationComparisonViewModel: TranslationComparisonViewModel
    @StateObject private var liveTranslationViewModel: LiveTranslationViewModel
    @StateObject private var fileTranslationViewModel: FileTranslationViewModel
    @StateObject private var documentConversionViewModel: DocumentConversionViewModel
    private let codexAppServerClient: CodexAppServerClient

    init() {
        // Process-scoped registration keeps the bundled typography available
        // to SwiftUI, AppKit editors, and PDFKit without installing user fonts.
        _ = AppFontRegistry.registerBundledFonts()
        UserDefaults.standard.registerKCDeepLDefaults()
        let codexAppServerClient = CodexAppServerClient()
        self.codexAppServerClient = codexAppServerClient
        let workspaceOperationGate = FileWorkspaceOperationGate()
        _translationViewModel = StateObject(
            wrappedValue: TranslationViewModel(
                appServerClient: codexAppServerClient
            )
        )
        _translationComparisonViewModel = StateObject(
            wrappedValue: TranslationComparisonViewModel(
                client: codexAppServerClient,
                modelProvider: codexAppServerClient
            )
        )
        _liveTranslationViewModel = StateObject(wrappedValue: LiveTranslationViewModel())
        _fileTranslationViewModel = StateObject(
            wrappedValue: FileTranslationViewModel(
                appServerClient: codexAppServerClient,
                codexModelProvider: codexAppServerClient,
                operationGate: workspaceOperationGate
            )
        )
        let documentConversionViewModel = DocumentConversionViewModel(
            operationGate: workspaceOperationGate
        )
        _documentConversionViewModel = StateObject(
            wrappedValue: documentConversionViewModel
        )
        PendingPersistenceRegistry.shared.registerPreparation { [weak documentConversionViewModel] in
            documentConversionViewModel?.prepareForApplicationTermination()
        }
        PendingPersistenceRegistry.shared.register { [weak documentConversionViewModel] in
            await documentConversionViewModel?.shutdownAndReapWorker()
        }
        PendingPersistenceRegistry.shared.register {
            await codexAppServerClient.shutdown()
        }
    }

    var body: some Scene {
        // KC DeepL is a single-workspace utility. A singleton Window scene is
        // important here because PopClip delivers an external URL; a
        // WindowGroup may create a new scene for each URL before onOpenURL is
        // called, while Window routes the request to the existing workspace.
        Window("KC DeepL", id: "main") {
            ContentView(
                viewModel: translationViewModel,
                comparisonViewModel: translationComparisonViewModel,
                liveTranslationViewModel: liveTranslationViewModel,
                fileTranslationViewModel: fileTranslationViewModel,
                documentConversionViewModel: documentConversionViewModel
            )
                .frame(minWidth: 980, minHeight: 600)
                .font(AppFont.swiftUIFont(size: 13))
                .background(AppCommandBridge())
                .preferredColorScheme(.dark)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            KCDeepLShortcutCommands()
        }

        Settings {
            SettingsView(codexClient: codexAppServerClient)
                .font(AppFont.swiftUIFont(size: 13))
                .preferredColorScheme(.dark)
        }
    }
}

private struct KCDeepLShortcutCommands: Commands {
    @AppStorage(PreferenceKeys.selectedTextShortcut)
    private var selectedTextShortcut = AppShortcutDefinition.textTranslation.defaultValue
    @AppStorage(PreferenceKeys.rewriteShortcut)
    private var liveTranslationShortcut = AppShortcutDefinition.liveTranslation.defaultValue
    @AppStorage(PreferenceKeys.screenCaptureShortcut)
    private var screenCaptureShortcut = AppShortcutDefinition.screenCapture.defaultValue

    var body: some Commands {
        CommandMenu("KC DeepL") {
            shortcutButton(
                title: "텍스트 번역",
                action: .textTranslation,
                storedValue: selectedTextShortcut,
                definition: .textTranslation
            )
            shortcutButton(
                title: "Live 번역",
                action: .writing,
                storedValue: liveTranslationShortcut,
                definition: .liveTranslation
            )
            shortcutButton(
                title: "화면 캡처",
                action: .screenCapture,
                storedValue: screenCaptureShortcut,
                definition: .screenCapture
            )
        }
    }

    @ViewBuilder
    private func shortcutButton(
        title: String,
        action: AppCommandAction,
        storedValue: String,
        definition: AppShortcutDefinition
    ) -> some View {
        let descriptor = AppShortcutDescriptor.parse(storedValue) ?? definition.descriptor()

        if let character = descriptor.keyEquivalentCharacter {
            Button(title) {
                AppActionDispatcher.shared.perform(action)
            }
            .keyboardShortcut(
                KeyEquivalent(character),
                modifiers: descriptor.swiftUIModifiers
            )
        } else {
            Button(title) {
                AppActionDispatcher.shared.perform(action)
            }
        }
    }
}
