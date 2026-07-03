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
        "죠",
        "임"
    ].sorted { $0.count > $1.count }

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
            if isKoreanEndingBoundary(endingAt: nextIndex, in: text, allowTrailingEndings: allowTrailingEndings) {
                boundaries.append(nextIndex)
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

            var boundary = text.index(after: index)
            while boundary < text.endIndex, text[boundary] == "." {
                boundary = text.index(after: boundary)
            }
            return boundary
        }

        return text.index(after: index)
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
        let prefix = String(text[..<boundary])

        if strongKoreanEndings.contains(where: { prefix.hasSuffix($0) }) {
            return isBoundaryFollowedBySeparator(boundary, in: text) || (boundary == text.endIndex && allowTrailingEndings)
        }

        guard weakKoreanEndings.contains(where: { prefix.hasSuffix($0) }) else {
            return false
        }

        return isBoundaryFollowedBySeparator(boundary, in: text)
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
