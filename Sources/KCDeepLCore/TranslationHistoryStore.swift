import Foundation

public protocol TranslationHistoryStoring: Sendable {
    func load() throws -> [TranslationHistoryItem]
    func save(_ items: [TranslationHistoryItem]) throws
}

public final class FileTranslationHistoryStore: TranslationHistoryStoring, @unchecked Sendable {
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
                .appendingPathComponent("translation-history.json")
        }
    }

    public func load() throws -> [TranslationHistoryItem] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([TranslationHistoryItem].self, from: data)
    }

    public func save(_ items: [TranslationHistoryItem]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(items)
        try data.write(to: fileURL, options: .atomic)
    }
}
