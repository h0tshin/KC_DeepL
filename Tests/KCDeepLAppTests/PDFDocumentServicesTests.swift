import AppKit
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import KCDeepL

final class PDFDocumentServicesTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PDFDocumentServicesTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testAnalyzeRejectsNonPDFExtensionEvenWhenContentsArePDF() throws {
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        try makeDigitalPDF(
            at: source,
            pages: [[DrawnLine("Hello", x: 50, y: 700)]]
        )
        let renamed = temporaryDirectory.appendingPathComponent("source.txt")
        try FileManager.default.moveItem(at: source, to: renamed)

        XCTAssertThrowsError(
            try PDFDocumentAnalysisService().analyze(sourceURL: renamed)
        ) { error in
            XCTAssertEqual(error as? PDFDocumentServiceError, .invalidFileType)
        }
    }

    func testIncompleteOCRWarningsRequireExplicitAcknowledgement() {
        let requiringAcknowledgement: [PDFDocumentWarning] = [
            .hybridOCRUnavailable(pageIndex: 0),
            .rotatedHybridOCRUnsupported(pageIndex: 0, rotation: 90),
            .lowOCRConfidence(pageIndex: 0, confidence: 0.4),
            .ocrRequired(pageIndex: 0),
            .rotatedOCRUnsupported(pageIndex: 0, rotation: 45),
            .pageHasNoTranslatableText(pageIndex: 0)
        ]
        XCTAssertTrue(
            requiringAcknowledgement.allSatisfy(
                \.requiresIncompleteOCRAcknowledgement
            )
        )

        let nonAcknowledgementWarnings: [PDFDocumentWarning] = [
            .ocrApplied(pageIndex: 0),
            .hybridOCRApplied(pageIndex: 0, addedLineCount: 1),
            .blockTranslationReflowed(blockID: "block"),
            .complexBackground(pageIndex: 0, lineID: "line"),
            .backgroundSamplingUnavailable(pageIndex: 0, lineID: "line"),
            .linkOverlap(pageIndex: 0, lineID: "line", target: nil),
            .bestEffortLineSkipped(
                pageIndex: 0,
                lineID: "line",
                reason: "test"
            )
        ]
        XCTAssertTrue(
            nonAcknowledgementWarnings.allSatisfy {
                !$0.requiresIncompleteOCRAcknowledgement
            }
        )
    }

    func testAnalyzeProducesStableColumnAwareLineAndBlockIDs() throws {
        let source = temporaryDirectory.appendingPathComponent("columns.pdf")
        try makeDigitalPDF(
            at: source,
            pages: [[
                DrawnLine("Left one", x: 50, y: 720),
                DrawnLine("Left two", x: 50, y: 702),
                DrawnLine("Right one", x: 330, y: 720),
                DrawnLine("Right two", x: 330, y: 702)
            ]]
        )

        let service = PDFDocumentAnalysisService()
        let first = try service.analyze(sourceURL: source)
        let second = try service.analyze(sourceURL: source)

        XCTAssertEqual(first.pageCount, 1)
        XCTAssertEqual(first.translatableLineCount, 4)
        XCTAssertEqual(first.pages.map(\.id), second.pages.map(\.id))
        XCTAssertEqual(
            first.pages[0].lines.map(\.id),
            second.pages[0].lines.map(\.id)
        )
        XCTAssertEqual(
            first.pages[0].blocks.map(\.id),
            second.pages[0].blocks.map(\.id)
        )
        XCTAssertEqual(
            first.pages[0].lines.map(\.text),
            ["Left one", "Left two", "Right one", "Right two"]
        )
        XCTAssertEqual(first.pages[0].lines.map(\.readingOrder), [0, 1, 2, 3])
        XCTAssertEqual(first.pages[0].lines.map(\.columnIndex), [0, 0, 1, 1])
        XCTAssertEqual(first.pages[0].blocks.count, 2)
        XCTAssertEqual(
            first.pages[0].blocks.map(\.text),
            ["Left one Left two", "Right one Right two"]
        )
    }

    func testAnalyzeSplitsDistantSameBaselineTextRuns() throws {
        let source = temporaryDirectory.appendingPathComponent(
            "same-baseline-runs.pdf"
        )
        try makeDigitalPDF(
            at: source,
            pages: [[
                DrawnLine("2020 Dec", x: 70, y: 700, size: 20),
                DrawnLine("2021 Sept", x: 420, y: 700, size: 20)
            ]]
        )

        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let page = try XCTUnwrap(analysis.pages.first)

        XCTAssertEqual(page.lines.map(\.text), ["2020 Dec", "2021 Sept"])
        XCTAssertEqual(page.lines.count, 2)
        XCTAssertLessThan(page.lines[0].bounds.maxX, page.lines[1].bounds.minX)
    }

    func testAnalyzeDropsHiddenWhiteRunFromMixedColorLine() throws {
        let source = temporaryDirectory.appendingPathComponent(
            "hidden-color-run.pdf"
        )
        let visibleText = "MES rollout? -> position Plex"
        let font = NSFont.systemFont(ofSize: 18)
        let visibleWidth = (visibleText as NSString).size(
            withAttributes: [.font: font]
        ).width
        try makeDigitalPDF(
            at: source,
            pages: [[
                DrawnLine(visibleText, x: 50, y: 700, size: 18),
                DrawnLine(
                    "or",
                    x: 50 + visibleWidth,
                    y: 700,
                    color: .white,
                    size: 18
                ),
                DrawnLine("MES?", x: 50, y: 670, color: .white, size: 18)
            ]]
        )

        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let texts = try XCTUnwrap(analysis.pages.first).lines.map(\.text)

        XCTAssertTrue(texts.contains(visibleText), texts.joined(separator: " | "))
        XCTAssertFalse(texts.contains("or"))
        XCTAssertFalse(texts.contains("MES?"))
        XCTAssertFalse(texts.contains(where: { $0.contains("Plexor") }))
    }

    func testAnalyzeHandlesNonBMPTextWhileSplittingAttributedRuns() throws {
        let source = temporaryDirectory.appendingPathComponent(
            "non-bmp-runs.pdf"
        )
        try makeDigitalPDF(
            at: source,
            pages: [[
                DrawnLine("Visible😀Text", x: 50, y: 700, size: 18),
                DrawnLine("Hidden", x: 220, y: 700, color: .white, size: 18)
            ]]
        )

        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let sourceText = try XCTUnwrap(analysis.pages.first).sourceText

        XCTAssertTrue(sourceText.contains("Visible"))
        XCTAssertFalse(sourceText.contains("Hidden"))
    }

    func testAnalyzeLeavesLegalFooterAndPageNumberUntouched() throws {
        let source = temporaryDirectory.appendingPathComponent(
            "legal-footer.pdf"
        )
        try makeDigitalPDF(
            at: source,
            pages: [[
                DrawnLine("Translate this content", x: 50, y: 700, size: 18),
                DrawnLine(
                    "INTERNAL • Copyright ©2023 Example, Inc.",
                    x: 50,
                    y: 20,
                    color: .darkGray,
                    size: 8
                ),
                DrawnLine("9", x: 520, y: 20, size: 8)
            ]]
        )

        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let texts = try XCTUnwrap(analysis.pages.first).lines.map(\.text)

        XCTAssertEqual(texts, ["Translate this content"])
    }

    func testAnalyzeUsesVisionOCRForCleanImageOnlyPage() throws {
        let source = temporaryDirectory.appendingPathComponent("scan.pdf")
        try makeImageOnlyPDF(at: source, text: "HELLO OCR")

        let analysis = try PDFDocumentAnalysisService(
            ocrLanguages: ["en-US"]
        ).analyze(sourceURL: source)

        let page = try XCTUnwrap(analysis.pages.first)
        if page.lines.isEmpty {
            throw XCTSkip(
                "Vision OCR is unavailable in this test runtime: \(page.warnings.map(\.message))"
            )
        }
        XCTAssertFalse(page.lines.isEmpty)
        XCTAssertTrue(page.lines.allSatisfy { $0.extractionSource == .visionOCR })
        XCTAssertTrue(
            page.sourceText.uppercased().contains("HELLO")
                || page.sourceText.uppercased().contains("OCR")
        )
        XCTAssertTrue(page.warnings.contains(.ocrApplied(pageIndex: 0)))
    }

    func testRotatedImageOCRRestoresGeometryAndComposesEveryRightAngle() throws {
        let rotations = [0, 90, 180, 270]
        let cropBox = CGRect(x: 40, y: 60, width: 900, height: 400)
        let background = NSColor(
            deviceRed: 0.08,
            green: 0.24,
            blue: 0.56,
            alpha: 1
        )
        var referenceBounds: CGRect?

        for rotation in rotations {
            let source = temporaryDirectory.appendingPathComponent(
                "rotated-scan-\(rotation).pdf"
            )
            try makeImageOnlyPDF(
                at: source,
                text: "ROTATED",
                rotation: rotation,
                cropBox: cropBox,
                backgroundColor: background,
                textColor: .white
            )

            let analysis = try PDFDocumentAnalysisService(
                ocrLanguages: ["en-US"]
            ).analyze(sourceURL: source)
            let page = try XCTUnwrap(analysis.pages.first)
            guard let line = page.lines.first(where: {
                $0.text.uppercased().contains("ROTATED")
            }) ?? page.lines.first else {
                throw XCTSkip(
                    "Vision OCR is unavailable in this test runtime: \(page.warnings.map(\.message))"
                )
            }

            XCTAssertEqual(line.extractionSource, .visionOCR)
            XCTAssertTrue(page.warnings.contains(.ocrApplied(pageIndex: 0)))
            XCTAssertFalse(
                page.warnings.contains {
                    if case .rotatedOCRUnsupported = $0 { return true }
                    return false
                }
            )
            XCTAssertFalse(
                page.warnings.contains {
                    if case .backgroundSamplingUnavailable = $0 { return true }
                    return false
                }
            )
            XCTAssertTrue(cropBox.contains(line.bounds))
            XCTAssertEqual(line.bounds.minX, 81, accuracy: 15)
            XCTAssertEqual(line.bounds.minY, 203, accuracy: 15)
            XCTAssertEqual(line.bounds.width, 378, accuracy: 30)
            XCTAssertEqual(line.bounds.height, 70, accuracy: 18)
            XCTAssertLessThan(line.backgroundColor.red, 0.3)
            XCTAssertGreaterThan(
                line.backgroundColor.blue,
                line.backgroundColor.red + 0.3
            )
            XCTAssertEqual(line.textColor, .white)

            if let referenceBounds {
                assertEqual(referenceBounds, line.bounds, accuracy: 8)
            } else {
                referenceBounds = line.bounds
            }

            let destination = temporaryDirectory.appendingPathComponent(
                "rotated-translated-\(rotation).pdf"
            )
            XCTAssertNoThrow(
                try PDFDocumentCompositionService().validateReadiness(
                    analysis: analysis
                )
            )
            _ = try PDFDocumentCompositionService().compose(
                analysis: analysis,
                translations: [line.id: "회전 번역"],
                destinationURL: destination
            )
            try preserveRotatedQAFixtureIfRequested(
                sourceURL: source,
                translatedURL: destination,
                rotation: rotation
            )

            let output = try XCTUnwrap(PDFDocument(url: destination))
            XCTAssertEqual(output.pageCount, 1)
            let outputPage = try XCTUnwrap(output.page(at: 0))
            XCTAssertEqual(outputPage.rotation, rotation)
            let mask = try XCTUnwrap(
                outputPage.annotations.first {
                    $0.userName == "KCDeepL Mask:\(line.id)"
                }
            )
            let overlay = try XCTUnwrap(
                outputPage.annotations.first {
                    $0.userName == "KCDeepL Translation:\(line.id)"
                }
            )
            let expectedOverlayBounds = line.bounds
                .insetBy(dx: -1.5, dy: 0)
                .intersection(cropBox)
            assertEqual(mask.bounds, expectedOverlayBounds)
            assertEqual(overlay.bounds, expectedOverlayBounds)
            XCTAssertEqual(overlay.contents, "회전 번역")
            XCTAssertTrue(overlay.hasAppearanceStream)
            XCTAssertTrue(
                font(try XCTUnwrap(overlay.font), supports: "회전 번역")
            )
            let maskColor = try XCTUnwrap(
                mask.interiorColor?.usingColorSpace(.deviceRGB)
            )
            XCTAssertEqual(
                maskColor.blueComponent,
                line.backgroundColor.blue,
                accuracy: 0.02
            )
        }
    }

    func testQuarterTurnDigitalPageBakesCJKAppearanceAndPreservesURL() throws {
        let cropBox = CGRect(x: 20, y: 30, width: 560, height: 740)
        let bleedBox = CGRect(x: 22, y: 32, width: 556, height: 736)
        let trimBox = CGRect(x: 24, y: 34, width: 552, height: 732)
        let artBox = CGRect(x: 26, y: 36, width: 548, height: 728)
        let linkURL = try XCTUnwrap(
            URL(string: "https://example.com/quarter-turn")
        )

        for rotation in [90, 270] {
            let source = temporaryDirectory.appendingPathComponent(
                "quarter-turn-digital-\(rotation).pdf"
            )
            try makeDigitalPDF(
                at: source,
                pages: [[DrawnLine("Quarter turn", x: 80, y: 400, size: 18)]],
                rotations: [rotation],
                cropBoxes: [cropBox],
                bleedBoxes: [bleedBox],
                trimBoxes: [trimBox],
                artBoxes: [artBox],
                addPreservationAnnotations: true,
                links: [
                    LinkFixture(
                        bounds: CGRect(x: 76, y: 395, width: 130, height: 32),
                        url: linkURL
                    )
                ]
            )

            let analysis = try PDFDocumentAnalysisService().analyze(
                sourceURL: source
            )
            let line = try XCTUnwrap(analysis.pages.first?.lines.first)
            XCTAssertEqual(analysis.pages[0].mediaBox.minX, 0, accuracy: 0.05)
            XCTAssertEqual(analysis.pages[0].mediaBox.minY, 0, accuracy: 0.05)
            XCTAssertNoThrow(
                try PDFDocumentCompositionService().validateReadiness(
                    analysis: analysis
                )
            )

            let destination = temporaryDirectory.appendingPathComponent(
                "quarter-turn-output-\(rotation).pdf"
            )
            _ = try PDFDocumentCompositionService().compose(
                analysis: analysis,
                translations: [line.id: "회전 번역"],
                destinationURL: destination
            )
            try preserveCarrierQAFixtureIfRequested(
                sourceURL: source,
                translatedURL: destination,
                rotation: rotation
            )

            let output = try XCTUnwrap(PDFDocument(url: destination))
            XCTAssertEqual(output.pageCount, 1)
            let outputPage = try XCTUnwrap(output.page(at: 0))
            XCTAssertEqual(outputPage.rotation, rotation)
            assertEqual(outputPage.bounds(for: .cropBox), cropBox)
            assertEqual(outputPage.bounds(for: .bleedBox), bleedBox)
            assertEqual(outputPage.bounds(for: .trimBox), trimBox)
            assertEqual(outputPage.bounds(for: .artBox), artBox)

            let mask = try XCTUnwrap(
                outputPage.annotations.first {
                    $0.userName == "KCDeepL Mask:\(line.id)"
                }
            )
            let overlay = try XCTUnwrap(
                outputPage.annotations.first {
                    $0.userName == "KCDeepL Translation:\(line.id)"
                }
            )
            XCTAssertEqual(overlay.contents, "회전 번역")
            XCTAssertTrue(overlay.hasAppearanceStream)
            XCTAssertTrue(overlay.shouldDisplay)
            XCTAssertTrue(overlay.shouldPrint)
            XCTAssertTrue(
                font(try XCTUnwrap(overlay.font), supports: "회전 번역")
            )
            XCTAssertEqual((mask.action as? PDFActionURL)?.url, linkURL)
            XCTAssertEqual((overlay.action as? PDFActionURL)?.url, linkURL)
            XCTAssertTrue(
                outputPage.annotations.contains {
                    ($0.action as? PDFActionURL)?.url == linkURL
                        && $0.type?.trimmingCharacters(
                            in: CharacterSet(charactersIn: "/")
                        ) == "Link"
                }
            )
        }
    }

    func testNonzeroMediaBoxOriginFailsPreflightForEveryRightAngle() throws {
        let mediaBox = CGRect(x: 1, y: 2, width: 600, height: 800)

        for rotation in [0, 90, 180, 270] {
            let source = temporaryDirectory.appendingPathComponent(
                "nonzero-media-\(rotation).pdf"
            )
            try makeDigitalPDF(
                at: source,
                pages: [[DrawnLine("Media origin", x: 60, y: 700)]],
                rotations: [rotation],
                mediaBoxes: [mediaBox]
            )
            try replaceFirstASCII(
                in: source,
                matching: "/MediaBox [0 0 600 800]",
                with: "/MediaBox [1 2 601 802]"
            )
            let sourceData = try Data(contentsOf: source)
            let analysis = try PDFDocumentAnalysisService().analyze(
                sourceURL: source
            )
            let line = try XCTUnwrap(analysis.pages.first?.lines.first)
            let expectedError = PDFDocumentServiceError
                .nonzeroMediaBoxOriginUnsupported(
                    pageIndex: 0,
                    minX: mediaBox.minX,
                    minY: mediaBox.minY
                )

            XCTAssertThrowsError(
                try PDFDocumentCompositionService().validateReadiness(
                    analysis: analysis
                )
            ) { error in
                XCTAssertEqual(error as? PDFDocumentServiceError, expectedError)
            }

            let destination = temporaryDirectory.appendingPathComponent(
                "nonzero-media-output-\(rotation).pdf"
            )
            XCTAssertThrowsError(
                try PDFDocumentCompositionService().compose(
                    analysis: analysis,
                    translations: [line.id: "미디어 원점"],
                    destinationURL: destination
                )
            ) { error in
                XCTAssertEqual(error as? PDFDocumentServiceError, expectedError)
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: destination.path)
            )
            XCTAssertEqual(try Data(contentsOf: source), sourceData)
        }
    }

    func testUnsupportedPageRotationFailsBeforeComposition() throws {
        let source = temporaryDirectory.appendingPathComponent(
            "unsupported-rotation.pdf"
        )
        try makeDigitalPDF(
            at: source,
            pages: [[DrawnLine("Malformed rotation", x: 60, y: 700)]],
            rotations: [90]
        )
        try replaceFirstASCII(
            in: source,
            matching: "/Rotate 90",
            with: "/Rotate 45"
        )
        let sourceData = try Data(contentsOf: source)
        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let line = try XCTUnwrap(analysis.pages.first?.lines.first)
        let expectedError = PDFDocumentServiceError.unsupportedPageRotation(
            pageIndex: 0,
            rotation: 45
        )

        XCTAssertThrowsError(
            try PDFDocumentCompositionService().validateReadiness(
                analysis: analysis
            )
        ) { error in
            XCTAssertEqual(error as? PDFDocumentServiceError, expectedError)
        }
        XCTAssertThrowsError(
            try PDFDocumentCompositionService().validateReadiness(
                analysis: analysis,
                policy: .bestEffort
            )
        ) { error in
            XCTAssertEqual(error as? PDFDocumentServiceError, expectedError)
        }

        let destination = temporaryDirectory.appendingPathComponent(
            "unsupported-rotation-output.pdf"
        )
        XCTAssertThrowsError(
            try PDFDocumentCompositionService().compose(
                analysis: analysis,
                translations: [line.id: "잘못된 회전"],
                destinationURL: destination
            )
        ) { error in
            XCTAssertEqual(error as? PDFDocumentServiceError, expectedError)
        }
        XCTAssertThrowsError(
            try PDFDocumentCompositionService().compose(
                analysis: analysis,
                translations: [line.id: "잘못된 회전"],
                destinationURL: destination,
                policy: .bestEffort
            )
        ) { error in
            XCTAssertEqual(error as? PDFDocumentServiceError, expectedError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), sourceData)
    }

    func testComposePreservesPageGeometryAnnotationsAndColoredBackground() throws {
        let source = temporaryDirectory.appendingPathComponent("styled-source.pdf")
        let sourceLinkURL = try XCTUnwrap(URL(string: "https://example.com/manual"))
        let sourceLinkBounds = CGRect(x: 58, y: 702, width: 48, height: 27)
        let blue = NSColor(
            calibratedRed: 0.16,
            green: 0.48,
            blue: 0.78,
            alpha: 1
        )
        try makeDigitalPDF(
            at: source,
            pages: [
                [DrawnLine("Hello", x: 60, y: 705, color: .white, size: 18)],
                [DrawnLine("Second", x: 70, y: 680, size: 16)]
            ],
            fillsByPage: [[ColoredRect(
                CGRect(x: 35, y: 675, width: 260, height: 70),
                color: blue
            )], []],
            rotations: [0, 180],
            cropBoxes: [
                CGRect(x: 10, y: 10, width: 580, height: 770),
                CGRect(x: 20, y: 20, width: 560, height: 750)
            ],
            bleedBoxes: [
                CGRect(x: 12, y: 12, width: 576, height: 766),
                CGRect(x: 22, y: 22, width: 556, height: 746)
            ],
            trimBoxes: [
                CGRect(x: 14, y: 14, width: 572, height: 762),
                CGRect(x: 24, y: 24, width: 552, height: 742)
            ],
            artBoxes: [
                CGRect(x: 16, y: 16, width: 568, height: 758),
                CGRect(x: 26, y: 26, width: 548, height: 738)
            ],
            addPreservationAnnotations: true,
            links: [LinkFixture(bounds: sourceLinkBounds, url: sourceLinkURL)]
        )
        let sourceDocument = try XCTUnwrap(PDFDocument(url: source))
        let originalAnnotationCounts = (0..<sourceDocument.pageCount).map {
            sourceDocument.page(at: $0)?.annotations.count ?? 0
        }
        let sourceFirstPage = try XCTUnwrap(sourceDocument.page(at: 0))
        let sourceNote = try XCTUnwrap(
            sourceFirstPage.annotations.first {
                $0.userName == "existing-note"
            }
        )
        let sourceLink = try XCTUnwrap(
            sourceFirstPage.annotations.first {
                ($0.action as? PDFActionURL)?.url == sourceLinkURL
            }
        )
        let preservedLinkURL = try XCTUnwrap(
            URL(string: "https://example.com/preserved-appearance")
        )
        let sourceStyledLink = try XCTUnwrap(
            sourceFirstPage.annotations.first {
                ($0.action as? PDFActionURL)?.url == preservedLinkURL
            }
        )

        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let firstLine = try XCTUnwrap(analysis.pages.first?.lines.first)
        XCTAssertLessThan(firstLine.backgroundColor.red, 0.55)
        XCTAssertGreaterThan(
            firstLine.backgroundColor.blue,
            firstLine.backgroundColor.red + 0.25
        )
        XCTAssertGreaterThan(
            firstLine.backgroundColor.green,
            firstLine.backgroundColor.red + 0.15
        )
        XCTAssertFalse(
            analysis.pages[1].warnings.contains {
                if case .backgroundSamplingUnavailable = $0 { return true }
                return false
            }
        )
        XCTAssertTrue(
            analysis.pages[0].warnings.contains {
                if case let .linkOverlap(pageIndex, lineID, target) = $0 {
                    return pageIndex == 0
                        && lineID == firstLine.id
                        && target == sourceLinkURL.absoluteString
                }
                return false
            }
        )

        let translations = Dictionary(
            uniqueKeysWithValues: analysis.pages.flatMap(\.lines).map { line in
                (line.id, line.text == "Hello" ? "안녕" : "둘")
            }
        )
        let destination = temporaryDirectory.appendingPathComponent("translated.pdf")
        XCTAssertNoThrow(
            try PDFDocumentCompositionService().validateReadiness(
                analysis: analysis
            )
        )
        let result = try PDFDocumentCompositionService().compose(
            analysis: analysis,
            translations: translations,
            destinationURL: destination
        )
        try preserveQAFixtureIfRequested(
            sourceURL: source,
            translatedURL: destination
        )

        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.translatedLineCount, analysis.translatableLineCount)
        let output = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(output.pageCount, sourceDocument.pageCount)

        for pageIndex in 0..<output.pageCount {
            let sourcePage = try XCTUnwrap(sourceDocument.page(at: pageIndex))
            let outputPage = try XCTUnwrap(output.page(at: pageIndex))
            assertEqual(
                sourcePage.bounds(for: .mediaBox),
                outputPage.bounds(for: .mediaBox)
            )
            assertEqual(
                sourcePage.bounds(for: .cropBox),
                outputPage.bounds(for: .cropBox)
            )
            assertEqual(
                sourcePage.bounds(for: .bleedBox),
                outputPage.bounds(for: .bleedBox)
            )
            assertEqual(
                sourcePage.bounds(for: .trimBox),
                outputPage.bounds(for: .trimBox)
            )
            assertEqual(
                sourcePage.bounds(for: .artBox),
                outputPage.bounds(for: .artBox)
            )
            assertEqual(
                sourcePage.bounds(for: .bleedBox),
                analysis.pages[pageIndex].bleedBox
            )
            assertEqual(
                sourcePage.bounds(for: .trimBox),
                analysis.pages[pageIndex].trimBox
            )
            assertEqual(
                sourcePage.bounds(for: .artBox),
                analysis.pages[pageIndex].artBox
            )
            XCTAssertEqual(sourcePage.rotation, outputPage.rotation)
            XCTAssertGreaterThanOrEqual(
                outputPage.annotations.count,
                originalAnnotationCounts[pageIndex]
                    + analysis.pages[pageIndex].lines.count * 2
            )
        }

        let firstOutputPage = try XCTUnwrap(output.page(at: 0))
        let outputNote = try XCTUnwrap(
            firstOutputPage.annotations.first {
                $0.contents == "keep-me" && $0.userName == "existing-note"
            }
        )
        let outputLink = try XCTUnwrap(
            firstOutputPage.annotations.first {
                ($0.action as? PDFActionURL)?.url == sourceLinkURL
            }
        )
        let outputStyledLink = try XCTUnwrap(
            firstOutputPage.annotations.first {
                ($0.action as? PDFActionURL)?.url == preservedLinkURL
            }
        )
        assertEqual(outputLink.bounds, sourceLinkBounds)
        assertAnnotationAppearance(sourceNote, outputNote)
        assertAnnotationAppearance(sourceLink, outputLink)
        assertAnnotationAppearance(sourceStyledLink, outputStyledLink)
        XCTAssertEqual(
            (outputLink.action as? PDFActionURL)?.url,
            sourceLinkURL
        )
        let mask = try XCTUnwrap(
            firstOutputPage.annotations.first {
                $0.userName == "KCDeepL Mask:\(firstLine.id)"
            }
        )
        let maskColor = try XCTUnwrap(mask.interiorColor?.usingColorSpace(.deviceRGB))
        let expectedOverlayBounds = firstLine.bounds
            .insetBy(dx: -1.5, dy: 0)
            .intersection(analysis.pages[0].cropBox)
        assertEqual(mask.bounds, expectedOverlayBounds)
        XCTAssertTrue(mask.shouldDisplay)
        XCTAssertTrue(mask.shouldPrint)
        XCTAssertEqual((mask.action as? PDFActionURL)?.url, sourceLinkURL)
        XCTAssertEqual(
            maskColor.redComponent,
            firstLine.backgroundColor.red,
            accuracy: 0.02
        )
        XCTAssertEqual(
            maskColor.greenComponent,
            firstLine.backgroundColor.green,
            accuracy: 0.02
        )
        XCTAssertEqual(
            maskColor.blueComponent,
            firstLine.backgroundColor.blue,
            accuracy: 0.02
        )
        XCTAssertTrue(
            firstOutputPage.annotations.contains {
                $0.userName == "KCDeepL Translation:\(firstLine.id)"
                    && $0.contents == "안녕"
            }
        )
        let cjkOverlay = try XCTUnwrap(
            firstOutputPage.annotations.first {
                $0.userName == "KCDeepL Translation:\(firstLine.id)"
            }
        )
        let cjkFont = try XCTUnwrap(cjkOverlay.font)
        XCTAssertTrue(font(cjkFont, supports: "안녕"))
        assertEqual(cjkOverlay.bounds, expectedOverlayBounds)
        XCTAssertTrue(cjkOverlay.shouldDisplay)
        XCTAssertTrue(cjkOverlay.shouldPrint)
        switch firstLine.alignment {
        case .left:
            XCTAssertEqual(cjkOverlay.alignment, .left)
        case .center:
            XCTAssertEqual(cjkOverlay.alignment, .center)
        case .right:
            XCTAssertEqual(cjkOverlay.alignment, .right)
        }
        let overlayColor = try XCTUnwrap(
            cjkOverlay.fontColor?.usingColorSpace(.deviceRGB)
        )
        XCTAssertEqual(
            overlayColor.redComponent,
            firstLine.textColor.red,
            accuracy: 0.02
        )
        XCTAssertEqual(
            overlayColor.greenComponent,
            firstLine.textColor.green,
            accuracy: 0.02
        )
        XCTAssertEqual(
            overlayColor.blueComponent,
            firstLine.textColor.blue,
            accuracy: 0.02
        )
        XCTAssertEqual((cjkOverlay.action as? PDFActionURL)?.url, sourceLinkURL)
    }

    func testComposePersistsBundledLatinAndKoreanFontIdentityAndGlyphs() throws {
        let source = temporaryDirectory.appendingPathComponent("font-source.pdf")
        try makeDigitalPDF(
            at: source,
            pages: [
                [DrawnLine("English source", x: 60, y: 700, size: 18)],
                [DrawnLine("Korean source", x: 60, y: 700, size: 18)]
            ]
        )
        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let latinLine = try XCTUnwrap(analysis.pages[0].lines.first)
        let koreanLine = try XCTUnwrap(analysis.pages[1].lines.first)
        XCTAssertTrue(latinLine.fontName.hasPrefix("."))
        XCTAssertTrue(koreanLine.fontName.hasPrefix("."))
        let destination = temporaryDirectory.appendingPathComponent("font-output.pdf")

        _ = try PDFDocumentCompositionService().compose(
            analysis: analysis,
            translations: [
                latinLine.id: "Translated output",
                koreanLine.id: "번역 결과"
            ],
            destinationURL: destination
        )

        let firstOpen = try XCTUnwrap(PDFDocument(url: destination))
        try assertTranslationFont(
            in: firstOpen,
            pageIndex: 0,
            lineID: latinLine.id,
            text: "Translated output",
            expectedPostScriptName: AppFont.barlowRegular
        )
        try assertTranslationFont(
            in: firstOpen,
            pageIndex: 1,
            lineID: koreanLine.id,
            text: "번역 결과",
            expectedPostScriptName: AppFont.notoSansKRRegular
        )

        let secondOpen = try XCTUnwrap(
            firstOpen.dataRepresentation().flatMap(PDFDocument.init(data:))
        )
        try assertTranslationFont(
            in: secondOpen,
            pageIndex: 0,
            lineID: latinLine.id,
            text: "Translated output",
            expectedPostScriptName: AppFont.barlowRegular
        )
        try assertTranslationFont(
            in: secondOpen,
            pageIndex: 1,
            lineID: koreanLine.id,
            text: "번역 결과",
            expectedPostScriptName: AppFont.notoSansKRRegular
        )
    }

    func testComposePreservesSupportedPublicSourceFontBeforeBundledFallbacks() throws {
        let source = temporaryDirectory.appendingPathComponent("public-font-source.pdf")
        try makeDigitalPDF(
            at: source,
            pages: [[
                DrawnLine(
                    "Public source",
                    x: 60,
                    y: 700,
                    size: 18,
                    fontName: "Helvetica"
                )
            ]]
        )
        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let line = try XCTUnwrap(analysis.pages.first?.lines.first)
        XCTAssertEqual(line.fontName, "Helvetica")
        let destination = temporaryDirectory.appendingPathComponent("public-font-output.pdf")

        _ = try PDFDocumentCompositionService().compose(
            analysis: analysis,
            translations: [line.id: "Public translation"],
            destinationURL: destination
        )

        let output = try XCTUnwrap(PDFDocument(url: destination))
        try assertTranslationFont(
            in: output,
            pageIndex: 0,
            lineID: line.id,
            text: "Public translation",
            expectedPostScriptName: "Helvetica"
        )
    }

    func testComposeUsesD2CodingForFixedPitchSourceNeedingKoreanGlyphs() throws {
        let source = temporaryDirectory.appendingPathComponent("fixed-font-source.pdf")
        try makeDigitalPDF(
            at: source,
            pages: [[
                DrawnLine(
                    "Fixed source",
                    x: 60,
                    y: 700,
                    size: 18,
                    fontName: "Courier"
                )
            ]]
        )
        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let line = try XCTUnwrap(analysis.pages.first?.lines.first)
        XCTAssertEqual(line.fontName, "Courier")
        let destination = temporaryDirectory.appendingPathComponent("fixed-font-output.pdf")

        _ = try PDFDocumentCompositionService().compose(
            analysis: analysis,
            translations: [line.id: "고정폭 번역"],
            destinationURL: destination
        )

        let output = try XCTUnwrap(PDFDocument(url: destination))
        try assertTranslationFont(
            in: output,
            pageIndex: 0,
            lineID: line.id,
            text: "고정폭 번역",
            expectedPostScriptName: AppFont.d2CodingRegular
        )
    }

    func testComposePreservesExistingCustomAppearanceStream() throws {
        let source = temporaryDirectory.appendingPathComponent(
            "custom-appearance-source.pdf"
        )
        try makeDigitalPDF(
            at: source,
            pages: [[DrawnLine("Appearance source", x: 60, y: 700)]],
            addPreservationAnnotations: true
        )

        let sourceDocument = try XCTUnwrap(PDFDocument(url: source))
        let sourcePage = try XCTUnwrap(sourceDocument.page(at: 0))
        let sourceAppearance = try XCTUnwrap(
            sourcePage.annotations.first {
                $0.userName == "existing-custom-appearance"
            }
        )
        XCTAssertTrue(sourceAppearance.hasAppearanceStream)

        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let line = try XCTUnwrap(analysis.pages.first?.lines.first)
        let destination = temporaryDirectory.appendingPathComponent(
            "custom-appearance-output.pdf"
        )
        _ = try PDFDocumentCompositionService().compose(
            analysis: analysis,
            translations: [line.id: "Translated"],
            destinationURL: destination
        )

        let outputDocument = try XCTUnwrap(PDFDocument(url: destination))
        let outputPage = try XCTUnwrap(outputDocument.page(at: 0))
        let outputAppearance = try XCTUnwrap(
            outputPage.annotations.first {
                $0.userName == "existing-custom-appearance"
            }
        )
        XCTAssertTrue(outputAppearance.hasAppearanceStream)
        XCTAssertEqual(outputAppearance.contents, sourceAppearance.contents)
        assertEqual(outputAppearance.bounds, sourceAppearance.bounds)
        assertAnnotationAppearance(sourceAppearance, outputAppearance)
    }

    func testComposeRejectsOverlappingLinksThatCannotBecomeOneURL() throws {
        let overlapBounds = CGRect(x: 48, y: 698, width: 100, height: 28)
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/one"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/two"))

        for fixture in ["named", "multiple"] {
            let source = temporaryDirectory.appendingPathComponent(
                "unsupported-link-\(fixture).pdf"
            )
            try makeDigitalPDF(
                at: source,
                pages: [[DrawnLine("Linked text", x: 50, y: 700)]],
                links: fixture == "multiple"
                    ? [
                        LinkFixture(bounds: overlapBounds, url: firstURL),
                        LinkFixture(bounds: overlapBounds, url: secondURL)
                    ]
                    : [],
                namedLinkBounds: fixture == "named" ? overlapBounds : nil
            )
            let analysis = try PDFDocumentAnalysisService().analyze(
                sourceURL: source
            )
            let line = try XCTUnwrap(analysis.pages.first?.lines.first)
            let destination = temporaryDirectory.appendingPathComponent(
                "unsupported-link-\(fixture)-output.pdf"
            )

            XCTAssertThrowsError(
                try PDFDocumentCompositionService().validateReadiness(
                    analysis: analysis
                )
            ) { error in
                XCTAssertEqual(
                    error as? PDFDocumentServiceError,
                    .unsupportedOverlappingLink(
                        pageIndex: 0,
                        lineID: line.id
                    )
                )
            }

            XCTAssertThrowsError(
                try PDFDocumentCompositionService().compose(
                    analysis: analysis,
                    translations: [line.id: "Translated"],
                    destinationURL: destination
                )
            ) { error in
                XCTAssertEqual(
                    error as? PDFDocumentServiceError,
                    .unsupportedOverlappingLink(
                        pageIndex: 0,
                        lineID: line.id
                    )
                )
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: destination.path)
            )
        }

        let edgeSource = temporaryDirectory.appendingPathComponent(
            "unsupported-link-edge.pdf"
        )
        try makeDigitalPDF(
            at: edgeSource,
            pages: [[DrawnLine("Edge link", x: 50, y: 700)]]
        )
        let edgeDocument = try XCTUnwrap(PDFDocument(url: edgeSource))
        let edgePage = try XCTUnwrap(edgeDocument.page(at: 0))
        let selection = try XCTUnwrap(
            edgePage.selection(for: edgePage.bounds(for: .cropBox))
        )
        let sourceLineBounds = try XCTUnwrap(
            selection.selectionsByLine().first?.bounds(for: edgePage)
        )
        let edgeLink = PDFAnnotation(
            bounds: CGRect(
                x: sourceLineBounds.maxX + 0.25,
                y: sourceLineBounds.midY - 2,
                width: 10,
                height: 4
            ),
            forType: .link,
            withProperties: nil
        )
        edgeLink.action = PDFActionNamed(name: .nextPage)
        edgePage.addAnnotation(edgeLink)
        try XCTUnwrap(edgeDocument.dataRepresentation()).write(
            to: edgeSource,
            options: .atomic
        )

        let edgeAnalysis = try PDFDocumentAnalysisService().analyze(
            sourceURL: edgeSource
        )
        let edgeLine = try XCTUnwrap(edgeAnalysis.pages.first?.lines.first)
        XCTAssertFalse(
            edgeAnalysis.pages[0].warnings.contains {
                if case .linkOverlap = $0 { return true }
                return false
            }
        )
        let edgeDestination = temporaryDirectory.appendingPathComponent(
            "unsupported-link-edge-output.pdf"
        )
        XCTAssertThrowsError(
            try PDFDocumentCompositionService().validateReadiness(
                analysis: edgeAnalysis
            )
        ) { error in
            XCTAssertEqual(
                error as? PDFDocumentServiceError,
                .unsupportedOverlappingLink(pageIndex: 0, lineID: edgeLine.id)
            )
        }
        XCTAssertThrowsError(
            try PDFDocumentCompositionService().compose(
                analysis: edgeAnalysis,
                translations: [edgeLine.id: "Translated"],
                destinationURL: edgeDestination
            )
        ) { error in
            XCTAssertEqual(
                error as? PDFDocumentServiceError,
                .unsupportedOverlappingLink(pageIndex: 0, lineID: edgeLine.id)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: edgeDestination.path)
        )
    }

    func testComposeRejectsAnnotationTouchingExpandedOverlay() throws {
        let source = temporaryDirectory.appendingPathComponent(
            "overlapping-highlight.pdf"
        )
        try makeDigitalPDF(
            at: source,
            pages: [[DrawnLine("Annotated", x: 50, y: 700)]]
        )
        let sourceDocument = try XCTUnwrap(PDFDocument(url: source))
        let sourcePage = try XCTUnwrap(sourceDocument.page(at: 0))
        let selection = try XCTUnwrap(
            sourcePage.selection(for: sourcePage.bounds(for: .cropBox))
        )
        let sourceLineBounds = try XCTUnwrap(
            selection.selectionsByLine().first?.bounds(for: sourcePage)
        )
        let highlight = PDFAnnotation(
            bounds: CGRect(
                x: sourceLineBounds.maxX + 0.25,
                y: sourceLineBounds.midY - 2,
                width: 1,
                height: 4
            ),
            forType: .highlight,
            withProperties: nil
        )
        highlight.color = NSColor(
            deviceRed: 0.95,
            green: 0.75,
            blue: 0.1,
            alpha: 1
        )
        highlight.shouldDisplay = true
        highlight.shouldPrint = true
        sourcePage.addAnnotation(highlight)
        try XCTUnwrap(sourceDocument.dataRepresentation()).write(
            to: source,
            options: .atomic
        )

        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let line = try XCTUnwrap(analysis.pages.first?.lines.first)
        XCTAssertFalse(line.bounds.intersects(highlight.bounds))
        let expectedError = PDFDocumentServiceError
            .unsupportedOverlappingAnnotation(
                pageIndex: 0,
                lineID: line.id,
                annotationType: "Highlight"
            )
        XCTAssertThrowsError(
            try PDFDocumentCompositionService().validateReadiness(
                analysis: analysis
            )
        ) { error in
            XCTAssertEqual(error as? PDFDocumentServiceError, expectedError)
        }

        let destination = temporaryDirectory.appendingPathComponent(
            "overlapping-highlight-output.pdf"
        )
        XCTAssertThrowsError(
            try PDFDocumentCompositionService().compose(
                analysis: analysis,
                translations: [line.id: "번역"],
                destinationURL: destination
            )
        ) { error in
            XCTAssertEqual(error as? PDFDocumentServiceError, expectedError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testComposeRejectsComplexBackgroundWithoutOutput() throws {
        let source = temporaryDirectory.appendingPathComponent(
            "complex-background.pdf"
        )
        let stripes = (0..<18).map { index in
            ColoredRect(
                CGRect(
                    x: 40 + CGFloat(index * 10),
                    y: 690,
                    width: 10,
                    height: 45
                ),
                color: index.isMultiple(of: 2) ? .black : .white
            )
        }
        try makeDigitalPDF(
            at: source,
            pages: [[DrawnLine("Complex", x: 50, y: 700, color: .red)]],
            fillsByPage: [stripes]
        )
        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let line = try XCTUnwrap(analysis.pages.first?.lines.first)
        XCTAssertTrue(
            analysis.pages[0].warnings.contains(
                .complexBackground(pageIndex: 0, lineID: line.id)
            )
        )

        let destination = temporaryDirectory.appendingPathComponent(
            "complex-background-output.pdf"
        )
        XCTAssertThrowsError(
            try PDFDocumentCompositionService().validateReadiness(
                analysis: analysis
            )
        ) { error in
            XCTAssertEqual(
                error as? PDFDocumentServiceError,
                .backgroundCannotBePreserved(pageIndex: 0, lineID: line.id)
            )
        }
        XCTAssertThrowsError(
            try PDFDocumentCompositionService().compose(
                analysis: analysis,
                translations: [line.id: "Translated"],
                destinationURL: destination
            )
        ) { error in
            XCTAssertEqual(
                error as? PDFDocumentServiceError,
                .backgroundCannotBePreserved(pageIndex: 0, lineID: line.id)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let result = try PDFDocumentCompositionService().compose(
            analysis: analysis,
            translations: [line.id: "Translated"],
            destinationURL: destination,
            policy: .bestEffort
        )
        XCTAssertEqual(result.translatedLineCount, 0)
        XCTAssertTrue(
            result.warnings.contains {
                if case let .bestEffortLineSkipped(pageIndex, lineID, _) = $0 {
                    return pageIndex == 0 && lineID == line.id
                }
                return false
            }
        )
        let output = try XCTUnwrap(PDFDocument(url: destination))
        let outputPage = try XCTUnwrap(output.page(at: 0))
        XCTAssertTrue((outputPage.string ?? "").contains("Complex"))
        XCTAssertFalse(
            outputPage.annotations.contains {
                ($0.userName ?? "").hasPrefix("KCDeepL ")
            }
        )
    }

    func testAdjacentLightTextOnUniformDarkPanelIsNotAComplexBackground() throws {
        let source = temporaryDirectory.appendingPathComponent(
            "uniform-dark-panel.pdf"
        )
        let panelColor = NSColor(
            deviceRed: 0.294,
            green: 0.294,
            blue: 0.294,
            alpha: 1
        )
        try makeDigitalPDF(
            at: source,
            pages: [[
                DrawnLine("Multi asset work orders", x: 60, y: 710, color: .white, size: 18),
                DrawnLine("I'm managing too many", x: 60, y: 698, color: .white, size: 18),
                DrawnLine("orders and it's causing", x: 60, y: 686, color: .white, size: 18),
                DrawnLine("confusion. I can't group", x: 60, y: 674, color: .white, size: 18)
            ]],
            fillsByPage: [[
                ColoredRect(
                    CGRect(x: 55, y: 625, width: 250, height: 125),
                    color: panelColor
                )
            ]]
        )

        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let page = try XCTUnwrap(analysis.pages.first)
        XCTAssertFalse(page.lines.isEmpty)
        XCTAssertFalse(
            page.warnings.contains {
                if case .complexBackground = $0 { return true }
                return false
            },
            page.warnings.map(\.message).joined(separator: "\n")
        )
        XCTAssertNoThrow(
            try PDFDocumentCompositionService().validateReadiness(
                analysis: analysis
            )
        )
    }

    func testForegroundLikeSolidAccentStillCountsAsComplexBackground() throws {
        let source = temporaryDirectory.appendingPathComponent(
            "foreground-like-accent.pdf"
        )
        let accent = NSColor(
            deviceRed: 0.12,
            green: 0.12,
            blue: 0.12,
            alpha: 1
        )
        try makeDigitalPDF(
            at: source,
            pages: [[
                DrawnLine(
                    "Foreground-like accent region",
                    x: 50,
                    y: 700,
                    size: 18
                )
            ]],
            fillsByPage: [[
                ColoredRect(
                    CGRect(x: 115, y: 690, width: 185, height: 45),
                    color: accent
                )
            ]]
        )

        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let line = try XCTUnwrap(analysis.pages.first?.lines.first)

        XCTAssertTrue(
            analysis.warnings.contains(
                .complexBackground(pageIndex: 0, lineID: line.id)
            )
        )
    }

    func testMaskBoundsTrimForegroundColoredAreaOutsideShapeEdge() throws {
        let source = temporaryDirectory.appendingPathComponent(
            "shape-edge-mask.pdf"
        )
        let red = NSColor(
            deviceRed: 0.804,
            green: 0.086,
            blue: 0.247,
            alpha: 1
        )
        let shapeMaxY: CGFloat = 715
        try makeDigitalPDF(
            at: source,
            pages: [[
                DrawnLine(
                    "Who should I contact for more information?",
                    x: 60,
                    y: 695,
                    color: .white,
                    size: 18
                )
            ]],
            fillsByPage: [[
                ColoredRect(
                    CGRect(x: 40, y: 670, width: 520, height: 45),
                    color: red
                )
            ]]
        )

        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let line = try XCTUnwrap(analysis.pages.first?.lines.first)

        XCTAssertFalse(
            analysis.warnings.contains {
                if case .complexBackground = $0 { return true }
                return false
            }
        )
        XCTAssertLessThanOrEqual(line.sourceMaskBounds.maxY, shapeMaxY + 0.6)
        XCTAssertGreaterThanOrEqual(line.sourceMaskBounds.minY, 670)
        XCTAssertNoThrow(
            try PDFDocumentCompositionService().validateReadiness(
                analysis: analysis
            )
        )
    }

    func testComposeAddsEveryMaskBeforeAnyTranslation() throws {
        let source = temporaryDirectory.appendingPathComponent(
            "annotation-z-order.pdf"
        )
        try makeDigitalPDF(
            at: source,
            pages: [[
                DrawnLine("First source", x: 50, y: 700, size: 18),
                DrawnLine("Second source", x: 50, y: 675, size: 18)
            ]]
        )
        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let lines = try XCTUnwrap(analysis.pages.first).lines
        XCTAssertEqual(lines.count, 2)
        let destination = temporaryDirectory.appendingPathComponent(
            "annotation-z-order-output.pdf"
        )
        _ = try PDFDocumentCompositionService().compose(
            analysis: analysis,
            translations: Dictionary(
                uniqueKeysWithValues: lines.map { ($0.id, "번역") }
            ),
            destinationURL: destination
        )

        let output = try XCTUnwrap(PDFDocument(url: destination))
        let page = try XCTUnwrap(output.page(at: 0))
        let generatedNames = page.annotations.compactMap(\.userName).filter {
            $0.hasPrefix("KCDeepL Mask:")
                || $0.hasPrefix("KCDeepL Translation:")
        }
        let lastMaskIndex = try XCTUnwrap(
            generatedNames.lastIndex { $0.hasPrefix("KCDeepL Mask:") }
        )
        let firstTranslationIndex = try XCTUnwrap(
            generatedNames.firstIndex {
                $0.hasPrefix("KCDeepL Translation:")
            }
        )
        XCTAssertLessThan(lastMaskIndex, firstTranslationIndex)
    }

    func testComposeRejectsMissingOrOverflowingTranslationWithoutOutput() throws {
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        try makeDigitalPDF(
            at: source,
            pages: [[DrawnLine("Short", x: 50, y: 700, size: 12)]]
        )
        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let line = try XCTUnwrap(analysis.pages.first?.lines.first)
        let missingDestination = temporaryDirectory.appendingPathComponent("missing.pdf")

        XCTAssertThrowsError(
            try PDFDocumentCompositionService().compose(
                analysis: analysis,
                translations: [:],
                destinationURL: missingDestination
            )
        ) { error in
            XCTAssertEqual(
                error as? PDFDocumentServiceError,
                .missingTranslation(pageIndex: 0, lineID: line.id)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDestination.path))

        let overflowDestination = temporaryDirectory.appendingPathComponent("overflow.pdf")
        let oversized = String(repeating: "unreasonably-long-translation ", count: 100)
        XCTAssertThrowsError(
            try PDFDocumentCompositionService().compose(
                analysis: analysis,
                translations: [line.id: oversized],
                destinationURL: overflowDestination
            )
        ) { error in
            guard case .textDoesNotFit(pageIndex: 0, lineID: line.id, minimumFontSize: 5)
                = error as? PDFDocumentServiceError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: overflowDestination.path))
    }

    func testComposeNeverOverwritesSourceOrExistingDestination() throws {
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        try makeDigitalPDF(
            at: source,
            pages: [[DrawnLine("Hello", x: 50, y: 700)]]
        )
        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let line = try XCTUnwrap(analysis.pages.first?.lines.first)
        let translations = [line.id: "Hi"]

        XCTAssertThrowsError(
            try PDFDocumentCompositionService().compose(
                analysis: analysis,
                translations: translations,
                destinationURL: source
            )
        ) { error in
            XCTAssertEqual(
                error as? PDFDocumentServiceError,
                .sourceAndDestinationMatch
            )
        }

        let existing = temporaryDirectory.appendingPathComponent("existing.pdf")
        let sentinel = Data("do-not-overwrite".utf8)
        try sentinel.write(to: existing)
        XCTAssertThrowsError(
            try PDFDocumentCompositionService().compose(
                analysis: analysis,
                translations: translations,
                destinationURL: existing
            )
        ) { error in
            XCTAssertEqual(
                error as? PDFDocumentServiceError,
                .destinationAlreadyExists
            )
        }
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
    }

    func testAnalyzeAndComposePreserveCenteredAndRightAlignment() throws {
        let source = temporaryDirectory.appendingPathComponent("alignment.pdf")
        let font = NSFont.systemFont(ofSize: 18)
        let centeredText = "Centered heading"
        let rightText = "Right value"
        let centeredWidth = (centeredText as NSString).size(
            withAttributes: [.font: font]
        ).width
        let rightWidth = (rightText as NSString).size(
            withAttributes: [.font: font]
        ).width
        try makeDigitalPDF(
            at: source,
            pages: [
                [DrawnLine(
                    centeredText,
                    x: (600 - centeredWidth) / 2,
                    y: 700,
                    size: 18
                )],
                [DrawnLine(
                    rightText,
                    x: 590 - rightWidth,
                    y: 700,
                    size: 18
                )]
            ]
        )

        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let centeredLine = try XCTUnwrap(analysis.pages[0].lines.first)
        let rightLine = try XCTUnwrap(analysis.pages[1].lines.first)
        XCTAssertEqual(centeredLine.alignment, .center)
        XCTAssertEqual(rightLine.alignment, .right)

        let destination = temporaryDirectory.appendingPathComponent("aligned-output.pdf")
        _ = try PDFDocumentCompositionService().compose(
            analysis: analysis,
            translations: [
                centeredLine.id: "Centered",
                rightLine.id: "Right"
            ],
            destinationURL: destination
        )
        let output = try XCTUnwrap(PDFDocument(url: destination))
        let centeredOverlay = try XCTUnwrap(
            output.page(at: 0)?.annotations.first {
                $0.userName == "KCDeepL Translation:\(centeredLine.id)"
            }
        )
        let rightOverlay = try XCTUnwrap(
            output.page(at: 1)?.annotations.first {
                $0.userName == "KCDeepL Translation:\(rightLine.id)"
            }
        )
        XCTAssertEqual(centeredOverlay.alignment, .center)
        XCTAssertEqual(rightOverlay.alignment, .right)
    }

    func testAnalyzeRejectsLockedDocument() throws {
        let unlocked = temporaryDirectory.appendingPathComponent("unlocked.pdf")
        try makeDigitalPDF(
            at: unlocked,
            pages: [[DrawnLine("Secret", x: 50, y: 700)]]
        )
        let document = try XCTUnwrap(PDFDocument(url: unlocked))
        let ownerKey = PDFDocumentWriteOption.ownerPasswordOption
        let userKey = PDFDocumentWriteOption.userPasswordOption
        let options: [AnyHashable: Any] = [
            ownerKey: "owner-password",
            userKey: "user-password"
        ]
        let lockedData = try XCTUnwrap(document.dataRepresentation(options: options))
        let locked = temporaryDirectory.appendingPathComponent("locked.pdf")
        try lockedData.write(to: locked)

        XCTAssertThrowsError(
            try PDFDocumentAnalysisService().analyze(sourceURL: locked)
        ) { error in
            XCTAssertEqual(error as? PDFDocumentServiceError, .lockedDocument)
        }
    }

    func testAnalyzeRejectsInteractiveFormsInsteadOfDamagingAppearance() throws {
        let source = temporaryDirectory.appendingPathComponent("form.pdf")
        try makeDigitalPDF(
            at: source,
            pages: [[DrawnLine("Form", x: 40, y: 720)]],
            addFormWidget: true
        )

        XCTAssertThrowsError(
            try PDFDocumentAnalysisService().analyze(sourceURL: source)
        ) { error in
            XCTAssertEqual(
                error as? PDFDocumentServiceError,
                .interactiveFormsUnsupported
            )
        }
    }

    func testAnalyzeRejectsCatalogFormTokensWithoutPageWidget() throws {
        for token in ["/AcroForm", "/XFA"] {
            let source = temporaryDirectory.appendingPathComponent(
                "catalog-form-\(token.dropFirst()).pdf"
            )
            try makeDigitalPDF(
                at: source,
                pages: [[DrawnLine("Hidden form", x: 40, y: 720)]]
            )
            var data = try Data(contentsOf: source)
            data.append(contentsOf: "\n% \(token) catalog fixture\n".utf8)
            try data.write(to: source, options: .atomic)

            XCTAssertThrowsError(
                try PDFDocumentAnalysisService().analyze(sourceURL: source)
            ) { error in
                XCTAssertEqual(
                    error as? PDFDocumentServiceError,
                    .interactiveFormsUnsupported
                )
            }
        }
    }

    func testAnalysisAndCompositionHonorTaskCancellation() async throws {
        let source = temporaryDirectory.appendingPathComponent("cancel-source.pdf")
        try makeDigitalPDF(
            at: source,
            pages: [[DrawnLine("Cancel me", x: 50, y: 700)]]
        )

        let analysisTask = Task {
            while !Task.isCancelled { await Task.yield() }
            return try PDFDocumentAnalysisService().analyze(sourceURL: source)
        }
        analysisTask.cancel()
        do {
            _ = try await analysisTask.value
            XCTFail("Cancelled analysis unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }

        let analysis = try PDFDocumentAnalysisService().analyze(sourceURL: source)
        let line = try XCTUnwrap(analysis.pages.first?.lines.first)
        let destination = temporaryDirectory.appendingPathComponent("cancel-output.pdf")
        let compositionTask = Task {
            while !Task.isCancelled { await Task.yield() }
            return try PDFDocumentCompositionService().compose(
                analysis: analysis,
                translations: [line.id: "Cancelled"],
                destinationURL: destination
            )
        }
        compositionTask.cancel()
        do {
            _ = try await compositionTask.value
            XCTFail("Cancelled composition unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

private extension PDFDocumentServicesTests {
    struct DrawnLine {
        let text: String
        let point: CGPoint
        let color: NSColor
        let size: CGFloat
        let fontName: String?

        init(
            _ text: String,
            x: CGFloat,
            y: CGFloat,
            color: NSColor = .black,
            size: CGFloat = 14,
            fontName: String? = nil
        ) {
            self.text = text
            self.point = CGPoint(x: x, y: y)
            self.color = color
            self.size = size
            self.fontName = fontName
        }
    }

    struct ColoredRect {
        let bounds: CGRect
        let color: NSColor

        init(_ bounds: CGRect, color: NSColor) {
            self.bounds = bounds
            self.color = color
        }
    }

    struct LinkFixture {
        let bounds: CGRect
        let url: URL
    }

    func assertTranslationFont(
        in document: PDFDocument,
        pageIndex: Int,
        lineID: String,
        text: String,
        expectedPostScriptName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let page = try XCTUnwrap(document.page(at: pageIndex), file: file, line: line)
        let annotation = try XCTUnwrap(
            page.annotations.first {
                $0.userName == "KCDeepL Translation:\(lineID)"
            },
            file: file,
            line: line
        )
        let storedFont = try XCTUnwrap(annotation.font, file: file, line: line)
        XCTAssertEqual(
            storedFont.fontName,
            expectedPostScriptName,
            file: file,
            line: line
        )
        XCTAssertTrue(
            font(storedFont, supports: text),
            "\(storedFont.fontName) is missing a translated glyph.",
            file: file,
            line: line
        )
    }

    func makeDigitalPDF(
        at url: URL,
        pages: [[DrawnLine]],
        fillsByPage: [[ColoredRect]] = [],
        rotations: [Int] = [],
        mediaBoxes: [CGRect] = [],
        cropBoxes: [CGRect] = [],
        bleedBoxes: [CGRect] = [],
        trimBoxes: [CGRect] = [],
        artBoxes: [CGRect] = [],
        addPreservationAnnotations: Bool = false,
        addFormWidget: Bool = false,
        links: [LinkFixture] = [],
        namedLinkBounds: CGRect? = nil
    ) throws {
        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else {
            return XCTFail("Could not create PDF data consumer")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 600, height: 800)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else {
            return XCTFail("Could not create PDF context")
        }

        for (pageIndex, lines) in pages.enumerated() {
            let pageMediaBox = mediaBoxes.indices.contains(pageIndex)
                ? mediaBoxes[pageIndex]
                : mediaBox
            let pageInfo: CFDictionary?
            if mediaBoxes.indices.contains(pageIndex) {
                var encodedMediaBox = pageMediaBox
                let mediaBoxData = Data(
                    bytes: &encodedMediaBox,
                    count: MemoryLayout<CGRect>.size
                )
                pageInfo = [kCGPDFContextMediaBox: mediaBoxData] as CFDictionary
            } else {
                pageInfo = nil
            }
            context.beginPDFPage(pageInfo)
            context.saveGState()
            context.setFillColor(NSColor.white.cgColor)
            context.fill(pageMediaBox)
            if fillsByPage.indices.contains(pageIndex) {
                for fill in fillsByPage[pageIndex] {
                    context.setFillColor(fill.color.cgColor)
                    context.fill(fill.bounds)
                }
            }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(
                cgContext: context,
                flipped: false
            )
            for line in lines {
                (line.text as NSString).draw(
                    at: line.point,
                    withAttributes: [
                        .font: line.fontName.flatMap {
                            NSFont(name: $0, size: line.size)
                        } ?? NSFont.systemFont(ofSize: line.size),
                        .foregroundColor: line.color
                    ]
                )
            }
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()

        guard let document = PDFDocument(data: mutableData as Data) else {
            return XCTFail("Could not reopen generated PDF")
        }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            if rotations.indices.contains(pageIndex) {
                page.rotation = rotations[pageIndex]
            }
            if cropBoxes.indices.contains(pageIndex) {
                page.setBounds(cropBoxes[pageIndex], for: .cropBox)
            }
            if bleedBoxes.indices.contains(pageIndex) {
                page.setBounds(bleedBoxes[pageIndex], for: .bleedBox)
            }
            if trimBoxes.indices.contains(pageIndex) {
                page.setBounds(trimBoxes[pageIndex], for: .trimBox)
            }
            if artBoxes.indices.contains(pageIndex) {
                page.setBounds(artBoxes[pageIndex], for: .artBox)
            }
        }

        if addPreservationAnnotations, let firstPage = document.page(at: 0) {
            let note = PDFAnnotation(
                bounds: CGRect(x: 500, y: 730, width: 24, height: 24),
                forType: .text,
                withProperties: nil
            )
            note.contents = "keep-me"
            note.userName = "existing-note"
            note.color = NSColor(
                deviceRed: 0.72,
                green: 0.18,
                blue: 0.52,
                alpha: 1
            )
            let noteBorder = PDFBorder()
            noteBorder.lineWidth = 1.25
            noteBorder.style = .dashed
            note.border = noteBorder
            note.shouldDisplay = true
            note.shouldPrint = true
            firstPage.addAnnotation(note)

            let appearanceLink = PDFAnnotation(
                bounds: CGRect(x: 430, y: 90, width: 90, height: 22),
                forType: .link,
                withProperties: nil
            )
            appearanceLink.action = PDFActionURL(
                url: try XCTUnwrap(
                    URL(string: "https://example.com/preserved-appearance")
                )
            )
            appearanceLink.color = NSColor(
                deviceRed: 0.38,
                green: 0.12,
                blue: 0.82,
                alpha: 1
            )
            let appearanceBorder = PDFBorder()
            appearanceBorder.lineWidth = 1.5
            appearanceBorder.style = .underline
            appearanceLink.border = appearanceBorder
            appearanceLink.shouldDisplay = true
            appearanceLink.shouldPrint = true
            firstPage.addAnnotation(appearanceLink)

            let customAppearance = PDFAnnotation(
                bounds: CGRect(x: 330, y: 180, width: 140, height: 28),
                forType: .freeText,
                withProperties: nil
            )
            customAppearance.contents = "CUSTOM AP"
            customAppearance.userName = "existing-custom-appearance"
            customAppearance.font = NSFont(name: "Helvetica-Bold", size: 11)
                ?? NSFont.boldSystemFont(ofSize: 11)
            customAppearance.fontColor = NSColor(
                deviceRed: 0.95,
                green: 0.95,
                blue: 0.98,
                alpha: 1
            )
            customAppearance.color = NSColor(
                deviceRed: 0.13,
                green: 0.26,
                blue: 0.58,
                alpha: 1
            )
            customAppearance.alignment = .center
            customAppearance.shouldDisplay = true
            customAppearance.shouldPrint = true
            firstPage.addAnnotation(customAppearance)

        }

        if addFormWidget, let firstPage = document.page(at: 0) {
            let widget = PDFAnnotation(
                bounds: CGRect(x: 400, y: 60, width: 130, height: 24),
                forType: .widget,
                withProperties: nil
            )
            widget.widgetFieldType = .text
            widget.fieldName = "customer"
            widget.widgetStringValue = "Alice"
            firstPage.addAnnotation(widget)
        }

        if let firstPage = document.page(at: 0) {
            for link in links {
                let annotation = PDFAnnotation(
                    bounds: link.bounds,
                    forType: .link,
                    withProperties: nil
                )
                annotation.action = PDFActionURL(url: link.url)
                annotation.shouldDisplay = true
                annotation.shouldPrint = true
                firstPage.addAnnotation(annotation)
            }
            if let namedLinkBounds {
                let annotation = PDFAnnotation(
                    bounds: namedLinkBounds,
                    forType: .link,
                    withProperties: nil
                )
                annotation.action = PDFActionNamed(name: .nextPage)
                firstPage.addAnnotation(annotation)
            }
        }

        let finalData = try XCTUnwrap(document.dataRepresentation())
        try finalData.write(to: url, options: .atomic)
    }

    func makeImageOnlyPDF(
        at url: URL,
        text: String,
        rotation: Int = 0,
        cropBox: CGRect? = nil,
        backgroundColor: NSColor = .white,
        textColor: NSColor = .black
    ) throws {
        let size = CGSize(width: 1_000, height: 500)
        let image = NSImage(size: size, flipped: false) { bounds in
            backgroundColor.setFill()
            bounds.fill()
            (text as NSString).draw(
                at: CGPoint(x: 80, y: 190),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 86, weight: .bold),
                    .foregroundColor: textColor
                ]
            )
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: image))
        page.rotation = rotation
        if let cropBox {
            page.setBounds(cropBox, for: .cropBox)
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        let data = try XCTUnwrap(document.dataRepresentation())
        try data.write(to: url, options: .atomic)
    }

    func assertEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        accuracy: CGFloat = 0.05,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.minX, rhs.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: accuracy, file: file, line: line)
    }

    func replaceFirstASCII(
        in url: URL,
        matching source: String,
        with replacement: String
    ) throws {
        let sourceData = Data(source.utf8)
        let replacementData = Data(replacement.utf8)
        XCTAssertEqual(sourceData.count, replacementData.count)
        var data = try Data(contentsOf: url)
        let range = try XCTUnwrap(data.range(of: sourceData))
        data.replaceSubrange(range, with: replacementData)
        try data.write(to: url, options: .atomic)
    }

    func assertAnnotationAppearance(
        _ source: PDFAnnotation,
        _ output: PDFAnnotation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            output.shouldDisplay,
            source.shouldDisplay,
            file: file,
            line: line
        )
        XCTAssertEqual(
            output.shouldPrint,
            source.shouldPrint,
            file: file,
            line: line
        )
        let sourceColor = source.color.usingColorSpace(.deviceRGB)
        let outputColor = output.color.usingColorSpace(.deviceRGB)
        XCTAssertEqual(
            outputColor?.redComponent ?? -1,
            sourceColor?.redComponent ?? -1,
            accuracy: 0.02,
            file: file,
            line: line
        )
        XCTAssertEqual(
            outputColor?.greenComponent ?? -1,
            sourceColor?.greenComponent ?? -1,
            accuracy: 0.02,
            file: file,
            line: line
        )
        XCTAssertEqual(
            outputColor?.blueComponent ?? -1,
            sourceColor?.blueComponent ?? -1,
            accuracy: 0.02,
            file: file,
            line: line
        )
        XCTAssertEqual(
            output.border?.lineWidth,
            source.border?.lineWidth,
            file: file,
            line: line
        )
        XCTAssertEqual(
            output.border?.style,
            source.border?.style,
            file: file,
            line: line
        )
    }

    func font(_ font: NSFont, supports text: String) -> Bool {
        let characters = Array(text.utf16)
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        return characters.withUnsafeBufferPointer { charactersPointer in
            glyphs.withUnsafeMutableBufferPointer { glyphsPointer in
                guard let charactersAddress = charactersPointer.baseAddress,
                      let glyphsAddress = glyphsPointer.baseAddress
                else {
                    return false
                }
                return CTFontGetGlyphsForCharacters(
                    font as CTFont,
                    charactersAddress,
                    glyphsAddress,
                    characters.count
                )
            }
        }
    }

    func preserveQAFixtureIfRequested(
        sourceURL: URL,
        translatedURL: URL
    ) throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "KCDEEPL_PDF_QA_OUTPUT_DIR"
        ], !outputPath.isEmpty else {
            return
        }

        let outputDirectory = URL(
            fileURLWithPath: outputPath,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try Data(contentsOf: sourceURL).write(
            to: outputDirectory.appendingPathComponent("styled-source.pdf"),
            options: .atomic
        )
        try Data(contentsOf: translatedURL).write(
            to: outputDirectory.appendingPathComponent("styled-translated.pdf"),
            options: .atomic
        )
    }

    func preserveRotatedQAFixtureIfRequested(
        sourceURL: URL,
        translatedURL: URL,
        rotation: Int
    ) throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "KCDEEPL_PDF_QA_OUTPUT_DIR"
        ], !outputPath.isEmpty else {
            return
        }

        let outputDirectory = URL(
            fileURLWithPath: outputPath,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try Data(contentsOf: sourceURL).write(
            to: outputDirectory.appendingPathComponent(
                "rotated-\(rotation)-source.pdf"
            ),
            options: .atomic
        )
        try Data(contentsOf: translatedURL).write(
            to: outputDirectory.appendingPathComponent(
                "rotated-\(rotation)-translated.pdf"
            ),
            options: .atomic
        )
    }

    func preserveCarrierQAFixtureIfRequested(
        sourceURL: URL,
        translatedURL: URL,
        rotation: Int
    ) throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "KCDEEPL_PDF_QA_OUTPUT_DIR"
        ], !outputPath.isEmpty else {
            return
        }

        let outputDirectory = URL(
            fileURLWithPath: outputPath,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try Data(contentsOf: sourceURL).write(
            to: outputDirectory.appendingPathComponent(
                "carrier-\(rotation)-source.pdf"
            ),
            options: .atomic
        )
        try Data(contentsOf: translatedURL).write(
            to: outputDirectory.appendingPathComponent(
                "carrier-\(rotation)-translated.pdf"
            ),
            options: .atomic
        )
    }

}
