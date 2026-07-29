import XCTest
@testable import KCDeepL

final class FontSizeControlTests: XCTestCase {
    func testFontSizePNGIconsLoadFromResources() {
        XCTAssertNotNil(FontSizeIconResource.image(named: "FontSizeDecrease"))
        XCTAssertNotNil(FontSizeIconResource.image(named: "FontSizeIncrease"))
    }

    func testApplicationIconsLoadFromResources() {
        XCTAssertNotNil(
            AppResourceLocator.url(
                forResource: "AppIcon",
                withExtension: "png"
            )
        )
        XCTAssertNotNil(
            AppResourceLocator.url(
                forResource: "MenuBarIcon",
                withExtension: "png"
            )
        )
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
