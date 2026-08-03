import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit

/// Native macOS PDF scene extractor. PDFKit supplies reliable text geometry
/// while Core Graphics supplies page rendering, resource/image inspection and
/// a conservative path trace. Unsupported compositing remains in the opaque
/// page safety net instead of being silently discarded or blended twice.
struct PDFSceneExtractor {
    let maximumRasterDimension: CGFloat

    init(maximumRasterDimension: CGFloat = 2_400) {
        self.maximumRasterDimension = max(1_024, maximumRasterDimension)
    }

    func extract(
        sourceURL: URL,
        layoutTarget: PDFOfficeLayoutTarget = .presentation
    ) throws -> PDFSceneDocument {
        guard sourceURL.isFileURL,
              sourceURL.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
        else {
            throw DocumentConversionError.sourceNotPDF
        }
        try Task.checkCancellation()
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        } catch {
            throw DocumentConversionError.sourceUnavailable
        }
        guard let document = PDFDocument(data: data) else {
            throw DocumentConversionError.invalidPDF
        }
        guard !document.isLocked else {
            throw DocumentConversionError.lockedPDF
        }
        guard document.pageCount > 0 else {
            throw DocumentConversionError.emptyPDF
        }

        let sha = Self.sha256(data)
        let analysis = try? PDFDocumentAnalysisService(
            includeOCR: true,
            maximumOCRImageDimension: 2_400,
            requiresSourceMaskHaloValidation: true
        ).analyze(sourceURL: sourceURL)

        var pages: [PDFScenePage] = []
        pages.reserveCapacity(document.pageCount)
        var documentWarnings = analysis?.warnings.map(\.message) ?? []

        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw DocumentConversionError.invalidPDF
            }
            let cropBox = page.bounds(for: .cropBox)
            let pageAnalysis = analysis?.pages[safe: pageIndex]
            let textBoxes = Self.textBoxes(
                from: pageAnalysis,
                layoutTarget: layoutTarget
            )
            let replacementLineIDs = Set(
                textBoxes
                    .filter { $0.visualPolicy == .replaceSourcePaint }
                    .flatMap(\.sourceLineIDs)
            )
            let masks = pageAnalysis?.lines.filter {
                replacementLineIDs.contains($0.id)
            }.map {
                ($0.sourceMaskBounds, $0.backgroundColor)
            } ?? []
            let imageData = try renderPage(
                page,
                cropBox: cropBox,
                masks: masks
            )
            let graphics = PDFGraphicsTrace.trace(
                page: page,
                cropBox: cropBox,
                pageSafetyNetPNG: imageData
            )
            let imageSummary = PDFImageExtractor.extract(
                page: page,
                pageIndex: pageIndex,
                cropBox: cropBox,
                maximumDimension: maximumRasterDimension,
                pageSafetyNetPNG: imageData
            )

            var pageWarnings = pageAnalysis?.warnings.map(\.message) ?? []
            let preservedTextBoxCount = textBoxes.filter {
                $0.visualPolicy == .preserveSourcePaint
            }.count
            if preservedTextBoxCount > 0 {
                pageWarnings.append(
                    "\(preservedTextBoxCount)개 텍스트 상자는 글꼴·배경·OCR 안전성 검증을 통과하지 않아 원본 페이지 이미지를 보존했습니다."
                )
            }
            if pageAnalysis == nil {
                pageWarnings.append("PDFKit 텍스트 분석을 사용할 수 없어 페이지 래스터 안전망을 보존했습니다.")
            }
            if imageSummary.imageOccurrenceCount > 0 {
                pageWarnings.append(
                    "페이지의 \(imageSummary.imageOccurrenceCount)개 이미지 occurrence를 검사했습니다. \(imageSummary.extractedImageCount)개는 PNG asset으로 추출했고, 복합 alpha/마스크 합성은 페이지 래스터 안전망으로 함께 보존했습니다."
                )
            }
            if graphics.vectors.isEmpty == false {
                pageWarnings.append(
                    "\(graphics.vectors.count)개 PDF 경로를 추적했습니다. 네이티브로 복원되지 않은 합성은 페이지 래스터 안전망을 기준으로 보존했습니다."
                )
            }

            let templates = Self.templateObjects(
                cropBox: cropBox,
                textBoxes: textBoxes,
                imageOccurrenceCount: imageSummary.imageOccurrenceCount,
                pageIndex: pageIndex,
                pageImageData: imageData
            )
            let usesFallback = true
            let pageID = "scene-page-\(pageIndex + 1)-\(Self.shortHash(String(describing: cropBox)))"
            let scenePage = PDFScenePage(
                id: pageID,
                pageIndex: pageIndex,
                cropBox: cropBox,
                rotation: page.rotation,
                pageImagePNG: imageData,
                textBoxes: textBoxes,
                images: imageSummary.images,
                vectors: graphics.vectors,
                templateObjects: templates,
                imageOccurrenceCount: imageSummary.imageOccurrenceCount,
                extractedImageCount: imageSummary.extractedImageCount,
                nativeVectorCount: graphics.vectors.filter(\.nativeEligible).count,
                warnings: pageWarnings,
                usesPageRasterFallback: usesFallback
            )
            pages.append(scenePage)
            documentWarnings.append(contentsOf: pageWarnings)
        }

        let classifiedPages = Self.classifyRepeatedTemplates(in: pages)
        return PDFSceneDocument(
            sourceURL: sourceURL.standardizedFileURL,
            sourceSHA256: sha,
            pages: classifiedPages,
            warnings: Self.deduplicated(documentWarnings)
        )
    }
}

private extension PDFSceneExtractor {
    static func textBoxes(
        from page: PDFPageAnalysis?,
        layoutTarget: PDFOfficeLayoutTarget
    ) -> [PDFSceneTextBox] {
        guard let page else { return [] }
        return page.blocks.compactMap { block -> PDFSceneTextBox? in
            let lines = block.lineIDs.compactMap { id in
                page.lines.first(where: { $0.id == id })
            }
            guard let firstLine = lines.first,
                  !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            let sceneLines = lines.enumerated().map { index, line in
                let sourceRuns = line.runs.isEmpty
                    ? [
                        PDFTextRun(
                            text: line.text,
                            fontName: line.fontName,
                            fontSize: line.fontSize,
                            textColor: line.textColor,
                            isOfficeCompatible: false
                        )
                    ]
                    : line.runs
                let listTabStop = PDFOfficeTextAppearance.listTabStop(
                    for: line,
                    continuations: Array(lines.dropFirst(index + 1))
                )
                let officeRuns = listTabStop.map { targetTextOffset in
                    PDFOfficeTextAppearance.runsReplacingListWhitespace(
                        sourceRuns,
                        targetTextOffset: targetTextOffset
                    )
                } ?? sourceRuns
                return PDFSceneTextLine(
                    id: line.id,
                    text: line.text,
                    bounds: line.bounds,
                    runs: officeRuns.map(PDFSceneTextRun.init),
                    sourceMaskBounds: line.sourceMaskBounds,
                    sourceMaskIsSafe: line.sourceMaskIsSafe,
                    extractionSource: line.extractionSource,
                    listTabStop: listTabStop
                )
            }
            let primaryRun = sceneLines.first?.runs.first
            let layoutBounds = PDFOfficeTextAppearance.officeLayoutBounds(
                for: lines,
                sourceBounds: block.bounds,
                alignment: firstLine.alignment,
                cropBox: page.cropBox,
                layoutTarget: layoutTarget
            )
            return PDFSceneTextBox(
                id: block.id,
                // Preserve visual PDF lines inside a single Office text box.
                // Joining with spaces here was the primary cause of changed
                // wrapping, clipped tails, and font substitutions in DOCX.
                text: lines.map(\.text).joined(separator: "\n"),
                bounds: block.bounds,
                layoutBounds: layoutBounds,
                fontName: primaryRun?.fontName ?? firstLine.fontName,
                fontSize: max(5, primaryRun?.fontSize ?? firstLine.fontSize),
                color: primaryRun?.color ?? firstLine.textColor,
                alignment: firstLine.alignment,
                lineCount: lines.count,
                sourceLineIDs: block.lineIDs,
                extractionSource: lines.contains(where: {
                    $0.extractionSource == .visionOCR
                }) ? .visionOCR : .native,
                lines: sceneLines,
                visualPolicy: PDFOfficeTextAppearance.canReplaceSourcePaint(
                    lines: lines
                ) ? .replaceSourcePaint : .preserveSourcePaint
            )
        }
    }

