import AppKit

@MainActor
final class AppStatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
        super.init()
        configureButton()
        configureMenu()
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

        menu.addItem(actionItem(
            title: "텍스트 번역",
            keyEquivalent: "1",
            modifiers: [.control, .shift],
            action: #selector(performTextTranslation)
        ))

        menu.addItem(actionItem(
            title: "Live 번역",
            keyEquivalent: "2",
            modifiers: [.control, .shift],
            action: #selector(performWriting)
        ))

        menu.addItem(actionItem(
            title: "파일 번역",
            keyEquivalent: "",
            modifiers: [],
            action: #selector(performFileTranslation)
        ))

        menu.addItem(actionItem(
            title: "화면 캡처",
            keyEquivalent: "3",
            modifiers: [.control, .shift],
            action: #selector(performScreenCapture)
        ))

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

        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        if let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        return nil
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
