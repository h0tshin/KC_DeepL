import Foundation

enum DocumentConversionOutputURLResolverError: LocalizedError, Equatable {
    case invalidSourceURL
    case destinationRequired
    case sourceWouldBeOverwritten

    var errorDescription: String? {
        switch self {
        case .invalidSourceURL:
            "원본 PDF 파일 이름을 확인할 수 없습니다."
        case .destinationRequired:
            "변환 파일을 저장할 위치를 선택해 주세요."
        case .sourceWouldBeOverwritten:
            "원본 PDF는 덮어쓸 수 없습니다."
        }
    }
}
struct DocumentConversionOutputURLResolver {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func suggestedFilename(
        for sourceURL: URL,
        format: DocumentConversionFormat
    ) throws -> String {
        let basename = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !basename.isEmpty else {
            throw DocumentConversionOutputURLResolverError.invalidSourceURL
        }
        return "\(basename).converted.\(format.fileExtension)"
    }

    func resolve(
        sourceURL: URL,
        format: DocumentConversionFormat,
        locationRawValue: String,
        explicitlySelectedURL: URL? = nil
    ) throws -> URL {
        let destination: URL
        if let explicitlySelectedURL {
            if explicitlySelectedURL.pathExtension.lowercased() == format.fileExtension {
                destination = explicitlySelectedURL
            } else {
                destination = explicitlySelectedURL
                    .deletingPathExtension()
                    .appendingPathExtension(format.fileExtension)
            }
        } else {
            let filename = try suggestedFilename(for: sourceURL, format: format)
            switch FileTranslationOutputLocation(rawValue: locationRawValue) ?? .ask {
            case .desktop:
                destination = fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Desktop", isDirectory: true)
                    .appendingPathComponent(filename, isDirectory: false)
            case .downloads:
                destination = fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads", isDirectory: true)
                    .appendingPathComponent(filename, isDirectory: false)
            case .ask:
                throw DocumentConversionOutputURLResolverError.destinationRequired
            }
        }

        guard destination.standardizedFileURL != sourceURL.standardizedFileURL else {
            throw DocumentConversionOutputURLResolverError.sourceWouldBeOverwritten
        }
        return uniqueURL(for: destination)
    }

    private func uniqueURL(for desiredURL: URL) -> URL {
        guard fileManager.fileExists(atPath: desiredURL.path) else {
            return desiredURL
        }
        let directory = desiredURL.deletingLastPathComponent()
        let basename = desiredURL.deletingPathExtension().lastPathComponent
        let extensionName = desiredURL.pathExtension
        for suffix in 2...9_999 {
            let candidate = directory
                .appendingPathComponent("\(basename) (\(suffix))")
                .appendingPathExtension(extensionName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory
            .appendingPathComponent("\(basename)-\(UUID().uuidString)")
            .appendingPathExtension(extensionName)
    }
}