    func renderPage(
        _ page: PDFPage,
        cropBox: CGRect,
        masks: [(CGRect?, PDFTextColor)]
    ) throws -> Data {
        let longestSide = max(cropBox.width, cropBox.height)
        let scale = min(3.0, maximumRasterDimension / max(1, longestSide))
        let width = max(1, Int((cropBox.width * scale).rounded(.up)))
        let height = max(1, Int((cropBox.height * scale).rounded(.up)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw DocumentConversionError.packageWriteFailed("sRGB 색 공간을 만들 수 없습니다.")
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw DocumentConversionError.packageWriteFailed("페이지 렌더 컨텍스트를 만들 수 없습니다.")
        }
        // An Office document page is an opaque visual canvas. Keeping this
        // fallback page image transparent looks equivalent in a PDF viewer,
        // but Word/LibreOffice re-encode its soft mask and can expose erased
        // text rectangles as faint seams. Flatten only this visual safety-net
        // against the page canvas; extracted image assets retain alpha/masks.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        // A bitmap CGContext and PDF page both use a bottom-left coordinate
        // system here.  Flipping it before PDFKit draws the page mirrors the
        // raster vertically; that error is hidden on text-only pages once
        // masks are applied, but corrupts images, watermarks and any unmasked
        // fallback content.  Keep the native orientation and transform only
        // for scale/crop.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -cropBox.minX, y: -cropBox.minY)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()

        // Replace original glyph paint only where PDFKit was able to estimate
        // a stable backdrop.  The final compositing color is sampled from the
        // actual RGBA page render, not from the opaque analysis bitmap.  That
        // distinction matters for a PDF with a transparent page canvas: an
        // opaque white mask leaves visible seams after Office scales the PNG.
        for (optionalBounds, fallbackColor) in masks {
            guard let bounds = optionalBounds,
                  !bounds.isNull,
                  bounds.width > 0,
                  bounds.height > 0
            else { continue }
            let rawPixelRect = CGRect(
                x: (bounds.minX - cropBox.minX) * scale,
                y: (bounds.minY - cropBox.minY) * scale,
                width: bounds.width * scale,
                height: bounds.height * scale
            )
            let pagePixels = CGRect(x: 0, y: 0, width: width, height: height)
            // PDF selection rectangles can end on a glyph's antialiased top
            // or bottom pixel.  Clear one *raster* pixel beyond the verified
            // source mask so that a surviving antialias fringe cannot appear
            // as a faint line under the editable Office text.  Keeping this
            // in pixel space makes the bleed smaller at higher render scales
            // and avoids a page-unit heuristic that could eat nearby artwork.
            let pixelRect = rawPixelRect
                .insetBy(dx: -1, dy: -1)
                .integral
                .intersection(pagePixels)
            guard !pixelRect.isNull,
                  pixelRect.width > 0,
                  pixelRect.height > 0
            else { continue }

            let background = renderedBackdropColor(
                in: context,
                near: pixelRect
            ) ?? fallbackColor
            context.saveGState()
            context.setShouldAntialias(false)
            // Source-over cannot restore a sampled backdrop after text glyphs
            // were already drawn. Copy the rendered colour exactly. The page
            // safety-net is intentionally opaque so a source-mask edge stays
            // invisible to Office's PNG importer.
            context.setBlendMode(.copy)
            context.setFillColor(
                CGColor(
                    red: background.red,
                    green: background.green,
                    blue: background.blue,
                    alpha: 1
                )
            )
            context.fill(pixelRect)
            context.restoreGState()
        }

        guard let image = makeOpaquePagePNGImage(
            from: context,
            colorSpace: colorSpace
        ) ?? context.makeImage() else {
            throw DocumentConversionError.packageWriteFailed("페이지 이미지를 생성하지 못했습니다.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw DocumentConversionError.packageWriteFailed("PNG 인코더를 만들지 못했습니다.")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyPNGInterlaceType: false
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw DocumentConversionError.packageWriteFailed("PNG 인코딩에 실패했습니다.")
        }
        return output as Data
    }

    /// Creates an opaque RGB page image for Office. PDF pages may begin with
    /// transparent pixels, but DOCX/PPTX pages are displayed on an opaque
    /// canvas. Serializing the fallback as RGBA makes some Office renderers
    /// resample its soft mask separately from colour data, revealing source
    /// mask seams. Native images with alpha remain separate PNG assets; this
    /// affects only the full-page visual safety net.
    func makeOpaquePagePNGImage(
        from context: CGContext,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        guard context.bitsPerComponent == 8,
              context.bytesPerRow >= context.width * 4,
              let source = context.data
        else {
            return nil
        }
        let byteCount = context.bytesPerRow * context.height
        var opaquePixels = Data(count: byteCount)
        let sourcePixels = source.assumingMemoryBound(to: UInt8.self)
        opaquePixels.withUnsafeMutableBytes { destination in
            guard let destinationPixels = destination.baseAddress?
                .assumingMemoryBound(to: UInt8.self)
            else { return }
            for y in 0..<context.height {
                for x in 0..<context.width {
                    let offset = y * context.bytesPerRow + x * 4
                    let alpha = sourcePixels[offset + 3]
                    if alpha == 0 {
                        destinationPixels[offset] = 255
                        destinationPixels[offset + 1] = 255
                        destinationPixels[offset + 2] = 255
                    } else {
                        // The context starts from opaque white, so alpha is
                        // expected to be one. Retain a defensive unpremultiply
                        // path for malformed PDF blend state.
                        let multiplier = 255.0 / Double(alpha)
                        destinationPixels[offset] = UInt8(min(
                            255,
                            Int((Double(sourcePixels[offset]) * multiplier).rounded())
                        ))
                        destinationPixels[offset + 1] = UInt8(min(
                            255,
                            Int((Double(sourcePixels[offset + 1]) * multiplier).rounded())
                        ))
                        destinationPixels[offset + 2] = UInt8(min(
                            255,
                            Int((Double(sourcePixels[offset + 2]) * multiplier).rounded())
                        ))
                    }
                    destinationPixels[offset + 3] = 255
                }
            }
        }
        guard let provider = CGDataProvider(data: opaquePixels as CFData) else {
            return nil
        }
        return CGImage(
            width: context.width,
            height: context.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: context.bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Finds the dominant rendered pixel in a source-mask rectangle. The
    /// analysis service uses an independent bitmap while judging background
    /// complexity; this helper samples the final Office page compositor so
    /// replacement paint exactly matches its flattened visual backdrop.
    func renderedBackdropColor(
        in context: CGContext,
        near pixelRect: CGRect
    ) -> PDFTextColor? {
        guard context.bitsPerComponent == 8,
              context.bytesPerRow >= context.width * 4,
              let data = context.data
        else {
            return nil
        }

        let minimumX = max(0, Int(pixelRect.minX.rounded(.down)))
        let maximumX = min(context.width - 1, Int(pixelRect.maxX.rounded(.up)) - 1)
        let minimumY = max(0, Int(pixelRect.minY.rounded(.down)))
        let maximumY = min(context.height - 1, Int(pixelRect.maxY.rounded(.up)) - 1)
        guard minimumX <= maximumX, minimumY <= maximumY else { return nil }

        let pixelCount = (maximumX - minimumX + 1) * (maximumY - minimumY + 1)
        let sampleStride = max(1, Int(sqrt(Double(pixelCount) / 4_096.0)))
        var frequencies: [RGBABin: Int] = [:]

        for y in stride(from: minimumY, through: maximumY, by: sampleStride) {
            for x in stride(from: minimumX, through: maximumX, by: sampleStride) {
                let offset = y * context.bytesPerRow + x * 4
                let pixel = data.assumingMemoryBound(to: UInt8.self)
                    .advanced(by: offset)
                let alpha = CGFloat(pixel[3]) / 255.0
                let divisor = max(alpha, 1.0 / 255.0)
                let red = alpha <= 1.0 / 255.0
                    ? 0
                    : min(1, CGFloat(pixel[0]) / 255.0 / divisor)
                let green = alpha <= 1.0 / 255.0
                    ? 0
                    : min(1, CGFloat(pixel[1]) / 255.0 / divisor)
                let blue = alpha <= 1.0 / 255.0
                    ? 0
                    : min(1, CGFloat(pixel[2]) / 255.0 / divisor)
                frequencies[RGBABin(
                    red: red,
                    green: green,
                    blue: blue,
                    alpha: alpha
                ), default: 0] += 1
            }
        }

        guard let dominant = frequencies.max(by: { $0.value < $1.value })?.key
        else { return nil }
        return dominant.color
    }

    struct RGBABin: Hashable {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int

        init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
            func quantize(_ value: CGFloat) -> Int {
                Int((max(0, min(1, value)) * 31).rounded())
            }
            self.red = quantize(red)
            self.green = quantize(green)
            self.blue = quantize(blue)
            self.alpha = quantize(alpha)
        }

        var color: PDFTextColor {
            PDFTextColor(
                red: CGFloat(red) / 31.0,
                green: CGFloat(green) / 31.0,
                blue: CGFloat(blue) / 31.0,
                alpha: CGFloat(alpha) / 31.0
            )
        }
    }

    static func dictionary(
        _ dictionary: CGPDFDictionaryRef,
        key: String
    ) -> CGPDFDictionaryRef? {
        var result: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, key, &result) else {
            return nil
        }
        return result
    }

    static func templateObjects(
        cropBox: CGRect,
        textBoxes: [PDFSceneTextBox],
        imageOccurrenceCount: Int,
        pageIndex: Int,
        pageImageData: Data
    ) -> [PDFSceneTemplateObject] {
        let fullPageArea = max(1, cropBox.width * cropBox.height)
        let textArea = textBoxes.reduce(CGFloat.zero) { $0 + $1.bounds.width * $1.bounds.height }
        let remainingArea = max(0, fullPageArea - textArea)
        guard imageOccurrenceCount > 0 || textBoxes.isEmpty else {
            return []
        }
        let confidence = min(0.95, max(0.52, Double(remainingArea / fullPageArea)))
        return [
            PDFSceneTemplateObject(
                id: "page-template-\(pageIndex + 1)",
                role: .pageLocalBackground,
                bounds: cropBox,
                confidence: confidence,
                sourceFingerprint: backgroundFingerprint(pageImageData)
            )
        ]
    }

    static func backgroundFingerprint(_ pageImageData: Data) -> String {
        guard let source = CGImageSourceCreateWithData(pageImageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return sha256(pageImageData)
        }
        let size = 32
        var pixels = Array(repeating: UInt8(0), count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return sha256(pageImageData)
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        var border = Data()
        for y in 0..<size where y < 3 || y >= size - 3 {
            for x in 0..<size {
                let offset = (y * size + x) * 4
                border.append(pixels[offset] & 0xF0)
                border.append(pixels[offset + 1] & 0xF0)
                border.append(pixels[offset + 2] & 0xF0)
                border.append(pixels[offset + 3] & 0xF0)
            }
        }
        for x in 0..<size {
            for y in 3..<(size - 3) {
                let offset = (y * size + x) * 4
                border.append(pixels[offset] & 0xF0)
                border.append(pixels[offset + 1] & 0xF0)
                border.append(pixels[offset + 2] & 0xF0)
                border.append(pixels[offset + 3] & 0xF0)
            }
        }
        return sha256(border)
    }

    static func classifyRepeatedTemplates(
        in pages: [PDFScenePage]
    ) -> [PDFScenePage] {
        let grouped = Dictionary(grouping: pages.indices) { index in
            pages[index].templateObjects.first?.sourceFingerprint
        }
        var classified = pages
        for indices in grouped.values where indices.count > 1 {
            for index in indices {
                let page = pages[index]
                let templates = page.templateObjects.map { object in
                    PDFSceneTemplateObject(
                        id: object.id,
                        role: .sharedTemplate,
                        bounds: object.bounds,
                        confidence: min(0.99, object.confidence + 0.08),
                        sourceFingerprint: object.sourceFingerprint
                    )
                }
                classified[index] = PDFScenePage(
                    id: page.id,
                    pageIndex: page.pageIndex,
                    cropBox: page.cropBox,
                    rotation: page.rotation,
                    pageImagePNG: page.pageImagePNG,
                    textBoxes: page.textBoxes,
                    images: page.images,
                    vectors: page.vectors,
                    templateObjects: templates,
                    imageOccurrenceCount: page.imageOccurrenceCount,
                    extractedImageCount: page.extractedImageCount,
                    nativeVectorCount: page.nativeVectorCount,
                    warnings: page.warnings,
                    usesPageRasterFallback: page.usesPageRasterFallback
                )
            }
        }
        return classified
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func shortHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private final class PDFGraphicsTrace {
    /// Only the PDF device colour spaces have a direct, lossless mapping to
    /// OOXML RGB. Resource-backed ICC, Separation, Pattern, and Indexed
    /// spaces remain in the page safety-net unless a dedicated colour-managed
    /// converter is available; guessing them as black caused opaque boxes in
    /// converted slides.
    enum SimpleColorSpace {
        case deviceGray
        case deviceRGB
        case deviceCMYK
        case unsupported

        var componentCount: Int? {
            switch self {
            case .deviceGray: 1
            case .deviceRGB: 3
            case .deviceCMYK: 4
            case .unsupported: nil
            }
        }

        static func named(_ rawName: String) -> Self {
            switch rawName {
            case "DeviceGray", "G": .deviceGray
            case "DeviceRGB", "RGB": .deviceRGB
            case "DeviceCMYK", "CMYK": .deviceCMYK
            default: .unsupported
            }
        }
    }

    struct Result {
        let vectors: [PDFSceneVector]
    }

    struct PendingRectangle {
        let bounds: CGRect
        let rotation: CGFloat
    }

    var pendingRectangles: [PendingRectangle] = []
    var currentPath: [CGPoint] = []
    var vectors: [PDFSceneVector] = []
    var paintOrder = 0
    var transform = CGAffineTransform.identity
    struct GraphicsState {
        let transform: CGAffineTransform
        let fillColor: PDFTextColor
        let strokeColor: PDFTextColor
        let lineWidth: CGFloat
        let fillColorIsKnown: Bool
        let strokeColorIsKnown: Bool
        let fillColorSpace: SimpleColorSpace
        let strokeColorSpace: SimpleColorSpace
        let hasActiveClippingPath: Bool
        let usesUnsupportedGraphicsState: Bool
    }
    var stateStack: [GraphicsState] = []
    var fillColor = PDFTextColor.black
    var strokeColor = PDFTextColor.black
    var lineWidth: CGFloat = 1
    // PDF defaults colors to black, but a converter must never treat a color
    // that it did not parse as an intentional black fill/stroke.
    var fillColorIsKnown = false
    var strokeColorIsKnown = false
    var fillColorSpace: SimpleColorSpace = .deviceGray
    var strokeColorSpace: SimpleColorSpace = .deviceGray
    // These flags apply to the current path. A clipping path or unsupported
    // curve must be preserved by the page raster rather than approximated as
    // a rectangular OOXML shape.
    var pathUsesClipping = false
    var pathHasUnsupportedGeometry = false
    // A `W`/`W*` clip remains in effect after the current path is ended. It is
    // part of the graphics state, not the path itself, so it must survive the
    // following `n` and only unwind on `Q`.
    var hasActiveClippingPath = false
    var usesUnsupportedGraphicsState = false

    static func trace(
        page: PDFPage,
        cropBox: CGRect,
        pageSafetyNetPNG: Data
    ) -> Result {
        guard let pageRef = page.pageRef,
              let table = CGPDFOperatorTableCreate()
        else {
            return Result(vectors: [])
        }
        let stream = CGPDFContentStreamCreateWithPage(pageRef)
        let trace = PDFGraphicsTrace()
        let info = Unmanaged.passUnretained(trace).toOpaque()
        CGPDFOperatorTableSetCallback(table, "q", pdfTraceSave)
        CGPDFOperatorTableSetCallback(table, "Q", pdfTraceRestore)
        CGPDFOperatorTableSetCallback(table, "cm", pdfTraceConcat)
        CGPDFOperatorTableSetCallback(table, "rg", pdfTraceFillRGB)
        CGPDFOperatorTableSetCallback(table, "RG", pdfTraceStrokeRGB)
        CGPDFOperatorTableSetCallback(table, "g", pdfTraceFillGray)
        CGPDFOperatorTableSetCallback(table, "G", pdfTraceStrokeGray)
        CGPDFOperatorTableSetCallback(table, "k", pdfTraceFillCMYK)
        CGPDFOperatorTableSetCallback(table, "K", pdfTraceStrokeCMYK)
        CGPDFOperatorTableSetCallback(table, "w", pdfTraceLineWidth)
        CGPDFOperatorTableSetCallback(table, "m", pdfTraceMove)
        CGPDFOperatorTableSetCallback(table, "l", pdfTraceLine)
        CGPDFOperatorTableSetCallback(table, "h", pdfTraceClosePath)
        CGPDFOperatorTableSetCallback(table, "n", pdfTraceEndPath)
        CGPDFOperatorTableSetCallback(table, "W", pdfTraceClip)
        CGPDFOperatorTableSetCallback(table, "W*", pdfTraceClip)
        CGPDFOperatorTableSetCallback(table, "re", pdfTraceRectangle)
        CGPDFOperatorTableSetCallback(table, "S", pdfTraceStroke)
        CGPDFOperatorTableSetCallback(table, "s", pdfTraceStroke)
        CGPDFOperatorTableSetCallback(table, "f", pdfTraceFill)
        CGPDFOperatorTableSetCallback(table, "F", pdfTraceFill)
        CGPDFOperatorTableSetCallback(table, "f*", pdfTraceFill)
        CGPDFOperatorTableSetCallback(table, "B", pdfTraceFillStroke)
        CGPDFOperatorTableSetCallback(table, "B*", pdfTraceFillStroke)
        CGPDFOperatorTableSetCallback(table, "b", pdfTraceFillStroke)
        CGPDFOperatorTableSetCallback(table, "b*", pdfTraceFillStroke)
        CGPDFOperatorTableSetCallback(table, "cs", pdfTraceUnknownFillColor)
        CGPDFOperatorTableSetCallback(table, "CS", pdfTraceUnknownStrokeColor)
        CGPDFOperatorTableSetCallback(table, "sc", pdfTraceFillComponents)
        CGPDFOperatorTableSetCallback(table, "SC", pdfTraceStrokeComponents)
        CGPDFOperatorTableSetCallback(table, "scn", pdfTraceFillComponents)
        CGPDFOperatorTableSetCallback(table, "SCN", pdfTraceStrokeComponents)
        CGPDFOperatorTableSetCallback(table, "gs", pdfTraceUnsupportedGraphicsState)
        CGPDFOperatorTableSetCallback(table, "c", pdfTraceUnsupportedCubicPath)
        CGPDFOperatorTableSetCallback(table, "v", pdfTraceUnsupportedQuadraticPath)
        CGPDFOperatorTableSetCallback(table, "y", pdfTraceUnsupportedQuadraticPath)
        let scanner = CGPDFScannerCreate(stream, table, info)
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        let safetyNet = NSBitmapImageRep(data: pageSafetyNetPNG)
        let verifiedVectors = trace.vectors.map { vector in
            PDFSceneVector(
                id: vector.id,
                kind: vector.kind,
                bounds: vector.bounds,
                stroke: vector.stroke,
                fill: vector.fill,
                lineWidth: vector.lineWidth,
                rotation: vector.rotation,
                paintOrder: vector.paintOrder,
                nativeEligible: vector.nativeEligible,
                isSafetyNetVerifiedOpaque: vectorMatchesSafetyNet(
                    vector,
                    cropBox: cropBox,
                    bitmap: safetyNet
                )
            )
        }
        return Result(vectors: verifiedVectors)
    }

    func rectangle(_ scanner: CGPDFScannerRef) {
        var h: CGPDFReal = 0
        var w: CGPDFReal = 0
        var y: CGPDFReal = 0
        var x: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &h),
              CGPDFScannerPopNumber(scanner, &w),
              CGPDFScannerPopNumber(scanner, &y),
              CGPDFScannerPopNumber(scanner, &x)
        else { return }
        let rect = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
        guard rect.width.isFinite, rect.height.isFinite,
              abs(rect.width) > 0.25, abs(rect.height) > 0.25,
              abs(rect.width) < 100_000, abs(rect.height) < 100_000
        else { return }
        let transformed = rect.applying(transform).standardized
        guard !transformed.isNull,
              transformed.width > 0.25,
              transformed.height > 0.25
        else { return }
        let rotation = atan2(transform.b, transform.a) * 180 / .pi
        if !currentPath.isEmpty {
            pathHasUnsupportedGeometry = true
        }
        pendingRectangles.append(
            PendingRectangle(
                bounds: transformed,
                rotation: rotation
            )
        )
    }

    func move(_ scanner: CGPDFScannerRef) {
        guard let point = popPoint(scanner) else { return }
        if !currentPath.isEmpty || !pendingRectangles.isEmpty {
            pathHasUnsupportedGeometry = true
        }
        currentPath = [point]
    }

    func line(_ scanner: CGPDFScannerRef) {
        guard let point = popPoint(scanner), !currentPath.isEmpty else {
            pathHasUnsupportedGeometry = true
            return
        }
        currentPath.append(point)
        if currentPath.count > 2 {
            pathHasUnsupportedGeometry = true
        }
    }

    func closePath() {
        // Closed paths require a polygon serializer. Do not turn their last
        // segment into a standalone OOXML line.
        pathHasUnsupportedGeometry = true
    }

    func endPath() {
        resetCurrentPath()
    }

    func stroke() {
        emitPending(fill: nil, emitsStroke: true)
    }

    func fill() {
        emitPending(fill: fillColor, emitsStroke: false)
    }

    func fillStroke() {
        emitPending(fill: fillColor, emitsStroke: true)
    }

    func clip() {
        pathUsesClipping = true
        hasActiveClippingPath = true
    }

    func selectFillColorSpace(named name: String?) {
        fillColorSpace = name.map(SimpleColorSpace.named) ?? .unsupported
        fillColorIsKnown = false
    }

    func selectStrokeColorSpace(named name: String?) {
        strokeColorSpace = name.map(SimpleColorSpace.named) ?? .unsupported
        strokeColorIsKnown = false
    }

    func setFillComponents(_ scanner: CGPDFScannerRef) {
        guard let color = popComponents(
            scanner,
            colorSpace: fillColorSpace,
            alpha: fillColor.alpha
        ) else {
            fillColorIsKnown = false
            return
        }
        fillColor = color
        fillColorIsKnown = true
    }

    func setStrokeComponents(_ scanner: CGPDFScannerRef) {
        guard let color = popComponents(
            scanner,
            colorSpace: strokeColorSpace,
            alpha: strokeColor.alpha
        ) else {
            strokeColorIsKnown = false
            return
        }
        strokeColor = color
        strokeColorIsKnown = true
    }

    func markUnsupportedGraphicsState() {
        usesUnsupportedGraphicsState = true
    }

    func markUnsupportedPath() {
        pathHasUnsupportedGeometry = true
    }

    func save() {
        stateStack.append(
            GraphicsState(
                transform: transform,
                fillColor: fillColor,
                strokeColor: strokeColor,
                lineWidth: lineWidth,
                fillColorIsKnown: fillColorIsKnown,
                strokeColorIsKnown: strokeColorIsKnown,
                fillColorSpace: fillColorSpace,
                strokeColorSpace: strokeColorSpace,
                hasActiveClippingPath: hasActiveClippingPath,
                usesUnsupportedGraphicsState: usesUnsupportedGraphicsState
            )
        )
    }

    func restore() {
        guard let state = stateStack.popLast() else {
            transform = .identity
            fillColor = .black
            strokeColor = .black
            lineWidth = 1
            fillColorIsKnown = false
            strokeColorIsKnown = false
            fillColorSpace = .deviceGray
            strokeColorSpace = .deviceGray
            hasActiveClippingPath = false
            usesUnsupportedGraphicsState = false
            resetCurrentPath()
            return
        }
        transform = state.transform
        fillColor = state.fillColor
        strokeColor = state.strokeColor
        lineWidth = state.lineWidth
        fillColorIsKnown = state.fillColorIsKnown
        strokeColorIsKnown = state.strokeColorIsKnown
        fillColorSpace = state.fillColorSpace
        strokeColorSpace = state.strokeColorSpace
        hasActiveClippingPath = state.hasActiveClippingPath
        usesUnsupportedGraphicsState = state.usesUnsupportedGraphicsState
    }

    func concatenate(_ scanner: CGPDFScannerRef) {
        var f: CGPDFReal = 0
        var e: CGPDFReal = 0
        var d: CGPDFReal = 0
        var c: CGPDFReal = 0
        var b: CGPDFReal = 0
        var a: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &f),
              CGPDFScannerPopNumber(scanner, &e),
              CGPDFScannerPopNumber(scanner, &d),
              CGPDFScannerPopNumber(scanner, &c),
              CGPDFScannerPopNumber(scanner, &b),
              CGPDFScannerPopNumber(scanner, &a)
        else { return }
        transform = transform.concatenating(
            CGAffineTransform(
                a: CGFloat(a), b: CGFloat(b), c: CGFloat(c), d: CGFloat(d),
                tx: CGFloat(e), ty: CGFloat(f)
            )
        )
    }

    func setFillRGB(_ scanner: CGPDFScannerRef) {
        fillColor = popRGB(scanner, alpha: fillColor.alpha)
        fillColorSpace = .deviceRGB
        fillColorIsKnown = true
    }

    func setStrokeRGB(_ scanner: CGPDFScannerRef) {
        strokeColor = popRGB(scanner, alpha: strokeColor.alpha)
        strokeColorSpace = .deviceRGB
        strokeColorIsKnown = true
    }

    func setFillGray(_ scanner: CGPDFScannerRef) {
        let gray = popNumber(scanner)
        fillColor = PDFTextColor(red: gray, green: gray, blue: gray, alpha: fillColor.alpha)
        fillColorSpace = .deviceGray
        fillColorIsKnown = true
    }

    func setStrokeGray(_ scanner: CGPDFScannerRef) {
        let gray = popNumber(scanner)
        strokeColor = PDFTextColor(red: gray, green: gray, blue: gray, alpha: strokeColor.alpha)
        strokeColorSpace = .deviceGray
        strokeColorIsKnown = true
    }

    func setFillCMYK(_ scanner: CGPDFScannerRef) {
        fillColor = popCMYK(scanner, alpha: fillColor.alpha)
        fillColorSpace = .deviceCMYK
        fillColorIsKnown = true
    }

    func setStrokeCMYK(_ scanner: CGPDFScannerRef) {
        strokeColor = popCMYK(scanner, alpha: strokeColor.alpha)
        strokeColorSpace = .deviceCMYK
        strokeColorIsKnown = true
    }

    func setLineWidth(_ scanner: CGPDFScannerRef) {
        let value = popRawNumber(scanner)
        lineWidth = max(0, min(1_000, value))
    }

    private func popRGB(_ scanner: CGPDFScannerRef, alpha: CGFloat) -> PDFTextColor {
        let blue = popNumber(scanner)
        let green = popNumber(scanner)
        let red = popNumber(scanner)
        return PDFTextColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private func popCMYK(_ scanner: CGPDFScannerRef, alpha: CGFloat) -> PDFTextColor {
        let key = popNumber(scanner)
        let yellow = popNumber(scanner)
        let magenta = popNumber(scanner)
        let cyan = popNumber(scanner)
        return PDFTextColor(
            red: 1 - min(1, cyan + key),
            green: 1 - min(1, magenta + key),
            blue: 1 - min(1, yellow + key),
            alpha: alpha
        )
    }

    private func popComponents(
        _ scanner: CGPDFScannerRef,
        colorSpace: SimpleColorSpace,
        alpha: CGFloat
    ) -> PDFTextColor? {
        guard let componentCount = colorSpace.componentCount else {
            // `scn`/`SCN` may carry an arbitrary Pattern or Separation name
            // in addition to colour components. A CGPDFScanner callback owns
            // the operator's operand stack, so leave no operands behind when
            // we intentionally decline that non-RGB colour space.
            discardRemainingOperands(scanner)
            return nil
        }
        var reversedComponents: [CGFloat] = []
        reversedComponents.reserveCapacity(componentCount)
        for _ in 0..<componentCount {
            var number: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &number) else {
                discardRemainingOperands(scanner)
                return nil
            }
            reversedComponents.append(min(1, max(0, CGFloat(number))))
        }
        let components = Array(reversedComponents.reversed())
        switch colorSpace {
        case .deviceGray:
            guard let gray = components.first else { return nil }
            return PDFTextColor(red: gray, green: gray, blue: gray, alpha: alpha)
        case .deviceRGB:
            guard components.count == 3 else { return nil }
            return PDFTextColor(
                red: components[0],
                green: components[1],
                blue: components[2],
                alpha: alpha
            )
        case .deviceCMYK:
            guard components.count == 4 else { return nil }
            return PDFTextColor(
                red: 1 - min(1, components[0] + components[3]),
                green: 1 - min(1, components[1] + components[3]),
                blue: 1 - min(1, components[2] + components[3]),
                alpha: alpha
            )
        case .unsupported:
            return nil
        }
    }

    private func discardRemainingOperands(_ scanner: CGPDFScannerRef) {
        var ignored: CGPDFObjectRef?
        while CGPDFScannerPopObject(scanner, &ignored) {}
    }

    private func popNumber(_ scanner: CGPDFScannerRef) -> CGFloat {
        min(1, max(0, popRawNumber(scanner)))
    }

    private func popRawNumber(_ scanner: CGPDFScannerRef) -> CGFloat {
        var number: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &number) else { return 0 }
        return CGFloat(number)
    }

    private func popPoint(_ scanner: CGPDFScannerRef) -> CGPoint? {
        var y: CGPDFReal = 0
        var x: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &y),
              CGPDFScannerPopNumber(scanner, &x) else {
            return nil
        }
        let point = CGPoint(x: CGFloat(x), y: CGFloat(y)).applying(transform)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }

    private func emitPending(
        fill: PDFTextColor?,
        emitsStroke: Bool
    ) {
        let canRepresentPath = !pathUsesClipping
            && !pathHasUnsupportedGeometry
            && !hasActiveClippingPath
            && !usesUnsupportedGraphicsState
        let selectedFill = canRepresentPath && fillColorIsKnown
            ? fill.flatMap { $0.alpha > 0 ? $0 : nil }
            : nil
        let selectedStroke = canRepresentPath
            && emitsStroke
            && strokeColorIsKnown
            && strokeColor.alpha > 0
            ? strokeColor
            : nil

        if canRepresentPath && (selectedFill != nil || selectedStroke != nil) {
            for rectangle in pendingRectangles {
                let eligible = rectangle.bounds.width.isFinite
                    && rectangle.bounds.height.isFinite
                    && lineWidth.isFinite
                    && lineWidth >= 0
                    && abs(rectangle.rotation.truncatingRemainder(dividingBy: 90)) < 0.01
                guard eligible else { continue }
                paintOrder += 1
                vectors.append(
                    PDFSceneVector(
                        id: "vector-\(paintOrder)",
                        kind: .rectangle,
                        bounds: rectangle.bounds,
                        stroke: selectedStroke,
                        fill: selectedFill,
                        lineWidth: lineWidth,
                        rotation: rectangle.rotation,
                        paintOrder: paintOrder,
                        nativeEligible: true,
                        isSafetyNetVerifiedOpaque: false
                    )
                )
            }
        }

        if canRepresentPath,
           selectedFill == nil,
           let selectedStroke,
           currentPath.count == 2,
           let first = currentPath.first,
           let last = currentPath.last {
            let dx = last.x - first.x
            let dy = last.y - first.y
            let length = hypot(dx, dy)
            let bounds = CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(dx),
                height: abs(dy)
            ).standardized
            let axisAligned = abs(dx) <= 0.25 || abs(dy) <= 0.25
            guard length > 0.25,
                  bounds.width.isFinite,
                  bounds.height.isFinite,
                  bounds.width < 100_000,
                  bounds.height < 100_000
            else {
                resetCurrentPath()
                return
            }
            paintOrder += 1
            vectors.append(
                PDFSceneVector(
                    id: "vector-\(paintOrder)",
                    kind: .line,
                    bounds: bounds,
                    stroke: selectedStroke,
                    fill: nil,
                    lineWidth: lineWidth,
                    rotation: atan2(dy, dx) * 180 / .pi,
                    paintOrder: paintOrder,
                    nativeEligible: axisAligned,
                    isSafetyNetVerifiedOpaque: false
                )
            )
        }
        resetCurrentPath()
    }

