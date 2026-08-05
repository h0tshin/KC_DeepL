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
        // Keep direct scene extraction (tests, diagnostics, future import
        // tools) aligned with the app conversion service. Bundled OFL fonts
        // such as Barlow can be embedded into the generated PPTX as editable
        // output faces, rather than depending on the recipient's macOS fonts.
        _ = AppFontRegistry.registerBundledFonts()
        self.maximumRasterDimension = max(1_024, maximumRasterDimension)
    }

    func extract(
        sourceURL: URL,
        layoutTarget: PDFOfficeLayoutTarget = .presentation,
        options: DocumentConversionPipelineOptions = .default,
        progress: (@Sendable (_ fraction: Double, _ phase: DocumentConversionProgress.Phase, _ completedPage: Int, _ totalPages: Int, _ message: String) -> Void)? = nil
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

        progress?(0.02, .preparing, 0, document.pageCount, "PDF 페이지를 준비하는 중입니다.")

        let sha = Self.sha256(data)
        let analysis = try? PDFDocumentAnalysisService(
            includeOCR: true,
            includeSupplementalOCR: false,
            maximumOCRImageDimension: 2_400,
            requiresSourceMaskHaloValidation: true,
            retainDocumentChromeForTemplate: true
        ).analyze(sourceURL: sourceURL) { completedPage, totalPages in
            let fraction = 0.05 + 0.35 * Double(completedPage) / Double(max(1, totalPages))
            progress?(fraction, .analyzing, completedPage, totalPages, "텍스트와 문단 구조를 분석하는 중입니다. (\(completedPage)/\(totalPages))")
        }

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
                layoutTarget: layoutTarget,
                options: options
            )
            // First render is the immutable reference used for source-image
            // inspection. The second render becomes the background/template
            // layer after editable text and pictures have been removed.
            let referenceImageData = try renderPage(
                page,
                cropBox: cropBox,
                masks: []
            )
            let imageSummary = PDFImageExtractor.extract(
                page: page,
                pageIndex: pageIndex,
                cropBox: cropBox,
                maximumDimension: maximumRasterDimension,
                pageSafetyNetPNG: referenceImageData
            )
            let graphics = PDFGraphicsTrace.trace(
                page: page,
                cropBox: cropBox,
                pageSafetyNetPNG: referenceImageData
            )
            let layeredBackground = Self.layeredBackgroundImage(
                in: imageSummary.images,
                cropBox: cropBox
            )
            var resolvedImages = Self.promotingVisibleLayeredAlphaImages(
                in: imageSummary.images,
                background: layeredBackground,
                referencePagePNG: referenceImageData,
                vectors: graphics.vectors
            )
            let nativeCanvasColor: PDFTextColor?
            if analysis == nil {
                nativeCanvasColor = nil
            } else {
                nativeCanvasColor = Self.uniformBackgroundColor(
                    in: referenceImageData,
                    cropBox: cropBox,
                    foregroundBounds: textBoxes.map(\.officeBounds)
                        + resolvedImages.map(\.bounds)
                        + graphics.vectors.map(\.bounds)
                )
            }
            if let nativeCanvasColor {
                // A white (or otherwise uniform) PDF canvas is a real
                // reconstruction layer, not a reason to flatten the page.
                // Image safety-net comparison is intentionally conservative
                // for colour-managed JPEGs and soft masks; use a second proof
                // against the known canvas to recover visible source images
                // without promoting an image that is completely hidden.
                resolvedImages = Self.promotingNativeCanvasImages(
                    in: resolvedImages,
                    referencePagePNG: referenceImageData,
                    cropBox: cropBox,
                    canvasColor: nativeCanvasColor
                )
            }
            let usesLayeredTemplate = Self.canUseLayeredTemplate(
                background: layeredBackground,
                textBoxes: textBoxes,
                images: resolvedImages,
                vectors: graphics.vectors,
                options: options,
                nativeCanvasColorAvailable: nativeCanvasColor != nil
            )
            let imageData: Data
            let isNativeCanvasBackground: Bool
            if usesLayeredTemplate,
               let layeredBackground {
                imageData = layeredBackground.pngData
                isNativeCanvasBackground = false
            } else if usesLayeredTemplate,
                      layeredBackground == nil,
                      nativeCanvasColor != nil {
                // A proven uniform canvas is only a native background when
                // every visible foreground object can be replayed. Keep the
                // immutable source render as the diagnostic/safety image for
                // this native-object path; writers suppress it because the
                // flag below tells them to emit the canvas colour instead.
                // If an unsupported object makes the page use the raster
                // safety net, execution reaches the branch below and keeps
                // the repaired full-page render instead.
                imageData = referenceImageData
                isNativeCanvasBackground = true
            } else {
                let masks = Self.rasterRepairMasks(
                    pageAnalysis: pageAnalysis,
                    textBoxes: textBoxes,
                    images: resolvedImages.filter { image in
                        options.preserveAlphaMasks
                            || (!image.hasAlpha && !image.maskApplied)
                    }
                )
                imageData = try renderPage(
                    page,
                    cropBox: cropBox,
                    masks: masks
                )
                isNativeCanvasBackground = false
            }

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
            let usesFallback = !usesLayeredTemplate
            let pageID = "scene-page-\(pageIndex + 1)-\(Self.shortHash(String(describing: cropBox)))"
            let scenePage = PDFScenePage(
                id: pageID,
                pageIndex: pageIndex,
                cropBox: cropBox,
                rotation: page.rotation,
                pageImagePNG: imageData,
                textBoxes: textBoxes,
                images: resolvedImages,
                vectors: graphics.vectors,
                templateObjects: templates,
                imageOccurrenceCount: imageSummary.imageOccurrenceCount,
                extractedImageCount: imageSummary.extractedImageCount,
                nativeVectorCount: graphics.vectors.filter(\.nativeEligible).count,
                warnings: pageWarnings,
                usesPageRasterFallback: usesFallback,
                isNativeCanvasBackground: isNativeCanvasBackground
            )
            pages.append(scenePage)
            documentWarnings.append(contentsOf: pageWarnings)
            let completedPage = pageIndex + 1
            let fraction = 0.40 + 0.35 * Double(completedPage) / Double(max(1, document.pageCount))
            progress?(fraction, .extracting, completedPage, document.pageCount, "페이지의 텍스트·이미지·도형을 추출하는 중입니다. (\(completedPage)/\(document.pageCount))")
        }

        let classifiedPages = Self.classifyRepeatedTemplates(in: pages)
        progress?(0.78, .extracting, document.pageCount, document.pageCount, "반복되는 템플릿 요소를 분류하는 중입니다.")
        return PDFSceneDocument(
            sourceURL: sourceURL.standardizedFileURL,
            sourceSHA256: sha,
            pages: classifiedPages,
            warnings: Self.deduplicated(documentWarnings)
        )
    }

    /// Samples used to prove a transparent image's contribution must respect
    /// the PDF clipping path that was active at its `Do` operator. Sampling
    /// the image's rectangular bounds would incorrectly treat pixels hidden
    /// by a footer mask or diagonal template edge as visible source pixels.
    static func pointIsInsideImageClip(
        _ point: CGPoint,
        clip: PDFSceneImageClip?
    ) -> Bool {
        guard let clip else { return true }

        let path = CGMutablePath()
        for command in clip.pathCommands {
            switch command {
            case let .move(point):
                path.move(to: point)
            case let .line(point):
                path.addLine(to: point)
            case let .cubic(control1, control2, end):
                path.addCurve(
                    to: end,
                    control1: control1,
                    control2: control2
                )
            case .close:
                path.closeSubpath()
            }
        }
        return path.contains(point, using: .winding, transform: .identity)
    }
}

/// A local repair performed in the template/background raster before an
/// editable Office object is placed above it. The repair is deliberately
/// narrow: it never replaces the page with another screenshot and it leaves
/// unsupported material untouched.
private struct PDFSceneRasterRepairMask {
    enum Kind {
        /// A verified single-colour background can be replaced as a whole.
        case solidText
        /// Reconstruct only pixels that follow the source text's alpha blend.
        case glyphAwareText
        /// Reconstruct the whole rectangular image placement before inserting
        /// its decoded PNG as a real PowerPoint picture.
        case imageArea
    }

    let bounds: CGRect
    let fallbackBackground: PDFTextColor
    let foregroundColors: [PDFTextColor]
    let kind: Kind
    /// The original, straight-alpha PNG for an image mask. Text masks keep
    /// this nil.  It lets the template repair undo the PDF's source-over
    /// blend for partially transparent pixels instead of painting a visible
    /// rectangular replacement behind a logo.
    let imagePNGData: Data?
    let imageUsesTransparency: Bool
}

/// A small, straight-alpha bitmap used only while repairing the template
/// underneath a native Office picture.  `CGImage`/`CGContext` expose
/// premultiplied samples, whereas the PDF image extractor writes a
/// straight-alpha PNG for PowerPoint.  Normalize once so inverse compositing
/// uses the same colour model as the emitted asset.
private struct PDFSceneRasterImage {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init?(pngData: Data) {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }

        width = image.width
        height = image.height
        var premultiplied = Array(repeating: UInt8(0), count: width * height * 4)
        guard let context = CGContext(
            data: &premultiplied,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var straight = premultiplied
        for offset in stride(from: 0, to: straight.count, by: 4) {
            let alpha = Int(straight[offset + 3])
            guard alpha > 0 else {
                straight[offset] = 0
                straight[offset + 1] = 0
                straight[offset + 2] = 0
                continue
            }
            straight[offset] = UInt8(min(
                255,
                (Int(straight[offset]) * 255 + alpha / 2) / alpha
            ))
            straight[offset + 1] = UInt8(min(
                255,
                (Int(straight[offset + 1]) * 255 + alpha / 2) / alpha
            ))
            straight[offset + 2] = UInt8(min(
                255,
                (Int(straight[offset + 2]) * 255 + alpha / 2) / alpha
            ))
        }
        rgba = straight
    }

    func sample(
        normalizedX: CGFloat,
        normalizedY: CGFloat,
        flipVertically: Bool
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let x = min(width - 1, max(0, Int((normalizedX * CGFloat(width)).rounded(.down))))
        let unflippedY = min(
            height - 1,
            max(0, Int((normalizedY * CGFloat(height)).rounded(.down)))
        )
        let y = flipVertically ? height - 1 - unflippedY : unflippedY
        let offset = (y * width + x) * 4
        return (
            CGFloat(rgba[offset]) / 255,
            CGFloat(rgba[offset + 1]) / 255,
            CGFloat(rgba[offset + 2]) / 255,
            CGFloat(rgba[offset + 3]) / 255
        )
    }
}

private extension PDFSceneExtractor {
    static func layeredBackgroundImage(
        in images: [PDFSceneImage],
        cropBox: CGRect
    ) -> PDFSceneImage? {
        images.first { image in
            !image.hasAlpha
                && !image.maskApplied
                && image.bounds.minX <= cropBox.minX + 0.5
                && image.bounds.minY <= cropBox.minY + 0.5
                && image.bounds.maxX >= cropBox.maxX - 0.5
                && image.bounds.maxY >= cropBox.maxY - 0.5
        }
    }

    /// Performs a second visibility proof for low-alpha/masked assets when a
    /// PDF provides an independently extracted full-page background image.
    ///
    /// The first image pass intentionally rejects a soft shadow when its
    /// opaque pixels are absent or its surrounding rendered backdrop is not
    /// uniform. In a layered slide, however, the background image is the
    /// exact backdrop. Re-compositing the alpha asset over that background and
    /// comparing it with the rendered PDF proves whether the asset contributes
    /// final pixels without promoting hidden logos or a flattened page.
    static func promotingVisibleLayeredAlphaImages(
        in images: [PDFSceneImage],
        background: PDFSceneImage?,
        referencePagePNG: Data,
        vectors: [PDFSceneVector]
    ) -> [PDFSceneImage] {
        guard let background,
              let backgroundBitmap = NSBitmapImageRep(data: background.pngData),
              let referenceBitmap = NSBitmapImageRep(data: referencePagePNG),
              backgroundBitmap.pixelsWide > 0,
              backgroundBitmap.pixelsHigh > 0,
              referenceBitmap.pixelsWide > 0,
              referenceBitmap.pixelsHigh > 0
        else {
            return images
        }

        var resolved = images
        for index in resolved.indices {
            let image = resolved[index]
            guard image.id != background.id,
                  !image.canRecreateOnLayeredTemplate,
                  image.hasRepresentableGeometry,
                  image.hasAlpha || image.maskApplied,
                  let imageBitmap = NSBitmapImageRep(data: image.pngData),
                  imageBitmap.pixelsWide > 0,
                  imageBitmap.pixelsHigh > 0
            else {
                continue
            }
            let laterVisibleImageBounds = resolved
                .filter {
                    $0.paintOrder > image.paintOrder
                        && $0.hasVisibleReferenceContribution
                        && $0.hasRepresentableGeometry
                }
                .map(\.bounds)
            let laterOpaqueVectorBounds = vectors
                .filter {
                    $0.paintOrder > image.paintOrder
                        && ($0.fill?.alpha ?? 0) >= 0.999
                }
                .map(\.bounds)
            guard layeredAlphaContributionMatches(
                imageBitmap: imageBitmap,
                placement: image.bounds,
                clip: image.clip,
                backgroundBitmap: backgroundBitmap,
                backgroundBounds: background.bounds,
                referenceBitmap: referenceBitmap,
                occludingImageBounds: laterVisibleImageBounds
                    + laterOpaqueVectorBounds
            ) else {
                continue
            }
            resolved[index] = PDFSceneImage(
                id: image.id,
                sourceName: image.sourceName,
                bounds: image.bounds,
                pngData: image.pngData,
                paintOrder: image.paintOrder,
                hasAlpha: image.hasAlpha,
                maskApplied: image.maskApplied,
                backdropColor: image.backdropColor,
                isBackdropIndependent: image.isBackdropIndependent,
                isSafetyNetVerifiedOpaque: image.isSafetyNetVerifiedOpaque,
                hasRepresentableGeometry: image.hasRepresentableGeometry,
                isNativeObjectEligible: image.isNativeObjectEligible,
                isLayeredTemplateEligible: true,
                hasVisibleReferenceContribution: true,
                clip: image.clip
            )
        }
        return resolved
    }

    static func layeredAlphaContributionMatches(
        imageBitmap: NSBitmapImageRep,
        placement: CGRect,
        clip: PDFSceneImageClip?,
        backgroundBitmap: NSBitmapImageRep,
        backgroundBounds: CGRect,
        referenceBitmap: NSBitmapImageRep,
        occludingImageBounds: [CGRect]
    ) -> Bool {
        guard placement.width > 0,
              placement.height > 0,
              backgroundBounds.width > 0,
              backgroundBounds.height > 0
        else {
            return false
        }

        func sample(
            _ bitmap: NSBitmapImageRep,
            normalizedX: CGFloat,
            normalizedY: CGFloat
        ) -> PDFTextColor? {
            let x = min(
                bitmap.pixelsWide - 1,
                max(0, Int((normalizedX * CGFloat(bitmap.pixelsWide)).rounded(.down)))
            )
            let y = min(
                bitmap.pixelsHigh - 1,
                max(0, Int((normalizedY * CGFloat(bitmap.pixelsHigh)).rounded(.down)))
            )
            guard let color = bitmap.colorAt(x: x, y: y)?
                .usingColorSpace(.deviceRGB)
            else {
                return nil
            }
            return PDFTextColor(
                red: color.redComponent,
                green: color.greenComponent,
                blue: color.blueComponent,
                alpha: color.alphaComponent
            )
        }

        let columns = min(96, max(24, Int((placement.width / 3).rounded())))
        let rows = min(96, max(24, Int((placement.height / 3).rounded())))
        var contributingSamples = 0
        var matchingSamples = 0

        for row in 0..<rows {
            let normalizedY = (CGFloat(row) + 0.5) / CGFloat(rows)
            let pageY = placement.maxY - normalizedY * placement.height
            for column in 0..<columns {
                let normalizedX = (CGFloat(column) + 0.5) / CGFloat(columns)
                let pageX = placement.minX + normalizedX * placement.width
                let pagePoint = CGPoint(x: pageX, y: pageY)
                guard pointIsInsideImageClip(pagePoint, clip: clip),
                      !occludingImageBounds.contains(where: { $0.contains(pagePoint) }),
                      let source = sample(
                        imageBitmap,
                        normalizedX: normalizedX,
                        normalizedY: normalizedY
                      ),
                      source.alpha >= 0.03
                else {
                    continue
                }
                let pageNormalizedX = (pageX - backgroundBounds.minX)
                    / backgroundBounds.width
                let pageNormalizedY = (backgroundBounds.maxY - pageY)
                    / backgroundBounds.height
                guard let backdrop = sample(
                    backgroundBitmap,
                    normalizedX: pageNormalizedX,
                    normalizedY: pageNormalizedY
                ), let reference = sample(
                    referenceBitmap,
                    normalizedX: pageNormalizedX,
                    normalizedY: pageNormalizedY
                ) else {
                    continue
                }
                let alpha = min(max(source.alpha, 0), 1)
                let expected = PDFTextColor(
                    red: alpha * source.red + (1 - alpha) * backdrop.red,
                    green: alpha * source.green + (1 - alpha) * backdrop.green,
                    blue: alpha * source.blue + (1 - alpha) * backdrop.blue,
                    alpha: 1
                )
                let difference = max(
                    abs(expected.red - reference.red),
                    abs(expected.green - reference.green),
                    abs(expected.blue - reference.blue)
                )
                contributingSamples += 1
                if difference <= 0.14 {
                    matchingSamples += 1
                }
            }
        }

        guard contributingSamples >= 20 else { return false }
        return Double(matchingSamples) / Double(contributingSamples) >= 0.64
    }

