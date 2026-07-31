import Foundation

/// A positioned text unit extracted from one document page.
public struct DocumentPageTextBlock: Equatable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// All text that must be translated together to retain page-level context.
public struct DocumentPageTranslationRequest: Equatable, Sendable {
    public let pageIndex: Int
    public let blocks: [DocumentPageTextBlock]
    public let sourceLanguage: LanguageOption
    public let targetLanguage: LanguageOption

    public init(
        pageIndex: Int,
        blocks: [DocumentPageTextBlock],
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption
    ) {
        self.pageIndex = pageIndex
        self.blocks = blocks
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

/// The translated text for one source block.
public struct DocumentPageBlockTranslation: Equatable, Sendable {
    public let id: String
    public let translatedText: String

    public init(id: String, translatedText: String) {
        self.id = id
        self.translatedText = translatedText
    }
}

/// A page translation whose block IDs map back to the source page layout.
public struct DocumentPageTranslationResult: Equatable, Sendable {
    public let pageIndex: Int
    public let translations: [DocumentPageBlockTranslation]

    public init(pageIndex: Int, translations: [DocumentPageBlockTranslation]) {
        self.pageIndex = pageIndex
        self.translations = translations
    }
}

/// A backend capable of translating all text blocks on one page as one unit.
public protocol DocumentPageTranslationClient: Sendable {
    func translatePage(
        _ request: DocumentPageTranslationRequest
    ) async throws -> DocumentPageTranslationResult
}

public enum DocumentPageTranslationError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequest(String)
    case emptyResponse
    case malformedResponse
    case duplicateTranslationID(String)
    case missingTranslationIDs([String])
    case unknownTranslationIDs([String])
    case emptyTranslation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason):
            "페이지 번역 요청이 올바르지 않습니다: \(reason)"
        case .emptyResponse:
            "페이지 번역 응답이 비어 있습니다."
        case .malformedResponse:
            "페이지 번역 응답 형식을 해석할 수 없습니다."
        case .duplicateTranslationID(let id):
            "페이지 번역 응답에 중복된 블록 ID가 있습니다: \(id)"
        case .missingTranslationIDs(let ids):
            "페이지 번역 응답에 누락된 블록이 있습니다: \(ids.joined(separator: ", "))"
        case .unknownTranslationIDs(let ids):
            "페이지 번역 응답에 알 수 없는 블록이 있습니다: \(ids.joined(separator: ", "))"
        case .emptyTranslation(let id):
            "블록의 번역 결과가 비어 있습니다: \(id)"
        }
    }
}

/// Validates an engine response and restores the original source-block order.
public enum DocumentPageTranslationValidator {
    public static func validateAndOrder(
        _ result: DocumentPageTranslationResult,
        for request: DocumentPageTranslationRequest
    ) throws -> DocumentPageTranslationResult {
        try validateRequest(request)

        guard result.pageIndex == request.pageIndex else {
            throw DocumentPageTranslationError.invalidRequest(
                "응답 페이지 인덱스가 요청과 일치하지 않습니다."
            )
        }

        var translationsByID: [String: DocumentPageBlockTranslation] = [:]
        translationsByID.reserveCapacity(result.translations.count)

        for translation in result.translations {
            guard translationsByID[translation.id] == nil else {
                throw DocumentPageTranslationError.duplicateTranslationID(translation.id)
            }
            guard !translation.translatedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            else {
                throw DocumentPageTranslationError.emptyTranslation(translation.id)
            }
            translationsByID[translation.id] = translation
        }

        let expectedIDs = Set(request.blocks.map(\.id))
        let actualIDs = Set(translationsByID.keys)

        let unknownIDs = actualIDs.subtracting(expectedIDs).sorted()
        guard unknownIDs.isEmpty else {
            throw DocumentPageTranslationError.unknownTranslationIDs(unknownIDs)
        }

        let missingIDs = expectedIDs.subtracting(actualIDs).sorted()
        guard missingIDs.isEmpty else {
            throw DocumentPageTranslationError.missingTranslationIDs(missingIDs)
        }

        let orderedTranslations = request.blocks.compactMap { translationsByID[$0.id] }
        return DocumentPageTranslationResult(
            pageIndex: request.pageIndex,
            translations: orderedTranslations
        )
    }

