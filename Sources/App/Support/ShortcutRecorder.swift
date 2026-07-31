import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: String
    let unavailableShortcuts: Set<String>
    let onValidationError: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shortcut: $shortcut,
            unavailableShortcuts: unavailableShortcuts,
            onValidationError: onValidationError
        )
    }

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        let control = ShortcutRecorderControl()
        control.shortcut = shortcut
        control.onKeyEvent = context.coordinator.handleKeyEvent
        return control
    }

    func updateNSView(_ control: ShortcutRecorderControl, context: Context) {
        context.coordinator.shortcut = $shortcut
        context.coordinator.unavailableShortcuts = unavailableShortcuts
        context.coordinator.onValidationError = onValidationError
        control.shortcut = shortcut
        control.onKeyEvent = context.coordinator.handleKeyEvent
    }

    final class Coordinator {
        var shortcut: Binding<String>
        var unavailableShortcuts: Set<String>
        var onValidationError: (String?) -> Void

        init(
            shortcut: Binding<String>,
            unavailableShortcuts: Set<String>,
            onValidationError: @escaping (String?) -> Void
        ) {
            self.shortcut = shortcut
            self.unavailableShortcuts = unavailableShortcuts
            self.onValidationError = onValidationError
        }

        func handleKeyEvent(_ event: NSEvent) -> ShortcutRecorderControl.KeyEventResult {
            let modifiers = event.modifierFlags.intersection([
                .command,
                .option,
                .control,
                .shift
            ])

            if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
                onValidationError(nil)
                return .cancelled
            }

            guard let descriptor = AppShortcutDescriptor.capture(
                keyCode: event.keyCode,
                modifiers: modifiers
            ) else {
                onValidationError("⌘, ⌥ 또는 ⌃와 일반 키를 함께 눌러 주세요.")
                NSSound.beep()
                return .rejected
            }

            guard !unavailableShortcuts.contains(descriptor.displayString) else {
                onValidationError("이미 다른 기능에서 사용 중인 단축키입니다.")
                NSSound.beep()
                return .rejected
            }

            shortcut.wrappedValue = descriptor.displayString
            onValidationError(nil)
            return .accepted(descriptor.displayString)
        }
    }
}

final class ShortcutRecorderControl: NSView {
    enum KeyEventResult {
        case accepted(String)
        case cancelled
        case rejected
    }

    var shortcut = "" {
        didSet {
            if oldValue != shortcut {
                needsDisplay = true
                invalidateIntrinsicContentSize()
            }
        }
    }

    var onKeyEvent: ((NSEvent) -> KeyEventResult)?
    private var isRecording = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 180, height: 32)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch onKeyEvent?(event) {
        case .accepted(let value):
            shortcut = value
            window?.makeFirstResponder(nil)
        case .cancelled:
            window?.makeFirstResponder(nil)
        case .rejected, .none:
            break
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else {
            return false
        }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let controlRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: controlRect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()

        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text = isRecording ? "새 단축키 입력…" : shortcut
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppFont.monospacedFont(size: 14, weight: .semibold),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        let textRect = NSRect(
            x: 8,
            y: (bounds.height - 18) / 2,
            width: bounds.width - 16,
            height: 18
        )
        text.draw(in: textRect, withAttributes: attributes)
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.textField)
        setAccessibilityLabel("키보드 단축키")
        setAccessibilityHelp("클릭한 다음 새로운 키 조합을 누르세요. Esc를 누르면 취소됩니다.")
    }
}
