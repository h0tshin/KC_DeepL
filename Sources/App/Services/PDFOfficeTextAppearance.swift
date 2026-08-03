import AppKit
import CoreText
import Foundation

/// Converts PDFKit's local font information into names and traits that Office
/// applications can use consistently. PDF font resource names are often
/// PostScript names or subset names and are not valid OOXML typeface values.
enum PDFOfficeTextAppearance {
    private struct FontResolution {
        let familyName: String
        let isBold: Bool
        let isItalic: Bool
        let isPortable: Bool
    }

    /// Builds visual runs while preserving the original text order and
    /// collapsing only PDF-inserted whitespace. The result's concatenated text
    /// is suitable for both the translation pipeline and OOXML serialization.
    static func runs(
        from attributedString: NSAttributedString?,
        fallbackFontName: String,
        fallbackFontSize: CGFloat,
        fallbackColor: PDFTextColor,
        forceSystemFallback: Bool = false
    ) -> [PDFTextRun] {
        guard let attributedString, attributedString.length > 0 else {
            return [
                makeRun(
                    text: "",
                    font: nil,
                    fallbackFontName: fallbackFontName,
                    fallbackFontSize: fallbackFontSize,
                    fallbackColor: fallbackColor,
                    forceSystemFallback: forceSystemFallback
                )
            ]
        }

        let source = attributedString.string as NSString
        var result: [PDFTextRun] = []
        var pendingWhitespace = false
        var index = 0

        while index < source.length {
            let range = source.rangeOfComposedCharacterSequence(at: index)
            let fragment = source.substring(with: range)
            index = NSMaxRange(range)

            if isWhitespace(fragment) {
                pendingWhitespace = !result.isEmpty
                continue
            }

            let attributes = attributedString.attributes(at: range.location, effectiveRange: nil)
            let font = attributes[.font] as? NSFont
            let color = (attributes[.foregroundColor] as? NSColor)
                .flatMap { $0.usingColorSpace(.deviceRGB) }
            let runColor = color.map(PDFTextColor.init) ?? fallbackColor
            let prefix = pendingWhitespace ? " " : ""
            pendingWhitespace = false
            append(
                makeRun(
                    text: prefix + fragment,
                    font: font,
                    fallbackFontName: fallbackFontName,
                    fallbackFontSize: fallbackFontSize,
                    fallbackColor: runColor,
                    forceSystemFallback: forceSystemFallback
                ),
                to: &result
            )
        }

        return result.isEmpty
            ? [
                makeRun(
                    text: "",
                    font: nil,
                    fallbackFontName: fallbackFontName,
                    fallbackFontSize: fallbackFontSize,
                    fallbackColor: fallbackColor,
                    forceSystemFallback: forceSystemFallback
                )
            ]
            : result
    }

    static func run(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        color: PDFTextColor,
        forceSystemFallback: Bool = false
    ) -> PDFTextRun {
        makeRun(
            text: text,
            font: nil,
            fallbackFontName: fontName,
            fallbackFontSize: fontSize,
            fallbackColor: color,
            forceSystemFallback: forceSystemFallback
        )
    }

