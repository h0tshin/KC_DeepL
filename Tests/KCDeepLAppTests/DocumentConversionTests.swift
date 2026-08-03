import AppKit
import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import KCDeepL

final class DocumentConversionTests: XCTestCase {
    func testNativeExtractorBuildsAOnePageSceneAndPPTX() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KCDeepL-ConversionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.pdf")
        try makePDF(at: source)
        let output = directory.appendingPathComponent("converted.pptx")
        let report = try PDFOfficeConversionService().convert(
            sourceURL: source,
            format: .pptx,
            destinationURL: output
        )

        XCTAssertEqual(report.pageCount, 1)
        XCTAssertTrue(report.pageRasterFallbackCount >= 1)
        XCTAssertGreaterThanOrEqual(report.textBoxCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: output).prefix(2), Data([0x50, 0x4b]))
    }

    func testNativeExtractorBuildsDOCXWithOneSection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KCDeepL-ConversionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.pdf")
        try makePDF(at: source)
        let output = directory.appendingPathComponent("converted.docx")
        let report = try PDFOfficeConversionService().convert(
            sourceURL: source,
            format: .docx,
            destinationURL: output
        )

        XCTAssertEqual(report.pageCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: output).prefix(2), Data([0x50, 0x4b]))
    }

    func testPresentationRelationshipIDsRemainUniqueForMultiplePages() throws {
        let directory = try temporaryDirectory(prefix: "KCDeepL-PresentationRelationshipTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        try makePDF(at: source)

        let extracted = try PDFSceneExtractor().extract(sourceURL: source)
        let firstPage = try XCTUnwrap(extracted.pages.first)
        let secondPage = PDFScenePage(
            id: "\(firstPage.id)-duplicate-page",
            pageIndex: 1,
            cropBox: firstPage.cropBox,
            rotation: firstPage.rotation,
            pageImagePNG: firstPage.pageImagePNG,
            textBoxes: firstPage.textBoxes,
            images: firstPage.images,
            vectors: firstPage.vectors,
            templateObjects: firstPage.templateObjects,
            imageOccurrenceCount: firstPage.imageOccurrenceCount,
            extractedImageCount: firstPage.extractedImageCount,
            nativeVectorCount: firstPage.nativeVectorCount,
            warnings: firstPage.warnings,
            usesPageRasterFallback: firstPage.usesPageRasterFallback
        )
        let scene = PDFSceneDocument(
            sourceURL: source,
            sourceSHA256: extracted.sourceSHA256,
            pages: [firstPage, secondPage],
            warnings: []
        )

        let parts = try PresentationMLWriter().makeParts(scene: scene)
        let relationshipsPart = try XCTUnwrap(
            parts.first(where: { $0.name == "ppt/_rels/presentation.xml.rels" })
        )
        let relationshipsXML = try XCTUnwrap(String(data: relationshipsPart.data, encoding: .utf8))
        let ids = relationshipsXML
            .components(separatedBy: "Id=\"")
            .dropFirst()
            .compactMap { $0.split(separator: "\"", maxSplits: 1).first.map(String.init) }

        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertTrue(relationshipsXML.contains("Id=\"rId5\""))
        XCTAssertTrue(relationshipsXML.contains("Id=\"rId6\""))

        let presentationPart = try XCTUnwrap(
            parts.first(where: { $0.name == "ppt/presentation.xml" })
        )
        let presentationXML = try XCTUnwrap(String(data: presentationPart.data, encoding: .utf8))
        XCTAssertTrue(presentationXML.contains("r:id=\"rId5\""))
        XCTAssertTrue(presentationXML.contains("r:id=\"rId6\""))
    }

    func testImageOccurrenceIsDecodedAndAddedAsOfficeMedia() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KCDeepL-ConversionImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("image-source.pdf")
        try makePDFWithImage(at: source)
        let output = directory.appendingPathComponent("image-converted.pptx")
        let report = try PDFOfficeConversionService().convert(
            sourceURL: source,
            format: .pptx,
            destinationURL: output
        )

        XCTAssertGreaterThanOrEqual(report.imageOccurrenceCount, 1)
        XCTAssertGreaterThanOrEqual(report.extractedImageCount, 1)
        XCTAssertTrue(
            (try Data(contentsOf: output)).range(
                of: Data("object-1-1.png".utf8)
            ) != nil
        )

        let scene = try PDFSceneExtractor().extract(sourceURL: source)
        let page = try XCTUnwrap(scene.pages.first)
        let transparentImage = try XCTUnwrap(
            page.images.first(where: { $0.hasAlpha || $0.maskApplied })
        )
        XCTAssertFalse(transparentImage.canOverlayOnPageSafetyNet)

        let parts = try PresentationMLWriter().makeParts(scene: scene)
        let slidePart = try XCTUnwrap(
            parts.first(where: { $0.name == "ppt/slides/slide1.xml" })
        )
        let slideXML = try XCTUnwrap(String(data: slidePart.data, encoding: .utf8))
        let imageIndex = try XCTUnwrap(page.images.firstIndex(where: {
            $0.id == transparentImage.id
        }))
        let transparentRelationshipID = "rId\(imageIndex + 3)"
        XCTAssertFalse(
            slideXML.contains("r:embed=\"\(transparentRelationshipID)\""),
            "A transparent/masked image must not blend a second time over the page safety-net."
        )
    }

    func testOpaqueImageCoveredByLaterPaintDoesNotOverlaySafetyNet() throws {
        let directory = try temporaryDirectory(prefix: "KCDeepL-OpaqueImageSafetyNetTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("opaque-image-covered.pdf")
        try makePDFWithOpaqueImageCoveredByLaterPaint(at: source)

        let scene = try PDFSceneExtractor().extract(sourceURL: source)
        let page = try XCTUnwrap(scene.pages.first)
        let opaqueImage = try XCTUnwrap(
            page.images.first(where: { !$0.hasAlpha && !$0.maskApplied })
        )

        XCTAssertFalse(
            opaqueImage.canOverlayOnPageSafetyNet,
            "An opaque PDF image covered by later paint must remain only in the authoritative page raster."
        )
        XCTAssertFalse(opaqueImage.isSafetyNetVerifiedOpaque)
    }

    func testOfficeRunResolverCanonicalizesLegacyTypefaceAndBullet() {
        let run = PDFOfficeTextAppearance.run(
            text: "\u{F0B7} FAQ",
            fontName: "ArialMT",
            fontSize: 10,
            color: .black
        )

        XCTAssertEqual(run.text, "• FAQ")
        XCTAssertNotEqual(run.fontName, "ArialMT")
        XCTAssertTrue(run.isOfficeCompatible)

        let courier = PDFOfficeTextAppearance.run(
            text: "o",
            fontName: "CourierNewPSMT",
            fontSize: 10,
            color: .black
        )
        XCTAssertEqual(courier.fontName, "Courier New")
        XCTAssertNotEqual(courier.fontName, "CourierNewPSMT")

        let branded = PDFOfficeTextAppearance.run(
            text: "Sales Talk",
            fontName: "Barlow-Regular",
            fontSize: 14,
            color: .black
        )
        XCTAssertFalse(
            branded.isOfficeCompatible,
            "An unembedded branded font must retain source paint instead of silently falling back in Office."
        )
    }

    func testSceneRasterKeepsPDFTopAndBottomOrientation() throws {
        let directory = try temporaryDirectory(prefix: "KCDeepL-OrientationTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("orientation.pdf")
        try makeOrientationPDF(at: source)

        let scene = try PDFSceneExtractor().extract(sourceURL: source)
        let page = try XCTUnwrap(scene.pages.first)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: page.pageImagePNG))
        let upper = try XCTUnwrap(bitmap.colorAt(x: 120, y: 90)?.usingColorSpace(.deviceRGB))
        let lower = try XCTUnwrap(bitmap.colorAt(x: 120, y: 510)?.usingColorSpace(.deviceRGB))

        XCTAssertGreaterThan(upper.redComponent, 0.8)
        XCTAssertLessThan(upper.blueComponent, 0.2)
        XCTAssertGreaterThan(lower.blueComponent, 0.8)
        XCTAssertLessThan(lower.redComponent, 0.2)
    }

    func testTransparentNativeTextMaskFlattensTheOfficePageCanvas() throws {
        let directory = try temporaryDirectory(prefix: "KCDeepL-TransparentMaskTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("transparent-text.pdf")
        try makeTransparentTextPDF(at: source)

        let scene = try PDFSceneExtractor().extract(sourceURL: source)
        let page = try XCTUnwrap(scene.pages.first)
        let textBox = try XCTUnwrap(
            page.textBoxes.first(where: {
                $0.visualPolicy == .replaceSourcePaint
                    && !$0.lines.isEmpty
            })
        )
        let mask = textBox.lines[0].sourceMaskBounds
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: page.pageImagePNG))
        let scale = CGFloat(bitmap.pixelsWide) / page.width
        let x = Int(((mask.midX - page.cropBox.minX) * scale).rounded())
        let y = Int(((page.cropBox.maxY - mask.midY) * scale).rounded())
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))

        XCTAssertGreaterThan(
            color.alphaComponent,
            0.99,
            "The Office page safety-net must be opaque to avoid soft-mask seams."
        )
        XCTAssertGreaterThan(color.redComponent, 0.99)
        XCTAssertGreaterThan(color.greenComponent, 0.99)
        XCTAssertGreaterThan(color.blueComponent, 0.99)
    }

    func testTextOnNonUniformBackgroundPreservesTheSourceSafetyNet() throws {
        let directory = try temporaryDirectory(prefix: "KCDeepL-NonUniformTextMaskTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("non-uniform-text.pdf")
        try makePDFWithNonUniformTextBackground(at: source)

        let scene = try PDFSceneExtractor().extract(sourceURL: source)
        let page = try XCTUnwrap(scene.pages.first)
        let textBox = try XCTUnwrap(
            page.textBoxes.first(where: { $0.text.contains("background safety") })
        )

        XCTAssertEqual(
            textBox.visualPolicy,
            .preserveSourcePaint,
            "A mask crossing even a light template transition must retain the exact source raster."
        )
    }

    func testClippingRectangleNeverBecomesAVisibleVectorOverlay() throws {
        let directory = try temporaryDirectory(prefix: "KCDeepL-ClippingVectorTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("clip-path.pdf")
        try makePDFWithFullPageClippingPath(at: source)

        let scene = try PDFSceneExtractor().extract(sourceURL: source)
        let page = try XCTUnwrap(scene.pages.first)
        XCTAssertFalse(
            page.vectors.contains {
                $0.bounds.width >= page.width * 0.98
                    && $0.bounds.height >= page.height * 0.98
            },
            "A `re W n` clipping path must be discarded before a later fill can be emitted."
        )
    }

    func testUnsafeOrOCRTextNeverErasesTheVisualSafetyNet() {
        let unsafeRun = PDFTextRun(
            text: "OCR text",
            fontName: "Arial",
            fontSize: 10,
            textColor: .black,
            isOfficeCompatible: true
        )
        let ocrLine = PDFTextLine(
            id: "ocr",
            text: "OCR text",
            runs: [unsafeRun],
            bounds: CGRect(x: 0, y: 0, width: 60, height: 12),
            sourceMaskBounds: CGRect(x: 0, y: 0, width: 60, height: 12),
            sourceMaskIsSafe: true,
            fontName: "Arial",
            fontSize: 10,
            textColor: .black,
            backgroundColor: .white,
            alignment: .left,
            readingOrder: 0,
            columnIndex: 0,
            extractionSource: .visionOCR
        )
        XCTAssertFalse(PDFOfficeTextAppearance.canReplaceSourcePaint(lines: [ocrLine]))

        let unknownGlyphRun = PDFTextRun(
            text: "\u{E000}",
            fontName: "Arial",
            fontSize: 10,
            textColor: .black,
            isOfficeCompatible: false
        )
        let unknownGlyphLine = PDFTextLine(
            id: "unknown-glyph",
            text: "\u{E000}",
            runs: [unknownGlyphRun],
            bounds: CGRect(x: 0, y: 0, width: 20, height: 12),
            sourceMaskBounds: CGRect(x: 0, y: 0, width: 20, height: 12),
            sourceMaskIsSafe: true,
            fontName: "Arial",
            fontSize: 10,
            textColor: .black,
            backgroundColor: .white,
            alignment: .left,
            readingOrder: 0,
            columnIndex: 0,
            extractionSource: .native
        )
        XCTAssertFalse(PDFOfficeTextAppearance.canReplaceSourcePaint(lines: [unknownGlyphLine]))

        let standaloneBullet = PDFTextLine(
            id: "standalone-bullet",
            text: "•",
            runs: [
                PDFTextRun(
                    text: "•",
                    fontName: "Arial",
                    fontSize: 12,
                    textColor: .black,
                    isOfficeCompatible: true
                )
            ],
            bounds: CGRect(x: 10, y: 10, width: 8, height: 12),
            sourceMaskBounds: CGRect(x: 10, y: 10, width: 8, height: 12),
            sourceMaskIsSafe: true,
            fontName: "Arial",
            fontSize: 12,
            textColor: .black,
            backgroundColor: .white,
            alignment: .left,
            readingOrder: 0,
            columnIndex: 0,
            extractionSource: .native
        )
        XCTAssertFalse(
            PDFOfficeTextAppearance.canReplaceSourcePaint(lines: [standaloneBullet]),
            "A standalone list marker must remain in the source safety-net."
        )
    }

    func testListPrefixRestoresOnlyTheSourceMarkerWhitespace() {
        let marker = PDFTextRun(
            text: "• ",
            fontName: "Arial",
            fontSize: 10,
            textColor: .black,
            isOfficeCompatible: true
        )
        let body = PDFTextRun(
            text: "First item keeps its ordinary spaces",
            fontName: "Arial",
            fontSize: 10,
            textColor: .black,
            isOfficeCompatible: true
        )
        let listLine = PDFTextLine(
            id: "list",
            text: "• First item keeps its ordinary spaces",
            runs: [marker, body],
            bounds: CGRect(x: 72, y: 680, width: 250, height: 12),
            sourceMaskBounds: CGRect(x: 72, y: 680, width: 250, height: 12),
            sourceMaskIsSafe: true,
            fontName: "Arial",
            fontSize: 10,
            textColor: .black,
            backgroundColor: .white,
            alignment: .left,
            readingOrder: 0,
            columnIndex: 0,
            extractionSource: .native
        )
        let continuation = PDFTextLine(
            id: "continuation",
            text: "Continuation",
            runs: [body],
            bounds: CGRect(x: 90, y: 664, width: 120, height: 12),
            sourceMaskBounds: CGRect(x: 90, y: 664, width: 120, height: 12),
            sourceMaskIsSafe: true,
            fontName: "Arial",
            fontSize: 10,
            textColor: .black,
            backgroundColor: .white,
            alignment: .left,
            readingOrder: 1,
            columnIndex: 0,
            extractionSource: .native
        )

        XCTAssertEqual(
            PDFOfficeTextAppearance.listTabStop(
                for: listLine,
                continuations: [continuation]
            ),
            18
        )
        let resolvedRuns = PDFOfficeTextAppearance.runsReplacingListWhitespace(
            [marker, body],
            targetTextOffset: 18
        )
        let resolvedText = resolvedRuns.map(\.text).joined()
        XCTAssertFalse(resolvedText.contains("\t"))
        XCTAssertTrue(resolvedText.hasPrefix("•"))
        XCTAssertTrue(resolvedText.hasSuffix("First item keeps its ordinary spaces"))
        XCTAssertGreaterThan(
            resolvedText.dropFirst().prefix(while: \.isWhitespace).count,
            0
        )
    }

    func testOfficeLayoutBoundsAnchorsFrameToRenderedInk() {
        let sourceBounds = CGRect(x: 72, y: 640, width: 260, height: 12)
        let cropBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let run = PDFTextRun(
            text: "The visible text begins below the PDF selection top.",
            fontName: "Arial",
            fontSize: 10,
            textColor: .black,
            isOfficeCompatible: true
        )
        let anchoredLine = PDFTextLine(
            id: "ink-anchor",
            text: run.text,
            runs: [run],
            bounds: sourceBounds,
            // The selection frame has 2pt of source font-cell padding but
            // the actual paint begins 2pt below its top edge.
            inkTopY: sourceBounds.maxY - 2,
            sourceMaskBounds: sourceBounds,
            sourceMaskIsSafe: true,
            fontName: "Arial",
            fontSize: 10,
            textColor: .black,
            backgroundColor: .white,
            alignment: .left,
            readingOrder: 0,
            columnIndex: 0,
            extractionSource: .native
        )
        let fallbackLine = PDFTextLine(
            id: "selection-anchor",
            text: run.text,
            runs: [run],
            bounds: sourceBounds,
            sourceMaskBounds: sourceBounds,
            sourceMaskIsSafe: true,
            fontName: "Arial",
            fontSize: 10,
            textColor: .black,
            backgroundColor: .white,
            alignment: .left,
            readingOrder: 0,
            columnIndex: 0,
            extractionSource: .native
        )

        let anchoredBounds = PDFOfficeTextAppearance.officeLayoutBounds(
            for: [anchoredLine],
            sourceBounds: sourceBounds,
            alignment: .left,
            cropBox: cropBox
        )
        let fallbackBounds = PDFOfficeTextAppearance.officeLayoutBounds(
            for: [fallbackLine],
            sourceBounds: sourceBounds,
            alignment: .left,
            cropBox: cropBox
        )
        let wordBounds = PDFOfficeTextAppearance.officeLayoutBounds(
            for: [anchoredLine],
            sourceBounds: sourceBounds,
            alignment: .left,
            cropBox: cropBox,
            layoutTarget: .word
        )

        XCTAssertEqual(fallbackBounds.maxY, sourceBounds.maxY, accuracy: 0.01)
        XCTAssertEqual(wordBounds.maxY, sourceBounds.maxY, accuracy: 0.01)
        XCTAssertGreaterThan(anchoredBounds.maxY, fallbackBounds.maxY)
        XCTAssertLessThan(anchoredBounds.maxY - fallbackBounds.maxY, 4.5)
    }

    func testWordWriterKeepsVisualLinesAndAttributedRunsInOneTextBox() throws {
        let firstLine = PDFSceneTextLine(
            id: "line-1",
            text: "•\tFirst line",
            bounds: CGRect(x: 72, y: 680, width: 200, height: 14),
            runs: [
                PDFSceneTextRun(
                    PDFTextRun(
                        text: "•",
                        fontName: "Arial",
                        fontSize: 10,
                        textColor: .black,
                        isOfficeCompatible: true
                    )
                ),
                PDFSceneTextRun(
                    PDFTextRun(
                        text: "\t",
                        fontName: "Arial",
                        fontSize: 10,
                        textColor: .black,
                        isOfficeCompatible: true
                    )
                ),
                PDFSceneTextRun(
                    PDFTextRun(
                        text: "First line",
                        fontName: "Arial",
                        fontSize: 10,
                        textColor: .black,
                        isBold: true,
                        isOfficeCompatible: true
                    )
                )
            ],
            sourceMaskBounds: CGRect(x: 72, y: 680, width: 200, height: 14),
            sourceMaskIsSafe: true,
            extractionSource: .native,
            listTabStop: 18
        )
        let secondLine = PDFSceneTextLine(
            id: "line-2",
            text: "Second line",
            bounds: CGRect(x: 90, y: 664, width: 182, height: 10),
            runs: [
                PDFSceneTextRun(
                    PDFTextRun(
                        text: "Second line",
                        fontName: "Arial",
                        fontSize: 10,
                        textColor: .black,
                        isItalic: true,
                        isOfficeCompatible: true
                    )
                )
            ],
            sourceMaskBounds: CGRect(x: 90, y: 664, width: 182, height: 10),
            sourceMaskIsSafe: true,
            extractionSource: .native
        )
        let textBox = PDFSceneTextBox(
            id: "text-box",
            text: "•\tFirst line\nSecond line",
            bounds: CGRect(x: 72, y: 664, width: 200, height: 30),
            layoutBounds: CGRect(x: 70, y: 662, width: 204, height: 32),
            fontName: "Arial",
            fontSize: 10,
            color: .black,
            alignment: .left,
            lineCount: 2,
            sourceLineIDs: ["line-1", "line-2"],
            extractionSource: .native,
            lines: [firstLine, secondLine],
            visualPolicy: .replaceSourcePaint
        )
        let page = PDFScenePage(
            id: "page",
            pageIndex: 0,
            cropBox: CGRect(x: 0, y: 0, width: 612, height: 792),
            rotation: 0,
            pageImagePNG: Data([0]),
            textBoxes: [textBox],
            images: [],
            vectors: [],
            templateObjects: [],
            imageOccurrenceCount: 0,
            extractedImageCount: 0,
            nativeVectorCount: 0,
            warnings: [],
            usesPageRasterFallback: true
        )
        let scene = PDFSceneDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/source.pdf"),
            sourceSHA256: "fixture",
            pages: [page],
            warnings: []
        )

        let parts = try WordprocessingMLWriter().makeParts(scene: scene)
        let documentPart = try XCTUnwrap(parts.first(where: { $0.name == "word/document.xml" }))
        let documentXML = try XCTUnwrap(String(data: documentPart.data, encoding: .utf8))
        let fontPart = try XCTUnwrap(parts.first(where: { $0.name == "word/fontTable.xml" }))
        let fontXML = try XCTUnwrap(String(data: fontPart.data, encoding: .utf8))

        XCTAssertTrue(documentXML.contains("<w:t xml:space=\"preserve\">•</w:t>"))
        XCTAssertTrue(documentXML.contains("<w:tab/>"))
        XCTAssertTrue(documentXML.contains("w:pos=\"360\""))
        XCTAssertTrue(documentXML.contains("<w:t xml:space=\"preserve\">First line</w:t>"))
        XCTAssertTrue(documentXML.contains("<w:t xml:space=\"preserve\">Second line</w:t>"))
        XCTAssertTrue(documentXML.contains("<w:b/><w:bCs/>"))
        XCTAssertTrue(documentXML.contains("<w:i/><w:iCs/>"))
        XCTAssertTrue(documentXML.contains("w:lineRule=\"atLeast\""))
        XCTAssertTrue(documentXML.contains("w:line=\"400\""))
        XCTAssertTrue(documentXML.contains("<w:ind w:left=\"360\" w:right=\"0\" w:firstLine=\"0\"/>"))
        XCTAssertTrue(documentXML.contains("lIns=\"25400\""))
        XCTAssertTrue(fontXML.contains("<w:font w:name=\"Arial\""))

        XCTAssertEqual(
            textBox.paragraphInsets(for: secondLine),
            PDFSceneTextParagraphInsets(leading: 18, trailing: 0)
        )

        let presentationParts = try PresentationMLWriter().makeParts(scene: scene)
        let slidePart = try XCTUnwrap(
            presentationParts.first(where: { $0.name == "ppt/slides/slide1.xml" })
        )
        let slideXML = try XCTUnwrap(String(data: slidePart.data, encoding: .utf8))
        XCTAssertTrue(slideXML.contains("typeface=\"Arial\""))
        XCTAssertTrue(slideXML.contains("lIns=\"25400\""))
        XCTAssertTrue(slideXML.contains("wrap=\"none\""))
        XCTAssertTrue(slideXML.contains("<a:tab pos=\"228600\"/>"))
        XCTAssertTrue(slideXML.contains("<a:tab/>"))
        XCTAssertTrue(slideXML.contains("<a:pPr marL=\"228600\" algn=\"l\""))
        XCTAssertTrue(slideXML.contains("<a:spcPts val=\"2000\"/>"))
    }

    @MainActor
    func testWorkspaceGateRejectsTheSecondKindUntilTheFirstReleases() throws {
        let gate = FileWorkspaceOperationGate()
        let translation = try gate.acquire(
            kind: .analysisOrTranslation,
            selectionGeneration: 1
        )
        XCTAssertThrowsError(
            try gate.acquire(kind: .conversion, selectionGeneration: 1)
        ) { error in
            XCTAssertEqual(
                error as? FileWorkspaceOperationGateError,
                .busy(.analysisOrTranslation)
            )
        }
        gate.release(translation)
        XCTAssertNoThrow(
            try gate.acquire(kind: .conversion, selectionGeneration: 1)
        )
    }

}

