import Foundation
import KCDeepLCore

#if canImport(Translation)
import Translation
#endif

/// Runtime support information that can be queried without referencing a macOS 15 API.
enum AppleDocumentTranslationRuntime {
    static var isAvailable: Bool {
#if canImport(Translation)
        if #available(macOS 15.0, *) {
            return true
        }
#endif
        return false
    }

    static let unavailableMessage =
        "Apple 번역 엔진은 macOS 15 이상에서 사용할 수 있습니다."
}

enum AppleDocumentTranslationError: Error, Equatable, LocalizedError, Sendable {
    case operatingSystemUnsupported
    case targetLanguageMustBeExplicit
    case invalidLanguageCode(String)
    case sessionConfigurationMismatch(
        expectedSource: String?,
        expectedTarget: String,
        actualSource: String?,
        actualTarget: String?
    )
    case unsupportedLanguagePair(source: String, target: String)
    case missingResponseIdentifier(responseIndex: Int)
    case unexpectedPageResponseIdentifier(expected: String, actual: String?)
    case unexpectedPageResponseCount(Int)
    case translationAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .operatingSystemUnsupported:
            return AppleDocumentTranslationRuntime.unavailableMessage

        case .targetLanguageMustBeExplicit:
            return "Apple 번역의 대상 언어는 직접 선택해야 합니다."

        case .invalidLanguageCode(let code):
            return "Apple 번역에 전달할 수 없는 언어 코드입니다: \(code)"

        case .sessionConfigurationMismatch(
            let expectedSource,
            let expectedTarget,
            let actualSource,
            let actualTarget
        ):
            let expected = "\(expectedSource ?? "auto") → \(expectedTarget)"
            let actual = "\(actualSource ?? "auto") → \(actualTarget ?? "nil")"
            return "Apple 번역 세션의 언어 설정이 요청과 다릅니다. "
                + "예상: \(expected), 실제: \(actual)"

        case .unsupportedLanguagePair(let source, let target):
            return "Apple 온디바이스 번역이 \(source) → \(target) 언어 조합을 "
                + "지원하지 않습니다."

        case .missingResponseIdentifier(let responseIndex):
            return "Apple 번역 응답 \(responseIndex + 1)번에 원본 블록 ID가 없습니다."

        case .unexpectedPageResponseIdentifier(let expected, let actual):
            return "Apple 페이지 번역 응답 ID가 요청과 다릅니다. "
                + "예상: \(expected), 실제: \(actual ?? "없음")"

        case .unexpectedPageResponseCount(let count):
            return "Apple 페이지 번역이 \(count)개의 응답을 반환했습니다. 정확히 1개가 필요합니다."

        case .translationAlreadyInProgress:
            return "하나의 Apple 번역 세션에서 이미 페이지를 번역하고 있습니다."
        }
    }
}

/// A framework-independent value used to map Apple's potentially reordered batch output.
struct AppleDocumentTranslationResponseValue: Equatable, Sendable {
    let clientIdentifier: String?
    let translatedText: String

    init(clientIdentifier: String?, translatedText: String) {
        self.clientIdentifier = clientIdentifier
        self.translatedText = translatedText
    }
}

/// Converts ID-tagged responses to the core page result and enforces an exact ID match.
enum AppleDocumentTranslationResponseMapper {
    static func map(
        _ responses: [AppleDocumentTranslationResponseValue],
        for request: DocumentPageTranslationRequest
    ) throws -> DocumentPageTranslationResult {
        let translations = try responses.enumerated().map { index, response in
            guard let identifier = response.clientIdentifier else {
                throw AppleDocumentTranslationError.missingResponseIdentifier(
                    responseIndex: index
                )
            }
            return DocumentPageBlockTranslation(
                id: identifier,
                translatedText: response.translatedText
            )
        }

        let unorderedResult = DocumentPageTranslationResult(
            pageIndex: request.pageIndex,
            translations: translations
        )
        return try DocumentPageTranslationValidator.validateAndOrder(
            unorderedResult,
            for: request
        )
    }

