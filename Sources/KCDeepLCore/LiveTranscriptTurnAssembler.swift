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
        switch field {
        case .original:
            original.update(text)
        case .translation:
            translation.update(text)
        }
        return flushPairedSegments(force: false)
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

    var visibleText: String {
        Self.joinedTranscript(queuedSegments + [buffer])
    }

    mutating func update(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let incoming = Self.stripConsumedPrefix(trimmed, consumed: consumedText)
        guard !incoming.isEmpty else {
            return
        }

        buffer = Self.mergedTranscript(current: buffer, incoming: incoming)
        drainCompletedSegments(allowTrailingEndings: false)
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

        return "\(current) \(incoming)"
    }

    private static func joinedTranscript(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