private extension DocumentConversionTests {
    func temporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    func makeOrientationPDF(at url: URL) throws {
        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else {
            XCTFail("PDF consumer creation failed")
            return
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 200)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else {
            XCTFail("PDF context creation failed")
            return
        }
        context.beginPDFPage([kCGPDFContextMediaBox: mediaBox] as CFDictionary)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: 140, width: 40, height: 40))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 40, height: 40))
        context.endPDFPage()
        context.closePDF()
        try (mutableData as Data).write(to: url, options: .atomic)
    }

    func makeTransparentTextPDF(at url: URL) throws {
        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else {
            XCTFail("PDF consumer creation failed")
            return
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else {
            XCTFail("PDF context creation failed")
            return
        }
        context.beginPDFPage([kCGPDFContextMediaBox: mediaBox] as CFDictionary)
        drawText("Transparent canvas text", at: CGPoint(x: 84, y: 690), in: context)
        context.endPDFPage()
        context.closePDF()
        try (mutableData as Data).write(to: url, options: .atomic)
    }

    func makePDFWithNonUniformTextBackground(at url: URL) throws {
        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else {
            XCTFail("PDF consumer creation failed")
            return
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else {
            XCTFail("PDF context creation failed")
            return
        }
        context.beginPDFPage([kCGPDFContextMediaBox: mediaBox] as CFDictionary)
        context.setFillColor(CGColor.white)
        context.fill(mediaBox)
        // The 8% tone transition is intentionally below the legacy interior
        // complexity threshold. The surrounding-halo check must therefore
        // catch it before a rectangular source mask can become visible.
        context.setFillColor(CGColor(gray: 0.92, alpha: 1))
        context.fill(CGRect(x: 210, y: 0, width: 402, height: 792))
        drawText(
            "background safety keeps template pixels",
            at: CGPoint(x: 100, y: 390),
            in: context
        )
        context.endPDFPage()
        context.closePDF()
        try (mutableData as Data).write(to: url, options: .atomic)
    }

    func makePDFWithFullPageClippingPath(at url: URL) throws {
        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else {
            XCTFail("PDF consumer creation failed")
            return
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else {
            XCTFail("PDF context creation failed")
            return
        }
        context.beginPDFPage([kCGPDFContextMediaBox: mediaBox] as CFDictionary)
        context.saveGState()
        context.addRect(mediaBox)
        context.clip()
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 96, y: 160, width: 160, height: 120))
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        try (mutableData as Data).write(to: url, options: .atomic)
    }

    func makePDF(at url: URL) throws {
        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else {
            XCTFail("PDF consumer creation failed")
            return
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else {
            XCTFail("PDF context creation failed")
            return
        }
        context.beginPDFPage([
            kCGPDFContextMediaBox: mediaBox
        ] as CFDictionary)
        context.setFillColor(CGColor(red: 0.95, green: 0.96, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
        context.setStrokeColor(CGColor.black)
        context.setLineWidth(2)
        context.stroke(CGRect(x: 60, y: 60, width: 492, height: 672))
        context.move(to: CGPoint(x: 60, y: 396))
        context.addLine(to: CGPoint(x: 552, y: 396))
        context.strokePath()
        drawText("First line of a paragraph", at: CGPoint(x: 84, y: 690), in: context)
        drawText("Second line of a paragraph", at: CGPoint(x: 84, y: 666), in: context)
        context.endPDFPage()
        context.closePDF()
        try (mutableData as Data).write(to: url, options: .atomic)
    }

    func makePDFWithImage(at url: URL) throws {
        let width = 48
        let height = 32
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                pixels.append(UInt8((x * 255) / max(1, width - 1)))
                pixels.append(UInt8((y * 255) / max(1, height - 1)))
                pixels.append(220)
                pixels.append((x < width / 2) ? 255 : 130)
            }
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.last.rawValue
                          | CGBitmapInfo.byteOrder32Big.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else {
            XCTFail("Image fixture creation failed")
            return
        }

        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else {
            XCTFail("PDF consumer creation failed")
            return
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            XCTFail("PDF context creation failed")
            return
        }
        context.beginPDFPage([kCGPDFContextMediaBox: mediaBox] as CFDictionary)
        context.draw(image, in: CGRect(x: 80, y: 120, width: 260, height: 180))
        context.endPDFPage()
        context.closePDF()
        try (mutableData as Data).write(to: url, options: .atomic)
    }

    func makePDFWithOpaqueImageCoveredByLaterPaint(at url: URL) throws {
        let width = 64
        let height = 48
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                pixels.append(UInt8((x * 255) / max(1, width - 1)))
                pixels.append(UInt8((y * 255) / max(1, height - 1)))
                pixels.append(80)
                pixels.append(0)
            }
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
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
        else {
            XCTFail("Opaque image fixture creation failed")
            return
        }

        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else {
            XCTFail("PDF consumer creation failed")
            return
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            XCTFail("PDF context creation failed")
            return
        }
        context.beginPDFPage([kCGPDFContextMediaBox: mediaBox] as CFDictionary)
        context.draw(image, in: CGRect(x: 120, y: 180, width: 300, height: 220))
        // This is deliberately larger than the image-safety sampler spacing:
        // reinserting the original image would visibly erase the later paint.
        context.setFillColor(CGColor.black)
        context.fill(CGRect(x: 200, y: 230, width: 150, height: 120))
        context.endPDFPage()
        context.closePDF()
        try (mutableData as Data).write(to: url, options: .atomic)
    }

    func drawText(_ text: String, at position: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: CGColor.black
            ]
        )
        context.textPosition = position
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
}