    /// Uses the public core validator to validate a request before invoking a backend.
    static func validateRequest(_ request: DocumentPageTranslationRequest) throws {
        let validationResult = DocumentPageTranslationResult(
            pageIndex: request.pageIndex,
            translations: request.blocks.map {
                DocumentPageBlockTranslation(id: $0.id, translatedText: $0.text)
            }
        )
        _ = try DocumentPageTranslationValidator.validateAndOrder(
            validationResult,
            for: request
        )
    }
}

enum AppleDocumentTranslationLanguageRole {
    case source
    case target
}

/// Maps the app's language codes to Foundation languages without losing Chinese script.
enum AppleDocumentTranslationLanguageMapper {
    static func language(
        for option: LanguageOption,
        role: AppleDocumentTranslationLanguageRole
    ) throws -> Locale.Language? {
        let trimmedCode = option.code.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCode = trimmedCode.replacingOccurrences(of: "_", with: "-")
        let lowercaseCode = normalizedCode.lowercased()

        if lowercaseCode == LanguageOption.autoDetect.code.lowercased() {
            guard role == .source else {
                throw AppleDocumentTranslationError.targetLanguageMustBeExplicit
            }
            return nil
        }

        guard isPlausibleBCP47Identifier(normalizedCode) else {
            throw AppleDocumentTranslationError.invalidLanguageCode(option.code)
        }

        switch lowercaseCode {
        case "zh-cn", "zh-hans", "zh-hans-cn":
            return Locale.Language(
                languageCode: .chinese,
                script: .hanSimplified,
                region: .chinaMainland
            )

        case "zh-tw", "zh-hant", "zh-hant-tw":
            return Locale.Language(
                languageCode: .chinese,
                script: .hanTraditional,
                region: .taiwan
            )

        default:
            let language = Locale.Language(identifier: normalizedCode)
            guard let languageCode = language.languageCode,
                  languageCode != .unidentified,
                  languageCode != .unavailable
            else {
                throw AppleDocumentTranslationError.invalidLanguageCode(option.code)
            }
            return language
        }
    }

    private static func isPlausibleBCP47Identifier(_ identifier: String) -> Bool {
        let components = identifier.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = components.first,
              (2...8).contains(language.count),
              language.unicodeScalars.allSatisfy(CharacterSet.letters.contains)
        else {
            return false
        }

        return components.dropFirst().allSatisfy { component in
            (1...8).contains(component.count)
                && component.unicodeScalars.allSatisfy(
                    CharacterSet.alphanumerics.contains
                )
        }
    }
}

enum AppleDocumentTranslationLanguageAvailability: Equatable, Sendable {
    case notRequired
    case installed
    case downloadRequired
    case unsupported
}

struct AppleDocumentTranslationPreflight: Equatable, Sendable {
    let availability: AppleDocumentTranslationLanguageAvailability
    let sourceLanguageCode: String
    let targetLanguageCode: String

    var message: String {
        switch availability {
        case .notRequired:
            "이 페이지에는 번역할 텍스트가 없습니다."
        case .installed:
            "Apple 온디바이스 번역 언어 팩이 설치되어 있습니다."
        case .downloadRequired:
            "번역을 시작하면 Apple 언어 팩 다운로드 승인을 요청합니다."
        case .unsupported:
            "Apple 온디바이스 번역이 선택한 언어 조합을 지원하지 않습니다."
        }
    }
}

enum AppleDocumentTranslationProgress: Equatable, Sendable {
    case checkingAvailability
    case availability(AppleDocumentTranslationPreflight)
    case preparingTranslation
    case translating(completed: Int, total: Int)
    case completed

    var message: String {
        switch self {
        case .checkingAvailability:
            "Apple 번역 언어 지원 상태를 확인하는 중입니다."
        case .availability(let preflight):
            preflight.message
        case .preparingTranslation:
            "Apple 번역 엔진과 언어 팩을 준비하는 중입니다."
        case .translating(let completed, let total):
            "페이지 텍스트 번역 중 \(completed)/\(total)"
        case .completed:
            "페이지 번역을 완료했습니다."
        }
    }
}

