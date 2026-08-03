import CoreGraphics
import Foundation

/// The source used to recover the text and geometry for a PDF line.
enum PDFTextExtractionSource: String, Equatable, Sendable {
    case native
    case visionOCR
}

enum PDFTextAlignment: String, Equatable, Sendable {
    case left
    case center
    case right
}

/// A platform-neutral representation of a PDF text color.
struct PDFTextColor: Equatable, Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    static let black = PDFTextColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let white = PDFTextColor(red: 1, green: 1, blue: 1, alpha: 1)
}

/// A contiguous character range with the visual appearance reported by
/// PDFKit. A PDF selection may contain several font resources (for example a
/// Symbol-font bullet followed by an Arial sentence), so treating the first
/// character's font as the font for the whole line is not safe.
struct PDFTextRun: Equatable, Sendable {
    let text: String
    /// An Office-compatible font family name, never an opaque PDF resource or
    /// PostScript identifier such as `ArialMT`.
    let fontName: String
    let fontSize: CGFloat
    let textColor: PDFTextColor
    let isBold: Bool
    let isItalic: Bool
    /// `false` means that the run remains extractable, but its source paint
    /// must remain in the raster backdrop to avoid a destructive replacement.
    let isOfficeCompatible: Bool

    init(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        textColor: PDFTextColor,
        isBold: Bool = false,
        isItalic: Bool = false,
        isOfficeCompatible: Bool = false
    ) {
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.textColor = textColor
        self.isBold = isBold
        self.isItalic = isItalic
        self.isOfficeCompatible = isOfficeCompatible
    }
}

/// Shared source-mask and translation-annotation geometry. The horizontal
/// padding covers PDF text antialiasing; vertical expansion is intentionally
/// avoided because many slide PDFs align text boxes directly to a coloured
/// shape edge.
enum PDFOverlayGeometry {
    static func bounds(
        for lineBounds: CGRect,
        constrainedTo cropBox: CGRect
    ) -> CGRect {
        let expanded = lineBounds.insetBy(dx: -1.5, dy: 0)
        let intersection = expanded.intersection(cropBox)
        return intersection.isNull ? lineBounds : intersection
    }
}

/// A geometrically anchored source line. IDs are deterministic for unchanged input PDFs.
struct PDFTextLine: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let runs: [PDFTextRun]
    let bounds: CGRect
    let sourceMaskBounds: CGRect
    /// Background sampling verified that this native line can be removed from
    /// the visual safety-net image. This is deliberately separate from
    /// extractability: OCR and complex backgrounds are never safe to erase.
    let sourceMaskIsSafe: Bool
    let fontName: String
    let fontSize: CGFloat
    let textColor: PDFTextColor
    let backgroundColor: PDFTextColor
    let alignment: PDFTextAlignment
    let readingOrder: Int
    let columnIndex: Int
    let extractionSource: PDFTextExtractionSource

    init(
        id: String,
        text: String,
        runs: [PDFTextRun] = [],
        bounds: CGRect,
        sourceMaskBounds: CGRect,
        sourceMaskIsSafe: Bool = false,
        fontName: String,
        fontSize: CGFloat,
        textColor: PDFTextColor,
        backgroundColor: PDFTextColor,
        alignment: PDFTextAlignment,
        readingOrder: Int,
        columnIndex: Int,
        extractionSource: PDFTextExtractionSource
    ) {
        self.id = id
        self.text = text
        self.runs = runs
        self.bounds = bounds
        self.sourceMaskBounds = sourceMaskBounds
        self.sourceMaskIsSafe = sourceMaskIsSafe
        self.fontName = fontName
        self.fontSize = fontSize
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.alignment = alignment
        self.readingOrder = readingOrder
        self.columnIndex = columnIndex
        self.extractionSource = extractionSource
    }
}

/// A conservative paragraph-like grouping of adjacent lines in the same column.
struct PDFTextBlock: Identifiable, Equatable, Sendable {
    let id: String
    let lineIDs: [String]
    let text: String
    let bounds: CGRect
    let readingOrder: Int
    let columnIndex: Int
}

