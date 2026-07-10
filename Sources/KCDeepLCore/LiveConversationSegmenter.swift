import Foundation

public struct LiveConversationSegmentSplit: Equatable {
    public let completedSegments: [String]
    public let remainder: String
}

public enum LiveConversationSegmenter {
    private static let strongKoreanEndings = [
        "습니다",
        "ㅂ니다",
        "입니다",
        "합니다",
        "됩니다",
        "군요",
        "네요",
        "지요",
        "죠"
    ].sorted { $0.count > $1.count }

    // "임" is also a common suffix inside nouns such as "게임". Treat it as
    // an ending only at the logical end of a transcript, where it is unambiguous.
    private static let trailingOnlyKoreanEndings = ["임"]

    private static let koreanEndingFinalCharacters: Set<Character> = [
        "다", "요", "죠", "어", "아", "임"
    ]

    private static let weakKoreanEndings = [
        "다",
        "어",
        "아"
    ]

    private static let physicalTerminators: Set<Character> = [
        ".",
        "!",
        "?",
        "。",
        "！",
        "？",
        "…"
    ]

    private static let trailingClosers: Set<Character> = [
        "\"", "'", ")", "]", "}", "”", "’", "»", "」", "』", "】", "〉", "》"
    ]

    private static let periodAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st"
    ]

    public static func splitCompletedSegments(
        in text: String,
        allowTrailingEndings: Bool = true
    ) -> LiveConversationSegmentSplit {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return LiveConversationSegmentSplit(completedSegments: [], remainder: "")
        }

        let boundaries = completionBoundaries(in: normalized, allowTrailingEndings: allowTrailingEndings)
        guard !boundaries.isEmpty else {
            return LiveConversationSegmentSplit(completedSegments: [], remainder: normalized)
        }

        var segments: [String] = []
        var segmentStart = normalized.startIndex

        for boundary in boundaries {
            let segment = normalized[segmentStart..<boundary]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                segments.append(String(segment))
            }
            segmentStart = boundary
        }

        let remainder = normalized[segmentStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return LiveConversationSegmentSplit(
            completedSegments: segments,
            remainder: String(remainder)
        )
    }

    private static func completionBoundaries(
        in text: String,
        allowTrailingEndings: Bool
    ) -> [String.Index] {
        var boundaries: [String.Index] = []
        var index = text.startIndex

        while index < text.endIndex {
            if let physicalBoundary = physicalBoundary(startingAt: index, in: text) {
                boundaries.append(physicalBoundary)
                index = physicalBoundary
                continue
            }

            let nextIndex = text.index(after: index)
            if koreanEndingFinalCharacters.contains(text[index]),
               isKoreanEndingBoundary(
                   endingAt: nextIndex,
                   in: text,
                   allowTrailingEndings: allowTrailingEndings
               ) {
                boundaries.append(boundaryIncludingTrailingClosers(from: nextIndex, in: text))
            }

            index = nextIndex
        }

        return deduplicated(boundaries)
    }

    private static func physicalBoundary(startingAt index: String.Index, in text: String) -> String.Index? {
        let character = text[index]
        guard physicalTerminators.contains(character) || character.isNewline else {
            return nil
        }

        if character == "." {
            if isDecimalSeparator(at: index, in: text) {
                return nil
            }

            if index > text.startIndex,
               text[text.index(before: index)] == "." {
                return nil
            }

            if isAbbreviationPeriod(at: index, in: text) {
                return nil
            }

            var boundary = text.index(after: index)
            while boundary < text.endIndex, text[boundary] == "." {
                boundary = text.index(after: boundary)
            }
            return boundaryIncludingTrailingClosers(from: boundary, in: text)
        }

        return boundaryIncludingTrailingClosers(from: text.index(after: index), in: text)
    }

    private static func isDecimalSeparator(at index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else {
            return false
        }

        let nextIndex = text.index(after: index)
        guard nextIndex < text.endIndex else {
            return false
        }

        let previous = text[text.index(before: index)]
        let next = text[nextIndex]
        return previous.isNumber && next.isNumber
    }

    private static func isKoreanEndingBoundary(
        endingAt boundary: String.Index,
        in text: String,
        allowTrailingEndings: Bool
    ) -> Bool {
        if strongKoreanEndings.contains(where: {
            textHasSuffix($0, endingAt: boundary, in: text)
        }) {
            return isBoundaryFollowedBySeparator(boundary, in: text)
                || (boundary == text.endIndex && allowTrailingEndings)
        }

        if trailingOnlyKoreanEndings.contains(where: {
            textHasSuffix($0, endingAt: boundary, in: text)
        }) {
            return allowTrailingEndings && isLogicalEnd(boundary, in: text)
        }

        return weakKoreanEndings.contains(where: {
            textHasSuffix($0, endingAt: boundary, in: text)
        })
            && isBoundaryFollowedBySeparator(boundary, in: text)
    }

    private static func textHasSuffix(
        _ suffix: String,
        endingAt boundary: String.Index,
        in text: String
    ) -> Bool {
        guard let start = text.index(
            boundary,
            offsetBy: -suffix.count,
            limitedBy: text.startIndex
        ) else {
            return false
        }
        return text[start..<boundary].elementsEqual(suffix)
    }

    private static func isLogicalEnd(_ boundary: String.Index, in text: String) -> Bool {
        var index = boundary
        while index < text.endIndex, trailingClosers.contains(text[index]) {
            index = text.index(after: index)
        }
        return index == text.endIndex
    }

    private static func boundaryIncludingTrailingClosers(
        from boundary: String.Index,
        in text: String
    ) -> String.Index {
        var boundary = boundary
        while boundary < text.endIndex, trailingClosers.contains(text[boundary]) {
            boundary = text.index(after: boundary)
        }
        return boundary
    }

    private static func isAbbreviationPeriod(at index: String.Index, in text: String) -> Bool {
        var tokenStart = index
        while tokenStart > text.startIndex {
            let previousIndex = text.index(before: tokenStart)
            guard text[previousIndex].isLetter else {
                break
            }
            tokenStart = previousIndex
        }

        let token = text[tokenStart..<index]
        guard !token.isEmpty else {
            return false
        }

        return periodAbbreviations.contains(token.lowercased())
    }

    private static func isBoundaryFollowedBySeparator(_ boundary: String.Index, in text: String) -> Bool {
        guard boundary < text.endIndex else {
            return false
        }

        let next = text[boundary]
        return next.isWhitespace
            || next.isNewline
            || next == "\""
            || next == "'"
            || next == ")"
            || next == "]"
            || next == "}"
            || next == "”"
            || next == "’"
    }

    private static func deduplicated(_ boundaries: [String.Index]) -> [String.Index] {
        var results: [String.Index] = []
        for boundary in boundaries where results.last != boundary {
            results.append(boundary)
        }
        return results
    }
}
