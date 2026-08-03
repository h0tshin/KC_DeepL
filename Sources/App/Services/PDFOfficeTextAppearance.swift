import AppKit
import CoreText
import Foundation

/// Converts PDFKit's local font information into names and traits that Office
/// applications can use consistently. PDF font resource names are often
/// PostScript names or subset names and are not valid OOXML typeface values.
enum PDFOfficeTextAppearance {
    private struct FontResolution {
        let familyName: String
        let sourceFontName: String?
        let isBold: Bool
        let isItalic: Bool
        let isPortable: Bool
    }

    private static let portableOfficeTypefaceTokens: Set<String> = [
        "aptos", "aptosdisplay", "aptosmono",
        "arial", "arialblack", "arialnarrow",
        "calibri", "cambria", "cambriamath", "candara", "consolas",
        "constantia", "corbel", "couriernew",
        "georgia", "helvetica", "helveticaneue",
        "menlo", "monaco",
        "notosans", "notoserif",
        "tahoma", "times", "timesnewroman", "trebuchetms", "verdana"
    ]

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

    /// Decides how an extracted text block is rebuilt in Office. The prior
    /// implementation treated a non-uniform template background as grounds to
    /// discard the entire editable block. That made a normal presentation look
    /// correct only because every page became one screenshot. Instead, native
    /// text with a subtle/structured backdrop uses a glyph-aware local repair
    /// in the page template, then becomes a real Office text box.
    static func visualPolicy(
        for lines: [PDFTextLine]
    ) -> PDFSceneTextVisualPolicy {
        guard !lines.isEmpty else { return .preserveSourcePaint }
        let canCreateEditableText = lines.allSatisfy { line in
            line.extractionSource == .native
                // Standalone bullets and ornaments are legitimate text
                // objects. The template repair path erases only pixels that
                // match the known glyph colour, rather than filling their
                // often-wide PDF selection rectangle, so they can remain
                // editable without exposing a rectangular patch.
                && line.textColor.alpha >= 0.999
                && !line.runs.isEmpty
                && line.runs.allSatisfy {
                    $0.isOfficeCompatible && $0.textColor.alpha >= 0.999
                }
                && hasPlausibleWidth(for: line)
        }
        guard canCreateEditableText else { return .preserveSourcePaint }
        return lines.allSatisfy(\.sourceMaskIsSafe)
            ? .replaceSourcePaint
            : .repairSourcePaint
    }

    /// Compatibility shim for callers/tests that need to know whether the
    /// inexpensive solid-mask path is available. Editable text can still be
    /// created through `repairSourcePaint` when this is false.
    static func canReplaceSourcePaint(
        lines: [PDFTextLine]
    ) -> Bool {
        visualPolicy(for: lines) == .replaceSourcePaint
    }