    /// Promotes visible image occurrences on a proven uniform canvas even
    /// when the normal page-safety-net matcher rejects them. JPEG colour
    /// management and PDF soft-mask sampling can make a pixel-for-pixel
    /// comparison fail although the image is plainly a separate source
    /// object. This proof compares only non-canvas ink and requires that the
    /// rendered page contains the same ink at the original placement, so a
    /// completely covered resource is still left in the authoritative raster.
    static func promotingNativeCanvasImages(
        in images: [PDFSceneImage],
        referencePagePNG: Data,
        cropBox: CGRect,
        canvasColor: PDFTextColor
    ) -> [PDFSceneImage] {
        guard let referenceBitmap = NSBitmapImageRep(data: referencePagePNG),
              referenceBitmap.pixelsWide > 0,
              referenceBitmap.pixelsHigh > 0
        else {
            return images
        }

        var resolved = images
        for index in resolved.indices {
            let image = resolved[index]
            guard image.hasRepresentableGeometry,
                  image.clip == nil,
                  image.bounds.width > 1,
                  image.bounds.height > 1,
                  !image.hasVisibleReferenceContribution,
                  let imageBitmap = NSBitmapImageRep(data: image.pngData),
                  imageBitmap.pixelsWide > 1,
                  imageBitmap.pixelsHigh > 1,
                  nativeCanvasImageHasVisibleInk(
                      imageBitmap: imageBitmap,
                      imageBounds: image.bounds,
                      cropBox: cropBox,
                      referenceBitmap: referenceBitmap,
                      canvasColor: canvasColor
                  )
            else {
                continue
            }
            resolved[index] = PDFSceneImage(
                id: image.id,
                sourceName: image.sourceName,
                bounds: image.bounds,
                pngData: image.pngData,
                paintOrder: image.paintOrder,
                hasAlpha: image.hasAlpha,
                maskApplied: image.maskApplied,
                backdropColor: image.backdropColor,
                isBackdropIndependent: image.isBackdropIndependent,
                isSafetyNetVerifiedOpaque: image.isSafetyNetVerifiedOpaque,
                hasRepresentableGeometry: image.hasRepresentableGeometry,
                isNativeObjectEligible: image.isNativeObjectEligible,
                isLayeredTemplateEligible: true,
                hasVisibleReferenceContribution: true,
                clip: image.clip
            )
        }
        return resolved
    }

    private static func nativeCanvasImageHasVisibleInk(
        imageBitmap: NSBitmapImageRep,
        imageBounds: CGRect,
        cropBox: CGRect,
        referenceBitmap: NSBitmapImageRep,
        canvasColor: PDFTextColor
    ) -> Bool {
        let columns = min(64, max(16, Int((imageBounds.width / 6).rounded())))
        let rows = min(64, max(16, Int((imageBounds.height / 6).rounded())))
        let pageScaleX = CGFloat(referenceBitmap.pixelsWide) / cropBox.width
        let pageScaleY = CGFloat(referenceBitmap.pixelsHigh) / cropBox.height
        let canvasRed = canvasColor.red * 255
        let canvasGreen = canvasColor.green * 255
        let canvasBlue = canvasColor.blue * 255

        func color(
            _ bitmap: NSBitmapImageRep,
            x: Int,
            y: Int
        ) -> PDFTextColor? {
            guard let value = bitmap.colorAt(x: x, y: y)?
                .usingColorSpace(.deviceRGB)
            else { return nil }
            return PDFTextColor(
                red: value.redComponent,
                green: value.greenComponent,
                blue: value.blueComponent,
                alpha: value.alphaComponent
            )
        }

        func evaluate(flipVertically: Bool) -> (ink: Int, matches: Int, renderedInk: Int) {
            var sourceInk = 0
            var matchingInk = 0
            var renderedInk = 0
            for row in 0..<rows {
                let v = (CGFloat(row) + 0.5) / CGFloat(rows)
                let sourceV = flipVertically ? 1 - v : v
                let imageY = min(
                    imageBitmap.pixelsHigh - 1,
                    max(0, Int((sourceV * CGFloat(imageBitmap.pixelsHigh - 1)).rounded()))
                )
                let pageY = min(
                    referenceBitmap.pixelsHigh - 1,
                    max(0, Int(((cropBox.maxY - (imageBounds.maxY - v * imageBounds.height)) * pageScaleY).rounded()))
                )
                for column in 0..<columns {
                    let u = (CGFloat(column) + 0.5) / CGFloat(columns)
                    let imageX = min(
                        imageBitmap.pixelsWide - 1,
                        max(0, Int((u * CGFloat(imageBitmap.pixelsWide - 1)).rounded()))
                    )
                    let pageX = min(
                        referenceBitmap.pixelsWide - 1,
                        max(0, Int((((imageBounds.minX + u * imageBounds.width) - cropBox.minX) * pageScaleX).rounded()))
                    )
                    guard let source = color(imageBitmap, x: imageX, y: imageY),
                          let rendered = color(referenceBitmap, x: pageX, y: pageY)
                    else { continue }
                    let sourceAlpha = min(max(source.alpha, 0), 1)
                    let expectedRed = sourceAlpha * source.red * 255 + (1 - sourceAlpha) * canvasRed
                    let expectedGreen = sourceAlpha * source.green * 255 + (1 - sourceAlpha) * canvasGreen
                    let expectedBlue = sourceAlpha * source.blue * 255 + (1 - sourceAlpha) * canvasBlue
                    let sourceInkDistance = max(
                        abs(expectedRed - canvasRed),
                        abs(expectedGreen - canvasGreen),
                        abs(expectedBlue - canvasBlue)
                    )
                    let renderedInkDistance = max(
                        abs(rendered.red * 255 - canvasRed),
                        abs(rendered.green * 255 - canvasGreen),
                        abs(rendered.blue * 255 - canvasBlue)
                    )
                    // Transparent pixels and JPEG's clean white backdrop do
                    // not prove that an occurrence contributes to the page.
                    guard sourceAlpha >= 0.04, sourceInkDistance >= 10 else {
                        continue
                    }
                    sourceInk += 1
                    if renderedInkDistance >= 8 {
                        renderedInk += 1
                    }
                    let directDifference = max(
                        abs(expectedRed - rendered.red * 255),
                        abs(expectedGreen - rendered.green * 255),
                        abs(expectedBlue - rendered.blue * 255)
                    )
                    if directDifference <= 48 {
                        matchingInk += 1
                    }
                }
            }
            return (sourceInk, matchingInk, renderedInk)
        }

        let normal = evaluate(flipVertically: false)
        let flipped = evaluate(flipVertically: true)
        let best = normal.matches >= flipped.matches ? normal : flipped
        guard best.ink >= 8, best.renderedInk >= 6 else { return false }
        return Double(best.matches) / Double(best.ink) >= 0.28
    }

    static func canUseLayeredTemplate(
        background: PDFSceneImage?,
        textBoxes: [PDFSceneTextBox],
        images: [PDFSceneImage],
        vectors: [PDFSceneVector],
        options: DocumentConversionPipelineOptions = .default,
        nativeCanvasColorAvailable: Bool = false
    ) -> Bool {
        guard textBoxes
            .filter(\.hasVisibleReferenceContribution)
            .allSatisfy(\.canRecreateOnLayeredTemplate)
        else {
            return false
        }
        guard let background else {
            // A PDF with no full-page image can still be reconstructed from
            // its native objects when the remaining canvas is proven to be a
            // uniform colour.  The extractor replaces that canvas with a
            // tiny, non-content background raster; it never captures the
            // page's foreground into the fallback image.
            guard nativeCanvasColorAvailable else { return false }
            return images.allSatisfy {
                $0.hasVisibleReferenceContribution
                    && $0.canRecreate(onPageSafetyNet: false, options: options)
            } && vectors.allSatisfy {
                $0.canRecreate(onPageSafetyNet: false, options: options)
            }
        }
        let foregroundImages = images.filter {
            $0.id != background.id && $0.hasVisibleReferenceContribution
        }
        return foregroundImages.allSatisfy {
            $0.canRecreate(onPageSafetyNet: false, options: options)
        }
            && vectors.allSatisfy {
                $0.canRecreate(onPageSafetyNet: false, options: options)
            }
    }

    /// Returns a stable canvas colour only when samples along the page edges
    /// agree and are not covered by any extracted foreground object.  This is
    /// intentionally conservative: a gradient, watermark, pattern, or
    /// unsupported paint path fails the proof and keeps the authoritative page
    /// safety-net instead of silently dropping it.
    static func uniformBackgroundColor(
        in pagePNG: Data,
        cropBox: CGRect,
        foregroundBounds: [CGRect]
    ) -> PDFTextColor? {
        guard let bitmap = NSBitmapImageRep(data: pagePNG),
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0,
              cropBox.width > 0,
              cropBox.height > 0
        else {
            return nil
        }

        let edgeSamples: [(CGFloat, CGFloat)] = [
            (0.02, 0.02), (0.25, 0.02), (0.50, 0.02), (0.75, 0.02), (0.98, 0.02),
            (0.02, 0.25), (0.02, 0.50), (0.02, 0.75),
            (0.98, 0.25), (0.98, 0.50), (0.98, 0.75),
            (0.02, 0.98), (0.25, 0.98), (0.50, 0.98), (0.75, 0.98), (0.98, 0.98),
            // Interior probes catch gradients or unsupported full-page
            // artwork whose border happens to be uniform.
            (0.18, 0.18), (0.50, 0.18), (0.82, 0.18),
            (0.18, 0.50), (0.50, 0.50), (0.82, 0.50),
            (0.18, 0.82), (0.50, 0.82), (0.82, 0.82)
        ]

        func isForeground(_ normalized: (CGFloat, CGFloat)) -> Bool {
            let pagePoint = CGPoint(
                x: cropBox.minX + normalized.0 * cropBox.width,
                y: cropBox.maxY - normalized.1 * cropBox.height
            )
            return foregroundBounds.contains { bounds in
                bounds.insetBy(dx: -2, dy: -2).contains(pagePoint)
            }
        }

        var colours: [PDFTextColor] = []
        for normalized in edgeSamples where !isForeground(normalized) {
            let x = min(
                bitmap.pixelsWide - 1,
                max(0, Int((normalized.0 * CGFloat(bitmap.pixelsWide)).rounded(.down)))
            )
            let y = min(
                bitmap.pixelsHigh - 1,
                max(0, Int((normalized.1 * CGFloat(bitmap.pixelsHigh)).rounded(.down)))
            )
            guard let colour = bitmap.colorAt(x: x, y: y)?
                .usingColorSpace(.deviceRGB)
            else { continue }
            let value = PDFTextColor(
                red: colour.redComponent,
                green: colour.greenComponent,
                blue: colour.blueComponent,
                alpha: colour.alphaComponent
            )
            guard value.alpha >= 0.98 else { return nil }
            colours.append(value)
        }
        guard colours.count >= 4 else { return nil }
        let reference = colours[0]
        guard colours.allSatisfy({ colour in
            max(
                abs(colour.red - reference.red),
                abs(colour.green - reference.green),
                abs(colour.blue - reference.blue)
            ) <= 0.045
        }) else {
            return nil
        }
        let count = CGFloat(colours.count)
        return PDFTextColor(
            red: colours.reduce(0) { $0 + $1.red } / count,
            green: colours.reduce(0) { $0 + $1.green } / count,
            blue: colours.reduce(0) { $0 + $1.blue } / count,
            alpha: 1
        )
    }

