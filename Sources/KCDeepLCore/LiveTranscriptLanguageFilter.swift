import Foundation

public struct LiveTranscriptLanguageRoute: Equatable {
    public let sourceLanguageCode: String
    public let targetLanguageCode: String

    public init(sourceLanguageCode: String, targetLanguageCode: String) {
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
    }
}

public enum LiveTranscriptLanguageFilter {
    public static func accepts(
        field: LiveTranscriptAssemblyField,
        text: String,
        languageCode: String?,
        route: LiveTranscriptLanguageRoute
    ) -> Bool {
        let expectedLanguage = field == .original
            ? route.sourceLanguageCode
            : route.targetLanguageCode
        let oppositeLanguage = field == .original
            ? route.targetLanguageCode
            : route.sourceLanguageCode

        if let languageCode,
           !languageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if languageMatches(languageCode, expectedLanguage) {
                return true
            }
            if languageMatches(languageCode, oppositeLanguage) {
                return false
            }
            return false
        }

        return textLooksLike(text, languageCode: expectedLanguage)
    }

    public static func languageMatches(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedLanguageCode(lhs)
        let right = normalizedLanguageCode(rhs)
        guard !left.isEmpty, !right.isEmpty else {
            return false
        }
        return left == right
            || left.hasPrefix("\(right)-")
            || right.hasPrefix("\(left)-")
    }

    private static func textLooksLike(_ text: String, languageCode: String) -> Bool {
        guard let expectedScripts = expectedScripts(for: languageCode) else {
            return true
        }

        let observedScripts = Set(text.unicodeScalars.compactMap(writingScript(for:)))
        guard !observedScripts.isEmpty else {
            // Numbers, punctuation, and emoji do not provide language evidence.
            return true
        }

        return !observedScripts.isDisjoint(with: expectedScripts)
    }

    private static func expectedScripts(for languageCode: String) -> Set<WritingScript>? {
        let baseLanguage = normalizedLanguageCode(languageCode)
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""

        switch baseLanguage {
        case "ko":
            return [.hangul]
        case "ja":
            return [.kana, .han]
        case "zh":
            return [.han]
        case "en", "fr", "de", "es", "pt", "it", "nl", "ca", "eu", "gl",
             "af", "sq", "id", "ms", "fil", "sv", "no", "nb", "da", "fi",
             "is", "pl", "cs", "sk", "sl", "hr", "ro", "hu", "tr", "vi",
             "et", "lv", "lt", "sw":
            return [.latin]
        case "ru", "uk", "bg", "be", "mk":
            return [.cyrillic]
        case "sr":
            return [.cyrillic, .latin]
        case "ar", "fa", "ur", "sd":
            return [.arabic]
        case "hi", "mr", "ne":
            return [.devanagari]
        case "el":
            return [.greek]
        case "he":
            return [.hebrew]
        case "th":
            return [.thai]
        default:
            return nil
        }
    }

    private static func writingScript(for scalar: Unicode.Scalar) -> WritingScript? {
        let value = Int(scalar.value)

        if (0x0041...0x005A).contains(value)
            || (0x0061...0x007A).contains(value)
            || (0x00C0...0x024F).contains(value)
            || (0x1E00...0x1EFF).contains(value)
            || (0xFF21...0xFF3A).contains(value)
            || (0xFF41...0xFF5A).contains(value) {
            return .latin
        }
        if (0xAC00...0xD7AF).contains(value)
            || (0x1100...0x11FF).contains(value)
            || (0x3130...0x318F).contains(value) {
            return .hangul
        }
        if (0x3040...0x30FF).contains(value)
            || (0x31F0...0x31FF).contains(value)
            || (0xFF66...0xFF9D).contains(value) {
            return .kana
        }
        if (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2FA1F).contains(value) {
            return .han
        }
        if (0x0400...0x052F).contains(value)
            || (0x2DE0...0x2DFF).contains(value)
            || (0xA640...0xA69F).contains(value) {
            return .cyrillic
        }
        if (0x0600...0x06FF).contains(value)
            || (0x0750...0x077F).contains(value)
            || (0x08A0...0x08FF).contains(value)
            || (0xFB50...0xFDFF).contains(value)
            || (0xFE70...0xFEFF).contains(value) {
            return .arabic
        }
        if (0x0900...0x097F).contains(value) {
            return .devanagari
        }
        if (0x0370...0x03FF).contains(value) || (0x1F00...0x1FFF).contains(value) {
            return .greek
        }
        if (0x0590...0x05FF).contains(value) {
            return .hebrew
        }
        if (0x0E00...0x0E7F).contains(value) {
            return .thai
        }

        return scalar.properties.isAlphabetic ? .other : nil
    }

    private static func normalizedLanguageCode(_ code: String) -> String {
        code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }
}

private enum WritingScript: Hashable {
    case latin
    case hangul
    case kana
    case han
    case cyrillic
    case arabic
    case devanagari
    case greek
    case hebrew
    case thai
    case other
}
