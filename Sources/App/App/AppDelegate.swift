import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let globalHotKeyManager = GlobalHotKeyManager()
    private let statusItemController = AppStatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        _ = statusItemController
        globalHotKeyManager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotKeyManager.stop()
    }
}