    static func textBoxes(
        from page: PDFPageAnalysis?,
        layoutTarget: PDFOfficeLayoutTarget,
        options: DocumentConversionPipelineOptions = .default
    ) -> [PDFSceneTextBox] {
        guard let page else { return [] }
        let contentBoxes = page.blocks.compactMap { block -> PDFSceneTextBox? in
            let lines = block.lineIDs.compactMap { id in
                page.lines.first(where: { $0.id == id })
            }
            guard let firstLine = lines.first,
                  !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            let paragraphAlignment = PDFOfficeTextAppearance.paragraphAlignment(
                for: lines,
                fallback: firstLine.alignment
            )
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
                    backgroundColor: line.backgroundColor,
                    sourceMaskIsSafe: line.sourceMaskIsSafe,
                    hasVisibleInk: line.hasVisibleInk,
                    extractionSource: line.extractionSource,
                    listTabStop: listTabStop
                )
            }
            let primaryRun = sceneLines.first?.runs.first
            let layoutBounds = PDFOfficeTextAppearance.officeLayoutBounds(
                for: lines,
                sourceBounds: block.bounds,
                alignment: paragraphAlignment,
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
                alignment: paragraphAlignment,
                lineCount: lines.count,
                sourceLineIDs: block.lineIDs,
                extractionSource: lines.contains(where: {
                    $0.extractionSource == .visionOCR
                }) ? .visionOCR : .native,
                lines: sceneLines,
                visualPolicy: PDFOfficeTextAppearance.visualPolicy(for: lines)
            )
        }
        let mergedContentBoxes = mergeContentTextBoxes(
            contentBoxes,
            level: options.textBoxMergeLevel
        )
        let foregroundTextBounds = mergedContentBoxes.flatMap { $0.lines.map(\.bounds) }
        let templateBoxes = page.templateChromeLines.compactMap { line -> PDFSceneTextBox? in
            guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
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
            let sceneLine = PDFSceneTextLine(
                id: line.id,
                text: line.text,
                bounds: line.bounds,
                runs: sourceRuns.map(PDFSceneTextRun.init),
                sourceMaskBounds: line.sourceMaskBounds,
                backgroundColor: line.backgroundColor,
                sourceMaskIsSafe: line.sourceMaskIsSafe,
                hasVisibleInk: line.hasVisibleInk,
                extractionSource: line.extractionSource
            )
            let layoutBounds = PDFOfficeTextAppearance.officeLayoutBounds(
                for: [line],
                sourceBounds: line.bounds,
                alignment: line.alignment,
                cropBox: page.cropBox,
                layoutTarget: layoutTarget
            )
            let primaryRun = sceneLine.runs.first
            let templateArea = max(1, line.bounds.width * line.bounds.height)
            let isOccludedByForeground = foregroundTextBounds.contains { foregroundBounds in
                let overlap = foregroundBounds.intersection(line.bounds)
                guard !overlap.isNull else { return false }
                let overlapArea = overlap.width * overlap.height
                // A narrow antialias/selection overlap is not occlusion. A
                // later text line must cover most of the template line's
                // glyph rectangle before it can suppress the template object.
                return overlapArea / templateArea >= 0.55
            }
            return PDFSceneTextBox(
                id: "template-\(line.id)",
                text: line.text,
                bounds: line.bounds,
                layoutBounds: layoutBounds,
                fontName: primaryRun?.fontName ?? line.fontName,
                fontSize: max(5, primaryRun?.fontSize ?? line.fontSize),
                color: primaryRun?.color ?? line.textColor,
                alignment: line.alignment,
                lineCount: 1,
                sourceLineIDs: [line.id],
                extractionSource: line.extractionSource,
                lines: [sceneLine],
                visualPolicy: PDFOfficeTextAppearance.visualPolicy(for: [line]),
                role: .templateChrome,
                isOccludedByForeground: isOccludedByForeground
            )
        }
        return templateBoxes + mergedContentBoxes
    }

    /// PDF analysis blocks are intentionally conservative. This second pass
    /// lets PPT users merge adjacent blocks only when their visual geometry
    /// proves that they belong to the same column/paragraph region.
    static func mergeContentTextBoxes(
        _ boxes: [PDFSceneTextBox],
        level: PresentationTextBoxMergeLevel
    ) -> [PDFSceneTextBox] {
        guard level != .separate, boxes.count > 1 else {
            return boxes
        }

        let ordered = boxes.sorted { lhs, rhs in
            if abs(lhs.bounds.maxY - rhs.bounds.maxY) > 0.5 {
                return lhs.bounds.maxY > rhs.bounds.maxY
            }
            return lhs.bounds.minX < rhs.bounds.minX
        }
        var merged: [PDFSceneTextBox] = []
        merged.reserveCapacity(ordered.count)

        for box in ordered {
            guard let previous = merged.last,
                  canMergeTextBoxes(previous, box, level: level)
            else {
                merged.append(box)
                continue
            }
            merged[merged.count - 1] = mergeTextBoxes(previous, box)
        }
        return merged
    }

    static func canMergeTextBoxes(
        _ first: PDFSceneTextBox,
        _ second: PDFSceneTextBox,
        level: PresentationTextBoxMergeLevel
    ) -> Bool {
        guard first.role == .editableContent,
              second.role == .editableContent,
              first.alignment == second.alignment
        else {
            return false
        }

        let referenceSize = max(5, max(first.fontSize, second.fontSize))
        let fontTolerance = level == .broad ? 0.35 : 0.18
        guard abs(first.fontSize - second.fontSize) <= referenceSize * fontTolerance else {
            return false
        }

        let verticalGap = max(0, first.bounds.minY - second.bounds.maxY)
        let maximumGap = level == .broad
            ? max(36, referenceSize * 2.5)
            : max(18, referenceSize * 1.25)
        guard verticalGap <= maximumGap else {
            return false
        }

        let intersection = first.bounds.intersection(second.bounds)
        let horizontalOverlap = intersection.isNull ? 0 : intersection.width
        let minimumWidth = max(1, min(first.bounds.width, second.bounds.width))
        let startTolerance = level == .broad
            ? max(24, referenceSize * 2.5)
            : max(10, referenceSize * 1.25)
        let sameColumn = horizontalOverlap / minimumWidth >= 0.22
            || abs(first.bounds.minX - second.bounds.minX) <= startTolerance
        guard sameColumn else { return false }

        let firstTabStops = first.lines.compactMap(\.listTabStop)
        let secondTabStops = second.lines.compactMap(\.listTabStop)
        if !firstTabStops.isEmpty || !secondTabStops.isEmpty {
            guard firstTabStops.count == secondTabStops.count,
                  zip(firstTabStops, secondTabStops).allSatisfy({
                      abs($0 - $1) <= startTolerance
                  })
            else {
                return false
            }
        }
        return true
    }

    static func mergeTextBoxes(
        _ first: PDFSceneTextBox,
        _ second: PDFSceneTextBox
    ) -> PDFSceneTextBox {
        let lines = first.lines + second.lines
        let visualPolicy: PDFSceneTextVisualPolicy
        if first.visualPolicy == .preserveSourcePaint
            || second.visualPolicy == .preserveSourcePaint {
            visualPolicy = .preserveSourcePaint
        } else if first.visualPolicy == .repairSourcePaint
                    || second.visualPolicy == .repairSourcePaint {
            visualPolicy = .repairSourcePaint
        } else {
            visualPolicy = .replaceSourcePaint
        }
        let layoutBounds: CGRect?
        if let firstLayout = first.layoutBounds,
           let secondLayout = second.layoutBounds {
            layoutBounds = firstLayout.union(secondLayout)
        } else {
            layoutBounds = nil
        }
        return PDFSceneTextBox(
            id: "merged-\(first.id)-\(second.id)",
            text: lines.map(\.text).joined(separator: "\n"),
            bounds: first.bounds.union(second.bounds),
            layoutBounds: layoutBounds,
            fontName: first.fontName,
            fontSize: max(first.fontSize, second.fontSize),
            color: first.color,
            alignment: first.alignment,
            lineCount: lines.count,
            sourceLineIDs: first.sourceLineIDs + second.sourceLineIDs,
            extractionSource: first.extractionSource == .visionOCR
                || second.extractionSource == .visionOCR
                ? .visionOCR
                : .native,
            lines: lines,
            visualPolicy: visualPolicy,
            role: .editableContent,
            isOccludedByForeground: false
        )
    }

    static func rasterRepairMasks(
        pageAnalysis: PDFPageAnalysis?,
        textBoxes: [PDFSceneTextBox],
        images: [PDFSceneImage]
    ) -> [PDFSceneRasterRepairMask] {
        guard let pageAnalysis else {
            return images.compactMap { image in
                guard image.canRecreateOnRepairedPage else { return nil }
                return PDFSceneRasterRepairMask(
                    bounds: image.bounds,
                    fallbackBackground: image.backdropColor ?? .white,
                    foregroundColors: [],
                    kind: .imageArea,
                    imagePNGData: image.pngData,
                    imageUsesTransparency: image.hasAlpha || image.maskApplied
                )
            }
        }

        let policyByLineID = Dictionary(
            uniqueKeysWithValues: textBoxes.flatMap { textBox in
                textBox.sourceLineIDs.map { ($0, textBox.visualPolicy) }
            }
        )
        var masks: [PDFSceneRasterRepairMask] = []
        masks.reserveCapacity(pageAnalysis.lines.count + images.count)

        for line in pageAnalysis.lines {
            guard let policy = policyByLineID[line.id],
                  policy.createsEditableText,
                  !line.sourceMaskBounds.isNull,
                  line.sourceMaskBounds.width > 0,
                  line.sourceMaskBounds.height > 0
            else {
                continue
            }
            var foregroundColors = [line.textColor]
            for color in line.runs.map(\.textColor) where !foregroundColors.contains(color) {
                foregroundColors.append(color)
            }
            masks.append(
                PDFSceneRasterRepairMask(
                    bounds: line.sourceMaskBounds,
                    fallbackBackground: line.backgroundColor,
                    foregroundColors: foregroundColors,
                    kind: policy.needsAdaptiveBackdropRepair
                        ? .glyphAwareText
                        : .solidText,
                    imagePNGData: nil,
                    imageUsesTransparency: false
                )
            )
        }

        // Pictures are removed only when the XObject has a trustworthy,
        // axis-aligned placement. Their PNG (including its original alpha or
        // soft mask) is then added back as a selectable Office object.
        for image in images where image.canRecreateOnRepairedPage {
            masks.append(
                PDFSceneRasterRepairMask(
                    bounds: image.bounds,
                    fallbackBackground: image.backdropColor ?? .white,
                    foregroundColors: [],
                    kind: .imageArea,
                    imagePNGData: image.pngData,
                    imageUsesTransparency: image.hasAlpha || image.maskApplied
                )
            )
        }
        return masks
    }

    func renderPage(
        _ page: PDFPage,
        cropBox: CGRect,
        masks: [PDFSceneRasterRepairMask]
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

        // Convert the rendered page into a background/template layer. A
        // solid source backdrop can be replaced directly; a gradient or
        // watermark is repaired only at glyph pixels, preserving the rest of
        // the source artwork. Images use an area repair before their decoded
        // PNG is reintroduced as a real Office picture.
        for mask in masks {
            let bounds = mask.bounds
            guard !bounds.isNull,
                  bounds.width > 0,
                  bounds.height > 0
            else { continue }
            let rawPixelRect = CGRect(
                x: (bounds.minX - cropBox.minX) * scale,
                // Pixel-repair routines operate on the bitmap's raw memory,
                // whose addressable rows are top-down. This is intentionally
                // different from CGContext's drawing coordinates (bottom-up).
                // Keep the conversion here and write solid masks directly to
                // bytes as well, rather than mixing the two coordinate spaces.
                y: (cropBox.maxY - bounds.maxY) * scale,
                width: bounds.width * scale,
                height: bounds.height * scale
            )
            let pagePixels = CGRect(x: 0, y: 0, width: width, height: height)
            // PDF selection rectangles can end on a glyph's antialiased top
            // or bottom pixel.  Clear one *raster* pixel beyond a text mask
            // so that a surviving antialias fringe cannot appear under the
            // editable Office text. An image must retain its exact placement
            // rectangle, however: alpha inversion maps each rendered pixel
            // back to the source PNG and an expanded rectangle would create a
            // false white border around otherwise transparent artwork.
            let pixelRect: CGRect
            switch mask.kind {
            case .imageArea:
                pixelRect = rawPixelRect.integral.intersection(pagePixels)
            case .solidText, .glyphAwareText:
                pixelRect = rawPixelRect
                    .insetBy(dx: -1, dy: -1)
                    .integral
                    .intersection(pagePixels)
            }
            guard !pixelRect.isNull,
                  pixelRect.width > 0,
                  pixelRect.height > 0
            else { continue }

            switch mask.kind {
            case .solidText:
                // The analysis stage has already proved this mask's halo is
                // uniform. Sampling *inside* a compact bold word here is
                // incorrect because the word itself can become the dominant
                // colour (black "Sales Talk" was copied straight back into
                // the template). Use the independently measured backdrop.
                fillRaster(pixelRect, with: mask.fallbackBackground, in: context)
            case .glyphAwareText:
                _ = repairGlyphPaint(
                    in: pixelRect,
                    foregroundColors: mask.foregroundColors,
                    fallbackBackground: mask.fallbackBackground,
                    context: context
                )
            case .imageArea:
                if mask.imageUsesTransparency,
                   let pngData = mask.imagePNGData,
                   let sourceImage = PDFSceneRasterImage(pngData: pngData) {
                    repairTransparentImageArea(
                        in: pixelRect,
                        sourcePlacement: rawPixelRect,
                        sourceImage: sourceImage,
                        fallbackBackground: mask.fallbackBackground,
                        context: context
                    )
                } else {
                    repairArea(
                        in: pixelRect,
                        fallbackBackground: mask.fallbackBackground,
                        context: context
                    )
                }
            }
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

    /// Fills a rectangle expressed in bitmap-memory coordinates (row zero is
    /// the top row). CGContext's `fill(_:)` uses the inverse y-axis, so using
    /// it for this path would move a correct PDF mask to its mirrored output
    /// position. Direct bytes also avoid a second alpha/compositing pass.
    func fillRaster(
        _ rect: CGRect,
        with color: PDFTextColor,
        in context: CGContext
    ) {
        guard context.bitsPerComponent == 8,
              context.bytesPerRow >= context.width * 4,
              let data = context.data
        else {
            // This is a defensive fallback for unusual non-addressable
            // contexts. Translate the memory-space rectangle into CGContext
            // coordinates before drawing it.
            let contextRect = CGRect(
                x: rect.minX,
                y: CGFloat(context.height) - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            context.saveGState()
            context.setShouldAntialias(false)
            context.setBlendMode(.copy)
            context.setFillColor(
                CGColor(
                    red: color.red,
                    green: color.green,
                    blue: color.blue,
                    alpha: 1
                )
            )
            context.fill(contextRect)
            context.restoreGState()
            return
        }
        let minimumX = max(0, Int(rect.minX.rounded(.down)))
        let maximumX = min(context.width - 1, Int((rect.maxX - 1).rounded(.down)))
        let minimumY = max(0, Int(rect.minY.rounded(.down)))
        let maximumY = min(context.height - 1, Int((rect.maxY - 1).rounded(.down)))
        guard minimumX <= maximumX, minimumY <= maximumY else { return }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let red = UInt8(max(0, min(255, Int((color.red * 255).rounded()))))
        let green = UInt8(max(0, min(255, Int((color.green * 255).rounded()))))
        let blue = UInt8(max(0, min(255, Int((color.blue * 255).rounded()))))
        for y in minimumY...maximumY {
            for x in minimumX...maximumX {
                let offset = y * context.bytesPerRow + x * 4
                pixels[offset] = red
                pixels[offset + 1] = green
                pixels[offset + 2] = blue
                pixels[offset + 3] = 255
            }
        }
    }

    /// Removes only source glyph pixels from a textured/gradient text area.
    /// The expected local backdrop is interpolated from pixels just outside
    /// the selection rectangle; a pixel is repaired only when it lies on the
    /// alpha-blend line between that backdrop and a known source text colour.
    /// This avoids the white/grey rectangular patches created by filling the
    /// entire text selection with one sampled colour.
    func repairGlyphPaint(
        in rect: CGRect,
        foregroundColors: [PDFTextColor],
        fallbackBackground: PDFTextColor,
        context: CGContext
    ) -> Int {
        repairBackdrop(
            in: rect,
            foregroundColors: foregroundColors,
            fallbackBackground: fallbackBackground,
            glyphOnly: true,
            context: context
        )
    }

    /// Reconstructs an image placement's immediate backdrop before the
    /// decoded image is inserted as an independent Office picture. This is
    /// intentionally used only for axis-aligned, non-page-sized image
    /// XObjects; photos/diagrams remain intact as individual editable images.
    func repairArea(
        in rect: CGRect,
        fallbackBackground: PDFTextColor,
        context: CGContext
    ) {
        _ = repairBackdrop(
            in: rect,
            foregroundColors: [],
            fallbackBackground: fallbackBackground,
            glyphOnly: false,
            context: context
        )
    }

    /// Removes an alpha or soft-masked PDF image from the page template
    /// without treating its transparent extent as a solid rectangle. For a
    /// source-over composite C = a·I + (1-a)·B, pixels with 0 < a < 1 let us
    /// solve B exactly. Fully transparent pixels are restored verbatim, and
    /// fully opaque pixels use the local backdrop interpolation because they
    /// will be covered exactly by the selectable Office image above it.
    func repairTransparentImageArea(
        in rect: CGRect,
        sourcePlacement: CGRect,
        sourceImage: PDFSceneRasterImage,
        fallbackBackground: PDFTextColor,
        context: CGContext
    ) {
        guard sourcePlacement.width > 0,
              sourcePlacement.height > 0,
              context.bitsPerComponent == 8,
              context.bytesPerRow >= context.width * 4,
              let data = context.data
        else {
            repairArea(in: rect, fallbackBackground: fallbackBackground, context: context)
            return
        }

        let minimumX = max(0, Int(rect.minX.rounded(.down)))
        let maximumX = min(context.width - 1, Int((rect.maxX - 1).rounded(.down)))
        let minimumY = max(0, Int(rect.minY.rounded(.down)))
        let maximumY = min(context.height - 1, Int((rect.maxY - 1).rounded(.down)))
        guard minimumX <= maximumX, minimumY <= maximumY else { return }

        let width = maximumX - minimumX + 1
        let height = maximumY - minimumY + 1
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var original = Array(repeating: UInt8(0), count: width * height * 4)
        for y in minimumY...maximumY {
            let sourceOffset = y * context.bytesPerRow + minimumX * 4
            let destinationOffset = (y - minimumY) * width * 4
            for offset in 0..<(width * 4) {
                original[destinationOffset + offset] = pixels[sourceOffset + offset]
            }
        }

        let flipVertically = sourceImageShouldFlipVertically(
            sourceImage,
            originalPixels: original,
            minimumX: minimumX,
            minimumY: minimumY,
            width: width,
            height: height,
            sourcePlacement: sourcePlacement
        )

        // First make a locally smooth backdrop for opaque source pixels.
        // This keeps the template useful when a user moves the extracted
        // picture later.  The original samples below are then restored or
        // inverse-composited wherever the image exposed any background.
        _ = repairBackdrop(
            in: rect,
            foregroundColors: [],
            fallbackBackground: fallbackBackground,
            glyphOnly: false,
            context: context
        )

        for y in minimumY...maximumY {
            if Task.isCancelled { return }
            for x in minimumX...maximumX {
                let u = (CGFloat(x) + 0.5 - sourcePlacement.minX)
                    / sourcePlacement.width
                let v = (CGFloat(y) + 0.5 - sourcePlacement.minY)
                    / sourcePlacement.height
                guard u >= 0, u <= 1, v >= 0, v <= 1 else { continue }
                let source = sourceImage.sample(
                    normalizedX: u,
                    normalizedY: v,
                    flipVertically: flipVertically
                )
                let originalOffset = ((y - minimumY) * width + (x - minimumX)) * 4
                let destinationOffset = y * context.bytesPerRow + x * 4

                // Nothing was painted at this pixel. Keeping the exact page
                // raster preserves gradients, watermark art and thin borders
                // that can run through a transparent image's bounding box.
                if source.alpha <= 1.0 / 255.0 {
                    pixels[destinationOffset] = original[originalOffset]
                    pixels[destinationOffset + 1] = original[originalOffset + 1]
                    pixels[destinationOffset + 2] = original[originalOffset + 2]
                    pixels[destinationOffset + 3] = original[originalOffset + 3]
                    continue
                }

                // For a partially transparent antialias/soft-mask pixel,
                // undo the original PDF source-over blend.  A threshold just
                // below one avoids numerical amplification at opaque glyph
                // interiors; those are safely covered by the reinserted PNG.
                guard source.alpha < 0.985 else { continue }
                let originalAlpha = max(
                    CGFloat(original[originalOffset + 3]) / 255,
                    1.0 / 255.0
                )
                let observedRed = min(
                    1,
                    CGFloat(original[originalOffset]) / 255 / originalAlpha
                )
                let observedGreen = min(
                    1,
                    CGFloat(original[originalOffset + 1]) / 255 / originalAlpha
                )
                let observedBlue = min(
                    1,
                    CGFloat(original[originalOffset + 2]) / 255 / originalAlpha
                )
                let inverseAlpha = 1 / max(1.0 / 255.0, 1 - source.alpha)
                let backgroundRed = min(
                    1,
                    max(0, (observedRed - source.alpha * source.red) * inverseAlpha)
                )
                let backgroundGreen = min(
                    1,
                    max(0, (observedGreen - source.alpha * source.green) * inverseAlpha)
                )
                let backgroundBlue = min(
                    1,
                    max(0, (observedBlue - source.alpha * source.blue) * inverseAlpha)
                )
                pixels[destinationOffset] = UInt8((backgroundRed * 255).rounded())
                pixels[destinationOffset + 1] = UInt8((backgroundGreen * 255).rounded())
                pixels[destinationOffset + 2] = UInt8((backgroundBlue * 255).rounded())
                pixels[destinationOffset + 3] = 255
            }
        }
    }

    /// Quartz image data and rendered page buffers do not promise the same
    /// row orientation. Compare their high-alpha source pixels at the actual
    /// placement rather than hard-coding an assumption; this works for both
    /// image XObjects and soft masks produced by different PDF generators.
    func sourceImageShouldFlipVertically(
        _ sourceImage: PDFSceneRasterImage,
        originalPixels: [UInt8],
        minimumX: Int,
        minimumY: Int,
        width: Int,
        height: Int,
        sourcePlacement: CGRect
    ) -> Bool {
        guard width > 0,
              height > 0,
              sourcePlacement.width > 0,
              sourcePlacement.height > 0
        else {
            return false
        }

        let horizontalStride = max(1, width / 32)
        let verticalStride = max(1, height / 16)
        var normalError: CGFloat = 0
        var flippedError: CGFloat = 0
        var sampleCount: CGFloat = 0
        for localY in stride(from: 0, to: height, by: verticalStride) {
            for localX in stride(from: 0, to: width, by: horizontalStride) {
                let x = minimumX + localX
                let y = minimumY + localY
                let u = (CGFloat(x) + 0.5 - sourcePlacement.minX)
                    / sourcePlacement.width
                let v = (CGFloat(y) + 0.5 - sourcePlacement.minY)
                    / sourcePlacement.height
                guard u >= 0, u <= 1, v >= 0, v <= 1 else { continue }
                let normal = sourceImage.sample(
                    normalizedX: u,
                    normalizedY: v,
                    flipVertically: false
                )
                let flipped = sourceImage.sample(
                    normalizedX: u,
                    normalizedY: v,
                    flipVertically: true
                )
                // Opaque source pixels are the least ambiguous orientation
                // probe because the page sample should closely equal the
                // decoded image colour before any local repair happens.
                guard max(normal.alpha, flipped.alpha) >= 0.85 else { continue }
                let offset = (localY * width + localX) * 4
                let observedAlpha = max(
                    CGFloat(originalPixels[offset + 3]) / 255,
                    1.0 / 255.0
                )
                let observed = (
                    red: min(1, CGFloat(originalPixels[offset]) / 255 / observedAlpha),
                    green: min(1, CGFloat(originalPixels[offset + 1]) / 255 / observedAlpha),
                    blue: min(1, CGFloat(originalPixels[offset + 2]) / 255 / observedAlpha)
                )
                func error(for sample: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)) -> CGFloat {
                    let weight = max(0.15, sample.alpha)
                    return weight * (
                        abs(observed.red - sample.red)
                            + abs(observed.green - sample.green)
                            + abs(observed.blue - sample.blue)
                    )
                }
                normalError += error(for: normal)
                flippedError += error(for: flipped)
                sampleCount += 1
            }
        }
        guard sampleCount >= 3 else { return false }
        return flippedError + 0.001 < normalError
    }

    func repairBackdrop(
        in rect: CGRect,
        foregroundColors: [PDFTextColor],
        fallbackBackground: PDFTextColor,
        glyphOnly: Bool,
        context: CGContext
    ) -> Int {
        guard context.bitsPerComponent == 8,
              context.bytesPerRow >= context.width * 4,
              let data = context.data
        else {
            if !glyphOnly {
                fillRaster(rect, with: fallbackBackground, in: context)
            }
            return 0
        }

        let minimumX = max(0, Int(rect.minX.rounded(.down)))
        let maximumX = min(context.width - 1, Int((rect.maxX - 1).rounded(.down)))
        let minimumY = max(0, Int(rect.minY.rounded(.down)))
        let maximumY = min(context.height - 1, Int((rect.maxY - 1).rounded(.down)))
        guard minimumX <= maximumX, minimumY <= maximumY else { return 0 }

        typealias RGB = (red: CGFloat, green: CGFloat, blue: CGFloat)
        let pixels = data.assumingMemoryBound(to: UInt8.self)

        func byte(_ value: CGFloat) -> UInt8 {
            UInt8(max(0, min(255, Int((value * 255).rounded()))))
        }

        func color(atX x: Int, y: Int) -> RGB? {
            guard x >= 0, x < context.width, y >= 0, y < context.height else {
                return nil
            }
            let offset = y * context.bytesPerRow + x * 4
            let alpha = CGFloat(pixels[offset + 3]) / 255
            guard alpha > 1.0 / 255 else { return nil }
            return (
                red: min(1, CGFloat(pixels[offset]) / 255 / alpha),
                green: min(1, CGFloat(pixels[offset + 1]) / 255 / alpha),
                blue: min(1, CGFloat(pixels[offset + 2]) / 255 / alpha)
            )
        }

        func average(aroundX x: Int, y: Int) -> RGB? {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var count: CGFloat = 0
            for sampleY in (y - 1)...(y + 1) {
                for sampleX in (x - 1)...(x + 1) {
                    guard let sample = color(atX: sampleX, y: sampleY) else { continue }
                    red += sample.red
                    green += sample.green
                    blue += sample.blue
                    count += 1
                }
            }
            guard count > 0 else { return nil }
            return (red / count, green / count, blue / count)
        }

        func interpolate(_ first: RGB, _ second: RGB, amount: CGFloat) -> RGB {
            let amount = max(0, min(1, amount))
            return (
                first.red + (second.red - first.red) * amount,
                first.green + (second.green - first.green) * amount,
                first.blue + (second.blue - first.blue) * amount
            )
        }

        // Sample the four outer edges once per row/column, not once per
        // source pixel.  A text box can contain thousands of antialiased
        // pixels; recomputing the same 3x3 edge average for every one turned
        // a normal multi-page deck into minutes of CPU work.  The cached edge
        // values preserve the same local-linear reconstruction model.
        let horizontalEdges: [(RGB?, RGB?)] = (minimumY...maximumY).map { y in
            (
                average(aroundX: minimumX - 3, y: y),
                average(aroundX: maximumX + 3, y: y)
            )
        }
        let verticalEdges: [(RGB?, RGB?)] = (minimumX...maximumX).map { x in
            (
                average(aroundX: x, y: minimumY - 3),
                average(aroundX: x, y: maximumY + 3)
            )
        }

        func expectedBackdrop(atX x: Int, y: Int) -> RGB {
            var totalRed: CGFloat = 0
            var totalGreen: CGFloat = 0
            var totalBlue: CGFloat = 0
            var estimateCount: CGFloat = 0

            func add(_ color: RGB) {
                totalRed += color.red
                totalGreen += color.green
                totalBlue += color.blue
                estimateCount += 1
            }

            let horizontal = horizontalEdges[y - minimumY]
            let left = horizontal.0
            let right = horizontal.1
            if let left, let right {
                let amount = CGFloat(x - minimumX) / CGFloat(max(1, maximumX - minimumX))
                add(interpolate(left, right, amount: amount))
            } else if let left {
                add(left)
            } else if let right {
                add(right)
            }

            let vertical = verticalEdges[x - minimumX]
            let bottom = vertical.0
            let top = vertical.1
            if let bottom, let top {
                let amount = CGFloat(y - minimumY) / CGFloat(max(1, maximumY - minimumY))
                add(interpolate(bottom, top, amount: amount))
            } else if let bottom {
                add(bottom)
            } else if let top {
                add(top)
            }

            guard estimateCount > 0 else {
                return (
                    fallbackBackground.red,
                    fallbackBackground.green,
                    fallbackBackground.blue
                )
            }
            return (
                totalRed / estimateCount,
                totalGreen / estimateCount,
                totalBlue / estimateCount
            )
        }

        func isSourceGlyph(_ observed: RGB, against backdrop: RGB) -> Bool {
            for foreground in foregroundColors where foreground.alpha >= 0.95 {
                let direction = (
                    red: backdrop.red - foreground.red,
                    green: backdrop.green - foreground.green,
                    blue: backdrop.blue - foreground.blue
                )
                let lengthSquared = direction.red * direction.red
                    + direction.green * direction.green
                    + direction.blue * direction.blue
                guard lengthSquared > 0.0025 else { continue }
                let alpha = (
                    (backdrop.red - observed.red) * direction.red
                    + (backdrop.green - observed.green) * direction.green
                    + (backdrop.blue - observed.blue) * direction.blue
                ) / lengthSquared
                guard alpha >= 0.035, alpha <= 1.05 else { continue }
                let reconstructed = interpolate(backdrop, (
                    foreground.red,
                    foreground.green,
                    foreground.blue
                ), amount: alpha)
                let residual = max(
                    abs(observed.red - reconstructed.red),
                    abs(observed.green - reconstructed.green),
                    abs(observed.blue - reconstructed.blue)
                )
                if residual <= 0.055 {
                    return true
                }
            }
            return false
        }

        let fallbackBackdrop: RGB = (
            fallbackBackground.red,
            fallbackBackground.green,
            fallbackBackground.blue
        )
        var repairedPixelCount = 0
        for y in minimumY...maximumY {
            if Task.isCancelled { return repairedPixelCount }
            for x in minimumX...maximumX {
                guard let observed = color(atX: x, y: y) else { continue }
                let backdrop = expectedBackdrop(atX: x, y: y)
                // The adaptive estimate can be contaminated when a very
                // broad bold glyph reaches both side samples of its own line
                // box.  The analysis service already records a dominant
                // local backdrop; use it as a second, independent classifier
                // rather than leaving the original black glyph beneath the
                // editable Office text.  Both predicates still require the
                // observed pixel to lie on the known text-color blend line.
                let isGlyph = isSourceGlyph(observed, against: backdrop)
                    || isSourceGlyph(observed, against: fallbackBackdrop)
                guard !glyphOnly || isGlyph else {
                    continue
                }
                let offset = y * context.bytesPerRow + x * 4
                pixels[offset] = byte(backdrop.red)
                pixels[offset + 1] = byte(backdrop.green)
                pixels[offset + 2] = byte(backdrop.blue)
                pixels[offset + 3] = 255
                repairedPixelCount += 1
            }
        }
        return repairedPixelCount
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
        let pageTemplate = PDFSceneTemplateObject(
            id: "page-template-\(pageIndex + 1)",
            role: .pageLocalBackground,
            bounds: cropBox,
            confidence: confidence,
            sourceFingerprint: backgroundFingerprint(pageImageData)
        )
        let chromeTemplates = textBoxes
            .filter { $0.role == .templateChrome }
            .map { textBox in
                let verticalCenter = (textBox.bounds.midY - cropBox.minY)
                    / max(1, cropBox.height)
                let role: PDFSceneTemplateRole
                if verticalCenter <= 0.18 {
                    role = .footer
                } else if verticalCenter >= 0.82 {
                    role = .header
                } else {
                    role = .watermark
                }
                return PDFSceneTemplateObject(
                    id: "template-chrome-\(textBox.id)",
                    role: role,
                    bounds: textBox.bounds,
                    confidence: 0.94,
                    sourceFingerprint: shortHash(
                        "\(role.rawValue)|\(textBox.text)|\(textBox.bounds.debugDescription)"
                    )
                )
            }
        return [pageTemplate] + chromeTemplates
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
        // A page's full-background fingerprint is not a reliable proxy for
        // repeated chrome. Two slides can have different body artwork while
        // retaining the exact same header/logo/footer. Count each object
        // fingerprint independently so those elements can still be promoted
        // to a master/header layer.
        var pageCountByFingerprint: [String: Int] = [:]
        for page in pages {
            for fingerprint in Set(page.templateObjects.map(\.sourceFingerprint)) {
                pageCountByFingerprint[fingerprint, default: 0] += 1
            }
        }

        return pages.map { page in
            let templates = page.templateObjects.map { object in
                let isRepeated = pageCountByFingerprint[object.sourceFingerprint, default: 0] > 1
                return PDFSceneTemplateObject(
                    id: object.id,
                    role: isRepeated ? .sharedTemplate : object.role,
                    bounds: object.bounds,
                    confidence: isRepeated
                        ? min(0.99, object.confidence + 0.08)
                        : object.confidence,
                    sourceFingerprint: object.sourceFingerprint
                )
            }
            return PDFScenePage(
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
                usesPageRasterFallback: page.usesPageRasterFallback,
                isNativeCanvasBackground: page.isNativeCanvasBackground
            )
        }
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
    var currentPath: [PDFSceneVectorPathCommand] = []
    var currentPathPoint: CGPoint?
    var currentSubpathStart: CGPoint?
    var vectors: [PDFSceneVector] = []
    /// Counts every graphics painting operation that can affect the relative
    /// stacking of a native image and a native vector.  This is deliberately
    /// distinct from `vectorIdentifier`: one PDF path-paint operation may
    /// contain several rectangles, all of which share one z-order slot.
    var paintOrder = 0
    var vectorIdentifier = 0
    var transform = CGAffineTransform.identity
    var currentOperatorTable: CGPDFOperatorTableRef?
    var formDepth = 0
    /// The visible PDF crop area in the same page coordinate system used by
    /// traced paths. A PDF commonly applies this exact rectangular clip before
    /// drawing a footer or bleed shape that intentionally extends a fraction
    /// of a point past the page edge. Office clips those shapes to the slide
    /// canvas too, so a page-sized clip may safely retain intersecting paths.
    var pageCropBounds: CGRect?
    struct GraphicsState {
        let transform: CGAffineTransform
        let fillColor: PDFTextColor
        let strokeColor: PDFTextColor
        let lineWidth: CGFloat
        let fillColorIsKnown: Bool
        let strokeColorIsKnown: Bool
        let fillColorSpace: SimpleColorSpace
        let strokeColorSpace: SimpleColorSpace
        let clipBounds: CGRect?
        let hasUnsupportedClip: Bool
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
    var clipBounds: CGRect?
    var hasUnsupportedClip = false
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
        trace.pageCropBounds = cropBox.standardized
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
        CGPDFOperatorTableSetCallback(table, "gs", pdfTraceGraphicsState)
        CGPDFOperatorTableSetCallback(table, "Do", pdfTraceDrawXObject)
        CGPDFOperatorTableSetCallback(table, "c", pdfTraceCubic)
        CGPDFOperatorTableSetCallback(table, "v", pdfTraceCubicUsingCurrentPoint)
        CGPDFOperatorTableSetCallback(table, "y", pdfTraceCubicUsingEndPoint)
        trace.currentOperatorTable = table
        trace.scan(stream, table: table, info: info)
        trace.currentOperatorTable = nil
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        let safetyNet = NSBitmapImageRep(data: pageSafetyNetPNG)
        let verifiedVectors = trace.vectors.map { vector in
            PDFSceneVector(
                id: vector.id,
                kind: vector.kind,
                bounds: vector.bounds,
                pathCommands: vector.pathCommands,
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
        return Result(vectors: consolidatedBackgroundVectors(verifiedVectors))
    }

    /// PDF producers frequently paint one callout/table background as a
    /// large rectangle and then replay the same fill for every text line.
    /// Emitting those redundant child rectangles as independent Office
    /// shapes creates the visible horizontal bars reported by users and can
    /// cover text when Office resolves anchors in a different order.  Keep
    /// the visually authoritative outer rectangle and discard only an
    /// entirely contained, same-colour opaque fill; strokes, transparent
    /// paint, and non-rectangular geometry remain untouched.
    static func consolidatedBackgroundVectors(
        _ vectors: [PDFSceneVector]
    ) -> [PDFSceneVector] {
        var kept: [PDFSceneVector] = []
        kept.reserveCapacity(vectors.count)

        for vector in vectors.sorted(by: {
            if $0.paintOrder != $1.paintOrder {
                return $0.paintOrder < $1.paintOrder
            }
            return $0.id < $1.id
        }) {
            guard isConsolidatableBackground(vector) else {
                kept.append(vector)
                continue
            }

            let isContainedByExisting = kept.contains { outer in
                isConsolidatableBackground(outer)
                    && sameOpaqueFill(outer.fill, vector.fill)
                    && containsWithTolerance(outer.bounds, vector.bounds)
            }
            if isContainedByExisting {
                continue
            }

            kept.removeAll { inner in
                isConsolidatableBackground(inner)
                    && sameOpaqueFill(inner.fill, vector.fill)
                    && containsWithTolerance(vector.bounds, inner.bounds)
            }
            kept.append(vector)
        }

        return kept.sorted(by: {
            if $0.paintOrder != $1.paintOrder {
                return $0.paintOrder < $1.paintOrder
            }
            return $0.id < $1.id
        })
    }

    private static func isConsolidatableBackground(
        _ vector: PDFSceneVector
    ) -> Bool {
        vector.kind == .rectangle
            && vector.rotation.isZero
            && vector.pathCommands.isEmpty
            && vector.stroke == nil
            && (vector.fill?.alpha ?? 0) >= 0.999
            && vector.bounds.width > 1
            && vector.bounds.height > 1
    }

    private static func sameOpaqueFill(
        _ lhs: PDFTextColor?,
        _ rhs: PDFTextColor?
    ) -> Bool {
        guard let lhs, let rhs else { return false }
        let difference = max(
            max(abs(lhs.red - rhs.red), abs(lhs.green - rhs.green)),
            max(abs(lhs.blue - rhs.blue), abs(lhs.alpha - rhs.alpha))
        )
        return difference <= 0.012
    }

    private static func containsWithTolerance(
        _ outer: CGRect,
        _ inner: CGRect
    ) -> Bool {
        // A repeated line-fill often leaves only a few points of inset from
        // the outer panel. Use an absolute margin instead of a percentage:
        // the panel may be only slightly wider than its child while still
        // being the authoritative background.
        guard outer.width - inner.width >= 2,
              outer.height - inner.height >= 2
        else { return false }
        return outer.insetBy(dx: -0.75, dy: -0.75).contains(inner)
    }

    func drawXObject(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name),
              let name
        else {
            return
        }
        let parent = CGPDFScannerGetContentStream(scanner)
        guard let xObject = Self.xObject(named: name, in: parent),
              let dictionary = CGPDFStreamGetDictionary(xObject)
        else {
            return
        }

        // Image and vector tracers must count the same PDF paint operations.
        // Earlier versions only advanced this counter for vectors, which
        // made the independently extracted image sequence incomparable to
        // the vector sequence.  A later footer path could then be written
        // underneath a preceding photo simply because both had local order 1.
        guard Self.name(in: dictionary, key: "Subtype") == "Form" else {
            if Self.name(in: dictionary, key: "Subtype") == "Image" {
                paintOrder += 1
            }
            return
        }
        guard let table = currentOperatorTable,
              let resources = Self.dictionary(in: dictionary, key: "Resources"),
              formDepth < 24
        else {
            return
        }

        let savedTransform = transform
        let savedStack = stateStack
        let savedPath = currentPath
        let savedPathPoint = currentPathPoint
        let savedSubpathStart = currentSubpathStart
        let savedRectangles = pendingRectangles
        let savedPathUsesClipping = pathUsesClipping
        let savedPathUnsupported = pathHasUnsupportedGeometry
        let savedClipBounds = clipBounds
        let savedUnsupportedClip = hasUnsupportedClip
        let savedUnsupportedState = usesUnsupportedGraphicsState

        transform = transform.concatenating(Self.formMatrix(in: dictionary))
        currentPath.removeAll(keepingCapacity: true)
        currentPathPoint = nil
        currentSubpathStart = nil
        pendingRectangles.removeAll(keepingCapacity: true)
        pathUsesClipping = false
        pathHasUnsupportedGeometry = false
        formDepth += 1
        let stream = CGPDFContentStreamCreateWithStream(xObject, resources, parent)
        scan(
            stream,
            table: table,
            info: Unmanaged.passUnretained(self).toOpaque()
        )
        CGPDFContentStreamRelease(stream)
        formDepth -= 1

        transform = savedTransform
        stateStack = savedStack
        currentPath = savedPath
        currentPathPoint = savedPathPoint
        currentSubpathStart = savedSubpathStart
        pendingRectangles = savedRectangles
        pathUsesClipping = savedPathUsesClipping
        pathHasUnsupportedGeometry = savedPathUnsupported
        clipBounds = savedClipBounds
        hasUnsupportedClip = savedUnsupportedClip
        usesUnsupportedGraphicsState = savedUnsupportedState
    }

    func applyGraphicsState(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else {
            markUnsupportedGraphicsState()
            return
        }
        let contentStream = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(
            contentStream,
            "ExtGState",
            name
        ),
        CGPDFObjectGetType(object) == .dictionary
        else {
            markUnsupportedGraphicsState()
            return
        }
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dictionary),
              let dictionary,
              Self.usesSupportedBlendAndMask(in: dictionary)
        else {
            markUnsupportedGraphicsState()
            return
        }

        if let alpha = Self.number(in: dictionary, key: "ca") {
            fillColor = Self.withAlpha(fillColor, alpha: alpha)
        }
        if let alpha = Self.number(in: dictionary, key: "CA") {
            strokeColor = Self.withAlpha(strokeColor, alpha: alpha)
        }
    }

    private func scan(
        _ stream: CGPDFContentStreamRef,
        table: CGPDFOperatorTableRef,
        info: UnsafeMutableRawPointer
    ) {
        let scanner = CGPDFScannerCreate(stream, table, info)
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    private static func xObject(
        named name: UnsafePointer<CChar>,
        in contentStream: CGPDFContentStreamRef
    ) -> CGPDFStreamRef? {
        guard let object = CGPDFContentStreamGetResource(
            contentStream,
            "XObject",
            name
        ),
        CGPDFObjectGetType(object) == .stream
        else {
            return nil
        }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream) else {
            return nil
        }
        return stream
    }

    private static func name(
        in dictionary: CGPDFDictionaryRef,
        key: String
    ) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else {
            return nil
        }
        return String(cString: value)
    }

    private static func dictionary(
        in dictionary: CGPDFDictionaryRef,
        key: String
    ) -> CGPDFDictionaryRef? {
        var result: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, key, &result) else {
            return nil
        }
        return result
    }

    private static func number(
        in dictionary: CGPDFDictionaryRef,
        key: String
    ) -> CGFloat? {
        var value: CGPDFReal = 0
        guard CGPDFDictionaryGetNumber(dictionary, key, &value) else {
            return nil
        }
        return min(1, max(0, CGFloat(value)))
    }

    private static func usesSupportedBlendAndMask(
        in dictionary: CGPDFDictionaryRef
    ) -> Bool {
        var blendMode: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "BM", &blendMode),
           let blendMode,
           String(cString: blendMode) != "Normal" {
            return false
        }

        var softMask: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, "SMask", &softMask),
              let softMask
        else {
            return true
        }
        if CGPDFObjectGetType(softMask) == .name {
            var value: UnsafePointer<CChar>?
            return CGPDFObjectGetValue(softMask, .name, &value)
                && value.map { String(cString: $0) == "None" } == true
        }
        return false
    }

    private static func withAlpha(
        _ color: PDFTextColor,
        alpha: CGFloat
    ) -> PDFTextColor {
        PDFTextColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: alpha
        )
    }

    private static func formMatrix(
        in dictionary: CGPDFDictionaryRef
    ) -> CGAffineTransform {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Matrix", &array),
              let array,
              CGPDFArrayGetCount(array) >= 6
        else {
            return .identity
        }
        var values = Array(repeating: CGPDFReal(0), count: 6)
        for index in values.indices {
            guard CGPDFArrayGetNumber(array, index, &values[index]) else {
                return .identity
            }
        }
        return CGAffineTransform(
            a: CGFloat(values[0]),
            b: CGFloat(values[1]),
            c: CGFloat(values[2]),
            d: CGFloat(values[3]),
            tx: CGFloat(values[4]),
            ty: CGFloat(values[5])
        )
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
        if !pendingRectangles.isEmpty {
            pathHasUnsupportedGeometry = true
        }
        currentPath.append(.move(point))
        currentPathPoint = point
        currentSubpathStart = point
    }

    func line(_ scanner: CGPDFScannerRef) {
        guard let point = popPoint(scanner), currentPathPoint != nil else {
            pathHasUnsupportedGeometry = true
            return
        }
        currentPath.append(.line(point))
        currentPathPoint = point
    }

    func closePath() {
        guard currentPathPoint != nil else {
            pathHasUnsupportedGeometry = true
            return
        }
        currentPath.append(.close)
        currentPathPoint = currentSubpathStart
    }

    func cubic(_ scanner: CGPDFScannerRef) {
        guard let end = popPoint(scanner),
              let control2 = popPoint(scanner),
              let control1 = popPoint(scanner),
              currentPathPoint != nil
        else {
            pathHasUnsupportedGeometry = true
            return
        }
        currentPath.append(
            .cubic(control1: control1, control2: control2, end: end)
        )
        currentPathPoint = end
    }

    func cubicUsingCurrentPoint(_ scanner: CGPDFScannerRef) {
        guard let end = popPoint(scanner),
              let control2 = popPoint(scanner),
              let currentPathPoint
        else {
            pathHasUnsupportedGeometry = true
            return
        }
        currentPath.append(
            .cubic(
                control1: currentPathPoint,
                control2: control2,
                end: end
            )
        )
        self.currentPathPoint = end
    }

    func cubicUsingEndPoint(_ scanner: CGPDFScannerRef) {
        guard let end = popPoint(scanner),
              let control1 = popPoint(scanner),
              currentPathPoint != nil
        else {
            pathHasUnsupportedGeometry = true
            return
        }
        currentPath.append(
            .cubic(
                control1: control1,
                control2: end,
                end: end
            )
        )
        currentPathPoint = end
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
        guard currentPath.isEmpty,
              pendingRectangles.count == 1,
              let rectangle = pendingRectangles.first?.bounds
        else {
            hasUnsupportedClip = true
            return
        }
        if let clipBounds {
            self.clipBounds = clipBounds.intersection(rectangle)
        } else {
            clipBounds = rectangle
        }
    }

    func selectFillColorSpace(
        named name: String?,
        scanner: CGPDFScannerRef
    ) {
        fillColorSpace = resolveColorSpace(named: name, scanner: scanner)
        fillColorIsKnown = false
    }

    func selectStrokeColorSpace(
        named name: String?,
        scanner: CGPDFScannerRef
    ) {
        strokeColorSpace = resolveColorSpace(named: name, scanner: scanner)
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
                clipBounds: clipBounds,
                hasUnsupportedClip: hasUnsupportedClip,
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
            clipBounds = nil
            hasUnsupportedClip = false
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
        clipBounds = state.clipBounds
        hasUnsupportedClip = state.hasUnsupportedClip
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

    private func resolveColorSpace(
        named name: String?,
        scanner: CGPDFScannerRef
    ) -> SimpleColorSpace {
        guard let name else {
            return .unsupported
        }
        let directlyNamed = SimpleColorSpace.named(name)
        guard directlyNamed == .unsupported else {
            return directlyNamed
        }
        let contentStream = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(
            contentStream,
            "ColorSpace",
            name
        ) else {
            return .unsupported
        }
        return Self.simpleColorSpace(from: object)
    }

    private static func simpleColorSpace(
        from object: CGPDFObjectRef
    ) -> SimpleColorSpace {
        switch CGPDFObjectGetType(object) {
        case .name:
            var name: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &name),
                  let name
            else {
                return .unsupported
            }
            return SimpleColorSpace.named(String(cString: name))
        case .array:
            var array: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &array),
                  let array,
                  CGPDFArrayGetCount(array) > 0
            else {
                return .unsupported
            }
            var familyName: UnsafePointer<CChar>?
            guard CGPDFArrayGetName(array, 0, &familyName),
                  let familyName
            else {
                return .unsupported
            }
            switch String(cString: familyName) {
            case "ICCBased":
                var profile: CGPDFStreamRef?
                guard CGPDFArrayGetStream(array, 1, &profile),
                      let profile,
                      let profileDictionary = CGPDFStreamGetDictionary(profile)
                else {
                    return .unsupported
                }
                if let alternate = name(in: profileDictionary, key: "Alternate") {
                    return SimpleColorSpace.named(alternate)
                }
                var components: CGPDFInteger = 0
                guard CGPDFDictionaryGetInteger(
                    profileDictionary,
                    "N",
                    &components
                ) else {
                    return .unsupported
                }
                switch components {
                case 1:
                    return .deviceGray
                case 3:
                    return .deviceRGB
                case 4:
                    return .deviceCMYK
                default:
                    return .unsupported
                }
            default:
                return .unsupported
            }
        default:
            return .unsupported
        }
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
        // A PDF `S`, `f`, or `B` operator occupies one position in the
        // graphics stack even if it yields no Office-representable vector.
        // Keep that position so this trace remains comparable with image
        // placements collected from the same content stream.
        paintOrder += 1
        let operationPaintOrder = paintOrder
        let canRepresentPath = !pathUsesClipping
            && !pathHasUnsupportedGeometry
            && !hasUnsupportedClip
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
                    && isWithinActiveClip(rectangle.bounds)
                guard eligible else { continue }
                vectorIdentifier += 1
                vectors.append(
                    PDFSceneVector(
                        id: "vector-\(vectorIdentifier)",
                        kind: .rectangle,
                        bounds: rectangle.bounds,
                        pathCommands: [],
                        stroke: selectedStroke,
                        fill: selectedFill,
                        lineWidth: lineWidth,
                        rotation: rectangle.rotation,
                        paintOrder: operationPaintOrder,
                        nativeEligible: true,
                        isSafetyNetVerifiedOpaque: false
                    )
                )
            }
        }

        let simpleLineEndpoints: (start: CGPoint, end: CGPoint)? = {
            guard currentPath.count == 2,
                  case let .move(start) = currentPath[0],
                  case let .line(end) = currentPath[1]
            else {
                return nil
            }
            return (start, end)
        }()

        if canRepresentPath,
           selectedFill == nil,
           let selectedStroke,
           let simpleLineEndpoints {
            let first = simpleLineEndpoints.start
            let last = simpleLineEndpoints.end
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
                  bounds.height < 100_000,
                  isWithinActiveClip(bounds)
            else {
                resetCurrentPath()
                return
            }
            vectorIdentifier += 1
            vectors.append(
                PDFSceneVector(
                        id: "vector-\(vectorIdentifier)",
                        kind: .line,
                        bounds: bounds,
                        pathCommands: [],
                        stroke: selectedStroke,
                        fill: nil,
                    lineWidth: lineWidth,
                    rotation: atan2(dy, dx) * 180 / .pi,
                    paintOrder: operationPaintOrder,
                    nativeEligible: axisAligned,
                    isSafetyNetVerifiedOpaque: false
                )
            )
        }
        if canRepresentPath,
           (selectedFill != nil || selectedStroke != nil),
           simpleLineEndpoints == nil,
           !currentPath.isEmpty,
           let bounds = pathBounds(currentPath),
           bounds.width.isFinite,
           bounds.height.isFinite,
           bounds.width <= 100_000,
           bounds.height <= 100_000,
           isWithinActiveClip(bounds) {
            vectorIdentifier += 1
            vectors.append(
                PDFSceneVector(
                    id: "vector-\(vectorIdentifier)",
                    kind: .freeform,
                    bounds: bounds,
                    pathCommands: currentPath,
                    stroke: selectedStroke,
                    fill: selectedFill,
                    lineWidth: lineWidth,
                    rotation: 0,
                    paintOrder: operationPaintOrder,
                    nativeEligible: true,
                    isSafetyNetVerifiedOpaque: false
                )
            )
        }
        resetCurrentPath()
    }

    private func resetCurrentPath() {
        pendingRectangles.removeAll(keepingCapacity: true)
        currentPath.removeAll(keepingCapacity: true)
        currentPathPoint = nil
        currentSubpathStart = nil
        pathUsesClipping = false
        pathHasUnsupportedGeometry = false
    }

    private func pathBounds(
        _ commands: [PDFSceneVectorPathCommand]
    ) -> CGRect? {
        let points = commands.flatMap { command -> [CGPoint] in
            switch command {
            case let .move(point), let .line(point):
                [point]
            case let .cubic(control1, control2, end):
                [control1, control2, end]
            case .close:
                []
            }
        }
        guard let first = points.first else {
            return nil
        }
        var minimumX = first.x
        var maximumX = first.x
        var minimumY = first.y
        var maximumY = first.y
        for point in points.dropFirst() {
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
        }
        let halfStroke = max(0, lineWidth * 0.5)
        return CGRect(
            x: minimumX - halfStroke,
            y: minimumY - halfStroke,
            width: maximumX - minimumX + lineWidth,
            height: maximumY - minimumY + lineWidth
        ).standardized
    }

    private func isWithinActiveClip(_ bounds: CGRect) -> Bool {
        guard let clipBounds else {
            return true
        }
        let tolerance: CGFloat = 0.5
        if let pageCropBounds,
           abs(clipBounds.minX - pageCropBounds.minX) <= tolerance,
           abs(clipBounds.minY - pageCropBounds.minY) <= tolerance,
           abs(clipBounds.width - pageCropBounds.width) <= tolerance,
           abs(clipBounds.height - pageCropBounds.height) <= tolerance {
            // The slide canvas reproduces the source page clip. Retain a
            // path that intersects it instead of discarding visible artwork
            // solely because its bleed extends infinitesimally past an edge.
            return bounds.intersects(clipBounds)
        }
        return bounds.minX >= clipBounds.minX - tolerance
            && bounds.maxX <= clipBounds.maxX + tolerance
            && bounds.minY >= clipBounds.minY - tolerance
            && bounds.maxY <= clipBounds.maxY + tolerance
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
        .selectFillColorSpace(named: selectedName, scanner: scanner)
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
        .selectStrokeColorSpace(named: selectedName, scanner: scanner)
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

private func pdfTraceGraphicsState(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue()
        .applyGraphicsState(scanner)
}

private func pdfTraceDrawXObject(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue()
        .drawXObject(scanner)
}

private func pdfTraceCubic(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue()
        .cubic(scanner)
}

private func pdfTraceCubicUsingCurrentPoint(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue()
        .cubicUsingCurrentPoint(scanner)
}

private func pdfTraceCubicUsingEndPoint(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFGraphicsTrace>.fromOpaque(info).takeUnretainedValue()
        .cubicUsingEndPoint(scanner)
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

    /// The PDF image colour spaces that can be losslessly represented as an
    /// RGBA PNG without invoking a platform-specific PDF renderer. Indexed
    /// images are especially common in slide footers, logos, and exports from
    /// presentation tools; their lookup table is preserved here rather than
    /// falling back to a flattened page image.
    private enum DirectImageColorSpace {
        case gray
        case rgb
        case cmyk

        var componentCount: Int {
            switch self {
            case .gray: 1
            case .rgb: 3
            case .cmyk: 4
            }
        }

        func rgb(_ components: ArraySlice<UInt8>) -> (Double, Double, Double)? {
            guard components.count == componentCount else { return nil }
            let normalized = components.map { Double($0) / 255 }
            switch self {
            case .gray:
                guard let gray = normalized.first else { return nil }
                return (gray, gray, gray)
            case .rgb:
                guard normalized.count == 3 else { return nil }
                return (normalized[0], normalized[1], normalized[2])
            case .cmyk:
                guard normalized.count == 4 else { return nil }
                return (
                    1 - min(1, normalized[0] + normalized[3]),
                    1 - min(1, normalized[1] + normalized[3]),
                    1 - min(1, normalized[2] + normalized[3])
                )
            }
        }
    }

    private struct IndexedImageColorSpace {
        let base: DirectImageColorSpace
        let maximumIndex: Int
        let lookup: [UInt8]

        func rgb(for index: Int) -> (Double, Double, Double)? {
            let boundedIndex = min(max(0, index), maximumIndex)
            let componentCount = base.componentCount
            let offset = boundedIndex * componentCount
            guard offset >= 0, offset + componentCount <= lookup.count else {
                return nil
            }
            return base.rgb(lookup[offset..<(offset + componentCount)])
        }
    }

    private enum ImageColorSpace {
        case direct(DirectImageColorSpace)
        case indexed(IndexedImageColorSpace)

        var componentCount: Int {
            switch self {
            case let .direct(space): space.componentCount
            case .indexed: 1
            }
        }
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
        let placements = PDFImagePlacementTrace.trace(
            page: page,
            cropBox: cropBox
        )
        let occurrenceCount = placements.isEmpty ? records.count : placements.count
        let pageSafetyNet = NSBitmapImageRep(data: pageSafetyNetPNG)
        var extracted: [PDFSceneImage] = []
        extracted.reserveCapacity(placements.count)
        for (order, placement) in placements.enumerated() {
            let record = ImageRecord(
                name: placement.name,
                stream: placement.stream,
                dictionary: placement.dictionary
            )
            guard let decoded = decode(record: record, maximumDimension: maximumDimension) else {
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
            // DrawingML pictures expose independent horizontal and vertical
            // extents, so ordinary non-uniform PDF scaling remains exactly
            // representable. Only rotation or shear needs a richer transform
            // serializer; those are already rejected by the placement trace.
            let hasRepresentableGeometry = placement.isAxisAligned
                && !placement.hasUnsupportedClip
            let canBeIndependent = isFullyOpaque
                && !decoded.maskApplied
                && !isPageBackdrop
            let localBackdrop = isFullyOpaque
                ? nil
                : locallyUniformBackdrop(
                    around: safeBounds,
                    cropBox: cropBox,
                    bitmap: pageSafetyNet
                )
            let safetyNetMatch: SafetyNetImageMatch?
            if isFullyOpaque {
                safetyNetMatch = imageSafetyNetMatch(
                    decoded,
                    placement: safeBounds,
                    cropBox: cropBox,
                    bitmap: pageSafetyNet
                )
            } else if let localBackdrop {
                // Unlike an opaque image, an alpha image cannot be compared
                // to the page pixels directly. Compare its expected
                // source-over composite on the independently sampled
                // backdrop instead. This also catches later paint inside an
                // otherwise transparent image extent.
                safetyNetMatch = imageSafetyNetMatch(
                    decoded,
                    placement: safeBounds,
                    cropBox: cropBox,
                    bitmap: pageSafetyNet,
                    backdrop: localBackdrop
                )
            } else {
                safetyNetMatch = nil
            }
            let matchesSafetyNet = safetyNetMatch?.matches ?? false
            let inkVisibility = !isFullyOpaque
                ? alphaInkVisibility(
                    decoded,
                    placement: safeBounds,
                    cropBox: cropBox,
                    bitmap: pageSafetyNet
                )
                : nil
            let isVisibleInLayeredTemplate = isFullyOpaque
                ? matchesSafetyNet
                : (inkVisibility?.matches ?? matchesSafetyNet)
            let shouldFlipVertically = safetyNetMatch?.isVerticallyFlipped
                ?? inkVisibility?.isVerticallyFlipped
                ?? false
            let officeImage = shouldFlipVertically
                ? verticallyFlipped(decoded)
                : decoded
            guard let pngData = pngData(from: officeImage) else {
                continue
            }
            // Every promoted image, including one with an alpha or soft mask,
            // must match the final rendered page at its original z-order.
            // Otherwise a later PDF object could be hidden when PowerPoint
            // reinserts the source image above the repaired template.
            let isNativeObjectEligible = !isPageBackdrop
                && hasRepresentableGeometry
                && matchesSafetyNet
            extracted.append(
                PDFSceneImage(
                    id: "pdf-image-\(pageIndex + 1)-\(order + 1)",
                    sourceName: record.name,
                    bounds: safeBounds,
                    pngData: pngData,
                    paintOrder: placement.paintOrder,
                    hasAlpha: decoded.hasAlpha,
                    maskApplied: decoded.maskApplied,
                    backdropColor: localBackdrop,
                    // A page-sized image is itself the visual safety-net or
                    // a template backdrop. Replaying it over that safety-net
                    // would hide logos/text that were painted later.
                    isBackdropIndependent: canBeIndependent,
                    isSafetyNetVerifiedOpaque: isFullyOpaque && matchesSafetyNet,
                    hasRepresentableGeometry: hasRepresentableGeometry,
                    isNativeObjectEligible: isNativeObjectEligible,
                    isLayeredTemplateEligible: !isPageBackdrop
                        && hasRepresentableGeometry
                        && isVisibleInLayeredTemplate,
                    hasVisibleReferenceContribution: !isPageBackdrop
                        && isVisibleInLayeredTemplate,
                    clip: placement.clip
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
        let colorSpace = imageColorSpace(record.dictionary)
            ?? (record.name == "mask" ? .direct(.gray) : nil)
        let effectiveColorSpace: ImageColorSpace
        if imageMask {
            effectiveColorSpace = .direct(.gray)
        } else if let colorSpace {
            effectiveColorSpace = colorSpace
        } else {
            return nil
        }
        let channels = effectiveColorSpace.componentCount
        guard bits == 1 || bits == 2 || bits == 4 || bits == 8 else { return nil }

        let widthInt = Int(width)
        let heightInt = Int(height)
        let rowBytes = (widthInt * channels * Int(bits) + 7) / 8
        guard rowBytes > 0,
              data.count >= rowBytes * heightInt
        else { return nil }

        let decodeValues = decodeArray(
            record.dictionary,
            count: channels,
            defaultRange: {
                if case let .indexed(indexed) = effectiveColorSpace {
                    return (0, Double(indexed.maximumIndex))
                }
                return (0, 1)
            }()
        )
        let colorKeyRanges = imageMask
            ? nil
            : colorKeyMaskRanges(
                record.dictionary,
                componentCount: channels
            )
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
                    // Indexed PDF colour spaces address a palette with the
                    // decoded sample value (0...maxIndex), not a normalized
                    // 0...1 component. Mapping an 8-bit index through the
                    // generic component path collapses indices 0, 1 and 2 to
                    // the first palette entry and turns real logos into white
                    // silhouettes when a soft mask is present.
                    if case let .indexed(indexed) = effectiveColorSpace {
                        samples[channel] = min(
                            Double(indexed.maximumIndex),
                            Double(sample)
                        )
                    } else {
                        let normalized = Double(sample) / maxSample
                        let low = decodeValues[channel * 2]
                        let high = decodeValues[channel * 2 + 1]
                        samples[channel] = low + normalized * (high - low)
                    }
                }

                let isColorKeyTransparent = colorKeyRanges.map {
                    samplesMatchColorKey(samples, ranges: $0)
                } ?? false

                let rgb: (Double, Double, Double)
                if imageMask {
                    let on = samples[0] >= 0.5
                    rgb = on ? (0, 0, 0) : (1, 1, 1)
                } else {
                    switch effectiveColorSpace {
                    case let .direct(space):
                        switch space {
                        case .gray:
                            rgb = (samples[0], samples[0], samples[0])
                        case .rgb:
                            rgb = (samples[0], samples[1], samples[2])
                        case .cmyk:
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
                    case let .indexed(indexed):
                        let index = Int(samples[0].rounded())
                        guard let paletteRGB = indexed.rgb(for: index) else {
                            return nil
                        }
                        rgb = paletteRGB
                    }
                }
                let destination = (y * widthInt + x) * 4
                rgba[destination] = byte(rgb.0)
                rgba[destination + 1] = byte(rgb.1)
                rgba[destination + 2] = byte(rgb.2)
                rgba[destination + 3] = imageMask || isColorKeyTransparent ? 0 : 255
            }
        }

        var result = DecodedImage(
            width: widthInt,
            height: heightInt,
            rgba: rgba,
            hasAlpha: imageMask || colorKeyRanges != nil,
            maskApplied: imageMask || colorKeyRanges != nil
        )
        applyMask(
            record.dictionary,
            to: &result,
            colorKeyWasApplied: colorKeyRanges != nil
        )
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
        // Quartz rendered into premultiplied-last storage above. The PNG
        // writer deliberately emits straight-alpha RGBA so Office preserves
        // a soft mask rather than interpreting dark premultiplied edge pixels
        // as opaque black. Normalize the buffer once at extraction time.
        if hasAlpha {
            for offset in stride(from: 0, to: rgba.count, by: 4) {
                let alpha = Int(rgba[offset + 3])
                guard alpha > 0 else {
                    rgba[offset] = 0
                    rgba[offset + 1] = 0
                    rgba[offset + 2] = 0
                    continue
                }
                rgba[offset] = UInt8(min(255, (Int(rgba[offset]) * 255 + alpha / 2) / alpha))
                rgba[offset + 1] = UInt8(min(255, (Int(rgba[offset + 1]) * 255 + alpha / 2) / alpha))
                rgba[offset + 2] = UInt8(min(255, (Int(rgba[offset + 2]) * 255 + alpha / 2) / alpha))
            }
        }
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
        to image: inout DecodedImage,
        colorKeyWasApplied: Bool = false
    ) {
        var softMaskObject: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dictionary, "SMask", &softMaskObject),
           let softMaskObject {
            applyStreamMask(softMaskObject, to: &image)
            return
        }

        var maskObject: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, "Mask", &maskObject),
              let maskObject
        else {
            return
        }

        if CGPDFObjectGetType(maskObject) == .array {
            guard !colorKeyWasApplied else { return }
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

        applyStreamMask(maskObject, to: &image)
    }

    private static func applyStreamMask(
        _ maskObject: CGPDFObjectRef,
        to image: inout DecodedImage
    ) {
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

    /// A `/Mask [min max ...]` colour-key is expressed in the image's source
    /// colour space. For an `/Indexed` image that component is the palette
    /// index, not the final RGB value. Applying it after palette conversion
    /// caused fully transparent copyright/footer assets in exported slides.
    private static func colorKeyMaskRanges(
        _ dictionary: CGPDFDictionaryRef,
        componentCount: Int
    ) -> [(Double, Double)]? {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, "Mask", &object),
              let object,
              CGPDFObjectGetType(object) == .array
        else {
            return nil
        }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array),
              let array,
              CGPDFArrayGetCount(array) >= componentCount * 2
        else {
            return nil
        }
        return (0..<componentCount).map { index in
            (
                number(array, index: index * 2) ?? 0,
                number(array, index: index * 2 + 1) ?? 1
            )
        }
    }

    private static func samplesMatchColorKey(
        _ samples: [Double],
        ranges: [(Double, Double)]
    ) -> Bool {
        guard samples.count >= ranges.count else { return false }
        return ranges.enumerated().allSatisfy { index, range in
            let lower = min(range.0, range.1)
            let upper = max(range.0, range.1)
            return samples[index] >= lower && samples[index] <= upper
        }
    }

    /// An opaque image may be replayed on top of the full-page fallback only
    /// if its own decoded pixels are already the final visible pixels at that
    /// placement. This catches images that sit below later text, images with a
    /// missed transform, and any decoder/color-space disagreement before they
    /// can cover correct fallback content in the Office document.
    private struct SafetyNetImageMatch {
        let meanDifference: Double
        let mismatchRatio: Double
        let mismatchRegion: MismatchRegionMetrics
        /// The fraction of direct mismatches that occur at a strong edge in
        /// the decoded source asset. A compact group of those mismatches is
        /// normally a one-pixel sampling/registration difference around
        /// screenshots, not later PDF paint. A true overpaint also changes
        /// the source image interior, where this value stays low.
        let edgeSupportedMismatchRatio: Double
        let colorTransform: ColorTransformVerification?
        let isVerticallyFlipped: Bool

        var matches: Bool {
            // Quartz and Office do not sample scaled bitmap pixels at the
            // exact same sub-pixel coordinates. A genuine source image can
            // therefore have a small set of high-contrast pixels above the
            // per-channel threshold even though its mean RGB error is tiny.
            // Keep the two gates together: this admits normal resampling
            // noise (such as screenshots on a slide) but still rejects a
            // later opaque paint layer, which produces a much larger mean
            // error across its covered region.
            let compactMismatchFollowsSourceEdge = mismatchRegion.ratio <= 0.025
                && edgeSupportedMismatchRatio >= 0.70
            if meanDifference <= 10,
               mismatchRatio <= 0.12,
               (mismatchRegion.isConsistentWithResampling
                   || compactMismatchFollowsSourceEdge) {
                return true
            }

            // PDF image streams can legitimately use an ICC/device colour
            // transform that Quartz applies when the page is rendered. The
            // raw decoded RGB then differs at every sample even though the
            // image is the final visible paint. Allow that only when a
            // monotonic per-channel curve explains the *whole* placement.
            // A later rectangle, clipping error, or wrong image breaks the
            // robust residual map and remains in the raster.
            return meanDifference <= 28
                && (colorTransform?.supportsColorManagedMatch ?? false)
        }

        var score: Double {
            meanDifference + mismatchRatio * 255
        }
    }

    /// Alpha/masked assets cannot be matched against a single uniform
    /// backdrop when they sit on a gradient or a reconstructed vector. Their
    /// opaque logo/illustration pixels still provide a reliable visibility
    /// proof: a later PDF object that covers the asset removes that coloured
    /// ink from the rendered reference page. This prevents a hidden footer
    /// logo from being reinserted above a later banner while retaining a
    /// visible transparent logo as a native Office picture.
    private struct AlphaInkVisibility {
        let highOpacitySampleCount: Int
        let matchingSampleCount: Int
        let saturatedSampleCount: Int
        let matchingSaturatedSampleCount: Int
        let isVerticallyFlipped: Bool

        var matches: Bool {
            guard highOpacitySampleCount >= 8 else { return false }
            let matchRatio = Double(matchingSampleCount) / Double(highOpacitySampleCount)
            guard matchRatio >= 0.58 else { return false }
            guard saturatedSampleCount >= 4 else { return true }
            return Double(matchingSaturatedSampleCount) / Double(saturatedSampleCount) >= 0.42
        }

        var score: Double {
            guard highOpacitySampleCount > 0 else { return -.infinity }
            return Double(matchingSampleCount) / Double(highOpacitySampleCount)
                + (saturatedSampleCount > 0
                    ? Double(matchingSaturatedSampleCount) / Double(saturatedSampleCount) * 0.25
                    : 0)
        }
    }

    private struct SafetyNetColorSample {
        let sourceRed: Double
        let sourceGreen: Double
        let sourceBlue: Double
        let renderedRed: Double
        let renderedGreen: Double
        let renderedBlue: Double
    }

    private struct ColorTransformVerification {
        let meanResidual: Double
        let maximumResidual: Double
        let mismatchRatio: Double
        let mismatchRegion: MismatchRegionMetrics
        let minimumRetainedDynamicRange: Double
        let activeChannelCount: Int
        let hasPlausibleMonotonicCurves: Bool

        var supportsColorManagedMatch: Bool {
            activeChannelCount >= 1
                && hasPlausibleMonotonicCurves
                && minimumRetainedDynamicRange >= 0.25
                && meanResidual <= 5
                && maximumResidual <= 40
                // PDF image sampling and alpha compositing can create a few
                // sub-pixel edge outliers after the monotonic curve has been
                // fitted. The ratio bound still rejects a later painted
                // region instead of relaxing the whole image.
                && mismatchRatio <= 0.05
        }
    }

    private struct MismatchRegionMetrics {
        let ratio: Double
        let fillRatio: Double

        /// A later rectangle is a compact, filled connected area. Scaling
        /// noise instead follows sparse contours of the source artwork.
        var isConsistentWithResampling: Bool {
            ratio <= 0.015 || (ratio <= 0.04 && fillRatio <= 0.25)
        }
    }

    private static func imageSafetyNetMatch(
        _ image: DecodedImage,
        placement: CGRect,
        cropBox: CGRect,
        bitmap: NSBitmapImageRep?,
        backdrop: PDFTextColor? = nil
    ) -> SafetyNetImageMatch? {
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
            return nil
        }

        let columns = min(64, max(12, Int((placement.width / 10).rounded())))
        let rows = min(64, max(12, Int((placement.height / 10).rounded())))
        let bitmapScaleX = CGFloat(bitmap.pixelsWide) / cropBox.width
        let bitmapScaleY = CGFloat(bitmap.pixelsHigh) / cropBox.height
        let sampleCount = columns * rows

        func compare(flipVertically: Bool) -> SafetyNetImageMatch? {
            var totalDifference = 0.0
            var mismatchedSamples = 0
            var edgeSupportedMismatchSamples = 0
            var directMismatchFlags = Array(repeating: false, count: sampleCount)
            var colorSamples: [SafetyNetColorSample] = []
            colorSamples.reserveCapacity(sampleCount)

            func hasStrongSourceEdge(atX x: Int, y: Int) -> Bool {
                let sourceOffset = (y * image.width + x) * 4
                let red = Int(image.rgba[sourceOffset])
                let green = Int(image.rgba[sourceOffset + 1])
                let blue = Int(image.rgba[sourceOffset + 2])
                let neighbors = [
                    (max(0, x - 1), y),
                    (min(image.width - 1, x + 1), y),
                    (x, max(0, y - 1)),
                    (x, min(image.height - 1, y + 1))
                ]
                for (neighborX, neighborY) in neighbors {
                    let neighborOffset = (neighborY * image.width + neighborX) * 4
                    let difference = max(
                        abs(red - Int(image.rgba[neighborOffset])),
                        abs(green - Int(image.rgba[neighborOffset + 1])),
                        abs(blue - Int(image.rgba[neighborOffset + 2]))
                    )
                    if difference >= 32 {
                        return true
                    }
                }
                return false
            }

            for row in 0..<rows {
                let v = (CGFloat(row) + 0.5) / CGFloat(rows)
                let sourceV = flipVertically ? 1 - v : v
                let imageY = min(
                    image.height - 1,
                    max(0, Int((sourceV * CGFloat(image.height - 1)).rounded()))
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
                        return nil
                    }
                    let sourceOffset = (imageY * image.width + imageX) * 4
                    let renderedRed = Double((pageColor.redComponent * 255).rounded())
                    let renderedGreen = Double((pageColor.greenComponent * 255).rounded())
                    let renderedBlue = Double((pageColor.blueComponent * 255).rounded())
                    let sourceAlpha = backdrop.map { _ in
                        Double(image.rgba[sourceOffset + 3]) / 255
                    } ?? 1
                    let expectedRed: Double
                    let expectedGreen: Double
                    let expectedBlue: Double
                    if let backdrop {
                        expectedRed = sourceAlpha * Double(image.rgba[sourceOffset])
                            + (1 - sourceAlpha) * Double(backdrop.red * 255)
                        expectedGreen = sourceAlpha * Double(image.rgba[sourceOffset + 1])
                            + (1 - sourceAlpha) * Double(backdrop.green * 255)
                        expectedBlue = sourceAlpha * Double(image.rgba[sourceOffset + 2])
                            + (1 - sourceAlpha) * Double(backdrop.blue * 255)
                    } else {
                        expectedRed = Double(image.rgba[sourceOffset])
                        expectedGreen = Double(image.rgba[sourceOffset + 1])
                        expectedBlue = Double(image.rgba[sourceOffset + 2])
                    }
                    let difference = max(
                        abs(expectedRed - renderedRed),
                        abs(expectedGreen - renderedGreen),
                        abs(expectedBlue - renderedBlue)
                    )
                    colorSamples.append(
                        SafetyNetColorSample(
                            sourceRed: expectedRed,
                            sourceGreen: expectedGreen,
                            sourceBlue: expectedBlue,
                            renderedRed: renderedRed,
                            renderedGreen: renderedGreen,
                            renderedBlue: renderedBlue
                        )
                    )
                    totalDifference += Double(difference)
                    if difference > 16 {
                        mismatchedSamples += 1
                        directMismatchFlags[row * columns + column] = true
                        if hasStrongSourceEdge(atX: imageX, y: imageY) {
                            edgeSupportedMismatchSamples += 1
                        }
                    }
                }
            }
            return SafetyNetImageMatch(
                meanDifference: totalDifference / Double(max(1, sampleCount)),
                mismatchRatio: Double(mismatchedSamples) / Double(max(1, sampleCount)),
                mismatchRegion: largestMismatchRegionMetrics(
                    for: directMismatchFlags,
                    columns: columns,
                    rows: rows
                ),
                edgeSupportedMismatchRatio: Double(edgeSupportedMismatchSamples)
                    / Double(max(1, mismatchedSamples)),
                colorTransform: colorTransformVerification(
                    for: colorSamples,
                    columns: columns,
                    rows: rows
                ),
                isVerticallyFlipped: flipVertically
            )
        }

        guard let normal = compare(flipVertically: false),
              let flipped = compare(flipVertically: true)
        else {
            return nil
        }
        return normal.score <= flipped.score ? normal : flipped
    }

    private static func alphaInkVisibility(
        _ image: DecodedImage,
        placement: CGRect,
        cropBox: CGRect,
        bitmap: NSBitmapImageRep?
    ) -> AlphaInkVisibility? {
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
            return nil
        }
        let columns = min(96, max(20, Int((placement.width / 6).rounded())))
        let rows = min(96, max(12, Int((placement.height / 4).rounded())))
        let bitmapScaleX = CGFloat(bitmap.pixelsWide) / cropBox.width
        let bitmapScaleY = CGFloat(bitmap.pixelsHigh) / cropBox.height

        func evaluate(flipVertically: Bool) -> AlphaInkVisibility? {
            var highOpacitySampleCount = 0
            var matchingSampleCount = 0
            var saturatedSampleCount = 0
            var matchingSaturatedSampleCount = 0
            for row in 0..<rows {
                let v = (CGFloat(row) + 0.5) / CGFloat(rows)
                let sourceV = flipVertically ? 1 - v : v
                let imageY = min(
                    image.height - 1,
                    max(0, Int((sourceV * CGFloat(image.height - 1)).rounded()))
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
                    let offset = (imageY * image.width + imageX) * 4
                    guard image.rgba[offset + 3] >= 128 else { continue }
                    highOpacitySampleCount += 1
                    let sourceRed = Int(image.rgba[offset])
                    let sourceGreen = Int(image.rgba[offset + 1])
                    let sourceBlue = Int(image.rgba[offset + 2])
                    // PDF image sampling and the page renderer can disagree
                    // by a couple of device pixels at a scaled edge. Search a
                    // very small local neighbourhood; a covered image still
                    // cannot manufacture its coloured ink anywhere nearby.
                    var bestDifference = Int.max
                    for offsetY in -3...3 {
                        for offsetX in -3...3 {
                            let candidateX = pageX + offsetX
                            let candidateY = pageY + offsetY
                            guard candidateX >= 0,
                                  candidateX < bitmap.pixelsWide,
                                  candidateY >= 0,
                                  candidateY < bitmap.pixelsHigh,
                                  let pageColor = bitmap.colorAt(x: candidateX, y: candidateY)?
                                    .usingColorSpace(.deviceRGB)
                            else {
                                continue
                            }
                            let difference = max(
                                abs(sourceRed - Int((pageColor.redComponent * 255).rounded())),
                                abs(sourceGreen - Int((pageColor.greenComponent * 255).rounded())),
                                abs(sourceBlue - Int((pageColor.blueComponent * 255).rounded()))
                            )
                            bestDifference = min(bestDifference, difference)
                        }
                    }
                    let matches = bestDifference <= 64
                    if matches {
                        matchingSampleCount += 1
                    }
                    let saturation = max(sourceRed, sourceGreen, sourceBlue)
                        - min(sourceRed, sourceGreen, sourceBlue)
                    if saturation >= 36 {
                        saturatedSampleCount += 1
                        if matches {
                            matchingSaturatedSampleCount += 1
                        }
                    }
                }
            }
            return AlphaInkVisibility(
                highOpacitySampleCount: highOpacitySampleCount,
                matchingSampleCount: matchingSampleCount,
                saturatedSampleCount: saturatedSampleCount,
                matchingSaturatedSampleCount: matchingSaturatedSampleCount,
                isVerticallyFlipped: flipVertically
            )
        }

        guard let normal = evaluate(flipVertically: false),
              let flipped = evaluate(flipVertically: true)
        else {
            return nil
        }
        return normal.score >= flipped.score ? normal : flipped
    }


    private struct RobustColorCalibration {
        let expectedValues: [Double]
        let isActive: Bool
        let retainedDynamicRange: Double
        let isPlausibleMonotonicCurve: Bool
    }

    private static func colorTransformVerification(
        for samples: [SafetyNetColorSample],
        columns: Int,
        rows: Int
    ) -> ColorTransformVerification? {
        guard samples.count >= 24 else { return nil }

        let channels: [(source: [Double], rendered: [Double])] = [
            (samples.map(\.sourceRed), samples.map(\.renderedRed)),
            (samples.map(\.sourceGreen), samples.map(\.renderedGreen)),
            (samples.map(\.sourceBlue), samples.map(\.renderedBlue))
        ]
        var residualTotal = 0.0
        var mismatchCount = 0
        var minimumRetainedDynamicRange = Double.infinity
        var activeChannelCount = 0
        var hasPlausibleMonotonicCurves = true
        var maximumResidualBySample = Array(repeating: 0.0, count: samples.count)

        for channel in channels {
            guard let calibration = robustColorCalibration(
                source: channel.source,
                rendered: channel.rendered
            ) else {
                return nil
            }
            if calibration.isActive {
                activeChannelCount += 1
                minimumRetainedDynamicRange = min(
                    minimumRetainedDynamicRange,
                    calibration.retainedDynamicRange
                )
                hasPlausibleMonotonicCurves = hasPlausibleMonotonicCurves
                    && calibration.isPlausibleMonotonicCurve
            }

            for index in channel.source.indices {
                let residual = abs(channel.rendered[index] - calibration.expectedValues[index])
                residualTotal += residual
                maximumResidualBySample[index] = max(
                    maximumResidualBySample[index],
                    residual
                )
            }
        }

        for residual in maximumResidualBySample where residual > 12 {
            mismatchCount += 1
        }

        let channelSampleCount = Double(samples.count * channels.count)
        return ColorTransformVerification(
            meanResidual: residualTotal / channelSampleCount,
            maximumResidual: maximumResidualBySample.max() ?? .infinity,
            mismatchRatio: Double(mismatchCount) / Double(samples.count),
            mismatchRegion: largestMismatchRegionMetrics(
                for: maximumResidualBySample.map { $0 > 12 },
                columns: columns,
                rows: rows
            ),
            minimumRetainedDynamicRange: minimumRetainedDynamicRange,
            activeChannelCount: activeChannelCount,
            hasPlausibleMonotonicCurves: hasPlausibleMonotonicCurves
        )
    }

    /// Learns a low-complexity, monotonic per-channel device/ICC colour
    /// transform from all samples. Median bins deliberately make a later
    /// overpaint an outlier instead of absorbing it into the colour model.
    private static func robustColorCalibration(
        source: [Double],
        rendered: [Double]
    ) -> RobustColorCalibration? {
        guard source.count == rendered.count, !source.isEmpty else { return nil }
        guard let sourceMinimum = source.min(),
              let sourceMaximum = source.max()
        else {
            return nil
        }
        let sourceRange = sourceMaximum - sourceMinimum
        let renderedMean = rendered.reduce(0, +) / Double(rendered.count)

        // A constant source channel cannot prove a transform, but it must
        // remain constant after the fitted offset. Its residuals still expose
        // a black box or another later paint layer.
        guard sourceRange >= 16 else {
            return RobustColorCalibration(
                expectedValues: Array(repeating: renderedMean, count: source.count),
                isActive: false,
                retainedDynamicRange: 1,
                isPlausibleMonotonicCurve: true
            )
        }

        let binCount = 32
        var renderedValuesByBin = Array(repeating: [Double](), count: binCount)
        var binBySample = Array(repeating: 0, count: source.count)
        for index in source.indices {
            let normalized = (source[index] - sourceMinimum) / sourceRange
            let bin = min(
                binCount - 1,
                max(0, Int((normalized * Double(binCount)).rounded(.down)))
            )
            binBySample[index] = bin
            renderedValuesByBin[bin].append(rendered[index])
        }

        var medians = Array<Double?>(repeating: nil, count: binCount)
        for index in medians.indices where !renderedValuesByBin[index].isEmpty {
            let values = renderedValuesByBin[index].sorted()
            let middle = values.count / 2
            medians[index] = values.count.isMultiple(of: 2)
                ? (values[middle - 1] + values[middle]) / 2
                : values[middle]
        }
        let occupiedBins = medians.indices.filter { medians[$0] != nil }
        guard !occupiedBins.isEmpty else { return nil }

        // Alpha compositing can legitimately reduce a source channel to two
        // or three distinct values (for example, a constant blue logo colour
        // drawn at two alpha levels). It cannot teach a full monotonic curve,
        // but the per-level medians still provide a robust residual map: a
        // small later rectangle remains an outlier instead of causing every
        // transparent image to stay flattened. Mark it inactive so the
        // overall proof still requires another channel with meaningful range.
        if occupiedBins.count < 4 {
            return RobustColorCalibration(
                expectedValues: binBySample.map {
                    medians[$0] ?? renderedMean
                },
                isActive: false,
                retainedDynamicRange: 1,
                isPlausibleMonotonicCurve: true
            )
        }

        let medianValues = occupiedBins.compactMap { medians[$0] }
        guard let renderedMinimum = medianValues.min(),
              let renderedMaximum = medianValues.max()
        else {
            return nil
        }
        let retainedDynamicRange = (renderedMaximum - renderedMinimum) / sourceRange
        var isPlausibleMonotonicCurve = true
        var previous: Double?
        for bin in occupiedBins {
            guard let value = medians[bin] else { continue }
            if let previous, value + 10 < previous {
                isPlausibleMonotonicCurve = false
            }
            previous = value
        }

        func expectedValue(for bin: Int) -> Double {
            if let exact = medians[bin] { return exact }
            let lower = medians.indices.reversed().first {
                $0 < bin && medians[$0] != nil
            }
            let upper = medians.indices.first {
                $0 > bin && medians[$0] != nil
            }
            switch (lower, upper) {
            case let (lower?, upper?):
                let lowerValue = medians[lower] ?? renderedMean
                let upperValue = medians[upper] ?? renderedMean
                let fraction = Double(bin - lower) / Double(upper - lower)
                return lowerValue + (upperValue - lowerValue) * fraction
            case let (lower?, nil):
                return medians[lower] ?? renderedMean
            case let (nil, upper?):
                return medians[upper] ?? renderedMean
            case (nil, nil):
                return renderedMean
            }
        }

        return RobustColorCalibration(
            expectedValues: binBySample.map(expectedValue(for:)),
            isActive: true,
            retainedDynamicRange: retainedDynamicRange,
            isPlausibleMonotonicCurve: isPlausibleMonotonicCurve
        )
    }

    /// A global mean error is insufficient for preserving z-order: a small
    /// opaque rectangle can affect only a few samples yet still be visibly
    /// destroyed when the original image is reinserted. Resampling noise is
    /// normally scattered along source edges; later PDF paint forms a compact
    /// connected region. Track the largest 8-neighbour component so both the
    /// direct and colour-managed checks reject that unsafe geometry.
    private static func largestMismatchRegionMetrics(
        for flags: [Bool],
        columns: Int,
        rows: Int
    ) -> MismatchRegionMetrics {
        guard columns > 0,
              rows > 0,
              flags.count == columns * rows
        else {
            return MismatchRegionMetrics(ratio: 1, fillRatio: 1)
        }
        var visited = Array(repeating: false, count: flags.count)
        var largestRegionSize = 0
        var largestRegionBounds: (minimumX: Int, maximumX: Int, minimumY: Int, maximumY: Int)?
        let offsets = [
            (-1, -1), (0, -1), (1, -1),
            (-1, 0),            (1, 0),
            (-1, 1),  (0, 1),   (1, 1)
        ]

        for start in flags.indices where flags[start] && !visited[start] {
            var pending = [start]
            visited[start] = true
            var regionSize = 0
            var minimumX = columns
            var maximumX = 0
            var minimumY = rows
            var maximumY = 0
            while let index = pending.popLast() {
                regionSize += 1
                let x = index % columns
                let y = index / columns
                minimumX = min(minimumX, x)
                maximumX = max(maximumX, x)
                minimumY = min(minimumY, y)
                maximumY = max(maximumY, y)
                for (deltaX, deltaY) in offsets {
                    let neighborX = x + deltaX
                    let neighborY = y + deltaY
                    guard neighborX >= 0,
                          neighborX < columns,
                          neighborY >= 0,
                          neighborY < rows
                    else {
                        continue
                    }
                    let neighbor = neighborY * columns + neighborX
                    guard flags[neighbor], !visited[neighbor] else { continue }
                    visited[neighbor] = true
                    pending.append(neighbor)
                }
            }
            if regionSize > largestRegionSize {
                largestRegionSize = regionSize
                largestRegionBounds = (minimumX, maximumX, minimumY, maximumY)
            }
        }
        guard let largestRegionBounds else {
            return MismatchRegionMetrics(ratio: 0, fillRatio: 0)
        }
        let boundingArea = max(
            1,
            (largestRegionBounds.maximumX - largestRegionBounds.minimumX + 1)
                * (largestRegionBounds.maximumY - largestRegionBounds.minimumY + 1)
        )
        return MismatchRegionMetrics(
            ratio: Double(largestRegionSize) / Double(flags.count),
            fillRatio: Double(largestRegionSize) / Double(boundingArea)
        )
    }

    /// Returns the locally uniform backdrop surrounding an alpha or soft-mask
    /// image. The value is deliberately sampled outside the image extent so
    /// source pixels cannot bias it. It serves two independent fidelity
    /// checks: reconstructing the repaired template, and proving that the
    /// image's expected source-over composite is still the final page paint.
    private static func locallyUniformBackdrop(
        around placement: CGRect,
        cropBox: CGRect,
        bitmap: NSBitmapImageRep?
    ) -> PDFTextColor? {
        guard let bitmap,
              placement.width > 0,
              placement.height > 0,
              cropBox.width > 0,
              cropBox.height > 0,
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0
        else {
            return nil
        }

        let scaleX = CGFloat(bitmap.pixelsWide) / cropBox.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / cropBox.height
        let inset: CGFloat = 3
        let horizontalSamples = max(4, min(16, Int((placement.width / 18).rounded())))
        let verticalSamples = max(4, min(16, Int((placement.height / 18).rounded())))
        var samples: [(red: CGFloat, green: CGFloat, blue: CGFloat)] = []

        func appendSample(pdfX: CGFloat, pdfY: CGFloat) {
            let pixelX = min(
                bitmap.pixelsWide - 1,
                max(0, Int(((pdfX - cropBox.minX) * scaleX).rounded()))
            )
            let pixelY = min(
                bitmap.pixelsHigh - 1,
                max(0, Int(((cropBox.maxY - pdfY) * scaleY).rounded()))
            )
            guard let color = bitmap.colorAt(x: pixelX, y: pixelY)?
                .usingColorSpace(.deviceRGB)
            else { return }
            samples.append((color.redComponent, color.greenComponent, color.blueComponent))
        }

        for index in 0..<horizontalSamples {
            let factor = (CGFloat(index) + 0.5) / CGFloat(horizontalSamples)
            let x = placement.minX + placement.width * factor
            appendSample(pdfX: x, pdfY: placement.minY - inset)
            appendSample(pdfX: x, pdfY: placement.maxY + inset)
        }
        for index in 0..<verticalSamples {
            let factor = (CGFloat(index) + 0.5) / CGFloat(verticalSamples)
            let y = placement.minY + placement.height * factor
            appendSample(pdfX: placement.minX - inset, pdfY: y)
            appendSample(pdfX: placement.maxX + inset, pdfY: y)
        }

        guard samples.count >= 8 else { return nil }
        let count = CGFloat(samples.count)
        let mean = (
            red: samples.reduce(CGFloat.zero) { $0 + $1.red } / count,
            green: samples.reduce(CGFloat.zero) { $0 + $1.green } / count,
            blue: samples.reduce(CGFloat.zero) { $0 + $1.blue } / count
        )
        let maximumDeviation = samples.reduce(CGFloat.zero) { maximum, sample in
            max(
                maximum,
                abs(sample.red - mean.red),
                abs(sample.green - mean.green),
                abs(sample.blue - mean.blue)
            )
        }
        // 4.7% RGB tolerance leaves a clean logo background editable while
        // rejecting photographs, patterned slide art, and strong gradients.
        guard maximumDeviation <= 0.047 else { return nil }
        return PDFTextColor(
            red: mean.red,
            green: mean.green,
            blue: mean.blue,
            alpha: 1
        )
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

    /// A decoded PDF image resource does not carry an intrinsic page
    /// orientation. When safety-net sampling proves that the page paints it
    /// upside down relative to the decoded rows, serialize the Office asset
    /// in the page's orientation as well. Alpha remains paired with each RGB
    /// row, so `/SMask` and image-mask edges stay intact.
    private static func verticallyFlipped(_ image: DecodedImage) -> DecodedImage {
        let rowStride = image.width * 4
        var pixels = Array(repeating: UInt8(0), count: image.rgba.count)
        for sourceRow in 0..<image.height {
            let destinationRow = image.height - sourceRow - 1
            let sourceOffset = sourceRow * rowStride
            let destinationOffset = destinationRow * rowStride
            pixels.replaceSubrange(
                destinationOffset..<(destinationOffset + rowStride),
                with: image.rgba[sourceOffset..<(sourceOffset + rowStride)]
            )
        }
        return DecodedImage(
            width: image.width,
            height: image.height,
            rgba: pixels,
            hasAlpha: image.hasAlpha,
            maskApplied: image.maskApplied
        )
    }

    private static func imageColorSpace(
        _ dictionary: CGPDFDictionaryRef
    ) -> ImageColorSpace? {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, "ColorSpace", &object),
              let object
        else {
            return nil
        }
        return imageColorSpace(from: object)
    }

    private static func imageColorSpace(
        from object: CGPDFObjectRef
    ) -> ImageColorSpace? {
        switch CGPDFObjectGetType(object) {
        case .name:
            guard let name = name(from: object),
                  let direct = directImageColorSpace(named: name)
            else {
                return nil
            }
            return .direct(direct)
        case .array:
            var array: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &array),
                  let array,
                  let family = name(in: array, at: 0)
            else {
                return nil
            }
            switch family {
            case "ICCBased":
                guard let direct = iccBasedColorSpace(in: array) else {
                    return nil
                }
                return .direct(direct)
            case "Indexed", "I":
                guard let indexed = indexedColorSpace(in: array) else {
                    return nil
                }
                return .indexed(indexed)
            // Calibrated spaces preserve their component count. The colour
            // transform is handled by Quartz when rendering the reference
            // page; this deterministic approximation can be safety-net
            // validated before it is promoted as a standalone Office image.
            case "CalGray":
                return .direct(.gray)
            case "CalRGB":
                return .direct(.rgb)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func directImageColorSpace(
        from object: CGPDFObjectRef
    ) -> DirectImageColorSpace? {
        guard let colorSpace = imageColorSpace(from: object) else {
            return nil
        }
        if case let .direct(direct) = colorSpace {
            return direct
        }
        return nil
    }

    private static func directImageColorSpace(
        named name: String
    ) -> DirectImageColorSpace? {
        switch name {
        case "DeviceGray", "G":
            .gray
        case "DeviceRGB", "RGB":
            .rgb
        case "DeviceCMYK", "CMYK":
            .cmyk
        default:
            nil
        }
    }

    private static func iccBasedColorSpace(
        in array: CGPDFArrayRef
    ) -> DirectImageColorSpace? {
        var stream: CGPDFStreamRef?
        guard CGPDFArrayGetStream(array, 1, &stream),
              let stream,
              let dictionary = CGPDFStreamGetDictionary(stream)
        else {
            return nil
        }
        var alternate: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "Alternate", &alternate),
           let alternate,
           let direct = directImageColorSpace(named: String(cString: alternate)) {
            return direct
        }
        var componentCount: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "N", &componentCount) else {
            return nil
        }
        switch componentCount {
        case 1:
            return .gray
        case 3:
            return .rgb
        case 4:
            return .cmyk
        default:
            return nil
        }
    }

    private static func indexedColorSpace(
        in array: CGPDFArrayRef
    ) -> IndexedImageColorSpace? {
        var baseObject: CGPDFObjectRef?
        var maximumObject: CGPDFObjectRef?
        var lookupObject: CGPDFObjectRef?
        guard CGPDFArrayGetObject(array, 1, &baseObject),
              let baseObject,
              let base = directImageColorSpace(from: baseObject),
              CGPDFArrayGetObject(array, 2, &maximumObject),
              let maximumObject,
              let maximumIndex = integerValue(from: maximumObject),
              maximumIndex >= 0,
              CGPDFArrayGetObject(array, 3, &lookupObject),
              let lookupObject,
              let lookup = lookupData(from: lookupObject)
        else {
            return nil
        }
        let requiredLength = (maximumIndex + 1) * base.componentCount
        guard requiredLength > 0, lookup.count >= requiredLength else {
            return nil
        }
        return IndexedImageColorSpace(
            base: base,
            maximumIndex: maximumIndex,
            lookup: Array(lookup.prefix(requiredLength))
        )
    }

    private static func integerValue(from object: CGPDFObjectRef) -> Int? {
        var integer: CGPDFInteger = 0
        if CGPDFObjectGetValue(object, .integer, &integer) {
            return Int(integer)
        }
        var number: CGPDFReal = 0
        guard CGPDFObjectGetValue(object, .real, &number), number.isFinite else {
            return nil
        }
        return Int(number.rounded())
    }

    private static func lookupData(from object: CGPDFObjectRef) -> Data? {
        switch CGPDFObjectGetType(object) {
        case .string:
            var string: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &string),
                  let string,
                  let bytes = CGPDFStringGetBytePtr(string)
            else {
                return nil
            }
            return Data(bytes: bytes, count: CGPDFStringGetLength(string))
        case .stream:
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream else {
                return nil
            }
            var format = CGPDFDataFormat.raw
            return CGPDFStreamCopyData(stream, &format) as Data?
        default:
            return nil
        }
    }

    private static func name(from object: CGPDFObjectRef) -> String? {
        var name: UnsafePointer<CChar>?
        guard CGPDFObjectGetValue(object, .name, &name), let name else {
            return nil
        }
        return String(cString: name)
    }

    private static func name(in array: CGPDFArrayRef, at index: Int) -> String? {
        var name: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, index, &name), let name else {
            return nil
        }
        return String(cString: name)
    }

    private static func decodeArray(
        _ dictionary: CGPDFDictionaryRef,
        count: Int,
        defaultRange: (Double, Double) = (0, 1)
    ) -> [Double] {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Decode", &array), let array,
              CGPDFArrayGetCount(array) >= count * 2
        else {
            return Array(repeating: 0, count: count * 2).enumerated().map {
                $0.offset.isMultiple(of: 2) ? defaultRange.0 : defaultRange.1
            }
        }
        return (0..<(count * 2)).map {
            number(array, index: $0)
                ?? ($0.isMultiple(of: 2) ? defaultRange.0 : defaultRange.1)
        }
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

private extension PDFSceneImageClip {
    /// A page-sized rectangular PDF clip has no visual effect on an image
    /// already fully inside it. Avoid serializing that common case as a
    /// freeform image-filled shape; retain the simpler selectable picture.
    func isAxisAlignedRectangle(containing rect: CGRect) -> Bool {
        guard pathCommands.contains(where: {
            if case .close = $0 { return true }
            return false
        }) else {
            return false
        }
        let vertices = pathCommands.compactMap { command -> CGPoint? in
            switch command {
            case let .move(point), let .line(point):
                point
            case .cubic, .close:
                nil
            }
        }
        guard vertices.count == 4,
              pathCommands.allSatisfy({ command in
                  if case .cubic = command { return false }
                  return true
              })
        else {
            return false
        }
        let tolerance: CGFloat = 0.5
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY)
        ]
        let followsCorners = vertices.allSatisfy { point in
            corners.contains {
                abs($0.x - point.x) <= tolerance && abs($0.y - point.y) <= tolerance
            }
        }
        return followsCorners
            && bounds.minX <= rect.minX + tolerance
            && bounds.minY <= rect.minY + tolerance
            && bounds.maxX >= rect.maxX - tolerance
            && bounds.maxY >= rect.maxY - tolerance
    }
}

