import AppKit
import CoreText
import Foundation
import PDFKit

/// Produces a translated copy by layering printable annotations over the
/// original text. The source bytes are never modified or overwritten.
struct PDFDocumentCompositionService: Sendable {
    private let minimumFontSize: CGFloat
    private let maskColor: PDFTextColor

    init(
        minimumFontSize: CGFloat = 5,
        maskColor: PDFTextColor = .white
    ) {
        _ = AppFontRegistry.registerBundledFonts()
        self.minimumFontSize = max(5, minimumFontSize)
        self.maskColor = maskColor
    }

    /// Performs every source/layout safety check that does not require translated
    /// text. Call this before invoking a paid or remote translation engine.
    func validateReadiness(
        analysis: PDFDocumentAnalysis,
        policy: PDFDocumentCompositionPolicy = .strict
    ) throws {
        guard let document = PDFDocument(data: analysis.sourceData) else {
            throw PDFDocumentServiceError.invalidPDF
        }
        guard !document.isLocked else {
            throw PDFDocumentServiceError.lockedDocument
        }
        guard document.allowsDocumentChanges, document.allowsCommenting else {
            throw PDFDocumentServiceError.changeDisallowed
        }
        try validateReadiness(analysis, against: document, policy: policy)
    }

    func compose(
        analysis: PDFDocumentAnalysis,
        translations: [String: String],
        destinationURL: URL,
        policy: PDFDocumentCompositionPolicy = .strict,
        renderMode: PDFTranslationRenderMode = .preserveOriginalWithLayer,
        allowMissingTranslations: Bool = false
    ) throws -> PDFCompositionResult {
        guard destinationURL.isFileURL,
              destinationURL.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
        else {
            throw PDFDocumentServiceError.invalidFileType
        }
        guard !Self.urlsReferToSameFile(analysis.sourceURL, destinationURL) else {
            throw PDFDocumentServiceError.sourceAndDestinationMatch
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw PDFDocumentServiceError.destinationAlreadyExists
        }
        guard var document = PDFDocument(data: analysis.sourceData) else {
            throw PDFDocumentServiceError.invalidPDF
        }
        guard !document.isLocked else {
            throw PDFDocumentServiceError.lockedDocument
        }
        guard document.allowsDocumentChanges, document.allowsCommenting else {
            throw PDFDocumentServiceError.changeDisallowed
        }

        try validateReadiness(analysis, against: document, policy: policy)
        let originalAnnotations = Self.annotationFingerprints(in: document)
        let carrierPageIndices = try makeQuarterTurnCarrierPages(
            in: document,
            analysis: analysis
        )
        var expectedOverlays: [OverlayExpectation] = []
        var directOverlaysByPage: [Int: [PreparedOverlay]] = [:]
        var warnings: [PDFDocumentWarning] = []
        var translatedLineCount = 0

        for pageAnalysis in analysis.pages {
            try Task.checkCancellation()
            guard let page = document.page(at: pageAnalysis.pageIndex) else {
                throw PDFDocumentServiceError.invalidAnalysis(
                    "\(pageAnalysis.pageIndex + 1)페이지가 원본 데이터에 없습니다."
                )
            }

            let resolved = try resolvedTranslations(
                for: pageAnalysis,
                translations: translations,
                warnings: &warnings,
                allowMissingTranslations: allowMissingTranslations
            )
            var preparedOverlays: [PreparedOverlay] = []
            preparedOverlays.reserveCapacity(pageAnalysis.lines.count)
            for line in pageAnalysis.lines {
                try Task.checkCancellation()
                if policy == .bestEffort,
                   let reason = Self.backgroundSkipReason(
                       for: line.id,
                       warnings: pageAnalysis.warnings
                   ) {
                    warnings.append(
                        .bestEffortLineSkipped(
                            pageIndex: pageAnalysis.pageIndex,
                            lineID: line.id,
                            reason: reason
                        )
                    )
                    continue
                }
                guard let translatedText = resolved[line.id] else {
                    throw PDFDocumentServiceError.missingTranslation(
                        pageIndex: pageAnalysis.pageIndex,
                        lineID: line.id
                    )
                }
                // In the explicit continue-on-error path, an untranslated line
                // must remain visible as source content. Do not paint a white
                // mask with an empty translation over it.
                if allowMissingTranslations,
                   !hasTranslation(
                       for: line.id,
                       in: pageAnalysis,
                       translations: translations
                   ) {
                    continue
                }

                let textBounds = Self.overlayBounds(
                    for: line.bounds,
                    constrainedTo: pageAnalysis.cropBox
                )
                let maskBounds = line.sourceMaskBounds
                    .intersection(pageAnalysis.cropBox)
                guard !maskBounds.isNull,
                      maskBounds.width > 0,
                      maskBounds.height > 0
                else {
                    if policy == .bestEffort {
                        warnings.append(
                            .bestEffortLineSkipped(
                                pageIndex: pageAnalysis.pageIndex,
                                lineID: line.id,
                                reason: "원문 마스크 위치가 올바르지 않아"
                            )
                        )
                        continue
                    }
                    throw PDFDocumentServiceError.invalidAnalysis(
                        "\(pageAnalysis.pageIndex + 1)페이지 문장의 원문 마스크 영역이 올바르지 않습니다: \(line.id)"
                    )
                }
                let interactionBounds = textBounds.union(maskBounds)
                if policy == .bestEffort,
                   let annotationType = Self.overlappingNonLinkAnnotation(
                       on: page,
                       bounds: interactionBounds
                   ) {
                    warnings.append(
                        .bestEffortLineSkipped(
                            pageIndex: pageAnalysis.pageIndex,
                            lineID: line.id,
                            reason: "기존 \(annotationType) 주석과 겹쳐"
                        )
                    )
                    continue
                }
                let normalizedTranslation = Self.normalizedLineText(translatedText)
                let preservedLinkURL: URL?
                switch Self.overlappingLink(
                    on: page,
                    bounds: interactionBounds
                ) {
                case .none:
                    preservedLinkURL = nil
                case let .url(url):
                    preservedLinkURL = url
                case .unsupported:
                    if policy == .bestEffort {
                        warnings.append(
                            .bestEffortLineSkipped(
                                pageIndex: pageAnalysis.pageIndex,
                                lineID: line.id,
                                reason: "보존할 수 없는 링크와 겹쳐"
                            )
                        )
                        continue
                    }
                    throw PDFDocumentServiceError.unsupportedOverlappingLink(
                        pageIndex: pageAnalysis.pageIndex,
                        lineID: line.id
                    )
                }

                // A deliberately empty chunk can occur only when a short block
                // translation is reflowed over more source lines. The mask is
                // still required to remove the corresponding source line.
                let mask = makeMaskAnnotation(
                    bounds: maskBounds,
                    line: line,
                    linkURL: preservedLinkURL
                )

                var expectedFontSize: CGFloat?
                var textAnnotation: PDFAnnotation?
                var renderedTextBounds = textBounds
                if !normalizedTranslation.isEmpty {
                    renderedTextBounds = Self.renderingTextBounds(
                        for: normalizedTranslation,
                        base: textBounds,
                        line: line,
                        cropBox: pageAnalysis.cropBox
                    )
                    let fontResult = fittedFont(
                        for: normalizedTranslation,
                        line: line,
                        annotationBounds: renderedTextBounds
                    )
                    let font: NSFont
                    switch fontResult {
                    case let .fit(fittedFont):
                        font = fittedFont
                    case .unsupportedCharacters:
                        if policy == .bestEffort {
                            warnings.append(
                                .bestEffortLineSkipped(
                                    pageIndex: pageAnalysis.pageIndex,
                                    lineID: line.id,
                                    reason: "번역문 글자를 표시할 글꼴이 없어"
                                )
                            )
                            continue
                        }
                        throw PDFDocumentServiceError.unsupportedTranslationCharacters(
                            pageIndex: pageAnalysis.pageIndex,
                            lineID: line.id
                        )
                    case .doesNotFit:
                        if policy == .bestEffort,
                           let fallbackFont = translationFont(
                               for: normalizedTranslation,
                               sourceFontName: line.fontName,
                               size: max(minimumFontSize, 5)
                           ) {
                            // The explicit ignore path must still emit a
                            // translation for narrow fragments such as
                            // “Cloud?” or “process.”. The fallback may clip a
                            // few glyphs, but retaining translated content is
                            // preferable to leaving an English source line
                            // visible; the surrounding mask/layout remains
                            // unchanged and the caller can review the result.
                            font = fallbackFont
                        } else if policy == .bestEffort {
                            warnings.append(
                                .bestEffortLineSkipped(
                                    pageIndex: pageAnalysis.pageIndex,
                                    lineID: line.id,
                                    reason: "번역문을 표시할 글꼴을 찾지 못해"
                                )
                            )
                            continue
                        } else {
                            throw PDFDocumentServiceError.textDoesNotFit(
                                pageIndex: pageAnalysis.pageIndex,
                                lineID: line.id,
                                minimumFontSize: minimumFontSize
                            )
                        }
                    }
                    expectedFontSize = font.pointSize
                    textAnnotation = makeTextAnnotation(
                        text: normalizedTranslation,
                        bounds: renderedTextBounds,
                        font: font,
                        line: line,
                        linkURL: preservedLinkURL
                    )
                }
                let expectation = OverlayExpectation(
                        pageIndex: pageAnalysis.pageIndex,
                        lineID: line.id,
                        maskBounds: maskBounds,
                        textBounds: renderedTextBounds,
                        maskInteriorColor: Self.isValidColor(
                            line.backgroundColor
                        ) ? line.backgroundColor : maskColor,
                        text: normalizedTranslation,
                        expectsTextAnnotation: !normalizedTranslation.isEmpty,
                        textColor: normalizedTranslation.isEmpty
                            ? nil
                            : line.textColor,
                        alignment: normalizedTranslation.isEmpty
                            ? nil
                            : line.alignment,
                        fontSize: expectedFontSize,
                        shouldDisplay: true,
                        shouldPrint: true,
                        requiresBakedAppearance: carrierPageIndices[
                            pageAnalysis.pageIndex
                        ] != nil,
                        linkURL: preservedLinkURL?.absoluteString,
                        renderedAsAnnotation: !Self.shouldRenderInContent(
                            renderMode: renderMode,
                            page: pageAnalysis,
                            line: line
                        )
                    )
                let rendersInContent = !expectation.renderedAsAnnotation
                preparedOverlays.append(
                    PreparedOverlay(
                        maskAnnotation: mask,
                        textAnnotation: textAnnotation,
                        expectation: expectation,
                        font: textAnnotation?.font,
                        rendersInContent: rendersInContent
                    )
                )
            }

            // PDF annotation order is visual z-order. Add every source mask
            // before any translated text so a later overlapping mask cannot
            // cover a translation that was already placed.
            for overlay in preparedOverlays {
                try Task.checkCancellation()
                if overlay.rendersInContent {
                    directOverlaysByPage[pageAnalysis.pageIndex, default: []]
                        .append(overlay)
                } else {
                    page.addAnnotation(overlay.maskAnnotation)
                }
            }
            let textPage: PDFPage
            if let carrierPageIndex = carrierPageIndices[
                pageAnalysis.pageIndex
            ], let carrierPage = document.page(at: carrierPageIndex) {
                textPage = carrierPage
            } else {
                textPage = page
            }
            for overlay in preparedOverlays {
                try Task.checkCancellation()
                if !overlay.rendersInContent,
                   let textAnnotation = overlay.textAnnotation {
                    textPage.addAnnotation(textAnnotation)
                }
            }
            expectedOverlays.append(
                contentsOf: preparedOverlays.map(\.expectation)
            )
            translatedLineCount += preparedOverlays.count
        }

        try Task.checkCancellation()
        if !carrierPageIndices.isEmpty {
            document = try moveBakedQuarterTurnAnnotations(
                in: document,
                originalPageCount: analysis.pageCount,
                carrierPageIndices: carrierPageIndices,
                expectedOverlays: expectedOverlays
            )
        }
        try Task.checkCancellation()
        var outputData: Data
        if directOverlaysByPage.isEmpty {
            guard let data = document.dataRepresentation() else {
                throw PDFDocumentServiceError.cannotSerializeOutput
            }
            outputData = data
        } else {
            outputData = try makeContentRecomposedData(
                document: document,
                analysis: analysis,
                directOverlaysByPage: directOverlaysByPage
            )
            guard let recomposed = PDFDocument(data: outputData) else {
                throw PDFDocumentServiceError.cannotSerializeOutput
            }
            for pageAnalysis in analysis.pages {
                guard let page = recomposed.page(at: pageAnalysis.pageIndex) else {
                    throw PDFDocumentServiceError.cannotSerializeOutput
                }
                page.setBounds(pageAnalysis.mediaBox, for: .mediaBox)
                page.setBounds(pageAnalysis.cropBox, for: .cropBox)
                page.setBounds(pageAnalysis.bleedBox, for: .bleedBox)
                page.setBounds(pageAnalysis.trimBox, for: .trimBox)
                page.setBounds(pageAnalysis.artBox, for: .artBox)
                page.rotation = pageAnalysis.rotation
            }
            try restoreAnnotations(
                from: document,
                to: recomposed,
                expectedOverlays: expectedOverlays
            )
            guard let data = recomposed.dataRepresentation() else {
                throw PDFDocumentServiceError.cannotSerializeOutput
            }
            outputData = data
        }

        let destinationDirectory = destinationURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw PDFDocumentServiceError.cannotWriteOutput(
                error.localizedDescription
            )
        }

