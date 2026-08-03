import Foundation

/// A font family packaged into a PresentationML document. PowerPoint expects
/// embedded fonts to be EOT payloads (fntdata) referenced by the presentation
/// part rather than ordinary TTF resources.
struct PresentationEmbeddedFont {
    enum Variant: String {
        case regular
        case bold
        case italic
        case boldItalic

        var elementName: String { rawValue }
    }

    struct Face {
        let variant: Variant
        let eotData: Data
    }

    let typeface: String
    let panose: String
    let pitchFamily: Int
    let charset: Int
    let faces: [Face]
}

/// Resolves the OFL fonts that KC DeepL is allowed to redistribute from its own
/// bundle. Process-local AppKit registration is deliberately not sufficient:
/// it disappears when the generated file is opened by PowerPoint or Word.
enum OfficeEmbeddedFontCatalog {
    static func canEmbedPresentationTypeface(_ typeface: String) -> Bool {
        isBundledBarlowTypeface(typeface) && barlow != nil
    }

    static func presentationFonts(
        usedTypefaceNames: Set<String>
    ) -> [PresentationEmbeddedFont] {
        guard usedTypefaceNames.contains(where: {
            isBundledBarlowTypeface($0)
        }), let barlow
        else {
            return []
        }
        return [barlow]
    }

    private struct Resource {
        let name: String
        let variant: PresentationEmbeddedFont.Variant
        let styleName: String
        let fullName: String
        let weight: UInt32
        let italic: Bool
    }

    /// All four variants must be present. Substituting a synthesized bold or
    /// italic face would change the line geometry even when the regular face
    /// is embedded correctly.
    private static let barlow: PresentationEmbeddedFont? = {
        let resources = [
            Resource(
                name: "Barlow-Regular",
                variant: .regular,
                styleName: "Regular",
                fullName: "Barlow Regular",
                weight: 400,
                italic: false
            ),
            Resource(
                name: "Barlow-Bold",
                variant: .bold,
                styleName: "Bold",
                fullName: "Barlow Bold",
                weight: 700,
                italic: false
            ),
            Resource(
                name: "Barlow-Italic",
                variant: .italic,
                styleName: "Italic",
                fullName: "Barlow Italic",
                weight: 400,
                italic: true
            ),
            Resource(
                name: "Barlow-BoldItalic",
                variant: .boldItalic,
                styleName: "Bold Italic",
                fullName: "Barlow Bold Italic",
                weight: 700,
                italic: true
            )
        ]

        do {
            let faces = try resources.map { resource in
                guard let url = AppResourceLocator.url(
                    forResource: resource.name,
                    withExtension: "ttf",
                    subdirectory: "Fonts/Barlow"
                ) else {
                    throw CatalogError.resourceUnavailable(resource.name)
                }
                let fontData = try Data(contentsOf: url, options: .mappedIfSafe)
                guard fontData.count >= 12,
                      hasTrueTypeSignature(fontData)
                else {
                    throw CatalogError.invalidFont(resource.name)
                }

                let fsType = try embeddingPermissions(in: fontData)
                guard fsType & 0x0002 == 0, fsType & 0x0200 == 0 else {
                    throw CatalogError.restrictedEmbedding(resource.name)
                }

                return PresentationEmbeddedFont.Face(
                    variant: resource.variant,
                    eotData: makeEOTPayload(
                        fontData: fontData,
                        styleName: resource.styleName,
                        fullName: resource.fullName,
                        weight: resource.weight,
                        italic: resource.italic,
                        fsType: fsType
                    )
                )
            }
            return PresentationEmbeddedFont(
                typeface: "Barlow",
                panose: "020B0504020101010102",
                pitchFamily: 0x22,
                charset: 0,
                faces: faces
            )
        } catch {
            return nil
        }
    }()

    private enum CatalogError: Error {
        case resourceUnavailable(String)
        case invalidFont(String)
        case restrictedEmbedding(String)
    }