    /// A page raster is the visual safety net. Source paint may be removed only
    /// when every visual line was natively extracted, has a simple sampled
    /// background, and can be faithfully expressed by Office. This fail-closed
    /// rule prevents text holes when OCR, transparency, private-use glyphs, or
    /// unknown fonts are encountered.
    static func canReplaceSourcePaint(
        lines: [PDFTextLine]
    ) -> Bool {
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            line.extractionSource == .native
                && line.sourceMaskIsSafe
                && line.textColor.alpha >= 0.999
                && !line.runs.isEmpty
                && line.runs.allSatisfy {
                    $0.isOfficeCompatible && $0.textColor.alpha >= 0.999
                }
                && hasPlausibleWidth(for: line)
        }
    }

    /// Calculates a non-destructive Office layout rectangle.  PDFKit reports
    /// ink bounds, whereas Office lays text out using logical advances and
    /// includes side bearings.  Reusing the ink bounds as a Word/PPTX shape
    /// can therefore clip a legitimate final character even when extraction
    /// itself was correct.  The source bounds remain untouched for raster
    /// masking; this larger rectangle is used only by target writers.
    static func officeLayoutBounds(
        for lines: [PDFTextLine],
        sourceBounds: CGRect,
        alignment: PDFTextAlignment,
        cropBox: CGRect
    ) -> CGRect {
        guard !lines.isEmpty,
              !sourceBounds.isNull,
              sourceBounds.width > 0,
              sourceBounds.height > 0
        else {
            return sourceBounds
        }

        let largestFontSize = lines.flatMap(\.runs)
            .map(\.fontSize)
            .max() ?? 5
        // Side bearings differ between Core Text and Office's layout engines.
        // The proportional budget is deliberately small; it is not a visual
        // mask and cannot alter the source paint beneath the text box.
        let sideBearingPadding = max(1, largestFontSize * 0.16)
        let requiredRightEdge = lines.reduce(sourceBounds.maxX) { edge, line in
            let measured = typographicWidth(for: line.runs)
            let requiredWidth = max(line.bounds.width, measured)
                + sideBearingPadding
            return max(edge, line.bounds.minX + requiredWidth)
        }

        let naturalMinX = sourceBounds.minX - sideBearingPadding
        let naturalMaxX = max(
            sourceBounds.maxX + sideBearingPadding,
            requiredRightEdge
        )
        let requiredWidth = naturalMaxX - naturalMinX
        var result: CGRect
        switch alignment {
        case .left:
            result = CGRect(
                x: naturalMinX,
                y: sourceBounds.minY,
                width: requiredWidth,
                height: sourceBounds.height
            )
        case .center:
            result = CGRect(
                x: sourceBounds.midX - requiredWidth / 2,
                y: sourceBounds.minY,
                width: requiredWidth,
                height: sourceBounds.height
            )
        case .right:
            result = CGRect(
                x: sourceBounds.maxX + sideBearingPadding - requiredWidth,
                y: sourceBounds.minY,
                width: requiredWidth,
                height: sourceBounds.height
            )
        }

        // Keep the top edge fixed so the first baseline stays anchored.  A
        // bottom-only allowance accommodates Office's descent and paragraph
        // metrics without moving the visible text vertically.
        let descentAllowance = max(1, largestFontSize * 0.18)
        result.origin.y -= descentAllowance
        result.size.height += descentAllowance

        let clipped = result.intersection(cropBox)
        return clipped.isNull || clipped.width <= 0 || clipped.height <= 0
            ? sourceBounds
            : clipped
    }

    /// PDF text extraction frequently turns a real list tab into a normal
    /// space. Recreate that geometry as an Office tab stop. A continuation
    /// line gives an exact source-derived hanging indent; a 0.25-inch default
    /// is used only when the item has no continuation to measure.
    static func listTabStop(
        for line: PDFTextLine,
        continuations: [PDFTextLine]
    ) -> CGFloat? {
        guard listMarkerLength(in: line.runs) != nil else { return nil }

        let minimumGap = max(6, line.fontSize * 0.8)
        let measuredGaps = continuations.compactMap { continuation -> CGFloat? in
            guard listMarkerLength(in: continuation.runs) == nil else {
                return nil
            }
            let gap = continuation.bounds.minX - line.bounds.minX
            guard gap >= minimumGap, gap <= 72 else { return nil }
            return gap
        }
        if !measuredGaps.isEmpty {
            return measuredGaps.sorted()[measuredGaps.count / 2]
        }

        // Word's standard bullet/tab layout is 0.25 inch. Larger display
        // lists receive a proportional allowance, bounded to one half-inch.
        return min(36, max(18, line.fontSize * 1.5))
    }

    /// Replaces only the whitespace immediately after a recognized list
    /// marker with a tab. All remaining text and formatting runs remain in
    /// their original order, so ordinary intra-line whitespace is untouched.
    static func runsReplacingListWhitespace(
        _ runs: [PDFTextRun]
    ) -> [PDFTextRun] {
        guard let markerLength = listMarkerLength(in: runs) else { return runs }

        var markerCharactersRemaining = markerLength
        var insertedTab = false
        var result: [PDFTextRun] = []

        for run in runs {
            let characters = Array(run.text)
            var index = 0

            if markerCharactersRemaining > 0 {
                let markerCount = min(markerCharactersRemaining, characters.count)
                appendRun(
                    copy(run, text: String(characters.prefix(markerCount))),
                    to: &result
                )
                markerCharactersRemaining -= markerCount
                index = markerCount
            }

            if markerCharactersRemaining == 0 && !insertedTab {
                let whitespaceStart = index
                while index < characters.count, characters[index].isWhitespace {
                    index += 1
                }
                if index > whitespaceStart {
                    appendRun(copy(run, text: "\t"), to: &result)
                    insertedTab = true
                }
            }

            if index < characters.count {
                appendRun(
                    copy(run, text: String(characters[index...])),
                    to: &result
                )
            }
        }

        return insertedTab ? result : runs
    }
}