#if canImport(Translation)
/// Bridges a view-owned `TranslationSession` to the shared page translation protocol.
///
/// Create this client inside the closure supplied to SwiftUI's `translationTask` modifier,
/// await all page work there, and do not retain the client after that closure finishes.
/// `TranslationSession` is not `Sendable`, so the client remains on the main actor that
/// owns SwiftUI's translation task instead of transferring the session to another actor.
@available(macOS 15.0, *)
@MainActor
final class AppleDocumentTranslationClient: DocumentPageTranslationClient {
    typealias ProgressHandler = @MainActor @Sendable (
        AppleDocumentTranslationProgress
    ) -> Void

    // TranslationSession lacks Sendable annotations in the SDK. Access remains
    // private to this MainActor-isolated type; this narrow escape only prevents
    // its nonisolated async SDK methods from appearing to transfer stored state.
    nonisolated(unsafe) private let session: TranslationSession
    private let progressHandler: ProgressHandler?
    private var isTranslating = false

    init(
        session: TranslationSession,
        progressHandler: ProgressHandler? = nil
    ) {
        self.session = session
        self.progressHandler = progressHandler
    }

    /// Builds the configuration that the host view passes to `.translationTask`.
    nonisolated static func configuration(
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption
    ) throws -> TranslationSession.Configuration {
        let source = try AppleDocumentTranslationLanguageMapper.language(
            for: sourceLanguage,
            role: .source
        )
        guard let target = try AppleDocumentTranslationLanguageMapper.language(
            for: targetLanguage,
            role: .target
        ) else {
            throw AppleDocumentTranslationError.targetLanguageMustBeExplicit
        }
        return TranslationSession.Configuration(source: source, target: target)
    }

    /// Checks support and download state without starting a translation or requiring packs.
    nonisolated static func preflight(
        for request: DocumentPageTranslationRequest
    ) async throws -> AppleDocumentTranslationPreflight {
        try AppleDocumentTranslationResponseMapper.validateRequest(request)

        guard !request.blocks.isEmpty else {
            return AppleDocumentTranslationPreflight(
                availability: .notRequired,
                sourceLanguageCode: request.sourceLanguage.code,
                targetLanguageCode: request.targetLanguage.code
            )
        }

        let source = try AppleDocumentTranslationLanguageMapper.language(
            for: request.sourceLanguage,
            role: .source
        )
        guard let target = try AppleDocumentTranslationLanguageMapper.language(
            for: request.targetLanguage,
            role: .target
        ) else {
            throw AppleDocumentTranslationError.targetLanguageMustBeExplicit
        }

        try Task.checkCancellation()
        let checker = LanguageAvailability()
        let status: LanguageAvailability.Status
        if let source {
            status = await checker.status(from: source, to: target)
        } else {
            let pageText = request.blocks.map(\.text).joined(separator: "\n")
            status = try await checker.status(for: pageText, to: target)
        }
        try Task.checkCancellation()

        let availability: AppleDocumentTranslationLanguageAvailability
        switch status {
        case .installed:
            availability = .installed
        case .supported:
            availability = .downloadRequired
        case .unsupported:
            availability = .unsupported
        @unknown default:
            availability = .unsupported
        }

        return AppleDocumentTranslationPreflight(
            availability: availability,
            sourceLanguageCode: request.sourceLanguage.code,
            targetLanguageCode: request.targetLanguage.code
        )
    }

