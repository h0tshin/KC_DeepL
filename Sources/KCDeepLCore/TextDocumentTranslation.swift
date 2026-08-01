import Foundation

/// File kinds that can be translated by the file workflow.
///
/// PDF remains a separate, geometry-aware pipeline in the app target. Text
/// documents use the structures in this file so the same engine adapter can
/// translate bounded, addressable segments and rebuild the original bytes.
public enum SupportedFileDocumentKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case pdf
    case plainText
    case markdown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pdf:
            "PDF"
        case .plainText:
            "텍스트 (TXT)"
        case .markdown:
            "Markdown (MD)"
        }
    }

    public var defaultOutputExtension: String {
        switch self {
        case .pdf:
            "pdf"
        case .plainText:
            "txt"
        case .markdown:
            "md"
        }
    }

    public var isTextBased: Bool {
        switch self {
        case .pdf:
            false
        case .plainText, .markdown:
            true
        }
    }

    public static func kind(forFileExtension pathExtension: String) -> Self? {
        switch pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pdf":
            .pdf
        case "md", "markdown", "mdown", "mkdn", "mkd", "mdwn":
            .markdown
        case "txt", "text", "log", "textile", "csv", "tsv":
            .plainText
        default:
            nil
        }
    }
}

public enum TextDocumentEncoding: String, Codable, CaseIterable, Sendable {
    case utf8
    case utf8WithBOM
    case utf16LittleEndian
    case utf16BigEndian
    case utf32LittleEndian
    case utf32BigEndian
    case isoLatin1

    fileprivate var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8WithBOM:
            .utf8
        case .utf16LittleEndian:
            .utf16LittleEndian
        case .utf16BigEndian:
            .utf16BigEndian
        case .utf32LittleEndian:
            .utf32LittleEndian
        case .utf32BigEndian:
            .utf32BigEndian
        case .isoLatin1:
            .isoLatin1
        }
    }

    fileprivate var byteOrderMark: Data {
        switch self {
        case .utf8WithBOM:
            Data([0xEF, 0xBB, 0xBF])
        case .utf16LittleEndian:
            Data([0xFF, 0xFE])
        case .utf16BigEndian:
            Data([0xFE, 0xFF])
        case .utf32LittleEndian:
            Data([0xFF, 0xFE, 0x00, 0x00])
        case .utf32BigEndian:
            Data([0x00, 0x00, 0xFE, 0xFF])
        case .utf8, .isoLatin1:
            Data()
        }
    }
}

public enum TextDocumentLineEnding: String, Codable, Sendable {
    case lf
    case crlf
    case cr
    case mixed

    fileprivate init(lineEndings: [String]) {
        let distinct = Set(lineEndings)
        if distinct.count > 1 {
            self = .mixed
        } else if distinct.first == "\r\n" {
            self = .crlf
        } else if distinct.first == "\r" {
            self = .cr
        } else {
            self = .lf
        }
    }

    fileprivate var preferredString: String {
        switch self {
        case .crlf:
            "\r\n"
        case .cr:
            "\r"
        case .lf, .mixed:
            "\n"
        }
    }
}

public enum TextDocumentDetectionError: Error, Equatable, LocalizedError, Sendable {
    case fileNotReadable(String)
    case unsupportedFileType(String)
    case invalidTextEncoding
    case emptyDocument

    public var errorDescription: String? {
        switch self {
        case let .fileNotReadable(path):
            "파일을 읽을 수 없습니다: \(path)"
        case let .unsupportedFileType(extensionName):
            extensionName.isEmpty
                ? "지원하지 않는 파일 형식입니다. PDF, TXT, MD 파일을 선택해 주세요."
                : "지원하지 않는 파일 형식입니다: .\(extensionName)"
        case .invalidTextEncoding:
            "텍스트 인코딩을 확인할 수 없습니다. UTF-8 또는 UTF-16 텍스트 파일을 사용해 주세요."
        case .emptyDocument:
            "빈 문서는 번역할 수 없습니다."
        }
    }
}

public struct TextDocumentFileDetection: Equatable, Sendable {
    public let kind: SupportedFileDocumentKind
    public let encoding: TextDocumentEncoding?
    public let byteCount: Int
    public let isEmpty: Bool
    public let markdownScore: Int
    public let confidence: Int