    private func resetCurrentPath() {
        pendingRectangles.removeAll(keepingCapacity: true)
        currentPath.removeAll(keepingCapacity: true)
        pathUsesClipping = false
        pathHasUnsupportedGeometry = false
    }

    private static func vectorMatchesSafetyNet(
        _ vector: PDFSceneVector,
        cropBox: CGRect,
        bitmap: NSBitmapImageRep?
    ) -> Bool {
        guard let bitmap,
              vector.nativeEligible,
              vector.kind == .rectangle,
              vector.stroke == nil,
              let fill = vector.fill,
              fill.alpha >= 0.999,
              cropBox.width > 0,
              cropBox.height > 0,
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0
        else {
            return false
        }

        let bounds = vector.bounds.intersection(cropBox)
        guard !bounds.isNull,
              bounds.width > 2,
              bounds.height > 2,
              bounds.width < cropBox.width * 0.95,
              bounds.height < cropBox.height * 0.95
        else {
            return false
        }

        let inset = min(bounds.width, bounds.height) * 0.12
        let interior = bounds.insetBy(dx: max(0.5, inset), dy: max(0.5, inset))
        guard interior.width > 1, interior.height > 1 else { return false }

        let columns = min(48, max(12, Int((interior.width / 8).rounded())))
        let rows = min(48, max(12, Int((interior.height / 8).rounded())))
        let scaleX = CGFloat(bitmap.pixelsWide) / cropBox.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / cropBox.height
        let fillRGB = [
            Int((fill.red * 255).rounded()),
            Int((fill.green * 255).rounded()),
            Int((fill.blue * 255).rounded())
        ]
        var mismatches = 0
        let samples = columns * rows

        for row in 0..<rows {
            let v = (CGFloat(row) + 0.5) / CGFloat(rows)
            let pageY = min(
                bitmap.pixelsHigh - 1,
                max(
                    0,
                    Int(((cropBox.maxY - (interior.maxY - v * interior.height)) * scaleY).rounded())
                )
            )
            for column in 0..<columns {
                let u = (CGFloat(column) + 0.5) / CGFloat(columns)
                let pageX = min(
                    bitmap.pixelsWide - 1,
                    max(
                        0,
                        Int((((interior.minX + u * interior.width) - cropBox.minX) * scaleX).rounded())
                    )
                )
                guard let color = bitmap.colorAt(x: pageX, y: pageY)?
                    .usingColorSpace(.deviceRGB)
                else {
                    return false
                }
                let observed = [
                    Int((color.redComponent * 255).rounded()),
                    Int((color.greenComponent * 255).rounded()),
                    Int((color.blueComponent * 255).rounded())
                ]
                let greatestDifference = zip(observed, fillRGB)
                    .map { abs($0 - $1) }
                    .max() ?? Int.max
                if greatestDifference > 12 {
                    mismatches += 1
                }
            }
        }

        return Double(mismatches) / Double(max(1, samples)) <= 0.01
    }
}

