import CryptoKit
import Foundation

/// Produces stable package-level keys for decoded PDF image assets. The image
/// placements remain separate Office objects; only the binary media asset is
/// shared when the user chooses an integration level.
enum OfficeImageAssetGrouping {
    static func key(
        image: PDFSceneImage,
        pageIndex: Int,
        occurrenceIndex: Int,
        level: DocumentImageGroupingLevel
    ) -> String {
        let hash = SHA256.hash(data: image.pngData)
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        switch level {
        case .split:
            return "split-\(pageIndex)-\(occurrenceIndex)-\(hash)"
        case .balanced:
            return "page-\(pageIndex)-\(hash)"
        case .integrated:
            return "document-\(hash)"
        }
    }

    static func sharedFilename(for key: String) -> String {
        "shared-\(shortHash(key)).png"
    }
}

private extension OfficeImageAssetGrouping {
    static func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(10)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