    func translatePage(
        _ request: DocumentPageTranslationRequest
    ) async throws -> DocumentPageTranslationResult {
        guard !isTranslating else {
            throw AppleDocumentTranslationError.translationAlreadyInProgress
        }
        isTranslating = true
        defer { isTranslating = false }

        return try await withTaskCancellationHandler {
            try await performTranslation(request)
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelFrameworkOperationIfAvailable()
            }
        }
    }

    private func performTranslation(
        _ request: DocumentPageTranslationRequest
    ) async throws -> DocumentPageTranslationResult {
        try Task.checkCancellation()
        try AppleDocumentTranslationResponseMapper.validateRequest(request)

        guard !request.blocks.isEmpty else {
            let result = try AppleDocumentTranslationResponseMapper.map([], for: request)
            report(.completed)
            return result
        }

        let expectedSource = try AppleDocumentTranslationLanguageMapper.language(
            for: request.sourceLanguage,
            role: .source
        )
        guard let expectedTarget = try AppleDocumentTranslationLanguageMapper.language(
            for: request.targetLanguage,
            role: .target
        ) else {
            throw AppleDocumentTranslationError.targetLanguageMustBeExplicit
        }
        try validateSessionConfiguration(
            expectedSource: expectedSource,
            expectedTarget: expectedTarget
        )

        report(.checkingAvailability)
        let preflight = try await Self.preflight(for: request)
        report(.availability(preflight))

        guard preflight.availability != .unsupported else {
            throw AppleDocumentTranslationError.unsupportedLanguagePair(
                source: request.sourceLanguage.code,
                target: request.targetLanguage.code
            )
        }

        try Task.checkCancellation()
        report(.preparingTranslation)
        try await session.prepareTranslation()
        try Task.checkCancellation()

        // Apple batch requests are independent translation items and do not
        // promise shared context. Packing every positioned block into one strict
        // envelope makes the page a single translation item while retaining IDs.
        let pageIdentifier = "kc-page-\(request.pageIndex)"
        let pagePayload = DocumentPageTranslationEnvelope.serialize(
            request.blocks
        )
        let batch = [
            TranslationSession.Request(
                sourceText: pagePayload,
                clientIdentifier: pageIdentifier
            )
        ]
        var translatedPage: String?

        for try await response in session.translate(batch: batch) {
            try Task.checkCancellation()
            guard response.clientIdentifier == pageIdentifier else {
                throw AppleDocumentTranslationError.unexpectedPageResponseIdentifier(
                    expected: pageIdentifier,
                    actual: response.clientIdentifier
                )
            }
            guard translatedPage == nil else {
                throw AppleDocumentTranslationError.unexpectedPageResponseCount(2)
            }
            translatedPage = response.targetText
        }

        try Task.checkCancellation()
        guard let translatedPage else {
            throw AppleDocumentTranslationError.unexpectedPageResponseCount(0)
        }
        let translations = try DocumentPageTranslationEnvelope.parse(
            translatedPage
        )
        let result = try DocumentPageTranslationValidator.validateAndOrder(
            DocumentPageTranslationResult(
                pageIndex: request.pageIndex,
                translations: translations
            ),
            for: request
        )
        report(
            .translating(
                completed: request.blocks.count,
                total: request.blocks.count
            )
        )
        report(.completed)
        return result
    }

    private func validateSessionConfiguration(
        expectedSource: Locale.Language?,
        expectedTarget: Locale.Language
    ) throws {
        guard languagesAreEquivalent(session.sourceLanguage, expectedSource),
              languagesAreEquivalent(session.targetLanguage, expectedTarget)
        else {
            throw AppleDocumentTranslationError.sessionConfigurationMismatch(
                expectedSource: expectedSource?.minimalIdentifier,
                expectedTarget: expectedTarget.minimalIdentifier,
                actualSource: session.sourceLanguage?.minimalIdentifier,
                actualTarget: session.targetLanguage?.minimalIdentifier
            )
        }
    }

    private func languagesAreEquivalent(
        _ first: Locale.Language?,
        _ second: Locale.Language?
    ) -> Bool {
        switch (first, second) {
        case (nil, nil):
            return true
        case (.some(let first), .some(let second)):
            return first.isEquivalent(to: second)
        case (.some, nil), (nil, .some):
            return false
        }
    }

    private func report(_ progress: AppleDocumentTranslationProgress) {
        guard let progressHandler else { return }
        progressHandler(progress)
    }

    private func cancelFrameworkOperationIfAvailable() {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            session.cancel()
        }
#endif
    }
}
#endif
