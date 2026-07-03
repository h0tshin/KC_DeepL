import Foundation

public struct LiveKaraokeCue: Equatable {
    public let startCharacter: Int
    public let text: String

    public init(startCharacter: Int, text: String) {
        self.startCharacter = startCharacter
        self.text = text
    }
}

public struct LiveKaraokeCuePlan: Equatable {
    public let preservedHighlight: Int
    public let trackedText: String
    public let cue: LiveKaraokeCue?
    public let shouldResetQueuedCues: Bool

    public init(
        preservedHighlight: Int,
        trackedText: String,
        cue: LiveKaraokeCue?,
        shouldResetQueuedCues: Bool
    ) {
        self.preservedHighlight = preservedHighlight
        self.trackedText = trackedText
        self.cue = cue
        self.shouldResetQueuedCues = shouldResetQueuedCues
    }
}

public enum LiveKaraokeTimeline {
    public static func cuePlan(
        previousText: String,
        updatedText: String,
        currentHighlight: Int
    ) -> LiveKaraokeCuePlan {
        let previousText = previousText.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedText = updatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedHighlight = min(max(0, currentHighlight), updatedText.count)

        guard !updatedText.isEmpty else {
            return LiveKaraokeCuePlan(
                preservedHighlight: 0,
                trackedText: "",
                cue: nil,
                shouldResetQueuedCues: !previousText.isEmpty
            )
        }

        if previousText.isEmpty || updatedText.hasPrefix(previousText) {
            let cueStart = min(max(previousText.count, clampedHighlight), updatedText.count)
            let cue = cueStart < updatedText.count
                ? LiveKaraokeCue(startCharacter: cueStart, text: String(updatedText.dropFirst(cueStart)))
                : nil

            return LiveKaraokeCuePlan(
                preservedHighlight: clampedHighlight,
                trackedText: updatedText,
                cue: cue,
                shouldResetQueuedCues: false
            )
        }

        let commonPrefix = commonPrefixCharacterCount(previousText, updatedText)
        let preservedHighlight = min(clampedHighlight, commonPrefix)
        let cue = preservedHighlight < updatedText.count
            ? LiveKaraokeCue(
                startCharacter: preservedHighlight,
                text: String(updatedText.dropFirst(preservedHighlight))
            )
            : nil

        return LiveKaraokeCuePlan(
            preservedHighlight: preservedHighlight,
            trackedText: updatedText,
            cue: cue,
            shouldResetQueuedCues: true
        )
    }

    public static func highlightedCharacters(
        in text: String,
        elapsedDuration: TimeInterval,
        totalDuration: TimeInterval
    ) -> Int {
        let characterCount = text.count
        guard characterCount > 0 else {
            return 0
        }
        guard totalDuration > 0 else {
            return elapsedDuration > 0 ? characterCount : 0
        }

        let progress = min(1.0, max(0.0, elapsedDuration / totalDuration))
        if progress >= 1.0 {
            return characterCount
        }
        return min(characterCount, max(0, Int((Double(characterCount) * progress).rounded(.down))))
    }

    public static func estimatedSpeechDuration(for text: String) -> TimeInterval {
        let weight = speechWeight(for: text)
        guard weight > 0 else {
            return 0.35
        }

        let cjkRatio = cjkWeightRatio(for: text)
        let charactersPerSecond = (9.5 * cjkRatio) + (18.5 * (1.0 - cjkRatio))
        return max(0.35, weight / charactersPerSecond)
    }

    public static func speechWeight(for text: String) -> Double {
        text.reduce(0.0) { partialResult, character in
            if character.isWhitespace || character.isNewline {
                return partialResult
            }
            if isCJK(character) {
                return partialResult + 1.0
            }
            if character.isPunctuation {
                return partialResult + 0.35
            }
            return partialResult + 1.0
        }
    }

    private static func cjkWeightRatio(for text: String) -> Double {
        let characters = text.filter { !$0.isWhitespace && !$0.isNewline }
        guard !characters.isEmpty else {
            return 0
        }

        let cjkCount = characters.filter(isCJK).count
        return Double(cjkCount) / Double(characters.count)
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0xAC00...0xD7AF).contains(Int(scalar.value))
                || (0x3040...0x30FF).contains(Int(scalar.value))
                || (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    private static func commonPrefixCharacterCount(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var leftIndex = lhs.startIndex
        var rightIndex = rhs.startIndex

        while leftIndex < lhs.endIndex,
              rightIndex < rhs.endIndex,
              lhs[leftIndex] == rhs[rightIndex] {
            count += 1
            leftIndex = lhs.index(after: leftIndex)
            rightIndex = rhs.index(after: rightIndex)
        }

        return count
    }
}
