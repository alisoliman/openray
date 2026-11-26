import AppKit
import Foundation
import UniformTypeIdentifiers

/// The formats a note exports to.
enum NoteExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown, html, plainText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .html: "HTML"
        case .plainText: "Plain Text"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .html: "html"
        case .plainText: "txt"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .html: .html
        case .plainText: .plainText
        }
    }
}

/// Turns a note into Markdown, HTML or plain text. Images the note references by asset path
/// are exported as links to the image file on this Mac; the exported file doesn't contain them.
enum NoteExporter {
    static func export(_ note: QuickNote, as format: NoteExportFormat, assets: NoteAssetStore?) -> String {
        let markdown = resolvingAssets(in: note.content, assets: assets)
        switch format {
        case .markdown: return markdown.hasSuffix("\n") ? markdown : markdown + "\n"
        case .html: return html(from: markdown, title: displayTitle(of: note))
        case .plainText:
            let text = plainText(from: markdown)
            return text.hasSuffix("\n") ? text : text + "\n"
        }
    }

    static func displayTitle(of note: QuickNote) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled Note" : title
    }

    /// A file name for the save panel: the title without characters Finder rejects.
    static func suggestedFileName(for note: QuickNote, format: NoteExportFormat) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\\0").union(.newlines).union(.controlCharacters)
        let base = displayTitle(of: note).components(separatedBy: unsafe).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return "\(base.isEmpty ? "Note" : String(base.prefix(80))).\(format.fileExtension)"
    }

    /// Rewrites `![…](NoteAssets/…)` references to file URLs, so exported files still find the images.
    static func resolvingAssets(in markdown: String, assets: NoteAssetStore?) -> String {
        guard let assets else { return markdown }
        let pattern = try! NSRegularExpression(pattern: #"(!\[[^\]\n]*\]\()([^)\s]+)(\))"#)
        let string = markdown as NSString
        var result = ""
        var last = 0
        for match in pattern.matches(in: markdown, range: NSRange(location: 0, length: string.length)) {
            let reference = string.substring(with: match.range(at: 2))
            guard let url = assets.url(for: reference) else { continue }
            result += string.substring(with: NSRange(location: last, length: match.range(at: 2).location - last))
            result += url.absoluteString
            last = NSMaxRange(match.range(at: 2))
        }
        result += string.substring(from: last)
        return result
    }

    // MARK: HTML

    /// A standalone HTML document for the note.
    static func html(from markdown: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        body { font: 15px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; max-width: 680px; margin: 40px auto; padding: 0 20px; color: #1d1d1f; }
        code, pre { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; background: rgba(0,0,0,.05); border-radius: 5px; }
        code { padding: 1px 4px; } pre { padding: 12px; overflow-x: auto; } pre code { background: none; padding: 0; }
        blockquote { margin: 0; padding-left: 14px; border-left: 3px solid #d2d2d7; color: #6e6e73; }
        ul.tasks { list-style: none; padding-left: 4px; } img { max-width: 100%; }
        li.done { color: #6e6e73; text-decoration: line-through; }
        </style>
        </head>
        <body>
        \(htmlBody(from: markdown))
        </body>
        </html>

        """
    }

    /// The note's blocks as HTML elements, one per line.
    static func htmlBody(from markdown: String) -> String {
        var output: [String] = []
        var paragraph: [String] = []
        var list: (tag: String, isTasks: Bool)?
        var code: [String]?
        var quote: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            output.append("<p>" + paragraph.map(inlineHTML).joined(separator: "<br>\n") + "</p>")
            paragraph = []
        }
        func closeList() {
            guard let open = list else { return }
            output.append("</\(open.tag)>")
            list = nil
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            output.append("<blockquote><p>" + quote.map(inlineHTML).joined(separator: "<br>\n") + "</p></blockquote>")
            quote = []
        }
        func flushAll() {
            flushParagraph()
            closeList()
            flushQuote()
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    output.append("<pre><code>" + lines.map(escape).joined(separator: "\n") + "</code></pre>")
                    code = nil
                } else {
                    lines.append(line)
                    code = lines
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                code = []
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if trimmed.range(of: #"^([-*_])([ \t]*\1){2,}$"#, options: .regularExpression) != nil {
                flushAll()
                output.append("<hr>")
                continue
            }
            if let match = captures(#"^(#{1,6})\s+(.*)$"#, in: trimmed) {
                flushAll()
                let level = match[1]?.count ?? 1
                output.append("<h\(level)>\(inlineHTML(match[2] ?? ""))</h\(level)>")
                continue
            }
            if let match = captures(#"^>\s?(.*)$"#, in: trimmed) {
                flushParagraph()
                closeList()
                quote.append(match[1] ?? "")
                continue
            }
            if let match = captures(#"^([-*+]|\d{1,9}[.)])\s+(?:\[( |x|X)\]\s?)?(.*)$"#, in: trimmed) {
                flushParagraph()
                flushQuote()
                let ordered = match[1]?.first?.isNumber == true
                let isTask = match[2] != nil
                let tag = ordered ? "ol" : "ul"
                if list?.tag != tag || list?.isTasks != isTask {
                    closeList()
                    output.append(isTask ? "<\(tag) class=\"tasks\">" : "<\(tag)>")
                    list = (tag, isTask)
                }
                let body = inlineHTML(match[3] ?? "")
                if let box = match[2] {
                    let checked = box != " "
                    output.append(
                        "<li\(checked ? " class=\"done\"" : "")><input type=\"checkbox\" disabled\(checked ? " checked" : "")> \(body)</li>")
                } else {
                    output.append("<li>\(body)</li>")
                }
                continue
            }
            closeList()
            flushQuote()
            paragraph.append(trimmed)
        }
        if let lines = code { output.append("<pre><code>" + lines.map(escape).joined(separator: "\n") + "</code></pre>") }
        flushAll()
        return output.joined(separator: "\n")
    }

    /// Inline Markdown as HTML: code first, so nothing inside it is formatted, then images,
    /// links, bold, italic and strikethrough. Everything else is escaped.
    static func inlineHTML(_ text: String) -> String {
        // Code is set aside behind private-use placeholders, which escaping can't produce, so
        // nothing inside it is formatted.
        var codes: [String] = []
        var working = ""
        let string = text as NSString
        var last = 0
        for match in regex(#"`([^`]+)`"#).matches(in: text, range: NSRange(location: 0, length: string.length)) {
            working += string.substring(with: NSRange(location: last, length: match.range.location - last))
            codes.append("<code>\(escape(string.substring(with: match.range(at: 1))))</code>")
            working += "\u{E000}\(codes.count - 1)\u{E001}"
            last = NSMaxRange(match.range)
        }
        working += string.substring(from: last)
        working = escape(working)
        working = replacing(#"!\[([^\]]*)\]\(([^)\s]+)\)"#, in: working, with: "<img src=\"$2\" alt=\"$1\">")
        working = replacing(#"\[([^\]]+)\]\(([^)\s]+)\)"#, in: working, with: "<a href=\"$2\">$1</a>")
        working = replacing(boldStars, in: working, with: "<strong>$1</strong>")
        working = replacing(boldUnderscores, in: working, with: "<strong>$1</strong>")
        working = replacing(italicStar, in: working, with: "<em>$1</em>")
        working = replacing(italicUnderscore, in: working, with: "<em>$1</em>")
        working = replacing(strike, in: working, with: "<del>$1</del>")
        for (index, code) in codes.enumerated() {
            working = working.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: code)
        }
        return working
    }

    // ICU patterns, which support the lookbehind the emphasis rules need.
    private static let boldStars = #"\*\*(\S(?:.*?\S)?)\*\*"#
    private static let boldUnderscores = #"(?<![\w_])__(\S(?:.*?\S)?)__(?![\w_])"#
    private static let italicStar = #"(?<![*\w])\*(?![*\s])(.+?)(?<![*\s])\*(?!\*)"#
    private static let italicUnderscore = #"(?<![\w_])_(?![_\s])(.+?)(?<![_\s])_(?![\w_])"#
    private static let strike = #"~~(\S(?:.*?\S)?)~~"#

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Constant patterns; a typo fails every export test.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    /// The capture groups of the first match, or nil when it doesn't match. Index 0 is the whole match.
    private static func captures(_ pattern: String, in text: String) -> [String?]? {
        let string = text as NSString
        guard let match = regex(pattern).firstMatch(in: text, range: NSRange(location: 0, length: string.length))
        else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : string.substring(with: range)
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Plain text

    /// The note as a reader would type it in a plain editor: no markup, tasks as ☐ and ☑,
    /// links as “text (url)”, images as “Image: url”.
    static func plainText(from markdown: String) -> String {
        var lines: [String] = []
        var inCode = false
        for rawLine in markdown.components(separatedBy: "\n") {
            var line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCode.toggle()
                continue
            }
            if inCode {
                lines.append(line)
                continue
            }
            if trimmed.range(of: #"^([-*_])([ \t]*\1){2,}$"#, options: .regularExpression) != nil {
                lines.append("————")
                continue
            }
            line = replacing(#"^#{1,6}\s+"#, in: line, with: "")
            line = replacing(#"^(\s*)>\s?"#, in: line, with: "$1")
            line = replacing(#"^(\s*)(?:[-*+]|\d{1,9}[.)])\s+\[ \]\s?"#, in: line, with: "$1☐ ")
            line = replacing(#"^(\s*)(?:[-*+]|\d{1,9}[.)])\s+\[[xX]\]\s?"#, in: line, with: "$1☑ ")
            line = replacing(#"^(\s*)[-*+]\s+"#, in: line, with: "$1• ")
            line = replacing(#"!\[(?:Image)?\]\(([^)\s]+)\)"#, in: line, with: "Image: $1")
            line = replacing(#"!\[([^\]]+)\]\(([^)\s]+)\)"#, in: line, with: "$1: $2")
            line = replacing(#"\[([^\]]+)\]\(([^)\s]+)\)"#, in: line, with: "$1 ($2)")
            line = replacing(#"`([^`]+)`"#, in: line, with: "$1")
            for pattern in [boldStars, boldUnderscores, italicStar, italicUnderscore, strike] {
                line = replacing(pattern, in: line, with: "$1")
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// Images pasted into notes, stored as files in `NoteAssets` next to `library.json`. Notes
/// reference them as `NoteAssets/<name>`, so the library itself stays small.
struct NoteAssetStore: Sendable, Equatable {
    static let folderName = "NoteAssets"
    /// The largest image a note takes, as in Raycast's notes: 20 MiB.
    static let maximumImageBytes = 20 * 1_024 * 1_024
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// Next to the library, or a per-process temporary folder for an in-memory library.
    init(libraryURL: URL?) {
        if let libraryURL {
            directory = libraryURL.deletingLastPathComponent().appending(path: Self.folderName, directoryHint: .isDirectory)
        } else {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "OpenRay-\(ProcessInfo.processInfo.processIdentifier)-\(Self.folderName)", directoryHint: .isDirectory)
        }
    }

    enum AssetError: LocalizedError, Equatable {
        case tooLarge, unsupported
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Images can be up to 20 MB."
            case .unsupported: "OpenRay can't add this kind of image."
            }
        }
    }

    /// Saves image data and returns the reference to put in the note.
    func save(_ data: Data, fileExtension: String) throws -> String {
        let ext = fileExtension.lowercased()
        guard Self.imageExtensions.contains(ext) else { throw AssetError.unsupported }
        guard data.count <= Self.maximumImageBytes else { throw AssetError.tooLarge }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "\(UUID().uuidString).\(ext)"
        let url = directory.appending(path: name)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return "\(Self.folderName)/\(name)"
    }

    /// The file a note's reference points at, only when it's inside the assets folder.
    func url(for reference: String) -> URL? {
        guard let name = Self.fileName(in: reference) else { return nil }
        return directory.appending(path: name)
    }

    /// The asset file name in a reference like `NoteAssets/ABC.png`. Nil for anything else,
    /// including paths that try to leave the folder.
    static func fileName(in reference: String) -> String? {
        let prefix = folderName + "/"
        guard reference.hasPrefix(prefix) else { return nil }
        let name = String(reference.dropFirst(prefix.count))
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.hasPrefix("."),
            imageExtensions.contains((name as NSString).pathExtension.lowercased())
        else { return nil }
        return name
    }

    /// Every asset file name the notes reference.
    static func referencedNames(in notes: [QuickNote]) -> Set<String> {
        var names = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(([^)\s]+)\)"#)
        for note in notes where note.content.contains(folderName + "/") {
            let string = note.content as NSString
            for match in pattern.matches(in: note.content, range: NSRange(location: 0, length: string.length)) {
                if let name = fileName(in: string.substring(with: match.range(at: 1))) { names.insert(name) }
            }
        }
        return names
    }

    /// Deletes image files no note references any more, after notes leave Recently Deleted for
    /// good. Only files in this folder with an image extension are considered.
    @discardableResult
    func removeUnreferenced(keeping notes: [QuickNote]) -> [String] {
        let keep = Self.referencedNames(in: notes)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var removed: [String] = []
        for name in names where !keep.contains(name) && Self.imageExtensions.contains((name as NSString).pathExtension.lowercased()) {
            if (try? FileManager.default.removeItem(at: directory.appending(path: name))) != nil { removed.append(name) }
        }
        return removed
    }

    /// PNG or JPEG data from a pasteboard: the file's own bytes when it holds an image file,
    /// otherwise the pasted image as PNG. Nil when it holds no image.
    @MainActor
    static func imageData(from pasteboard: NSPasteboard) -> (data: Data, fileExtension: String)? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            let url = urls.first, imageExtensions.contains(url.pathExtension.lowercased()),
            let data = try? Data(contentsOf: url)
        {
            return (data, url.pathExtension.lowercased())
        }
        if let png = pasteboard.data(forType: .png) { return (png, "png") }
        if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        {
            return (png, "png")
        }
        return nil
    }
}