    public init(
        kind: SupportedFileDocumentKind,
        encoding: TextDocumentEncoding?,
        byteCount: Int,
        isEmpty: Bool,
        markdownScore: Int = 0,
        confidence: Int = 100
    ) {
        self.kind = kind
        self.encoding = encoding
        self.byteCount = byteCount
        self.isEmpty = isEmpty
        self.markdownScore = markdownScore
        self.confidence = min(100, max(0, confidence))
    }
}

/// Detects a document from both its extension and its bytes.
///
/// Extension is the first signal because it is what users see in the file
/// picker. Magic bytes and decoding are used to reject a mislabeled binary
/// file and to support extensionless text files safely.
public struct TextDocumentFileDetector: Sendable {
    public init() {}

    public func detect(sourceURL: URL) throws -> TextDocumentFileDetection {
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        } catch {
            throw TextDocumentDetectionError.fileNotReadable(sourceURL.path)
        }
        return try detect(sourceURL: sourceURL, data: data)
    }

    public func detect(
        sourceURL: URL,
        data: Data
    ) throws -> TextDocumentFileDetection {
        if data.starts(with: Data("%PDF-".utf8)) {
            return TextDocumentFileDetection(
                kind: .pdf,
                encoding: nil,
                byteCount: data.count,
                isEmpty: data.isEmpty,
                confidence: 100
            )
        }

        if let extensionKind = SupportedFileDocumentKind.kind(
            forFileExtension: sourceURL.pathExtension
        ) {
            if extensionKind == .pdf {
                return TextDocumentFileDetection(
                    kind: .pdf,
                    encoding: nil,
                    byteCount: data.count,
                    isEmpty: data.isEmpty,
                    confidence: 100
                )
            }

            let decoded = try Self.decode(data: data)
            let score = Self.markdownScore(in: decoded.text)
            return TextDocumentFileDetection(
                kind: extensionKind,
                encoding: decoded.encoding,
                byteCount: data.count,
                isEmpty: decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                markdownScore: score,
                confidence: extensionKind == .markdown ? 100 : 98
            )
        }

        let decoded = try Self.decode(data: data)
        let score = Self.markdownScore(in: decoded.text)
        let kind: SupportedFileDocumentKind = score >= 3 ? .markdown : .plainText
        return TextDocumentFileDetection(
            kind: kind,
            encoding: decoded.encoding,
            byteCount: data.count,
            isEmpty: decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            markdownScore: score,
            confidence: score >= 3 ? 82 : 72
        )
    }

    fileprivate static func decode(data: Data) throws -> (text: String, encoding: TextDocumentEncoding) {
        if data.isEmpty {
            return ("", .utf8)
        }

        let candidates: [(TextDocumentEncoding, Data)] = [
            (.utf8WithBOM, Data(data.dropFirst(3))),
            (.utf16LittleEndian, Data(data.dropFirst(2))),
            (.utf16BigEndian, Data(data.dropFirst(2))),
            (.utf32LittleEndian, Data(data.dropFirst(4))),
            (.utf32BigEndian, Data(data.dropFirst(4))),
            (.utf8, data),
            (.isoLatin1, data)
        ]

        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: candidates[0].1, encoding: .utf8) {
            return (text, .utf8WithBOM)
        }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]),
           let text = String(data: candidates[3].1, encoding: .utf32LittleEndian) {
            return (text, .utf32LittleEndian)
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]),
           let text = String(data: candidates[4].1, encoding: .utf32BigEndian) {
            return (text, .utf32BigEndian)
        }
        if data.starts(with: [0xFF, 0xFE]),
           let text = String(data: candidates[1].1, encoding: .utf16LittleEndian) {
            return (text, .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]),
           let text = String(data: candidates[2].1, encoding: .utf16BigEndian) {
            return (text, .utf16BigEndian)
        }
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8)
        }

        // ISO-8859-1 is a lossless one-byte fallback. It is intentionally
        // last so a malformed UTF-8 file is never silently preferred over a
        // valid Unicode decode. NUL and binary-control bytes are rejected so
        // a PNG/ZIP renamed to .txt is never sent to a translation engine.
        let binaryControlCount = data.reduce(into: 0) { count, byte in
            if byte == 0 || (byte < 0x09 && byte != 0x07) {
                count += 1
            }
        }
        guard binaryControlCount == 0
                || Double(binaryControlCount) / Double(max(1, data.count)) < 0.01
        else {
            throw TextDocumentDetectionError.invalidTextEncoding
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return (text, .isoLatin1)
        }
        throw TextDocumentDetectionError.invalidTextEncoding
    }

    fileprivate static func markdownScore(in text: String) -> Int {
        var score = 0
        let lines = text.components(separatedBy: .newlines)
        var sawFence = false
        for line in lines.prefix(400) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^#{1,6}\s+\S+"#, options: .regularExpression) != nil {
                score += 2
            }
            if trimmed.hasPrefix("```"), trimmed.count >= 3 {
                sawFence = true
                score += 2
            }
            if trimmed.range(of: #"^[-*+]\s+\S+"#, options: .regularExpression) != nil {
                score += 1
            }
            if trimmed.range(of: #"^\d+[.)]\s+\S+"#, options: .regularExpression) != nil {
                score += 1
            }
            if trimmed.contains("](") || trimmed.hasPrefix("> ") {
                score += 1
            }
            if trimmed.filter({ $0 == "|" }).count >= 2 {
                score += 1
            }
        }
        if sawFence {
            score += 1
        }
        return score
    }
}