    static func validateRequest(_ request: DocumentPageTranslationRequest) throws {
        guard request.pageIndex >= 0 else {
            throw DocumentPageTranslationError.invalidRequest(
                "페이지 인덱스는 0 이상이어야 합니다."
            )
        }

        var blockIDs: Set<String> = []
        for block in request.blocks {
            guard !block.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DocumentPageTranslationError.invalidRequest(
                    "블록 ID는 비어 있을 수 없습니다."
                )
            }
            guard blockIDs.insert(block.id).inserted else {
                throw DocumentPageTranslationError.invalidRequest(
                    "중복된 원본 블록 ID가 있습니다: \(block.id)"
                )
            }
            guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DocumentPageTranslationError.invalidRequest(
                    "원본 블록 텍스트는 비어 있을 수 없습니다: \(block.id)"
                )
            }
            guard block.id.unicodeScalars.allSatisfy(\.isValidXMLScalar),
                  block.text.unicodeScalars.allSatisfy(\.isValidXMLScalar)
            else {
                throw DocumentPageTranslationError.invalidRequest(
                    "XML로 표현할 수 없는 문자가 포함되어 있습니다: \(block.id)"
                )
            }
        }
    }
}

/// Adapts a plain text `TranslationClient` to page-aware block translation.
public struct TranslationClientDocumentPageAdapter: DocumentPageTranslationClient, Sendable {
    private let client: any TranslationClient
    private let provider: LLMProvider
    private let modelID: String
    private let apiKey: String
    private let temperature: Double
    private let maxAttempts: Int

    public init(
        client: any TranslationClient,
        provider: LLMProvider,
        modelID: String,
        apiKey: String,
        temperature: Double = 0.2,
        maxAttempts: Int = 3
    ) {
        self.client = client
        self.provider = provider
        self.modelID = modelID
        self.apiKey = apiKey
        self.temperature = temperature
        self.maxAttempts = max(1, maxAttempts)
    }

