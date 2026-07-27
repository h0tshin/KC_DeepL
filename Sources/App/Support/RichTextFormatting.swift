import AppKit

enum RichTextFormatting {
    static func plainAttributedString(_ text: String, fontSize: CGFloat = 26) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    static func attributedString(from pasteboard: NSPasteboard, fontSize: CGFloat = 26) -> NSAttributedString? {
        if let attributed = pasteboard.readObjects(forClasses: [NSAttributedString.self])?.first as? NSAttributedString {
            return normalize(attributed, fontSize: fontSize)
        }

        if let rtfdData = pasteboard.data(forType: .rtfd),
           let attributed = NSAttributedString(rtfd: rtfdData, documentAttributes: nil) {
            return normalize(attributed, fontSize: fontSize)
        }

        if let rtfData = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            return normalize(attributed, fontSize: fontSize)
        }

        if let htmlData = pasteboard.data(forType: .html),
           let attributed = NSAttributedString(
            html: htmlData,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
           ) {
            return normalize(attributed, fontSize: fontSize)
        }

        if let text = pasteboard.string(forType: .string) {
            return plainAttributedString(text, fontSize: fontSize)
        }

        return nil
    }

    static func normalize(_ attributed: NSAttributedString, fontSize: CGFloat = 26) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)

        mutable.enumerateAttributes(in: fullRange) { attributes, range, _ in
            var updated = attributes
            if updated[.font] == nil {
                updated[.font] = NSFont.systemFont(ofSize: fontSize)
            }

            // Preserve semantic and typographic formatting while discarding
            // source-specific colors that may be unreadable in the app theme.
            updated.removeValue(forKey: .backgroundColor)
            updated[.foregroundColor] = NSColor.labelColor
            mutable.setAttributes(updated, range: range)
        }

        return mutable
    }

    static func hasFormatting(_ attributed: NSAttributedString) -> Bool {
        guard attributed.length > 0 else {
            return false
        }

        var hasFormatting = false
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: fullRange) { attributes, _, stop in
            if attributes[.link] != nil || attributes[.underlineStyle] != nil {
                hasFormatting = true
                stop.pointee = true
                return
            }

            if let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle,
               !paragraphStyle.isEqual(NSParagraphStyle.default) {
                hasFormatting = true
                stop.pointee = true
                return
            }

            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) || traits.contains(.italicFontMask) {
                    hasFormatting = true
                    stop.pointee = true
                }
            }
        }

        return hasFormatting
    }

    static func markdown(from attributed: NSAttributedString, fallback: String) -> String {
        guard hasFormatting(attributed), attributed.string == fallback else {
            return fallback
        }

        let nsString = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: attributed.length)
        var output = ""

        nsString.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            output += markdownLine(from: attributed, lineRange: lineRange)
            if NSMaxRange(lineRange) < attributed.length {
                output += "\n"
            }
        }

        return output.isEmpty ? fallback : output
    }

    static func write(_ attributed: NSAttributedString, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(attributed.string, forType: .string)

        let fullRange = NSRange(location: 0, length: attributed.length)
        if let rtfData = try? attributed.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            pasteboard.setData(rtfData, forType: .rtf)
        }

        if let htmlData = try? attributed.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        ) {
            pasteboard.setData(htmlData, forType: .html)
        }
    }

    static func writeMarkdown(_ text: String, to pasteboard: NSPasteboard) {
        let attributed = attributedString(markdown: text)
        write(attributed, to: pasteboard)
    }

    static func attributedString(markdown text: String, fontSize: CGFloat = 25) -> NSAttributedString {
        if let swiftAttributed = try? AttributedString(markdown: text) {
            let attributed = NSMutableAttributedString(swiftAttributed)
            return normalize(attributed, fontSize: fontSize)
        }

        return plainAttributedString(text, fontSize: fontSize)
    }

    private static func markdownLine(from attributed: NSAttributedString, lineRange: NSRange) -> String {
        var line = ""
        attributed.enumerateAttributes(in: lineRange) { attributes, range, _ in
            let text = (attributed.string as NSString).substring(with: range)
            line += markdownRun(text, attributes: attributes)
        }
        return line
    }

    private static func markdownRun(_ text: String, attributes: [NSAttributedString.Key: Any]) -> String {
        guard !text.isEmpty else {
            return text
        }

        var escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")

        if let link = attributes[.link] {
            escaped = "[\(escaped)](\(link))"
        }

        if let font = attributes[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.italicFontMask) {
                escaped = "*\(escaped)*"
            }
            if traits.contains(.boldFontMask) {
                escaped = "**\(escaped)**"
            }
        }

        if attributes[.underlineStyle] != nil {
            escaped = "<u>\(escaped)</u>"
        }

        return escaped
    }
}
