import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let globalHotKeyManager = GlobalHotKeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        globalHotKeyManager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotKeyManager.stop()
    }
}
