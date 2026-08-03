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
        XCTAssertGreaterThanOrEqual(report.nativeVectorCount, 2)
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
