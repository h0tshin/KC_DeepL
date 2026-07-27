import AppKit
import XCTest
@testable import KCDeepL

final class RichTextFormattingTests: XCTestCase {
    func testNormalizeDiscardsTextAndBackgroundColorsWhilePreservingFormatting() throws {
        let sourceFont = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: 18),
            toHaveTrait: [.boldFontMask, .italicFontMask]
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.headIndent = 12
        let link = try XCTUnwrap(URL(string: "https://example.com"))
        let source = NSAttributedString(
            string: "Styled text",
            attributes: [
                .font: sourceFont,
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.white,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .link: link,
                .paragraphStyle: paragraphStyle
            ]
        )

        let normalized = RichTextFormatting.normalize(source)
        let attributes = normalized.attributes(at: 0, effectiveRange: nil)

        XCTAssertNil(attributes[.backgroundColor])
        XCTAssertTrue(
            try XCTUnwrap(attributes[.foregroundColor] as? NSColor)
                .isEqual(NSColor.labelColor)
        )

        let normalizedFont = try XCTUnwrap(attributes[.font] as? NSFont)
        let traits = NSFontManager.shared.traits(of: normalizedFont)
        XCTAssertTrue(traits.contains(.boldFontMask))
        XCTAssertTrue(traits.contains(.italicFontMask))
        XCTAssertEqual(normalizedFont.pointSize, sourceFont.pointSize)
        XCTAssertEqual(
            attributes[.underlineStyle] as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertEqual(attributes[.link] as? URL, link)
        XCTAssertTrue(
            try XCTUnwrap(attributes[.paragraphStyle] as? NSParagraphStyle)
                .isEqual(paragraphStyle)
        )
    }

    func testPasteboardImportDiscardsColorsFromRichText() throws {
        let source = NSAttributedString(
            string: "Imported text",
            attributes: [
                .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
                .foregroundColor: NSColor.systemYellow,
                .backgroundColor: NSColor.white
            ]
        )
        let sourceRange = NSRange(location: 0, length: source.length)
        let rtfData = try source.data(
            from: sourceRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("RichTextFormattingTests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setData(rtfData, forType: .rtf)

        let imported = try XCTUnwrap(RichTextFormatting.attributedString(from: pasteboard))
        let attributes = imported.attributes(at: 0, effectiveRange: nil)

        XCTAssertEqual(imported.string, source.string)
        XCTAssertNil(attributes[.backgroundColor])
        XCTAssertTrue(
            try XCTUnwrap(attributes[.foregroundColor] as? NSColor)
                .isEqual(NSColor.labelColor)
        )
        XCTAssertEqual(
            try XCTUnwrap(attributes[.font] as? NSFont).pointSize,
            21,
            accuracy: 0.01
        )
    }
}
