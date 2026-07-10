import Foundation

public enum LiveConversationSpeaker: String, Codable, Equatable, CaseIterable, Sendable {
    case me
    case other

    public var displayName: String {
        switch self {
        case .me:
            "나"
        case .other:
            "상대방"
        }
    }
}

public struct LiveConversationMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let speaker: LiveConversationSpeaker
    public var originalText: String
    public var translatedText: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        speaker: LiveConversationSpeaker,
        originalText: String,
        translatedText: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.speaker = speaker
        self.originalText = originalText
        self.translatedText = translatedText
        self.timestamp = timestamp
    }
}

public struct LiveConversation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [LiveConversationMessage]

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [LiveConversationMessage] = []
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "새 대화" : title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

public struct LiveConversationSnapshot: Codable, Equatable, Sendable {
    public var conversations: [LiveConversation]
    public var selectedConversationID: LiveConversation.ID?

    public init(
        conversations: [LiveConversation],
        selectedConversationID: LiveConversation.ID?
    ) {
        self.conversations = conversations
        self.selectedConversationID = selectedConversationID
    }
}

public protocol LiveConversationStoring: Sendable {
    func load() throws -> LiveConversationSnapshot
    func save(_ snapshot: LiveConversationSnapshot) throws
}

public final class FileLiveConversationStore: LiveConversationStoring, @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.fileURL = baseDirectory
                .appendingPathComponent("KCDeepL", isDirectory: true)
                .appendingPathComponent("live-conversations.json")
        }
    }

    public func load() throws -> LiveConversationSnapshot {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return LiveConversationSnapshot(conversations: [], selectedConversationID: nil)
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LiveConversationSnapshot.self, from: data)
    }

    public func save(_ snapshot: LiveConversationSnapshot) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
