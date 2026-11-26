import Foundation

/// The Markdown the Notes window styles as you type, and the edits its commands make.
///
/// Everything here is pure: it reads a string and returns UTF-16 ranges (`NSRange`, as
/// `NSTextView` uses) or edits to apply, so tests check the exact ranges.
enum NoteMarkdown {
    enum Style: Hashable, Sendable {
        /// A heading's text, level 1–6. The `#`s are `.syntax`.
        case heading(Int)
        /// Markup to dim: `#`, `**`, backticks, `>`, link brackets and destinations.
        case syntax
        case bold
        case italic
        case strikethrough
        /// Inline code, without its backticks.
        case code
        /// A fenced code block, fences included.
        case codeBlock
        /// A list marker: `-`, `*`, `+`, `1.`.
        case listMarker
        /// A task's `[ ]` or `[x]`.
        case task(checked: Bool)
        /// The text after a checked box.
        case completedTask
        /// A link's text, or a bare URL; the destination.
        case link(String)
        /// A quoted line's text. The `>` is `.syntax`.
        case quote
        /// `---`, `***` or `___` alone on a line.
        case rule
        /// A whole `![alt](path)`; the path.
        case image(String)
    }

    struct Span: Hashable, Sendable {
        var style: Style
        var range: NSRange
    }

    /// A replacement to make, and the selection after it, in the new text's coordinates.
    struct Edit: Equatable, Sendable {
        var range: NSRange
        var replacement: String
        var selection: NSRange

        func applied(to text: String) -> String {
            (text as NSString).replacingCharacters(in: range, with: replacement)
        }
    }

