import Foundation
import KCDeepLCore

struct LiveConversationCSVExporter {
    static func suggestedFilename(for conversation: LiveConversation) -> String {
        let sanitizedTitle = conversation.title
            .map { character in
                if character.isWhitespace || "/\\:*?\"<>|".contains(character) {
                    return "_"
                }
                return String(character)
            }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "_."))

        return "\(sanitizedTitle.isEmpty ? "live-conversation" : sanitizedTitle).csv"
    }

    static func data(for conversation: LiveConversation) -> Data {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: csv(for: conversation).utf8)
        return data
    }

    static func write(_ conversation: LiveConversation, to url: URL) throws {
        try data(for: conversation).write(to: url, options: .atomic)
    }

    static func csv(for conversation: LiveConversation) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var rows = [
            [
                "conversation_title",
                "timestamp",
                "speaker",
                "original_text",
                "translated_text"
            ].map(csvField).joined(separator: ",")
        ]

        rows.append(contentsOf: conversation.messages.map { message in
            [
                conversation.title,
                formatter.string(from: message.timestamp),
                message.speaker.displayName,
                message.originalText,
                message.translatedText
            ].map(csvField).joined(separator: ",")
        })

        return rows.joined(separator: "\r\n") + "\r\n"
    }

    private static func csvField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
