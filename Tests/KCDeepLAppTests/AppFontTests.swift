import AppKit
import CoreText
import XCTest
@testable import KCDeepL

final class AppFontTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = AppFontRegistry.registerBundledFonts()
    }

    func testBundledFontsRegisterByStablePublicPostScriptName() {
        let report = AppFontRegistry.registerBundledFonts()

        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertEqual(report, AppFontRegistry.registerBundledFonts())
        XCTAssertEqual(
            Set(report.registeredPostScriptNames),
            Set([
                AppFont.barlowRegular,
                AppFont.barlowItalic,
                AppFont.barlowBold,
                AppFont.barlowBoldItalic,
                AppFont.barlowSemibold,
                AppFont.barlowSemiboldItalic,
                AppFont.notoSansKRRegular,
                AppFont.notoSansKRBold,
                AppFont.d2CodingRegular,
                AppFont.d2CodingBold
            ])
        )
        for name in report.registeredPostScriptNames {
            XCTAssertNotNil(NSFont(name: name, size: 14), name)
        }
    }

    func testMixedUIFontCascadesFromBarlowToNotoSansKR() throws {
        let font = AppFont.uiFont(size: 16)
        XCTAssertEqual(font.fontName, AppFont.barlowRegular)

        let korean = "한글" as NSString
        let fallback = CTFontCreateForString(
            font as CTFont,
            korean,
            CFRange(location: 0, length: korean.length)
        ) as NSFont
        XCTAssertEqual(fallback.fontName, AppFont.notoSansKRRegular)
        XCTAssertTrue(fontSupportsAllCharacters(fallback, text: korean as String))
    }

    func testContentFontChoosesRequestedScriptAndWeight() {
        XCTAssertEqual(
            AppFont.contentFont(for: "English", size: 14).fontName,
            AppFont.barlowRegular
        )
        XCTAssertEqual(
            AppFont.contentFont(
                for: "한국어",
                size: 14,
                weight: .bold
            ).fontName,
            AppFont.notoSansKRBold
        )
        XCTAssertEqual(
            AppFont.monospacedFont(size: 14).fontName,
            AppFont.d2CodingRegular
        )
        XCTAssertEqual(
            AppFont.monospacedFont(size: 14, weight: .bold).fontName,
            AppFont.d2CodingBold
        )
    }

    func testPDFCandidateOrderPrefersBundledPublicFonts() {
        XCTAssertEqual(
            AppFont.preferredPostScriptNames(
                for: "Translated PDF",
                isBold: false
            ).first,
            AppFont.barlowRegular
        )
        XCTAssertEqual(
            AppFont.preferredPostScriptNames(
                for: "번역된 PDF",
                isBold: true
            ).first,
            AppFont.notoSansKRBold
        )
        XCTAssertEqual(
            AppFont.preferredPostScriptNames(
                for: "翻訳した文書です",
                isBold: false
            ).first,
            "HiraginoSans-W3"
        )
        XCTAssertEqual(
            AppFont.preferredPostScriptNames(
                for: "翻译文档",
                isBold: false
            ).first,
            "PingFangSC-Regular"
        )
        XCTAssertEqual(
            AppFont.preferredPostScriptNames(
                for: "let value = 1",
                isBold: false,
                monospaced: true
            ).first,
            AppFont.d2CodingRegular
        )
    }

    private func fontSupportsAllCharacters(_ font: NSFont, text: String) -> Bool {
        let utf16 = Array(text.utf16)
        var glyphs = Array(repeating: CGGlyph(), count: utf16.count)
        return utf16.withUnsafeBufferPointer { characters in
            glyphs.withUnsafeMutableBufferPointer { glyphs in
                guard let characterBase = characters.baseAddress,
                      let glyphBase = glyphs.baseAddress
                else {
                    return true
                }
                return CTFontGetGlyphsForCharacters(
                    font as CTFont,
                    characterBase,
                    glyphBase,
                    utf16.count
                )
            }
        }
    }
}