struct PDFPageAnalysis: Identifiable, Equatable, Sendable {
    let id: String
    let pageIndex: Int
    let mediaBox: CGRect
    let cropBox: CGRect
    let bleedBox: CGRect
    let trimBox: CGRect
    let artBox: CGRect
    let rotation: Int
    let lines: [PDFTextLine]
    let blocks: [PDFTextBlock]
    let warnings: [PDFDocumentWarning]

    /// Page-scoped text in the spatial reading order used for translation.
    var sourceText: String {
        blocks.map(\.text).joined(separator: "\n\n")
    }
}

struct PDFDocumentAnalysis: Equatable, Sendable {
    let sourceURL: URL
    let sourceData: Data
    let pageCount: Int
    let pages: [PDFPageAnalysis]
    let warnings: [PDFDocumentWarning]

    var translatableLineCount: Int {
        pages.reduce(into: 0) { $0 += $1.lines.count }
    }
}

struct PDFCompositionResult: Equatable, Sendable {
    let destinationURL: URL
    let pageCount: Int
    let translatedLineCount: Int
    let warnings: [PDFDocumentWarning]
}

enum PDFDocumentCompositionPolicy: Equatable, Sendable {
    case strict
    case bestEffort
}

/// Controls how translated text is written back to the result PDF.
enum PDFTranslationRenderMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case replaceText
    case preserveOriginalWithLayer
    case hybrid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .replaceText:
            "원본 텍스트 교체"
        case .preserveOriginalWithLayer:
            "원본 이미지 유지 (번역 레이어)"
        case .hybrid:
            "하이브리드 사용"
        }
    }

    var detail: String {
        switch self {
        case .replaceText:
            "페이지 콘텐츠로 번역문을 다시 그려 별도 번역 레이어를 만들지 않습니다."
        case .preserveOriginalWithLayer:
            "원본 PDF를 보존하고 번역문을 별도 레이어로 추가합니다."
        case .hybrid:
            "네이티브 텍스트는 콘텐츠로 교체하고 OCR·이미지 영역은 번역 레이어를 사용합니다."
        }
    }
}

enum PDFDocumentWarning: Error, LocalizedError, Equatable, Sendable {
    case ocrApplied(pageIndex: Int)
    case ocrDisabled(pageIndex: Int)
    case hybridOCRApplied(pageIndex: Int, addedLineCount: Int)
    case hybridOCRUnavailable(pageIndex: Int)
    case rotatedHybridOCRUnsupported(pageIndex: Int, rotation: Int)
    case lowOCRConfidence(pageIndex: Int, confidence: Float)
    case ocrRequired(pageIndex: Int)
    case rotatedOCRUnsupported(pageIndex: Int, rotation: Int)
    case pageHasNoTranslatableText(pageIndex: Int)
    case blockTranslationReflowed(blockID: String)
    case complexBackground(pageIndex: Int, lineID: String)
    case backgroundSamplingUnavailable(pageIndex: Int, lineID: String)
    case linkOverlap(pageIndex: Int, lineID: String, target: String?)
    case bestEffortLineSkipped(pageIndex: Int, lineID: String, reason: String)

    var errorDescription: String? { message }

    var requiresIncompleteOCRAcknowledgement: Bool {
        switch self {
        case .hybridOCRUnavailable,
             .rotatedHybridOCRUnsupported,
             .lowOCRConfidence,
             .ocrRequired,
             .rotatedOCRUnsupported,
             .pageHasNoTranslatableText:
            return true
        case .ocrApplied,
             .ocrDisabled,
             .hybridOCRApplied,
             .blockTranslationReflowed,
             .complexBackground,
             .backgroundSamplingUnavailable,
             .linkOverlap,
             .bestEffortLineSkipped:
            return false
        }
    }

