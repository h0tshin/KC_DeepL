import CryptoKit
import Foundation

struct PDFOfficeConversionService {
    private let extractor: PDFSceneExtractor

    init(extractor: PDFSceneExtractor = PDFSceneExtractor()) {
        // Conversion can also be invoked from a detached worker or a test,
        // before the SwiftUI app's initializer runs. Register the bundled OFL
        // fonts here so source-family resolution is identical in every path.
        _ = AppFontRegistry.registerBundledFonts()
        self.extractor = extractor
    }

    /// Builds and validates an Office package at `destinationURL`. Callers
    /// should provide a UUID temp URL in the destination directory and move it
    /// into the final path only after this method returns successfully.
    func convert(
        sourceURL: URL,
        format: DocumentConversionFormat,
        destinationURL: URL
    ) throws -> DocumentConversionReport {
        try Task.checkCancellation()
        let scene = try extractor.extract(
            sourceURL: sourceURL,
            layoutTarget: format.officeLayoutTarget
        )
        try Task.checkCancellation()

        let parts: [OOXMLPart]
        switch format {
        case .pptx:
            parts = try PresentationMLWriter().makeParts(scene: scene)
        case .docx:
            parts = try WordprocessingMLWriter().makeParts(scene: scene)
        }
        try Task.checkCancellation()
        do {
            try OOXMLPackageValidator.validate(parts: parts, format: format)
        } catch {
            throw DocumentConversionError.packageValidationFailed(
                error.localizedDescription
            )
        }
        do {
            try SimpleZIPWriter().write(parts: parts, to: destinationURL)
        } catch is CancellationError {
            throw DocumentConversionError.cancelled
        } catch {
            throw DocumentConversionError.packageWriteFailed(
                error.localizedDescription
            )
        }
        return DocumentConversionReport(scene: scene, format: format)
    }
}

struct DocumentConversionReportStore {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func save(_ report: DocumentConversionReport) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appendingPathComponent("KCDeepL", isDirectory: true)
            .appendingPathComponent("ConversionReports", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let timestamp = ISO8601DateFormatter().string(from: report.createdAt)
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(report.sourceSHA256.prefix(16))-\(timestamp).json"
        let destination = uniqueReportURL(
            directory: directory,
            filename: filename
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: destination, options: .atomic)
        return destination
    }

    private func uniqueReportURL(directory: URL, filename: String) -> URL {
        let desired = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: desired.path) else { return desired }
        let base = desired.deletingPathExtension().lastPathComponent
        for suffix in 2...9_999 {
            let candidate = directory
                .appendingPathComponent("\(base)-\(suffix)")
                .appendingPathExtension("json")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory
            .appendingPathComponent("\(base)-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }
}
