import AppKit
import Carbon
import KCDeepLCore
import SwiftUI

struct AppShortcutDescriptor: Equatable {
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags
    let keyEquivalent: String
    let keyName: String

    var displayString: String {
        Self.modifierDisplayOrder.compactMap { modifier, symbol in
            modifiers.contains(modifier) ? symbol : nil
        }.joined() + keyName
    }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) {
            value |= UInt32(cmdKey)
        }
        if modifiers.contains(.option) {
            value |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            value |= UInt32(controlKey)
        }
        if modifiers.contains(.shift) {
            value |= UInt32(shiftKey)
        }
        return value
    }

    var swiftUIModifiers: SwiftUI.EventModifiers {
        var value: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) {
            value.insert(.command)
        }
        if modifiers.contains(.option) {
            value.insert(.option)
        }
        if modifiers.contains(.control) {
            value.insert(.control)
        }
        if modifiers.contains(.shift) {
            value.insert(.shift)
        }
        return value
    }

    var keyEquivalentCharacter: Character? {
        keyEquivalent.first
    }

    static func parse(_ value: String) -> AppShortcutDescriptor? {
        let compactValue = value.filter { !$0.isWhitespace }
        guard !compactValue.isEmpty else {
            return nil
        }

        var modifiers: NSEvent.ModifierFlags = []
        var keyName = compactValue

        for (modifier, symbol) in modifierDisplayOrder {
            if keyName.contains(symbol) {
                modifiers.insert(modifier)
                keyName = keyName.replacingOccurrences(of: symbol, with: "")
            }
        }

        guard isSafeGlobalShortcut(modifiers: modifiers),
              let key = keyByName[keyName.uppercased()]
        else {
            return nil
        }

        return AppShortcutDescriptor(
            keyCode: key.keyCode,
            modifiers: modifiers,
            keyEquivalent: key.keyEquivalent,
            keyName: key.name
        )
    }

    static func capture(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> AppShortcutDescriptor? {
        let normalizedModifiers = modifiers.intersection(supportedModifiers)
        guard isSafeGlobalShortcut(modifiers: normalizedModifiers),
              let key = keyByCode[UInt32(keyCode)]
        else {
            return nil
        }

        return AppShortcutDescriptor(
            keyCode: key.keyCode,
            modifiers: normalizedModifiers,
            keyEquivalent: key.keyEquivalent,
            keyName: key.name
        )
    }

    static func resolved(
        preferenceKey: String,
        defaultValue: String,
        defaults: UserDefaults = .standard
    ) -> AppShortcutDescriptor {
        if let storedValue = defaults.string(forKey: preferenceKey),
           let descriptor = parse(storedValue) {
            return descriptor
        }

        guard let fallback = parse(defaultValue) else {
            preconditionFailure("Invalid built-in shortcut: \(defaultValue)")
        }
        return fallback
    }

    private struct ShortcutKey {
        let keyCode: UInt32
        let name: String
        let keyEquivalent: String
    }

    private static let supportedModifiers: NSEvent.ModifierFlags = [
        .command,
        .option,
        .control,
        .shift
    ]

    private static let modifierDisplayOrder: [(NSEvent.ModifierFlags, String)] = [
        (.control, "⌃"),
        (.option, "⌥"),
        (.shift, "⇧"),
        (.command, "⌘")
    ]

    private static let keys: [ShortcutKey] = {
        var keys: [ShortcutKey] = [
            ShortcutKey(keyCode: UInt32(kVK_ANSI_0), name: "0", keyEquivalent: "0"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_1), name: "1", keyEquivalent: "1"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_2), name: "2", keyEquivalent: "2"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_3), name: "3", keyEquivalent: "3"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_4), name: "4", keyEquivalent: "4"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_5), name: "5", keyEquivalent: "5"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_6), name: "6", keyEquivalent: "6"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_7), name: "7", keyEquivalent: "7"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_8), name: "8", keyEquivalent: "8"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_9), name: "9", keyEquivalent: "9"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_A), name: "A", keyEquivalent: "a"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_B), name: "B", keyEquivalent: "b"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_C), name: "C", keyEquivalent: "c"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_D), name: "D", keyEquivalent: "d"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_E), name: "E", keyEquivalent: "e"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_F), name: "F", keyEquivalent: "f"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_G), name: "G", keyEquivalent: "g"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_H), name: "H", keyEquivalent: "h"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_I), name: "I", keyEquivalent: "i"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_J), name: "J", keyEquivalent: "j"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_K), name: "K", keyEquivalent: "k"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_L), name: "L", keyEquivalent: "l"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_M), name: "M", keyEquivalent: "m"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_N), name: "N", keyEquivalent: "n"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_O), name: "O", keyEquivalent: "o"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_P), name: "P", keyEquivalent: "p"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_Q), name: "Q", keyEquivalent: "q"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_R), name: "R", keyEquivalent: "r"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_S), name: "S", keyEquivalent: "s"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_T), name: "T", keyEquivalent: "t"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_U), name: "U", keyEquivalent: "u"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_V), name: "V", keyEquivalent: "v"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_W), name: "W", keyEquivalent: "w"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_X), name: "X", keyEquivalent: "x"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_Y), name: "Y", keyEquivalent: "y"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_Z), name: "Z", keyEquivalent: "z"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_Minus), name: "-", keyEquivalent: "-"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_Equal), name: "=", keyEquivalent: "="),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_LeftBracket), name: "[", keyEquivalent: "["),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_RightBracket), name: "]", keyEquivalent: "]"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_Backslash), name: "\\", keyEquivalent: "\\"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_Semicolon), name: ";", keyEquivalent: ";"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_Quote), name: "'", keyEquivalent: "'"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_Comma), name: ",", keyEquivalent: ","),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_Period), name: ".", keyEquivalent: "."),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_Slash), name: "/", keyEquivalent: "/"),
            ShortcutKey(keyCode: UInt32(kVK_ANSI_Grave), name: "`", keyEquivalent: "`"),
            ShortcutKey(keyCode: UInt32(kVK_Space), name: "Space", keyEquivalent: " "),
            ShortcutKey(keyCode: UInt32(kVK_Return), name: "Return", keyEquivalent: "\r"),
            ShortcutKey(keyCode: UInt32(kVK_Tab), name: "Tab", keyEquivalent: "\t"),
            ShortcutKey(keyCode: UInt32(kVK_Escape), name: "Esc", keyEquivalent: "\u{1B}"),
            ShortcutKey(keyCode: UInt32(kVK_Delete), name: "Delete", keyEquivalent: "\u{8}"),
            ShortcutKey(
                keyCode: UInt32(kVK_ForwardDelete),
                name: "ForwardDelete",
                keyEquivalent: functionKey(NSDeleteFunctionKey)
            ),
            ShortcutKey(
                keyCode: UInt32(kVK_LeftArrow),
                name: "←",
                keyEquivalent: functionKey(NSLeftArrowFunctionKey)
            ),
            ShortcutKey(
                keyCode: UInt32(kVK_RightArrow),
                name: "→",
                keyEquivalent: functionKey(NSRightArrowFunctionKey)
            ),
            ShortcutKey(
                keyCode: UInt32(kVK_UpArrow),
                name: "↑",
                keyEquivalent: functionKey(NSUpArrowFunctionKey)
            ),
            ShortcutKey(
                keyCode: UInt32(kVK_DownArrow),
                name: "↓",
                keyEquivalent: functionKey(NSDownArrowFunctionKey)
            ),
            ShortcutKey(
                keyCode: UInt32(kVK_Home),
                name: "Home",
                keyEquivalent: functionKey(NSHomeFunctionKey)
            ),
            ShortcutKey(
                keyCode: UInt32(kVK_End),
                name: "End",
                keyEquivalent: functionKey(NSEndFunctionKey)
            ),
            ShortcutKey(
                keyCode: UInt32(kVK_PageUp),
                name: "PageUp",
                keyEquivalent: functionKey(NSPageUpFunctionKey)
            ),
            ShortcutKey(
                keyCode: UInt32(kVK_PageDown),
                name: "PageDown",
                keyEquivalent: functionKey(NSPageDownFunctionKey)
            )
        ]

        let functionKeys: [(Int, Int)] = [
            (kVK_F1, NSF1FunctionKey),
            (kVK_F2, NSF2FunctionKey),
            (kVK_F3, NSF3FunctionKey),
            (kVK_F4, NSF4FunctionKey),
            (kVK_F5, NSF5FunctionKey),
            (kVK_F6, NSF6FunctionKey),
            (kVK_F7, NSF7FunctionKey),
            (kVK_F8, NSF8FunctionKey),
            (kVK_F9, NSF9FunctionKey),
            (kVK_F10, NSF10FunctionKey),
            (kVK_F11, NSF11FunctionKey),
            (kVK_F12, NSF12FunctionKey),
            (kVK_F13, NSF13FunctionKey),
            (kVK_F14, NSF14FunctionKey),
            (kVK_F15, NSF15FunctionKey),
            (kVK_F16, NSF16FunctionKey),
            (kVK_F17, NSF17FunctionKey),
            (kVK_F18, NSF18FunctionKey),
            (kVK_F19, NSF19FunctionKey),
            (kVK_F20, NSF20FunctionKey)
        ]
        keys.append(contentsOf: functionKeys.enumerated().map { index, values in
            ShortcutKey(
                keyCode: UInt32(values.0),
                name: "F\(index + 1)",
                keyEquivalent: functionKey(values.1)
            )
        })
        return keys
    }()

    private static let keyByName = Dictionary(
        uniqueKeysWithValues: keys.map { ($0.name.uppercased(), $0) }
    )

    private static let keyByCode = Dictionary(
        uniqueKeysWithValues: keys.map { ($0.keyCode, $0) }
    )

    private static func isSafeGlobalShortcut(modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    private static func functionKey(_ value: Int) -> String {
        guard let scalar = UnicodeScalar(value) else {
            preconditionFailure("Invalid function-key scalar: \(value)")
        }
        return String(Character(scalar))
    }
}

struct AppShortcutDefinition: Hashable {
    let action: AppCommandAction
    let preferenceKey: String
    let defaultValue: String
    let hotKeyID: UInt32

    func descriptor(defaults: UserDefaults = .standard) -> AppShortcutDescriptor {
        AppShortcutDescriptor.resolved(
            preferenceKey: preferenceKey,
            defaultValue: defaultValue,
            defaults: defaults
        )
    }

    static let textTranslation = AppShortcutDefinition(
        action: .textTranslation,
        preferenceKey: PreferenceKeys.selectedTextShortcut,
        defaultValue: "⌃⇧1",
        hotKeyID: 1
    )

    static let liveTranslation = AppShortcutDefinition(
        action: .writing,
        preferenceKey: PreferenceKeys.rewriteShortcut,
        defaultValue: "⌃⇧2",
        hotKeyID: 2
    )

    static let all: [AppShortcutDefinition] = [
        .textTranslation,
        .liveTranslation
    ]
}
