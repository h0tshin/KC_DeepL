import AppKit
import CoreText
import SwiftUI

/// Central typography policy for both SwiftUI and AppKit surfaces.
///
/// Barlow is the primary Latin face. Its descriptor cascades to Noto Sans CJK
/// KR so mixed English/Korean strings use both families without manual run
/// splitting. Monospaced content is explicitly routed to D2Coding.
enum AppFont {
    static let barlowRegular = "Barlow-Regular"
    static let barlowItalic = "Barlow-Italic"
    static let barlowBold = "Barlow-Bold"
    static let barlowBoldItalic = "Barlow-BoldItalic"
    static let barlowSemibold = "Barlow-SemiBold"
    static let barlowSemiboldItalic = "Barlow-SemiBoldItalic"
    static let notoSansKRRegular = "NotoSansCJKkr-Regular"
    static let notoSansKRBold = "NotoSansCJKkr-Bold"
    static let d2CodingRegular = "D2Coding"
    static let d2CodingBold = "D2CodingBold"

    static func swiftUIFont(
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        Font(uiFont(size: size, weight: nsWeight(for: weight)))
    }

    static func monospacedSwiftUIFont(
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        Font(monospacedFont(size: size, weight: nsWeight(for: weight)))
    }

    static func uiFont(
        size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        let isEmphasized = isEmphasized(weight)
        let latinName = isEmphasized ? barlowSemibold : barlowRegular
        let koreanName = isEmphasized ? notoSansKRBold : notoSansKRRegular

        guard let latin = NSFont(name: latinName, size: size) else {
            return NSFont(name: koreanName, size: size)
                ?? NSFont.systemFont(ofSize: size, weight: weight)
        }

        let cascade = [NSFontDescriptor(name: koreanName, size: size)]
        let descriptor = latin.fontDescriptor.addingAttributes([
            .cascadeList: cascade
        ])
        return NSFont(descriptor: descriptor, size: size) ?? latin
    }

    static func contentFont(
        for text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        let names = preferredPostScriptNames(
            for: text,
            isBold: isEmphasized(weight)
        )
        return names.lazy.compactMap { NSFont(name: $0, size: size) }.first
            ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func monospacedFont(
        size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        let name = isEmphasized(weight) ? d2CodingBold : d2CodingRegular
        return NSFont(name: name, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Stable public PostScript names ordered for a single-font PDF text run.
    /// PDF free-text annotations cannot attach a different font to each script,
    /// so Korean/CJK content starts with Noto and Latin-only content with Barlow.
    static func preferredPostScriptNames(
        for text: String,
        isBold: Bool,
        monospaced: Bool = false
    ) -> [String] {
        if monospaced {
            return [
                isBold ? d2CodingBold : d2CodingRegular,
                isBold ? notoSansKRBold : notoSansKRRegular,
                isBold ? barlowSemibold : barlowRegular
            ]
        }

        let latin = isBold ? barlowSemibold : barlowRegular
        let korean = isBold ? notoSansKRBold : notoSansKRRegular
        if containsHangul(in: text) {
            return [korean, latin]
        }
        if containsKana(in: text) {
            return [
                isBold ? "HiraginoSans-W6" : "HiraginoSans-W3",
                korean,
                latin
            ]
        }
        if containsHan(in: text) {
            return [
                isBold ? "PingFangSC-Semibold" : "PingFangSC-Regular",
                isBold ? "PingFangTC-Semibold" : "PingFangTC-Regular",
                korean,
                latin
            ]
        }
        return [latin, korean]
    }

    static func containsHangul(in text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x11FF, // Hangul Jamo
                 0x3130...0x318F, // Hangul compatibility Jamo
                 0xA960...0xA97F, // Hangul Jamo Extended-A
                 0xAC00...0xD7AF, // Hangul syllables
                 0xD7B0...0xD7FF: // Hangul Jamo Extended-B
                return true
            default:
                return false
            }
        }
    }

    static func containsKana(in text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x309F, // Hiragana
                 0x30A0...0x30FF, // Katakana
                 0x31F0...0x31FF, // Katakana phonetic extensions
                 0xFF65...0xFF9F: // Half-width Katakana
                return true
            default:
                return false
            }
        }
    }

    static func containsHan(in text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x2FFF, // CJK radicals
                 0x31C0...0x31EF, // CJK strokes
                 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF, // CJK unified ideographs
                 0xF900...0xFAFF: // CJK compatibility ideographs
                return true
            default:
                return false
            }
        }
    }

    private static func isEmphasized(_ weight: NSFont.Weight) -> Bool {
        weight.rawValue >= NSFont.Weight.semibold.rawValue
    }

    private static func nsWeight(for weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .black:
            return .black
        case .heavy:
            return .heavy
        case .bold:
            return .bold
        case .semibold:
            return .semibold
        case .medium:
            return .medium
        case .light:
            return .light
        case .thin:
            return .thin
        case .ultraLight:
            return .ultraLight
        default:
            return .regular
        }
    }
}

