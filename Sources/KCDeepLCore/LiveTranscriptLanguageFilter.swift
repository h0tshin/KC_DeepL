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
        let normalized = normalizedLanguageCode(languageCode)
        guard !normalized.isEmpty else {
            return true
        }

        let hasHangul = text.contains { character in
            character.unicodeScalars.contains { scalar in
                (0xAC00...0xD7AF).contains(Int(scalar.value))
                    || (0x1100...0x11FF).contains(Int(scalar.value))
                    || (0x3130...0x318F).contains(Int(scalar.value))
            }
        }
        let hasLatin = text.contains { character in
            character.unicodeScalars.contains { scalar in
                (0x0041...0x005A).contains(Int(scalar.value))
                    || (0x0061...0x007A).contains(Int(scalar.value))
            }
        }

        if normalized == "ko" {
            return hasHangul || !hasLatin
        }

        if normalized == "en" {
            return !hasHangul
        }

        return true
    }

    private static func normalizedLanguageCode(_ code: String) -> String {
        code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }
}