public struct TextDocumentChunkingConfiguration: Equatable, Codable, Sendable {
    public let minimumCharacters: Int
    public let targetCharacters: Int
    public let maximumCharacters: Int
    public let maximumEstimatedTokens: Int
    public let maximumSegments: Int

    public init(
        minimumCharacters: Int = 700,
        targetCharacters: Int = 2_600,
        maximumCharacters: Int = 5_200,
        maximumEstimatedTokens: Int = 2_200,
        maximumSegments: Int = 40
    ) {
        let minimum = max(100, minimumCharacters)
        let maximum = max(minimum, maximumCharacters)
        self.minimumCharacters = min(minimum, maximum)
        self.targetCharacters = min(max(self.minimumCharacters, targetCharacters), maximum)
        self.maximumCharacters = maximum
        self.maximumEstimatedTokens = max(256, maximumEstimatedTokens)
        self.maximumSegments = max(1, maximumSegments)
    }

    public static let balanced = Self()

    public var description: String {
        "약 \(targetCharacters)자 단위, 최대 \(maximumCharacters)자·약 \(maximumEstimatedTokens)토큰"
    }
}

public enum TextDocumentChunkingProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case balanced
    case contextHeavy
    case responsive

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .balanced:
            "균형형 (권장)"
        case .contextHeavy:
            "문맥 우선"
        case .responsive:
            "빠른 피드백"
        }
    }

    public var detail: String {
        switch self {
        case .balanced:
            "문단·목록 경계를 유지하면서 안정적인 호출 크기를 사용합니다."
        case .contextHeavy:
            "호출 횟수를 줄이고 더 넓은 문맥을 한 번에 전달합니다."
        case .responsive:
            "청크를 작게 만들어 진행 결과를 더 자주 표시합니다."
        }
    }

    public var configuration: TextDocumentChunkingConfiguration {
        switch self {
        case .balanced:
            .init()
        case .contextHeavy:
            .init(
                minimumCharacters: 1_000,
                targetCharacters: 4_000,
                maximumCharacters: 7_200,
                maximumEstimatedTokens: 3_000,
                maximumSegments: 60
            )
        case .responsive:
            .init(
                minimumCharacters: 450,
                targetCharacters: 1_700,
                maximumCharacters: 3_600,
                maximumEstimatedTokens: 1_600,
                maximumSegments: 28
            )
        }
    }
}

public enum TextDocumentSegmentKind: String, Codable, Sendable {
    case paragraph
    case heading
    case listItem
    case blockQuote
    case tableCell
    case plainLine
    case preserved
    case codeBlock
    case frontMatter
}

/// One independently addressable text range. `prefix` and `suffix` are not
/// sent to the engine, which makes Markdown markers and line endings immune to
/// model reformatting.
public struct TextDocumentSegment: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourceText: String
    public let prefix: String
    public let suffix: String
    public let kind: TextDocumentSegmentKind
    public let translates: Bool

    public init(
        id: String,
        sourceText: String,
        prefix: String = "",
        suffix: String = "",
        kind: TextDocumentSegmentKind,
        translates: Bool = true
    ) {
        self.id = id
        self.sourceText = sourceText
        self.prefix = prefix
        self.suffix = suffix
        self.kind = kind
        self.translates = translates
    }

    public var rawText: String {
        prefix + sourceText + suffix
    }

    public var characterCount: Int {
        sourceText.count
    }
}

public struct TextDocumentChunk: Identifiable, Equatable, Sendable {
    public let id: String
    public let segmentIDs: [String]
    public let characterCount: Int
    public let estimatedTokenCount: Int