    /// Resolves one paragraph alignment from the *set* of visual PDF lines.
    ///
    /// A positioned PDF has no semantic paragraph alignment to trust.  The
    /// reliable evidence is repeated geometry: left-aligned lines share a
    /// leading edge, centred lines share a midpoint, and right-aligned lines
    /// share a trailing edge.  Evaluating a single line against an inferred
    /// column is unstable for speech bubbles and narrow diagrams because the
    /// column can collapse to the line's ink width.  Use robust edge
    /// dispersion across the whole block instead, while retaining the
    /// source-side fallback for a genuinely ambiguous one-line block.
    static func paragraphAlignment(
        for lines: [PDFTextLine],
        fallback: PDFTextAlignment
    ) -> PDFTextAlignment {
        guard lines.count >= 2,
              !lines.contains(where: { beginsWithListMarker($0.text) })
        else {
            return fallback
        }

        let widths = lines.map(\.bounds.width)
        guard let narrowest = widths.min(),
              let widest = widths.max()
        else {
            return fallback
        }
        let largestFontSize = lines.map(\.fontSize).max() ?? 10
        // If every source line has almost the same width, its leading,
        // midpoint, and trailing edges all convey the same geometry. Keep the
        // already-resolved single-line result instead of inventing a style.
        guard widest - narrowest >= max(4, largestFontSize * 0.7) else {
            return fallback
        }

        let candidates: [(PDFTextAlignment, [CGFloat])] = [
            (.left, lines.map { $0.bounds.minX }),
            (.center, lines.map { $0.bounds.midX }),
            (.right, lines.map { $0.bounds.maxX })
        ]
        let scored = candidates.map { alignment, edges in
            (alignment, robustEdgeDispersion(edges))
        }.sorted { lhs, rhs in
            lhs.1 < rhs.1
        }
        guard let winner = scored.first,
              let runnerUp = scored.dropFirst().first
        else {
            return fallback
        }

        // PDFKit character rectangles can vary fractionally from line to
        // line.  Require both a tightly shared anchor and a meaningful lead
        // over the next best anchor before overriding the fallback.
        let anchorTolerance = max(1.25, largestFontSize * 0.11)
        let confidenceGap = max(1.5, largestFontSize * 0.22)
        guard winner.1 <= anchorTolerance,
              runnerUp.1 - winner.1 >= confidenceGap
        else {
            return fallback
        }
        return winner.0
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
        cropBox: CGRect,
        layoutTarget: PDFOfficeLayoutTarget = .presentation
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

        // Reserve room for Office's descenders without moving the source
        // paint/mask reference rectangle itself.
        let descentAllowance = max(1, largestFontSize * 0.18)
        result.origin.y -= descentAllowance
        result.size.height += descentAllowance

        // A PDF selection's top edge is a hit-test rectangle, not a text
        // frame baseline. In mixed-font list items it is often determined by
        // the marker font, while the visible body starts noticeably lower.
        // DrawingML, in contrast, positions a logical Office line cell inside
        // the text frame. Calibrate the *PowerPoint frame* top from the source
        // ink top and the resolved Office run metrics so all paragraphs in one
        // box move together without disturbing their measured line advances.
        // Word floating text boxes follow the source selection geometry more
        // closely, so they deliberately keep the uncalibrated source top;
        // applying the DrawingML correction there moves Word body text upward.
        //
        // Changing only `size.height` moves `maxY` in PDF coordinates; the
        // writers map that edge to the target text-frame top coordinate. The
        // bottom/descent allowance remains intact, so no editable glyph is
        // clipped by the correction.
        if layoutTarget == .presentation {
            let topAnchorAdjustment = officeTopAnchorAdjustment(
                for: lines,
                sourceBounds: sourceBounds,
                fallbackFontSize: largestFontSize
            )
            if abs(topAnchorAdjustment) > 0.01,
               result.height + topAnchorAdjustment > 1 {
                result.size.height += topAnchorAdjustment
            }
        }

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
    /// marker with a measured, editable typographic spacer. A literal Drawing
    /// ML tab is not stable inside a multi-paragraph text box across Office
    /// renderers: some renderers collapse it after a paragraph margin is
    /// applied. The spacer is chosen from standard Unicode space glyphs in
    /// the source run's resolved Office font, so the following text still
    /// lands at the source-derived list anchor without adding another text
    /// shape.
    static func runsReplacingListWhitespace(
        _ runs: [PDFTextRun],
        targetTextOffset: CGFloat
    ) -> [PDFTextRun] {
        guard let markerLength = listMarkerLength(in: runs) else { return runs }

        var markerCharactersRemaining = markerLength
        var insertedSpacer = false
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

            if markerCharactersRemaining == 0 && !insertedSpacer {
                let whitespaceStart = index
                while index < characters.count, characters[index].isWhitespace {
                    index += 1
                }
                if index > whitespaceStart {
                    let markerWidth = typographicWidth(for: result)
                    let spacerWidth = max(0.5, targetTextOffset - markerWidth)
                    appendRun(
                        copy(
                            run,
                            text: editableWhitespaceSpacer(
                                width: spacerWidth,
                                matching: run
                            )
                        ),
                        to: &result
                    )
                    insertedSpacer = true
                }
            }

            if index < characters.count {
                appendRun(
                    copy(run, text: String(characters[index...])),
                    to: &result
                )
            }
        }

        return insertedSpacer ? result : runs
    }