enum AppFontRegistry {
    struct RegistrationFailure: Equatable, Sendable {
        let fileName: String
        let reason: String
    }

    struct RegistrationReport: Equatable, Sendable {
        let registeredPostScriptNames: [String]
        let failures: [RegistrationFailure]

        var isComplete: Bool { failures.isEmpty }
    }

    private struct Resource: Sendable {
        let name: String
        let fileExtension: String
        let subdirectory: String
        let postScriptName: String

        var fileName: String { "\(name).\(fileExtension)" }
    }

    private static let resources = [
        Resource(
            name: "Barlow-Regular",
            fileExtension: "ttf",
            subdirectory: "Fonts/Barlow",
            postScriptName: AppFont.barlowRegular
        ),
        Resource(
            name: "Barlow-Italic",
            fileExtension: "ttf",
            subdirectory: "Fonts/Barlow",
            postScriptName: AppFont.barlowItalic
        ),
        Resource(
            name: "Barlow-Bold",
            fileExtension: "ttf",
            subdirectory: "Fonts/Barlow",
            postScriptName: AppFont.barlowBold
        ),
        Resource(
            name: "Barlow-BoldItalic",
            fileExtension: "ttf",
            subdirectory: "Fonts/Barlow",
            postScriptName: AppFont.barlowBoldItalic
        ),
        Resource(
            name: "Barlow-SemiBold",
            fileExtension: "ttf",
            subdirectory: "Fonts/Barlow",
            postScriptName: AppFont.barlowSemibold
        ),
        Resource(
            name: "Barlow-SemiBoldItalic",
            fileExtension: "ttf",
            subdirectory: "Fonts/Barlow",
            postScriptName: AppFont.barlowSemiboldItalic
        ),
        Resource(
            name: "NotoSansCJKkr-Regular",
            fileExtension: "otf",
            subdirectory: "Fonts/NotoSansKR",
            postScriptName: AppFont.notoSansKRRegular
        ),
        Resource(
            name: "NotoSansCJKkr-Bold",
            fileExtension: "otf",
            subdirectory: "Fonts/NotoSansKR",
            postScriptName: AppFont.notoSansKRBold
        ),
        Resource(
            name: "D2Coding-Regular",
            fileExtension: "ttf",
            subdirectory: "Fonts/D2Coding",
            postScriptName: AppFont.d2CodingRegular
        ),
        Resource(
            name: "D2Coding-Bold",
            fileExtension: "ttf",
            subdirectory: "Fonts/D2Coding",
            postScriptName: AppFont.d2CodingBold
        )
    ]

    /// Registers bundled fonts for this process. Registration is intentionally
    /// non-fatal: a damaged or unavailable resource falls back to system fonts.
    @discardableResult
    static func registerBundledFonts() -> RegistrationReport {
        registrationReport
    }

    /// Swift's immutable static initialization is lazy and process-wide, so
    /// CoreText registration runs exactly once even when composition services
    /// are created from multiple tasks.
    private static let registrationReport = performRegistration()

    private static func performRegistration() -> RegistrationReport {
        var registeredNames: [String] = []
        var failures: [RegistrationFailure] = []

        for resource in resources {
            guard let url = AppResourceLocator.url(
                forResource: resource.name,
                withExtension: resource.fileExtension,
                subdirectory: resource.subdirectory
            ) else {
                failures.append(
                    RegistrationFailure(
                        fileName: resource.fileName,
                        reason: "번들 리소스를 찾을 수 없습니다."
                    )
                )
                continue
            }

            var unmanagedError: Unmanaged<CFError>?
            let didRegister = CTFontManagerRegisterFontsForURL(
                url as CFURL,
                .process,
                &unmanagedError
            )
            let error = unmanagedError?.takeRetainedValue()

            // CoreText reports an error when a process-scoped font was already
            // registered. Resolve by public PostScript name before treating it
            // as a real failure, which keeps repeated startup/test calls safe.
            guard didRegister || NSFont(name: resource.postScriptName, size: 12) != nil else {
                failures.append(
                    RegistrationFailure(
                        fileName: resource.fileName,
                        reason: error.map { CFErrorCopyDescription($0) as String }
                            ?? "CoreText 등록에 실패했습니다."
                    )
                )
                continue
            }

            registeredNames.append(resource.postScriptName)
        }

        return RegistrationReport(
            registeredPostScriptNames: registeredNames,
            failures: failures
        )
    }
}
