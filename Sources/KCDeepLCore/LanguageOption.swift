import Foundation

public struct LanguageOption: Codable, Hashable, Identifiable {
    public let code: String
    public let displayName: String

    public var id: String { code }

    public init(code: String, displayName: String) {
        self.code = code
        self.displayName = displayName
    }

    public static let autoDetect = LanguageOption(code: "auto", displayName: "언어 감지")
    public static let korean = LanguageOption(code: "ko", displayName: "한국어")
    public static let english = LanguageOption(code: "en", displayName: "영어")
    public static let japanese = LanguageOption(code: "ja", displayName: "일본어")
    public static let chineseSimplified = LanguageOption(code: "zh-CN", displayName: "중국어 간체")
    public static let chineseTraditional = LanguageOption(code: "zh-TW", displayName: "중국어 번체")
    public static let french = LanguageOption(code: "fr", displayName: "프랑스어")
    public static let german = LanguageOption(code: "de", displayName: "독일어")
    public static let spanish = LanguageOption(code: "es", displayName: "스페인어")

    public static let sourceLanguages: [LanguageOption] = [
        .autoDetect,
        .korean,
        .english,
        .japanese,
        .chineseSimplified,
        .chineseTraditional,
        .french,
        .german,
        .spanish
    ]

    public static let targetLanguages: [LanguageOption] = [
        .korean,
        .english,
        .japanese,
        .chineseSimplified,
        .chineseTraditional,
        .french,
        .german,
        .spanish
    ]
}