    /// Fits Office text to the source visual advance. PDF stores line-level
    /// glyph geometry (including producer-specific tracking), while Office
    /// stores a family, size and optional character spacing. A substituted
    /// typeface first receives a bounded size correction; every safe Office
    /// line then receives a small source-derived tracking correction so the
    /// result keeps its original right edge without scaling glyph outlines.
    static func calibratedRuns(
        _ runs: [PDFTextRun],
        sourceWidth: CGFloat
    ) -> [PDFTextRun] {
        guard sourceWidth.isFinite,
              sourceWidth > 0.5,
              runs.isEmpty == false,
              runs.allSatisfy(\.isOfficeCompatible)
        else {
            return runs
        }

        let officeWidth = typographicWidth(for: runs)
        guard officeWidth.isFinite, officeWidth > 0.5 else { return runs }

        var fittedRuns = runs
        if runs.contains(where: { $0.sourceFontName != nil }) {
            // PDF selection bounds omit some side bearings. Bound a font-size
            // correction so malformed source bounds cannot cause a destructive
            // scale change after an actual typeface substitution.
            let scale = min(1.2, max(0.72, sourceWidth / officeWidth))
            if abs(scale - 1) > 0.01 {
                fittedRuns = runs.map { run in
                    PDFTextRun(
                        text: run.text,
                        fontName: run.fontName,
                        sourceFontName: run.sourceFontName,
                        fontSize: max(5, min(144, run.fontSize * scale)),
                        characterSpacing: run.characterSpacing,
                        textColor: run.textColor,
                        isBold: run.isBold,
                        isItalic: run.isItalic,
                        isOfficeCompatible: run.isOfficeCompatible
                    )
                }
            }
        }

        let fittedWidth = typographicWidth(for: fittedRuns)
        guard fittedWidth.isFinite, fittedWidth > 0.5 else {
            return fittedRuns
        }
        // List items are rebuilt later with an explicit source-derived marker
        // spacer. Applying a per-character correction before that whitespace
        // expands would count the newly inserted Unicode spaces as real PDF
        // character gaps and move the list body too far right.
        guard listMarkerLength(in: fittedRuns) == nil else {
            return fittedRuns
        }
        let widthRatio = sourceWidth / fittedWidth
        guard widthRatio >= 0.92, widthRatio <= 1.08 else {
            return fittedRuns
        }

        let gapCount = fittedRuns.reduce(0) { count, run in
            count + max(0, run.text.count - 1)
        }
        guard gapCount > 0 else { return fittedRuns }
        let correction = (sourceWidth - fittedWidth) / CGFloat(gapCount)
        // PDF selection bounds include a small amount of side-bearing space,
        // so apply a conservative fraction of the raw difference. Tracking
        // above 0.18pt per gap is almost certainly a broken selection width
        // rather than a font-metric difference.
        let boundedCorrection = min(0.18, max(-0.18, correction * 0.35))
        guard abs(boundedCorrection) >= 0.005 else { return fittedRuns }

        return fittedRuns.map { run in
            PDFTextRun(
                text: run.text,
                fontName: run.fontName,
                sourceFontName: run.sourceFontName,
                fontSize: run.fontSize,
                characterSpacing: boundedCorrection,
                textColor: run.textColor,
                isBold: run.isBold,
                isItalic: run.isItalic,
                isOfficeCompatible: run.isOfficeCompatible
            )
        }
    }
}

private extension PDFOfficeTextAppearance {
    /// The logical DrawingML line cell has a small top reserve beyond the
    /// actual Core Text ink bound. It scales with the font em square rather
    /// than with a particular document's geometry. Keeping the value here
    /// lets the source-side ink measurement and the target-side metrics remain
    /// explicit, testable parts of one anchor model instead of applying a
    /// document-specific y-offset in either writer.
    static let officeTextFrameTopReserveRatio: CGFloat = 0.20
    static let officeTextFrameTopReserveMaximum: CGFloat = 4