private func pdfTraceRectangle(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().rectangle(scanner)
}

private func pdfTraceSave(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().save()
}

private func pdfTraceRestore(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().restore()
}

private func pdfTraceConcat(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().concatenate(scanner)
}

private func pdfTraceFillRGB(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().setFillRGB(scanner)
}

private func pdfTraceStrokeRGB(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().setStrokeRGB(scanner)
}

private func pdfTraceFillGray(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().setFillGray(scanner)
}

private func pdfTraceStrokeGray(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().setStrokeGray(scanner)
}

private func pdfTraceFillCMYK(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().setFillCMYK(scanner)
}

private func pdfTraceStrokeCMYK(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().setStrokeCMYK(scanner)
}

private func pdfTraceLineWidth(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().setLineWidth(scanner)
}

private func pdfTraceMove(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().move(scanner)
}

private func pdfTraceLine(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().line(scanner)
}

private func pdfTraceClosePath(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().closePath()
}

private func pdfTraceEndPath(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().endPath()
}

private func pdfTraceClip(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().clip()
}

private func pdfTraceFillStroke(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().fillStroke()
}

private func pdfTraceUnknownFillColor(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    var name: UnsafePointer<CChar>?
    _ = CGPDFScannerPopName(scanner, &name)
    let selectedName = name.map { String(cString: $0) }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue()
        .selectFillColorSpace(named: selectedName)
}

