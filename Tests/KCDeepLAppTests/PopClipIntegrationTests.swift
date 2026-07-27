import Foundation
import XCTest
@testable import KCDeepL

final class PopClipIntegrationTests: XCTestCase {
    @MainActor
    func testIntegrationDispatchesSelectedTextToTranslationAction() async throws {
        let url = try XCTUnwrap(
            URL(string: "kcdeepl://translate?text=Translate%20this")
        )
        let dispatched = expectation(
            forNotification: .kcDeepLPerformAction,
            object: nil
        ) { notification in
            guard let payload = notification.object as? AppCommandPayload else {
                return false
            }

            return payload.action == .textTranslation
                && payload.capturedText == "Translate this"
                && payload.statusMessage == "PopClip에서 선택한 텍스트를 가져왔습니다."
        }

        PopClipIntegration.handle(url)

        await fulfillment(of: [dispatched], timeout: 1)
    }

    func testTranslationRequestDecodesSelectedTextWithoutChangingLayout() throws {
        var components = URLComponents()
        components.scheme = PopClipTranslationRequest.urlScheme
        components.host = PopClipTranslationRequest.translateHost
        components.queryItems = [
            URLQueryItem(
                name: "text",
                value: "Hello & 안녕하세요?\n\nSecond paragraph"
            )
        ]
        let url = try XCTUnwrap(components.url)

        let request = try XCTUnwrap(PopClipTranslationRequest(url: url))

        XCTAssertEqual(
            request.text,
            "Hello & 안녕하세요?\n\nSecond paragraph"
        )
    }

    func testTranslationRequestAcceptsCaseInsensitiveRoute() throws {
        let url = try XCTUnwrap(URL(string: "KCDEEPL://TRANSLATE?text=Hello%20world"))

        let request = try XCTUnwrap(PopClipTranslationRequest(url: url))

        XCTAssertEqual(request.text, "Hello world")
    }

    func testTranslationRequestRejectsUnknownRoutesAndEmptyText() throws {
        let wrongScheme = try XCTUnwrap(URL(string: "https://translate?text=Hello"))
        let wrongHost = try XCTUnwrap(URL(string: "kcdeepl://unknown?text=Hello"))
        let missingText = try XCTUnwrap(URL(string: "kcdeepl://translate"))
        let blankText = try XCTUnwrap(URL(string: "kcdeepl://translate?text=%20%0A"))

        XCTAssertNil(PopClipTranslationRequest(url: wrongScheme))
        XCTAssertNil(PopClipTranslationRequest(url: wrongHost))
        XCTAssertNil(PopClipTranslationRequest(url: missingText))
        XCTAssertNil(PopClipTranslationRequest(url: blankText))
    }
}