    public init(
        id: String,
        segmentIDs: [String],
        characterCount: Int,
        estimatedTokenCount: Int
    ) {
        self.id = id
        self.segmentIDs = segmentIDs
        self.characterCount = characterCount
        self.estimatedTokenCount = estimatedTokenCount
    }
}

public struct TextDocumentAnalysis: Equatable, Sendable {
    public let sourceURL: URL
    public let sourceData: Data
    public let sourceText: String
    public let kind: SupportedFileDocumentKind
    public let encoding: TextDocumentEncoding
    public let lineEnding: TextDocumentLineEnding
    public let segments: [TextDocumentSegment]
    public let chunks: [TextDocumentChunk]
    public let detection: TextDocumentFileDetection

    public init(
        sourceURL: URL,
        sourceData: Data,
        sourceText: String,
        kind: SupportedFileDocumentKind,
        encoding: TextDocumentEncoding,
        lineEnding: TextDocumentLineEnding,
        segments: [TextDocumentSegment],
        chunks: [TextDocumentChunk],
        detection: TextDocumentFileDetection
    ) {
        self.sourceURL = sourceURL
        self.sourceData = sourceData
        self.sourceText = sourceText
        self.kind = kind
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.segments = segments
        self.chunks = chunks
        self.detection = detection
    }

    public var translatableSegments: [TextDocumentSegment] {
        segments.filter(\.translates)
    }

    public var translatableSegmentCount: Int {
        translatableSegments.count
    }

    public var characterCount: Int {
        sourceText.count
    }

    public var estimatedTokenCount: Int {
        TextDocumentChunker.estimateTokens(sourceText)
    }

    public func rechunked(
        using configuration: TextDocumentChunkingConfiguration
    ) -> TextDocumentAnalysis {
        TextDocumentAnalysis(
            sourceURL: sourceURL,
            sourceData: sourceData,
            sourceText: sourceText,
            kind: kind,
            encoding: encoding,
            lineEnding: lineEnding,
            segments: segments,
            chunks: TextDocumentChunker.makeChunks(
                from: segments,
                configuration: configuration
            ),
            detection: detection
        )
    }

    public func withMarkdownCodeBlocksTranslated(
        _ shouldTranslate: Bool
    ) -> TextDocumentAnalysis {
        guard kind == .markdown, shouldTranslate else {
            return self
        }
        let adjustedSegments = segments.map { segment in
            guard segment.kind == .codeBlock,
                  !segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !segment.sourceText.trimmingCharacters(in: .whitespaces).hasPrefix("```"),
                  !segment.sourceText.trimmingCharacters(in: .whitespaces).hasPrefix("~~~")
            else {
                return segment
            }
            return TextDocumentSegment(
                id: segment.id,
                sourceText: segment.sourceText,
                prefix: segment.prefix,
                suffix: segment.suffix,
                kind: segment.kind,
                translates: true
            )
        }
        return TextDocumentAnalysis(
            sourceURL: sourceURL,
            sourceData: sourceData,
            sourceText: sourceText,
            kind: kind,
            encoding: encoding,
            lineEnding: lineEnding,
            segments: adjustedSegments,
            chunks: TextDocumentChunker.makeChunks(
                from: adjustedSegments,
                configuration: .balanced
            ),
            detection: detection
        )
    }

    public func withMarkdownStructurePreserved(
        _ shouldPreserve: Bool
    ) -> TextDocumentAnalysis {
        guard kind == .markdown, !shouldPreserve else {
            return self
        }
        let adjustedSegments = segments.map { segment in
            guard segment.translates, !segment.prefix.isEmpty else {
                return segment
            }
            return TextDocumentSegment(
                id: segment.id,
                sourceText: segment.prefix + segment.sourceText,
                prefix: "",
                suffix: segment.suffix,
                kind: segment.kind,
                translates: true
            )
        }
        return TextDocumentAnalysis(
            sourceURL: sourceURL,
            sourceData: sourceData,
            sourceText: sourceText,
            kind: kind,
            encoding: encoding,
            lineEnding: lineEnding,
            segments: adjustedSegments,
            chunks: TextDocumentChunker.makeChunks(
                from: adjustedSegments,
                configuration: .balanced
            ),
            detection: detection
        )
    }