private func pdfTraceUnknownStrokeColor(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    var name: UnsafePointer<CChar>?
    _ = CGPDFScannerPopName(scanner, &name)
    let selectedName = name.map { String(cString: $0) }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue()
        .selectStrokeColorSpace(named: selectedName)
}

private func pdfTraceFillComponents(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue()
        .setFillComponents(scanner)
}

private func pdfTraceStrokeComponents(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue()
        .setStrokeComponents(scanner)
}

private func pdfTraceUnsupportedGraphicsState(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    var ignored: UnsafePointer<CChar>?
    _ = CGPDFScannerPopName(scanner, &ignored)
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().markUnsupportedGraphicsState()
}

private func pdfTraceUnsupportedCubicPath(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    var ignored: CGPDFReal = 0
    for _ in 0..<6 {
        _ = CGPDFScannerPopNumber(scanner, &ignored)
    }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().markUnsupportedPath()
}

private func pdfTraceUnsupportedQuadraticPath(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    var ignored: CGPDFReal = 0
    for _ in 0..<4 {
        _ = CGPDFScannerPopNumber(scanner, &ignored)
    }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().markUnsupportedPath()
}

private func pdfTraceStroke(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().stroke()
}

private func pdfTraceFill(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue().fill()
}

/// Quartz exposes the decoded bytes of an image XObject, but not a convenient
/// "copy this PDF image" API. This small decoder handles the common native
/// image forms (JPEG/JPX and 1/8-bit DeviceGray/RGB/CMYK) and combines the
/// image's `/SMask` or `/Mask` into a straight-alpha PNG. Unsupported color
/// spaces are deliberately left in the page RGBA fallback instead of being
/// mislabelled as extracted data.
private enum PDFImageExtractor {
    struct Result {
        let imageOccurrenceCount: Int
        let extractedImageCount: Int
        let images: [PDFSceneImage]
    }