private extension PDFOfficeTextAppearance {
    static func listMarkerLength(in runs: [PDFTextRun]) -> Int? {
        let text = runs.map(\.text).joined()
        let characters = Array(text)
        guard !characters.isEmpty else { return nil }

        var markerEnd = 0
        while markerEnd < characters.count, !characters[markerEnd].isWhitespace {
            markerEnd += 1
        }
        guard markerEnd > 0,
              markerEnd < characters.count,
              characters[markerEnd].isWhitespace
        else {
            return nil
        }

        let marker = String(characters[..<markerEnd])
        let directMarkers: Set<String> = [
            "•", "◦", "○", "●", "▪", "▫", "‣", "⁃",
            "-", "–", "—", "*", "o", "O", "0"
        ]
        if directMarkers.contains(marker) {
            return markerEnd
        }
        let suffix = marker.drop(while: { $0.isNumber })
        guard !suffix.isEmpty,
              suffix.allSatisfy({ $0 == "." || $0 == ")" }),
              marker.dropLast(suffix.count).allSatisfy(\.isNumber)
        else {
            return nil
        }
        return markerEnd
    }

    static func copy(_ run: PDFTextRun, text: String) -> PDFTextRun {
        PDFTextRun(
            text: text,
            fontName: run.fontName,
            fontSize: run.fontSize,
            textColor: run.textColor,
            isBold: run.isBold,
            isItalic: run.isItalic,
            isOfficeCompatible: run.isOfficeCompatible
        )
    }

    static func appendRun(_ run: PDFTextRun, to runs: inout [PDFTextRun]) {
        guard !run.text.isEmpty else { return }
        guard run.text != "\t",
              let last = runs.last,
              last.text != "\t",
              last.fontName == run.fontName,
              abs(last.fontSize - run.fontSize) < 0.01,
              last.textColor == run.textColor,
              last.isBold == run.isBold,
              last.isItalic == run.isItalic,
              last.isOfficeCompatible == run.isOfficeCompatible
        else {
            runs.append(run)
            return
        }
        runs[runs.count - 1] = copy(last, text: last.text + run.text)
    }

    static func makeRun(
        text: String,
        font: NSFont?,
        fallbackFontName: String,
        fallbackFontSize: CGFloat,
        fallbackColor: PDFTextColor,
        forceSystemFallback: Bool
    ) -> PDFTextRun {
        let rawName: String
        if forceSystemFallback {
            rawName = NSFont.systemFont(ofSize: max(5, fallbackFontSize)).fontName
        } else {
            rawName = font?.fontName ?? fallbackFontName
        }
        let size = max(5, font?.pointSize ?? fallbackFontSize)
        let resolution = resolveFont(
            rawName: rawName,
            pointSize: size,
            fallbackFont: forceSystemFallback ? NSFont.systemFont(ofSize: size) : font
        )
        let normalized = normalizeLegacySymbolText(text)
        return PDFTextRun(
            text: normalized.text,
            fontName: resolution.familyName,
            fontSize: size,
            textColor: fallbackColor,
            isBold: resolution.isBold,
            isItalic: resolution.isItalic,
            isOfficeCompatible: resolution.isPortable && !normalized.hasUnsupportedPrivateUse
        )
    }

    static func append(_ run: PDFTextRun, to runs: inout [PDFTextRun]) {
        guard !run.text.isEmpty else { return }
        if let last = runs.last,
           last.fontName == run.fontName,
           abs(last.fontSize - run.fontSize) < 0.01,
           last.textColor == run.textColor,
           last.isBold == run.isBold,
           last.isItalic == run.isItalic,
           last.isOfficeCompatible == run.isOfficeCompatible {
            runs[runs.count - 1] = PDFTextRun(
                text: last.text + run.text,
                fontName: last.fontName,
                fontSize: last.fontSize,
                textColor: last.textColor,
                isBold: last.isBold,
                isItalic: last.isItalic,
                isOfficeCompatible: last.isOfficeCompatible
            )
        } else {
            runs.append(run)
        }
    }

    private static func resolveFont(
        rawName: String,
        pointSize: CGFloat,
        fallbackFont: NSFont?
    ) -> FontResolution {
        let normalizedRaw = normalizedFontToken(rawName)
        let requestedTraits = traits(for: fallbackFont, rawName: rawName)
        for candidate in fontCandidates(for: rawName) {
            let ctFont = CTFontCreateWithName(candidate as CFString, pointSize, nil)
            let family = CTFontCopyFamilyName(ctFont) as String
            let postScriptName = CTFontCopyPostScriptName(ctFont) as String
            guard fontAppearsToMatch(
                requestedToken: normalizedRaw,
                candidate: candidate,
                family: family,
                postScriptName: postScriptName
            ) else {
                continue
            }
            let symbolicTraits = CTFontGetSymbolicTraits(ctFont)
            return FontResolution(
                familyName: family,
                isBold: requestedTraits.bold
                    || symbolicTraits.contains(.traitBold),
                isItalic: requestedTraits.italic
                    || symbolicTraits.contains(.traitItalic),
                isPortable: isOfficeTypeface(family)
            )
        }

        let fallback = fallbackFont ?? NSFont.systemFont(ofSize: pointSize)
        return FontResolution(
            familyName: fallback.familyName ?? "Helvetica",
            isBold: requestedTraits.bold,
            isItalic: requestedTraits.italic,
            isPortable: false
        )
    }