    public func request(
        for chunk: TextDocumentChunk,
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption
    ) throws -> DocumentPageTranslationRequest {
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        let blocks = try chunk.segmentIDs.map { id in
            guard let segment = byID[id], segment.translates else {
                throw TextDocumentTranslationError.missingSegment(id)
            }
            return DocumentPageTextBlock(id: segment.id, text: segment.sourceText)
        }
        return DocumentPageTranslationRequest(
            pageIndex: Self.pageIndex(for: chunk.id),
            blocks: blocks,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    public func renderedText(
        translations: [String: String],
        preserveSourceForMissing: Bool = true
    ) -> String {
        segments.map { segment in
            guard segment.translates else {
                return segment.rawText
            }
            guard let translated = translations[segment.id],
                  !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return preserveSourceForMissing ? segment.rawText : segment.prefix + segment.suffix
            }
            return segment.prefix + translated + segment.suffix
        }.joined()
    }

    public func encodedData(
        translations: [String: String],
        preserveSourceForMissing: Bool = true
    ) throws -> Data {
        let rendered = renderedText(
            translations: translations,
            preserveSourceForMissing: preserveSourceForMissing
        )
        return try Self.encode(rendered, encoding: encoding)
    }

    fileprivate static func pageIndex(for chunkID: String) -> Int {
        Int(chunkID.split(separator: "-").last ?? "0") ?? 0
    }

    private static func encode(
        _ text: String,
        encoding: TextDocumentEncoding
    ) throws -> Data {
        guard let body = text.data(using: encoding.stringEncoding) else {
            throw TextDocumentTranslationError.cannotEncode(encoding.rawValue)
        }
        if encoding.byteOrderMark.isEmpty {
            return body
        }
        var output = encoding.byteOrderMark
        output.append(body)
        return output
    }
}

public enum TextDocumentTranslationError: Error, Equatable, LocalizedError, Sendable {
    case noTranslatableText
    case missingSegment(String)
    case cannotEncode(String)

    public var errorDescription: String? {
        switch self {
        case .noTranslatableText:
            "번역할 수 있는 텍스트가 없습니다."
        case let .missingSegment(id):
            "텍스트 번역 청크에 필요한 영역이 없습니다: \(id)"
        case let .cannotEncode(encoding):
            "번역 결과를 원본 인코딩(\(encoding))으로 저장할 수 없습니다."
        }
    }
}

public struct TextDocumentAnalyzer: Sendable {
    public let chunking: TextDocumentChunkingConfiguration

    public init(chunking: TextDocumentChunkingConfiguration = .balanced) {
        self.chunking = chunking
    }

    public func analyze(sourceURL: URL) throws -> TextDocumentAnalysis {
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        } catch {
            throw TextDocumentDetectionError.fileNotReadable(sourceURL.path)
        }
        let detection = try TextDocumentFileDetector().detect(
            sourceURL: sourceURL,
            data: data
        )
        return try analyze(sourceURL: sourceURL, sourceData: data, detection: detection)
    }

    public func analyze(
        sourceURL: URL,
        sourceData: Data,
        detection: TextDocumentFileDetection
    ) throws -> TextDocumentAnalysis {
        guard detection.kind.isTextBased else {
            throw TextDocumentDetectionError.unsupportedFileType(sourceURL.pathExtension)
        }
        guard let encoding = detection.encoding else {
            throw TextDocumentDetectionError.invalidTextEncoding
        }
        let decoded = try TextDocumentFileDetector.decode(data: sourceData)
        guard !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextDocumentDetectionError.emptyDocument
        }

        let lines = Self.splitLinesPreservingEndings(decoded.text)
        let lineEnding = TextDocumentLineEnding(
            lineEndings: lines.compactMap { $0.lineEnding.isEmpty ? nil : $0.lineEnding }
        )
        let segments = Self.makeSegments(
            lines: lines,
            kind: detection.kind,
            maximumSegmentCharacters: chunking.maximumCharacters
        )
        let chunks = TextDocumentChunker.makeChunks(
            from: segments,
            configuration: chunking
        )
        return TextDocumentAnalysis(
            sourceURL: sourceURL.standardizedFileURL,
            sourceData: sourceData,
            sourceText: decoded.text,
            kind: detection.kind,
            encoding: encoding,
            lineEnding: lineEnding,
            segments: segments,
            chunks: chunks,
            detection: detection
        )
    }
}

private extension TextDocumentAnalyzer {
    struct SourceLine {
        let content: String
        let lineEnding: String
    }

