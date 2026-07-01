import AppKit
import Carbon
import SwiftUI

enum AppCommandAction: String {
    case textTranslation
    case writing
    case fileTranslation
    case screenCapture
}

extension Notification.Name {
    static let kcDeepLPerformAction = Notification.Name("KCDeepLPerformAction")
}

final class AppActionDispatcher {
    static let shared = AppActionDispatcher()

    var openMainWindow: (() -> Void)?

    private init() {}

    func perform(_ action: AppCommandAction) {
        DispatchQueue.main.async {
            self.showMainWindow()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                NotificationCenter.default.post(name: .kcDeepLPerformAction, object: action)
            }
        }
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.title == "KC DeepL" }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}

struct AppCommandBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let openWindow = openWindow
                AppActionDispatcher.shared.openMainWindow = {
                    openWindow(id: "main")
                }
            }
    }
}

final class GlobalHotKeyManager {
    private struct HotKeyRegistration {
        let action: AppCommandAction
        let keyCode: UInt32
        let id: UInt32
    }

    private let signature = FourCharCode("KCDL")
    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: AppCommandAction] = [:]
    private var isRunning = false

    private let registrations: [HotKeyRegistration] = [
        HotKeyRegistration(action: .textTranslation, keyCode: UInt32(kVK_ANSI_1), id: 1),
        HotKeyRegistration(action: .writing, keyCode: UInt32(kVK_ANSI_2), id: 2),
        HotKeyRegistration(action: .screenCapture, keyCode: UInt32(kVK_ANSI_3), id: 3)
    ]

    func start() {
        guard !isRunning else {
            return
        }

        installEventHandler()
        registerHotKeys()
        isRunning = true
    }

    func stop() {
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        actionsByID.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }

        isRunning = false
    }

    deinit {
        stop()
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard parameterStatus == noErr else {
                    return parameterStatus
                }

                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                manager.handleHotKey(id: hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandler
        )

        if status != noErr {
            NSLog("KCDeepL failed to install global hotkey handler: \(status)")
        }
    }

    private func registerHotKeys() {
        let modifiers = UInt32(controlKey | shiftKey)

        for registration in registrations {
            let hotKeyID = EventHotKeyID(signature: signature, id: registration.id)
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                registration.keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            if status == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
                actionsByID[registration.id] = registration.action
            } else {
                NSLog("KCDeepL failed to register global hotkey \(registration.id): \(status)")
            }
        }
    }

    private func handleHotKey(id: UInt32) {
        guard let action = actionsByID[id] else {
            return
        }

        AppActionDispatcher.shared.perform(action)
    }
}

private extension FourCharCode {
    init(_ string: String) {
        self = string.utf8.reduce(0) { result, character in
            (result << 8) + FourCharCode(character)
        }
    }
}