    public func translatePage(
        _ request: DocumentPageTranslationRequest
    ) async throws -> DocumentPageTranslationResult {
        try Task.checkCancellation()
        try DocumentPageTranslationValidator.validateRequest(request)

        guard !request.blocks.isEmpty else {
            return DocumentPageTranslationResult(
                pageIndex: request.pageIndex,
                translations: []
            )
        }

        let pagePayload = DocumentPageTranslationEnvelope.serialize(request.blocks)
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            do {
                let response = try await client.translate(
                    TranslationRequest(
                        sourceText: pagePayload,
                        sourceLanguage: request.sourceLanguage,
                        targetLanguage: request.targetLanguage,
                        provider: provider,
                        modelID: modelID,
                        apiKey: apiKey,
                        temperature: temperature
                    )
                )
                try Task.checkCancellation()

                let translations = try DocumentPageTranslationEnvelope.parse(response)
                let result = DocumentPageTranslationResult(
                    pageIndex: request.pageIndex,
                    translations: translations
                )
                return try DocumentPageTranslationValidator.validateAndOrder(
                    result,
                    for: request
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DocumentPageTranslationError {
                guard Self.isRetryable(error), attempt + 1 < maxAttempts else {
                    throw error
                }
                lastError = error
            } catch {
                guard attempt + 1 < maxAttempts else {
                    throw error
                }
                lastError = error
            }

            // A short backoff gives a model time to complete a second
            // structured-output attempt without serializing page requests.
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        throw lastError ?? DocumentPageTranslationError.emptyResponse
    }

    private static func isRetryable(_ error: DocumentPageTranslationError) -> Bool {
        switch error {
        case .emptyResponse,
             .malformedResponse,
             .duplicateTranslationID,
             .missingTranslationIDs,
             .unknownTranslationIDs,
             .emptyTranslation:
            return true
        case .invalidRequest:
            return false
        }
    }
}

/// Stable XML envelope used to send a whole page through engines that accept text.
///
/// Parsers reject prose, nested markup, missing roots, and malformed segments so
/// an engine can never silently detach a translation from its source position.
public enum DocumentPageTranslationEnvelope {
    static let rootElement = "kc_page_translation"
    static let segmentElement = "kc_segment"

    public static func serialize(_ blocks: [DocumentPageTextBlock]) -> String {
        var payload = "<\(rootElement) version=\"1\">"
        for block in blocks {
            payload += "<\(segmentElement) id=\"\(escape(block.id))\">"
            payload += escape(block.text)
            payload += "</\(segmentElement)>"
        }
        payload += "</\(rootElement)>"
        return payload
    }

    public static func parse(
        _ response: String
    ) throws -> [DocumentPageBlockTranslation] {
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else {
            throw DocumentPageTranslationError.emptyResponse
        }

        let xml = removeOptionalMarkdownFence(from: trimmedResponse)
        guard !xml.isEmpty, let data = xml.data(using: .utf8) else {
            throw DocumentPageTranslationError.malformedResponse
        }

        let delegate = DocumentPageTranslationXMLParserDelegate(
            rootElement: rootElement,
            segmentElement: segmentElement
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false

        guard parser.parse(), delegate.isComplete, !delegate.isMalformed else {
            throw DocumentPageTranslationError.malformedResponse
        }
        return delegate.translations
    }

    private static func escape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)

        for character in value {
            switch character {
            case "&":
                escaped += "&amp;"
            case "<":
                escaped += "&lt;"
            case ">":
                escaped += "&gt;"
            case "\"":
                escaped += "&quot;"
            case "'":
                escaped += "&apos;"
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    private static func removeOptionalMarkdownFence(from value: String) -> String {
        var lines = value.split(
            omittingEmptySubsequences: false,
            whereSeparator: \Character.isNewline
        ).map(String.init)

        guard lines.count >= 2 else {
            return value
        }

        let opening = lines[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard opening == "```" || opening == "```xml" else {
            return value
        }

        while lines.count > 1,
              lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        guard lines.last?.trimmingCharacters(in: .whitespaces) == "```" else {
            return value
        }

        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class DocumentPageTranslationXMLParserDelegate: NSObject, XMLParserDelegate {
    private let rootElement: String
    private let segmentElement: String
    private var depth = 0
    private var didSeeRoot = false
    private var didCloseRoot = false
    private var currentID: String?
    private var currentText = ""

    private(set) var translations: [DocumentPageBlockTranslation] = []
    private(set) var isMalformed = false

    var isComplete: Bool {
        didSeeRoot && didCloseRoot && depth == 0 && currentID == nil
    }

    init(rootElement: String, segmentElement: String) {
        self.rootElement = rootElement
        self.segmentElement = segmentElement
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard !isMalformed else {
            return
        }

        if depth == 0 {
            guard !didSeeRoot, elementName == rootElement else {
                isMalformed = true
                parser.abortParsing()
                return
            }
            didSeeRoot = true
        } else if depth == 1 {
            guard elementName == segmentElement,
                  currentID == nil,
                  let id = attributeDict["id"],
                  !id.isEmpty
            else {
                isMalformed = true
                parser.abortParsing()
                return
            }
            currentID = id
            currentText = ""
        } else {
            isMalformed = true
            parser.abortParsing()
            return
        }
        depth += 1
    }

    func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        if currentID != nil {
            currentText += string
        } else if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isMalformed = true
            parser.abortParsing()
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCDATA CDATABlock: Data
    ) {
        guard currentID != nil,
              let string = String(data: CDATABlock, encoding: .utf8)
        else {
            isMalformed = true
            parser.abortParsing()
            return
        }
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard !isMalformed, depth > 0 else {
            return
        }

        if depth == 2 {
            guard elementName == segmentElement, let id = currentID else {
                isMalformed = true
                parser.abortParsing()
                return
            }
            translations.append(
                DocumentPageBlockTranslation(
                    id: id,
                    translatedText: currentText.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                )
            )
            currentID = nil
            currentText = ""
        } else if depth == 1 {
            guard elementName == rootElement, currentID == nil else {
                isMalformed = true
                parser.abortParsing()
                return
            }
            didCloseRoot = true
        } else {
            isMalformed = true
            parser.abortParsing()
            return
        }
        depth -= 1
    }
}

private extension Unicode.Scalar {
    var isValidXMLScalar: Bool {
        value == 0x9
            || value == 0xA
            || value == 0xD
            || (0x20...0xD7FF).contains(value)
            || (0xE000...0xFFFD).contains(value)
            || (0x10000...0x10FFFF).contains(value)
    }
}
