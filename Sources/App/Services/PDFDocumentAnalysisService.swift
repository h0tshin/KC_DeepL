import AppKit
import Foundation
import PDFKit
import Vision

/// Extracts text together with page-space geometry without mutating the source PDF.
struct PDFDocumentAnalysisService: Sendable {
    private let ocrLanguages: [String]
    private let includeOCR: Bool
    private let ocrMinimumConfidence: Float
    private let maximumOCRImageDimension: CGFloat

    init(
        ocrLanguages: [String] = [],
        includeOCR: Bool = true,
        ocrMinimumConfidence: Float = 0.55,
        maximumOCRImageDimension: CGFloat = 3_200
    ) {
        self.ocrLanguages = ocrLanguages
        self.includeOCR = includeOCR
        self.ocrMinimumConfidence = min(max(ocrMinimumConfidence, 0), 1)
        self.maximumOCRImageDimension = max(1_024, maximumOCRImageDimension)
    }

    func analyze(sourceURL: URL) throws -> PDFDocumentAnalysis {
        guard sourceURL.isFileURL,
              sourceURL.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
        else {
            throw PDFDocumentServiceError.invalidFileType
        }

        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        } catch {
            throw PDFDocumentServiceError.cannotReadSource(error.localizedDescription)
        }

        guard Self.hasPDFHeader(sourceData),
              let document = PDFDocument(data: sourceData)
        else {
            throw PDFDocumentServiceError.invalidPDF
        }
        guard !document.isLocked else {
            throw PDFDocumentServiceError.lockedDocument
        }
        guard document.allowsDocumentChanges, document.allowsCommenting else {
            throw PDFDocumentServiceError.changeDisallowed
        }
        guard !Self.containsDigitalSignature(document: document, data: sourceData) else {
            throw PDFDocumentServiceError.signedDocument
        }
        guard !Self.containsInteractiveForm(document, data: sourceData) else {
            throw PDFDocumentServiceError.interactiveFormsUnsupported
        }
        guard document.pageCount > 0 else {
            throw PDFDocumentServiceError.emptyDocument
        }

        var pages: [PDFPageAnalysis] = []
        var documentWarnings: [PDFDocumentWarning] = []
        pages.reserveCapacity(document.pageCount)
        let containsPrivateSystemFontResource = Self
            .containsPrivateSystemFontResource(sourceData)

        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw PDFDocumentServiceError.invalidAnalysis(
                    "\(pageIndex + 1)페이지를 불러올 수 없습니다."
                )
            }

            let mediaBox = page.bounds(for: .mediaBox)
            let cropBox = page.bounds(for: .cropBox)
            let rotation = try PDFPageMetadataSafety.effectiveRotation(
                of: page,
                pageIndex: pageIndex
            )
            let nativeCandidates = nativeTextCandidates(
                on: page,
                cropBox: cropBox,
                containsPrivateSystemFontResource: containsPrivateSystemFontResource
            )
            var candidates = nativeCandidates
            var pageWarnings: [PDFDocumentWarning] = []

            if includeOCR {
                let ocrResult = try visionTextCandidates(
                    on: page,
                    cropBox: cropBox,
                    rotation: rotation
                )
                if nativeCandidates.isEmpty {
                    candidates = ocrResult.candidates
                    if !candidates.isEmpty {
                        pageWarnings.append(.ocrApplied(pageIndex: pageIndex))
                        if let minimumConfidence = ocrResult.minimumConfidence,
                           minimumConfidence < ocrMinimumConfidence {
                            pageWarnings.append(
                                .lowOCRConfidence(
                                    pageIndex: pageIndex,
                                    confidence: minimumConfidence
                                )
                            )
                        }
                    } else {
                        if rotation != 0, ocrResult.didFail {
                            pageWarnings.append(
                                .rotatedOCRUnsupported(
                                    pageIndex: pageIndex,
                                    rotation: rotation
                                )
                            )
                        }
                        pageWarnings.append(.ocrRequired(pageIndex: pageIndex))
                    }
                } else if ocrResult.didFail {
                    if rotation == 0 {
                        pageWarnings.append(.hybridOCRUnavailable(pageIndex: pageIndex))
                    } else {
                        pageWarnings.append(
                            .rotatedHybridOCRUnsupported(
                                pageIndex: pageIndex,
                                rotation: rotation
                            )
                        )
                    }
                } else {
                    let supplementalOCR = ocrResult.candidates.filter { ocrCandidate in
                        !nativeCandidates.contains {
                            Self.areDuplicate($0, ocrCandidate)
                        }
                    }
                    if !supplementalOCR.isEmpty {
                        candidates.append(contentsOf: supplementalOCR)
                        pageWarnings.append(
                            .hybridOCRApplied(
                                pageIndex: pageIndex,
                                addedLineCount: supplementalOCR.count
                            )
                        )
                        if let minimumConfidence = ocrResult.minimumConfidence,
                           minimumConfidence < ocrMinimumConfidence {
                            pageWarnings.append(
                                .lowOCRConfidence(
                                    pageIndex: pageIndex,
                                    confidence: minimumConfidence
                                )
                            )
                        }
                    }
                }
            } else if nativeCandidates.isEmpty {
                pageWarnings.append(.ocrDisabled(pageIndex: pageIndex))
            }

            let orderedCandidates = spatiallyOrdered(
                candidates,
                pageBounds: cropBox
            )
            try Task.checkCancellation()
            var backgroundResult = try estimateBackgroundColors(
                for: orderedCandidates,
                on: page,
                cropBox: cropBox,
                rotation: rotation
            )
            backgroundResult = Self.applyingOCRContrast(to: backgroundResult)
            let extractedLines = try makeLines(
                from: backgroundResult.candidates,
                pageIndex: pageIndex
            )
            for index in backgroundResult.complexCandidateIndices
            where extractedLines.indices.contains(index) {
                pageWarnings.append(
                    .complexBackground(
                        pageIndex: pageIndex,
                        lineID: extractedLines[index].id
                    )
                )
            }
            for index in backgroundResult.unavailableCandidateIndices
            where extractedLines.indices.contains(index) {
                pageWarnings.append(
                    .backgroundSamplingUnavailable(
                        pageIndex: pageIndex,
                        lineID: extractedLines[index].id
                    )
                )
            }
            let blocks = try makeBlocks(
                from: extractedLines,
                pageIndex: pageIndex
            )
            let lines = Self.alignListBlockLines(
                extractedLines,
                blocks: blocks
            )

            pageWarnings.append(
                contentsOf: Self.linkOverlapWarnings(
                    on: page,
                    lines: lines,
                    pageIndex: pageIndex
                )
            )

            if lines.isEmpty {
                pageWarnings.append(
                    .pageHasNoTranslatableText(pageIndex: pageIndex)
                )
            }

            let pageIDSeed = [
                "page",
                String(pageIndex),
                Self.geometryKey(mediaBox),
                Self.geometryKey(cropBox),
                Self.geometryKey(page.bounds(for: .bleedBox)),
                Self.geometryKey(page.bounds(for: .trimBox)),
                Self.geometryKey(page.bounds(for: .artBox)),
                String(rotation)
            ].joined(separator: "|")
            let analysis = PDFPageAnalysis(
                id: "pdf-page-\(Self.stableHash(pageIDSeed))",
                pageIndex: pageIndex,
                mediaBox: mediaBox,
                cropBox: cropBox,
                bleedBox: page.bounds(for: .bleedBox),
                trimBox: page.bounds(for: .trimBox),
                artBox: page.bounds(for: .artBox),
                rotation: rotation,
                lines: lines,
                blocks: blocks,
                warnings: pageWarnings
            )
            pages.append(analysis)
            documentWarnings.append(contentsOf: pageWarnings)
        }

        return PDFDocumentAnalysis(
            sourceURL: sourceURL.standardizedFileURL,
            sourceData: sourceData,
            pageCount: document.pageCount,
            pages: pages,
            warnings: documentWarnings
        )
    }
}

private extension PDFDocumentAnalysisService {
    struct TextCandidate {
        let text: String
        let bounds: CGRect
        let fontName: String
        let fontSize: CGFloat
        var textColor: PDFTextColor
        let foregroundColorIsTrusted: Bool
        let extractionSource: PDFTextExtractionSource
        var columnIndex: Int = 0
        var backgroundColor: PDFTextColor = .white
        var sourceMaskBounds: CGRect?
        var alignment: PDFTextAlignment?
    }

    struct OCRResult {
        let candidates: [TextCandidate]
        let minimumConfidence: Float?
        let didFail: Bool
    }

    struct PageDisplayGeometry {
        let cropBox: CGRect
        let pageToDisplay: CGAffineTransform
        let displayToPage: CGAffineTransform
        let displayBounds: CGRect
    }

    struct BackgroundSamplingResult {
        let candidates: [TextCandidate]
        let complexCandidateIndices: [Int]
        let unavailableCandidateIndices: [Int]
    }

    struct ColumnCluster {
        var bounds: CGRect
        var leftEdges: [CGFloat]
        var candidateIndices: [Int]

        var representativeLeftEdge: CGFloat {
            let sorted = leftEdges.sorted()
            return sorted[sorted.count / 2]
        }
    }

    struct AttributedColorRun {
        var range: NSRange
        let color: NSColor
    }