private final class PDFImagePlacementTrace {
    private enum ClipState {
        case none
        case representable(PDFSceneImageClip)
        case unsupported
    }

    private enum PendingClipRule {
        case nonZero
        case evenOdd
    }

    private struct GraphicsState {
        let transform: CGAffineTransform
        let clip: ClipState
    }

    struct Placement {
        let name: String
        let stream: CGPDFStreamRef
        let dictionary: CGPDFDictionaryRef
        let bounds: CGRect
        let paintOrder: Int
        let isAxisAligned: Bool
        let clip: PDFSceneImageClip?
        let hasUnsupportedClip: Bool
    }

    private var transform = CGAffineTransform.identity
    private var stack: [GraphicsState] = []
    private var paintOrder = 0
    private var placements: [Placement] = []
    private let cropBox: CGRect
    private var resourcePath: [String] = []
    private var formDepth = 0
    private var currentOperatorTable: CGPDFOperatorTableRef?
    private var currentPath: [PDFSceneVectorPathCommand] = []
    private var currentPathPoint: CGPoint?
    private var currentSubpathStart: CGPoint?
    private var currentPathIsUnsupported = false
    private var pendingClipRule: PendingClipRule?
    private var clipState: ClipState = .none

    private init(cropBox: CGRect) {
        self.cropBox = cropBox
    }

