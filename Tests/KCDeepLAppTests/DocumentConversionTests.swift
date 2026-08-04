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

    func testConversionProgressIsMonotonicAndCoversPipelinePhases() throws {
        let directory = try temporaryDirectory(prefix: "KCDeepL-ConversionProgressTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        try makePDF(at: source)
        let output = directory.appendingPathComponent("converted.docx")
        let recorder = ProgressRecorder()

        _ = try PDFOfficeConversionService().convert(
            sourceURL: source,
            format: .docx,
            destinationURL: output,
            progress: { recorder.append($0) }
        )

        let updates = recorder.values
        XCTAssertGreaterThan(updates.count, 4)
        XCTAssertEqual(try XCTUnwrap(updates.last).fraction, 1, accuracy: 0.0001)
        XCTAssertEqual(updates.first?.phase, .preparing)
        XCTAssertTrue(updates.contains { $0.phase == .extracting })
        XCTAssertTrue(updates.contains { $0.phase == .writing })
        XCTAssertTrue(updates.contains { $0.phase == .validating })
        XCTAssertTrue(updates.contains { $0.phase == .saving })
        XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { current, next in
            next.fraction + 0.0001 >= current.fraction
        })
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

        let scene = try PDFSceneExtractor().extract(sourceURL: source)
        let page = try XCTUnwrap(scene.pages.first)
        let transparentImage = try XCTUnwrap(
            page.images.first(where: { $0.hasAlpha || $0.maskApplied })
        )
        XCTAssertFalse(transparentImage.canOverlayOnPageSafetyNet)
        XCTAssertTrue(
            transparentImage.canRecreateOnRepairedPage,
            "A transparent image on a simple, fully recoverable backdrop must become a native Office picture."
        )

        let parts = try PresentationMLWriter().makeParts(scene: scene)
        XCTAssertNotNil(
            parts.first(where: { $0.name == "ppt/media/object-1-1.png" }),
            "The selectable source image must be packaged separately from the page template."
        )
        let slidePart = try XCTUnwrap(
            parts.first(where: { $0.name == "ppt/slides/slide1.xml" })
        )
        let slideXML = try XCTUnwrap(String(data: slidePart.data, encoding: .utf8))
        XCTAssertTrue(
            slideXML.contains("r:embed=\"rId3\""),
            "The transparent image must be reinserted over its repaired template, not omitted or blended twice over original pixels."
        )
    }

    func testSeparateSourceImageDoesNotCreateAFlattenedPageAsset() throws {
        let directory = try temporaryDirectory(prefix: "KCDeepL-NativeCanvasImageTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("image-source.pdf")
        try makePDFWithImage(at: source)

        let scene = try PDFSceneExtractor().extract(sourceURL: source)
        let page = try XCTUnwrap(scene.pages.first)
        XCTAssertTrue(page.isNativeCanvasBackground)
        XCTAssertFalse(page.usesPageRasterFallback)
        XCTAssertGreaterThanOrEqual(page.images.count, 1)

        let parts = try PresentationMLWriter().makeParts(scene: scene)
        XCTAssertFalse(
            parts.contains { $0.name == "ppt/media/image1.png" },
            "A page made from a plain canvas and a source image must not be flattened back into one page screenshot."
        )
        XCTAssertTrue(
            parts.contains { $0.name.hasPrefix("ppt/media/object-1-") },
            "The source image must remain a separately editable Office picture."
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
        let laterVector = try XCTUnwrap(
            page.vectors.max(by: { $0.paintOrder < $1.paintOrder })
        )

        XCTAssertGreaterThan(
            laterVector.paintOrder,
            opaqueImage.paintOrder,
            "Vector and image paint orders must share one PDF content-stream sequence."
        )

        XCTAssertFalse(
            opaqueImage.canOverlayOnPageSafetyNet,
            "An opaque PDF image covered by later paint must remain only in the authoritative page raster."
        )
        XCTAssertFalse(opaqueImage.isSafetyNetVerifiedOpaque)
        XCTAssertFalse(
            opaqueImage.canRecreateOnRepairedPage,
            "A later paint layer must also prevent template repair and native image reinsertion."
        )
    }

    func testTransparentImageCoveredByLaterPaintRemainsInTemplate() throws {
        let directory = try temporaryDirectory(prefix: "KCDeepL-TransparentImageSafetyNetTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("transparent-image-covered.pdf")
        try makePDFWithImage(
            at: source,
            // This later rectangle intersects both opaque and semi-transparent
            // pixels. Reinserting the source PNG above the repaired template
            // would otherwise hide the real topmost PDF paint.
            laterPaintRect: CGRect(x: 180, y: 175, width: 84, height: 54)
        )

        let scene = try PDFSceneExtractor().extract(sourceURL: source)
        let page = try XCTUnwrap(scene.pages.first)
        let transparentImage = try XCTUnwrap(
            page.images.first(where: { $0.hasAlpha || $0.maskApplied })
        )

        XCTAssertFalse(transparentImage.canOverlayOnPageSafetyNet)
        XCTAssertFalse(
            transparentImage.canRecreateOnRepairedPage,
            "A later paint layer must prevent a transparent source image from covering the final PDF content."
        )
    }

    func testImagePlacementCapturesNonRectangularPDFClip() throws {
        let directory = try temporaryDirectory(prefix: "KCDeepL-ImageClipTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("clipped-image.pdf")
        try makePDFWithClippedImage(at: source)

        let scene = try PDFSceneExtractor().extract(sourceURL: source)
        let page = try XCTUnwrap(scene.pages.first)
        let clippedImage = try XCTUnwrap(
            page.images.first(where: { $0.clip != nil })
        )
        let clip = try XCTUnwrap(clippedImage.clip)

        XCTAssertGreaterThanOrEqual(clip.pathCommands.count, 4)
        XCTAssertTrue(
            clip.pathCommands.contains { command in
                if case .close = command { return true }
                return false
            },
            "The PDF clipping polygon must retain its closed path for DrawingML custom geometry."
        )
        XCTAssertTrue(clippedImage.hasRepresentableGeometry)
        XCTAssertFalse(
            clippedImage.canRecreateOnRepairedPage,
            "A non-rectangular clip cannot be repaired by erasing a rectangular page-fallback area."
        )
    }

    func testImageClipVisibilityProofExcludesMaskedOutPixels() {
        let clip = PDFSceneImageClip(
            bounds: CGRect(x: 100, y: 100, width: 160, height: 160),
            pathCommands: [
                .move(CGPoint(x: 100, y: 100)),
                .line(CGPoint(x: 260, y: 100)),
                .line(CGPoint(x: 260, y: 260)),
                .close
            ]
        )

        XCTAssertTrue(
            PDFSceneExtractor.pointIsInsideImageClip(
                CGPoint(x: 220, y: 130),
                clip: clip
            )
        )
        XCTAssertFalse(
            PDFSceneExtractor.pointIsInsideImageClip(
                CGPoint(x: 120, y: 240),
                clip: clip
            ),
            "The alpha visibility proof must ignore source pixels outside a PDF clip."
        )
    }

    func testPresentationWriterSerializesClippedImageAsEditableFreeform() throws {
        let clip = PDFSceneImageClip(
            bounds: CGRect(x: 200, y: 40, width: 160, height: 120),
            pathCommands: [
                .move(CGPoint(x: 200, y: 40)),
                .line(CGPoint(x: 360, y: 40)),
                .line(CGPoint(x: 360, y: 160)),
                .line(CGPoint(x: 240, y: 160)),
                .close
            ]
        )
        let image = PDFSceneImage(
            id: "clipped-image",
            sourceName: "photo",
            bounds: CGRect(x: 200, y: 40, width: 160, height: 120),
            pngData: Data([0]),
            paintOrder: 2,
            hasAlpha: false,
            maskApplied: false,
            backdropColor: nil,
            isBackdropIndependent: true,
            isSafetyNetVerifiedOpaque: true,
            hasRepresentableGeometry: true,
            isNativeObjectEligible: true,
            isLayeredTemplateEligible: true,
            hasVisibleReferenceContribution: true,
            clip: clip
        )
        let page = PDFScenePage(
            id: "clipped-page",
            pageIndex: 0,
            cropBox: CGRect(x: 0, y: 0, width: 400, height: 240),
            rotation: 0,
            pageImagePNG: Data([0]),
            textBoxes: [],
            images: [image],
            vectors: [],
            templateObjects: [],
            imageOccurrenceCount: 1,
            extractedImageCount: 1,
            nativeVectorCount: 0,
            warnings: [],
            usesPageRasterFallback: false
        )
        let scene = PDFSceneDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/clipped-image.pdf"),
            sourceSHA256: "clip-fixture",
            pages: [page],
            warnings: []
        )

        let parts = try PresentationMLWriter().makeParts(scene: scene)
        let slide = try XCTUnwrap(parts.first(where: { $0.name == "ppt/slides/slide1.xml" }))
        let xml = try XCTUnwrap(String(data: slide.data, encoding: .utf8))

        XCTAssertTrue(xml.contains("name=\"PDF clipped image photo\""))
        XCTAssertTrue(xml.contains("<a:custGeom>"))
        XCTAssertTrue(xml.contains("<a:blipFill"))
        XCTAssertTrue(xml.contains("<a:close/>"))
    }

    func testPresentationWriterReplaysImagesAndVectorsInGlobalPaintOrder() throws {
        let black = PDFTextColor(red: 0, green: 0, blue: 0, alpha: 1)
        let earlyVector = PDFSceneVector(
            id: "early-vector",
            kind: .rectangle,
            bounds: CGRect(x: 20, y: 20, width: 80, height: 60),
            pathCommands: [],
            stroke: nil,
            fill: black,
            lineWidth: 0,
            rotation: 0,
            paintOrder: 10,
            nativeEligible: true,
            isSafetyNetVerifiedOpaque: true
        )
        let image = PDFSceneImage(
            id: "photo",
            sourceName: "photo",
            bounds: CGRect(x: 80, y: 40, width: 120, height: 90),
            pngData: Data([0]),
            paintOrder: 20,
            hasAlpha: false,
            maskApplied: false,
            backdropColor: nil,
            isBackdropIndependent: true,
            isSafetyNetVerifiedOpaque: true,
            hasRepresentableGeometry: true,
            isNativeObjectEligible: true,
            isLayeredTemplateEligible: true,
            hasVisibleReferenceContribution: true
        )
        let lateVector = PDFSceneVector(
            id: "late-vector",
            kind: .rectangle,
            bounds: CGRect(x: 120, y: 70, width: 70, height: 50),
            pathCommands: [],
            stroke: nil,
            fill: black,
            lineWidth: 0,
            rotation: 0,
            paintOrder: 30,
            nativeEligible: true,
            isSafetyNetVerifiedOpaque: true
        )
        let page = PDFScenePage(
            id: "paint-order-page",
            pageIndex: 0,
            cropBox: CGRect(x: 0, y: 0, width: 400, height: 240),
            rotation: 0,
            pageImagePNG: Data([0]),
            textBoxes: [],
            images: [image],
            vectors: [lateVector, earlyVector],
            templateObjects: [],
            imageOccurrenceCount: 1,
            extractedImageCount: 1,
            nativeVectorCount: 2,
            warnings: [],
            usesPageRasterFallback: false
        )
        let scene = PDFSceneDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/paint-order.pdf"),
            sourceSHA256: "paint-order-fixture",
            pages: [page],
            warnings: []
        )

        let parts = try PresentationMLWriter().makeParts(scene: scene)
        let slide = try XCTUnwrap(parts.first(where: { $0.name == "ppt/slides/slide1.xml" }))
        let xml = try XCTUnwrap(String(data: slide.data, encoding: .utf8))
        let early = try XCTUnwrap(xml.range(of: "name=\"PDF rectangle 3\""))
        let photo = try XCTUnwrap(xml.range(of: "name=\"PDF image photo\""))
        let late = try XCTUnwrap(xml.range(of: "name=\"PDF rectangle 5\""))

        XCTAssertLessThan(early.lowerBound, photo.lowerBound)
        XCTAssertLessThan(photo.lowerBound, late.lowerBound)
    }

    func testScaledOpaqueImageIsRecreatedAsNativePicture() throws {
        let directory = try temporaryDirectory(prefix: "KCDeepL-OpaqueImageNativeTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("opaque-image.pdf")
        try makePDFWithOpaqueImage(at: source, laterPaintRect: nil)

        let scene = try PDFSceneExtractor().extract(sourceURL: source)
        let page = try XCTUnwrap(scene.pages.first)
        let opaqueImage = try XCTUnwrap(
            page.images.first(where: { !$0.hasAlpha && !$0.maskApplied })
        )

        XCTAssertTrue(opaqueImage.isSafetyNetVerifiedOpaque)
        XCTAssertTrue(opaqueImage.canRecreateOnRepairedPage)

        let parts = try PresentationMLWriter().makeParts(scene: scene)
        let slidePart = try XCTUnwrap(
            parts.first(where: { $0.name == "ppt/slides/slide1.xml" })
        )
        let slideXML = try XCTUnwrap(String(data: slidePart.data, encoding: .utf8))
        let imageIndex = try XCTUnwrap(page.images.firstIndex(where: { $0.id == opaqueImage.id }))
        XCTAssertTrue(slideXML.contains("r:embed=\"rId\(imageIndex + 3)\""))
    }

    func testOpaqueImageWithSmallLaterPaintDoesNotOverlaySafetyNet() throws {
        let directory = try temporaryDirectory(prefix: "KCDeepL-SmallOpaqueImageSafetyNetTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("opaque-image-small-covered.pdf")
        try makePDFWithOpaqueImage(
            at: source,
            // Four and a half percent of the image: small enough to evade a
            // pure mean-error gate, but large enough to be visibly wrong if
            // the source image is inserted over it again.
            laterPaintRect: CGRect(x: 180, y: 260, width: 100, height: 30)
        )

        let scene = try PDFSceneExtractor().extract(sourceURL: source)
        let page = try XCTUnwrap(scene.pages.first)
        let opaqueImage = try XCTUnwrap(
            page.images.first(where: { !$0.hasAlpha && !$0.maskApplied })
        )

        XCTAssertFalse(opaqueImage.isSafetyNetVerifiedOpaque)
        XCTAssertFalse(opaqueImage.canRecreateOnRepairedPage)
    }

    func testOpaqueImageWithSmallLaterPaintDoesNotPassDirectPixelMatch() throws {
        let directory = try temporaryDirectory(prefix: "KCDeepL-DirectImageSafetyNetTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("opaque-image-direct-covered.pdf")
        try makePDFWithOpaqueImage(
            at: source,
            // This source is white, so the direct RGB mean remains low even
            // though a compact black later paint layer is visible.
            laterPaintRect: CGRect(x: 180, y: 260, width: 80, height: 20),
            solidWhite: true
        )

        let scene = try PDFSceneExtractor().extract(sourceURL: source)
        let page = try XCTUnwrap(scene.pages.first)
        let opaqueImage = try XCTUnwrap(
            page.images.first(where: { !$0.hasAlpha && !$0.maskApplied })
        )

        XCTAssertFalse(opaqueImage.isSafetyNetVerifiedOpaque)
        XCTAssertFalse(opaqueImage.canRecreateOnRepairedPage)
    }

    func testOfficeRunResolverCanonicalizesLegacyTypefaceAndBullet() throws {
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
        XCTAssertTrue(
            branded.isOfficeCompatible,
            "A bundled OFL font must resolve to an editable Office typeface."
        )
        XCTAssertEqual(
            branded.fontName,
            "Barlow",
            "The real Barlow faces are embedded into the PPTX package."
        )
        XCTAssertNil(branded.sourceFontName)

        let fitted = PDFOfficeTextAppearance.calibratedRuns(
            [branded],
            sourceWidth: 40
        )
        let fittedRun = try XCTUnwrap(fitted.first)
        XCTAssertEqual(
            fittedRun.fontSize,
            branded.fontSize,
            "A real embedded face preserves the PDF's original typographic metrics."
        )
    }

    func testPresentationWriterEmbedsBundledBarlowForEditableText() throws {
        XCTAssertNotNil(
            AppResourceLocator.url(
                forResource: "Barlow-Regular",
                withExtension: "ttf",
                subdirectory: "Fonts/Barlow"
            )
        )
        XCTAssertTrue(OfficeEmbeddedFontCatalog.canEmbedPresentationTypeface("Barlow"))
        let run = PDFSceneTextRun(
            PDFOfficeTextAppearance.run(
                text: "Editable Barlow",
                fontName: "Barlow-Regular",
                fontSize: 20,
                color: .black
            )
        )
        let line = PDFSceneTextLine(
            id: "barlow-line",
            text: "Editable Barlow",
            bounds: CGRect(x: 60, y: 480, width: 180, height: 24),
            runs: [run],
            sourceMaskBounds: CGRect(x: 60, y: 480, width: 180, height: 24),
            sourceMaskIsSafe: true,
            extractionSource: .native
        )
        let textBox = PDFSceneTextBox(
            id: "barlow-box",
            text: "Editable Barlow",
            bounds: CGRect(x: 60, y: 480, width: 180, height: 24),
            fontName: "Barlow",
            fontSize: 20,
            color: .black,
            alignment: .left,
            lineCount: 1,
            sourceLineIDs: [line.id],
            extractionSource: .native,
            lines: [line],
            visualPolicy: .replaceSourcePaint
        )
        let page = PDFScenePage(
            id: "barlow-page",
            pageIndex: 0,
            cropBox: CGRect(x: 0, y: 0, width: 400, height: 240),
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
            sourceURL: URL(fileURLWithPath: "/tmp/barlow-source.pdf"),
            sourceSHA256: "barlow-fixture",
            pages: [page],
            warnings: []
        )

        let parts = try PresentationMLWriter().makeParts(scene: scene)
        let fontParts = parts.filter { $0.name.hasPrefix("ppt/fonts/") }
        XCTAssertEqual(fontParts.count, 4)
        for fontPart in fontParts {
            XCTAssertGreaterThan(fontPart.data.count, 1_000)
            XCTAssertEqual(fontPart.data[34], 0x4C)
            XCTAssertEqual(fontPart.data[35], 0x50)
            let declaredSize = Int(fontPart.data[0])
                | Int(fontPart.data[1]) << 8
                | Int(fontPart.data[2]) << 16
                | Int(fontPart.data[3]) << 24
            XCTAssertEqual(declaredSize, fontPart.data.count)
        }
        let boldFace = try XCTUnwrap(
            fontParts.first(where: { $0.name == "ppt/fonts/font2.fntdata" })
        )
        let boldDescriptor = try XCTUnwrap(
            "Barlow Bold".data(using: .utf16LittleEndian)
        )
        let semiBoldDescriptor = try XCTUnwrap(
            "Barlow SemiBold".data(using: .utf16LittleEndian)
        )
        XCTAssertNotNil(
            boldFace.data.range(of: boldDescriptor),
            "The <p:bold> face must embed Barlow Bold, not a synthesized or SemiBold substitute."
        )
        XCTAssertNil(
            boldFace.data.range(of: semiBoldDescriptor)
        )

        let presentation = try XCTUnwrap(
            parts.first(where: { $0.name == "ppt/presentation.xml" })
        )
        let presentationXML = String(decoding: presentation.data, as: UTF8.self)
        XCTAssertTrue(presentationXML.contains("embedTrueTypeFonts=\"1\""))
        XCTAssertTrue(presentationXML.contains("typeface=\"Barlow\""))
        XCTAssertTrue(presentationXML.contains("<p:regular r:id="))
        XCTAssertTrue(presentationXML.contains("<p:bold r:id="))
        XCTAssertTrue(presentationXML.contains("<p:italic r:id="))
        XCTAssertTrue(presentationXML.contains("<p:boldItalic r:id="))

        let relationships = try XCTUnwrap(
            parts.first(where: { $0.name == "ppt/_rels/presentation.xml.rels" })
        )
        let relationshipsXML = String(decoding: relationships.data, as: UTF8.self)
        XCTAssertEqual(
            relationshipsXML.components(separatedBy: "/relationships/font").count - 1,
            4
        )
        let contentTypes = try XCTUnwrap(
            parts.first(where: { $0.name == "[Content_Types].xml" })
        )
        XCTAssertTrue(
            String(decoding: contentTypes.data, as: UTF8.self)
                .contains("Extension=\"fntdata\" ContentType=\"application/x-fontdata\"")
        )
        let slide = try XCTUnwrap(
            parts.first(where: { $0.name == "ppt/slides/slide1.xml" })
        )
        let slideXML = String(decoding: slide.data, as: UTF8.self)
        XCTAssertTrue(slideXML.contains("typeface=\"Barlow\""))
        XCTAssertTrue(
            slideXML.contains("spc=\"4\""),
            "Editable Barlow Regular runs retain the calibrated DrawingML advance."
        )
    }

    func testPresentationWriterUsesSoftLineBreaksForWrappedListItem() throws {
        let firstRun = PDFSceneTextRun(
            PDFTextRun(
                text: "• First source line",
                fontName: "Arial",
                fontSize: 12,
                textColor: .black,
                isOfficeCompatible: true
            )
        )
        let continuationRun = PDFSceneTextRun(
            PDFTextRun(
                text: "wrapped continuation",
                fontName: "Arial",
                fontSize: 12,
                textColor: .black,
                isOfficeCompatible: true
            )
        )
        let first = PDFSceneTextLine(
            id: "wrapped-list-first",
            text: "• First source line",
            bounds: CGRect(x: 50, y: 198, width: 140, height: 12),
            runs: [firstRun],
            sourceMaskBounds: CGRect(x: 50, y: 198, width: 140, height: 12),
            sourceMaskIsSafe: true,
            extractionSource: .native,
            listTabStop: 24
        )
        let continuation = PDFSceneTextLine(
            id: "wrapped-list-continuation",
            text: "wrapped continuation",
            bounds: CGRect(x: 74, y: 176, width: 120, height: 12),
            runs: [continuationRun],
            sourceMaskBounds: CGRect(x: 74, y: 176, width: 120, height: 12),
            sourceMaskIsSafe: true,
            extractionSource: .native
        )
        let textBox = PDFSceneTextBox(
            id: "wrapped-list-box",
            text: "• First source line\nwrapped continuation",
            bounds: CGRect(x: 50, y: 176, width: 144, height: 34),
            fontName: "Arial",
            fontSize: 12,
            color: .black,
            alignment: .left,
            lineCount: 2,
            sourceLineIDs: [first.id, continuation.id],
            extractionSource: .native,
            lines: [first, continuation],
            visualPolicy: .replaceSourcePaint
        )
        let page = PDFScenePage(
            id: "wrapped-list-page",
            pageIndex: 0,
            cropBox: CGRect(x: 0, y: 0, width: 300, height: 240),
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
            sourceURL: URL(fileURLWithPath: "/tmp/wrapped-list.pdf"),
            sourceSHA256: "wrapped-list-fixture",
            pages: [page],
            warnings: []
        )

        let parts = try PresentationMLWriter().makeParts(scene: scene)
        let slide = try XCTUnwrap(
            parts.first(where: { $0.name == "ppt/slides/slide1.xml" })
        )
        let xml = String(decoding: slide.data, as: UTF8.self)

        XCTAssertEqual(
            xml.components(separatedBy: "<a:p>").count - 1,
            1,
            "One PDF paragraph must remain one editable PowerPoint paragraph."
        )
        XCTAssertTrue(xml.contains("<a:br/>"))
        XCTAssertTrue(xml.contains("marL=\"304800\""))
        XCTAssertTrue(xml.contains("indent=\"-304800\""))
        XCTAssertTrue(xml.contains("<a:spcPts val=\"2200\"/>"))
        XCTAssertTrue(
            xml.contains("tIns=\"45720\""),
            "A fixed-line paragraph needs its proportional top reserve in the text frame."
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

    func testTextOnNonUniformBackgroundUsesGlyphAwareTemplateRepair() throws {
        let directory = try temporaryDirectory(prefix: "KCDeepL-NonUniformTextMaskTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("non-uniform-text.pdf")
        try makePDFWithNonUniformTextBackground(at: source)

        let analysis = try PDFDocumentAnalysisService(
            includeOCR: true,
            includeSupplementalOCR: false,
            maximumOCRImageDimension: 2_400,
            requiresSourceMaskHaloValidation: true,
            retainDocumentChromeForTemplate: true
        ).analyze(sourceURL: source)
        let analyzedLine = try XCTUnwrap(
            analysis.pages.first?.lines.first(where: {
                $0.text.contains("background safety")
            })
        )
        XCTAssertFalse(
            analyzedLine.sourceMaskIsSafe,
            "The non-uniform template must remain protected from rectangular source-paint removal."
        )
        XCTAssertNotNil(
            analyzedLine.inkTopY,
            "A protected template can still provide a reliable rendered-ink anchor for editable Office text."
        )

        let scene = try PDFSceneExtractor().extract(sourceURL: source)
        let page = try XCTUnwrap(scene.pages.first)
        let textBox = try XCTUnwrap(
            page.textBoxes.first(where: { $0.text.contains("background safety") })
        )

        XCTAssertEqual(
            textBox.visualPolicy,
            .repairSourcePaint,
            "Native text on a non-uniform backdrop must remain editable through local glyph repair."
        )
    }

    func testParagraphAlignmentPrefersRepeatedLeadingEdges() {
        let makeLine: (String, CGFloat, CGFloat, CGFloat) -> PDFTextLine = {
            id, x, width, y in
            PDFTextLine(
                id: id,
                text: "A paragraph line with measurable width",
                runs: [
                    PDFTextRun(
                        text: "A paragraph line with measurable width",
                        fontName: "Arial",
                        fontSize: 18,
                        textColor: .black,
                        isOfficeCompatible: true
                    )
                ],
                bounds: CGRect(x: x, y: y, width: width, height: 22),
                sourceMaskBounds: CGRect(x: x, y: y, width: width, height: 22),
                sourceMaskIsSafe: true,
                fontName: "Arial",
                fontSize: 18,
                textColor: .black,
                backgroundColor: .white,
                alignment: .center,
                readingOrder: 0,
                columnIndex: 0,
                extractionSource: .native
            )
        }
        let lines = [
            makeLine("one", 160, 150, 300),
            makeLine("two", 160, 260, 276),
            makeLine("three", 160, 125, 252)
        ]

        XCTAssertEqual(
            PDFOfficeTextAppearance.paragraphAlignment(
                for: lines,
                fallback: .center
            ),
            .left,
            "A narrow inferred column must not turn a common leading edge into centred text."
        )
    }

    func testParagraphAlignmentPrefersRepeatedMidpoints() {
        let makeLine: (String, CGFloat, CGFloat, CGFloat) -> PDFTextLine = {
            id, x, width, y in
            PDFTextLine(
                id: id,
                text: "A paragraph line with measurable width",
                runs: [
                    PDFTextRun(
                        text: "A paragraph line with measurable width",
                        fontName: "Arial",
                        fontSize: 18,
                        textColor: .black,
                        isOfficeCompatible: true
                    )
                ],
                bounds: CGRect(x: x, y: y, width: width, height: 22),
                sourceMaskBounds: CGRect(x: x, y: y, width: width, height: 22),
                sourceMaskIsSafe: true,
                fontName: "Arial",
                fontSize: 18,
                textColor: .black,
                backgroundColor: .white,
                alignment: .left,
                readingOrder: 0,
                columnIndex: 0,
                extractionSource: .native
            )
        }
        let lines = [
            makeLine("one", 210, 180, 300),
            makeLine("two", 170, 260, 276),
            makeLine("three", 240, 120, 252)
        ]

        XCTAssertEqual(
            PDFOfficeTextAppearance.paragraphAlignment(
                for: lines,
                fallback: .left
            ),
            .center,
            "A multi-line title with one shared midpoint must remain centred."
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
        XCTAssertTrue(
            PDFOfficeTextAppearance.canReplaceSourcePaint(lines: [standaloneBullet]),
            "Glyph-aware template repair removes only the marker pixels, so a supported standalone bullet remains editable."
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

    func testListContinuationWithOverlappingSelectionCellsStaysInSameBlock() {
        let run = PDFTextRun(
            text: "• First visual line",
            fontName: "Barlow",
            fontSize: 18,
            textColor: .black,
            isOfficeCompatible: true
        )
        let first = PDFTextLine(
            id: "list-first",
            text: run.text,
            runs: [run],
            bounds: CGRect(x: 21.72, y: 299.27, width: 826.03, height: 25.36),
            sourceMaskBounds: CGRect(x: 21.72, y: 299.27, width: 826.03, height: 25.36),
            sourceMaskIsSafe: false,
            fontName: "Barlow",
            fontSize: 18,
            textColor: .black,
            backgroundColor: .white,
            alignment: .left,
            readingOrder: 0,
            columnIndex: -1,
            extractionSource: .native
        )
        let continuationRun = PDFTextRun(
            text: "wrapped continuation",
            fontName: "Barlow",
            fontSize: 18,
            textColor: .black,
            isOfficeCompatible: true
        )
        let continuation = PDFTextLine(
            id: "list-continuation",
            text: continuationRun.text,
            runs: [continuationRun],
            bounds: CGRect(x: 48.72, y: 281.92, width: 258.66, height: 23.27),
            sourceMaskBounds: CGRect(x: 48.72, y: 281.92, width: 258.66, height: 23.27),
            sourceMaskIsSafe: false,
            fontName: "Barlow",
            fontSize: 18,
            textColor: .black,
            backgroundColor: .white,
            alignment: .left,
            readingOrder: 1,
            columnIndex: 0,
            extractionSource: .native
        )

        XCTAssertTrue(
            PDFDocumentAnalysisService.canJoin(
                first,
                continuation,
                blockStart: first
            )
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

        var documentTextOptions = DocumentConversionPipelineOptions.default
        documentTextOptions.wordTextRepresentation = .documentText
        documentTextOptions.wordTextBoxAllowance = .never
        let documentTextParts = try WordprocessingMLWriter().makeParts(
            scene: scene,
            options: documentTextOptions
        )
        let documentTextPart = try XCTUnwrap(
            documentTextParts.first(where: { $0.name == "word/document.xml" })
        )
        let documentTextXML = try XCTUnwrap(
            String(data: documentTextPart.data, encoding: .utf8)
        )
        XCTAssertFalse(documentTextXML.contains("<w:txbx"))
        XCTAssertTrue(documentTextXML.contains("<w:br/>"))
        XCTAssertTrue(documentTextXML.contains("w:lineRule=\"exact\""))

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
        XCTAssertTrue(slideXML.contains("<a:pPr marL=\"228600\" indent=\"-228600\" algn=\"l\""))
        XCTAssertTrue(slideXML.contains("<a:spcPts val=\"2000\"/>"))
    }

    func testConversionOptionsRoundTripAndTargetMapping() throws {
        var options = DocumentConversionOptions.default
        options.presentation.templatePriority = .repeatedToTemplate
        options.presentation.textBoxMergeLevel = .broad
        options.presentation.imageGroupingLevel = .integrated
        options.word.textRepresentation = .documentText
        options.word.textBoxAllowance = .permissive
        options.word.templatePriority = .repeatedToTemplate
        options.word.imageGroupingLevel = .balanced
        options.word.preserveNativeVectors = false

        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(
            DocumentConversionOptions.self,
            from: data
        )
        XCTAssertEqual(decoded, options)
        XCTAssertEqual(
            decoded.pipeline(for: .pptx).textBoxMergeLevel,
            .broad
        )
        XCTAssertEqual(
            decoded.pipeline(for: .docx).wordTextRepresentation,
            .documentText
        )
        XCTAssertFalse(decoded.pipeline(for: .docx).preserveNativeVectors)
    }

    func testTemplatePriorityUsesPPTMasterAndDOCXHeaderLayer() throws {
        let scene = makeTemplateScene()
        var options = DocumentConversionPipelineOptions.default
        options.templatePriority = .repeatedToTemplate
        options.imageGroupingLevel = .integrated

        let presentationParts = try PresentationMLWriter().makeParts(
            scene: scene,
            options: options
        )
        XCTAssertNoThrow(
            try OOXMLPackageValidator.validate(
                parts: presentationParts,
                format: .pptx
            )
        )
        let masterPart = try XCTUnwrap(
            presentationParts.first(where: {
                $0.name == "ppt/slideMasters/slideMaster1.xml"
            })
        )
        let masterXML = try XCTUnwrap(String(data: masterPart.data, encoding: .utf8))
        XCTAssertTrue(masterXML.contains("Shared chrome"))
        XCTAssertTrue(masterXML.contains("<p:bg>"))
        XCTAssertTrue(masterXML.contains("p:sldLayoutId id=\"2147483649\""))
        let masterRelationships = try XCTUnwrap(
            presentationParts.first(where: {
                $0.name == "ppt/slideMasters/_rels/slideMaster1.xml.rels"
            })
        )
        let masterRelationshipsXML = try XCTUnwrap(
            String(data: masterRelationships.data, encoding: .utf8)
        )
        XCTAssertTrue(masterRelationshipsXML.contains("master-object-1.png"))
        let slidePart = try XCTUnwrap(
            presentationParts.first(where: { $0.name == "ppt/slides/slide1.xml" })
        )
        let slideXML = try XCTUnwrap(String(data: slidePart.data, encoding: .utf8))
        XCTAssertFalse(slideXML.contains("Shared chrome"))
        XCTAssertTrue(slideXML.contains("showMasterSp=\"1\""))

        let wordParts = try WordprocessingMLWriter().makeParts(
            scene: scene,
            options: options
        )
        XCTAssertNoThrow(
            try OOXMLPackageValidator.validate(
                parts: wordParts,
                format: .docx
            )
        )
        let headerPart = try XCTUnwrap(
            wordParts.first(where: { $0.name == "word/header1.xml" })
        )
        let headerXML = try XCTUnwrap(String(data: headerPart.data, encoding: .utf8))
        XCTAssertTrue(headerXML.contains("Shared chrome"))
        XCTAssertTrue(
            wordParts.contains(where: { $0.name == "word/_rels/header1.xml.rels" })
        )
        let documentPart = try XCTUnwrap(
            wordParts.first(where: { $0.name == "word/document.xml" })
        )
        let documentXML = try XCTUnwrap(String(data: documentPart.data, encoding: .utf8))
        XCTAssertTrue(documentXML.contains("<w:headerReference"))
        XCTAssertFalse(documentXML.contains("Shared chrome"))
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

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DocumentConversionProgress] = []

    var values: [DocumentConversionProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: DocumentConversionProgress) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private extension DocumentConversionTests {
    func makeTemplateScene() -> PDFSceneDocument {
        let bounds = CGRect(x: 72, y: 720, width: 160, height: 18)
        let run = PDFSceneTextRun(
            PDFTextRun(
                text: "Shared chrome",
                fontName: "Arial",
                fontSize: 12,
                textColor: .black,
                isOfficeCompatible: true
            )
        )
        let line = PDFSceneTextLine(
            id: "template-line",
            text: "Shared chrome",
            bounds: bounds,
            runs: [run],
            sourceMaskBounds: bounds,
            sourceMaskIsSafe: true,
            hasVisibleInk: true,
            extractionSource: .native
        )
        let textBox = PDFSceneTextBox(
            id: "template-template-line",
            text: "Shared chrome",
            bounds: bounds,
            layoutBounds: bounds,
            fontName: "Arial",
            fontSize: 12,
            color: .black,
            alignment: .left,
            lineCount: 1,
            sourceLineIDs: [line.id],
            extractionSource: .native,
            lines: [line],
            visualPolicy: .replaceSourcePaint,
            role: .templateChrome
        )
        let image = PDFSceneImage(
            id: "shared-logo",
            sourceName: "logo.png",
            bounds: CGRect(x: 24, y: 724, width: 36, height: 24),
            pngData: Data([1, 2, 3, 4]),
            paintOrder: 1,
            hasAlpha: false,
            maskApplied: false,
            backdropColor: .white,
            isBackdropIndependent: true,
            isSafetyNetVerifiedOpaque: true,
            hasRepresentableGeometry: true,
            isNativeObjectEligible: true,
            isLayeredTemplateEligible: true,
            hasVisibleReferenceContribution: true
        )
        return PDFSceneDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/template.pdf"),
            sourceSHA256: "template",
            pages: (0..<2).map { index in
                PDFScenePage(
                    id: "page-\(index)",
                    pageIndex: index,
                    cropBox: CGRect(x: 0, y: 0, width: 612, height: 792),
                    rotation: 0,
                    pageImagePNG: Data([8, UInt8(index)]),
                    textBoxes: [textBox],
                    images: [image],
                    vectors: [],
                    templateObjects: [
                        PDFSceneTemplateObject(
                            id: "template-chrome-\(textBox.id)",
                            role: .sharedTemplate,
                            bounds: bounds,
                            confidence: 0.99,
                            sourceFingerprint: "chrome-fp"
                        )
                    ],
                    imageOccurrenceCount: 1,
                    extractedImageCount: 1,
                    nativeVectorCount: 0,
                    warnings: [],
                    usesPageRasterFallback: false
                )
            },
            warnings: []
        )
    }

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

    func makePDFWithClippedImage(at url: URL) throws {
        let width = 64
        let height = 64
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                pixels.append(UInt8((x * 255) / max(1, width - 1)))
                pixels.append(UInt8((y * 255) / max(1, height - 1)))
                pixels.append(96)
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
            XCTFail("Clipped image fixture creation failed")
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
        context.setFillColor(CGColor.white)
        context.fill(mediaBox)
        context.saveGState()
        context.move(to: CGPoint(x: 140, y: 160))
        context.addLine(to: CGPoint(x: 420, y: 160))
        context.addLine(to: CGPoint(x: 420, y: 420))
        context.addLine(to: CGPoint(x: 220, y: 420))
        context.closePath()
        context.clip()
        context.draw(image, in: CGRect(x: 100, y: 120, width: 360, height: 340))
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        try (mutableData as Data).write(to: url, options: .atomic)
    }

    func makePDFWithImage(
        at url: URL,
        laterPaintRect: CGRect? = nil
    ) throws {
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
        if let laterPaintRect {
            context.setFillColor(CGColor.black)
            context.fill(laterPaintRect)
        }
        context.endPDFPage()
        context.closePDF()
        try (mutableData as Data).write(to: url, options: .atomic)
    }

    func makePDFWithOpaqueImage(
        at url: URL,
        laterPaintRect: CGRect?,
        solidWhite: Bool = false
    ) throws {
        let width = 64
        let height = 48
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                pixels.append(solidWhite ? 255 : UInt8((x * 255) / max(1, width - 1)))
                pixels.append(solidWhite ? 255 : UInt8((y * 255) / max(1, height - 1)))
                pixels.append(solidWhite ? 255 : 80)
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
        if let laterPaintRect {
            // This is deliberately larger than the image-safety sampler
            // spacing: reinserting the original image would visibly erase the
            // later paint.
            context.setFillColor(CGColor.black)
            context.fill(laterPaintRect)
        }
        context.endPDFPage()
        context.closePDF()
        try (mutableData as Data).write(to: url, options: .atomic)
    }

    func makePDFWithOpaqueImageCoveredByLaterPaint(at url: URL) throws {
        try makePDFWithOpaqueImage(
            at: url,
            laterPaintRect: CGRect(x: 200, y: 230, width: 150, height: 120)
        )
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
