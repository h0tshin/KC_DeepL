import AppKit

@MainActor
final class AppStatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var shortcutItems: [AppCommandAction: NSMenuItem] = [:]

    override init() {
        super.init()
        configureButton()
        configureMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            return
        }

        if let image = loadMenuBarImage() {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = "KC"
            button.font = .systemFont(ofSize: 11, weight: .bold)
        }

        button.toolTip = "KC DeepL"
        button.setAccessibilityLabel("KC DeepL")
    }

    private func configureMenu() {
        let menu = NSMenu()

        let textTranslationItem = actionItem(
            title: "텍스트 번역",
            keyEquivalent: "",
            modifiers: [],
            action: #selector(performTextTranslation)
        )
        shortcutItems[.textTranslation] = textTranslationItem
        menu.addItem(textTranslationItem)

        let liveTranslationItem = actionItem(
            title: "Live 번역",
            keyEquivalent: "",
            modifiers: [],
            action: #selector(performWriting)
        )
        shortcutItems[.writing] = liveTranslationItem
        menu.addItem(liveTranslationItem)

        menu.addItem(actionItem(
            title: "파일 번역",
            keyEquivalent: "",
            modifiers: [],
            action: #selector(performFileTranslation)
        ))

        let screenCaptureItem = actionItem(
            title: "화면 캡처",
            keyEquivalent: "",
            modifiers: [],
            action: #selector(performScreenCapture)
        )
        shortcutItems[.screenCapture] = screenCaptureItem
        menu.addItem(screenCaptureItem)

        menu.addItem(.separator())

        menu.addItem(actionItem(
            title: "환경설정...",
            keyEquivalent: ",",
            modifiers: [.command],
            action: #selector(showSettings)
        ))

        menu.addItem(actionItem(
            title: "KC DeepL 종료",
            keyEquivalent: "q",
            modifiers: [.command],
            action: #selector(quit)
        ))

        statusItem.menu = menu
        refreshShortcutItems()
    }

    private func actionItem(
        title: String,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func loadMenuBarImage() -> NSImage? {
        if let image = NSImage(named: "MenuBarIcon") {
            return image
        }

        if let url = AppResourceLocator.url(
            forResource: "MenuBarIcon",
            withExtension: "png"
        ),
           let image = NSImage(contentsOf: url) {
            return image
        }

        return nil
    }

    @objc private func preferencesDidChange() {
        refreshShortcutItems()
    }

    private func refreshShortcutItems() {
        for definition in AppShortcutDefinition.all {
            guard let item = shortcutItems[definition.action] else {
                continue
            }
            let descriptor = definition.descriptor()
            item.keyEquivalent = descriptor.keyEquivalent
            item.keyEquivalentModifierMask = descriptor.modifiers
        }
    }

    @objc private func performTextTranslation() {
        AppActionDispatcher.shared.perform(.textTranslation)
    }

    @objc private func performWriting() {
        AppActionDispatcher.shared.perform(.writing)
    }

    @objc private func performFileTranslation() {
        AppActionDispatcher.shared.perform(.fileTranslation)
    }

    @objc private func performScreenCapture() {
        AppActionDispatcher.shared.perform(.screenCapture)
    }

    @objc private func showSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let showSettingsSelector = Selector(("showSettingsWindow:"))
        if !NSApp.sendAction(showSettingsSelector, to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
