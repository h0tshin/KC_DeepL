import Foundation

enum OOXMLPackageError: Error, LocalizedError, Equatable {
    case duplicatePart(String)
    case unsafePartName(String)
    case packageTooLarge
    case invalidXML(String)
    case missingPart(String)
    case danglingRelationship(String)

    var errorDescription: String? {
        switch self {
        case let .duplicatePart(name):
            "중복된 OOXML part입니다: \(name)"
        case let .unsafePartName(name):
            "안전하지 않은 OOXML part 경로입니다: \(name)"
        case .packageTooLarge:
            "Office package가 ZIP32 크기 제한을 넘었습니다."
        case let .invalidXML(name):
            "OOXML XML을 읽을 수 없습니다: \(name)"
        case let .missingPart(name):
            "필수 OOXML part가 없습니다: \(name)"
        case let .danglingRelationship(name):
            "OOXML relationship 대상이 없습니다: \(name)"
        }
    }
}

struct OOXMLPart {
    let name: String
    let data: Data

    init(name: String, data: Data) throws {
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.split(separator: "/").contains(".."),
              !normalized.contains("%2e"),
              !normalized.contains("%2E")
        else {
            throw OOXMLPackageError.unsafePartName(name)
        }
        self.name = normalized
        self.data = data
    }

    init(name: String, xml: String) throws {
        try self.init(name: name, data: Data(xml.utf8))
    }
}

/// A dependency-free ZIP writer. OOXML permits stored (uncompressed) entries,
/// which keeps the macOS app self-contained and makes output deterministic.
struct SimpleZIPWriter {
    private struct CentralRecord {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    func write(parts: [OOXMLPart], to url: URL) throws {
        var unique: [String: OOXMLPart] = [:]
        unique.reserveCapacity(parts.count)
        for part in parts {
            guard unique[part.name] == nil else {
                throw OOXMLPackageError.duplicatePart(part.name)
            }
            unique[part.name] = part
        }

        let ordered = unique.values.sorted { $0.name < $1.name }
        var output = Data()
        var central: [CentralRecord] = []
        central.reserveCapacity(ordered.count)

        for part in ordered {
            try Task.checkCancellation()
            let nameData = Data(part.name.utf8)
            guard nameData.count <= Int(UInt16.max),
                  part.data.count <= Int(UInt32.max),
                  output.count <= Int(UInt32.max)
            else {
                throw OOXMLPackageError.packageTooLarge
            }
            let crc = CRC32.checksum(part.data)
            let offset = UInt32(output.count)
            output.appendUInt32(0x04034b50)
            output.appendUInt16(20)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt32(crc)
            output.appendUInt32(UInt32(part.data.count))
            output.appendUInt32(UInt32(part.data.count))
            output.appendUInt16(UInt16(nameData.count))
            output.appendUInt16(0)
            output.append(nameData)
            output.append(part.data)
            central.append(
                CentralRecord(
                    name: nameData,
                    crc: crc,
                    size: UInt32(part.data.count),
                    offset: offset
                )
            )
        }

        let centralOffset = output.count
        for record in central {
            output.appendUInt32(0x02014b50)
            output.appendUInt16(20)
            output.appendUInt16(20)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt32(record.crc)
            output.appendUInt32(record.size)
            output.appendUInt32(record.size)
            output.appendUInt16(UInt16(record.name.count))
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt32(0)
            output.appendUInt32(record.offset)
            output.append(record.name)
        }

