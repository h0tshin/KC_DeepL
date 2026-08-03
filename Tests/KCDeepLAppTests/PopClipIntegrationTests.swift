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
                && payload.windowPolicy == .reuseExisting
        }

        PopClipIntegration.handle(url)

        await fulfillment(of: [dispatched], timeout: 1)
    }

    @MainActor
    func testPopClipDoesNotRequestAnotherWindowWhenNoWindowIsFound() throws {
        let dispatcher = AppActionDispatcher.shared
        let previousOpenMainWindow = dispatcher.openMainWindow
        var didRequestNewWindow = false
        dispatcher.openMainWindow = {
            didRequestNewWindow = true
        }
        defer {
            dispatcher.openMainWindow = previousOpenMainWindow
        }

        let url = try XCTUnwrap(
            URL(string: "kcdeepl://translate?text=Reuse%20the%20current%20window")
        )
        PopClipIntegration.handle(url)

        XCTAssertFalse(didRequestNewWindow)
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
