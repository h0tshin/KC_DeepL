import Foundation
import KCDeepLCore

enum FileTranslationOutputLocation: String, CaseIterable, Sendable {
    case desktop
    case downloads
    case ask
}

enum FileTranslationOutputURLResolverError: LocalizedError, Equatable {
    case destinationRequired
    case invalidSourceURL
    case sourceWouldBeOverwritten

    var errorDescription: String? {
        switch self {
        case .destinationRequired:
            "번역 파일을 저장할 위치를 선택해 주세요."
        case .invalidSourceURL:
            "원본 파일 이름을 확인할 수 없습니다."
        case .sourceWouldBeOverwritten:
            "원본 파일은 덮어쓸 수 없습니다. 다른 파일 이름을 선택해 주세요."
        }
    }
}

struct FileTranslationOutputURLResolver {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func suggestedFilename(
        for sourceURL: URL,
        targetLanguage: LanguageOption,
        kind: SupportedFileDocumentKind = .pdf
    ) throws -> String {
        let basename = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !basename.isEmpty else {
            throw FileTranslationOutputURLResolverError.invalidSourceURL
        }
        return "\(basename).\(targetLanguage.code).translated.\(kind.defaultOutputExtension)"
    }

    func resolve(
        sourceURL: URL,
        targetLanguage: LanguageOption,
        locationRawValue: String,
        explicitlySelectedURL: URL? = nil,
        kind: SupportedFileDocumentKind = .pdf
    ) throws -> URL {
        let location = FileTranslationOutputLocation(rawValue: locationRawValue) ?? .ask
        let destination: URL

        if let explicitlySelectedURL {
            destination = Self.acceptedExtensions(for: kind).contains(
                explicitlySelectedURL.pathExtension.lowercased()
            )
                ? explicitlySelectedURL
                : explicitlySelectedURL.appendingPathExtension(kind.defaultOutputExtension)
        } else {
            let filename = try suggestedFilename(
                for: sourceURL,
                targetLanguage: targetLanguage,
                kind: kind
            )
            switch location {
            case .desktop:
                destination = fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Desktop", isDirectory: true)
                    .appendingPathComponent(filename, isDirectory: false)
            case .downloads:
                destination = fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads", isDirectory: true)
                    .appendingPathComponent(filename, isDirectory: false)
            case .ask:
                throw FileTranslationOutputURLResolverError.destinationRequired
            }
        }

        guard destination.standardizedFileURL != sourceURL.standardizedFileURL else {
            throw FileTranslationOutputURLResolverError.sourceWouldBeOverwritten
        }
        return uniqueURL(for: destination)
    }

    private func uniqueURL(for desiredURL: URL) -> URL {
        guard fileManager.fileExists(atPath: desiredURL.path) else {
            return desiredURL
        }

        let directory = desiredURL.deletingLastPathComponent()
        let basename = desiredURL.deletingPathExtension().lastPathComponent
        let pathExtension = desiredURL.pathExtension

        for suffix in 2...9_999 {
            let candidate = directory
                .appendingPathComponent("\(basename) (\(suffix))", isDirectory: false)
                .appendingPathExtension(pathExtension)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return directory
            .appendingPathComponent("\(basename)-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension(pathExtension)
    }

    private static func acceptedExtensions(
        for kind: SupportedFileDocumentKind
    ) -> Set<String> {
        switch kind {
        case .pdf:
            ["pdf"]
        case .plainText:
            ["txt", "text", "log", "csv", "tsv"]
        case .markdown:
            ["md", "markdown", "mdown", "mkd"]
        }
    }
}