    static func trace(
        page: PDFPage,
        cropBox: CGRect
    ) -> [Placement] {
        guard let pageRef = page.pageRef,
              let table = CGPDFOperatorTableCreate()
        else { return [] }
        let stream = CGPDFContentStreamCreateWithPage(pageRef)
        let trace = PDFImagePlacementTrace(
            cropBox: cropBox
        )
        let info = Unmanaged.passUnretained(trace).toOpaque()
        CGPDFOperatorTableSetCallback(table, "q", pdfImageSave)
        CGPDFOperatorTableSetCallback(table, "Q", pdfImageRestore)
        CGPDFOperatorTableSetCallback(table, "cm", pdfImageConcat)
        CGPDFOperatorTableSetCallback(table, "m", pdfImageMove)
        CGPDFOperatorTableSetCallback(table, "l", pdfImageLine)
        CGPDFOperatorTableSetCallback(table, "h", pdfImageClosePath)
        CGPDFOperatorTableSetCallback(table, "re", pdfImageRectangle)
        CGPDFOperatorTableSetCallback(table, "c", pdfImageCubic)
        CGPDFOperatorTableSetCallback(table, "v", pdfImageCubicUsingCurrentPoint)
        CGPDFOperatorTableSetCallback(table, "y", pdfImageCubicUsingEndPoint)
        CGPDFOperatorTableSetCallback(table, "W", pdfImageClip)
        CGPDFOperatorTableSetCallback(table, "W*", pdfImageEvenOddClip)
        CGPDFOperatorTableSetCallback(table, "n", pdfImageEndPath)
        CGPDFOperatorTableSetCallback(table, "S", pdfImagePaint)
        CGPDFOperatorTableSetCallback(table, "s", pdfImagePaint)
        CGPDFOperatorTableSetCallback(table, "f", pdfImagePaint)
        CGPDFOperatorTableSetCallback(table, "F", pdfImagePaint)
        CGPDFOperatorTableSetCallback(table, "f*", pdfImagePaint)
        CGPDFOperatorTableSetCallback(table, "B", pdfImagePaint)
        CGPDFOperatorTableSetCallback(table, "B*", pdfImagePaint)
        CGPDFOperatorTableSetCallback(table, "b", pdfImagePaint)
        CGPDFOperatorTableSetCallback(table, "b*", pdfImagePaint)
        CGPDFOperatorTableSetCallback(table, "Do", pdfImageDraw)
        trace.currentOperatorTable = table
        trace.scan(stream, table: table, info: info)
        trace.currentOperatorTable = nil
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return trace.placements
    }