    var message: String {
        switch self {
        case let .ocrApplied(pageIndex):
            return "\(pageIndex + 1)페이지는 이미지 문서여서 Vision OCR로 텍스트를 인식했습니다."
        case let .ocrDisabled(pageIndex):
            return "\(pageIndex + 1)페이지는 OCR을 제외해 PDF에 포함된 네이티브 텍스트만 분석했습니다. 이미지 안의 글자는 번역하지 않습니다."
        case let .hybridOCRApplied(pageIndex, addedLineCount):
            return "\(pageIndex + 1)페이지의 이미지 영역에서 OCR 문장 \(addedLineCount)개를 추가로 인식했습니다."
        case let .hybridOCRUnavailable(pageIndex):
            return "\(pageIndex + 1)페이지의 일반 텍스트는 추출했지만 이미지 안의 글자는 OCR 시스템을 사용할 수 없어 누락될 수 있습니다."
        case let .rotatedHybridOCRUnsupported(pageIndex, rotation):
            return "\(pageIndex + 1)페이지는 \(rotation)도 회전되어 이미지 영역의 OCR 위치를 안전하게 복원할 수 없습니다. 일반 PDF 텍스트만 번역합니다."
        case let .lowOCRConfidence(pageIndex, confidence):
            let percent = Int((confidence * 100).rounded())
            return "\(pageIndex + 1)페이지의 OCR 신뢰도가 낮습니다(최저 \(percent)%). 번역 전에 인식 결과를 확인해 주세요."
        case let .ocrRequired(pageIndex):
            return "\(pageIndex + 1)페이지에서 번역 가능한 텍스트를 찾지 못했습니다. 더 선명한 스캔본이나 별도 OCR 처리가 필요합니다."
        case let .rotatedOCRUnsupported(pageIndex, rotation):
            return "\(pageIndex + 1)페이지는 \(rotation)도 회전된 스캔 페이지라 안전한 위치 복원을 보장할 수 없어 OCR을 적용하지 않았습니다."
        case let .pageHasNoTranslatableText(pageIndex):
            return "\(pageIndex + 1)페이지에는 번역할 수 있는 텍스트가 없습니다."
        case let .blockTranslationReflowed(blockID):
            return "문단 \(blockID)의 번역문을 원래 줄 영역에 맞춰 재배치했습니다."
        case let .complexBackground(pageIndex, lineID):
            return "\(pageIndex + 1)페이지의 문장(\(lineID)) 배경이 복잡해 레이아웃 보존을 보장할 수 없으므로 출력 생성을 중단합니다."
        case let .backgroundSamplingUnavailable(pageIndex, lineID):
            return "\(pageIndex + 1)페이지의 문장(\(lineID)) 배경을 페이지 좌표에서 안전하게 추정할 수 없어 레이아웃 보존을 보장할 수 없으므로 출력 생성을 중단합니다."
        case let .linkOverlap(pageIndex, lineID, target):
            if let target, !target.isEmpty {
                return "\(pageIndex + 1)페이지의 문장(\(lineID))이 링크(\(target))와 겹칩니다. URL 클릭 동작을 번역 레이어에도 보존하지만 출력에서 확인해 주세요."
            }
            return "\(pageIndex + 1)페이지의 문장(\(lineID))이 링크와 겹쳐 번역 레이어가 클릭을 가릴 수 있습니다. 출력에서 링크 동작을 확인해 주세요."
        case let .bestEffortLineSkipped(pageIndex, lineID, reason):
            return "\(pageIndex + 1)페이지의 문장(\(lineID))은 \(reason) 최선 노력 출력에서 원문으로 남겼습니다."
        }
    }
}