    static func splitLinesPreservingEndings(_ text: String) -> [SourceLine] {
        var result: [SourceLine] = []
        var current = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x0A {
                result.append(SourceLine(content: current, lineEnding: "\n"))
                current.removeAll(keepingCapacity: true)
                index += 1
            } else if scalar.value == 0x0D {
                if index + 1 < scalars.count, scalars[index + 1].value == 0x0A {
                    result.append(SourceLine(content: current, lineEnding: "\r\n"))
                    current.removeAll(keepingCapacity: true)
                    index += 2
                } else {
                    result.append(SourceLine(content: current, lineEnding: "\r"))
                    current.removeAll(keepingCapacity: true)
                    index += 1
                }
            } else {
                current.unicodeScalars.append(scalar)
                index += 1
            }
        }
        if !current.isEmpty || result.isEmpty {
            result.append(SourceLine(content: current, lineEnding: ""))
        }
        return result
    }

    static func makeSegments(
        lines: [SourceLine],
        kind: SupportedFileDocumentKind,
        maximumSegmentCharacters: Int
    ) -> [TextDocumentSegment] {
        var result: [TextDocumentSegment] = []
        var inCodeFence = false
        var inFrontMatter = false
        var inHTMLComment = false
        var lineNumber = 0

        for line in lines {
            let trimmed = line.content.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")

            if kind == .markdown {
                if lineNumber == 0, trimmed == "---" {
                    inFrontMatter = true
                }

                if inFrontMatter {
                    result.append(preservedSegment(
                        line: line,
                        lineNumber: lineNumber,
                        kind: .frontMatter
                    ))
                    if lineNumber > 0, trimmed == "---" || trimmed == "..." {
                        inFrontMatter = false
                    }
                    lineNumber += 1
                    continue
                }

                if inHTMLComment || trimmed.hasPrefix("<!--") {
                    inHTMLComment = !trimmed.contains("-->")
                    result.append(preservedSegment(
                        line: line,
                        lineNumber: lineNumber,
                        kind: .preserved
                    ))
                    lineNumber += 1
                    continue
                }

                if isFence {
                    inCodeFence.toggle()
                    result.append(preservedSegment(
                        line: line,
                        lineNumber: lineNumber,
                        kind: .codeBlock
                    ))
                    lineNumber += 1
                    continue
                }
                if inCodeFence {
                    result.append(preservedSegment(
                        line: line,
                        lineNumber: lineNumber,
                        kind: .codeBlock
                    ))
                    lineNumber += 1
                    continue
                }
            }

            if trimmed.isEmpty {
                result.append(preservedSegment(
                    line: line,
                    lineNumber: lineNumber,
                    kind: .preserved
                ))
                lineNumber += 1
                continue
            }

            if kind == .markdown, isMarkdownThematicBreak(trimmed) {
                result.append(preservedSegment(
                    line: line,
                    lineNumber: lineNumber,
                    kind: .preserved
                ))
                lineNumber += 1
                continue
            }

            if kind == .markdown, line.content.filter({ $0 == "|" }).count >= 2 {
                result.append(contentsOf: makeTableSegments(
                    line: line,
                    lineNumber: lineNumber
                ))
                lineNumber += 1
                continue
            }

            let syntax = kind == .markdown
                ? markdownSyntax(for: line.content)
                : MarkdownSyntax(prefix: "", content: line.content, kind: .plainLine)
            let contentParts = splitLongContent(
                syntax.content,
                maximumCharacters: maximumSegmentCharacters
            )

            for (partIndex, part) in contentParts.enumerated() {
                let isLast = partIndex == contentParts.count - 1
                let prefix = partIndex == 0 ? syntax.prefix : ""
                let suffix = isLast ? line.lineEnding : part.separator
                result.append(TextDocumentSegment(
                    id: String(format: "text-%06d-%03d", lineNumber, partIndex),
                    sourceText: part.text,
                    prefix: prefix,
                    suffix: suffix,
                    kind: syntax.kind,
                    translates: true
                ))
            }
            lineNumber += 1
        }
        return result
    }

    struct MarkdownSyntax {
        let prefix: String
        let content: String
        let kind: TextDocumentSegmentKind
    }

    static func markdownSyntax(for line: String) -> MarkdownSyntax {
        let patterns: [(String, TextDocumentSegmentKind)] = [
            (#"^\s*#{1,6}\s+"#, .heading),
            (#"^\s*>+\s*"#, .blockQuote),
            (#"^\s*(?:[-*+]\s+|\d+[.)]\s+)"#, .listItem)
        ]
        for (pattern, segmentKind) in patterns {
            if let range = line.range(of: pattern, options: .regularExpression) {
                return MarkdownSyntax(
                    prefix: String(line[range]),
                    content: String(line[range.upperBound...]),
                    kind: segmentKind
                )
            }
        }
        if line.filter({ $0 == "|" }).count >= 2 {
            return MarkdownSyntax(prefix: "", content: line, kind: .tableCell)
        }
        return MarkdownSyntax(prefix: "", content: line, kind: .paragraph)
    }

    static func makeTableSegments(
        line: SourceLine,
        lineNumber: Int
    ) -> [TextDocumentSegment] {
        let pipeIndices = line.content.indices.filter { index in
            guard line.content[index] == "|" else {
                return false
            }
            let previous = index > line.content.startIndex
                ? line.content[line.content.index(before: index)]
                : nil
            return previous != "\\"
        }
        guard pipeIndices.count >= 2 else {
            return [preservedSegment(line: line, lineNumber: lineNumber, kind: .preserved)]
        }

        var boundaries = [line.content.startIndex]
        boundaries.append(contentsOf: pipeIndices)
        boundaries.append(line.content.endIndex)

        var segments: [TextDocumentSegment] = []
        for cellIndex in 0..<(boundaries.count - 1) {
            let cellStart = boundaries[cellIndex]
            let cellEnd = boundaries[cellIndex + 1]
            let rawCell = String(line.content[cellStart..<cellEnd])
            let isLastCell = cellIndex == boundaries.count - 2
            let trailingDelimiter = isLastCell
                ? String(line.content[cellEnd...])
                : ""

            let nonWhitespaceStart = rawCell.firstIndex {
                !$0.isWhitespace && $0 != "|"
            }
            let nonWhitespaceEnd = rawCell.lastIndex {
                !$0.isWhitespace && $0 != "|"
            }.map { rawCell.index(after: $0) }

            guard let contentStart = nonWhitespaceStart,
                  let contentEnd = nonWhitespaceEnd,
                  contentStart < contentEnd
            else {
                let suffix = (isLastCell ? trailingDelimiter : "")
                    + (isLastCell ? line.lineEnding : "")
                segments.append(TextDocumentSegment(
                    id: String(format: "table-%06d-%03d", lineNumber, cellIndex),
                    sourceText: rawCell,
                    suffix: suffix,
                    kind: .preserved,
                    translates: false
                ))
                continue
            }

            let prefix = String(rawCell[..<contentStart])
            let source = String(rawCell[contentStart..<contentEnd])
            var suffix = String(rawCell[contentEnd...])
            if isLastCell {
                suffix += trailingDelimiter
                suffix += line.lineEnding
            }
            segments.append(TextDocumentSegment(
                id: String(format: "table-%06d-%03d", lineNumber, cellIndex),
                sourceText: source,
                prefix: prefix,
                suffix: suffix,
                kind: .tableCell,
                translates: true
            ))
        }
        return segments
    }

    static func preservedSegment(
        line: SourceLine,
        lineNumber: Int,
        kind: TextDocumentSegmentKind
    ) -> TextDocumentSegment {
        TextDocumentSegment(
            id: String(format: "preserved-%06d", lineNumber),
            sourceText: line.content,
            suffix: line.lineEnding,
            kind: kind,
            translates: false
        )
    }

    static func isMarkdownThematicBreak(_ line: String) -> Bool {
        line.range(of: #"^(?:[-*_]\s*){3,}$"#, options: .regularExpression) != nil
            || line.range(of: #"^\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?$"#, options: .regularExpression) != nil
    }

    struct ContentPart {
        let text: String
        let separator: String
    }

    static func splitLongContent(
        _ content: String,
        maximumCharacters: Int
    ) -> [ContentPart] {
        guard content.count > maximumCharacters else {
            return [ContentPart(text: content, separator: "")]
        }

        var result: [ContentPart] = []
        var remaining = content
        while remaining.count > maximumCharacters {
            let limitIndex = remaining.index(
                remaining.startIndex,
                offsetBy: maximumCharacters,
                limitedBy: remaining.endIndex
            ) ?? remaining.endIndex
            let candidate = remaining[..<limitIndex]
            let splitIndex = bestSplitIndex(in: candidate)
            let partEnd = splitIndex ?? limitIndex
            let part = String(remaining[..<partEnd])
            guard !part.isEmpty else {
                break
            }
            var nextStart = partEnd
            var separator = ""
            while nextStart < remaining.endIndex,
                  remaining[nextStart].isWhitespace,
                  remaining[nextStart] != "\n",
                  remaining[nextStart] != "\r" {
                separator.append(remaining[nextStart])
                nextStart = remaining.index(after: nextStart)
            }
            result.append(ContentPart(text: part, separator: separator))
            remaining = String(remaining[nextStart...])
        }
        if !remaining.isEmpty {
            result.append(ContentPart(text: remaining, separator: ""))
        }
        return result.isEmpty ? [ContentPart(text: content, separator: "")] : result
    }

    static func bestSplitIndex(in candidate: Substring) -> String.Index? {
        let sentenceTerminators: Set<Character> = [".", "!", "?", "。", "！", "？"]
        var lastSentence: String.Index?
        var lastWhitespace: String.Index?
        for index in candidate.indices {
            let character = candidate[index]
            if sentenceTerminators.contains(character) {
                lastSentence = candidate.index(after: index)
            }
            if character.isWhitespace {
                lastWhitespace = index
            }
        }
        if let lastSentence {
            return lastSentence
        }
        if let lastWhitespace {
            return lastWhitespace
        }
        return nil
    }
}

public enum TextDocumentChunker {
    public static func makeChunks(
        from segments: [TextDocumentSegment],
        configuration: TextDocumentChunkingConfiguration = .balanced
    ) -> [TextDocumentChunk] {
        let translatable = segments.filter(\.translates)
        guard !translatable.isEmpty else {
            return []
        }

        var chunks: [TextDocumentChunk] = []
        var currentIDs: [String] = []
        var currentCharacters = 0
        var currentTokens = 0
        var chunkNumber = 0

        func flush() {
            guard !currentIDs.isEmpty else {
                return
            }
            chunks.append(TextDocumentChunk(
                id: String(format: "chunk-%06d", chunkNumber),
                segmentIDs: currentIDs,
                characterCount: currentCharacters,
                estimatedTokenCount: currentTokens
            ))
            chunkNumber += 1
            currentIDs.removeAll(keepingCapacity: true)
            currentCharacters = 0
            currentTokens = 0
        }

        for segment in translatable {
            let characters = segment.characterCount
            let tokens = estimateTokens(segment.sourceText)
            let wouldExceedMaximum = !currentIDs.isEmpty && (
                currentCharacters + characters > configuration.maximumCharacters
                    || currentTokens + tokens > configuration.maximumEstimatedTokens
                    || currentIDs.count >= configuration.maximumSegments
            )
            if wouldExceedMaximum {
                flush()
            }
            currentIDs.append(segment.id)
            currentCharacters += characters
            currentTokens += tokens

            let reachedTarget = currentCharacters >= configuration.targetCharacters
                || currentTokens >= configuration.maximumEstimatedTokens
            if reachedTarget, currentCharacters >= configuration.minimumCharacters {
                flush()
            }
        }
        flush()

        // Avoid a tiny tail caused by a semantic boundary. It is better to
        // give one final model call a little more context than to ask for a
        // low-signal fragment by itself.
        guard chunks.count >= 2,
              let last = chunks.last,
              last.characterCount < configuration.minimumCharacters
        else {
            return chunks
        }
        let previousIndex = chunks.index(before: chunks.endIndex)
        let previous = chunks[previousIndex - 1]
        guard previous.characterCount + last.characterCount <= configuration.maximumCharacters,
              previous.estimatedTokenCount + last.estimatedTokenCount <= configuration.maximumEstimatedTokens,
              previous.segmentIDs.count + last.segmentIDs.count <= configuration.maximumSegments
        else {
            return chunks
        }
        chunks[previousIndex - 1] = TextDocumentChunk(
            id: previous.id,
            segmentIDs: previous.segmentIDs + last.segmentIDs,
            characterCount: previous.characterCount + last.characterCount,
            estimatedTokenCount: previous.estimatedTokenCount + last.estimatedTokenCount
        )
        chunks.removeLast()
        return chunks
    }

    public static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else {
            return 0
        }
        var estimate = 0.0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7AF,
                 0x3040...0x30FF,
                 0x3400...0x9FFF:
                estimate += 1.0
            case 0x20...0x7E:
                estimate += 0.25
            default:
                estimate += 0.75
            }
        }
        return max(1, Int(ceil(estimate)))
    }
}
