import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// The Office layout engines use different text-frame conventions even when
/// the source geometry and fonts are identical. Keep that choice explicit at
/// scene-extraction time so a PowerPoint calibration is never silently reused
/// for a Word floating text box.
enum PDFOfficeLayoutTarget: Equatable, Sendable {
    case presentation
    case word
}

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

    var officeLayoutTarget: PDFOfficeLayoutTarget {
        switch self {
        case .pptx: .presentation
        case .docx: .word
        }
    }

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

/// Controls whether repeated page chrome is kept on each page or promoted to
/// the target document's reusable template layer.  PPTX uses a slide master;
/// DOCX uses a shared header/footer drawing layer when the geometry is safe.
enum DocumentTemplatePriority: String, CaseIterable, Codable, Identifiable, Sendable {
    case perPage = "per-page"
    case repeatedToTemplate = "repeated-to-template"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .perPage:
            "페이지별 오브젝트"
        case .repeatedToTemplate:
            "템플릿화 우선"
        }
    }

    var detail: String {
        switch self {
        case .perPage:
            "머릿말·꼬리말·배경을 각 페이지에 보존합니다. 원본과 가장 보수적으로 일치합니다."
        case .repeatedToTemplate:
            "반복되는 안전한 요소를 PPTX 슬라이드 마스터 또는 DOCX 공통 헤더 레이어로 이동합니다."
        }
    }

    /// Word does not expose a slide-master UI.  Keep the persisted enum
    /// shared with PPTX, but present the choice to users as the actual Word
    /// behavior: whether repeated header/footer formatting is emitted into
    /// the document's common header/footer parts.
    var wordDisplayName: String {
        switch self {
        case .perPage:
            "페이지별 오브젝트"
        case .repeatedToTemplate:
            "꼬리말 사용"
        }
    }

    var wordDetail: String {
        switch self {
        case .perPage:
            "반복되는 머릿말·꼬리말과 공통 선·이미지를 각 페이지의 본문 오브젝트로 보존합니다."
        case .repeatedToTemplate:
            "반복되는 머릿말·꼬리말과 공통 선·이미지를 DOCX 공통 머리글·꼬리말 영역으로 분리하고 본문에서 제거합니다."
        }
    }
}

/// Controls how decoded PDF image assets are represented in the Office
/// package.  Integration deduplicates identical PNG assets while preserving
/// each placement as an independently movable Office object.
enum DocumentImageGroupingLevel: Int, CaseIterable, Codable, Identifiable, Sendable {
    case split = 0
    case balanced = 1
    case integrated = 2

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .split:
            "분할 우선"
        case .balanced:
            "균형"
        case .integrated:
            "통합 우선"
        }
    }

    var detail: String {
        switch self {
        case .split:
            "PDF 이미지 occurrence마다 별도 PNG 자산과 관계를 만듭니다. 개별 편집성이 가장 높습니다."
        case .balanced:
            "같은 페이지의 동일 이미지 데이터만 공유하고, 배치된 그림은 각각 유지합니다."
        case .integrated:
            "문서 전체의 동일 이미지 데이터를 하나의 미디어 자산으로 공유해 패키지 크기를 줄입니다."
        }
    }
}

/// Presentation-specific text grouping.  The merge operation is geometry
/// aware: alignment, column position, font scale, and vertical gap must all
/// satisfy the selected tolerance before separate PDF blocks become one text
/// box.
enum PresentationTextBoxMergeLevel: Int, CaseIterable, Codable, Identifiable, Sendable {
    case separate = 0
    case balanced = 1
    case broad = 2

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .separate:
            "개별 글상자"
        case .balanced:
            "정렬·간격 일치"
        case .broad:
            "넓게 병합"
        }
    }

    var detail: String {
        switch self {
        case .separate:
            "PDF가 분리한 블록을 그대로 유지합니다."
        case .balanced:
            "같은 정렬·열 위치와 일정한 줄 간격을 가진 인접 블록만 통합합니다."
        case .broad:
            "같은 열 안의 가까운 블록까지 통합해 글상자 수를 줄입니다."
        }
    }
}

