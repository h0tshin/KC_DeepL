import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// The two Office packages that the document-conversion surface can produce.
enum DocumentConversionFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case pptx
    case docx

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pptx:
            "파워포인트 (.pptx)"
        case .docx:
            "워드 (.docx)"
        }
    }

    var shortName: String {
        switch self {
        case .pptx:
            "파워포인트"
        case .docx:
            "워드"
        }
    }

    var fileExtension: String { rawValue }

    var contentType: UTType {
        switch self {
        case .pptx:
            UTType("org.openxmlformats.presentationml.presentation")
                ?? .data
        case .docx:
            UTType("org.openxmlformats.wordprocessingml.document")
                ?? .data
        }
    }
}

enum DocumentConversionStage: Equatable {
    case idle
    case preparing
    case converting(page: Int, total: Int)
    case validating
    case completed
    case cancelled
    case failed

    var isBusy: Bool {
        switch self {
        case .preparing, .converting, .validating:
            true
        case .idle, .completed, .cancelled, .failed:
            false
        }
    }
}

enum DocumentConversionError: LocalizedError, Equatable {
    case sourceNotPDF
    case sourceUnavailable
    case emptyPDF
    case invalidPDF
    case lockedPDF
    case unsupportedPDF(String)
    case destinationUnavailable(String)
    case destinationAlreadyExists
    case packageWriteFailed(String)
    case packageValidationFailed(String)
    case unsupportedText(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sourceNotPDF:
            "PDF 파일만 파워포인트 또는 워드로 변환할 수 있습니다."
        case .sourceUnavailable:
            "선택한 PDF를 읽을 수 없습니다. 파일 권한과 위치를 확인해 주세요."
        case .emptyPDF:
            "페이지가 없는 PDF는 변환할 수 없습니다."
        case .invalidPDF:
            "유효하지 않거나 손상된 PDF입니다."
        case .lockedPDF:
            "암호로 잠긴 PDF는 먼저 잠금을 해제해야 합니다."
        case let .unsupportedPDF(reason):
            "PDF의 일부 기능을 안전하게 변환할 수 없습니다: \(reason)"
        case let .destinationUnavailable(path):
            "변환 파일을 저장할 폴더에 쓸 수 없습니다: \(path)"
        case .destinationAlreadyExists:
            "같은 이름의 변환 파일이 이미 존재합니다."
        case let .packageWriteFailed(reason):
            "Office 파일을 생성하지 못했습니다: \(reason)"
        case let .packageValidationFailed(reason):
            "생성된 Office 파일의 구조 검증에 실패했습니다: \(reason)"
        case let .unsupportedText(reason):
            "텍스트를 Office 글상자로 복원하지 못했습니다: \(reason)"
        case .cancelled:
            "문서 변환을 취소했습니다."
        }
    }
}

/// A PDF object after extraction and before target-specific serialization.
/// Coordinates remain in PDF points with a bottom-left origin until a writer
/// performs the final target conversion. Keeping this model target-neutral is
/// what allows PPTX and DOCX to share the same fidelity decisions.
struct PDFSceneDocument {
    let sourceURL: URL
    let sourceSHA256: String
    let pages: [PDFScenePage]
    let warnings: [String]

    var pageCount: Int { pages.count }
    var textBoxCount: Int { pages.reduce(0) { $0 + $1.textBoxes.count } }
    var imageOccurrenceCount: Int { pages.reduce(0) { $0 + $1.imageOccurrenceCount } }
    var extractedImageCount: Int { pages.reduce(0) { $0 + $1.extractedImageCount } }
    var extractedImageAssetCount: Int { pages.reduce(0) { $0 + $1.images.count } }
    var nativeVectorCount: Int { pages.reduce(0) { $0 + $1.nativeVectorCount } }
    var rasterFallbackPageCount: Int { pages.filter(\.usesPageRasterFallback).count }
    var templateCount: Int { pages.reduce(0) { $0 + $1.templateObjects.count } }
    var sharedTemplateCount: Int {
        pages.reduce(0) { total, page in
            total + page.templateObjects.filter { $0.role == .sharedTemplate }.count
        }
    }
}

struct PDFScenePage {
    let id: String
    let pageIndex: Int
    let cropBox: CGRect
    let rotation: Int
    let pageImagePNG: Data
    let textBoxes: [PDFSceneTextBox]
    /// Decoded image paint occurrences. The page PNG remains the visual
    /// safety net, while these assets give Office users a selectable/editable
    /// image object whenever the PDF image stream can be decoded safely.
    let images: [PDFSceneImage]
    let vectors: [PDFSceneVector]
    let templateObjects: [PDFSceneTemplateObject]
    let imageOccurrenceCount: Int
    let extractedImageCount: Int
    let nativeVectorCount: Int
    let warnings: [String]
    let usesPageRasterFallback: Bool