    private struct ImageRecord {
        let name: String
        let stream: CGPDFStreamRef
        let dictionary: CGPDFDictionaryRef
    }

    private struct DecodedImage {
        let width: Int
        let height: Int
        var rgba: [UInt8]
        var hasAlpha: Bool
        var maskApplied: Bool
    }

    static func extract(
        page: PDFPage,
        pageIndex: Int,
        cropBox: CGRect,
        maximumDimension: CGFloat,
        pageSafetyNetPNG: Data
    ) -> Result {
        guard let pageRef = page.pageRef,
              let pageDictionary = pageRef.dictionary,
              let resources = dictionary(pageDictionary, key: "Resources")
        else {
            return Result(imageOccurrenceCount: 0, extractedImageCount: 0, images: [])
        }

        let records = imageRecords(in: resources)
        guard !records.isEmpty else {
            return Result(imageOccurrenceCount: 0, extractedImageCount: 0, images: [])
        }
        var byName: [String: ImageRecord] = [:]
        for record in records {
            byName[record.name] = record
        }
        let placements = PDFImagePlacementTrace.trace(
            page: page,
            cropBox: cropBox,
            availableNames: Set(byName.keys)
        )
        let occurrenceCount = placements.isEmpty ? records.count : placements.count
        let pageSafetyNet = NSBitmapImageRep(data: pageSafetyNetPNG)
        var extracted: [PDFSceneImage] = []
        extracted.reserveCapacity(placements.count)
        for (order, placement) in placements.enumerated() {
            guard let record = byName[placement.name] else {
                continue
            }
            guard let decoded = decode(record: record, maximumDimension: maximumDimension) else {
                continue
            }
            guard let pngData = pngData(from: decoded) else {
                continue
            }
            let safeBounds = placement.bounds.intersection(cropBox)
            guard !safeBounds.isNull,
                  safeBounds.width > 0.25,
                  safeBounds.height > 0.25
            else {
                continue
            }
            let isPageBackdrop = safeBounds.width >= cropBox.width * 0.98
                && safeBounds.height >= cropBox.height * 0.98
            // `hasAlpha` records the source image model.  A soft mask can
            // still leave an RGBA buffer whose individual alpha samples are
            // not all opaque, so inspect the alpha channel as well.  Iterate
            // by pixel rather than enumerating every RGBA component: large
            // background images are common in slide PDFs and this check runs
            // for every image occurrence.
            let isFullyOpaque = !decoded.hasAlpha
                && stride(from: 3, to: decoded.rgba.count, by: 4).allSatisfy {
                    decoded.rgba[$0] == 255
                }
            let canBeIndependent = isFullyOpaque
                && !decoded.maskApplied
                && !isPageBackdrop
            let matchesSafetyNet = canBeIndependent
                && imageMatchesSafetyNet(
                    decoded,
                    placement: safeBounds,
                    cropBox: cropBox,
                    bitmap: pageSafetyNet
                )
            extracted.append(
                PDFSceneImage(
                    id: "pdf-image-\(pageIndex + 1)-\(order + 1)",
                    sourceName: record.name,
                    bounds: safeBounds,
                    pngData: pngData,
                    paintOrder: placement.paintOrder,
                    hasAlpha: decoded.hasAlpha,
                    maskApplied: decoded.maskApplied,
                    // A page-sized image is itself the visual safety-net or
                    // a template backdrop. Replaying it over that safety-net
                    // would hide logos/text that were painted later.
                    isBackdropIndependent: canBeIndependent,
                    isSafetyNetVerifiedOpaque: matchesSafetyNet
                )
            )
        }

        // A Form XObject can contain an image resource without exposing a
        // direct page-level `Do` callback. Count that resource as an occurrence
        // but do not invent a placement; the page render remains authoritative.
        return Result(
            imageOccurrenceCount: occurrenceCount,
            extractedImageCount: extracted.count,
            images: extracted
        )
    }