        let temporaryURL = destinationDirectory.appendingPathComponent(
            ".kcdeepl-\(UUID().uuidString).pdf",
            isDirectory: false
        )
        var ownsTemporaryFile = false
        defer {
            if ownsTemporaryFile {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        do {
            // The destination is a fresh UUID path. `atomic` and
            // `withoutOverwriting` are mutually exclusive Data options on macOS.
            try outputData.write(to: temporaryURL, options: .withoutOverwriting)
            ownsTemporaryFile = true
        } catch {
            throw PDFDocumentServiceError.cannotWriteOutput(
                error.localizedDescription
            )
        }

        try validateOutput(
            at: temporaryURL,
            analysis: analysis,
            originalAnnotations: originalAnnotations,
            expectedOverlays: expectedOverlays
        )

        // The validated temporary file is in the destination directory, so this
        // rename is the final atomic commit. Do not reopen-and-delete by pathname
        // afterward: another process could replace that path between those steps.
        do {
            try FileManager.default.moveItem(
                at: temporaryURL,
                to: destinationURL
            )
            ownsTemporaryFile = false
        } catch {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                throw PDFDocumentServiceError.destinationAlreadyExists
            }
            throw PDFDocumentServiceError.cannotWriteOutput(
                error.localizedDescription
            )
        }

        return PDFCompositionResult(
            destinationURL: destinationURL.standardizedFileURL,
            pageCount: analysis.pageCount,
            translatedLineCount: translatedLineCount,
            warnings: warnings
        )
    }
}

