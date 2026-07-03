import Foundation

public enum LiveKaraokeTimeline {
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
}