    var width: CGFloat { cropBox.width }
    var height: CGFloat { cropBox.height }
}

struct PDFSceneImage {
    let id: String
    let sourceName: String
    let bounds: CGRect
    let pngData: Data
    let paintOrder: Int
    let hasAlpha: Bool
    let maskApplied: Bool
    let isBackdropIndependent: Bool

    /// Native image placement is safe only when it cannot alter pixels that
    /// are already represented by the full-page visual safety net.  An opaque
    /// image can be painted over its identical raster pixels; a transparent
    /// or masked image would blend a second time and become too dark or leave
    /// a mask edge in Word/PowerPoint.
    var canOverlayOnPageSafetyNet: Bool {
        isBackdropIndependent && !hasAlpha && !maskApplied
    }
}

/// Controls the relationship between a native Office text box and the visual
/// fallback image. `replaceSourcePaint` is used only after the extractor has
/// verified that the source glyphs can be rebuilt safely; otherwise the image
/// remains authoritative and the text is retained as non-destructive metadata
/// in the scene/report rather than risking a blank patch.
enum PDFSceneTextVisualPolicy: String, Sendable {
    case replaceSourcePaint
    case preserveSourcePaint
}

/// A run retains the formatting boundary that PDFKit exposed inside one visual
/// PDF line. Office writers serialize every run separately instead of applying
/// the first glyph's font to an entire paragraph.
struct PDFSceneTextRun {
    let text: String
    let fontName: String
    let fontSize: CGFloat
    let color: PDFTextColor
    let isBold: Bool
    let isItalic: Bool

    init(_ run: PDFTextRun) {
        self.text = run.text
        self.fontName = run.fontName
        self.fontSize = run.fontSize
        self.color = run.textColor
        self.isBold = run.isBold
        self.isItalic = run.isItalic
    }
}

/// A visual source line contained in a single editable Office text box. The
/// surrounding box groups paragraph-like lines without discarding their
/// original line breaks, bounds, or styling.
struct PDFSceneTextLine {
    let id: String
    let text: String
    let bounds: CGRect
    let runs: [PDFSceneTextRun]
    let sourceMaskBounds: CGRect
    let sourceMaskIsSafe: Bool
    let extractionSource: PDFTextExtractionSource
    /// Offset, in source points from `bounds.minX`, of a list item's text tab
    /// stop. PDFKit commonly collapses a PDF list tab to a normal space; the
    /// writers restore it as a native Office tab instead of letting the
    /// substituted marker font shift all following text left.
    let listTabStop: CGFloat?

    init(
        id: String,
        text: String,
        bounds: CGRect,
        runs: [PDFSceneTextRun],
        sourceMaskBounds: CGRect,
        sourceMaskIsSafe: Bool,
        extractionSource: PDFTextExtractionSource,
        listTabStop: CGFloat? = nil
    ) {
        self.id = id
        self.text = text
        self.bounds = bounds
        self.runs = runs
        self.sourceMaskBounds = sourceMaskBounds
        self.sourceMaskIsSafe = sourceMaskIsSafe
        self.extractionSource = extractionSource
        self.listTabStop = listTabStop
    }
}

struct PDFSceneTextBox {
    let id: String
    let text: String
    /// Tight union of the source PDF glyph bounds.  This remains the reference
    /// rectangle for source-paint masking and for diagnostics.
    let bounds: CGRect
    /// A target-layout rectangle derived from the resolved Office fonts.  PDF
    /// glyph bounds are often tighter than Word/PowerPoint's logical advance
    /// and side bearings, so writers use this rectangle to avoid clipping a
    /// valid final character.  It never changes the source mask rectangle.
    let layoutBounds: CGRect?
    let fontName: String
    let fontSize: CGFloat
    let color: PDFTextColor
    let alignment: PDFTextAlignment
    let lineCount: Int
    let sourceLineIDs: [String]
    let extractionSource: PDFTextExtractionSource
    let lines: [PDFSceneTextLine]
    let visualPolicy: PDFSceneTextVisualPolicy

    init(
        id: String,
        text: String,
        bounds: CGRect,
        layoutBounds: CGRect? = nil,
        fontName: String,
        fontSize: CGFloat,
        color: PDFTextColor,
        alignment: PDFTextAlignment,
        lineCount: Int,
        sourceLineIDs: [String],
        extractionSource: PDFTextExtractionSource,
        lines: [PDFSceneTextLine],
        visualPolicy: PDFSceneTextVisualPolicy
    ) {
        self.id = id
        self.text = text
        self.bounds = bounds
        self.layoutBounds = layoutBounds
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.alignment = alignment
        self.lineCount = lineCount
        self.sourceLineIDs = sourceLineIDs
        self.extractionSource = extractionSource
        self.lines = lines
        self.visualPolicy = visualPolicy
    }