    static func fontCandidates(for rawName: String) -> [String] {
        let withoutSubset = rawName.replacingOccurrences(
            of: "^[A-Z]{6}\\+",
            with: "",
            options: .regularExpression
        )
        let compact = normalizedFontToken(withoutSubset)
        var candidates = [withoutSubset]
        let familyAliases: [(tokens: [String], family: String)] = [
            (["arial"], "Arial"),
            (["helvetica"], "Helvetica"),
            (["couriernew", "courier"], "Courier New"),
            (["timesnewroman", "timesroman", "times"], "Times New Roman"),
            (["calibri"], "Calibri"),
            (["cambria"], "Cambria"),
            (["aptos"], "Aptos"),
            (["notosans"], "Noto Sans"),
            (["notoserif"], "Noto Serif")
        ]
        for alias in familyAliases where alias.tokens.contains(where: compact.contains) {
            candidates.append(alias.family)
        }
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func fontAppearsToMatch(
        requestedToken: String,
        candidate: String,
        family: String,
        postScriptName: String
    ) -> Bool {
        let candidateToken = normalizedFontToken(candidate)
        let familyToken = normalizedFontToken(family)
        let postScriptToken = normalizedFontToken(postScriptName)
        return requestedToken.contains(familyToken)
            || familyToken.contains(requestedToken)
            || requestedToken.contains(postScriptToken)
            || postScriptToken.contains(requestedToken)
            || candidateToken == familyToken
    }

    static func traits(
        for font: NSFont?,
        rawName: String
    ) -> (bold: Bool, italic: Bool) {
        let symbolic = font?.fontDescriptor.symbolicTraits ?? []
        let token = normalizedFontToken(rawName)
        return (
            symbolic.contains(.bold)
                || ["bold", "black", "semibold", "demi"].contains(where: token.contains),
            symbolic.contains(.italic)
                || ["italic", "oblique"].contains(where: token.contains)
        )
    }

    static func normalizedFontToken(_ value: String) -> String {
        value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0).lowercased() }
            .joined()
    }

    static func isOfficeTypeface(_ family: String) -> Bool {
        let token = normalizedFontToken(family)
        return !token.isEmpty
            && !token.contains("lastresort")
            && !token.contains("systemui")
    }

    static func isWhitespace(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    /// Microsoft Word's legacy Symbol bullet is commonly surfaced from PDFs as
    /// U+F0B7. OOXML consumers do not consistently preserve that private-use
    /// glyph, so emit its standard Unicode semantic instead. Unknown private
    /// use glyphs are intentionally left untouched and make replacement
    /// ineligible; the original raster remains visible in that case.
    static func normalizeLegacySymbolText(_ value: String) -> (
        text: String,
        hasUnsupportedPrivateUse: Bool
    ) {
        var output = String.UnicodeScalarView()
        var unsupported = false
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0xF0B7:
                output.append("•")
            case 0xE000...0xF8FF:
                unsupported = true
                output.append(scalar)
            default:
                output.append(scalar)
            }
        }
        return (String(output), unsupported)
    }

    static func hasPlausibleWidth(for line: PDFTextLine) -> Bool {
        guard line.bounds.width > 0.5 else { return false }
        let measured = typographicWidth(for: line.runs)
        guard measured.isFinite, measured > 0 else { return false }
        let ratio = measured / line.bounds.width
        // PDF glyph bounds omit side bearings and can include intentional word
        // spacing. This deliberately broad gate catches clearly unrelated
        // fallbacks while avoiding false negatives on justified PDF text.
        return ratio >= 0.45 && ratio <= 1.8
    }

    static func typographicWidth(for runs: [PDFTextRun]) -> CGFloat {
        let attributed = NSMutableAttributedString()
        for run in runs {
            let font = NSFont(name: run.fontName, size: max(5, run.fontSize))
                ?? NSFont.systemFont(ofSize: max(5, run.fontSize))
            attributed.append(
                NSAttributedString(
                    string: run.text,
                    attributes: [.font: font]
                )
            )
        }
        guard attributed.length > 0 else { return 0 }
        return CGFloat(CTLineGetTypographicBounds(
            CTLineCreateWithAttributedString(attributed),
            nil,
            nil,
            nil
        ))
    }
}

private extension PDFTextColor {
    init(_ color: NSColor) {
        self.init(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent
        )
    }
}