/// DOCX can either preserve the exact floating text-box geometry or emit
/// ordinary Word text paragraphs for easier document editing and reflow.
enum WordTextRepresentation: String, CaseIterable, Codable, Identifiable, Sendable {
    case textBoxes = "text-boxes"
    case documentText = "document-text"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .textBoxes:
            "모든 글상자"
        case .documentText:
            "문서 Text"
        }
    }

    var detail: String {
        switch self {
        case .textBoxes:
            "PPT처럼 원본 위치와 크기를 우선해 모든 내용을 편집 가능한 글상자로 배치합니다."
        case .documentText:
            "일반 Word 문단으로 출력해 문서 흐름·검색·재배치를 우선합니다."
        }
    }
}

/// When DOCX is in ordinary-document-text mode, this tolerance decides when
/// a structurally difficult block may fall back to a floating text box.
enum WordTextBoxAllowance: Int, CaseIterable, Codable, Identifiable, Sendable {
    case never = 0
    case conservative = 1
    case balanced = 2
    case permissive = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .never:
            "허용 안 함"
        case .conservative:
            "보수적"
        case .balanced:
            "균형"
        case .permissive:
            "허용 범위 넓게"
        }
    }

    var detail: String {
        switch self {
        case .never:
            "구조가 복잡해도 일반 문단으로 유지합니다. 위치가 달라질 수 있습니다."
        case .conservative:
            "혼합 글꼴·탭·큰 들여쓰기처럼 문단으로 손실될 가능성이 높은 경우만 허용합니다."
        case .balanced:
            "정렬·들여쓰기·줄 간격을 재현하기 어려운 블록에 글상자를 허용합니다."
        case .permissive:
            "원본 위치 보존을 위해 대부분의 비정형 블록을 글상자로 보존합니다."
        }
    }
}

/// Options consumed by extraction and both OOXML writers.  Keeping this
/// target-neutral avoids a PPT-only decision leaking into the Word path.
struct DocumentConversionPipelineOptions: Equatable, Sendable {
    var templatePriority: DocumentTemplatePriority = .perPage
    var imageGroupingLevel: DocumentImageGroupingLevel = .split
    var textBoxMergeLevel: PresentationTextBoxMergeLevel = .separate
    var wordTextRepresentation: WordTextRepresentation = .textBoxes
    var wordTextBoxAllowance: WordTextBoxAllowance = .balanced
    var preserveNativeVectors = true
    var preserveAlphaMasks = true

    static let `default` = DocumentConversionPipelineOptions()
}

struct PresentationConversionOptions: Codable, Equatable, Sendable {
    var templatePriority: DocumentTemplatePriority = .perPage
    var textBoxMergeLevel: PresentationTextBoxMergeLevel = .separate
    var imageGroupingLevel: DocumentImageGroupingLevel = .split
    var preserveNativeVectors = true
    var preserveAlphaMasks = true

    var pipeline: DocumentConversionPipelineOptions {
        DocumentConversionPipelineOptions(
            templatePriority: templatePriority,
            imageGroupingLevel: imageGroupingLevel,
            textBoxMergeLevel: textBoxMergeLevel,
            wordTextRepresentation: .textBoxes,
            wordTextBoxAllowance: .balanced,
            preserveNativeVectors: preserveNativeVectors,
            preserveAlphaMasks: preserveAlphaMasks
        )
    }
}

struct WordConversionOptions: Codable, Equatable, Sendable {
    // Shared header/footer formatting is the useful Word default.  The
    // persisted enum remains backward compatible, so an existing saved
    // preference of `.perPage` is still respected until the user changes it.
    var templatePriority: DocumentTemplatePriority = .repeatedToTemplate
    var textRepresentation: WordTextRepresentation = .textBoxes
    var textBoxAllowance: WordTextBoxAllowance = .balanced
    var imageGroupingLevel: DocumentImageGroupingLevel = .split
    var preserveNativeVectors = true
    var preserveAlphaMasks = true

    var pipeline: DocumentConversionPipelineOptions {
        DocumentConversionPipelineOptions(
            templatePriority: templatePriority,
            imageGroupingLevel: imageGroupingLevel,
            textBoxMergeLevel: .separate,
            wordTextRepresentation: textRepresentation,
            wordTextBoxAllowance: textBoxAllowance,
            preserveNativeVectors: preserveNativeVectors,
            preserveAlphaMasks: preserveAlphaMasks
        )
    }
}

struct DocumentConversionOptions: Codable, Equatable, Sendable {
    var presentation = PresentationConversionOptions()
    var word = WordConversionOptions()