    /// Builds an uncompressed, version-1 EOT container. EOT explicitly permits
    /// raw TrueType/OpenType data, so no third-party compressor or DLL is
    /// required on macOS. The source Barlow files are SIL OFL licensed and
    /// permit editable embedding.
    private static func makeEOTPayload(
        fontData: Data,
        styleName: String,
        fullName: String,
        weight: UInt32,
        italic: Bool,
        fsType: UInt16
    ) -> Data {
        var result = Data()
        result.appendEOTUInt32(0) // EOTSize, patched after appending FontData.
        result.appendEOTUInt32(UInt32(fontData.count))
        result.appendEOTUInt32(0x0001_0000)
        result.appendEOTUInt32(0) // Raw, full-font payload.
        result.append(contentsOf: [
            0x02, 0x0B, 0x05, 0x04, 0x02,
            0x01, 0x01, 0x01, 0x01, 0x02
        ])
        result.append(1) // DEFAULT_CHARSET
        result.append(italic ? 1 : 0)
        result.appendEOTUInt32(weight)
        result.appendEOTUInt16(fsType)
        result.appendEOTUInt16(0x504C)
        // Unicode and code-page ranges are advisory for fallback selection;
        // the actual glyph set is carried by the raw TTF data below.
        for _ in 0..<6 {
            result.appendEOTUInt32(0)
        }
        result.appendEOTUInt32(0) // head.CheckSumAdjustment
        for _ in 0..<4 {
            result.appendEOTUInt32(0)
        }
        result.appendEOTUInt16(0)
        result.appendEOTString("Barlow")
        result.appendEOTUInt16(0)
        result.appendEOTString(styleName)
        result.appendEOTUInt16(0)
        result.appendEOTString("Version 1.0")
        result.appendEOTUInt16(0)
        result.appendEOTString(fullName)
        result.append(fontData)

        result.replaceSubrange(
            0..<4,
            with: eotLittleEndian(UInt32(result.count))
        )
        return result
    }

    /// The OS/2 fsType flags are the authoritative embedding restriction in a
    /// TrueType file. We intentionally refuse restricted and bitmap-only
    /// resources even if someone accidentally replaces an app asset later.
    private static func embeddingPermissions(in fontData: Data) throws -> UInt16 {
        guard let tableCount = eotBigEndianUInt16(fontData, at: 4) else {
            throw CatalogError.invalidFont("TrueType table count")
        }
        let directoryEnd = 12 + Int(tableCount) * 16
        guard directoryEnd <= fontData.count else {
            throw CatalogError.invalidFont("TrueType directory")
        }

        for index in 0..<Int(tableCount) {
            let offset = 12 + index * 16
            guard let tag = fontData.eotData(in: offset..<(offset + 4)),
                  String(data: tag, encoding: .ascii) == "OS/2",
                  let tableOffset = eotBigEndianUInt32(fontData, at: offset + 8),
                  let tableLength = eotBigEndianUInt32(fontData, at: offset + 12)
            else {
                continue
            }
            let start = Int(tableOffset)
            let length = Int(tableLength)
            guard start >= 0,
                  length >= 10,
                  start <= fontData.count,
                  length <= fontData.count - start,
                  let fsType = eotBigEndianUInt16(fontData, at: start + 8)
            else {
                throw CatalogError.invalidFont("OS/2 table")
            }
            return fsType
        }

        // OpenType treats a missing OS/2 table as least restrictive.
        return 0
    }

    private static func hasTrueTypeSignature(_ data: Data) -> Bool {
        guard let signature = data.eotData(in: 0..<4) else { return false }
        return signature == Data([0x00, 0x01, 0x00, 0x00])
            || signature == Data("true".utf8)
    }

    private static func normalizedTypeface(_ value: String) -> String {
        value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    private static func isBundledBarlowTypeface(_ value: String) -> Bool {
        switch normalizedTypeface(value) {
        case "barlow", "barlowregular", "barlowsemibold",
             "barlowbold", "barlowitalic", "barlowsemibolditalic",
             "barlowbolditalic":
            true
        default:
            false
        }
    }
}

private func eotBigEndianUInt16(_ data: Data, at offset: Int) -> UInt16? {
    guard let value = data.eotData(in: offset..<(offset + 2)) else {
        return nil
    }
    return UInt16(value[value.startIndex]) << 8
        | UInt16(value[value.startIndex + 1])
}

private func eotBigEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard let value = data.eotData(in: offset..<(offset + 4)) else {
        return nil
    }
    return UInt32(value[value.startIndex]) << 24
        | UInt32(value[value.startIndex + 1]) << 16
        | UInt32(value[value.startIndex + 2]) << 8
        | UInt32(value[value.startIndex + 3])
}

private func eotLittleEndian(_ value: UInt32) -> Data {
    Data([
        UInt8(value & 0x0000_00ff),
        UInt8((value >> 8) & 0x0000_00ff),
        UInt8((value >> 16) & 0x0000_00ff),
        UInt8((value >> 24) & 0x0000_00ff)
    ])
}

private extension Data {
    func eotData(in range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0,
              range.upperBound >= range.lowerBound,
              range.upperBound <= count
        else {
            return nil
        }
        return subdata(in: range)
    }

    mutating func appendEOTUInt16(_ value: UInt16) {
        append(UInt8(value & 0x00ff))
        append(UInt8((value >> 8) & 0x00ff))
    }

    mutating func appendEOTUInt32(_ value: UInt32) {
        append(eotLittleEndian(value))
    }

    mutating func appendEOTString(_ value: String) {
        var encoded = Data()
        for codeUnit in value.utf16 {
            encoded.appendEOTUInt16(codeUnit)
        }
        appendEOTUInt16(UInt16(encoded.count))
        append(encoded)
    }
}