    // MARK: Patterns

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are constants; a typo fails every test, not a user.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let fence = regex(#"^[ \t]*(```|~~~)"#)
    private static let rule = regex(#"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let heading = regex(#"^(#{1,6})([ \t]+)(.*)$"#)
    private static let quote = regex(#"^([ \t]*>[ \t]?)"#)
    /// Indent, marker, space; then an optional task box and its space.
    private static let listItem = regex(#"^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+)(\[( |x|X)\](?:[ \t]|$))?"#)
    private static let inlineCode = regex(#"`([^`\n]+)`"#)
    private static let image = regex(#"!\[([^\]\n]*)\]\(([^)\s]+)\)"#)
    private static let link = regex(#"(?<!!)\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    private static let boldStars = regex(#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#)
    private static let boldUnderscores = regex(#"(?<![\w_])__(?=\S)(.+?)(?<=\S)__(?![\w_])"#)
    private static let italicStar = regex(#"(?<![*\\\w])\*(?![*\s])(.+?)(?<![*\s\\])\*(?!\*)"#)
    private static let italicUnderscore = regex(#"(?<![\w_\\])_(?![_\s])(.+?)(?<![_\s\\])_(?![\w_])"#)
    private static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let bareURL = regex(#"(?<![\w(<\[/])https?://[^\s<>()\[\]]*[^\s<>()\[\].,;:!?'"]"#)

    // MARK: Styling

    /// Every styled range in the text, sorted by location.
    static func spans(in text: String) -> [Span] {
        let string = text as NSString
        var spans: [Span] = []
        var fenceStart: Int?
        var fenceMarker = ""
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) {
            _, lineRange, _, _ in
            let line = string.substring(with: lineRange)
            let local = NSRange(location: 0, length: (line as NSString).length)
            if let start = fenceStart {
                if let match = fence.firstMatch(in: line, range: local),
                    (line as NSString).substring(with: match.range(at: 1)) == fenceMarker
                {
                    spans.append(Span(style: .codeBlock, range: NSRange(location: start, length: NSMaxRange(lineRange) - start)))
                    fenceStart = nil
                }
                return
            }
            if let match = fence.firstMatch(in: line, range: local) {
                fenceStart = lineRange.location
                fenceMarker = (line as NSString).substring(with: match.range(at: 1))
                return
            }
            spans += lineSpans(line, offset: lineRange.location)
        }
        // An unclosed fence runs to the end, as you type the block.
        if let start = fenceStart {
            spans.append(Span(style: .codeBlock, range: NSRange(location: start, length: string.length - start)))
        }
        return spans.sorted { $0.range.location == $1.range.location ? $0.range.length < $1.range.length : $0.range.location < $1.range.location }
    }

    private static func lineSpans(_ line: String, offset: Int) -> [Span] {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        func shifted(_ range: NSRange) -> NSRange { NSRange(location: range.location + offset, length: range.length) }
        var spans: [Span] = []
        if rule.firstMatch(in: line, range: all) != nil {
            return [Span(style: .rule, range: shifted(all))]
        }
        var contentStart = 0
        if let match = heading.firstMatch(in: line, range: all) {
            let level = match.range(at: 1).length
            spans.append(Span(style: .syntax, range: shifted(NSRange(location: 0, length: match.range(at: 3).location))))
            if match.range(at: 3).length > 0 {
                spans.append(Span(style: .heading(level), range: shifted(match.range(at: 3))))
            }
            contentStart = match.range(at: 3).location
        } else {
            if let match = quote.firstMatch(in: line, range: all) {
                spans.append(Span(style: .syntax, range: shifted(match.range)))
                let rest = NSRange(location: NSMaxRange(match.range), length: ns.length - NSMaxRange(match.range))
                if rest.length > 0 { spans.append(Span(style: .quote, range: shifted(rest))) }
                contentStart = NSMaxRange(match.range)
            }
            let remainder = NSRange(location: contentStart, length: ns.length - contentStart)
            if let match = listItem.firstMatch(in: line, range: remainder) {
                spans.append(Span(style: .listMarker, range: shifted(match.range(at: 2))))
                contentStart = NSMaxRange(match.range(at: 3))
                if match.range(at: 4).location != NSNotFound {
                    let box = NSRange(location: match.range(at: 4).location, length: 3)
                    let checked = match.range(at: 5).location != NSNotFound && ns.substring(with: match.range(at: 5)) != " "
                    spans.append(Span(style: .task(checked: checked), range: shifted(box)))
                    contentStart = NSMaxRange(match.range(at: 4))
                    let rest = NSRange(location: contentStart, length: ns.length - contentStart)
                    if checked, rest.length > 0 { spans.append(Span(style: .completedTask, range: shifted(rest))) }
                }
            }
        }
        let content = NSRange(location: contentStart, length: ns.length - contentStart)
        spans += inlineSpans(line, in: content).map { Span(style: $0.style, range: shifted($0.range)) }
        return spans
    }

    /// Emphasis, code, links and images inside one line.
    private static func inlineSpans(_ line: String, in range: NSRange) -> [Span] {
        var spans: [Span] = []
        // Code and links are claimed first; nothing inside them is styled again.
        var claimed: [NSRange] = []
        func isFree(_ range: NSRange) -> Bool { !claimed.contains { NSIntersectionRange($0, range).length > 0 } }

        for match in inlineCode.matches(in: line, range: range) {
            spans.append(Span(style: .syntax, range: NSRange(location: match.range.location, length: 1)))
            spans.append(Span(style: .code, range: match.range(at: 1)))
            spans.append(Span(style: .syntax, range: NSRange(location: NSMaxRange(match.range) - 1, length: 1)))
            claimed.append(match.range)
        }
        for match in image.matches(in: line, range: range) where isFree(match.range) {
            let path = (line as NSString).substring(with: match.range(at: 2))
            spans.append(Span(style: .image(path), range: match.range))
            claimed.append(match.range)
        }
        for match in link.matches(in: line, range: range) where isFree(match.range) {
            let destination = (line as NSString).substring(with: match.range(at: 2))
            let text = match.range(at: 1)
            spans.append(Span(style: .syntax, range: NSRange(location: match.range.location, length: 1)))
            spans.append(Span(style: .link(destination), range: text))
            spans.append(
                Span(style: .syntax, range: NSRange(location: NSMaxRange(text), length: NSMaxRange(match.range) - NSMaxRange(text))))
            claimed.append(match.range)
        }
        for match in bareURL.matches(in: line, range: range) where isFree(match.range) {
            spans.append(Span(style: .link((line as NSString).substring(with: match.range)), range: match.range))
            claimed.append(match.range)
        }
        func wrapped(_ expression: NSRegularExpression, style: Style, marker: Int) {
            for match in expression.matches(in: line, range: range) where isFree(match.range) {
                spans.append(Span(style: .syntax, range: NSRange(location: match.range.location, length: marker)))
                spans.append(Span(style: style, range: match.range(at: 1)))
                spans.append(Span(style: .syntax, range: NSRange(location: NSMaxRange(match.range) - marker, length: marker)))
            }
        }
        wrapped(boldStars, style: .bold, marker: 2)
        wrapped(boldUnderscores, style: .bold, marker: 2)
        // Italic markers inside bold ones (“***x***”) are left alone.
        let boldRanges = spans.filter { $0.style == .bold }.map(\.range)
        for expression in [italicStar, italicUnderscore] {
            for match in expression.matches(in: line, range: range)
            where isFree(match.range) && !boldRanges.contains(where: { NSIntersectionRange($0, match.range) == match.range }) {
                spans.append(Span(style: .syntax, range: NSRange(location: match.range.location, length: 1)))
                spans.append(Span(style: .italic, range: match.range(at: 1)))
                spans.append(Span(style: .syntax, range: NSRange(location: NSMaxRange(match.range) - 1, length: 1)))
            }
        }
        wrapped(strike, style: .strikethrough, marker: 2)
        return spans
    }

    // MARK: Lines

    /// The range of the line holding `location`, without its line break.
    static func lineRange(in text: String, at location: Int) -> NSRange {
        let string = text as NSString
        let clamped = min(max(location, 0), string.length)
        var start = 0
        var end = 0
        var contentsEnd = 0
        string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: clamped, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    /// The ranges of every line the selection touches.
    static func lineRanges(in text: String, selection: NSRange) -> [NSRange] {
        let string = text as NSString
        let end = min(NSMaxRange(selection), string.length)
        var ranges = [lineRange(in: text, at: selection.location)]
        while let last = ranges.last {
            // The line after this one's break. A selection that ends right where a line starts
            // doesn't reach into it.
            let next = NSMaxRange(string.lineRange(for: NSRange(location: last.location, length: 0)))
            guard next > last.location, next < end else { break }
            ranges.append(lineRange(in: text, at: next))
        }
        return ranges
    }

    // MARK: Tasks

    /// Checks or unchecks the task on the line holding `location`. Nil when the line isn't a task.
    /// The caret stays where it was.
    static func toggleTask(in text: String, at location: Int, selection: NSRange? = nil) -> Edit? {
        let line = lineRange(in: text, at: location)
        let string = text as NSString
        let lineText = string.substring(with: line)
        var start = 0
        if let match = quote.firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) {
            start = NSMaxRange(match.range)
        }
        let rest = NSRange(location: start, length: (lineText as NSString).length - start)
        guard let match = listItem.firstMatch(in: lineText, range: rest), match.range(at: 5).location != NSNotFound
        else { return nil }
        let box = match.range(at: 5)
        let checked = (lineText as NSString).substring(with: box) != " "
        let range = NSRange(location: line.location + box.location, length: 1)
        return Edit(range: range, replacement: checked ? " " : "x", selection: selection ?? NSRange(location: location, length: 0))
    }

    /// The task box under a click, so a click on `[ ]` toggles it.
    static func taskBox(in text: String, at location: Int) -> NSRange? {
        let line = lineRange(in: text, at: location)
        let lineText = (text as NSString).substring(with: line)
        return lineSpans(lineText, offset: line.location).first { span in
            if case .task = span.style { return NSLocationInRange(location, span.range) }
            return false
        }?.range
    }

    // MARK: Return

    /// What ↩ at the end of `line` does: continue its list, task list or quote on the next line,
    /// or end the list when the item is empty. Nil for an ordinary line.
    enum Continuation: Equatable {
        /// Start the next line with this prefix.
        case continueWith(String)
        /// The item is empty: remove its marker instead of adding a line.
        case endList(markerLength: Int)
    }

    static func continuation(after line: String) -> Continuation? {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let match = listItem.firstMatch(in: line, range: all) {
            let afterMarker = NSMaxRange(match.range)
            if ns.substring(from: afterMarker).trimmingCharacters(in: .whitespaces).isEmpty {
                return .endList(markerLength: ns.length)
            }
            let indent = ns.substring(with: match.range(at: 1))
            let marker = ns.substring(with: match.range(at: 2))
            var next = marker
            if let last = marker.last, last == "." || last == ")", let number = Int(marker.dropLast()) {
                next = "\(number + 1)\(last)"
            }
            let task = match.range(at: 4).location != NSNotFound ? "[ ] " : ""
            return .continueWith(indent + next + " " + task)
        }
        if let match = quote.firstMatch(in: line, range: all) {
            if ns.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespaces).isEmpty {
                return .endList(markerLength: ns.length)
            }
            let marker = ns.substring(with: match.range)
            return .continueWith(marker.hasSuffix(" ") ? marker : marker + " ")
        }
        return nil
    }

    /// The edit for ↩ with the caret at `location` and nothing selected, or nil to insert a plain line break.
    static func newline(in text: String, at location: Int) -> Edit? {
        let line = lineRange(in: text, at: location)
        // Only at the end of the line; ↩ mid-line splits it as usual.
        guard location == NSMaxRange(line), !isInsideCodeBlock(text, at: location) else { return nil }
        let lineText = (text as NSString).substring(with: line)
        switch continuation(after: lineText) {
        case .continueWith(let prefix)?:
            let replacement = "\n" + prefix
            return Edit(
                range: NSRange(location: location, length: 0), replacement: replacement,
                selection: NSRange(location: location + (replacement as NSString).length, length: 0))
        case .endList(let length)?:
            let range = NSRange(location: line.location, length: length)
            return Edit(range: range, replacement: "", selection: NSRange(location: line.location, length: 0))
        case nil:
            return nil
        }
    }

    static func isInsideCodeBlock(_ text: String, at location: Int) -> Bool {
        // Past the opening fence and up to the block's end, so the caret at the end of an
        // unclosed block counts as inside it.
        spans(in: text).contains {
            $0.style == .codeBlock && location > $0.range.location && location <= NSMaxRange($0.range)
        }
    }

    // MARK: Blocks

    enum Block: Hashable, Sendable {
        case paragraph
        case heading(Int)
        case bulletList
        case numberedList
        case taskList
        case quote
    }

    /// The block prefix a line starts with, and its length.
    static func block(of line: String) -> (block: Block, prefixLength: Int) {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let match = heading.firstMatch(in: line, range: all) {
            return (.heading(match.range(at: 1).length), match.range(at: 3).location)
        }
        if let match = quote.firstMatch(in: line, range: all) { return (.quote, NSMaxRange(match.range)) }
        if let match = listItem.firstMatch(in: line, range: all) {
            let marker = ns.substring(with: match.range(at: 2))
            if match.range(at: 4).location != NSNotFound { return (.taskList, NSMaxRange(match.range)) }
            return (marker.first?.isNumber == true ? .numberedList : .bulletList, NSMaxRange(match.range))
        }
        return (.paragraph, 0)
    }

    private static func prefix(for block: Block, number: Int) -> String {
        switch block {
        case .paragraph: ""
        case .heading(let level): String(repeating: "#", count: min(max(level, 1), 6)) + " "
        case .bulletList: "- "
        case .numberedList: "\(number). "
        case .taskList: "- [ ] "
        case .quote: "> "
        }
    }

    /// Turns every line the selection touches into `block`, or back into paragraphs when they
    /// all already are one. The selection keeps covering the same words.
    static func setBlock(_ block: Block, in text: String, selection: NSRange) -> Edit {
        let lines = lineRanges(in: text, selection: selection)
        let string = text as NSString
        let current = lines.map { Self.block(of: string.substring(with: $0)) }
        let target: Block = current.allSatisfy({ $0.block == block }) && block != .paragraph ? .paragraph : block
        let whole = NSRange(location: lines[0].location, length: NSMaxRange(lines[lines.count - 1]) - lines[0].location)
        var replacement = ""
        var delta = 0
        var startDelta = 0
        for (index, line) in lines.enumerated() {
            let text = string.substring(with: line)
            let body = (text as NSString).substring(from: current[index].prefixLength)
            let newPrefix = prefix(for: target, number: index + 1)
            let change = (newPrefix as NSString).length - current[index].prefixLength
            if index == 0 { startDelta = change }
            delta += change
            replacement += newPrefix + body
            if index < lines.count - 1 {
                let gap = NSRange(location: NSMaxRange(line), length: lines[index + 1].location - NSMaxRange(line))
                replacement += string.substring(with: gap)
            }
        }
        let start = max(lines[0].location, selection.location + startDelta)
        let length = selection.length == 0 ? 0 : max(0, selection.length + delta - startDelta)
        return Edit(range: whole, replacement: replacement, selection: NSRange(location: start, length: length))
    }

    // MARK: Inline

    /// Wraps the selection in `marker` (“**”, “_”, “~~”, “`”), or unwraps it when it's already
    /// wrapped. With nothing selected it inserts a pair and puts the caret between them.
    static func toggleWrap(_ marker: String, in text: String, selection: NSRange) -> Edit {
        let string = text as NSString
        let length = (marker as NSString).length
        let before = NSRange(location: selection.location - length, length: length)
        let after = NSRange(location: NSMaxRange(selection), length: length)
        if before.location >= 0, NSMaxRange(after) <= string.length, string.substring(with: before) == marker,
            string.substring(with: after) == marker
        {
            let whole = NSRange(location: before.location, length: NSMaxRange(after) - before.location)
            return Edit(
                range: whole, replacement: string.substring(with: selection),
                selection: NSRange(location: before.location, length: selection.length))
        }
        let selected = string.substring(with: selection)
        if selected.count >= 2 * marker.count, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: length, length: (selected as NSString).length - 2 * length))
            return Edit(range: selection, replacement: inner, selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }
        return Edit(
            range: selection, replacement: marker + selected + marker,
            selection: NSRange(location: selection.location + length, length: selection.length))
    }

    /// Makes the selection a link's text, with the caret in the empty destination.
    /// A selected URL becomes the destination instead, with the caret in the text.
    static func insertLink(in text: String, selection: NSRange) -> Edit {
        let selected = (text as NSString).substring(with: selection)
        if let url = URL(string: selected), url.scheme?.hasPrefix("http") == true {
            return Edit(range: selection, replacement: "[](\(selected))", selection: NSRange(location: selection.location + 1, length: 0))
        }
        let replacement = "[\(selected)]()"
        return Edit(
            range: selection, replacement: replacement,
            selection: NSRange(location: selection.location + (replacement as NSString).length - 1, length: 0))
    }

    /// Wraps the lines the selection touches in a fenced code block, with the caret inside.
    static func codeBlock(in text: String, selection: NSRange) -> Edit {
        let lines = lineRanges(in: text, selection: selection)
        let whole = NSRange(location: lines[0].location, length: NSMaxRange(lines[lines.count - 1]) - lines[0].location)
        let body = (text as NSString).substring(with: whole)
        let replacement = "```\n" + body + "\n```"
        let caret = whole.location + 4 + (body as NSString).length
        return Edit(range: whole, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }

    /// Inserts an image reference on its own line at the selection.
    static func insertImage(_ reference: String, in text: String, selection: NSRange, alt: String = "Image") -> Edit {
        let string = text as NSString
        let needsLeadingBreak = selection.location > 0 && string.character(at: selection.location - 1) != 10
        let replacement = (needsLeadingBreak ? "\n" : "") + "![\(alt)](\(reference))\n"
        let caret = selection.location + (replacement as NSString).length
        return Edit(range: selection, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }
}

/// An entry in the `/` menu: a block to start, or something to insert.
enum NoteSlashCommand: String, CaseIterable, Identifiable, Sendable {
    case heading1, heading2, heading3, bulletList, numberedList, taskList, quote, codeBlock, divider, link, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .bulletList: "Bulleted List"
        case .numberedList: "Numbered List"
        case .taskList: "Task List"
        case .quote: "Quote"
        case .codeBlock: "Code Block"
        case .divider: "Divider"
        case .link: "Link"
        case .image: "Image…"
        }
    }

    var symbol: String {
        switch self {
        case .heading1: "textformat.size.larger"
        case .heading2: "textformat.size"
        case .heading3: "textformat.size.smaller"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .taskList: "checklist"
        case .quote: "text.quote"
        case .codeBlock: "chevron.left.forwardslash.chevron.right"
        case .divider: "minus"
        case .link: "link"
        case .image: "photo"
        }
    }

    /// The Markdown you could type instead, shown beside the title.
    var hint: String {
        switch self {
        case .heading1: "#"
        case .heading2: "##"
        case .heading3: "###"
        case .bulletList: "-"
        case .numberedList: "1."
        case .taskList: "[ ]"
        case .quote: ">"
        case .codeBlock: "```"
        case .divider: "---"
        case .link: "⌘L"
        case .image: "⌘V"
        }
    }

    private var keywords: String {
        switch self {
        case .heading1: "h1 title heading"
        case .heading2: "h2 subtitle heading"
        case .heading3: "h3 heading"
        case .bulletList: "ul bullet unordered list"
        case .numberedList: "ol ordered number list"
        case .taskList: "todo checkbox task checklist"
        case .quote: "blockquote quote"
        case .codeBlock: "code pre fence"
        case .divider: "hr rule separator line divider"
        case .link: "url link href"
        case .image: "picture photo image screenshot"
        }
    }

    /// Commands matching what follows the `/`, best first. An empty query lists them all.
    static func matching(_ query: String) -> [NoteSlashCommand] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return allCases }
        var scored: [(command: NoteSlashCommand, score: Int)] = []
        for command in allCases {
            let titleScore: Int? = SearchMatcher.score(query, in: command.title)
            let keywordScore: Int? = SearchMatcher.score(query, in: command.keywords).map { $0 - 50 }
            guard let score = [titleScore, keywordScore].compactMap({ $0 }).max() else { continue }
            scored.append((command, score))
        }
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.command.sortIndex < rhs.command.sortIndex : lhs.score > rhs.score
        }
        return scored.map(\.command)
    }

    private var sortIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// The `/` the caret is typing a command after: a slash at the start of a line or after a
    /// space, followed only by letters and digits up to the caret.
    static func trigger(in text: String, caret: Int) -> (slash: Int, query: String)? {
        let string = text as NSString
        guard caret > 0, caret <= string.length else { return nil }
        let line = NoteMarkdown.lineRange(in: text, at: caret)
        var index = caret - 1
        while index >= line.location {
            let character = string.character(at: index)
            if character == 0x2F {  // "/"
                guard index == line.location || [0x20, 0x09].contains(string.character(at: index - 1)) else { return nil }
                let query = string.substring(with: NSRange(location: index + 1, length: caret - index - 1))
                guard query.count <= 24 else { return nil }
                return (index, query)
            }
            guard let scalar = Unicode.Scalar(character), CharacterSet.alphanumerics.contains(scalar) else { return nil }
            index -= 1
        }
        return nil
    }

    /// Removes the typed `/query` and applies the command to its line. Nil for `.image`, which
    /// needs a file first (see `NoteMarkdown.insertImage`).
    func edit(in text: String, slash: Int, caret: Int) -> NoteMarkdown.Edit? {
        let typed = NSRange(location: slash, length: max(0, caret - slash))
        let cleared = (text as NSString).replacingCharacters(in: typed, with: "")
        let at = NSRange(location: slash, length: 0)
        let applied: NoteMarkdown.Edit
        switch self {
        case .heading1: applied = NoteMarkdown.setBlock(.heading(1), in: cleared, selection: at)
        case .heading2: applied = NoteMarkdown.setBlock(.heading(2), in: cleared, selection: at)
        case .heading3: applied = NoteMarkdown.setBlock(.heading(3), in: cleared, selection: at)
        case .bulletList: applied = NoteMarkdown.setBlock(.bulletList, in: cleared, selection: at)
        case .numberedList: applied = NoteMarkdown.setBlock(.numberedList, in: cleared, selection: at)
        case .taskList: applied = NoteMarkdown.setBlock(.taskList, in: cleared, selection: at)
        case .quote: applied = NoteMarkdown.setBlock(.quote, in: cleared, selection: at)
        case .codeBlock: applied = NoteMarkdown.codeBlock(in: cleared, selection: at)
        case .divider:
            let line = NoteMarkdown.lineRange(in: cleared, at: slash)
            let isEmpty = (cleared as NSString).substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty
            let replacement = isEmpty ? "---\n" : "\n---\n"
            let insertAt = isEmpty ? line.location : NSMaxRange(line)
            let range = isEmpty ? line : NSRange(location: insertAt, length: 0)
            applied = NoteMarkdown.Edit(
                range: range, replacement: replacement,
                selection: NSRange(location: insertAt + (replacement as NSString).length, length: 0))
        case .link: applied = NoteMarkdown.insertLink(in: cleared, selection: at)
        case .image: return nil
        }
        // Express it as one edit over the original text, so a single undo reverts it.
        let result = applied.applied(to: cleared) as NSString
        let original = text as NSString
        var prefix = 0
        let limit = min(original.length, result.length)
        while prefix < limit, original.character(at: prefix) == result.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix,
            original.character(at: original.length - 1 - suffix) == result.character(at: result.length - 1 - suffix)
        {
            suffix += 1
        }
        let range = NSRange(location: prefix, length: original.length - prefix - suffix)
        let replacement = result.substring(with: NSRange(location: prefix, length: result.length - prefix - suffix))
        return NoteMarkdown.Edit(range: range, replacement: replacement, selection: applied.selection)
    }
}