    var officeBounds: CGRect { layoutBounds ?? bounds }

    /// Insets that retain the original PDF text origin after `officeBounds`
    /// gains room for font side bearings.  A left-aligned paragraph needs a
    /// leading inset; a right-aligned paragraph needs the corresponding
    /// trailing inset.  Centered text remains centered in the expanded box.
    var officeLeadingInset: CGFloat {
        alignment == .left
            ? max(0, bounds.minX - officeBounds.minX)
            : 0
    }

    var officeTrailingInset: CGFloat {
        alignment == .right
            ? max(0, officeBounds.maxX - bounds.maxX)
            : 0
    }
}

enum PDFSceneVectorKind: String, Codable, Sendable {
    case line
    case rectangle
    case ellipse
}

struct PDFSceneVector {
    let id: String
    let kind: PDFSceneVectorKind
    let bounds: CGRect
    let stroke: PDFTextColor
    let fill: PDFTextColor?
    let lineWidth: CGFloat
    let rotation: CGFloat
    let paintOrder: Int
    let nativeEligible: Bool

    /// The page safety net already contains the source vector. Repainting an
    /// opaque vector is stable, but repainting a translucent stroke/fill would
    /// apply alpha blending twice. Keep those vectors in the visual fallback.
    var canOverlayOnPageSafetyNet: Bool {
        nativeEligible
            && stroke.alpha >= 0.999
            && (fill?.alpha ?? 1) >= 0.999
    }
}

enum PDFSceneTemplateRole: String, Codable, Sendable {
    case pageLocalBackground
    case sharedTemplate
    case header
    case footer
    case watermark
    case fallback
}

struct PDFSceneTemplateObject {
    let id: String
    let role: PDFSceneTemplateRole
    let bounds: CGRect
    let confidence: Double
    let sourceFingerprint: String
}

/// A deliberately small, user-facing report. It is written next to the
/// app's Application Support data so users can inspect why an object became a
/// native Office object or an image fallback.
struct DocumentConversionReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sourceFileName: String
    let sourceSHA256: String
    let format: DocumentConversionFormat
    let pageCount: Int
    let textBoxCount: Int
    let imageOccurrenceCount: Int
    let extractedImageCount: Int
    let extractedImageAssetCount: Int
    let nativeVectorCount: Int
    let sharedTemplateCount: Int
    let pageRasterFallbackCount: Int
    let warnings: [String]
    let pageMetrics: [DocumentConversionPageMetric]
    let createdAt: Date

    init(
        scene: PDFSceneDocument,
        format: DocumentConversionFormat,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = 1
        self.sourceFileName = scene.sourceURL.lastPathComponent
        self.sourceSHA256 = scene.sourceSHA256
        self.format = format
        self.pageCount = scene.pageCount
        self.textBoxCount = scene.textBoxCount
        self.imageOccurrenceCount = scene.imageOccurrenceCount
        self.extractedImageCount = scene.extractedImageCount
        self.extractedImageAssetCount = scene.extractedImageAssetCount
        self.nativeVectorCount = scene.nativeVectorCount
        self.sharedTemplateCount = scene.sharedTemplateCount
        self.pageRasterFallbackCount = scene.rasterFallbackPageCount
        self.warnings = scene.warnings
        self.pageMetrics = scene.pages.map(DocumentConversionPageMetric.init)
        self.createdAt = createdAt
    }
}

struct DocumentConversionPageMetric: Codable, Equatable, Sendable {
    let page: Int
    let widthPoints: Double
    let heightPoints: Double
    let textBoxCount: Int
    let imageOccurrenceCount: Int
    let extractedImageCount: Int
    let extractedImageAssetCount: Int
    let nativeVectorCount: Int
    let templateObjectCount: Int
    let usesPageRasterFallback: Bool
    let warnings: [String]

    init(page: PDFScenePage) {
        self.page = page.pageIndex + 1
        self.widthPoints = Double(page.width)
        self.heightPoints = Double(page.height)
        self.textBoxCount = page.textBoxes.count
        self.imageOccurrenceCount = page.imageOccurrenceCount
        self.extractedImageCount = page.extractedImageCount
        self.extractedImageAssetCount = page.images.count
        self.nativeVectorCount = page.nativeVectorCount
        self.templateObjectCount = page.templateObjects.count
        self.usesPageRasterFallback = page.usesPageRasterFallback
        self.warnings = page.warnings
    }
}

struct DocumentConversionResult {
    let outputURL: URL
    let reportURL: URL?
    let report: DocumentConversionReport
}