    func save() {
        stack.append(GraphicsState(transform: transform, clip: clipState))
    }

    func restore() {
        guard let state = stack.popLast() else {
            transform = .identity
            clipState = .none
            return
        }
        transform = state.transform
        clipState = state.clip
    }

    /// Advances through a non-image PDF painting operator.  Image placements
    /// share this counter with `PDFGraphicsTrace`, which makes their stored
    /// paint orders comparable to path vectors instead of merely comparable
    /// to other images.
    func paint() {
        commitPendingClip()
        paintOrder += 1
        resetCurrentPath()
    }

    func move(_ scanner: CGPDFScannerRef) {
        guard let point = popPoint(scanner) else {
            markCurrentPathUnsupported()
            return
        }
        currentPath.append(.move(point))
        currentPathPoint = point
        currentSubpathStart = point
    }

    func line(_ scanner: CGPDFScannerRef) {
        guard let point = popPoint(scanner), currentPathPoint != nil else {
            markCurrentPathUnsupported()
            return
        }
        currentPath.append(.line(point))
        currentPathPoint = point
    }

    func closePath() {
        guard currentPathPoint != nil else {
            markCurrentPathUnsupported()
            return
        }
        currentPath.append(.close)
        currentPathPoint = currentSubpathStart
    }

    func rectangle(_ scanner: CGPDFScannerRef) {
        let height = popRawNumber(scanner)
        let width = popRawNumber(scanner)
        let y = popRawNumber(scanner)
        let x = popRawNumber(scanner)
        guard width.isFinite, height.isFinite,
              let first = transformedPoint(x: x, y: y),
              let second = transformedPoint(x: x + width, y: y),
              let third = transformedPoint(x: x + width, y: y + height),
              let fourth = transformedPoint(x: x, y: y + height)
        else {
            markCurrentPathUnsupported()
            return
        }
        currentPath.append(contentsOf: [
            .move(first),
            .line(second),
            .line(third),
            .line(fourth),
            .close
        ])
        currentPathPoint = first
        currentSubpathStart = first
    }

