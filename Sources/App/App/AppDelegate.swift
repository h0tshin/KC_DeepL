import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let globalHotKeyManager = GlobalHotKeyManager()
    private let statusItemController = AppStatusItemController()
    private var isPreparingToTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        _ = statusItemController
        globalHotKeyManager.start()
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
}