    /// Median absolute deviation keeps a single short wrapped line from
    /// changing a paragraph's inferred anchor. PDF coordinates are in
    /// points, so this is directly comparable with font-size based
    /// tolerances in paragraphAlignment.
    static func robustEdgeDispersion(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return .greatestFiniteMagnitude }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let deviations = values.map { abs($0 - median) }.sorted()
        return deviations[deviations.count / 2]
    }

    static func beginsWithListMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstToken = trimmed.split(whereSeparator: \.isWhitespace).first
        else {
            return false
        }
        let token = String(firstToken)
        if [
            "•", "◦", "○", "●", "▪", "▫", "‣", "⁃",
            "-", "–", "—", "*", "o", "O", "0", ""
        ].contains(token) {
            return true
        }
        let suffix = token.drop(while: { $0.isNumber })
        return !suffix.isEmpty
            && suffix.allSatisfy { $0 == "." || $0 == ")" }
            && token.dropLast(suffix.count).allSatisfy(\.isNumber)
    }

    static func officeTopAnchorAdjustment(
        for lines: [PDFTextLine],
        sourceBounds: CGRect,
        fallbackFontSize: CGFloat
    ) -> CGFloat {
        guard let firstLine = lines.first,
              firstLine.extractionSource == .native,
              let sourceInkTopY = firstLine.inkTopY,
              firstLine.runs.isEmpty == false,
              firstLine.runs.allSatisfy(\.isOfficeCompatible)
        else {
            return 0
        }

        let sourceInkInset = max(0, sourceBounds.maxY - sourceInkTopY)
        guard sourceInkInset.isFinite,
              let targetInkInset = officeVisibleTopInset(
                for: firstLine.runs,
                fallbackFontSize: fallbackFontSize
              )
        else {
            return 0
        }

        // The source selection box can contain a malformed or invisible
        // glyph. Cap the correction to a fraction of the line cell so such a
        // case cannot pull a whole paragraph across neighbouring content.
        let limit = max(1, fallbackFontSize * 0.45)
        return max(
            -limit,
            min(limit, targetInkInset - sourceInkInset)
        )
    }

    static func officeVisibleTopInset(
        for runs: [PDFTextRun],
        fallbackFontSize: CGFloat
    ) -> CGFloat? {
        let attributed = NSMutableAttributedString()
        for run in runs where !run.text.isEmpty {
            attributed.append(
                NSAttributedString(
                    string: run.text,
                    attributes: [.font: officeLayoutFont(for: run)]
                )
            )
        }
        guard attributed.length > 0 else { return nil }

        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let inkBounds = CTLineGetImageBounds(line, nil)
        guard ascent.isFinite,
              ascent > 0,
              !inkBounds.isNull,
              !inkBounds.isInfinite,
              inkBounds.maxY.isFinite
        else {
            return nil
        }

        let largestRunSize = runs.map(\.fontSize).max() ?? fallbackFontSize
        let topBearing = max(0, ascent - inkBounds.maxY)
        let officeFrameReserve = max(
            0.35,
            min(
                officeTextFrameTopReserveMaximum,
                largestRunSize * officeTextFrameTopReserveRatio
            )
        )
        return topBearing + officeFrameReserve
    }

    static func officeLayoutFont(for run: PDFTextRun) -> NSFont {
        let size = max(5, run.fontSize)
        let base = NSFont(name: run.fontName, size: size)
            ?? NSFont.systemFont(ofSize: size)
        var traits: NSFontTraitMask = []
        if run.isBold { traits.insert(.boldFontMask) }
        if run.isItalic { traits.insert(.italicFontMask) }
        guard !traits.isEmpty else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: traits)
    }

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
            sourceFontName: run.sourceFontName,
            fontSize: run.fontSize,
            characterSpacing: run.characterSpacing,
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
              last.sourceFontName == run.sourceFontName,
              abs(last.fontSize - run.fontSize) < 0.01,
              abs(last.characterSpacing - run.characterSpacing) < 0.0001,
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
            sourceFontName: resolution.sourceFontName,
            fontSize: size,
            characterSpacing: 0,
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
           last.sourceFontName == run.sourceFontName,
           abs(last.fontSize - run.fontSize) < 0.01,
           abs(last.characterSpacing - run.characterSpacing) < 0.0001,
           last.textColor == run.textColor,
           last.isBold == run.isBold,
           last.isItalic == run.isItalic,
           last.isOfficeCompatible == run.isOfficeCompatible {
            runs[runs.count - 1] = PDFTextRun(
                text: last.text + run.text,
                fontName: last.fontName,
                sourceFontName: last.sourceFontName,
                fontSize: last.fontSize,
                characterSpacing: last.characterSpacing,
                textColor: last.textColor,
                isBold: last.isBold,
                isItalic: last.isItalic,
                isOfficeCompatible: last.isOfficeCompatible
            )
        } else {
            runs.append(run)
        }
    }

    /// Returns a short sequence of standard Unicode whitespace characters
    /// whose measured width most closely matches the requested source gap.
    /// Keeping the spacer in the same run font avoids a hidden fallback font
    /// changing the list body's horizontal anchor.
    static func editableWhitespaceSpacer(
        width targetWidth: CGFloat,
        matching run: PDFTextRun
    ) -> String {
        let candidates = [
            "\u{200A}", // hair space
            "\u{2006}", // six-per-em space
            "\u{2009}", // thin space
            " ",
            "\u{2005}", // four-per-em space
            "\u{2002}", // en space
            "\u{2003}"  // em space
        ].compactMap { character -> (text: String, width: CGFloat)? in
            let measured = typographicWidth(for: [copy(run, text: character)])
            guard measured.isFinite, measured > 0.05 else { return nil }
            return (character, measured)
        }
        guard !candidates.isEmpty else { return " " }

        // Space advances are additive for this character set. Quantise to a
        // tenth of a point for a small deterministic dynamic-programming
        // search; that is finer than the visual precision of a PDF glyph box.
        let step: CGFloat = 0.1
        let largestAdvance = candidates.map(\.width).max() ?? targetWidth
        let limit = max(
            1,
            Int(((targetWidth + largestAdvance) / step).rounded(.up))
        )
        var best: [(text: String, count: Int)?] = Array(
            repeating: nil,
            count: limit + 1
        )
        best[0] = ("", 0)

        for unit in 0...limit {
            guard let current = best[unit] else { continue }
            for candidate in candidates {
                let candidateUnits = max(
                    1,
                    Int((candidate.width / step).rounded())
                )
                let nextUnit = unit + candidateUnits
                guard nextUnit <= limit else { continue }
                let proposed = (
                    text: current.text + candidate.text,
                    count: current.count + 1
                )
                if let existing = best[nextUnit] {
                    if proposed.count < existing.count {
                        best[nextUnit] = proposed
                    }
                } else {
                    best[nextUnit] = proposed
                }
            }
        }

        let targetUnit = Int((targetWidth / step).rounded())
        let winner = best.enumerated().compactMap {
            offset, candidate -> (distance: Int, count: Int, text: String)? in
            guard let candidate else { return nil }
            return (
                distance: abs(offset - targetUnit),
                count: candidate.count,
                text: candidate.text
            )
        }.min {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.count < $1.count
        }
        return winner?.text ?? " "
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
            let officeFamily = officeOutputTypeface(for: family)
            return FontResolution(
                familyName: officeFamily,
                sourceFontName: normalizedFontToken(officeFamily)
                    == normalizedFontToken(family) ? nil : rawName,
                isBold: requestedTraits.bold
                    || symbolicTraits.contains(.traitBold),
                isItalic: requestedTraits.italic
                    || symbolicTraits.contains(.traitItalic),
                isPortable: isOfficeTypeface(officeFamily)
            )
        }

        let fallback = fallbackFont ?? NSFont.systemFont(ofSize: pointSize)
        return FontResolution(
            familyName: fallback.familyName ?? "Helvetica",
            sourceFontName: nil,
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
            (["barlow"], "Barlow"),
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

    /// A process-scoped app font is visible to PDFKit while KC DeepL is
    /// running, but it is not automatically installed for PowerPoint, Word,
    /// or LibreOffice. Barlow is a bundled OFL family, so its four real faces
    /// are emitted into the PPTX as PresentationML font parts. Keep the
    /// original typeface name when that package path is available; otherwise
    /// fall back to a broad Office sans-serif instead of allowing a serif
    /// substitution to change the source layout.
    static func officeOutputTypeface(for family: String) -> String {
        switch normalizedFontToken(family) {
        case "barlow":
            OfficeEmbeddedFontCatalog.canEmbedPresentationTypeface(family)
                ? "Barlow"
                : "Arial"
        default:
            family
        }
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

    /// "Office compatible" means the emitted typeface is expected to resolve
    /// in an Office editor outside KC DeepL's process. Unknown subsetted/brand
    /// fonts remain in the template rather than being silently substituted.
    static func isOfficeTypeface(_ family: String) -> Bool {
        let token = normalizedFontToken(family)
        if token == "barlow" {
            return OfficeEmbeddedFontCatalog.canEmbedPresentationTypeface(family)
        }
        return portableOfficeTypefaceTokens.contains(token)
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
            attributed.append(
                NSAttributedString(
                    string: run.text,
                    attributes: [.font: officeLayoutFont(for: run)]
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
