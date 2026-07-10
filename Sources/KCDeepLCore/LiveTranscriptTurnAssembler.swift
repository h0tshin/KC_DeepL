import Foundation

public enum LiveTranscriptAssemblyField {
    case original
    case translation
}

public struct LiveTranscriptAssemblyDraft: Equatable {
    public let speaker: LiveConversationSpeaker
    public var originalText: String
    public var translatedText: String

    public var isEmpty: Bool {
        originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum LiveTranscriptAssemblyChange: Equatable {
    case append(LiveConversationMessage)
    case update(LiveConversationMessage)
}

public struct LiveTranscriptTurnAssembler {
    private let speaker: LiveConversationSpeaker
    private var original = TranscriptStreamState()
    private var translation = TranscriptStreamState()
    private var lastMessageInTurn: LiveConversationMessage?

    public init(speaker: LiveConversationSpeaker) {
        self.speaker = speaker
    }

    public var draft: LiveTranscriptAssemblyDraft {
        LiveTranscriptAssemblyDraft(
            speaker: speaker,
            originalText: original.visibleText,
            translatedText: translation.visibleText
        )
    }

    public mutating func update(
        field: LiveTranscriptAssemblyField,
        text: String
    ) -> [LiveTranscriptAssemblyChange] {
        let previouslyQueuedSegmentCount: Int
        let didChange: Bool

        switch field {
        case .original:
            previouslyQueuedSegmentCount = original.queuedSegmentCount
            didChange = original.update(text)
        case .translation:
            previouslyQueuedSegmentCount = translation.queuedSegmentCount
            didChange = translation.update(text)
        }

        var changes: [LiveTranscriptAssemblyChange] = []
        if didChange, previouslyQueuedSegmentCount > 0 {
            changes.append(contentsOf: settlePreviouslyQueuedSegments(
                field: field,
                count: previouslyQueuedSegmentCount
            ))
        }
        changes.append(contentsOf: flushPairedSegments(force: false))
        return changes
    }

    public mutating func finish() -> [LiveTranscriptAssemblyChange] {
        original.finish()
        translation.finish()
        let changes = flushPairedSegments(force: true)
        resetForNextTurn()
        return changes
    }

    public mutating func reset() {
        original.reset()
        translation.reset()
        lastMessageInTurn = nil
    }

    private mutating func settlePreviouslyQueuedSegments(
        field: LiveTranscriptAssemblyField,
        count: Int
    ) -> [LiveTranscriptAssemblyChange] {
        guard var lastMessageInTurn else {
            return []
        }

        let queuedText: String
        switch field {
        case .original:
            queuedText = original.removeFirstQueuedSegments(count: count)
            lastMessageInTurn.originalText = Self.joinedTranscript([
                lastMessageInTurn.originalText,
                queuedText
            ])
        case .translation:
            queuedText = translation.removeFirstQueuedSegments(count: count)
            lastMessageInTurn.translatedText = Self.joinedTranscript([
                lastMessageInTurn.translatedText,
                queuedText
            ])
        }

        guard !queuedText.isEmpty else {
            return []
        }

        self.lastMessageInTurn = lastMessageInTurn
        return [.update(lastMessageInTurn)]
    }

    private mutating func flushPairedSegments(force: Bool) -> [LiveTranscriptAssemblyChange] {
        var changes: [LiveTranscriptAssemblyChange] = []

        while original.hasQueuedSegment && translation.hasQueuedSegment {
            let message = LiveConversationMessage(
                speaker: speaker,
                originalText: original.removeFirstQueuedSegment(),
                translatedText: translation.removeFirstQueuedSegment()
            )
            lastMessageInTurn = message
            changes.append(.append(message))
        }

        guard force else {
            return changes
        }

        let remainingOriginal = original.removeAllQueuedSegments()
        let remainingTranslation = translation.removeAllQueuedSegments()
        guard !remainingOriginal.isEmpty || !remainingTranslation.isEmpty else {
            return changes
        }

        guard !remainingOriginal.isEmpty else {
            if var lastMessageInTurn,
               !remainingTranslation.isEmpty {
                lastMessageInTurn.translatedText = Self.joinedTranscript([
                    lastMessageInTurn.translatedText,
                    remainingTranslation
                ])
                self.lastMessageInTurn = lastMessageInTurn
                changes.append(.update(lastMessageInTurn))
            }
            return changes
        }

        if var lastMessageInTurn {
            lastMessageInTurn.originalText = Self.joinedTranscript([
                lastMessageInTurn.originalText,
                remainingOriginal
            ])
            lastMessageInTurn.translatedText = Self.joinedTranscript([
                lastMessageInTurn.translatedText,
                remainingTranslation
            ])
            self.lastMessageInTurn = lastMessageInTurn
            changes.append(.update(lastMessageInTurn))
        } else {
            let message = LiveConversationMessage(
                speaker: speaker,
                originalText: remainingOriginal,
                translatedText: remainingTranslation
            )
            lastMessageInTurn = message
            changes.append(.append(message))
        }

        return changes
    }

    private mutating func resetForNextTurn() {
        original.reset()
        translation.reset()
        lastMessageInTurn = nil
    }

    private static func joinedTranscript(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct TranscriptStreamState {
    private var consumedText = ""
    private var buffer = ""
    private var queuedSegments: [String] = []

    var hasQueuedSegment: Bool {
        !queuedSegments.isEmpty
    }

    var queuedSegmentCount: Int {
        queuedSegments.count
    }

    var visibleText: String {
        Self.joinedTranscript(queuedSegments + [buffer])
    }

    @discardableResult
    mutating func update(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let incoming = Self.stripConsumedPrefix(trimmed, consumed: consumedText)
        guard !incoming.isEmpty else {
            return false
        }

        let previousVisibleText = visibleText
        buffer = Self.mergedTranscript(current: buffer, incoming: incoming)
        drainCompletedSegments(allowTrailingEndings: false)
        return visibleText != previousVisibleText
    }

    mutating func finish() {
        drainCompletedSegments(allowTrailingEndings: true)
        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            queuedSegments.append(remainder)
            appendConsumed(remainder)
        }
        buffer = ""
    }

    mutating func reset() {
        consumedText = ""
        buffer = ""
        queuedSegments.removeAll()
    }

    mutating func removeFirstQueuedSegment() -> String {
        queuedSegments.removeFirst()
    }

    mutating func removeFirstQueuedSegments(count: Int) -> String {
        let removalCount = min(max(0, count), queuedSegments.count)
        guard removalCount > 0 else {
            return ""
        }

        let text = Self.joinedTranscript(Array(queuedSegments.prefix(removalCount)))
        queuedSegments.removeFirst(removalCount)
        return text
    }

    mutating func removeAllQueuedSegments() -> String {
        let text = Self.joinedTranscript(queuedSegments)
        queuedSegments.removeAll()
        return text
    }

    private mutating func drainCompletedSegments(allowTrailingEndings: Bool) {
        let split = LiveConversationSegmenter.splitCompletedSegments(
            in: buffer,
            allowTrailingEndings: allowTrailingEndings
        )
        guard !split.completedSegments.isEmpty else {
            return
        }

        for segment in split.completedSegments {
            queuedSegments.append(segment)
            appendConsumed(segment)
        }
        buffer = split.remainder
    }

    private mutating func appendConsumed(_ text: String) {
        consumedText = Self.mergedTranscript(current: consumedText, incoming: text)
    }

    private static func stripConsumedPrefix(_ incoming: String, consumed: String) -> String {
        let consumed = consumed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !consumed.isEmpty else {
            return incoming
        }

        if incoming == consumed {
            return ""
        }

        if incoming.hasPrefix(consumed) {
            return incoming
                .dropFirst(consumed.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return incoming
    }

    private static func mergedTranscript(current: String, incoming: String) -> String {
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !incoming.isEmpty else {
            return current
        }
        guard !current.isEmpty else {
            return incoming
        }
        if incoming == current || current.hasSuffix(incoming) {
            return current
        }
        if incoming.hasPrefix(current) {
            return incoming
        }

        if isLikelyRevision(of: current, with: incoming) {
            return incoming
        }

        let overlap = suffixPrefixOverlapCount(current, incoming)
        if overlap >= 2 {
            return current + String(incoming.dropFirst(overlap))
        }

        return "\(current) \(incoming)"
    }

    private static func isLikelyRevision(of current: String, with incoming: String) -> Bool {
        let shorterCount = min(current.count, incoming.count)
        guard shorterCount >= 5 else {
            return false
        }

        let prefixCount = commonPrefixCount(current, incoming)
        let suffixCount = commonSuffixCount(
            current,
            incoming,
            excludingLeadingCharacters: prefixCount
        )
        let sharedEdgeCount = prefixCount + suffixCount
        guard sharedEdgeCount >= 3 else {
            return false
        }

        return Double(sharedEdgeCount) / Double(shorterCount) >= 0.6
    }

    private static func commonPrefixCount(_ lhs: String, _ rhs: String) -> Int {
        zip(lhs, rhs).prefix { $0.0 == $0.1 }.count
    }

    private static func commonSuffixCount(
        _ lhs: String,
        _ rhs: String,
        excludingLeadingCharacters prefixCount: Int
    ) -> Int {
        let maximumCount = min(lhs.count, rhs.count) - prefixCount
        guard maximumCount > 0 else {
            return 0
        }

        return zip(lhs.reversed(), rhs.reversed())
            .prefix(maximumCount)
            .prefix { $0.0 == $0.1 }
            .count
    }

    private static func suffixPrefixOverlapCount(_ current: String, _ incoming: String) -> Int {
        // Live transcript overlaps are short; bounding the search avoids quadratic
        // work if a provider sends an unexpectedly large snapshot.
        let maximumCount = min(min(current.count, incoming.count), 256)
        guard maximumCount > 1 else {
            return 0
        }

        for count in stride(from: maximumCount, through: 2, by: -1) {
            if current.suffix(count).elementsEqual(incoming.prefix(count)) {
                return count
            }
        }
        return 0
    }

    private static func joinedTranscript(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
