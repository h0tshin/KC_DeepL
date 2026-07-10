import AppKit
@preconcurrency import ApplicationServices
import Carbon
import SwiftUI

enum AppCommandAction: String {
    case textTranslation
    case writing
    case fileTranslation
    case screenCapture

    var capturesSelectedText: Bool {
        switch self {
        case .textTranslation:
            true
        case .writing, .fileTranslation, .screenCapture:
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
    let capturedAttributedText: NSAttributedString?
    let statusMessage: String?
    let pasteBackTarget: PasteBackTarget?
}

@MainActor
final class AppActionDispatcher {
    static let shared = AppActionDispatcher()

    var openMainWindow: (() -> Void)?

    private init() {}

    func perform(
        _ action: AppCommandAction,
        capturedText: String? = nil,
        capturedAttributedText: NSAttributedString? = nil,
        statusMessage: String? = nil,
        pasteBackTarget: PasteBackTarget? = nil
    ) {
        showMainWindow()

        let payload = AppCommandPayload(
            action: action,
            capturedText: capturedText,
            capturedAttributedText: capturedAttributedText,
            statusMessage: statusMessage,
            pasteBackTarget: pasteBackTarget
        )
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else {
                return
            }
            NotificationCenter.default.post(name: .kcDeepLPerformAction, object: payload)
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

@MainActor
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
    private var captureTask: Task<Void, Never>?

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
        captureTask?.cancel()
        captureTask = nil
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
                Task { @MainActor in
                    manager.handleHotKey(id: hotKeyID.id)
                }
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

        guard captureTask == nil else {
            return
        }
        captureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard let self, !Task.isCancelled else {
                return
            }

            let result = await SelectedTextCaptureService.captureSelectedText()
            guard !Task.isCancelled else {
                return
            }
            AppActionDispatcher.shared.perform(
                action,
                capturedText: result.text,
                capturedAttributedText: result.attributedText,
                statusMessage: result.statusMessage,
                pasteBackTarget: result.pasteBackTarget
            )
            self.captureTask = nil
        }
    }
}

private struct SelectedTextCaptureResult {
    let text: String?
    let attributedText: NSAttributedString?
    let statusMessage: String?
    let pasteBackTarget: PasteBackTarget?
}

@MainActor
private enum SelectedTextCaptureService {
    static func captureSelectedText() async -> SelectedTextCaptureResult {
        guard isAccessibilityTrusted() else {
            return SelectedTextCaptureResult(
                text: nil,
                attributedText: nil,
                statusMessage: "선택 텍스트를 자동으로 가져오려면 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 KC DeepL을 허용해 주세요.",
                pasteBackTarget: nil
            )
        }

        guard PasteboardTransactionCoordinator.shared.begin() else {
            return SelectedTextCaptureResult(
                text: nil,
                attributedText: nil,
                statusMessage: "다른 클립보드 작업이 진행 중입니다. 잠시 후 다시 시도해 주세요.",
                pasteBackTarget: nil
            )
        }
        defer {
            PasteboardTransactionCoordinator.shared.end()
        }

        let pasteBackTarget = PasteBackTarget.captureCurrentFocusIfInputCapable()
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let changeCount = pasteboard.changeCount
        var ownedChangeCount: Int?

        defer {
            if let ownedChangeCount,
               pasteboard.changeCount == ownedChangeCount {
                snapshot.restore(to: pasteboard)
            }
        }

        guard await postCopyShortcut() else {
            return SelectedTextCaptureResult(
                text: nil,
                attributedText: nil,
                statusMessage: "선택 텍스트 복사 이벤트를 보낼 수 없습니다.",
                pasteBackTarget: nil
            )
        }

        guard let copyResult = await PasteboardPolling.waitForCopiedText(
            on: pasteboard,
            originalChangeCount: changeCount
        ) else {
            return SelectedTextCaptureResult(
                text: nil,
                attributedText: nil,
                statusMessage: "선택된 텍스트를 읽지 못했습니다. 텍스트를 블럭 지정한 뒤 다시 눌러 주세요.",
                pasteBackTarget: nil
            )
        }

        guard pasteboard.changeCount == copyResult.changeCount else {
            return SelectedTextCaptureResult(
                text: nil,
                attributedText: nil,
                statusMessage: "복사 중 클립보드가 변경되어 작업을 취소했습니다.",
                pasteBackTarget: nil
            )
        }
        ownedChangeCount = copyResult.changeCount

        let copiedAttributedText = RichTextFormatting.attributedString(from: pasteboard)
        guard pasteboard.changeCount == copyResult.changeCount else {
            return SelectedTextCaptureResult(
                text: nil,
                attributedText: nil,
                statusMessage: "복사 중 클립보드가 변경되어 작업을 취소했습니다.",
                pasteBackTarget: nil
            )
        }

        guard let copiedText = copyResult.text,
              !copiedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return SelectedTextCaptureResult(
                text: nil,
                attributedText: nil,
                statusMessage: "선택된 텍스트를 읽지 못했습니다. 텍스트를 블럭 지정한 뒤 다시 눌러 주세요.",
                pasteBackTarget: nil
            )
        }