        let centralSize = output.count - centralOffset
        guard centralOffset <= Int(UInt32.max),
              centralSize <= Int(UInt32.max),
              central.count <= Int(UInt16.max)
        else {
            throw OOXMLPackageError.packageTooLarge
        }
        output.appendUInt32(0x06054b50)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(UInt16(central.count))
        output.appendUInt16(UInt16(central.count))
        output.appendUInt32(UInt32(centralSize))
        output.appendUInt32(UInt32(centralOffset))
        output.appendUInt16(0)
        try output.write(to: url, options: .atomic)
    }
}

enum XMLValue {
    static func escape(_ value: String, preserveWhitespace: Bool = false) -> String {
        var result = String()
        result.reserveCapacity(value.utf8.count + 16)
        for scalar in value.unicodeScalars {
            let code = scalar.value
            guard code == 0x9 || code == 0xA || code == 0xD
                    || (code >= 0x20 && code <= 0xD7FF)
                    || (code >= 0xE000 && code <= 0xFFFD)
                    || code >= 0x10000
            else {
                continue
            }
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        if preserveWhitespace {
            return result
        }
        return result
    }

    static func attribute(_ value: String) -> String {
        escape(value)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var c = UInt32(value)
        for _ in 0..<8 {
            c = (c & 1) == 1 ? 0xedb88320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}

enum OOXMLPackageValidator {
    static func validate(
        parts: [OOXMLPart],
        format: DocumentConversionFormat
    ) throws {
        let names = Set(parts.map(\.name))
        let required: Set<String>
        switch format {
        case .pptx:
            required = [
                "[Content_Types].xml",
                "_rels/.rels",
                "ppt/presentation.xml",
                "ppt/_rels/presentation.xml.rels",
                "ppt/presProps.xml",
                "ppt/viewProps.xml",
                "ppt/tableStyles.xml",
                "ppt/slideMasters/slideMaster1.xml",
                "ppt/slideLayouts/slideLayout1.xml",
                "ppt/theme/theme1.xml",
                "docProps/core.xml",
                "docProps/app.xml"
            ]
        case .docx:
            required = [
                "[Content_Types].xml",
                "_rels/.rels",
                "word/document.xml",
                "word/_rels/document.xml.rels",
                "word/styles.xml",
                "word/settings.xml",
                "word/theme/theme1.xml",
                "word/fontTable.xml",
                "docProps/core.xml",
                "docProps/app.xml"
            ]
        }
        for name in required where !names.contains(name) {
            throw OOXMLPackageError.missingPart(name)
        }

        for part in parts where part.name.hasSuffix(".xml") || part.name == "[Content_Types].xml" {
            let parser = XMLParser(data: part.data)
            let delegate = XMLValidationDelegate()
            parser.delegate = delegate
            guard parser.parse(), !delegate.failed else {
                throw OOXMLPackageError.invalidXML(part.name)
            }
        }

        // Relationship targets are intentionally conservative. All internal
        // targets generated by these writers are relative and must exist.
        for part in parts where part.name.hasSuffix(".rels") {
            let text = String(decoding: part.data, as: UTF8.self)
            let targets = relationshipTargets(in: text)
            let base = part.name
                .components(separatedBy: "/_rels/").first
                .map { $0.isEmpty ? "" : $0 + "/" } ?? ""
            for target in targets where !target.hasPrefix("http://")
                && !target.hasPrefix("https://")
                && !target.hasPrefix("mailto:") {
                let normalized: String
                if target.hasPrefix("/") {
                    normalized = String(target.dropFirst())
                } else if part.name == "_rels/.rels" {
                    normalized = target
                } else {
                    let sourceDirectory = part.name
                        .deletingLastPathComponent()
                        .replacingOccurrences(of: "_rels", with: "")
                    normalized = normalizeRelative(
                        target,
                        relativeTo: sourceDirectory
                    )
                }
                guard names.contains(normalized) else {
                    throw OOXMLPackageError.danglingRelationship(
                        "\(part.name) -> \(target) (base \(base))"
                    )
                }
            }
        }
    }

    private static func relationshipTargets(in xml: String) -> [String] {
        let pattern = #"Target="([^"]+)""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return expression.matches(in: xml, range: range).compactMap { match in
            guard let targetRange = Range(match.range(at: 1), in: xml) else {
                return nil
            }
            return String(xml[targetRange])
        }
    }

    private static func normalizeRelative(_ target: String, relativeTo directory: String) -> String {
        let components = (directory.isEmpty ? [] : directory.split(separator: "/"))
            + target.split(separator: "/")
        var result: [Substring] = []
        for component in components {
            if component == "." || component.isEmpty { continue }
            if component == ".." {
                if !result.isEmpty { result.removeLast() }
            } else {
                result.append(component)
            }
        }
        return result.map(String.init).joined(separator: "/")
    }
}

private final class XMLValidationDelegate: NSObject, XMLParserDelegate {
    var failed = false

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failed = true
    }
}

private extension String {
    func deletingLastPathComponent() -> String {
        guard let slash = lastIndex(of: "/") else { return "" }
        return String(prefix(upTo: slash))
    }
}
