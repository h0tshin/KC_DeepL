import Foundation

struct PopClipTranslationRequest: Equatable {
    static let urlScheme = "kcdeepl"
    static let translateHost = "translate"

    let text: String

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.urlScheme,
              url.host?.lowercased() == Self.translateHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let text = components.queryItems?.first(where: { $0.name == "text" })?.value,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        self.text = text
    }
}

@MainActor
enum PopClipIntegration {
    static func handle(_ url: URL) {
        guard let request = PopClipTranslationRequest(url: url) else {
            return
        }

        AppActionDispatcher.shared.perform(
            .textTranslation,
            capturedText: request.text,
            statusMessage: "PopClip에서 선택한 텍스트를 가져왔습니다.",
            windowPolicy: .reuseExisting
        )
    }
}