    static func hasPDFHeader(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let prefix = data.prefix(1_024)
        return prefix.range(of: Data("%PDF-".utf8)) != nil
    }

    static func containsDigitalSignature(
        document: PDFDocument,
        data: Data
    ) -> Bool {
        // A populated signature dictionary carries /ByteRange. Search the raw
        // bytes so a large mapped PDF is not duplicated into a String.
        if data.range(of: Data("/ByteRange".utf8)) != nil {
            return true
        }

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations
            where annotation.widgetFieldType == .signature {
                if annotation.value(forAnnotationKey: .widgetValue) != nil {
                    return true
                }
            }
        }
        return false
    }

    static func containsInteractiveForm(
        _ document: PDFDocument,
        data: Data
    ) -> Bool {
        // Reject catalog-only AcroForm/XFA documents even when PDFKit does not
        // expose a page widget. Rewriting such a file can silently detach field
        // state or appearance streams.
        if data.range(of: Data("/AcroForm".utf8)) != nil
            || data.range(of: Data("/XFA".utf8)) != nil {
            return true
        }
        if let provider = CGDataProvider(data: data as CFData),
           let cgDocument = CGPDFDocument(provider),
           let catalog = cgDocument.catalog {
            var object: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(catalog, "AcroForm", &object)
                || CGPDFDictionaryGetObject(catalog, "XFA", &object) {
                return true
            }
        }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            if page.annotations.contains(where: {
                !$0.widgetFieldType.rawValue.isEmpty
                    || $0.type?.trimmingCharacters(
                        in: CharacterSet(charactersIn: "/")
                    ) == "Widget"
            }) {
                return true
            }
        }
        return false
    }

    func nativeTextCandidates(
        on page: PDFPage,
        cropBox: CGRect,
        containsPrivateSystemFontResource: Bool
    ) -> [TextCandidate] {
        guard let selection = page.selection(for: cropBox) else { return [] }

        let visualSelections = selection.selectionsByLine().flatMap {
            Self.splitVisualLineSelection($0, on: page)
        }.flatMap {
            Self.splitAttributedColorRuns($0, on: page)
        }
        return visualSelections.compactMap {
            lineSelection -> TextCandidate? in
            let text = Self.normalizedText(lineSelection.string ?? "")
            guard !text.isEmpty else { return nil }

            let rawBounds = lineSelection.bounds(for: page)
            let bounds = rawBounds.intersection(cropBox)
            guard !bounds.isNull, bounds.width > 0.25, bounds.height > 0.25 else {
                return nil
            }
            guard !Self.isFreeTextAnnotationAppearance(
                text: text,
                bounds: bounds,
                on: page
            ) else {
                return nil
            }

            let attributes = lineSelection.attributedString.flatMap {
                attributedString -> [NSAttributedString.Key: Any]? in
                guard attributedString.length > 0 else { return nil }
                return attributedString.attributes(at: 0, effectiveRange: nil)
            } ?? [:]
            let font = attributes[.font] as? NSFont
            let color = attributes[.foregroundColor] as? NSColor
            let trustedTextColor = Self.uniformTextColor(
                in: lineSelection.attributedString
            )
            let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
            let inferredFontSize = max(5, min(144, bounds.height * 0.78))
            let resolvedFontSize = font?.pointSize ?? inferredFontSize
            let extractedFontName = font?.fontName
            let resolvedFontName: String
            if containsPrivateSystemFontResource,
               Self.isPDFKitPrivateFontFallback(extractedFontName) {
                // PDFKit reports Times New Roman when it cannot reconstruct an
                // embedded private .SFNS font. Preserve that fact as a private
                // name so composition chooses Barlow/Noto rather than serializing
                // the unrelated Times fallback.
                resolvedFontName = NSFont.systemFont(
                    ofSize: resolvedFontSize
                ).fontName
            } else {
                resolvedFontName = extractedFontName
                    ?? NSFont.systemFont(ofSize: inferredFontSize).fontName
            }
            guard !Self.isPreservedDocumentChrome(
                text: text,
                bounds: bounds,
                fontSize: resolvedFontSize,
                pageBounds: cropBox
            ) else {
                return nil
            }

            return TextCandidate(
                text: text,
                bounds: bounds,
                fontName: resolvedFontName,
                fontSize: resolvedFontSize,
                textColor: trustedTextColor ?? Self.textColor(from: color),
                foregroundColorIsTrusted: trustedTextColor != nil,
                extractionSource: .native,
                alignment: Self.textAlignment(from: paragraphStyle?.alignment)
            )
        }
    }

    func visionTextCandidates(
        on page: PDFPage,
        cropBox: CGRect,
        rotation: Int
    ) throws -> OCRResult {
        try Task.checkCancellation()
        guard let geometry = Self.pageDisplayGeometry(
            for: page,
            cropBox: cropBox,
            rotation: rotation
        ) else {
            return OCRResult(
                candidates: [],
                minimumConfidence: nil,
                didFail: true
            )
        }

        let longestSide = max(
            geometry.displayBounds.width,
            geometry.displayBounds.height
        )
        let scale = min(3, maximumOCRImageDimension / longestSide)
        let targetSize = CGSize(
            width: max(
                1,
                (geometry.displayBounds.width * scale).rounded(.up)
            ),
            height: max(
                1,
                (geometry.displayBounds.height * scale).rounded(.up)
            )
        )
        let image = page.thumbnail(of: targetSize, for: .cropBox)
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            return OCRResult(
                candidates: [],
                minimumConfidence: nil,
                didFail: true
            )
        }
        guard Self.hasMatchingAspectRatio(
            CGSize(
                width: CGFloat(cgImage.width),
                height: CGFloat(cgImage.height)
            ),
            geometry.displayBounds.size
        ) else {
            return OCRResult(
                candidates: [],
                minimumConfidence: nil,
                didFail: true
            )
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        if !ocrLanguages.isEmpty,
           let supportedLanguages = try? request.supportedRecognitionLanguages() {
            let supported = Set(supportedLanguages)
            let validHints = ocrLanguages.filter(supported.contains)
            if !validHints.isEmpty {
                request.recognitionLanguages = validHints
            }
        }

        do {
            try Task.checkCancellation()
            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: .up,
                options: [:]
            )
            try handler.perform([request])
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return OCRResult(
                candidates: [],
                minimumConfidence: nil,
                didFail: true
            )
        }

        var minimumConfidence: Float?
        var candidates: [TextCandidate] = []
        let observations: [VNRecognizedTextObservation] = request.results ?? []
        for observation in observations {
            try Task.checkCancellation()
            guard let recognized = observation.topCandidates(1).first else {
                continue
            }
            let text = Self.normalizedText(recognized.string)
            guard !text.isEmpty else { continue }

            let normalizedBounds = observation.boundingBox.standardized
            guard Self.isFinite(normalizedBounds),
                  normalizedBounds.width > 0,
                  normalizedBounds.height > 0
            else {
                continue
            }
            let displayRect = CGRect(
                x: geometry.displayBounds.minX
                    + normalizedBounds.minX * geometry.displayBounds.width,
                y: geometry.displayBounds.minY
                    + normalizedBounds.minY * geometry.displayBounds.height,
                width: normalizedBounds.width * geometry.displayBounds.width,
                height: normalizedBounds.height * geometry.displayBounds.height
            ).standardized.intersection(geometry.displayBounds)
            guard Self.isFinite(displayRect),
                  !displayRect.isNull,
                  displayRect.width > 0.25,
                  displayRect.height > 0.25
            else {
                continue
            }
            let bounds = displayRect
                .applying(geometry.displayToPage)
                .standardized
                .intersection(cropBox)
            guard Self.isFinite(bounds),
                  !bounds.isNull,
                  bounds.width > 0.25,
                  bounds.height > 0.25
            else {
                continue
            }
            guard !Self.isFreeTextAnnotationAppearance(
                text: text,
                bounds: bounds,
                on: page
            ) else {
                continue
            }

            minimumConfidence = min(
                minimumConfidence ?? recognized.confidence,
                recognized.confidence
            )
            let fontSize = max(5, min(144, bounds.height * 0.72))
            guard !Self.isPreservedDocumentChrome(
                text: text,
                bounds: bounds,
                fontSize: fontSize,
                pageBounds: cropBox
            ) else {
                continue
            }
            candidates.append(
                TextCandidate(
                    text: text,
                    bounds: bounds,
                    fontName: NSFont.systemFont(ofSize: fontSize).fontName,
                    fontSize: fontSize,
                    textColor: .black,
                    foregroundColorIsTrusted: false,
                    extractionSource: .visionOCR,
                    alignment: nil
                )
            )
        }

        return OCRResult(
            candidates: candidates,
            minimumConfidence: minimumConfidence,
            didFail: false
        )
    }

    func estimateBackgroundColors(
        for input: [TextCandidate],
        on page: PDFPage,
        cropBox: CGRect,
        rotation: Int
    ) throws -> BackgroundSamplingResult {
        try Task.checkCancellation()
        guard !input.isEmpty else {
            return BackgroundSamplingResult(
                candidates: [],
                complexCandidateIndices: [],
                unavailableCandidateIndices: []
            )
        }

        guard let bitmap = pageBitmap(
            page,
            cropBox: cropBox,
            rotation: rotation
        )
        else {
            return BackgroundSamplingResult(
                candidates: input,
                complexCandidateIndices: [],
                unavailableCandidateIndices: Array(input.indices)
            )
        }

        var candidates: [TextCandidate] = []
        candidates.reserveCapacity(input.count)
        var complexIndices: [Int] = []
        var unavailableIndices: [Int] = []

        for sourceCandidate in input {
            try Task.checkCancellation()
            guard let estimate = try sampledBackground(
                for: sourceCandidate.bounds,
                foregroundColor: sourceCandidate.textColor,
                foregroundColorIsTrusted: sourceCandidate
                    .foregroundColorIsTrusted,
                cropBox: cropBox,
                bitmap: bitmap
            ) else {
                let outputIndex = candidates.count
                candidates.append(sourceCandidate)
                unavailableIndices.append(outputIndex)
                continue
            }

            // A trusted attributed run whose colour is effectively identical
            // to its rendered background is hidden/occluded source content.
            // Translating it would reveal PowerPoint animation artifacts that
            // were not visible in the original slide.
            if !estimate.isComplex,
               sourceCandidate.foregroundColorIsTrusted,
               Self.isVisuallyIndistinguishable(
                foreground: sourceCandidate.textColor,
                background: estimate.color
               ) {
                continue
            }

            var candidate = sourceCandidate
            candidate.backgroundColor = estimate.color
            candidate.sourceMaskBounds = estimate.maskBounds
            let outputIndex = candidates.count
            candidates.append(candidate)
            if estimate.isComplex {
                complexIndices.append(outputIndex)
            }
        }

        return BackgroundSamplingResult(
            candidates: candidates,
            complexCandidateIndices: complexIndices,
            unavailableCandidateIndices: unavailableIndices
        )
    }

    func pageBitmap(
        _ page: PDFPage,
        cropBox: CGRect,
        rotation: Int
    ) -> NSBitmapImageRep? {
        guard let geometry = Self.pageDisplayGeometry(
            for: page,
            cropBox: cropBox,
            rotation: rotation
        ) else {
            return nil
        }
        let longestSide = max(cropBox.width, cropBox.height)
        let scale = min(2, 2_000 / longestSide)
        let targetSize = CGSize(
            width: max(1, (cropBox.width * scale).rounded(.up)),
            height: max(1, (cropBox.height * scale).rounded(.up))
        )
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // PDFPage.thumbnail renders through the display's ICC profile. Feeding
        // those display-converted pixels back into a PDF annotation applies a
        // second color transform and leaves a visible mask rectangle. Render
        // directly into Device RGB so the sampled components and the annotation
        // appearance share the same PDF color semantics.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(
            x: CGFloat(width) / cropBox.width,
            y: CGFloat(height) / cropBox.height
        )
        context.translateBy(x: -cropBox.minX, y: -cropBox.minY)
        // PDFPage.draw applies the page rotation/crop transform internally.
        // Cancel it so the bitmap remains in unrotated PDF page-space, matching
        // the line bounds used by the compositor and background sampler.
        context.concatenate(geometry.displayToPage)
        page.draw(with: .cropBox, to: context)
        guard let cgImage = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    func sampledBackground(
        for lineBounds: CGRect,
        foregroundColor: PDFTextColor,
        foregroundColorIsTrusted: Bool,
        cropBox: CGRect,
        bitmap: NSBitmapImageRep
    ) throws -> (
        color: PDFTextColor,
        isComplex: Bool,
        maskBounds: CGRect
    )? {
        guard bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0,
              cropBox.width > 0,
              cropBox.height > 0
        else {
            return nil
        }

        let scaleX = CGFloat(bitmap.pixelsWide) / cropBox.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / cropBox.height
        let maskBounds = PDFOverlayGeometry.bounds(
            for: lineBounds,
            constrainedTo: cropBox
        )
        guard !maskBounds.isNull,
              maskBounds.width > 0,
              maskBounds.height > 0
        else {
            return nil
        }
        let pixelRect = CGRect(
            x: (maskBounds.minX - cropBox.minX) * scaleX,
            // NSBitmapImageRep's row zero is the top of PDFKit's thumbnail.
            y: (cropBox.maxY - maskBounds.maxY) * scaleY,
            width: maskBounds.width * scaleX,
            height: maskBounds.height * scaleY
        )
        // Include a pixel only when its centre is inside the exact annotation
        // mask. Sampling the neighbouring pixel cell can otherwise turn a
        // harmless shape edge into a false complex-background warning.
        let minimumX = max(
            0,
            Int((pixelRect.minX - 0.5).rounded(.up))
        )
        let maximumX = min(
            bitmap.pixelsWide - 1,
            Int((pixelRect.maxX - 0.5).rounded(.down))
        )
        let minimumY = max(
            0,
            Int((pixelRect.minY - 0.5).rounded(.up))
        )
        let maximumY = min(
            bitmap.pixelsHigh - 1,
            Int((pixelRect.maxY - 0.5).rounded(.down))
        )
        guard minimumX <= maximumX, minimumY <= maximumY else { return nil }

        let pixelCount = (maximumX - minimumX + 1) * (maximumY - minimumY + 1)
        let strideLength = max(1, Int(sqrt(Double(pixelCount) / 4_000)))
        var samples: [(red: CGFloat, green: CGFloat, blue: CGFloat)] = []
        var boundarySamples: [(red: CGFloat, green: CGFloat, blue: CGFloat)] = []
        samples.reserveCapacity(min(4_000, pixelCount))
        let boundaryBand = max(
            1,
            min(
                4,
                Int(
                    (min(pixelRect.width, pixelRect.height) * 0.08)
                        .rounded(.up)
                )
            )
        )

        for y in stride(from: minimumY, through: maximumY, by: strideLength) {
            try Task.checkCancellation()
            for x in stride(from: minimumX, through: maximumX, by: strideLength) {
                guard let sourceColor = bitmap.colorAt(x: x, y: y),
                      let color = sourceColor.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.05
                else {
                    continue
                }
                let sample = (
                    red: color.redComponent,
                    green: color.greenComponent,
                    blue: color.blueComponent
                )
                samples.append(sample)
                if x - minimumX <= boundaryBand
                    || maximumX - x <= boundaryBand
                    || y - minimumY <= boundaryBand
                    || maximumY - y <= boundaryBand {
                    boundarySamples.append(sample)
                }
            }
        }
        guard !samples.isEmpty else { return nil }

        let quantizationSteps: CGFloat = 12
        let seedSamples = boundarySamples.count >= 16
            ? boundarySamples
            : samples
        guard let seed = Self.dominantColor(
            in: seedSamples,
            quantizationSteps: quantizationSteps
        ) else {
            return nil
        }

        // OCR and PDFKit fallbacks do not provide a trustworthy foreground
        // colour. For those candidates, keep to the mask perimeter so glyphs in
        // the interior cannot be mistaken for a second background colour.
        var backgroundSamples = foregroundColorIsTrusted
            ? samples
            : seedSamples
        let foregroundContrast = Self.colorDistanceSquared(
            foregroundColor,
            seed.color
        )
        if foregroundColorIsTrusted, foregroundContrast >= 0.16 {
            let filtered = samples.filter {
                !Self.isLikelyForegroundSample(
                    $0,
                    foregroundColor: foregroundColor,
                    backgroundColor: seed.color
                )
            }
            let excludedCount = samples.count - filtered.count
            // Bold glyphs can legitimately occupy close to half of a tight
            // PDFKit line box. Never discard a majority of the mask pixels;
            // a solid foreground-like background region therefore still
            // fails closed instead of being mistaken for text antialiasing.
            if excludedCount <= samples.count / 2,
               filtered.count >= max(32, samples.count / 2) {
                backgroundSamples = filtered
            }
        }

        guard let dominant = Self.dominantColor(
            in: backgroundSamples,
            quantizationSteps: quantizationSteps
        ) else {
            return nil
        }

        let dominantRatio = CGFloat(dominant.count)
            / CGFloat(backgroundSamples.count)
        let meanSquaredDistance = backgroundSamples.reduce(
            CGFloat.zero
        ) { result, sample in
            let red = sample.red - dominant.color.red
            let green = sample.green - dominant.color.green
            let blue = sample.blue - dominant.color.blue
            return result + red * red + green * green + blue * blue
        } / CGFloat(backgroundSamples.count)
        // A mask may cross a hard edge even when one side occupies more than
        // half of the narrow sampling ring. Treat a material secondary color as
        // unsafe when it is genuinely distant from the dominant fill. Mild
        // antialiasing or JPEG noise has low squared distance and remains safe.
        let secondaryRatio = 1 - dominantRatio
        let isComplex = secondaryRatio > 0.12
            && meanSquaredDistance > 0.02
        let resolvedMaskBounds = try Self.trimmedMaskBounds(
            maskBounds,
            foregroundColor: foregroundColor,
            foregroundColorIsTrusted: foregroundColorIsTrusted,
            backgroundColor: dominant.color,
            cropBox: cropBox,
            bitmap: bitmap,
            scaleX: scaleX,
            scaleY: scaleY,
            minimumX: minimumX,
            maximumX: maximumX,
            minimumY: minimumY,
            maximumY: maximumY
        )
        return (dominant.color, isComplex, resolvedMaskBounds)
    }

    static func trimmedMaskBounds(
        _ maskBounds: CGRect,
        foregroundColor: PDFTextColor,
        foregroundColorIsTrusted: Bool,
        backgroundColor: PDFTextColor,
        cropBox: CGRect,
        bitmap: NSBitmapImageRep,
        scaleX: CGFloat,
        scaleY: CGFloat,
        minimumX: Int,
        maximumX: Int,
        minimumY: Int,
        maximumY: Int
    ) throws -> CGRect {
        guard foregroundColorIsTrusted,
              colorDistanceSquared(foregroundColor, backgroundColor) >= 0.16
        else {
            return maskBounds
        }

        typealias EdgeSupport = (background: CGFloat, foreground: CGFloat)
        func support(xs: ClosedRange<Int>, ys: ClosedRange<Int>) -> EdgeSupport {
            let pixelCount = xs.count * ys.count
            let strideLength = max(
                1,
                Int(sqrt(Double(pixelCount) / 1_000))
            )
            var validCount = 0
            var backgroundCount = 0
            var foregroundCount = 0
            for y in stride(
                from: ys.lowerBound,
                through: ys.upperBound,
                by: strideLength
            ) {
                for x in stride(
                    from: xs.lowerBound,
                    through: xs.upperBound,
                    by: strideLength
                ) {
                    guard let sourceColor = bitmap.colorAt(x: x, y: y),
                          let color = sourceColor.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.05
                    else {
                        continue
                    }
                    validCount += 1
                    if colorDistanceSquared(
                        red: color.redComponent,
                        green: color.greenComponent,
                        blue: color.blueComponent,
                        to: backgroundColor
                    ) <= 0.01 {
                        backgroundCount += 1
                    }
                    if colorDistanceSquared(
                        red: color.redComponent,
                        green: color.greenComponent,
                        blue: color.blueComponent,
                        to: foregroundColor
                    ) <= 0.01 {
                        foregroundCount += 1
                    }
                }
            }
            guard validCount > 0 else { return (0, 0) }
            return (
                CGFloat(backgroundCount) / CGFloat(validCount),
                CGFloat(foregroundCount) / CGFloat(validCount)
            )
        }

        func edgeTrim(
            length: Int,
            supportAtOffset: (Int) -> EdgeSupport
        ) -> Int {
            let limit = min(max(0, length / 4), length - 2)
            guard limit >= 2 else { return 0 }
            var badCount = 0
            while badCount < limit {
                let edge = supportAtOffset(badCount)
                guard edge.background < 0.5, edge.foreground >= 0.5 else {
                    break
                }
                badCount += 1
            }
            guard badCount >= 2 else { return 0 }
            var retainedOffset = badCount
            var transitionCount = 0
            while retainedOffset < limit, transitionCount < 2 {
                let transition = supportAtOffset(retainedOffset)
                guard transition.background < 0.5,
                      transition.foreground < 0.5
                else {
                    break
                }
                retainedOffset += 1
                transitionCount += 1
            }
            guard retainedOffset + 1 < length else { return 0 }
            let firstInterior = supportAtOffset(retainedOffset)
            let secondInterior = supportAtOffset(retainedOffset + 1)
            guard firstInterior.background >= 0.5,
                  secondInterior.background >= 0.5
            else {
                return 0
            }
            return retainedOffset
        }

        let pixelWidth = maximumX - minimumX + 1
        let pixelHeight = maximumY - minimumY + 1
        let topTrim = edgeTrim(length: pixelHeight) { offset in
            support(
                xs: minimumX...maximumX,
                ys: (minimumY + offset)...(minimumY + offset)
            )
        }
        let bottomTrim = edgeTrim(length: pixelHeight) { offset in
            support(
                xs: minimumX...maximumX,
                ys: (maximumY - offset)...(maximumY - offset)
            )
        }
        let leftTrim = edgeTrim(length: pixelWidth) { offset in
            support(
                xs: (minimumX + offset)...(minimumX + offset),
                ys: minimumY...maximumY
            )
        }
        let rightTrim = edgeTrim(length: pixelWidth) { offset in
            support(
                xs: (maximumX - offset)...(maximumX - offset),
                ys: minimumY...maximumY
            )
        }
        try Task.checkCancellation()
        let trimmed = CGRect(
            x: maskBounds.minX + CGFloat(leftTrim) / scaleX,
            y: maskBounds.minY + CGFloat(bottomTrim) / scaleY,
            width: maskBounds.width
                - CGFloat(leftTrim + rightTrim) / scaleX,
            height: maskBounds.height
                - CGFloat(topTrim + bottomTrim) / scaleY
        ).intersection(cropBox)
        guard !trimmed.isNull,
              trimmed.width >= maskBounds.width * 0.5,
              trimmed.height >= maskBounds.height * 0.5
        else {
            return maskBounds
        }
        return trimmed
    }

    static func dominantColor(
        in samples: [(red: CGFloat, green: CGFloat, blue: CGFloat)],
        quantizationSteps: CGFloat
    ) -> (color: PDFTextColor, count: Int)? {
        var buckets: [
            Int: (count: Int, red: CGFloat, green: CGFloat, blue: CGFloat)
        ] = [:]
        for sample in samples {
            let redBucket = min(
                quantizationSteps - 1,
                floor(sample.red * quantizationSteps)
            )
            let greenBucket = min(
                quantizationSteps - 1,
                floor(sample.green * quantizationSteps)
            )
            let blueBucket = min(
                quantizationSteps - 1,
                floor(sample.blue * quantizationSteps)
            )
            let key = Int(redBucket) * 10_000
                + Int(greenBucket) * 100
                + Int(blueBucket)
            var bucket = buckets[key] ?? (0, 0, 0, 0)
            bucket.count += 1
            bucket.red += sample.red
            bucket.green += sample.green
            bucket.blue += sample.blue
            buckets[key] = bucket
        }
        guard let dominant = buckets.values.max(by: { $0.count < $1.count })
        else {
            return nil
        }
        let count = CGFloat(dominant.count)
        return (
            PDFTextColor(
                red: dominant.red / count,
                green: dominant.green / count,
                blue: dominant.blue / count,
                alpha: 1
            ),
            dominant.count
        )
    }

    static func isLikelyForegroundSample(
        _ sample: (red: CGFloat, green: CGFloat, blue: CGFloat),
        foregroundColor: PDFTextColor,
        backgroundColor: PDFTextColor
    ) -> Bool {
        let alpha = min(max(foregroundColor.alpha, 0), 1)
        let effectiveForeground = PDFTextColor(
            red: alpha * foregroundColor.red
                + (1 - alpha) * backgroundColor.red,
            green: alpha * foregroundColor.green
                + (1 - alpha) * backgroundColor.green,
            blue: alpha * foregroundColor.blue
                + (1 - alpha) * backgroundColor.blue,
            alpha: 1
        )
        let vectorRed = effectiveForeground.red - backgroundColor.red
        let vectorGreen = effectiveForeground.green - backgroundColor.green
        let vectorBlue = effectiveForeground.blue - backgroundColor.blue
        let vectorLengthSquared = vectorRed * vectorRed
            + vectorGreen * vectorGreen
            + vectorBlue * vectorBlue
        guard vectorLengthSquared >= 0.16 else { return false }

        let sampleRed = sample.red - backgroundColor.red
        let sampleGreen = sample.green - backgroundColor.green
        let sampleBlue = sample.blue - backgroundColor.blue
        let projection = (
            sampleRed * vectorRed
                + sampleGreen * vectorGreen
                + sampleBlue * vectorBlue
        ) / vectorLengthSquared
        guard projection >= 0.20, projection <= 1.10 else { return false }

        let clampedProjection = min(max(projection, 0), 1)
        let residualRed = sampleRed - clampedProjection * vectorRed
        let residualGreen = sampleGreen - clampedProjection * vectorGreen
        let residualBlue = sampleBlue - clampedProjection * vectorBlue
        let residualSquared = residualRed * residualRed
            + residualGreen * residualGreen
            + residualBlue * residualBlue
        return residualSquared <= 0.0025
    }

    static func colorDistanceSquared(
        _ lhs: PDFTextColor,
        _ rhs: PDFTextColor
    ) -> CGFloat {
        colorDistanceSquared(
            red: lhs.red,
            green: lhs.green,
            blue: lhs.blue,
            to: rhs
        )
    }

    static func colorDistanceSquared(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        to color: PDFTextColor
    ) -> CGFloat {
        let redDistance = red - color.red
        let greenDistance = green - color.green
        let blueDistance = blue - color.blue
        return redDistance * redDistance
            + greenDistance * greenDistance
            + blueDistance * blueDistance
    }

    static func isVisuallyIndistinguishable(
        foreground: PDFTextColor,
        background: PDFTextColor
    ) -> Bool {
        let alpha = min(max(foreground.alpha, 0), 1)
        let effectiveForeground = PDFTextColor(
            red: alpha * foreground.red + (1 - alpha) * background.red,
            green: alpha * foreground.green + (1 - alpha) * background.green,
            blue: alpha * foreground.blue + (1 - alpha) * background.blue,
            alpha: 1
        )
        guard colorDistanceSquared(effectiveForeground, background) <= 0.0025
        else {
            return false
        }
        let foregroundLuminance = relativeLuminance(effectiveForeground)
        let backgroundLuminance = relativeLuminance(background)
        let contrastRatio = (
            max(foregroundLuminance, backgroundLuminance) + 0.05
        ) / (min(foregroundLuminance, backgroundLuminance) + 0.05)
        return contrastRatio <= 1.08
    }

    static func relativeLuminance(_ color: PDFTextColor) -> CGFloat {
        func linearized(_ component: CGFloat) -> CGFloat {
            let clamped = min(max(component, 0), 1)
            if clamped <= 0.04045 {
                return clamped / 12.92
            }
            return pow((clamped + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(color.red)
            + 0.7152 * linearized(color.green)
            + 0.0722 * linearized(color.blue)
    }

    func spatiallyOrdered(
        _ input: [TextCandidate],
        pageBounds: CGRect
    ) -> [TextCandidate] {
        guard input.count > 1 else {
            return input.map { candidate in
                var copy = candidate
                copy.alignment = Self.resolvedAlignment(
                    for: copy,
                    within: pageBounds
                )
                return copy
            }
        }

        let verticalOrder: (TextCandidate, TextCandidate) -> Bool = { lhs, rhs in
            let verticalTolerance = max(2, min(lhs.bounds.height, rhs.bounds.height) * 0.35)
            if abs(lhs.bounds.maxY - rhs.bounds.maxY) > verticalTolerance {
                return lhs.bounds.maxY > rhs.bounds.maxY
            }
            return lhs.bounds.minX < rhs.bounds.minX
        }

        let wideThreshold = max(pageBounds.width * 0.50, 1)
        let spanningIndices = Set(
            input.indices.filter { input[$0].bounds.width >= wideThreshold }
        )
        let bodyIndices = input.indices.filter { !spanningIndices.contains($0) }
        guard !bodyIndices.isEmpty else {
            return input.map { candidate in
                var copy = candidate
                copy.alignment = Self.resolvedAlignment(
                    for: copy,
                    within: pageBounds
                )
                return copy
            }.sorted(by: verticalOrder)
        }

        let alignmentTolerance = max(12, pageBounds.width * 0.045)
        var clusters: [ColumnCluster] = []
        for index in bodyIndices.sorted(by: {
            if input[$0].bounds.minX == input[$1].bounds.minX {
                return input[$0].bounds.maxY > input[$1].bounds.maxY
            }
            return input[$0].bounds.minX < input[$1].bounds.minX
        }) {
            let candidate = input[index]
            let bestClusterIndex = clusters.indices
                .filter { clusterIndex in
                    let cluster = clusters[clusterIndex]
                    let overlap = Self.horizontalOverlap(
                        candidate.bounds,
                        cluster.bounds
                    )
                    let minimumWidth = max(
                        1,
                        min(candidate.bounds.width, cluster.bounds.width)
                    )
                    let leftEdgeDistance = abs(
                        candidate.bounds.minX
                            - cluster.representativeLeftEdge
                    )
                    let overlapDistanceLimit = max(
                        alignmentTolerance * 2,
                        minimumWidth * 0.35
                    )
                    return leftEdgeDistance <= alignmentTolerance
                        || (overlap / minimumWidth >= 0.25
                            && leftEdgeDistance <= overlapDistanceLimit)
                }
                .min { lhs, rhs in
                    abs(input[index].bounds.minX - clusters[lhs].representativeLeftEdge)
                        < abs(input[index].bounds.minX - clusters[rhs].representativeLeftEdge)
                }

            if let bestClusterIndex {
                clusters[bestClusterIndex].bounds = clusters[bestClusterIndex]
                    .bounds.union(candidate.bounds)
                clusters[bestClusterIndex].leftEdges.append(candidate.bounds.minX)
                clusters[bestClusterIndex].candidateIndices.append(index)
            } else {
                clusters.append(
                    ColumnCluster(
                        bounds: candidate.bounds,
                        leftEdges: [candidate.bounds.minX],
                        candidateIndices: [index]
                    )
                )
            }
        }

        clusters.sort { $0.bounds.minX < $1.bounds.minX }
        var columnByCandidateIndex: [Int: Int] = [:]
        for (columnIndex, cluster) in clusters.enumerated() {
            for candidateIndex in cluster.candidateIndices {
                columnByCandidateIndex[candidateIndex] = columnIndex
            }
        }

        // With only one detected body column, ordinary top-to-bottom order is safest.
        guard clusters.count > 1 else {
            return input.enumerated()
                .map { index, candidate in
                    var copy = candidate
                    let columnIndex = columnByCandidateIndex[index] ?? 0
                    copy.columnIndex = columnIndex
                    copy.alignment = Self.resolvedAlignment(
                        for: copy,
                        // With one body column the cluster's maxX is merely
                        // the longest glyph run, not the column's right edge.
                        // Use the page bounds so a line ending at that run is
                        // not falsely classified as right-aligned.
                        within: pageBounds
                    )
                    return copy
                }
                .sorted(by: verticalOrder)
        }

        let spanning = spanningIndices.sorted { verticalOrder(input[$0], input[$1]) }
        var outputIndices: [Int] = []
        var unusedBody = Set(bodyIndices)

        func alignmentBounds(for columnIndex: Int) -> CGRect {
            guard clusters.indices.contains(columnIndex) else {
                return pageBounds
            }
            let cluster = clusters[columnIndex]
            let leftBoundary: CGFloat
            if columnIndex > clusters.startIndex {
                let previous = clusters[columnIndex - 1]
                leftBoundary = (previous.bounds.maxX + cluster.bounds.minX) / 2
            } else {
                leftBoundary = pageBounds.minX
            }
            let rightBoundary: CGFloat
            if columnIndex + 1 < clusters.endIndex {
                let next = clusters[columnIndex + 1]
                rightBoundary = (cluster.bounds.maxX + next.bounds.minX) / 2
            } else {
                rightBoundary = pageBounds.maxX
            }
            return CGRect(
                x: leftBoundary,
                y: pageBounds.minY,
                width: max(1, rightBoundary - leftBoundary),
                height: pageBounds.height
            )
        }

        func appendRegion(above lowerY: CGFloat, below upperY: CGFloat) {
            let region = unusedBody.filter { index in
                let midpointY = input[index].bounds.midY
                return midpointY > lowerY && midpointY <= upperY
            }
            let ordered = region.sorted { lhs, rhs in
                let leftColumn = columnByCandidateIndex[lhs] ?? 0
                let rightColumn = columnByCandidateIndex[rhs] ?? 0
                if leftColumn != rightColumn { return leftColumn < rightColumn }
                return verticalOrder(input[lhs], input[rhs])
            }
            outputIndices.append(contentsOf: ordered)
            unusedBody.subtract(region)
        }

        var upperY = pageBounds.maxY + 1
        for spanningIndex in spanning {
            appendRegion(above: input[spanningIndex].bounds.midY, below: upperY)
            outputIndices.append(spanningIndex)
            upperY = input[spanningIndex].bounds.midY
        }
        appendRegion(above: pageBounds.minY - 1, below: upperY)
        outputIndices.append(
            contentsOf: unusedBody.sorted { lhs, rhs in
                let leftColumn = columnByCandidateIndex[lhs] ?? 0
                let rightColumn = columnByCandidateIndex[rhs] ?? 0
                if leftColumn != rightColumn { return leftColumn < rightColumn }
                return verticalOrder(input[lhs], input[rhs])
            }
        )

        return outputIndices.map { index in
            var candidate = input[index]
            if spanningIndices.contains(index) {
                candidate.columnIndex = -1
                candidate.alignment = Self.resolvedAlignment(
                    for: candidate,
                    within: pageBounds
                )
            } else {
                let columnIndex = columnByCandidateIndex[index] ?? 0
                candidate.columnIndex = columnIndex
                candidate.alignment = Self.resolvedAlignment(
                    for: candidate,
                    within: alignmentBounds(for: columnIndex)
                )
            }
            return candidate
        }
    }

    func makeLines(
        from candidates: [TextCandidate],
        pageIndex: Int
    ) throws -> [PDFTextLine] {
        var occurrenceBySeed: [String: Int] = [:]
        var lines: [PDFTextLine] = []
        lines.reserveCapacity(candidates.count)
        for (readingOrder, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            let seed = [
                "line",
                String(pageIndex),
                Self.geometryKey(candidate.bounds),
                candidate.text,
                candidate.extractionSource.rawValue
            ].joined(separator: "|")
            let occurrence = occurrenceBySeed[seed, default: 0]
            occurrenceBySeed[seed] = occurrence + 1
            let stableSeed = occurrence == 0 ? seed : "\(seed)|\(occurrence)"

            lines.append(PDFTextLine(
                id: "pdf-line-\(Self.stableHash(stableSeed))",
                text: candidate.text,
                bounds: candidate.bounds,
                sourceMaskBounds: candidate.sourceMaskBounds
                    ?? candidate.bounds,
                fontName: candidate.fontName,
                fontSize: candidate.fontSize,
                textColor: candidate.textColor,
                backgroundColor: candidate.backgroundColor,
                alignment: candidate.alignment ?? .left,
                readingOrder: readingOrder,
                columnIndex: candidate.columnIndex,
                extractionSource: candidate.extractionSource
            ))
        }
        return lines
    }

    func makeBlocks(
        from lines: [PDFTextLine],
        pageIndex: Int
    ) throws -> [PDFTextBlock] {
        guard let firstLine = lines.first else { return [] }

        var groupedLines: [[PDFTextLine]] = [[firstLine]]
        for line in lines.dropFirst() {
            try Task.checkCancellation()
            guard let previous = groupedLines.last?.last,
                  Self.canJoin(previous, line)
            else {
                groupedLines.append([line])
                continue
            }
            groupedLines[groupedLines.count - 1].append(line)
        }

        var blocks: [PDFTextBlock] = []
        blocks.reserveCapacity(groupedLines.count)
        for (readingOrder, blockLines) in groupedLines.enumerated() {
            try Task.checkCancellation()
            let lineIDs = blockLines.map(\.id)
            let text = blockLines.reduce(into: "") { result, line in
                if result.isEmpty {
                    result = line.text
                } else if result.hasSuffix("-") {
                    result.removeLast()
                    result += line.text
                } else {
                    result += " " + line.text
                }
            }
            let bounds = blockLines.dropFirst().reduce(blockLines[0].bounds) {
                $0.union($1.bounds)
            }
            let seed = [
                "block",
                String(pageIndex),
                lineIDs.joined(separator: ",")
            ].joined(separator: "|")
            blocks.append(PDFTextBlock(
                id: "pdf-block-\(Self.stableHash(seed))",
                lineIDs: lineIDs,
                text: text,
                bounds: bounds,
                readingOrder: readingOrder,
                columnIndex: blockLines[0].columnIndex
            ))
        }
        return blocks
    }

    static func alignListBlockLines(
        _ lines: [PDFTextLine],
        blocks: [PDFTextBlock]
    ) -> [PDFTextLine] {
        let listBlockLineIDs = Set(
            blocks
                .filter { block in
                    guard let firstLineID = block.lineIDs.first,
                          let firstLine = lines.first(where: {
                              $0.id == firstLineID
                          })
                    else {
                        return false
                    }
                    return startsWithListMarker(firstLine.text)
                }
                .flatMap(\.lineIDs)
        )
        guard !listBlockLineIDs.isEmpty else { return lines }

        return lines.map { line in
            guard listBlockLineIDs.contains(line.id),
                  line.alignment != .left
            else {
                return line
            }
            return PDFTextLine(
                id: line.id,
                text: line.text,
                bounds: line.bounds,
                sourceMaskBounds: line.sourceMaskBounds,
                fontName: line.fontName,
                fontSize: line.fontSize,
                textColor: line.textColor,
                backgroundColor: line.backgroundColor,
                alignment: .left,
                readingOrder: line.readingOrder,
                columnIndex: line.columnIndex,
                extractionSource: line.extractionSource
            )
        }
    }

    static func canJoin(_ previous: PDFTextLine, _ current: PDFTextLine) -> Bool {
        guard previous.extractionSource == current.extractionSource,
              // A fresh list item starts a new translation unit.  A wrapped
              // continuation line has no marker and can safely share the
              // preceding block even when PDFKit reports a different font
              // resource for that run.
              !startsWithListMarker(current.text)
        else {
            return false
        }

        let sameColumn = previous.columnIndex >= 0
            && previous.columnIndex == current.columnIndex
        // A long list line can be classified as a page-spanning candidate
        // while its short wrapped continuation is assigned to the nearest
        // body column.  Treat that specific geometry as one text block; if it
        // is not joined, the translation engine receives `Cloud?` or `data`
        // as an independent unit and the composer must squeeze the translated
        // sentence into a tiny source glyph box.
        let spanningListContinuation = previous.columnIndex < 0
            && startsWithListMarker(previous.text)
        guard sameColumn || spanningListContinuation else {
            return false
        }

        let verticalGap = previous.bounds.minY - current.bounds.maxY
        let referenceHeight = max(previous.bounds.height, current.bounds.height)
        guard verticalGap >= -referenceHeight * 0.15,
              verticalGap <= referenceHeight * 0.85
        else {
            return false
        }

        let overlap = horizontalOverlap(previous.bounds, current.bounds)
        let minimumWidth = max(1, min(previous.bounds.width, current.bounds.width))
        // Word/PDF exports commonly indent a wrapped continuation by 18pt
        // (the FAQ fixture does exactly this).  The old 8–13pt threshold split
        // those lines into independent blocks and sent a short fragment such
        // as “process.” to the model by itself, which then had to be squeezed
        // into a 38pt source box.
        let leftEdgeTolerance = max(
            24,
            max(previous.fontSize, current.fontSize) * 2.5
        )
        guard overlap / minimumWidth >= 0.35,
              abs(previous.bounds.minX - current.bounds.minX) <= leftEdgeTolerance,
              abs(previous.fontSize - current.fontSize)
                  <= max(1.5, previous.fontSize * 0.18)
        else {
            return false
        }

        // The font resource name is not a semantic style boundary. Microsoft
        // Word exports the first indented answer run as CourierNewPSMT and its
        // wrapped continuation as ArialMT even though both are visually the
        // same size and colour. Keep the block together when those observable
        // metrics match; the composer will choose one stable target font for
        // the translated block.
        return previous.textColor == current.textColor
    }

    static func startsWithListMarker(_ text: String) -> Bool {
        let normalized = normalizedText(text)
        guard let token = normalized.split(separator: " ").first else {
            return false
        }
        let marker = String(token)
        let listMarkers = [
            "•", "◦", "○", "●", "▪", "▫", "‣", "⁃",
            "-", "–", "—", "*", "o", "O", "0", ""
        ]
        if listMarkers.contains(marker) {
            return true
        }
        let digits = marker.drop(while: { $0.isNumber })
        return !digits.isEmpty
            && digits.allSatisfy { $0 == "." || $0 == ")" }
            && marker.dropLast(digits.count).allSatisfy(\.isNumber)
    }

    /// PowerPoint PDFs can place a hidden white animation run in the same
    /// PDFKit selection as visible black text. Preserve the attributed colour
    /// boundaries so the later raster-contrast pass can discard only the
    /// genuinely invisible run.
    static func splitAttributedColorRuns(
        _ selection: PDFSelection,
        on page: PDFPage
    ) -> [PDFSelection] {
        guard selection.numberOfTextRanges(on: page) == 1,
              let attributedString = selection.attributedString,
              attributedString.length > 0,
              let pageString = page.string
        else {
            return [selection]
        }
        let source = pageString as NSString
        let rawPageRange = selection.range(at: 0, on: page)
        guard rawPageRange.location != NSNotFound,
              rawPageRange.location < source.length
        else {
            return [selection]
        }
        let pageRange = NSRange(
            location: rawPageRange.location,
            length: min(
                rawPageRange.length,
                source.length - rawPageRange.location
            )
        )
        let pageSubstring = source.substring(with: pageRange) as NSString
        let attributedSource = attributedString.string as NSString
        guard attributedSource.length > 0 else { return [selection] }
        let match = pageSubstring.range(of: attributedString.string)
        guard match.location != NSNotFound else { return [selection] }
        let remainingSearchRange = NSRange(
            location: NSMaxRange(match),
            length: pageSubstring.length - NSMaxRange(match)
        )
        guard pageSubstring.range(
            of: attributedString.string,
            options: [],
            range: remainingSearchRange
        ).location == NSNotFound
        else {
            return [selection]
        }
        let mappedBase = pageRange.location + match.location

        var runs: [AttributedColorRun] = []
        var encounteredInvalidColor = false
        attributedString.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, stop in
            guard let color = value as? NSColor,
                  let deviceColor = color.usingColorSpace(.deviceRGB)
            else {
                encounteredInvalidColor = true
                stop.pointee = true
                return
            }
            if let lastIndex = runs.indices.last,
               NSMaxRange(runs[lastIndex].range) == range.location,
               Self.colorsApproximatelyEqual(
                runs[lastIndex].color,
                deviceColor
               ) {
                runs[lastIndex].range.length += range.length
            } else {
                runs.append(
                    AttributedColorRun(range: range, color: deviceColor)
                )
            }
        }
        guard !encounteredInvalidColor, runs.count > 1 else {
            return [selection]
        }

        var output: [PDFSelection] = []
        for run in runs {
            guard let localRange = Self.trimmedTextRange(
                run.range,
                in: attributedSource
            ) else {
                continue
            }
            let absoluteRange = NSRange(
                location: mappedBase + localRange.location,
                length: localRange.length
            )
            guard NSMaxRange(absoluteRange) <= source.length,
                  let runSelection = page.selection(for: absoluteRange),
                  Self.normalizedText(runSelection.string ?? "")
                    == Self.normalizedText(
                        attributedSource.substring(with: localRange)
                    )
            else {
                return [selection]
            }
            output.append(runSelection)
        }
        return output.count > 1 ? output : [selection]
    }

    static func colorsApproximatelyEqual(
        _ lhs: NSColor?,
        _ rhs: NSColor?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.redComponent - rhs.redComponent) <= 0.01
                && abs(lhs.greenComponent - rhs.greenComponent) <= 0.01
                && abs(lhs.blueComponent - rhs.blueComponent) <= 0.01
                && abs(lhs.alphaComponent - rhs.alphaComponent) <= 0.01
        default:
            return false
        }
    }

    /// PDFKit sometimes represents visually separate, same-baseline text runs
    /// as one line by inserting a whitespace character whose bounds span the
    /// entire gap. Splitting only those oversized spaces preserves ordinary
    /// sentences while recovering the source document's actual text boxes.
    static func splitVisualLineSelection(
        _ selection: PDFSelection,
        on page: PDFPage
    ) -> [PDFSelection] {
        let rangeCount = selection.numberOfTextRanges(on: page)
        guard rangeCount > 0, let pageString = page.string else {
            return [selection]
        }
        let source = pageString as NSString
        guard source.length > 0 else { return [selection] }

        let selectionFontSize = selection.attributedString.flatMap {
            attributedString -> CGFloat? in
            guard attributedString.length > 0 else { return nil }
            return (attributedString.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? NSFont)?.pointSize
        } ?? max(5, selection.bounds(for: page).height * 0.78)
        let oversizedSpaceWidth = max(12, selectionFontSize * 2)
        var output: [PDFSelection] = []
        var didSplit = false

        for rangeIndex in 0..<rangeCount {
            let rawRange = selection.range(at: rangeIndex, on: page)
            guard rawRange.location != NSNotFound,
                  rawRange.location < source.length
            else {
                return [selection]
            }
            let safeLength = min(
                rawRange.length,
                source.length - rawRange.location
            )
            guard safeLength > 0 else { return [selection] }
            let upperBound = rawRange.location + safeLength
            var segmentRanges: [NSRange] = []
            var segmentStart = rawRange.location
            var cursor = rawRange.location

            while cursor < upperBound {
                guard Self.isHorizontalWhitespace(
                    source.character(at: cursor)
                ) else {
                    cursor += 1
                    continue
                }
                let whitespaceStart = cursor
                repeat {
                    cursor += 1
                } while cursor < upperBound
                    && Self.isHorizontalWhitespace(
                        source.character(at: cursor)
                    )

                let whitespaceRange = NSRange(
                    location: whitespaceStart,
                    length: cursor - whitespaceStart
                )
                let whitespaceBounds = Self.visualBounds(
                    for: whitespaceRange,
                    on: page
                )
                let prefixRange = Self.trimmedTextRange(
                    NSRange(
                        location: segmentStart,
                        length: whitespaceStart - segmentStart
                    ),
                    in: source
                )
                let remainingRange = Self.trimmedTextRange(
                    NSRange(
                        location: cursor,
                        length: upperBound - cursor
                    ),
                    in: source
                )

                // Only split an interior gap. Large indentation or a trailing
                // PDF-inserted space must not create an empty text box.
                if let prefixRange,
                   let remainingRange,
                   !whitespaceBounds.isNull,
                   !whitespaceBounds.isInfinite,
                   whitespaceBounds.width > oversizedSpaceWidth {
                    let prefixBounds = Self.visualBounds(
                        for: prefixRange,
                        on: page
                    )
                    let remainingBounds = Self.visualBounds(
                        for: remainingRange,
                        on: page
                    )
                    let actualGlyphGap = max(
                        0,
                        max(
                            remainingBounds.minX - prefixBounds.maxX,
                            prefixBounds.minX - remainingBounds.maxX
                        )
                    )
                    guard !prefixBounds.isNull,
                          !remainingBounds.isNull,
                          actualGlyphGap > oversizedSpaceWidth
                    else {
                        continue
                    }
                    segmentRanges.append(prefixRange)
                    segmentStart = cursor
                    didSplit = true
                }
            }

            if let suffixRange = Self.trimmedTextRange(
                NSRange(
                    location: segmentStart,
                    length: upperBound - segmentStart
                ),
                in: source
            ) {
                segmentRanges.append(suffixRange)
            }

            guard !segmentRanges.isEmpty else { return [selection] }
            for segmentRange in segmentRanges {
                guard let segmentSelection = page.selection(for: segmentRange)
                else {
                    return [selection]
                }
                output.append(segmentSelection)
            }
        }

        return didSplit && !output.isEmpty ? output : [selection]
    }

    static func visualBounds(
        for range: NSRange,
        on page: PDFPage
    ) -> CGRect {
        // This is more accurate than characterBounds(at:) for PowerPoint PDFs,
        // whose inserted gap character can report another glyph's geometry.
        if let whitespaceSelection = page.selection(for: range) {
            let bounds = whitespaceSelection.bounds(for: page)
            if !bounds.isNull, !bounds.isInfinite {
                return bounds
            }
        }

        var bounds = CGRect.null
        let upperBound = range.location + range.length
        for index in range.location..<upperBound {
            let characterBounds = page.characterBounds(at: index)
            guard !characterBounds.isNull,
                  !characterBounds.isInfinite,
                  characterBounds.width > 0 || characterBounds.height > 0
            else {
                continue
            }
            bounds = bounds.union(characterBounds)
        }
        return bounds
    }

    static func trimmedTextRange(
        _ range: NSRange,
        in source: NSString
    ) -> NSRange? {
        guard range.location != NSNotFound,
              range.location < source.length
        else {
            return nil
        }
        let safeLength = min(range.length, source.length - range.location)
        var lowerBound = range.location
        var upperBound = range.location + safeLength
        while lowerBound < upperBound,
              Self.isWhitespaceOrNewline(source.character(at: lowerBound)) {
            lowerBound += 1
        }
        while upperBound > lowerBound,
              Self.isWhitespaceOrNewline(source.character(at: upperBound - 1)) {
            upperBound -= 1
        }
        guard lowerBound < upperBound else { return nil }
        return NSRange(
            location: lowerBound,
            length: upperBound - lowerBound
        )
    }

    static func isHorizontalWhitespace(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(codeUnit) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }

    static func isWhitespaceOrNewline(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(codeUnit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    static func normalizedText(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Legal boilerplate and page numbers are part of the document chrome, not
    /// translatable content. Leaving them untouched also preserves decorative
    /// footer gradients that cannot be recreated by a solid text mask.
    static func isPreservedDocumentChrome(
        text: String,
        bounds: CGRect,
        fontSize: CGFloat,
        pageBounds: CGRect
    ) -> Bool {
        let normalized = normalizedText(text).lowercased()
        let legalMarkers = [
            "©",
            "copyright",
            "all rights reserved",
            "confidential",
            "internal",
            "disclosure prohibited"
        ]
        let legalFooterLimit = pageBounds.minY + pageBounds.height * 0.15
        if bounds.maxY <= legalFooterLimit,
           legalMarkers.contains(where: normalized.contains) {
            return true
        }

        guard bounds.maxY <= pageBounds.minY + pageBounds.height * 0.09 else {
            return false
        }

        guard fontSize <= max(10, pageBounds.height * 0.025) else {
            return false
        }

        let ignorable = CharacterSet.decimalDigits
            .union(.whitespacesAndNewlines)
            .union(.punctuationCharacters)
        return !normalized.isEmpty
            && normalized.unicodeScalars.allSatisfy(ignorable.contains)
    }

    static func containsPrivateSystemFontResource(_ data: Data) -> Bool {
        [".SFNS-", ".AppleSystemUIFont"].contains { marker in
            data.range(of: Data(marker.utf8)) != nil
        }
    }

    static func isPDFKitPrivateFontFallback(_ fontName: String?) -> Bool {
        switch fontName {
        case "TimesNewRomanPSMT", "Times-Roman":
            return true
        default:
            return false
        }
    }

    /// PDFKit exposes the baked appearance text of FreeText annotations through
    /// page text selection. It is existing interactive document chrome, not a
    /// second copy of body text, so translating it would collide with itself.
    static func isFreeTextAnnotationAppearance(
        text: String,
        bounds: CGRect,
        on page: PDFPage
    ) -> Bool {
        let normalized = normalizedText(text)
        guard !normalized.isEmpty else { return false }

        return page.annotations.contains { annotation in
            let subtype = annotation.type?
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard subtype == "FreeText" else {
                return false
            }
            let intersection = annotation.bounds.intersection(bounds)
            guard !intersection.isNull else { return false }
            let textArea = max(0.01, bounds.width * bounds.height)
            return intersection.width * intersection.height / textArea >= 0.5
        }
    }

    /// A foreground colour is safe to use for glyph filtering only when every
    /// attributed run resolves to the same Device RGB colour. Mixed-colour text
    /// deliberately falls back to conservative perimeter sampling.
    static func uniformTextColor(
        in attributedString: NSAttributedString?
    ) -> PDFTextColor? {
        guard let attributedString, attributedString.length > 0 else {
            return nil
        }
        var resolvedColor: PDFTextColor?
        var isUniform = true
        attributedString.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, stop in
            guard let color = value as? NSColor,
                  let deviceColor = color.usingColorSpace(.deviceRGB)
            else {
                isUniform = false
                stop.pointee = true
                return
            }
            let candidate = PDFTextColor(
                red: deviceColor.redComponent,
                green: deviceColor.greenComponent,
                blue: deviceColor.blueComponent,
                alpha: deviceColor.alphaComponent
            )
            if let resolvedColor,
               abs(resolvedColor.red - candidate.red) > 0.01
                    || abs(resolvedColor.green - candidate.green) > 0.01
                    || abs(resolvedColor.blue - candidate.blue) > 0.01
                    || abs(resolvedColor.alpha - candidate.alpha) > 0.01 {
                isUniform = false
                stop.pointee = true
                return
            }
            resolvedColor = candidate
        }
        return isUniform ? resolvedColor : nil
    }

    static func textColor(from color: NSColor?) -> PDFTextColor {
        guard let converted = (color ?? .black).usingColorSpace(.deviceRGB) else {
            return .black
        }
        return PDFTextColor(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
    }

    static func textAlignment(
        from alignment: NSTextAlignment?
    ) -> PDFTextAlignment? {
        switch alignment {
        case .center, .right:
            // PDFKit often copies a paragraph's alignment onto every visual
            // glyph run. In Word-exported PDFs that style can be stale or
            // synthetic: the FAQ answer runs visibly start at x=126, yet
            // PDFKit reports `.right`. Do not trust the style until it agrees
            // with the measured glyph geometry in `resolvedAlignment`.
            return nil
        default:
            // PDFKit frequently synthesizes `.left` for positioned glyph runs
            // even when the visual line is centered or right-aligned. Let the
            // page/column geometry disambiguate every default.
            return nil
        }
    }

    static func resolvedAlignment(
        for candidate: TextCandidate,
        within container: CGRect
    ) -> PDFTextAlignment {
        // The actual glyph edges are authoritative for positioned PDF text.
        // This prevents a stale paragraph style from turning a left-indented
        // answer into a centered translation annotation. It also keeps true
        // centered/right text working because the same geometry is used by the
        // existing alignment regression test.
        return inferredAlignment(for: candidate, within: container)
    }

    static func inferredAlignment(
        for candidate: TextCandidate,
        within container: CGRect
    ) -> PDFTextAlignment {
        // Bullet and numbered runs are list geometry, not paragraph geometry.
        // A long bullet line can happen to have equal page-side whitespace and
        // look mathematically centered; translating it as centered would move
        // the whole question away from its bullet and its following answer.
        if startsWithListMarker(candidate.text) {
            return .left
        }
        guard container.width > candidate.bounds.width else { return .left }
        let tolerance = max(5, min(18, candidate.fontSize * 0.8))
        let leftGap = candidate.bounds.minX - container.minX
        let rightGap = container.maxX - candidate.bounds.maxX

        if abs(candidate.bounds.midX - container.midX) <= tolerance,
           leftGap > tolerance,
           rightGap > tolerance {
            return .center
        }
        if abs(rightGap) <= tolerance, leftGap > tolerance * 2 {
            return .right
        }
        return .left
    }

    static func horizontalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
    }

    static func areDuplicate(
        _ nativeCandidate: TextCandidate,
        _ ocrCandidate: TextCandidate
    ) -> Bool {
        let intersection = nativeCandidate.bounds.intersection(ocrCandidate.bounds)
        if !intersection.isNull {
            let smallerArea = max(
                1,
                min(
                    nativeCandidate.bounds.width * nativeCandidate.bounds.height,
                    ocrCandidate.bounds.width * ocrCandidate.bounds.height
                )
            )
            let overlapRatio = intersection.width * intersection.height / smallerArea
            if overlapRatio >= 0.4 { return true }
        }

        let nativeText = normalizedText(nativeCandidate.text).lowercased()
        let ocrText = normalizedText(ocrCandidate.text).lowercased()
        guard nativeText == ocrText else { return false }
        let horizontalDistance = abs(
            nativeCandidate.bounds.midX - ocrCandidate.bounds.midX
        )
        let verticalDistance = abs(
            nativeCandidate.bounds.midY - ocrCandidate.bounds.midY
        )
        return horizontalDistance <= max(
            nativeCandidate.bounds.width,
            ocrCandidate.bounds.width
        ) && verticalDistance <= max(
            nativeCandidate.bounds.height,
            ocrCandidate.bounds.height
        ) * 2
    }

    static func applyingOCRContrast(
        to result: BackgroundSamplingResult
    ) -> BackgroundSamplingResult {
        var candidates = result.candidates
        for index in candidates.indices
        where candidates[index].extractionSource == .visionOCR {
            let background = candidates[index].backgroundColor
            let luminance = 0.2126 * background.red
                + 0.7152 * background.green
                + 0.0722 * background.blue
            candidates[index].textColor = luminance >= 0.52 ? .black : .white
        }
        return BackgroundSamplingResult(
            candidates: candidates,
            complexCandidateIndices: result.complexCandidateIndices,
            unavailableCandidateIndices: result.unavailableCandidateIndices
        )
    }

    static func linkOverlapWarnings(
        on page: PDFPage,
        lines: [PDFTextLine],
        pageIndex: Int
    ) -> [PDFDocumentWarning] {
        let links = page.annotations.filter(isLinkAnnotation)
        guard !links.isEmpty else { return [] }

        return lines.compactMap { line in
            let overlapping = links.filter {
                meaningfullyOverlaps(line.bounds, $0.bounds)
            }
            guard !overlapping.isEmpty else { return nil }
            let targets = Set(overlapping.compactMap(linkURLString))
            return .linkOverlap(
                pageIndex: pageIndex,
                lineID: line.id,
                target: targets.count == 1 ? targets.first : nil
            )
        }
    }

    static func isLinkAnnotation(_ annotation: PDFAnnotation) -> Bool {
        annotation.type?.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        ) == "Link"
    }

    static func linkURLString(_ annotation: PDFAnnotation) -> String? {
        if let action = annotation.action as? PDFActionURL,
           let url = action.url {
            return url.absoluteString
        }
        return annotation.url?.absoluteString
    }

    static func meaningfullyOverlaps(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        guard isFinite(lhs),
              isFinite(rhs),
              lhs.width > 0,
              lhs.height > 0,
              rhs.width > 0,
              rhs.height > 0
        else {
            return false
        }
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull,
              intersection.width > 0,
              intersection.height > 0
        else {
            return false
        }
        let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
        return smallerArea > 0
            && intersection.width * intersection.height / smallerArea >= 0.2
    }

    static func pageDisplayGeometry(
        for page: PDFPage,
        cropBox: CGRect,
        rotation: Int
    ) -> PageDisplayGeometry? {
        guard [0, 90, 180, 270].contains(rotation),
              isFinite(cropBox),
              !cropBox.isNull,
              cropBox.width > 0,
              cropBox.height > 0
        else {
            return nil
        }

        let pageToDisplay = page.transform(for: .cropBox)
        guard isFinite(pageToDisplay) else { return nil }
        let determinant = pageToDisplay.a * pageToDisplay.d
            - pageToDisplay.b * pageToDisplay.c
        guard determinant.isFinite, abs(determinant) > 0.000_001 else {
            return nil
        }

        let displayBounds = cropBox
            .applying(pageToDisplay)
            .standardized
        let expectedDisplaySize = rotation == 90 || rotation == 270
            ? CGSize(width: cropBox.height, height: cropBox.width)
            : cropBox.size
        guard isFinite(displayBounds),
              !displayBounds.isNull,
              displayBounds.width > 0,
              displayBounds.height > 0,
              hasMatchingAspectRatio(
                  displayBounds.size,
                  expectedDisplaySize
              )
        else {
            return nil
        }

        let displayToPage = pageToDisplay.inverted()
        guard isFinite(displayToPage) else { return nil }
        let reconstructedCrop = displayBounds
            .applying(displayToPage)
            .standardized
            .intersection(cropBox)
        guard isFinite(reconstructedCrop),
              !reconstructedCrop.isNull,
              reconstructedCrop.width >= cropBox.width * 0.999,
              reconstructedCrop.height >= cropBox.height * 0.999
        else {
            return nil
        }

        return PageDisplayGeometry(
            cropBox: cropBox,
            pageToDisplay: pageToDisplay,
            displayToPage: displayToPage,
            displayBounds: displayBounds
        )
    }

    static func hasMatchingAspectRatio(
        _ lhs: CGSize,
        _ rhs: CGSize,
        tolerance: CGFloat = 0.02
    ) -> Bool {
        guard lhs.width.isFinite,
              lhs.height.isFinite,
              rhs.width.isFinite,
              rhs.height.isFinite,
              lhs.width > 0,
              lhs.height > 0,
              rhs.width > 0,
              rhs.height > 0
        else {
            return false
        }
        let lhsRatio = lhs.width / lhs.height
        let rhsRatio = rhs.width / rhs.height
        return abs(lhsRatio / rhsRatio - 1) <= tolerance
    }

    static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
    }

    static func isFinite(_ transform: CGAffineTransform) -> Bool {
        transform.a.isFinite
            && transform.b.isFinite
            && transform.c.isFinite
            && transform.d.isFinite
            && transform.tx.isFinite
            && transform.ty.isFinite
    }

    static func normalizedRotation(_ rotation: Int) -> Int {
        let value = rotation % 360
        return value >= 0 ? value : value + 360
    }

    static func geometryKey(_ rect: CGRect) -> String {
        [rect.minX, rect.minY, rect.width, rect.height]
            .map { String(Int(($0 * 100).rounded())) }
            .joined(separator: ",")
    }

    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
