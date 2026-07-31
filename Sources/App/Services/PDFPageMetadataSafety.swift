import CoreGraphics
import PDFKit

/// Reads page-tree metadata without accepting PDFKit's lossy normalization.
///
/// `PDFPage.rotation` always exposes one of the four quarter turns, even when
/// the source dictionary contains an unsupported value such as `/Rotate 45`.
/// Translation placement must therefore inspect the inheritable PDF value.
enum PDFPageMetadataSafety {
    static func effectiveRotation(
        of page: PDFPage,
        pageIndex: Int
    ) throws -> Int {
        guard let pageReference = page.pageRef,
              var dictionary = pageReference.dictionary
        else {
            return normalizedRotation(page.rotation)
        }

        // Rotate is inheritable through the page tree. A depth bound treats a
        // malformed/cyclic tree as an invalid PDF instead of looping forever.
        for _ in 0..<64 {
            var rotation: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(dictionary, "Rotate", &rotation) {
                return Int(rotation)
            }

            var rawRotation: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(
                dictionary,
                "Rotate",
                &rawRotation
            ) {
                // The PDF specification defines Rotate as an integer. Refuse a
                // malformed value rather than silently inheriting or rounding.
                throw PDFDocumentServiceError.invalidPDF
            }

            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(
                dictionary,
                "Parent",
                &parent
            ), let parent else {
                return 0
            }
            dictionary = parent
        }

        _ = pageIndex
        throw PDFDocumentServiceError.invalidPDF
    }

    private static func normalizedRotation(_ rotation: Int) -> Int {
        let value = rotation % 360
        return value >= 0 ? value : value + 360
    }
}
