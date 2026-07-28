import XCTest
@testable import KCDeepL

final class FontSizeControlTests: XCTestCase {
    func testFontSizePNGIconsLoadFromResources() {
        XCTAssertNotNil(FontSizeIconResource.image(named: "FontSizeDecrease"))
        XCTAssertNotNil(FontSizeIconResource.image(named: "FontSizeIncrease"))
    }

    func testMissingResourceReturnsNilWithoutCrashing() {
        XCTAssertNil(
            AppResourceLocator.url(
                forResource: "ResourceThatDoesNotExist",
                withExtension: "png"
            )
        )
    }
}
