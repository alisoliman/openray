import AppKit

/// Paste Formatted Response (⌥↵, work item 5): a response's Markdown as rich text, so apps that
/// take formatting get bold, italics, code, headings and lists instead of their markers.
enum AIFormattedText {
    /// RTF and HTML for `markdown`, or nil when it has no formatting to keep, so a plain paste
    /// is the same.
    @MainActor static func richText(fromMarkdown markdown: String) -> ClipboardRichText? {
        guard let attributed = attributedString(fromMarkdown: markdown) else { return nil }
        let range = NSRange(location: 0, length: attributed.length)
        let rtf = try? attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let html = try? attributed.data(
            from: range,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue,
            ])
        return ClipboardRichText.capture(rtf: rtf, html: html)
    }

    /// The Markdown with its markers turned into attributes, line by line as the AI view renders
    /// it, or nil when nothing in it is formatted.
    static func attributedString(fromMarkdown markdown: String) -> NSAttributedString? {
        let body = NSFont.systemFont(ofSize: 13)
        let result = NSMutableAttributedString()
        var formatted = false
        var fence: String?
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: [.font: body])) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let run = trimmed.prefix(while: { $0 == marker })
                if run.count >= 3, fence == nil || trimmed.allSatisfy({ $0 == marker }) {
                    fence = fence == nil ? String(run) : nil
                    formatted = true
                    continue
                }
            }
            if fence != nil {
                result.append(
                    NSAttributedString(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
                continue
            }
            let depth = trimmed.prefix(while: { $0 == "#" }).count
            var content = line
            var font = body
            if (1...6).contains(depth), trimmed.dropFirst(depth).first == " " {
                content = String(trimmed.dropFirst(depth + 1))
                font = NSFont.systemFont(ofSize: depth == 1 ? 18 : depth == 2 ? 16 : 14, weight: .semibold)
                formatted = true
            } else if ["- ", "* ", "+ "].contains(where: trimmed.hasPrefix) {
                let indentation = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                content = indentation + "• " + trimmed.dropFirst(2)
                formatted = true
            }
            let (inline, hasInline) = inlineRuns(content, font: font)
            formatted = formatted || hasInline
            result.append(inline)
        }
        return formatted ? result : nil
    }

    /// Bold, italics, code and strikethrough within one line.
    private static func inlineRuns(_ line: String, font: NSFont) -> (NSAttributedString, Bool) {
        guard
            let parsed = try? AttributedString(
                markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return (NSAttributedString(string: line, attributes: [.font: font]), false) }
        let result = NSMutableAttributedString()
        var formatted = false
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if let intent = run.inlinePresentationIntent {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if intent.contains(.code) {
                    attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                } else if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    attributes[.font] = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                formatted = formatted || !intent.isEmpty
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return (result, formatted)
    }
}