    func cubic(_ scanner: CGPDFScannerRef) {
        guard let end = popPoint(scanner),
              let control2 = popPoint(scanner),
              let control1 = popPoint(scanner),
              currentPathPoint != nil
        else {
            markCurrentPathUnsupported()
            return
        }
        currentPath.append(
            .cubic(control1: control1, control2: control2, end: end)
        )
        currentPathPoint = end
    }

    func cubicUsingCurrentPoint(_ scanner: CGPDFScannerRef) {
        guard let end = popPoint(scanner),
              let control2 = popPoint(scanner),
              let currentPathPoint
        else {
            markCurrentPathUnsupported()
            return
        }
        currentPath.append(
            .cubic(control1: currentPathPoint, control2: control2, end: end)
        )
        self.currentPathPoint = end
    }

    func cubicUsingEndPoint(_ scanner: CGPDFScannerRef) {
        guard let end = popPoint(scanner),
              let control1 = popPoint(scanner),
              currentPathPoint != nil
        else {
            markCurrentPathUnsupported()
            return
        }
        currentPath.append(
            .cubic(control1: control1, control2: end, end: end)
        )
        currentPathPoint = end
    }

    func clip(evenOdd: Bool) {
        pendingClipRule = evenOdd ? .evenOdd : .nonZero
    }

