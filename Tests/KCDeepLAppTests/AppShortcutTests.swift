import AppKit
import Carbon
import Foundation
import KCDeepLCore
import XCTest
@testable import KCDeepL

final class AppShortcutTests: XCTestCase {
    func testParserNormalizesModifierOrderAndResolvesKeyCode() throws {
        let shortcut = try XCTUnwrap(AppShortcutDescriptor.parse("⇧⌃4"))

        XCTAssertEqual(shortcut.displayString, "⌃⇧4")
        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_4))
        XCTAssertEqual(shortcut.modifiers, [.control, .shift])
        XCTAssertEqual(
            shortcut.carbonModifiers,
            UInt32(controlKey | shiftKey)
        )
    }

    func testParserRejectsUnsafeModifierlessAndShiftOnlyShortcuts() {
        XCTAssertNil(AppShortcutDescriptor.parse("A"))
        XCTAssertNil(AppShortcutDescriptor.parse("⇧A"))
        XCTAssertNil(AppShortcutDescriptor.parse("⌃"))
    }

    func testCaptureProducesCanonicalDisplayValue() throws {
        let shortcut = try XCTUnwrap(
            AppShortcutDescriptor.capture(
                keyCode: UInt16(kVK_ANSI_K),
                modifiers: [.shift, .command, .capsLock]
            )
        )

        XCTAssertEqual(shortcut.displayString, "⇧⌘K")
        XCTAssertEqual(shortcut.modifiers, [.shift, .command])
        XCTAssertEqual(shortcut.keyEquivalent, "k")
    }

    func testResolverReadsChangedPreferenceInsteadOfBuiltInDefault() throws {
        let suiteName = "AppShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("⌥⌘M", forKey: PreferenceKeys.selectedTextShortcut)

        let shortcut = AppShortcutDefinition.textTranslation.descriptor(defaults: defaults)

        XCTAssertEqual(shortcut.displayString, "⌥⌘M")
        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_M))
    }

    func testResolverFallsBackWhenStoredValueIsInvalid() throws {
        let suiteName = "AppShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("invalid", forKey: PreferenceKeys.rewriteShortcut)

        let shortcut = AppShortcutDefinition.liveTranslation.descriptor(defaults: defaults)

        XCTAssertEqual(shortcut.displayString, "⌃⇧2")
    }

    func testInProcessPreferenceChangeEmitsReloadNotification() throws {
        let suiteName = "AppShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expectation = expectation(
            forNotification: UserDefaults.didChangeNotification,
            object: defaults
        )

        defaults.set("⌥⌘K", forKey: PreferenceKeys.selectedTextShortcut)

        wait(for: [expectation], timeout: 1)
    }
}