enum PDFDocumentServiceError: Error, LocalizedError, Equatable, Sendable {
    case invalidFileType
    case cannotReadSource(String)
    case invalidPDF
    case emptyDocument
    case lockedDocument
    case changeDisallowed
    case signedDocument
    case interactiveFormsUnsupported
    case unsupportedPageRotation(pageIndex: Int, rotation: Int)
    case nonzeroMediaBoxOriginUnsupported(
        pageIndex: Int,
        minX: CGFloat,
        minY: CGFloat
    )
    case unsupportedOverlappingLink(pageIndex: Int, lineID: String)
    case unsupportedOverlappingAnnotation(
        pageIndex: Int,
        lineID: String,
        annotationType: String
    )
    case backgroundCannotBePreserved(pageIndex: Int, lineID: String)
    case sourceAndDestinationMatch
    case destinationAlreadyExists
    case invalidAnalysis(String)
    case missingTranslation(pageIndex: Int, lineID: String)
    case emptyTranslation(pageIndex: Int, lineID: String)
    case unsupportedTranslationCharacters(pageIndex: Int, lineID: String)
    case textDoesNotFit(pageIndex: Int, lineID: String, minimumFontSize: CGFloat)
    case cannotSerializeOutput
    case cannotWriteOutput(String)
    case outputValidationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFileType:
            return "PDF 파일만 번역할 수 있습니다."
        case let .cannotReadSource(reason):
            return "PDF 파일을 읽을 수 없습니다: \(reason)"
        case .invalidPDF:
            return "유효한 PDF 문서가 아닙니다."
        case .emptyDocument:
            return "페이지가 없는 PDF 문서는 번역할 수 없습니다."
        case .lockedDocument:
            return "암호로 잠긴 PDF 문서는 번역할 수 없습니다. 먼저 잠금을 해제해 주세요."
        case .changeDisallowed:
            return "변경이 허용되지 않은 PDF 문서는 번역할 수 없습니다. 문서 권한을 확인해 주세요."
        case .signedDocument:
            return "전자 서명된 PDF는 번역 시 서명이 무효화될 수 있어 처리하지 않습니다."
        case .interactiveFormsUnsupported:
            return "입력 가능한 양식이 포함된 PDF는 양식 표시를 완전히 보존할 수 없어 처리하지 않습니다. 양식을 평면화한 사본을 사용해 주세요."
        case let .unsupportedPageRotation(pageIndex, rotation):
            return "\(pageIndex + 1)페이지의 회전값(\(rotation)도)은 지원하지 않습니다. 페이지 회전을 0도, 90도, 180도 또는 270도로 평면화한 사본을 사용해 주세요."
        case let .nonzeroMediaBoxOriginUnsupported(pageIndex, minX, minY):
            return "\(pageIndex + 1)페이지의 MediaBox 원점(\(Self.coordinate(minX)), \(Self.coordinate(minY)))이 0이 아니어서 번역문 위치를 안전하게 보존할 수 없습니다. MediaBox 원점이 (0, 0)인 사본을 사용해 주세요."
        case let .unsupportedOverlappingLink(pageIndex, lineID):
            return "\(pageIndex + 1)페이지의 문장(\(lineID))에 단일 URL로 안전하게 복제할 수 없는 링크가 겹쳐 출력을 만들지 않았습니다."
        case let .unsupportedOverlappingAnnotation(
            pageIndex,
            lineID,
            annotationType
        ):
            return "\(pageIndex + 1)페이지의 문장(\(lineID))에 기존 \(annotationType) 주석이 겹쳐 표시와 상호작용을 보존할 수 없으므로 출력을 만들지 않았습니다."
        case let .backgroundCannotBePreserved(pageIndex, lineID):
            return "\(pageIndex + 1)페이지의 문장(\(lineID)) 배경을 단색 마스크로 안전하게 보존할 수 없어 출력을 만들지 않았습니다."
        case .sourceAndDestinationMatch:
            return "원본 PDF를 덮어쓸 수 없습니다. 다른 저장 위치를 선택해 주세요."
        case .destinationAlreadyExists:
            return "같은 이름의 출력 파일이 이미 있습니다. 다른 이름을 선택해 주세요."
        case let .invalidAnalysis(reason):
            return "PDF 분석 결과가 올바르지 않습니다: \(reason)"
        case let .missingTranslation(pageIndex, lineID):
            return "\(pageIndex + 1)페이지의 문장(\(lineID))에 대한 번역 결과가 없습니다."
        case let .emptyTranslation(pageIndex, lineID):
            return "\(pageIndex + 1)페이지의 문장(\(lineID)) 번역 결과가 비어 있습니다."
        case let .unsupportedTranslationCharacters(pageIndex, lineID):
            return "\(pageIndex + 1)페이지의 번역문(\(lineID))을 모두 표시할 수 있는 글꼴을 찾지 못했습니다."
        case let .textDoesNotFit(pageIndex, lineID, minimumFontSize):
            return "\(pageIndex + 1)페이지의 번역문(\(lineID))이 최소 글자 크기 \(minimumFontSize)pt에서도 원래 영역에 들어가지 않습니다. 번역문을 줄여 주세요."
        case .cannotSerializeOutput:
            return "번역 PDF 데이터를 생성하지 못했습니다."
        case let .cannotWriteOutput(reason):
            return "번역 PDF를 저장하지 못했습니다: \(reason)"
        case let .outputValidationFailed(reason):
            return "저장된 번역 PDF 검증에 실패했습니다: \(reason)"
        }
    }

    private static func coordinate(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }
}