    private static func imageRecords(in resources: CGPDFDictionaryRef) -> [ImageRecord] {
        guard let xObjects = dictionary(resources, key: "XObject") else { return [] }
        var records: [ImageRecord] = []
        CGPDFDictionaryApplyBlock(xObjects, { key, _, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(xObjects, key, &stream),
                  let stream,
                  let streamDictionary = CGPDFStreamGetDictionary(stream)
            else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype),
                  let subtype
            else { return true }
            let name = String(cString: subtype)
            if name == "Image" {
                records.append(
                    ImageRecord(
                        name: String(cString: key),
                        stream: stream,
                        dictionary: streamDictionary
                    )
                )
            } else if name == "Form",
                      let nested = dictionary(streamDictionary, key: "Resources") {
                records.append(contentsOf: imageRecords(in: nested))
            }
            return true
        }, nil)
        return records
    }

    private static func decode(
        record: ImageRecord,
        maximumDimension: CGFloat
    ) -> DecodedImage? {
        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(record.stream, &format) else {
            return nil
        }
        let data = cfData as Data
        if format == .jpegEncoded || format == .JPEG2000 {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            guard var decoded = decodedImage(
                from: image,
                maximumDimension: maximumDimension
            ) else {
                return nil
            }
            // JPEG/JPX streams can carry a PDF soft mask separately. ImageIO
            // decodes only the color stream, so returning here used to drop
            // the transparency and turn transparent logos into black boxes.
            applyMask(record.dictionary, to: &decoded)
            return decoded
        }

        var width: CGPDFInteger = 0
        var height: CGPDFInteger = 0
        var bits: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(record.dictionary, "Width", &width),
              CGPDFDictionaryGetInteger(record.dictionary, "Height", &height),
              CGPDFDictionaryGetInteger(record.dictionary, "BitsPerComponent", &bits),
              width > 0,
              height > 0,
              width <= 16_384,
              height <= 16_384,
              CGFloat(max(width, height)) <= max(1_024, maximumDimension * 4)
        else { return nil }

        let imageMask = Self.boolean(record.dictionary, key: "ImageMask")
        let colorSpace = colorSpaceName(record.dictionary)
            ?? (record.name == "mask" ? "DeviceGray" : nil)
        let channels: Int
        if imageMask || colorSpace == "DeviceGray" {
            channels = 1
        } else if colorSpace == "DeviceRGB" {
            channels = 3
        } else if colorSpace == "DeviceCMYK" {
            channels = 4
        } else {
            return nil
        }
        guard bits == 1 || bits == 8 else { return nil }

        let widthInt = Int(width)
        let heightInt = Int(height)
        let rowBytes = (widthInt * channels * Int(bits) + 7) / 8
        guard rowBytes > 0,
              data.count >= rowBytes * heightInt
        else { return nil }

        let decodeValues = decodeArray(record.dictionary, count: channels)
        var rgba = Array(repeating: UInt8(0), count: widthInt * heightInt * 4)
        for y in 0..<heightInt {
            let sourceRow = y * rowBytes
            for x in 0..<widthInt {
                var samples = Array(repeating: 0.0, count: channels)
                for channel in 0..<channels {
                    let sample = bits == 8
                        ? Int(data[sourceRow + x * channels + channel])
                        : bitSample(
                            data: data,
                            rowOffset: sourceRow,
                            bitIndex: x * channels + channel,
                            bitsPerComponent: Int(bits)
                        )
                    let maxSample = Double((1 << Int(bits)) - 1)
                    let normalized = Double(sample) / maxSample
                    let low = decodeValues[channel * 2]
                    let high = decodeValues[channel * 2 + 1]
                    samples[channel] = low + normalized * (high - low)
                }

                let rgb: (Double, Double, Double)
                if imageMask {
                    let on = samples[0] >= 0.5
                    rgb = on ? (0, 0, 0) : (1, 1, 1)
                } else {
                    switch colorSpace {
                    case "DeviceGray":
                        rgb = (samples[0], samples[0], samples[0])
                    case "DeviceRGB":
                        rgb = (samples[0], samples[1], samples[2])
                    default:
                        let c = min(1, max(0, samples[0]))
                        let m = min(1, max(0, samples[1]))
                        let yy = min(1, max(0, samples[2]))
                        let k = min(1, max(0, samples[3]))
                        rgb = (
                            1 - min(1, c + k),
                            1 - min(1, m + k),
                            1 - min(1, yy + k)
                        )
                    }
                }
                let destination = (y * widthInt + x) * 4
                rgba[destination] = byte(rgb.0)
                rgba[destination + 1] = byte(rgb.1)
                rgba[destination + 2] = byte(rgb.2)
                rgba[destination + 3] = imageMask ? 0 : 255
            }
        }

        var result = DecodedImage(
            width: widthInt,
            height: heightInt,
            rgba: rgba,
            hasAlpha: imageMask,
            maskApplied: imageMask
        )
        applyMask(record.dictionary, to: &result)
        return result
    }

    private static func decodedImage(
        from image: CGImage,
        maximumDimension: CGFloat
    ) -> DecodedImage? {
        let width = image.width
        let height = image.height
        guard width > 0,
              height > 0,
              CGFloat(max(width, height)) <= max(1_024, maximumDimension * 4),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var rgba = Array(repeating: UInt8(0), count: width * height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let hasAlpha = image.alphaInfo != .none && image.alphaInfo != .noneSkipLast
        return DecodedImage(
            width: width,
            height: height,
            rgba: rgba,
            hasAlpha: hasAlpha,
            maskApplied: false
        )
    }

    private static func applyMask(
        _ dictionary: CGPDFDictionaryRef,
        to image: inout DecodedImage
    ) {
        var maskObject: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, "SMask", &maskObject)
                || CGPDFDictionaryGetObject(dictionary, "Mask", &maskObject),
              let maskObject
        else { return }

        if CGPDFObjectGetType(maskObject) == .array {
            var array: CGPDFArrayRef?
            guard CGPDFObjectGetValue(maskObject, .array, &array),
                  let array,
                  CGPDFArrayGetCount(array) >= 2
            else { return }
            let pairCount = CGPDFArrayGetCount(array) / 2
            let ranges = (0..<pairCount).map { index in
                (number(array, index: index * 2) ?? 0,
                 number(array, index: index * 2 + 1) ?? 1)
            }
            image.hasAlpha = true
            image.maskApplied = true
            for pixel in stride(from: 0, to: image.rgba.count, by: 4) {
                let channels = [
                    Double(image.rgba[pixel]) / 255,
                    Double(image.rgba[pixel + 1]) / 255,
                    Double(image.rgba[pixel + 2]) / 255
                ]
                let isMaskedColor = ranges.prefix(channels.count).enumerated().allSatisfy { index, range in
                    return channels[index] >= range.0 && channels[index] <= range.1
                }
                image.rgba[pixel + 3] = isMaskedColor ? 0 : 255
            }
            return
        }

        var maskStream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(maskObject, .stream, &maskStream),
              let maskStream,
              let maskDictionary = CGPDFStreamGetDictionary(maskStream),
              var mask = decode(
                  record: ImageRecord(name: "mask", stream: maskStream, dictionary: maskDictionary),
                  maximumDimension: CGFloat(max(image.width, image.height))
              )
        else { return }
        guard mask.width == image.width, mask.height == image.height else { return }
        image.hasAlpha = true
        image.maskApplied = true
        for pixel in stride(from: 0, to: image.rgba.count, by: 4) {
            let maskAlpha = mask.rgba[pixel]
            image.rgba[pixel + 3] = UInt8(
                (Int(image.rgba[pixel + 3]) * Int(maskAlpha) + 127) / 255
            )
        }
        mask.rgba.removeAll(keepingCapacity: false)
    }

    /// An opaque image may be replayed on top of the full-page fallback only
    /// if its own decoded pixels are already the final visible pixels at that
    /// placement. This catches images that sit below later text, images with a
    /// missed transform, and any decoder/color-space disagreement before they
    /// can cover correct fallback content in the Office document.
    private static func imageMatchesSafetyNet(
        _ image: DecodedImage,
        placement: CGRect,
        cropBox: CGRect,
        bitmap: NSBitmapImageRep?
    ) -> Bool {
        guard let bitmap,
              image.width > 1,
              image.height > 1,
              placement.width > 0,
              placement.height > 0,
              cropBox.width > 0,
              cropBox.height > 0,
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0
        else {
            return false
        }

        let imageAspect = CGFloat(image.width) / CGFloat(image.height)
        let placementAspect = placement.width / placement.height
        // A rotated/sheared Image XObject needs a full transform serializer,
        // not a resized OOXML rectangle. Refuse it until that representation
        // is available instead of guessing an orientation.
        guard abs(imageAspect - placementAspect) / max(imageAspect, placementAspect) < 0.025 else {
            return false
        }

        let columns = min(64, max(12, Int((placement.width / 10).rounded())))
        let rows = min(64, max(12, Int((placement.height / 10).rounded())))
        let bitmapScaleX = CGFloat(bitmap.pixelsWide) / cropBox.width
        let bitmapScaleY = CGFloat(bitmap.pixelsHigh) / cropBox.height
        var totalDifference = 0.0
        var mismatchedSamples = 0
        let sampleCount = columns * rows

        for row in 0..<rows {
            let v = (CGFloat(row) + 0.5) / CGFloat(rows)
            let imageY = min(
                image.height - 1,
                max(0, Int((v * CGFloat(image.height - 1)).rounded()))
            )
            let pageY = min(
                bitmap.pixelsHigh - 1,
                max(
                    0,
                    Int(((cropBox.maxY - (placement.maxY - v * placement.height)) * bitmapScaleY).rounded())
                )
            )
            for column in 0..<columns {
                let u = (CGFloat(column) + 0.5) / CGFloat(columns)
                let imageX = min(
                    image.width - 1,
                    max(0, Int((u * CGFloat(image.width - 1)).rounded()))
                )
                let pageX = min(
                    bitmap.pixelsWide - 1,
                    max(
                        0,
                        Int((((placement.minX + u * placement.width) - cropBox.minX) * bitmapScaleX).rounded())
                    )
                )
                guard let pageColor = bitmap.colorAt(x: pageX, y: pageY)?
                    .usingColorSpace(.deviceRGB)
                else {
                    return false
                }
                let sourceOffset = (imageY * image.width + imageX) * 4
                let difference = max(
                    abs(Int(image.rgba[sourceOffset]) - Int((pageColor.redComponent * 255).rounded())),
                    abs(Int(image.rgba[sourceOffset + 1]) - Int((pageColor.greenComponent * 255).rounded())),
                    abs(Int(image.rgba[sourceOffset + 2]) - Int((pageColor.blueComponent * 255).rounded()))
                )
                totalDifference += Double(difference)
                if difference > 16 {
                    mismatchedSamples += 1
                }
            }
        }

        let meanDifference = totalDifference / Double(max(1, sampleCount))
        let mismatchRatio = Double(mismatchedSamples) / Double(max(1, sampleCount))
        return meanDifference <= 6 && mismatchRatio <= 0.015
    }

    private static func pngData(from image: DecodedImage) -> Data? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(image.rgba) as CFData),
              let cgImage = CGImage(
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: image.width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.last.rawValue
                          | CGBitmapInfo.byteOrder32Big.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func colorSpaceName(_ dictionary: CGPDFDictionaryRef) -> String? {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, "ColorSpace", &object),
              let object
        else { return nil }
        if CGPDFObjectGetType(object) == .name {
            var name: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &name), let name else { return nil }
            return String(cString: name)
        }
        if CGPDFObjectGetType(object) == .array {
            var array: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &array), let array else { return nil }
            var name: UnsafePointer<CChar>?
            guard CGPDFArrayGetName(array, 0, &name), let name else { return nil }
            let firstName = String(cString: name)
            if firstName == "ICCBased", CGPDFArrayGetCount(array) > 1 {
                var stream: CGPDFStreamRef?
                if CGPDFArrayGetStream(array, 1, &stream),
                   let stream,
                   let streamDictionary = CGPDFStreamGetDictionary(stream) {
                    var alternate: UnsafePointer<CChar>?
                    if CGPDFDictionaryGetName(streamDictionary, "Alternate", &alternate),
                       let alternate {
                        return String(cString: alternate)
                    }
                    var componentCount: CGPDFInteger = 0
                    if CGPDFDictionaryGetInteger(streamDictionary, "N", &componentCount) {
                        return componentCount == 1 ? "DeviceGray"
                            : componentCount == 4 ? "DeviceCMYK" : "DeviceRGB"
                    }
                }
                return "DeviceRGB"
            }
            return firstName
        }
        return nil
    }

    private static func decodeArray(
        _ dictionary: CGPDFDictionaryRef,
        count: Int
    ) -> [Double] {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Decode", &array), let array,
              CGPDFArrayGetCount(array) >= count * 2
        else {
            return Array(repeating: 0, count: count * 2).enumerated().map {
                $0.offset.isMultiple(of: 2) ? 0 : 1
            }
        }
        return (0..<(count * 2)).map { number(array, index: $0) ?? ($0.isMultiple(of: 2) ? 0 : 1) }
    }

    private static func number(_ array: CGPDFArrayRef, index: Int) -> Double? {
        var value: CGPDFReal = 0
        guard CGPDFArrayGetNumber(array, index, &value) else { return nil }
        return Double(value)
    }

    private static func boolean(_ dictionary: CGPDFDictionaryRef, key: String) -> Bool {
        var value: CGPDFBoolean = 0
        return CGPDFDictionaryGetBoolean(dictionary, key, &value) && value != 0
    }

    private static func bitSample(
        data: Data,
        rowOffset: Int,
        bitIndex: Int,
        bitsPerComponent: Int
    ) -> Int {
        let bitOffset = bitIndex * bitsPerComponent
        let byteOffset = rowOffset + bitOffset / 8
        let shift = 8 - bitsPerComponent - (bitOffset % 8)
        let mask = (1 << bitsPerComponent) - 1
        return (Int(data[byteOffset]) >> shift) & mask
    }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8((min(1, max(0, value)) * 255).rounded())
    }

    private static func dictionary(
        _ dictionary: CGPDFDictionaryRef,
        key: String
    ) -> CGPDFDictionaryRef? {
        var result: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, key, &result) else { return nil }
        return result
    }
}