private extension PDFDocumentCompositionService {
    struct AnnotationFingerprint: Hashable {
        let pageIndex: Int
        let type: String
        let geometry: String
        let contents: String
        let color: String
        let interiorColor: String
        let border: String
        let shouldDisplay: Bool
        let shouldPrint: Bool
        let hasAppearanceStream: Bool
        let font: String
        let fontColor: String
        let alignment: Int
        let widgetType: String
        let fieldName: String
        let fieldValue: String
        let linkURL: String
        let actionIdentity: String

        func settingAppearanceStream(_ value: Bool) -> Self {
            Self(
                pageIndex: pageIndex,
                type: type,
                geometry: geometry,
                contents: contents,
                color: color,
                interiorColor: interiorColor,
                border: border,
                shouldDisplay: shouldDisplay,
                shouldPrint: shouldPrint,
                hasAppearanceStream: value,
                font: font,
                fontColor: fontColor,
                alignment: alignment,
                widgetType: widgetType,
                fieldName: fieldName,
                fieldValue: fieldValue,
                linkURL: linkURL,
                actionIdentity: actionIdentity
            )
        }
    }

    struct OverlayExpectation {
        let pageIndex: Int
        let lineID: String
        let maskBounds: CGRect
        let textBounds: CGRect
        let maskInteriorColor: PDFTextColor
        let text: String
        let expectsTextAnnotation: Bool
        let textColor: PDFTextColor?
        let alignment: PDFTextAlignment?
        let fontSize: CGFloat?
        let shouldDisplay: Bool
        let shouldPrint: Bool
        let requiresBakedAppearance: Bool
        let linkURL: String?
        let renderedAsAnnotation: Bool
    }

    struct PreparedOverlay {
        let maskAnnotation: PDFAnnotation
        let textAnnotation: PDFAnnotation?
        let expectation: OverlayExpectation
        let font: NSFont?
        let rendersInContent: Bool
    }

    enum FontFitResult {
        case fit(NSFont)
        case unsupportedCharacters
        case doesNotFit
    }

    enum OverlappingLink {
        case none
        case url(URL)
        case unsupported
    }

    static func shouldRenderInContent(
        renderMode: PDFTranslationRenderMode,
        page: PDFPageAnalysis,
        line: PDFTextLine
    ) -> Bool {
        guard page.rotation == 0 else {
            // The annotation path has a dedicated, validated appearance bake
            // for quarter-turn pages. Keep that path for rotated content.
            return false
        }
        switch renderMode {
        case .replaceText:
            return true
        case .preserveOriginalWithLayer:
            return false
        case .hybrid:
            return line.extractionSource == .native
        }
    }

