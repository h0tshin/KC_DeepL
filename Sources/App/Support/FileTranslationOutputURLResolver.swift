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
            "번역 PDF를 저장할 위치를 선택해 주세요."
        case .invalidSourceURL:
            "원본 PDF 파일 이름을 확인할 수 없습니다."
        case .sourceWouldBeOverwritten:
            "원본 PDF는 덮어쓸 수 없습니다. 다른 파일 이름을 선택해 주세요."
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
        targetLanguage: LanguageOption
    ) throws -> String {
        let basename = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !basename.isEmpty else {
            throw FileTranslationOutputURLResolverError.invalidSourceURL
        }
        return "\(basename).\(targetLanguage.code).translated.pdf"
    }

    func resolve(
        sourceURL: URL,
        targetLanguage: LanguageOption,
        locationRawValue: String,
        explicitlySelectedURL: URL? = nil
    ) throws -> URL {
        let location = FileTranslationOutputLocation(rawValue: locationRawValue) ?? .ask
        let destination: URL

        if let explicitlySelectedURL {
            destination = explicitlySelectedURL.pathExtension.lowercased() == "pdf"
                ? explicitlySelectedURL
                : explicitlySelectedURL.appendingPathExtension("pdf")
        } else {
            let filename = try suggestedFilename(
                for: sourceURL,
                targetLanguage: targetLanguage
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
}