    static let `default` = DocumentConversionOptions()

    func pipeline(for format: DocumentConversionFormat) -> DocumentConversionPipelineOptions {
        switch format {
        case .pptx:
            presentation.pipeline
        case .docx:
            word.pipeline
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
    /// True when `pageImagePNG` contains only a verified uniform page canvas
    /// synthesized by the extractor.  It is not a flattened copy of the PDF
    /// content and can therefore be omitted from Office output when all
    /// foreground PDF objects have native representations.
    let isNativeCanvasBackground: Bool

    init(
        id: String,
        pageIndex: Int,
        cropBox: CGRect,
        rotation: Int,
        pageImagePNG: Data,
        textBoxes: [PDFSceneTextBox],
        images: [PDFSceneImage],
        vectors: [PDFSceneVector],
        templateObjects: [PDFSceneTemplateObject],
        imageOccurrenceCount: Int,
        extractedImageCount: Int,
        nativeVectorCount: Int,
        warnings: [String],
        usesPageRasterFallback: Bool,
        isNativeCanvasBackground: Bool = false
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.cropBox = cropBox
        self.rotation = rotation
        self.pageImagePNG = pageImagePNG
        self.textBoxes = textBoxes
        self.images = images
        self.vectors = vectors
        self.templateObjects = templateObjects
        self.imageOccurrenceCount = imageOccurrenceCount
        self.extractedImageCount = extractedImageCount
        self.nativeVectorCount = nativeVectorCount
        self.warnings = warnings
        self.usesPageRasterFallback = usesPageRasterFallback
        self.isNativeCanvasBackground = isNativeCanvasBackground
    }

    var width: CGFloat { cropBox.width }
    var height: CGFloat { cropBox.height }
}

/// A monotonic progress event emitted by the PDF-to-Office pipeline.  The
/// service reports page-level work during analysis/extraction and serialization
/// rather than waiting for the final package, allowing the macOS UI to update
/// continuously even for long PDFs.
struct DocumentConversionProgress: Equatable, Sendable {
    enum Phase: String, Sendable {
        case preparing
        case analyzing
        case extracting
        case writing
        case validating
        case saving

        var displayName: String {
            switch self {
            case .preparing: "준비"
            case .analyzing: "텍스트 분석"
            case .extracting: "페이지·이미지 추출"
            case .writing: "Office 문서 작성"
            case .validating: "구조 검증"
            case .saving: "저장"
            }
        }
    }

    let fraction: Double
    let phase: Phase
    let completedUnits: Int
    let totalUnits: Int
    let message: String

    init(
        fraction: Double,
        phase: Phase,
        completedUnits: Int = 0,
        totalUnits: Int = 0,
        message: String
    ) {
        self.fraction = min(1, max(0, fraction))
        self.phase = phase
        self.completedUnits = max(0, completedUnits)
        self.totalUnits = max(0, totalUnits)
        self.message = message
    }
}

typealias DocumentConversionProgressHandler = @Sendable (DocumentConversionProgress) -> Void

struct PDFSceneImage {
    let id: String
    let sourceName: String
    let bounds: CGRect
    let pngData: Data
    let paintOrder: Int
    let hasAlpha: Bool
    let maskApplied: Bool
    /// The locally uniform backdrop inferred for an alpha/masked image. It is
    /// used both to prove the image's source-over composite against the page
    /// safety net and to repair the template before the selectable picture is
    /// inserted. `nil` means no reliable local backdrop was available.
    let backdropColor: PDFTextColor?
    let isBackdropIndependent: Bool
    /// The decoded opaque image has been compared against the rendered page
    /// safety-net at its original placement. Only a match can be drawn above
    /// that safety-net without hiding later PDF paint.
    let isSafetyNetVerifiedOpaque: Bool
    /// True when the original image placement needs no rotation or shear and
    /// can therefore be represented by a normal Office picture frame.
    let hasRepresentableGeometry: Bool
    /// True when the PDF image occurrence has an axis-aligned placement that
    /// can be reconstructed as a real Office picture after the corresponding
    /// area has been repaired in the template/background raster. Unlike
    /// `canOverlayOnPageSafetyNet`, this intentionally supports alpha and
    /// masked images because their original paint is removed first.
    let isNativeObjectEligible: Bool
    /// The image stream can be reproduced on top of an independently
    /// extracted page background template. This keeps alpha/mask images
    /// editable without requiring the image's original pixels to exist in
    /// the template raster beneath it.
    let isLayeredTemplateEligible: Bool
    /// The decoded asset contributes visible final pixels in the rendered PDF
    /// reference. A resource that is completely covered by a later PDF draw
    /// operation must be omitted from a layered Office reconstruction rather
    /// than forcing a foreground-page screenshot or resurfacing above content.
    let hasVisibleReferenceContribution: Bool
    /// A PDF clipping path active at the image's `Do` operator.  A normal
    /// Office picture only has a rectangular frame, so a non-rectangular PDF
    /// clip is preserved as a freeform shape filled with the original image.
    /// This is essential for slide footers and masks whose photo is visibly
    /// cut around a template rather than simply layered behind it.
    let clip: PDFSceneImageClip?

    init(
        id: String,
        sourceName: String,
        bounds: CGRect,
        pngData: Data,
        paintOrder: Int,
        hasAlpha: Bool,
        maskApplied: Bool,
        backdropColor: PDFTextColor?,
        isBackdropIndependent: Bool,
        isSafetyNetVerifiedOpaque: Bool,
        hasRepresentableGeometry: Bool,
        isNativeObjectEligible: Bool,
        isLayeredTemplateEligible: Bool,
        hasVisibleReferenceContribution: Bool,
        clip: PDFSceneImageClip? = nil
    ) {
        self.id = id
        self.sourceName = sourceName
        self.bounds = bounds
        self.pngData = pngData
        self.paintOrder = paintOrder
        self.hasAlpha = hasAlpha
        self.maskApplied = maskApplied
        self.backdropColor = backdropColor
        self.isBackdropIndependent = isBackdropIndependent
        self.isSafetyNetVerifiedOpaque = isSafetyNetVerifiedOpaque
        self.hasRepresentableGeometry = hasRepresentableGeometry
        self.isNativeObjectEligible = isNativeObjectEligible
        self.isLayeredTemplateEligible = isLayeredTemplateEligible
        self.hasVisibleReferenceContribution = hasVisibleReferenceContribution
        self.clip = clip
    }

    /// Native image placement is safe only when it cannot alter pixels that
    /// are already represented by the full-page visual safety net.  An opaque
    /// image can be painted over its identical raster pixels; a transparent
    /// or masked image would blend a second time and become too dark or leave
    /// a mask edge in Word/PowerPoint.
    var canOverlayOnPageSafetyNet: Bool {
        isBackdropIndependent
            && !hasAlpha
            && !maskApplied
            && isSafetyNetVerifiedOpaque
    }

    /// The editable-first conversion path draws this image above a repaired
    /// page template only after the source paint has been proven to match the
    /// final page: directly for opaque pixels, or as a source-over composite
    /// against a locally uniform backdrop for alpha/masked pixels.
    var canRecreateOnRepairedPage: Bool {
        // The raster-repair path removes a rectangle from the page template.
        // It cannot safely restore pixels outside a non-rectangular clip, so
        // clipped images are promoted only when a clean layered background is
        // available below them.
        isNativeObjectEligible && clip == nil
    }

    var canRecreateOnLayeredTemplate: Bool {
        isLayeredTemplateEligible
    }

    /// The visible Office frame is the image rectangle intersected with the
    /// active PDF clip.  The writer uses this frame both for a normal picture
    /// and for a freeform image-filled shape.
    var officeBounds: CGRect {
        guard let clip else { return bounds }
        let clipped = bounds.intersection(clip.bounds)
        return clipped.isNull || clipped.width <= 0 || clipped.height <= 0
            ? bounds
            : clipped
    }

    func canRecreate(
        onPageSafetyNet: Bool,
        options: DocumentConversionPipelineOptions
    ) -> Bool {
        guard options.preserveAlphaMasks || (!hasAlpha && !maskApplied) else {
            return false
        }
        return onPageSafetyNet
            ? canRecreateOnRepairedPage
            : canRecreateOnLayeredTemplate
    }
}

/// A representable PDF clipping path captured at an image painting operator.
/// Coordinates remain in source-PDF page space and are normalized by the
/// Office writer only when it emits DrawingML custom geometry.
struct PDFSceneImageClip {
    let bounds: CGRect
    let pathCommands: [PDFSceneVectorPathCommand]
}

/// Controls the relationship between a native Office text box and the
/// template/background raster. Native text is the default outcome: a stable
/// solid background uses a direct mask, while a subtle gradient or watermark
/// uses a glyph-aware local repair. Only text that cannot be recovered as a
/// trustworthy editable run remains in the template image.
enum PDFSceneTextVisualPolicy: String, Sendable {
    case replaceSourcePaint
    case repairSourcePaint
    case preserveSourcePaint

    var createsEditableText: Bool {
        switch self {
        case .replaceSourcePaint, .repairSourcePaint:
            true
        case .preserveSourcePaint:
            false
        }
    }

    var needsAdaptiveBackdropRepair: Bool {
        self == .repairSourcePaint
    }
}

/// Separates editable document content from source header/footer/watermark
/// chrome. Template chrome remains visually intact but is emitted as a locked
/// background-layer object instead of becoming an ordinary editing target.
enum PDFSceneTextRole: String, Sendable {
    case editableContent
    case templateChrome
}

/// A run retains the formatting boundary that PDFKit exposed inside one visual
/// PDF line. Office writers serialize every run separately instead of applying
/// the first glyph's font to an entire paragraph.
struct PDFSceneTextRun {
    let text: String
    let fontName: String
    let fontSize: CGFloat
    let characterSpacing: CGFloat
    let color: PDFTextColor
    let isBold: Bool
    let isItalic: Bool

    init(_ run: PDFTextRun) {
        self.text = run.text
        self.fontName = run.fontName
        self.fontSize = run.fontSize
        self.characterSpacing = run.characterSpacing
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
    /// The local backdrop sampled around the source glyphs.  Keeping this in
    /// the scene is important for DOCX structure decisions: a run painted on
    /// a stable shaded panel belongs in a panel/text box (or table cell), not
    /// in a free-flowing paragraph whose background is emitted as unrelated
    /// horizontal rectangles.
    let backgroundColor: PDFTextColor
    let sourceMaskIsSafe: Bool
    /// A source-render visibility proof for template text. It remains true
    /// when the surrounding template is complex, so visual presence and safe
    /// source-paint replacement are never conflated.
    let hasVisibleInk: Bool
    let extractionSource: PDFTextExtractionSource
    /// Offset, in source points from `bounds.minX`, where a list item's body
    /// text begins. PDFKit commonly collapses a PDF list tab to a normal
    /// space; writers use this source anchor when restoring marker-to-text
    /// geometry with an Office-compatible editable spacer.
    let listTabStop: CGFloat?

    init(
        id: String,
        text: String,
        bounds: CGRect,
        runs: [PDFSceneTextRun],
        sourceMaskBounds: CGRect,
        backgroundColor: PDFTextColor = .white,
        sourceMaskIsSafe: Bool,
        hasVisibleInk: Bool = false,
        extractionSource: PDFTextExtractionSource,
        listTabStop: CGFloat? = nil
    ) {
        self.id = id
        self.text = text
        self.bounds = bounds
        self.runs = runs
        self.sourceMaskBounds = sourceMaskBounds
        self.backgroundColor = backgroundColor
        self.sourceMaskIsSafe = sourceMaskIsSafe
        self.hasVisibleInk = hasVisibleInk
        self.extractionSource = extractionSource
        self.listTabStop = listTabStop
    }
}

/// Paragraph-local horizontal geometry expressed in source PDF points.
///
/// A `PDFSceneTextBox` can contain several visual PDF lines.  PDFKit reports
/// each line's ink origin independently, while Office otherwise starts every
/// paragraph at the text box's single default margin.  Keeping these values
/// separate lets the OOXML writers restore hanging indents, continuation
/// indents, and right/centred line extents without splitting editable text
/// back into one shape per visual line.
struct PDFSceneTextParagraphInsets: Equatable {
    let leading: CGFloat
    let trailing: CGFloat
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
    let role: PDFSceneTextRole
    /// A later editable source text run occupies this template text's glyph
    /// area. The template line is therefore excluded rather than resurfaced
    /// above the foreground during layered reconstruction.
    let isOccludedByForeground: Bool

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
        visualPolicy: PDFSceneTextVisualPolicy,
        role: PDFSceneTextRole = .editableContent,
        isOccludedByForeground: Bool = false
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
        self.role = role
        self.isOccludedByForeground = isOccludedByForeground
    }

    var officeBounds: CGRect { layoutBounds ?? bounds }

    /// Body text is always a required editable reconstruction candidate. A
    /// header/footer line, however, may still be extractable after a later PDF
    /// object has completely covered it. Only a source-mask proof promotes
    /// such chrome into the layered template; otherwise it is intentionally
    /// omitted instead of resurfacing above the final content.
    var hasVisibleReferenceContribution: Bool {
        role == .editableContent
            || (!isOccludedByForeground && lines.allSatisfy(\.hasVisibleInk))
    }

    var canRecreateOnLayeredTemplate: Bool {
        visualPolicy.createsEditableText && hasVisibleReferenceContribution
    }

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

    /// Returns paragraph margins relative to the original source text block,
    /// not to the expanded `officeBounds`.  The body insets above restore that
    /// source origin before these per-line offsets are applied.
    func paragraphInsets(for line: PDFSceneTextLine) -> PDFSceneTextParagraphInsets {
        switch alignment {
        case .left:
            return PDFSceneTextParagraphInsets(
                leading: max(0, line.bounds.minX - bounds.minX),
                trailing: 0
            )
        case .right:
            return PDFSceneTextParagraphInsets(
                leading: 0,
                trailing: max(0, bounds.maxX - line.bounds.maxX)
            )
        case .center:
            // Restrict the paragraph's local line area on both sides.  This
            // preserves the source centre even when visual lines have
            // different widths.
            return PDFSceneTextParagraphInsets(
                leading: max(0, line.bounds.minX - bounds.minX),
                trailing: max(0, bounds.maxX - line.bounds.maxX)
            )
        }
    }
}

enum PDFSceneVectorKind: String, Codable, Sendable {
    case line
    case rectangle
    case ellipse
    case freeform
}

/// A path command preserved from a PDF painting operation. Coordinates remain
/// in PDF page space so each Office writer can normalize them to its own
/// drawing canvas without losing Bézier control points or shape geometry.
enum PDFSceneVectorPathCommand: Equatable {
    case move(CGPoint)
    case line(CGPoint)
    case cubic(control1: CGPoint, control2: CGPoint, end: CGPoint)
    case close
}

struct PDFSceneVector {
    let id: String
    let kind: PDFSceneVectorKind
    let bounds: CGRect
    /// Freeform vectors retain their original PDF path in page coordinates.
    /// Preset line/rectangle geometry leaves this empty.
    let pathCommands: [PDFSceneVectorPathCommand]
    /// `nil` means that the original path was filled without a stroke. OOXML
    /// must emit an explicit no-line rather than inventing a black outline.
    let stroke: PDFTextColor?
    let fill: PDFTextColor?
    let lineWidth: CGFloat
    let rotation: CGFloat
    let paintOrder: Int
    let nativeEligible: Bool
    /// Replaying a vector above a full-page raster is safe only when its
    /// visible pixels are independently confirmed to be the topmost source
    /// pixels in that area.
    let isSafetyNetVerifiedOpaque: Bool

    /// The page safety net already contains the source vector. Repainting an
    /// opaque vector is stable, but repainting a translucent stroke/fill would
    /// apply alpha blending twice. Keep those vectors in the visual fallback.
    var canOverlayOnPageSafetyNet: Bool {
        nativeEligible
            && (stroke?.alpha ?? 1) >= 0.999
            && (fill?.alpha ?? 1) >= 0.999
            && isSafetyNetVerifiedOpaque
    }

    /// A page-sized raster is only an allowed template when it is a verified
    /// background asset rather than a flattened copy of all foreground
    /// content. In that mode, an eligible vector can be recreated without
    /// drawing over a second copy of itself. Unlike the page-safety-net mode,
    /// alpha is safe here because the source vector is absent from the
    /// template and is composited exactly once by Office.
    var canRecreateOnLayeredTemplate: Bool {
        nativeEligible
    }

    func canRecreate(
        onPageSafetyNet: Bool,
        options: DocumentConversionPipelineOptions
    ) -> Bool {
        guard options.preserveNativeVectors else { return false }
        return onPageSafetyNet
            ? canOverlayOnPageSafetyNet
            : canRecreateOnLayeredTemplate
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
