import AppKit
import ApplicationServices
import Carbon
import SwiftUI

enum AppCommandAction: String {
    case textTranslation
    case writing
    case fileTranslation
    case screenCapture

    var capturesSelectedText: Bool {
        switch self {
        case .textTranslation, .writing:
            true
        case .fileTranslation, .screenCapture:
            false
        }
    }
}

extension Notification.Name {
    static let kcDeepLPerformAction = Notification.Name("KCDeepLPerformAction")
}

struct AppCommandPayload {
    let action: AppCommandAction
    let capturedText: String?
    let statusMessage: String?
}

final class AppActionDispatcher {
    static let shared = AppActionDispatcher()

    var openMainWindow: (() -> Void)?

    private init() {}

    func perform(_ action: AppCommandAction, capturedText: String? = nil, statusMessage: String? = nil) {
        DispatchQueue.main.async {
            self.showMainWindow()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                let payload = AppCommandPayload(
                    action: action,
                    capturedText: capturedText,
                    statusMessage: statusMessage
                )
                NotificationCenter.default.post(name: .kcDeepLPerformAction, object: payload)
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

        guard action.capturesSelectedText else {
            AppActionDispatcher.shared.perform(action)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            let result = SelectedTextCaptureService.captureSelectedText()
            AppActionDispatcher.shared.perform(
                action,
                capturedText: result.text,
                statusMessage: result.statusMessage
            )
        }
    }
}

private struct SelectedTextCaptureResult {
    let text: String?
    let statusMessage: String?
}

private enum SelectedTextCaptureService {
    static func captureSelectedText() -> SelectedTextCaptureResult {
        guard isAccessibilityTrusted() else {
            return SelectedTextCaptureResult(
                text: nil,
                statusMessage: "선택 텍스트를 자동으로 가져오려면 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 KC DeepL을 허용해 주세요."
            )
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let changeCount = pasteboard.changeCount

        guard postCopyShortcut() else {
            return SelectedTextCaptureResult(
                text: nil,
                statusMessage: "선택 텍스트 복사 이벤트를 보낼 수 없습니다."
            )
        }

        let copiedText = waitForCopiedText(on: pasteboard, originalChangeCount: changeCount)
        snapshot.restore(to: pasteboard)

        guard let copiedText,
              !copiedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return SelectedTextCaptureResult(
                text: nil,
                statusMessage: "선택된 텍스트를 읽지 못했습니다. 텍스트를 블럭 지정한 뒤 다시 눌러 주세요."
            )
        }

        return SelectedTextCaptureResult(text: copiedText, statusMessage: nil)
    }

    private static func isAccessibilityTrusted() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary

        return AXIsProcessTrustedWithOptions(options)
    }

    private static func postCopyShortcut() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_C),
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_C),
                keyDown: false
              )
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.025)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func waitForCopiedText(
        on pasteboard: NSPasteboard,
        originalChangeCount: Int
    ) -> String? {
        let deadline = Date().addingTimeInterval(0.75)

        while Date() < deadline {
            if pasteboard.changeCount != originalChangeCount,
               let text = pasteboard.string(forType: .string) {
                return text
            }

            Thread.sleep(forTimeInterval: 0.035)
        }

        return nil
    }
}

private struct PasteboardSnapshot {
    let items: [NSPasteboardItem]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let copiedItems: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copiedItem = NSPasteboardItem()

            for type in item.types {
                if let data = item.data(forType: type) {
                    copiedItem.setData(data, forType: type)
                }
            }

            return copiedItem
        } ?? []

        return PasteboardSnapshot(items: copiedItems)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        guard !items.isEmpty else {
            return
        }

        pasteboard.writeObjects(items)
    }
}

private extension FourCharCode {
    init(_ string: String) {
        self = string.utf8.reduce(0) { result, character in
            (result << 8) + FourCharCode(character)
        }
    }
}
