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

    func testDisplayMarkdownPreservesParagraphsAndInlineFormatting() throws {
        let markdown = "First line\nSecond line\n\n**Bold paragraph**\n[Link](https://example.com)"

        let displayed = RichTextFormatting.displayAttributedString(markdown: markdown)
        let displayedText = String(displayed.characters)

        XCTAssertEqual(
            displayedText,
            "First line\nSecond line\n\nBold paragraph\nLink"
        )

        let attributed = NSAttributedString(displayed)
        let boldRange = (attributed.string as NSString).range(of: "Bold paragraph")
        let boldIntent = try XCTUnwrap(
            attributed.attribute(
                .inlinePresentationIntent,
                at: boldRange.location,
                effectiveRange: nil
            ) as? NSNumber
        )
        XCTAssertTrue(
            InlinePresentationIntent(rawValue: boldIntent.uintValue)
                .contains(.stronglyEmphasized)
        )

        let linkRange = (attributed.string as NSString).range(of: "Link")
        XCTAssertEqual(
            attributed.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL,
            URL(string: "https://example.com")
        )
    }

    func testMarkdownPasteboardFormattingPreservesParagraphsAndStyles() throws {
        let markdown = "First paragraph\n\n**Bold** and *italic* with <u>underline</u>."
        let attributed = RichTextFormatting.attributedString(markdown: markdown)

        XCTAssertEqual(
            attributed.string,
            "First paragraph\n\nBold and italic with underline."
        )

        let string = attributed.string as NSString
        assertFontTrait(.boldFontMask, in: attributed, text: "Bold", string: string)
        assertFontTrait(.italicFontMask, in: attributed, text: "italic", string: string)

        let underlineRange = string.range(of: "underline")
        XCTAssertEqual(
            attributed.attribute(
                .underlineStyle,
                at: underlineRange.location,
                effectiveRange: nil
            ) as? Int,
            NSUnderlineStyle.single.rawValue
        )
    }

    func testSourceMarkdownPreservesBlankLinesAndBoldRuns() {
        let source = NSMutableAttributedString(
            attributedString: RichTextFormatting.plainAttributedString("First paragraph\n\nBold paragraph")
        )
        let boldRange = (source.string as NSString).range(of: "Bold paragraph")
        let boldFont = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: 26),
            toHaveTrait: .boldFontMask
        )
        source.addAttribute(.font, value: boldFont, range: boldRange)

        let markdown = RichTextFormatting.markdown(from: source, fallback: source.string)

        XCTAssertEqual(markdown, "First paragraph\n\n**Bold paragraph**")
    }

    private func assertFontTrait(
        _ trait: NSFontTraitMask,
        in attributed: NSAttributedString,
        text: String,
        string: NSString,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let range = string.range(of: text)
        let font = attributed.attribute(
            .font,
            at: range.location,
            effectiveRange: nil
        ) as? NSFont
        XCTAssertNotNil(font, file: file, line: line)
        if let font {
            XCTAssertTrue(
                NSFontManager.shared.traits(of: font).contains(trait),
                file: file,
                line: line
            )
        }
    }
}