        return SelectedTextCaptureResult(
            text: copiedText,
            attributedText: copiedAttributedText,
            statusMessage: nil,
            pasteBackTarget: pasteBackTarget
        )
    }

    private static func isAccessibilityTrusted() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary

        return AXIsProcessTrustedWithOptions(options)
    }

    private static func postCopyShortcut() async -> Bool {
        await KeyboardShortcutPoster.postCommandKey(CGKeyCode(kVK_ANSI_C))
    }
}

@MainActor
final class PasteBackTarget {
    private let processIdentifier: pid_t
    private let focusedElement: AXUIElement
    private let appName: String

    private init(processIdentifier: pid_t, focusedElement: AXUIElement, appName: String) {
        self.processIdentifier = processIdentifier
        self.focusedElement = focusedElement
        self.appName = appName
    }

    static func captureCurrentFocusIfInputCapable() -> PasteBackTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let focusedElement = focusedElement(for: app),
              isInputCapable(focusedElement)
        else {
            return nil
        }

        return PasteBackTarget(
            processIdentifier: app.processIdentifier,
            focusedElement: focusedElement,
            appName: app.localizedName ?? "이전 앱"
        )
    }

    func paste(_ text: String) async -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "붙여넣을 번역 결과가 없습니다."
        }

        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            return "\(appName)을 다시 찾을 수 없습니다."
        }

        guard PasteboardTransactionCoordinator.shared.begin() else {
            return "다른 붙여넣기 작업이 진행 중입니다. 잠시 후 다시 시도해 주세요."
        }
        defer {
            PasteboardTransactionCoordinator.shared.end()
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        RichTextFormatting.writeMarkdown(text, to: pasteboard)
        let temporaryChangeCount = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == temporaryChangeCount {
                snapshot.restore(to: pasteboard)
            }
        }

        guard app.activate() else {
            return "\(appName)을 활성화할 수 없습니다."
        }
        _ = AXUIElementSetAttributeValue(
            focusedElement,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        try? await Task.sleep(for: .milliseconds(120))

        guard pasteboard.changeCount == temporaryChangeCount else {
            return "클립보드가 변경되어 붙여넣기를 취소했습니다."
        }

        if await KeyboardShortcutPoster.postCommandKey(CGKeyCode(kVK_ANSI_V)) {
            try? await Task.sleep(for: .milliseconds(450))
            return "\(appName)에 번역 결과를 붙여넣었습니다."
        }

        return "\(appName)에 붙여넣기 이벤트를 보낼 수 없습니다."
    }

    private static func focusedElement(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )

        guard error == .success else {
            return nil
        }

        guard let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func isInputCapable(_ element: AXUIElement) -> Bool {
        if let role = stringAttribute(kAXRoleAttribute, from: element),
           ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) {
            return true
        }

        if let subrole = stringAttribute(kAXSubroleAttribute, from: element),
           subrole == "AXSecureTextField" {
            return true
        }

        var isSettable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        )

        return error == .success && isSettable.boolValue
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            return nil
        }

        return value as? String
    }
}

@MainActor
private final class PasteboardTransactionCoordinator {
    static let shared = PasteboardTransactionCoordinator()

    private var isBusy = false

    private init() {}

    func begin() -> Bool {
        guard !isBusy else {
            return false
        }
        isBusy = true
        return true
    }

    func end() {
        isBusy = false
    }
}

@MainActor
private enum KeyboardShortcutPoster {
    static func postCommandKey(_ keyCode: CGKeyCode) async -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: false
              )
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(25))
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

private struct PasteboardCopyResult {
    let text: String?
    let changeCount: Int
}

@MainActor
private enum PasteboardPolling {
    static func waitForCopiedText(
        on pasteboard: NSPasteboard,
        originalChangeCount: Int
    ) async -> PasteboardCopyResult? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(750))

        while clock.now < deadline, !Task.isCancelled {
            if pasteboard.changeCount != originalChangeCount {
                return PasteboardCopyResult(
                    text: pasteboard.string(forType: .string),
                    changeCount: pasteboard.changeCount
                )
            }

            try? await Task.sleep(for: .milliseconds(35))
        }

        guard pasteboard.changeCount != originalChangeCount else {
            return nil
        }
        return PasteboardCopyResult(
            text: pasteboard.string(forType: .string),
            changeCount: pasteboard.changeCount
        )
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