private final class PDFImagePlacementTrace {
    struct Placement {
        let name: String
        let bounds: CGRect
        let paintOrder: Int
    }

    private var transform = CGAffineTransform.identity
    private var stack: [CGAffineTransform] = []
    private var paintOrder = 0
    private var placements: [Placement] = []
    private let cropBox: CGRect
    private let availableNames: Set<String>

    private init(cropBox: CGRect, availableNames: Set<String>) {
        self.cropBox = cropBox
        self.availableNames = availableNames
    }

    static func trace(
        page: PDFPage,
        cropBox: CGRect,
        availableNames: Set<String>
    ) -> [Placement] {
        guard let pageRef = page.pageRef,
              let table = CGPDFOperatorTableCreate()
        else { return [] }
        let stream = CGPDFContentStreamCreateWithPage(pageRef)
        let trace = PDFImagePlacementTrace(
            cropBox: cropBox,
            availableNames: availableNames
        )
        let info = Unmanaged.passUnretained(trace).toOpaque()
        CGPDFOperatorTableSetCallback(table, "q", pdfImageSave)
        CGPDFOperatorTableSetCallback(table, "Q", pdfImageRestore)
        CGPDFOperatorTableSetCallback(table, "cm", pdfImageConcat)
        CGPDFOperatorTableSetCallback(table, "Do", pdfImageDraw)
        let scanner = CGPDFScannerCreate(stream, table, info)
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return trace.placements
    }

    func save() { stack.append(transform) }

    func restore() {
        transform = stack.popLast() ?? .identity
    }

    func concatenate(_ scanner: CGPDFScannerRef) {
        var f: CGPDFReal = 0
        var e: CGPDFReal = 0
        var d: CGPDFReal = 0
        var c: CGPDFReal = 0
        var b: CGPDFReal = 0
        var a: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &f),
              CGPDFScannerPopNumber(scanner, &e),
              CGPDFScannerPopNumber(scanner, &d),
              CGPDFScannerPopNumber(scanner, &c),
              CGPDFScannerPopNumber(scanner, &b),
              CGPDFScannerPopNumber(scanner, &a)
        else { return }
        transform = transform.concatenating(
            CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c), d: CGFloat(d), tx: CGFloat(e), ty: CGFloat(f))
        )
    }

    func draw(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else { return }
        let sourceName = String(cString: name)
        guard availableNames.contains(sourceName) else { return }
        let rawBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
            .applying(transform)
            .standardized
        let bounds = rawBounds.intersection(cropBox)
        guard !bounds.isNull, bounds.width > 0.25, bounds.height > 0.25 else { return }
        paintOrder += 1
        placements.append(
            Placement(name: sourceName, bounds: bounds, paintOrder: paintOrder)
        )
    }
}

private func pdfImageSave(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue().save()
}

private func pdfImageRestore(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue().restore()
}

private func pdfImageConcat(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue().concatenate(scanner)
}

private func pdfImageDraw(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue().draw(scanner)
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
