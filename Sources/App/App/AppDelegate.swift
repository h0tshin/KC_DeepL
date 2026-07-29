import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let globalHotKeyManager = GlobalHotKeyManager()
    private let statusItemController = AppStatusItemController()
    private var isPreparingToTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        applyApplicationIcon()
        NSApp.activate(ignoringOtherApps: true)
        _ = statusItemController
        globalHotKeyManager.start()
        LaunchAtLoginController.shared.synchronizeOnLaunch()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        LaunchAtLoginController.shared.refreshStatus()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingToTerminate else {
            return .terminateLater
        }

        isPreparingToTerminate = true
        Task { @MainActor in
            globalHotKeyManager.stop()
            await PendingPersistenceRegistry.shared.flushAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotKeyManager.stop()
    }

    private func applyApplicationIcon() {
        guard let iconURL = AppResourceLocator.url(
            forResource: "AppIcon",
            withExtension: "png"
        ),
        let icon = NSImage(contentsOf: iconURL)
        else {
            return
        }

        NSApp.applicationIconImage = icon
    }
}