    func paragraphStyle(for alignment: PDFTextAlignment?) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        switch alignment ?? .left {
        case .left:
            paragraph.alignment = .left
        case .center:
            paragraph.alignment = .center
        case .right:
            paragraph.alignment = .right
        }
        return paragraph
    }

    func makeContentRecomposedData(
        document: PDFDocument,
        analysis: PDFDocumentAnalysis,
        directOverlaysByPage: [Int: [PreparedOverlay]]
    ) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(
                  consumer: consumer,
                  mediaBox: nil,
                  nil
              )
        else {
            throw PDFDocumentServiceError.cannotSerializeOutput
        }

        for pageAnalysis in analysis.pages {
            try Task.checkCancellation()
            let mediaBox = pageAnalysis.mediaBox
            context.beginPDFPage([
                kCGPDFContextMediaBox: NSValue(rect: mediaBox)
            ] as CFDictionary)
            context.saveGState()
            if let page = document.page(at: pageAnalysis.pageIndex) {
                page.draw(with: .mediaBox, to: context)
            }
            context.restoreGState()

            let overlays = directOverlaysByPage[pageAnalysis.pageIndex] ?? []
            let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            for overlay in overlays {
                try Task.checkCancellation()
                let expectation = overlay.expectation
                let maskColor = Self.platformColor(expectation.maskInteriorColor)
                maskColor.setFill()
                expectation.maskBounds.fill()

                guard !expectation.text.isEmpty,
                      let font = overlay.font else {
                    continue
                }
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: Self.platformColor(
                        expectation.textColor ?? .black
                    ),
                    .paragraphStyle: paragraphStyle(for: expectation.alignment)
                ]
                let attributedText = NSAttributedString(
                    string: expectation.text,
                    attributes: attributes
                )
                attributedText.draw(
                    with: expectation.textBounds,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    func restoreAnnotations(
        from source: PDFDocument,
        to destination: PDFDocument,
        expectedOverlays: [OverlayExpectation]
    ) throws {
        for pageIndex in 0..<min(source.pageCount, destination.pageCount) {
            try Task.checkCancellation()
            guard let sourcePage = source.page(at: pageIndex),
                  let destinationPage = destination.page(at: pageIndex)
            else {
                continue
            }
            let expected = Set(
                expectedOverlays
                    .filter { $0.pageIndex == pageIndex && $0.renderedAsAnnotation }
                    .map(\.lineID)
            )
            for annotation in sourcePage.annotations {
                let name = annotation.userName ?? ""
                let isTranslationAnnotation = name.hasPrefix("KCDeepL Translation:")
                    || name.hasPrefix("KCDeepL Mask:")
                if isTranslationAnnotation {
                    let identifier = name.split(separator: ":", maxSplits: 1)
                        .dropFirst().first.map(String.init) ?? ""
                    guard expected.contains(identifier) else {
                        continue
                    }
                }
                guard let copy = annotation.copy() as? PDFAnnotation else {
                    continue
                }
                destinationPage.addAnnotation(copy)
            }
        }
    }

    func makeQuarterTurnCarrierPages(
        in document: PDFDocument,
        analysis: PDFDocumentAnalysis
    ) throws -> [Int: Int] {
        var result: [Int: Int] = [:]
        for page in analysis.pages
        where !page.lines.isEmpty
            && (page.rotation == 90 || page.rotation == 270) {
            try Task.checkCancellation()
            let carrier = PDFPage()
            carrier.setBounds(page.mediaBox, for: .mediaBox)
            carrier.setBounds(page.cropBox, for: .cropBox)
            carrier.setBounds(page.bleedBox, for: .bleedBox)
            carrier.setBounds(page.trimBox, for: .trimBox)
            carrier.setBounds(page.artBox, for: .artBox)
            carrier.rotation = 0
            let carrierPageIndex = document.pageCount
            document.insert(carrier, at: carrierPageIndex)
            result[page.pageIndex] = carrierPageIndex
        }
        return result
    }

    /// Bakes each quarter-turn FreeText appearance on a temporary unrotated
    /// page, then moves the exact reopened annotation object within the same
    /// document. Copying or detaching it through another PDFDocument can leave
    /// dangling appearance resources and must never replace this sequence.
    func moveBakedQuarterTurnAnnotations(
        in document: PDFDocument,
        originalPageCount: Int,
        carrierPageIndices: [Int: Int],
        expectedOverlays: [OverlayExpectation]
    ) throws -> PDFDocument {
        try Task.checkCancellation()
        guard let stagedData = document.dataRepresentation(),
              let reopened = PDFDocument(data: stagedData),
              reopened.pageCount == originalPageCount + carrierPageIndices.count
        else {
            throw PDFDocumentServiceError.outputValidationFailed(
                "회전 페이지 번역문의 appearance를 준비하지 못했습니다."
            )
        }

        for (targetPageIndex, carrierPageIndex) in carrierPageIndices.sorted(
            by: { $0.key < $1.key }
        ) {
            try Task.checkCancellation()
            guard let targetPage = reopened.page(at: targetPageIndex),
                  let carrierPage = reopened.page(at: carrierPageIndex)
            else {
                throw PDFDocumentServiceError.outputValidationFailed(
                    "회전 페이지의 임시 appearance 페이지를 찾지 못했습니다."
                )
            }

            let expectations = expectedOverlays.filter {
                $0.pageIndex == targetPageIndex && $0.expectsTextAnnotation
            }
            for expectation in expectations {
                try Task.checkCancellation()
                let annotationName = "KCDeepL Translation:\(expectation.lineID)"
                guard let annotation = carrierPage.annotations.first(where: {
                    $0.userName == annotationName
                        && $0.contents == expectation.text
                        && Self.annotationSubtype($0) == "FreeText"
                }), annotation.hasAppearanceStream
                else {
                    throw PDFDocumentServiceError.outputValidationFailed(
                        "회전 번역문 appearance를 안전하게 생성하지 못했습니다: \(expectation.lineID)"
                    )
                }
                if let mismatch = Self.translationAnnotationMismatch(
                    annotation,
                    expectation: expectation
                ) {
                    throw PDFDocumentServiceError.outputValidationFailed(
                        "회전 번역문 appearance의 \(mismatch)이(가) 변경되었습니다: \(expectation.lineID)"
                    )
                }

                // Keep this exact object in the reopened document. All visual,
                // action and flag properties were finalized before the bake;
                // mutating them after this move would invalidate the AP.
                carrierPage.removeAnnotation(annotation)
                targetPage.addAnnotation(annotation)
                guard annotation.hasAppearanceStream else {
                    throw PDFDocumentServiceError.outputValidationFailed(
                        "회전 번역문 appearance를 대상 페이지로 옮기지 못했습니다: \(expectation.lineID)"
                    )
                }
                if let mismatch = Self.translationAnnotationMismatch(
                    annotation,
                    expectation: expectation
                ) {
                    throw PDFDocumentServiceError.outputValidationFailed(
                        "대상 페이지 회전 번역문의 \(mismatch)이(가) 변경되었습니다: \(expectation.lineID)"
                    )
                }
            }

            guard !carrierPage.annotations.contains(where: {
                ($0.userName ?? "").hasPrefix("KCDeepL Translation:")
            }) else {
                throw PDFDocumentServiceError.outputValidationFailed(
                    "회전 번역문의 임시 appearance가 완전히 이동되지 않았습니다."
                )
            }
        }

        for carrierPageIndex in carrierPageIndices.values.sorted(by: >) {
            try Task.checkCancellation()
            reopened.removePage(at: carrierPageIndex)
        }
        guard reopened.pageCount == originalPageCount else {
            throw PDFDocumentServiceError.outputValidationFailed(
                "회전 번역문 준비 후 페이지 수가 변경되었습니다."
            )
        }
        return reopened
    }

    func validateReadiness(
        _ analysis: PDFDocumentAnalysis,
        against document: PDFDocument,
        policy: PDFDocumentCompositionPolicy = .strict
    ) throws {
        for pageAnalysis in analysis.pages {
            try Task.checkCancellation()
            guard let page = document.page(at: pageAnalysis.pageIndex) else {
                throw PDFDocumentServiceError.invalidAnalysis(
                    "\(pageAnalysis.pageIndex + 1)페이지가 원본 데이터에 없습니다."
                )
            }
            let sourceRotation = try PDFPageMetadataSafety.effectiveRotation(
                of: page,
                pageIndex: pageAnalysis.pageIndex
            )
            if ![0, 90, 180, 270].contains(sourceRotation) {
                throw PDFDocumentServiceError.unsupportedPageRotation(
                    pageIndex: pageAnalysis.pageIndex,
                    rotation: sourceRotation
                )
            }
            if !Self.hasSupportedMediaBoxOrigin(pageAnalysis.mediaBox) {
                throw PDFDocumentServiceError
                    .nonzeroMediaBoxOriginUnsupported(
                        pageIndex: pageAnalysis.pageIndex,
                        minX: pageAnalysis.mediaBox.minX,
                        minY: pageAnalysis.mediaBox.minY
                    )
            }
            if policy == .strict {
                for line in pageAnalysis.lines {
                    try Task.checkCancellation()
                    let overlayBounds = Self.overlayBounds(
                        for: line.bounds,
                        constrainedTo: pageAnalysis.cropBox
                    )
                    if let annotationType = Self.overlappingNonLinkAnnotation(
                        on: page,
                        bounds: overlayBounds
                    ) {
                        throw PDFDocumentServiceError
                            .unsupportedOverlappingAnnotation(
                                pageIndex: pageAnalysis.pageIndex,
                                lineID: line.id,
                                annotationType: annotationType
                            )
                    }
                    if case .unsupported = Self.overlappingLink(
                        on: page,
                        bounds: overlayBounds
                    ) {
                        throw PDFDocumentServiceError.unsupportedOverlappingLink(
                            pageIndex: pageAnalysis.pageIndex,
                            lineID: line.id
                        )
                    }
                }
            }
        }
        try validateAnalysis(analysis, against: document)
        if policy == .strict {
            try validateMaskBackgrounds(in: analysis)
        }
    }

    static func backgroundSkipReason(
        for lineID: String,
        warnings: [PDFDocumentWarning]
    ) -> String? {
        for warning in warnings {
            switch warning {
            case let .complexBackground(_, warningLineID)
                where warningLineID == lineID:
                return "복잡한 배경을 안전하게 가릴 수 없어"
            case let .backgroundSamplingUnavailable(_, warningLineID)
                where warningLineID == lineID:
                return "배경색을 안전하게 확인할 수 없어"
            default:
                continue
            }
        }
        return nil
    }

    func validateMaskBackgrounds(in analysis: PDFDocumentAnalysis) throws {
        for page in analysis.pages {
            try Task.checkCancellation()
            for warning in page.warnings {
                switch warning {
                case let .complexBackground(pageIndex, lineID),
                     let .backgroundSamplingUnavailable(pageIndex, lineID):
                    throw PDFDocumentServiceError.backgroundCannotBePreserved(
                        pageIndex: pageIndex,
                        lineID: lineID
                    )
                default:
                    continue
                }
            }
        }
    }

    func validateAnalysis(
        _ analysis: PDFDocumentAnalysis,
        against document: PDFDocument
    ) throws {
        guard analysis.pageCount == document.pageCount,
              analysis.pages.count == analysis.pageCount
        else {
            throw PDFDocumentServiceError.invalidAnalysis(
                "분석 시점과 합성 시점의 페이지 수가 다릅니다."
            )
        }

        var lineIDs = Set<String>()
        var blockIDs = Set<String>()
        for (expectedIndex, pageAnalysis) in analysis.pages.enumerated() {
            try Task.checkCancellation()
            guard pageAnalysis.pageIndex == expectedIndex,
                  let page = document.page(at: expectedIndex)
            else {
                throw PDFDocumentServiceError.invalidAnalysis(
                    "페이지 순서가 연속적이지 않습니다."
                )
            }
            let sourceRotation = try PDFPageMetadataSafety.effectiveRotation(
                of: page,
                pageIndex: expectedIndex
            )
            guard Self.rectanglesMatch(
                pageAnalysis.mediaBox,
                page.bounds(for: .mediaBox)
            ), Self.rectanglesMatch(
                pageAnalysis.cropBox,
                page.bounds(for: .cropBox)
            ), Self.rectanglesMatch(
                pageAnalysis.bleedBox,
                page.bounds(for: .bleedBox)
            ), Self.rectanglesMatch(
                pageAnalysis.trimBox,
                page.bounds(for: .trimBox)
            ), Self.rectanglesMatch(
                pageAnalysis.artBox,
                page.bounds(for: .artBox)
            ), pageAnalysis.rotation == sourceRotation
            else {
                throw PDFDocumentServiceError.invalidAnalysis(
                    "\(expectedIndex + 1)페이지의 크기 또는 회전 정보가 원본과 다릅니다."
                )
            }

            for line in pageAnalysis.lines {
                try Task.checkCancellation()
                guard lineIDs.insert(line.id).inserted else {
                    throw PDFDocumentServiceError.invalidAnalysis(
                        "중복 문장 ID가 있습니다: \(line.id)"
                    )
                }
                guard pageAnalysis.cropBox.intersects(line.bounds),
                      line.bounds.width > 0,
                      line.bounds.height > 0
                else {
                    throw PDFDocumentServiceError.invalidAnalysis(
                        "문장 \(line.id)의 위치가 페이지 밖에 있습니다."
                    )
                }
            }
            let lineIDSet = Set(pageAnalysis.lines.map(\.id))
            for block in pageAnalysis.blocks {
                try Task.checkCancellation()
                guard blockIDs.insert(block.id).inserted,
                      !block.lineIDs.isEmpty,
                      Set(block.lineIDs).isSubset(of: lineIDSet)
                else {
                    throw PDFDocumentServiceError.invalidAnalysis(
                        "문단 \(block.id)의 문장 참조가 올바르지 않습니다."
                    )
                }
            }
        }
    }

    func resolvedTranslations(
        for page: PDFPageAnalysis,
        translations: [String: String],
        warnings: inout [PDFDocumentWarning],
        allowMissingTranslations: Bool = false
    ) throws -> [String: String] {
        var resolved: [String: String] = [:]
        let linesByID = Dictionary(uniqueKeysWithValues: page.lines.map { ($0.id, $0) })

        for line in page.lines {
            try Task.checkCancellation()
            guard let direct = translations[line.id] else { continue }
            guard !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PDFDocumentServiceError.emptyTranslation(
                    pageIndex: page.pageIndex,
                    lineID: line.id
                )
            }
            resolved[line.id] = direct
        }

        for block in page.blocks where block.lineIDs.contains(where: { resolved[$0] == nil }) {
            try Task.checkCancellation()
            let directlyTranslatedCount = block.lineIDs.reduce(into: 0) {
                if resolved[$1] != nil { $0 += 1 }
            }
            guard directlyTranslatedCount == 0,
                  let blockTranslation = translations[block.id]
            else {
                continue
            }
            guard !blockTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PDFDocumentServiceError.emptyTranslation(
                    pageIndex: page.pageIndex,
                    lineID: block.id
                )
            }

            let blockLines = block.lineIDs.compactMap { linesByID[$0] }
            let chunks = try reflow(blockTranslation, across: blockLines)
            for (line, chunk) in zip(blockLines, chunks) {
                try Task.checkCancellation()
                resolved[line.id] = chunk
            }
            warnings.append(.blockTranslationReflowed(blockID: block.id))
        }

        for line in page.lines where resolved[line.id] == nil {
            try Task.checkCancellation()
            if allowMissingTranslations {
                resolved[line.id] = ""
                warnings.append(
                    .bestEffortLineSkipped(
                        pageIndex: page.pageIndex,
                        lineID: line.id,
                        reason: "아직 번역되지 않아"
                    )
                )
                continue
            }
            throw PDFDocumentServiceError.missingTranslation(
                pageIndex: page.pageIndex,
                lineID: line.id
            )
        }
        return resolved
    }

    func hasTranslation(
        for lineID: String,
        in page: PDFPageAnalysis,
        translations: [String: String]
    ) -> Bool {
        if translations[lineID] != nil {
            return true
        }
        return page.blocks.contains { block in
            block.lineIDs.contains(lineID) && translations[block.id] != nil
        }
    }

    func reflow(
        _ text: String,
        across lines: [PDFTextLine]
    ) throws -> [String] {
        guard lines.count > 1 else { return [text] }

        let explicitLines = text.components(separatedBy: .newlines)
            .map(Self.normalizedLineText)
        if explicitLines.count == lines.count {
            return explicitLines
        }

        var remaining = Array(Self.normalizedLineText(text))
        var chunks: [String] = []
        var remainingWidth = lines.reduce(CGFloat.zero) {
            $0 + max(1, $1.bounds.width)
        }

        for (index, line) in lines.enumerated() {
            try Task.checkCancellation()
            guard index < lines.count - 1, !remaining.isEmpty else {
                chunks.append(String(remaining).trimmingCharacters(in: .whitespaces))
                remaining.removeAll()
                continue
            }

            let lineWidth = max(1, line.bounds.width)
            let proportionalCount = max(
                1,
                Int((CGFloat(remaining.count) * lineWidth / remainingWidth).rounded())
            )
            let reservedCharacters = max(0, lines.count - index - 1)
            let upperBound = max(1, remaining.count - reservedCharacters)
            var splitIndex = min(proportionalCount, upperBound)

            if splitIndex < remaining.count {
                let searchLowerBound = max(1, splitIndex / 2)
                if let whitespaceIndex = stride(
                    from: splitIndex,
                    through: searchLowerBound,
                    by: -1
                ).first(where: { remaining[$0 - 1].isWhitespace }) {
                    splitIndex = whitespaceIndex
                }
            }

            let chunk = String(remaining.prefix(splitIndex))
                .trimmingCharacters(in: .whitespaces)
            chunks.append(chunk)
            remaining.removeFirst(splitIndex)
            while remaining.first?.isWhitespace == true {
                remaining.removeFirst()
            }
            remainingWidth -= lineWidth
        }

        while chunks.count < lines.count {
            chunks.append("")
        }
        return chunks
    }

    func fittedFont(
        for text: String,
        line: PDFTextLine,
        annotationBounds: CGRect
    ) -> FontFitResult {
        let availableBounds = annotationBounds.insetBy(dx: 1.5, dy: 0.75)
        guard availableBounds.width > 0, availableBounds.height > 0 else {
            return .doesNotFit
        }

        // PDFKit rounds FreeText default-appearance sizes to whole points when
        // serializing. Fit with that same granularity so the reopened output
        // cannot become larger than the size that was measured here.
        let minimumSerializableSize = ceil(minimumFontSize)
        let maximumSize = max(
            minimumSerializableSize,
            floor(min(line.fontSize, 144))
        )
        var size = maximumSize
        var foundSupportedFont = false
        while size >= minimumFontSize {
            guard let font = translationFont(
                for: text,
                sourceFontName: line.fontName,
                size: size
            ) else {
                size -= 1
                continue
            }
            foundSupportedFont = true
            // FreeText annotations wrap at their actual bounds. Measure with
            // that same width instead of an unlimited single-line width;
            // otherwise a long Korean chunk appears to fit here but PDFKit
            // wraps it into the next line at render time and overlaps the
            // neighboring source-line overlays.
            let measured = (text as NSString).boundingRect(
                with: CGSize(
                    width: availableBounds.width,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesFontLeading, .usesLineFragmentOrigin],
                attributes: [.font: font]
            ).integral.size
            if measured.width <= availableBounds.width + 0.5,
               measured.height <= availableBounds.height + 0.5 {
                return .fit(font)
            }
            size -= 1
        }
        return foundSupportedFont ? .doesNotFit : .unsupportedCharacters
    }

    func translationFont(
        for text: String,
        sourceFontName: String,
        size: CGFloat
    ) -> NSFont? {
        let publicSourceFont = sourceFontName.hasPrefix(".")
            ? nil
            : NSFont(name: sourceFontName, size: size)
        let sourceFont = publicSourceFont
            ?? NSFont.systemFont(ofSize: size)
        let traits = NSFontManager.shared.traits(of: sourceFont)
        let isBold = traits.contains(.boldFontMask)
        let isMonospaced = traits.contains(.fixedPitchFontMask)
        var candidates: [NSFont] = []

        // A public source font that contains every translated glyph gives the
        // closest line metrics and therefore the best layout preservation.
        // Private dot-prefixed system names are never serialization candidates.
        if let publicSourceFont,
           !publicSourceFont.fontName.hasPrefix("."),
           Self.font(publicSourceFont, supports: text) {
            candidates.append(publicSourceFont)
        }

        candidates.append(contentsOf: AppFont.preferredPostScriptNames(
            for: text,
            isBold: isBold,
            monospaced: isMonospaced
        ).compactMap {
            NSFont(name: $0, size: size)
        })
        // PDFKit can serialize a system fallback with a private dot-prefixed
        // PostScript name (for example, `.AppleSDGothicNeoI-Regular`). On
        // reopen that name is not constructible and PDFKit substitutes Times,
        // which drops CJK glyphs. Only public, serialization-stable fonts are
        // allowed after the bundled/script-specific candidates.
        let stableFallbackNames = isBold
            ? [
                "AppleSDGothicNeo-SemiBold",
                "HiraginoSans-W6",
                "PingFangSC-Semibold",
                "PingFangTC-Semibold",
                "Helvetica-Bold"
            ]
            : [
                "AppleSDGothicNeo-Regular",
                "HiraginoSans-W3",
                "PingFangSC-Regular",
                "PingFangTC-Regular",
                "Helvetica"
            ]
        candidates.append(
            contentsOf: stableFallbackNames.compactMap {
                NSFont(name: $0, size: size)
            }
        )

        var seenNames = Set<String>()
        for candidate in candidates
        where !candidate.fontName.hasPrefix(".")
            && seenNames.insert(candidate.fontName).inserted {
            if Self.font(candidate, supports: text) {
                return candidate
            }
        }
        return nil
    }

    func makeMaskAnnotation(
        bounds: CGRect,
        line: PDFTextLine,
        linkURL: URL?
    ) -> PDFAnnotation {
        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .square,
            withProperties: nil
        )
        let backgroundColor = Self.isValidColor(line.backgroundColor)
            ? line.backgroundColor
            : maskColor
        let color = Self.platformColor(backgroundColor)
        annotation.color = color
        annotation.interiorColor = color
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        annotation.userName = "KCDeepL Mask:\(line.id)"
        if let linkURL {
            annotation.action = PDFActionURL(url: linkURL)
        }
        return annotation
    }

    func makeTextAnnotation(
        text: String,
        bounds: CGRect,
        font: NSFont,
        line: PDFTextLine,
        linkURL: URL?
    ) -> PDFAnnotation {
        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = Self.platformColor(line.textColor)
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        switch line.alignment {
        case .left:
            annotation.alignment = .left
        case .center:
            annotation.alignment = .center
        case .right:
            annotation.alignment = .right
        }
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        annotation.userName = "KCDeepL Translation:\(line.id)"
        if let linkURL {
            annotation.action = PDFActionURL(url: linkURL)
        }
        return annotation
    }

    func validateOutput(
        at url: URL,
        analysis: PDFDocumentAnalysis,
        originalAnnotations: [AnnotationFingerprint: Int],
        expectedOverlays: [OverlayExpectation]
    ) throws {
        guard let output = PDFDocument(url: url), !output.isLocked else {
            throw PDFDocumentServiceError.outputValidationFailed(
                "저장된 파일을 다시 열 수 없습니다."
            )
        }
        guard output.pageCount == analysis.pageCount else {
            throw PDFDocumentServiceError.outputValidationFailed(
                "페이지 수가 원본과 다릅니다."
            )
        }

        for pageAnalysis in analysis.pages {
            try Task.checkCancellation()
            guard let outputPage = output.page(at: pageAnalysis.pageIndex),
                  Self.rectanglesMatch(
                    outputPage.bounds(for: .mediaBox),
                    pageAnalysis.mediaBox
                  ), Self.rectanglesMatch(
                    outputPage.bounds(for: .cropBox),
                    pageAnalysis.cropBox
                  ), Self.rectanglesMatch(
                    outputPage.bounds(for: .bleedBox),
                    pageAnalysis.bleedBox
                  ), Self.rectanglesMatch(
                    outputPage.bounds(for: .trimBox),
                    pageAnalysis.trimBox
                  ), Self.rectanglesMatch(
                    outputPage.bounds(for: .artBox),
                    pageAnalysis.artBox
                  ), Self.normalizedRotation(outputPage.rotation) == pageAnalysis.rotation
            else {
                throw PDFDocumentServiceError.outputValidationFailed(
                    "\(pageAnalysis.pageIndex + 1)페이지의 크기 또는 회전값이 변경되었습니다."
                )
            }
        }

        let outputFingerprints = Self.annotationFingerprints(in: output)
        let originalAnnotationIdentities = Set(
            originalAnnotations.keys.map {
                $0.settingAppearanceStream(false)
            }
        )
        for identity in originalAnnotationIdentities {
            let withAppearance = identity.settingAppearanceStream(true)
            let originalWithoutAppearance = originalAnnotations[identity, default: 0]
            let originalWithAppearance = originalAnnotations[
                withAppearance,
                default: 0
            ]
            let outputWithoutAppearance = outputFingerprints[identity, default: 0]
            let outputWithAppearance = outputFingerprints[
                withAppearance,
                default: 0
            ]
            guard outputWithoutAppearance + outputWithAppearance
                    >= originalWithoutAppearance + originalWithAppearance,
                  outputWithAppearance >= originalWithAppearance
            else {
                throw PDFDocumentServiceError.outputValidationFailed(
                    "기존 주석, appearance stream 또는 양식 필드가 보존되지 않았습니다."
                )
            }
        }

        for expectation in expectedOverlays {
            try Task.checkCancellation()
            if !expectation.renderedAsAnnotation {
                continue
            }
            guard let page = output.page(at: expectation.pageIndex) else {
                throw PDFDocumentServiceError.outputValidationFailed(
                    "번역 주석의 페이지를 확인할 수 없습니다."
                )
            }
            let maskName = "KCDeepL Mask:\(expectation.lineID)"
            guard let mask = page.annotations.first(where: {
                $0.userName == maskName
                    && Self.annotationSubtype($0) == "Square"
            }) else {
                throw PDFDocumentServiceError.outputValidationFailed(
                    "원문 마스크가 저장되지 않았습니다: \(expectation.lineID)"
                )
            }
            guard Self.rectanglesMatch(
                mask.bounds,
                expectation.maskBounds
            ),
                  Self.colorsMatch(
                    mask.interiorColor,
                    expectation.maskInteriorColor
                  ), mask.shouldDisplay == expectation.shouldDisplay,
                  mask.shouldPrint == expectation.shouldPrint
            else {
                throw PDFDocumentServiceError.outputValidationFailed(
                    "원문 마스크의 위치, 색상 또는 표시 속성이 변경되었습니다: \(expectation.lineID)"
                )
            }
            if Self.linkURLString(mask) != expectation.linkURL {
                throw PDFDocumentServiceError.outputValidationFailed(
                    "원문 링크 동작이 마스크에 보존되지 않았습니다: \(expectation.lineID)"
                )
            }
            if expectation.expectsTextAnnotation {
                let translationName = "KCDeepL Translation:\(expectation.lineID)"
                guard let translation = page.annotations.first(where: {
                    $0.userName == translationName
                        && $0.contents == expectation.text
                        && Self.annotationSubtype($0) == "FreeText"
                }) else {
                    throw PDFDocumentServiceError.outputValidationFailed(
                        "번역문 주석이 저장되지 않았습니다: \(expectation.lineID)"
                    )
                }
                if let mismatch = Self.translationAnnotationMismatch(
                    translation,
                    expectation: expectation
                ) {
                    throw PDFDocumentServiceError.outputValidationFailed(
                        "번역문 주석의 \(mismatch)이(가) 변경되었습니다: \(expectation.lineID)"
                    )
                }
                if expectation.requiresBakedAppearance,
                   !translation.hasAppearanceStream {
                    throw PDFDocumentServiceError.outputValidationFailed(
                        "회전 번역문 appearance가 저장되지 않았습니다: \(expectation.lineID)"
                    )
                }
            } else if page.annotations.contains(where: {
                $0.userName == "KCDeepL Translation:\(expectation.lineID)"
            }) {
                throw PDFDocumentServiceError.outputValidationFailed(
                    "빈 번역 영역에 예상하지 않은 번역문 주석이 있습니다: \(expectation.lineID)"
                )
            }
        }

        for pageIndex in Set(expectedOverlays.map(\.pageIndex)) {
            try Task.checkCancellation()
            guard let page = output.page(at: pageIndex) else { continue }
            let pageExpectations = expectedOverlays.filter {
                $0.pageIndex == pageIndex && $0.renderedAsAnnotation
            }
            let lineIDs = Set(pageExpectations.map(\.lineID))
            let maskIndices = page.annotations.enumerated().compactMap {
                index, annotation -> Int? in
                guard let name = annotation.userName,
                      name.hasPrefix("KCDeepL Mask:"),
                      lineIDs.contains(String(name.dropFirst("KCDeepL Mask:".count)))
                else {
                    return nil
                }
                return index
            }
            let textIndices = page.annotations.enumerated().compactMap {
                index, annotation -> Int? in
                guard let name = annotation.userName,
                      name.hasPrefix("KCDeepL Translation:"),
                      lineIDs.contains(
                        String(name.dropFirst("KCDeepL Translation:".count))
                      )
                else {
                    return nil
                }
                return index
            }
            if let lastMaskIndex = maskIndices.max(),
               let firstTextIndex = textIndices.min(),
               lastMaskIndex >= firstTextIndex {
                throw PDFDocumentServiceError.outputValidationFailed(
                    "\(pageIndex + 1)페이지에서 원문 마스크가 번역문 위에 배치되었습니다."
                )
            }
        }
    }

    static func translationAnnotationMismatch(
        _ annotation: PDFAnnotation,
        expectation: OverlayExpectation
    ) -> String? {
        guard annotation.contents == expectation.text else { return "내용" }
        guard annotationSubtype(annotation) == "FreeText" else { return "종류" }
        guard rectanglesMatch(annotation.bounds, expectation.textBounds) else {
            return "위치"
        }
        guard let expectedTextColor = expectation.textColor else {
            return "글자 색상 기대값"
        }
        guard colorsMatch(annotation.fontColor, expectedTextColor) else {
            let expected = Self.colorDescription(expectedTextColor)
            let actual = Self.colorDescription(annotation.fontColor)
            return "글자 색상(예상 \(expected), 저장 \(actual))"
        }
        guard let expectedAlignment = expectation.alignment,
              annotation.alignment == platformAlignment(expectedAlignment)
        else { return "정렬" }
        guard annotation.shouldDisplay == expectation.shouldDisplay else { return "화면 표시 속성" }
        guard annotation.shouldPrint == expectation.shouldPrint else { return "인쇄 속성" }
        guard let font = annotation.font else { return "글꼴" }
        guard Self.font(font, supports: expectation.text) else { return "글꼴 glyph" }
        guard let expectedFontSize = expectation.fontSize else {
            return "글꼴 크기 기대값"
        }
        guard abs(font.pointSize - expectedFontSize) <= 0.1 else {
            return "글꼴 크기(예상 \(expectedFontSize), 저장 \(font.pointSize))"
        }
        guard linkURLString(annotation) == expectation.linkURL else { return "링크 동작" }
        return nil
    }

    static func annotationFingerprints(
        in document: PDFDocument
    ) -> [AnnotationFingerprint: Int] {
        var result: [AnnotationFingerprint: Int] = [:]
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                let fingerprint = AnnotationFingerprint(
                    pageIndex: pageIndex,
                    type: annotation.type ?? "",
                    geometry: geometryKey(annotation.bounds),
                    contents: annotation.contents ?? "",
                    color: colorKey(annotation.color),
                    interiorColor: colorKey(annotation.interiorColor),
                    border: borderKey(annotation.border),
                    shouldDisplay: annotation.shouldDisplay,
                    shouldPrint: annotation.shouldPrint,
                    hasAppearanceStream: annotation.hasAppearanceStream,
                    font: fontKey(annotation),
                    fontColor: fontColorKey(annotation),
                    alignment: alignmentKey(annotation),
                    widgetType: annotation.widgetFieldType.rawValue,
                    fieldName: annotation.fieldName ?? "",
                    fieldValue: annotation.widgetStringValue ?? "",
                    linkURL: linkURLString(annotation) ?? "",
                    actionIdentity: actionIdentity(
                        annotation.action,
                        in: document
                    )
                )
                result[fingerprint, default: 0] += 1
            }
        }
        return result
    }

    static func overlappingNonLinkAnnotation(
        on page: PDFPage,
        bounds: CGRect
    ) -> String? {
        for annotation in page.annotations
        where !isLinkAnnotation(annotation)
            && positivelyOverlaps(bounds, annotation.bounds) {
            let subtype = annotationSubtype(annotation)
            return subtype.isEmpty ? "알 수 없는 유형" : subtype
        }
        return nil
    }

    static func overlappingLink(
        on page: PDFPage,
        bounds: CGRect
    ) -> OverlappingLink {
        let links = page.annotations.filter {
            isLinkAnnotation($0)
                && positivelyOverlaps(bounds, $0.bounds)
        }
        guard !links.isEmpty else { return .none }
        let urls = links.compactMap(linkURL)
        guard urls.count == links.count else { return .unsupported }
        let byString = Dictionary(
            urls.map { ($0.absoluteString, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard byString.count == 1, let url = byString.values.first else {
            return .unsupported
        }
        return .url(url)
    }

    static func isLinkAnnotation(_ annotation: PDFAnnotation) -> Bool {
        annotationSubtype(annotation) == "Link"
    }

    static func annotationSubtype(_ annotation: PDFAnnotation) -> String {
        annotation.type?.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        ) ?? ""
    }

    static func linkURL(_ annotation: PDFAnnotation) -> URL? {
        if let action = annotation.action as? PDFActionURL,
           let url = action.url {
            return url
        }
        return annotation.url
    }

    static func linkURLString(_ annotation: PDFAnnotation) -> String? {
        linkURL(annotation)?.absoluteString
    }

    static func actionIdentity(
        _ action: PDFAction?,
        in document: PDFDocument
    ) -> String {
        guard let action else { return "" }
        if let action = action as? PDFActionURL {
            return "\(action.type)|\(action.url?.absoluteString ?? "")"
        }
        if let action = action as? PDFActionGoTo {
            let destination = action.destination
            let pageIndex = destination.page.map {
                document.index(for: $0)
            } ?? NSNotFound
            return [
                action.type,
                String(pageIndex),
                pointKey(destination.point),
                String(format: "%.4f", destination.zoom)
            ].joined(separator: "|")
        }
        if let action = action as? PDFActionRemoteGoTo {
            return [
                action.type,
                action.url.absoluteString,
                String(action.pageIndex),
                pointKey(action.point)
            ].joined(separator: "|")
        }
        if let action = action as? PDFActionNamed {
            return "\(action.type)|\(action.name.rawValue)"
        }
        if let action = action as? PDFActionResetForm {
            return [
                action.type,
                action.fields?.sorted().joined(separator: ",") ?? "",
                String(action.fieldsIncludedAreCleared)
            ].joined(separator: "|")
        }
        return action.type
    }

    static func pointKey(_ point: CGPoint) -> String {
        [point.x, point.y]
            .map { String(Int(($0 * 100).rounded())) }
            .joined(separator: ",")
    }

    static func positivelyOverlaps(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        guard lhs.width > 0,
              lhs.height > 0,
              rhs.width > 0,
              rhs.height > 0
        else {
            return false
        }
        let intersection = lhs.intersection(rhs)
        return !intersection.isNull
            && intersection.width > 0
            && intersection.height > 0
    }

    static func overlayBounds(
        for lineBounds: CGRect,
        constrainedTo cropBox: CGRect
    ) -> CGRect {
        PDFOverlayGeometry.bounds(
            for: lineBounds,
            constrainedTo: cropBox
        )
    }

    /// PDFKit clips CJK glyphs when a one-line FreeText annotation has exactly
    /// the source glyph box as its height. FAQ-style PDFs commonly use 11–12pt
    /// lines, so the translated Korean appearance needs a little vertical
    /// breathing room even while its mask remains at the original coordinates.
    /// Larger slide typography keeps the original bounds to preserve the exact
    /// layout contract covered by the composition tests.
    static func renderingTextBounds(
        for text: String,
        base: CGRect,
        line: PDFTextLine,
        cropBox: CGRect
    ) -> CGRect {
        guard AppFont.containsHangul(in: text),
              line.fontSize <= 12.5,
              base.width > 0,
              base.height > 0
        else {
            return base
        }
        let extraVerticalPadding = min(3.5, max(2.0, base.height * 0.28))
        return base
            .insetBy(dx: 0, dy: -extraVerticalPadding)
            .intersection(cropBox)
    }

    static func normalizedLineText(_ text: String) -> String {
        // Office/PDF exports often encode a bullet as the private-use glyph
        // U+F0B7 (the legacy Symbol/Arial bullet). That code point is not
        // present in Noto Sans KR or Barlow, so PDFKit silently falls back to
        // an unsupported font and the best-effort path drops the whole line.
        // Normalize legacy bullets to the portable Unicode bullet before font
        // selection; this preserves the list marker while keeping the chosen
        // Korean/Latin font stable.
        let portableBullets = text
            .replacingOccurrences(of: "\u{F0B7}", with: "•")
            .replacingOccurrences(of: "\u{2022}\u{FE0F}", with: "•")
        return portableBullets.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func platformColor(_ color: PDFTextColor) -> NSColor {
        NSColor(
            deviceRed: min(max(color.red, 0), 1),
            green: min(max(color.green, 0), 1),
            blue: min(max(color.blue, 0), 1),
            alpha: min(max(color.alpha, 0), 1)
        )
    }

    static func colorsMatch(
        _ actual: NSColor?,
        _ expected: PDFTextColor
    ) -> Bool {
        guard isValidColor(expected),
              let sourceColor = actual
        else {
            return false
        }
        let comparisonSpace = sourceColor.colorSpace.colorSpaceModel == .rgb
            ? sourceColor.colorSpace
            : NSColorSpace.deviceRGB
        guard let actual = sourceColor.usingColorSpace(comparisonSpace),
              let expectedColor = platformColor(expected)
                .usingColorSpace(comparisonSpace)
        else {
            return false
        }
        let tolerance: CGFloat = 0.02
        return abs(actual.redComponent - expectedColor.redComponent) <= tolerance
            && abs(actual.greenComponent - expectedColor.greenComponent) <= tolerance
            && abs(actual.blueComponent - expectedColor.blueComponent) <= tolerance
            && abs(actual.alphaComponent - expectedColor.alphaComponent) <= tolerance
    }

    static func colorDescription(_ color: PDFTextColor) -> String {
        String(
            format: "%.3f/%.3f/%.3f/%.3f",
            Double(color.red),
            Double(color.green),
            Double(color.blue),
            Double(color.alpha)
        )
    }

    static func colorDescription(_ color: NSColor?) -> String {
        guard let sourceColor = color else {
            return "없음"
        }
        let color: NSColor
        if sourceColor.colorSpace.colorSpaceModel == .rgb {
            color = sourceColor
        } else if let converted = sourceColor.usingColorSpace(.deviceRGB) {
            color = converted
        } else {
            return "변환 불가"
        }
        let components = String(
            format: "%.3f/%.3f/%.3f/%.3f",
            Double(color.redComponent),
            Double(color.greenComponent),
            Double(color.blueComponent),
            Double(color.alphaComponent)
        )
        return "\(sourceColor.colorSpace.localizedName ?? "알 수 없는 색 공간") \(components)"
    }

    static func platformAlignment(
        _ alignment: PDFTextAlignment
    ) -> NSTextAlignment {
        switch alignment {
        case .left:
            return .left
        case .center:
            return .center
        case .right:
            return .right
        }
    }

    static func isValidColor(_ color: PDFTextColor) -> Bool {
        color.red.isFinite
            && color.green.isFinite
            && color.blue.isFinite
            && color.alpha.isFinite
    }

    static func colorKey(_ color: NSColor?) -> String {
        guard let color = color?.usingColorSpace(.deviceRGB) else {
            return "nil"
        }
        return [
            color.redComponent,
            color.greenComponent,
            color.blueComponent,
            color.alphaComponent
        ].map(componentKey).joined(separator: ",")
    }

    static func borderKey(_ border: PDFBorder?) -> String {
        guard let border else { return "nil" }
        return [
            componentKey(border.lineWidth),
            String(border.style.rawValue)
        ].joined(separator: "|")
    }

    static func fontKey(_ annotation: PDFAnnotation) -> String {
        guard annotationSubtype(annotation) == "FreeText" else { return "" }
        guard let font = annotation.font else { return "nil" }
        return "\(font.fontName)|\(componentKey(font.pointSize))"
    }

    static func fontColorKey(_ annotation: PDFAnnotation) -> String {
        guard annotationSubtype(annotation) == "FreeText" else { return "" }
        return colorKey(annotation.fontColor)
    }

    static func alignmentKey(_ annotation: PDFAnnotation) -> Int {
        guard annotationSubtype(annotation) == "FreeText" else { return -1 }
        return annotation.alignment.rawValue
    }

    static func componentKey(_ value: CGFloat) -> String {
        guard value.isFinite else { return "nonfinite" }
        return String(Int((value * 1_000).rounded()))
    }

    static func font(_ font: NSFont, supports text: String) -> Bool {
        let characters = Array(text.utf16)
        guard !characters.isEmpty else { return true }
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        return characters.withUnsafeBufferPointer { characterBuffer in
            glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
                guard let characterAddress = characterBuffer.baseAddress,
                      let glyphAddress = glyphBuffer.baseAddress
                else {
                    return false
                }
                return CTFontGetGlyphsForCharacters(
                    font as CTFont,
                    characterAddress,
                    glyphAddress,
                    characters.count
                )
            }
        }
    }

    static func urlsReferToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalURL(lhs) == canonicalURL(rhs)
    }

    static func canonicalURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath()
        }
        let resolvedParent = standardized.deletingLastPathComponent()
            .resolvingSymlinksInPath()
        return resolvedParent.appendingPathComponent(standardized.lastPathComponent)
    }

    static func rectanglesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 0.05
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    static func hasSupportedMediaBoxOrigin(_ mediaBox: CGRect) -> Bool {
        let tolerance: CGFloat = 0.05
        return abs(mediaBox.minX) <= tolerance
            && abs(mediaBox.minY) <= tolerance
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
}