    func endPath() {
        commitPendingClip()
        resetCurrentPath()
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
        let contentStream = CGPDFScannerGetContentStream(scanner)
        guard let xObject = Self.xObject(
            named: name,
            in: contentStream
        ),
        let dictionary = CGPDFStreamGetDictionary(xObject)
        else {
            return
        }
        let subtype = Self.name(in: dictionary, key: "Subtype")
        switch subtype {
        case "Image":
            recordImage(
                stream: xObject,
                dictionary: dictionary,
                sourceName: qualifiedName(sourceName)
            )
        case "Form":
            scanForm(
                stream: xObject,
                dictionary: dictionary,
                sourceName: sourceName,
                parent: contentStream
            )
        default:
            break
        }
    }

    private func recordImage(
        stream: CGPDFStreamRef,
        dictionary: CGPDFDictionaryRef,
        sourceName: String
    ) {
        // Count every image `Do`, including an image that falls outside the
        // crop or an unsupported clip, so vector and image z-orders retain
        // the same global sequence.
        paintOrder += 1
        let rawBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
            .applying(transform)
            .standardized
        let bounds = rawBounds.intersection(cropBox)
        guard !bounds.isNull, bounds.width > 0.25, bounds.height > 0.25 else { return }
        let imageClip: PDFSceneImageClip?
        let hasUnsupportedClip: Bool
        switch clipState {
        case .none:
            imageClip = nil
            hasUnsupportedClip = false
        case let .representable(clip):
            guard clip.bounds.intersects(bounds) else { return }
            imageClip = clip.isAxisAlignedRectangle(containing: bounds)
                ? nil
                : clip
            hasUnsupportedClip = false
        case .unsupported:
            imageClip = nil
            hasUnsupportedClip = true
        }
        placements.append(
            Placement(
                name: sourceName,
                stream: stream,
                dictionary: dictionary,
                bounds: bounds,
                paintOrder: paintOrder,
                // An OOXML picture rectangle cannot express a rotated or
                // sheared PDF image matrix without a full transform model.
                // Negative scale is normal for PDF's image coordinate system
                // and is still axis-aligned, so do not reject it here.
                isAxisAligned: abs(transform.b) <= 0.0001
                    && abs(transform.c) <= 0.0001,
                clip: imageClip,
                hasUnsupportedClip: hasUnsupportedClip
            )
        )
    }

    private func commitPendingClip() {
        guard let rule = pendingClipRule else { return }
        pendingClipRule = nil
        guard rule == .nonZero,
              !currentPathIsUnsupported,
              !currentPath.isEmpty,
              let bounds = pathBounds(currentPath),
              bounds.width > 0,
              bounds.height > 0
        else {
            clipState = .unsupported
            return
        }

        let next = PDFSceneImageClip(bounds: bounds, pathCommands: currentPath)
        switch clipState {
        case .none:
            clipState = .representable(next)
        case .representable, .unsupported:
            // Intersecting arbitrary Bézier paths requires a boolean-path
            // engine. Keep the source template instead of approximating an
            // incorrect image mask.
            clipState = .unsupported
        }
    }

    private func resetCurrentPath() {
        currentPath.removeAll(keepingCapacity: true)
        currentPathPoint = nil
        currentSubpathStart = nil
        currentPathIsUnsupported = false
    }

    private func markCurrentPathUnsupported() {
        currentPathIsUnsupported = true
    }

    private func popRawNumber(_ scanner: CGPDFScannerRef) -> CGFloat {
        var value: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &value) else { return .nan }
        return CGFloat(value)
    }

    private func popPoint(_ scanner: CGPDFScannerRef) -> CGPoint? {
        let y = popRawNumber(scanner)
        let x = popRawNumber(scanner)
        return transformedPoint(x: x, y: y)
    }

    private func transformedPoint(x: CGFloat, y: CGFloat) -> CGPoint? {
        guard x.isFinite, y.isFinite else { return nil }
        let point = CGPoint(x: x, y: y).applying(transform)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }

    private func pathBounds(_ commands: [PDFSceneVectorPathCommand]) -> CGRect? {
        let points = commands.flatMap { command -> [CGPoint] in
            switch command {
            case let .move(point), let .line(point):
                [point]
            case let .cubic(control1, control2, end):
                [control1, control2, end]
            case .close:
                []
            }
        }
        guard let first = points.first else { return nil }
        var minimumX = first.x
        var maximumX = first.x
        var minimumY = first.y
        var maximumY = first.y
        for point in points.dropFirst() {
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
        }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        ).standardized
    }

    private func scan(
        _ stream: CGPDFContentStreamRef,
        table: CGPDFOperatorTableRef,
        info: UnsafeMutableRawPointer
    ) {
        let scanner = CGPDFScannerCreate(stream, table, info)
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    private func scanForm(
        stream: CGPDFStreamRef,
        dictionary: CGPDFDictionaryRef,
        sourceName: String,
        parent: CGPDFContentStreamRef
    ) {
        guard formDepth < 24,
              let resources = Self.dictionary(in: dictionary, key: "Resources"),
              let table = currentOperatorTable
        else {
            return
        }
        let savedTransform = transform
        let savedStack = stack
        let savedClipState = clipState
        let savedPath = currentPath
        let savedPathPoint = currentPathPoint
        let savedSubpathStart = currentSubpathStart
        let savedPathUnsupported = currentPathIsUnsupported
        let savedPendingClipRule = pendingClipRule
        transform = transform.concatenating(Self.formMatrix(in: dictionary))
        resourcePath.append(sourceName)
        formDepth += 1
        let contentStream = CGPDFContentStreamCreateWithStream(
            stream,
            resources,
            parent
        )
        let info = Unmanaged.passUnretained(self).toOpaque()
        scan(contentStream, table: table, info: info)
        CGPDFContentStreamRelease(contentStream)
        formDepth -= 1
        _ = resourcePath.popLast()
        transform = savedTransform
        stack = savedStack
        clipState = savedClipState
        currentPath = savedPath
        currentPathPoint = savedPathPoint
        currentSubpathStart = savedSubpathStart
        currentPathIsUnsupported = savedPathUnsupported
        pendingClipRule = savedPendingClipRule
    }

    private func qualifiedName(_ sourceName: String) -> String {
        (resourcePath + [sourceName]).joined(separator: "/")
    }

    private static func xObject(
        named name: UnsafePointer<CChar>,
        in contentStream: CGPDFContentStreamRef
    ) -> CGPDFStreamRef? {
        guard let object = CGPDFContentStreamGetResource(
            contentStream,
            "XObject",
            name
        ),
        CGPDFObjectGetType(object) == .stream
        else {
            return nil
        }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream) else {
            return nil
        }
        return stream
    }

    private static func name(
        in dictionary: CGPDFDictionaryRef,
        key: String
    ) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else {
            return nil
        }
        return String(cString: value)
    }

    private static func dictionary(
        in dictionary: CGPDFDictionaryRef,
        key: String
    ) -> CGPDFDictionaryRef? {
        var result: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, key, &result) else {
            return nil
        }
        return result
    }

    private static func formMatrix(
        in dictionary: CGPDFDictionaryRef
    ) -> CGAffineTransform {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Matrix", &array),
              let array,
              CGPDFArrayGetCount(array) >= 6
        else {
            return .identity
        }
        var values = Array(repeating: CGPDFReal(0), count: 6)
        for index in values.indices {
            guard CGPDFArrayGetNumber(array, index, &values[index]) else {
                return .identity
            }
        }
        return CGAffineTransform(
            a: CGFloat(values[0]),
            b: CGFloat(values[1]),
            c: CGFloat(values[2]),
            d: CGFloat(values[3]),
            tx: CGFloat(values[4]),
            ty: CGFloat(values[5])
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

private func pdfImageMove(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue().move(scanner)
}

private func pdfImageLine(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue().line(scanner)
}

private func pdfImageClosePath(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue().closePath()
}

private func pdfImageRectangle(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue().rectangle(scanner)
}

private func pdfImageCubic(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue().cubic(scanner)
}

private func pdfImageCubicUsingCurrentPoint(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue()
        .cubicUsingCurrentPoint(scanner)
}

private func pdfImageCubicUsingEndPoint(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue()
        .cubicUsingEndPoint(scanner)
}

private func pdfImageClip(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue().clip(evenOdd: false)
}

private func pdfImageEvenOddClip(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue().clip(evenOdd: true)
}

private func pdfImageEndPath(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue().endPath()
}

private func pdfImagePaint(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PDFImagePlacementTrace>.fromOpaque(info).takeUnretainedValue().paint()
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
