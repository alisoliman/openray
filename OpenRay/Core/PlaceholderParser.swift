import Foundation

/// Turns template text into literal and placeholder segments.
///
/// Grammar, with whitespace allowed between parts:
///
///     placeholder := "{" name attribute* ("|" modifier)* "}"
///     attribute   := key "=" value
///     value       := "…" | “…” | '…' | bare
///
/// Double-quoted values accept `\"` and `\\`. Bare values run to the next space,
/// `|` or `}`. A placeholder never spans lines. Unknown names are literal text.
/// A known name with bad syntax is reported as `.invalid` and kept literal: when
/// its closing brace can be found (skipping quoted text), the whole span stays
/// literal, so nothing quoted inside it expands. When it's never closed, or an
/// unquoted `{` starts another token first, only the `{` is literal and parsing
/// continues after it.
struct PlaceholderParser {
    let source: String
    let context: PlaceholderContext

    /// Longest placeholder considered, so a stray `{` can't make parsing quadratic.
    static let maximumLength = 2_048

    private enum Outcome {
        case placeholder(Placeholder)
        /// The text to report and, for a closed token, where its literal span ends.
        case invalid(String, end: String.Index?)
        case notAPlaceholder
    }

    func parse() -> ([PlaceholderTemplate.Segment], [PlaceholderIssue]) {
        var segments: [PlaceholderTemplate.Segment] = []
        var issues: [PlaceholderIssue] = []
        var literal = ""
        var index = source.startIndex

        func flush() {
            if !literal.isEmpty { segments.append(.literal(literal)) }
            literal = ""
        }

        while index < source.endIndex {
            let character = source[index]
            if character == "\\", source.index(after: index) < source.endIndex,
                source[source.index(after: index)] == "{"
            {
                let brace = source.index(after: index)
                if case .placeholder(let placeholder) = scan(at: brace) {
                    // An escaped placeholder is kept as written, without the backslash.
                    literal += placeholder.source
                    index = placeholder.range.upperBound
                    continue
                }
                literal.append(character)
                index = brace
                continue
            }
            guard character == "{" else {
                literal.append(character)
                index = source.index(after: index)
                continue
            }
            switch scan(at: index) {
            case .placeholder(let placeholder):
                flush()
                segments.append(.placeholder(placeholder))
                index = placeholder.range.upperBound
            case .invalid(let text, let end):
                issues.append(.invalid(text))
                if let end {
                    literal += source[index..<end]
                    index = end
                } else {
                    literal.append(character)
                    index = source.index(after: index)
                }
            case .notAPlaceholder:
                literal.append(character)
                index = source.index(after: index)
            }
        }
        flush()
        return (segments, issues)
    }

    // MARK: - Scanning

    private func scan(at start: String.Index) -> Outcome {
        var cursor = Cursor(text: source, index: source.index(after: start), start: start)
        cursor.skipSpaces()
        let name = cursor.identifier()
        guard !name.isEmpty else { return .notAPlaceholder }
        let kind: Placeholder.Kind?
        if let known = Placeholder.Kind(rawValue: name) {
            kind = known
        } else if context == .quicklink {
            // Quicklinks written before named arguments used `{query}` or `{Name}`.
            kind = nil
        } else {
            return .notAPlaceholder
        }
        let isLegacyArgument = kind == nil

        var attributes: [String: String] = [:]
        var modifiers: [PlaceholderModifier] = []
        var failed = false
        scanning: while true {
            cursor.skipSpaces()
            guard let next = cursor.peek, !cursor.exceededLimit else {
                failed = true
                break
            }
            switch next {
            case "}":
                cursor.advance()
                break scanning
            case "|":
                cursor.advance()
                cursor.skipSpaces()
                let word = cursor.identifier()
                guard let modifier = PlaceholderModifier(rawValue: word) else {
                    failed = true
                    break scanning
                }
                modifiers.append(modifier)
            default:
                let key = cursor.identifier()
                guard !key.isEmpty, !isLegacyArgument, cursor.peek == "=", attributes[key] == nil else {
                    failed = true
                    break scanning
                }
                cursor.advance()
                guard let value = cursor.value() else {
                    failed = true
                    break scanning
                }
                attributes[key] = value
            }
        }

        if isLegacyArgument {
            // A legacy `{Name}` has no attributes. Anything else is ordinary text.
            guard !failed, modifiers.count <= PlaceholderModifier.maximumChain else { return .notAPlaceholder }
            let range = start..<cursor.index
            return .placeholder(
                Placeholder(
                    token: .argument(PlaceholderArgument(id: .named(name))), modifiers: modifiers,
                    source: String(source[range]), range: range, isLegacyArgument: true))
        }
        guard let kind else { return .notAPlaceholder }
        guard !failed else {
            if let end = closingEnd(from: start) { return .invalid(String(source[start..<end]), end: end) }
            return .invalid(Self.excerpt(of: source, from: start), end: nil)
        }
        let range = start..<cursor.index
        let text = String(source[range])
        guard modifiers.count <= PlaceholderModifier.maximumChain,
            let token = Self.token(for: kind, attributes: attributes, modifiers: modifiers)
        else {
            return .invalid(text, end: range.upperBound)
        }
        return .placeholder(Placeholder(token: token, modifiers: modifiers, source: text, range: range))
    }

    /// The end of a malformed token, just past its closing brace, found by skipping
    /// quoted text on the same line. Nil when unclosed or when an unquoted `{`
    /// comes first; stopping there keeps the scan short on hostile input.
    private func closingEnd(from start: String.Index) -> String.Index? {
        var index = source.index(after: start)
        var quote: Character?
        var scanned = 0
        while index < source.endIndex, scanned <= Self.maximumLength {
            let character = source[index]
            guard !character.isNewline else { return nil }
            if let open = quote {
                if character == open || (open == "\"" && (character == "”" || character == "“")) { quote = nil }
            } else {
                switch character {
                case "\"", "“", "”", "'": quote = character == "'" ? "'" : "\""
                case "{": return nil
                case "}": return source.index(after: index)
                default: break
                }
            }
            index = source.index(after: index)
            scanned += 1
        }
        return nil
    }

    private static func excerpt(of source: String, from start: String.Index) -> String {
        // Bounded first: an unbounded scan here made many malformed placeholders quadratic.
        let tail = source[start...].prefix(80).prefix { !$0.isNewline }
        if let close = tail.firstIndex(of: "}") { return String(tail[...close]) }
        return String(tail)
    }

    // MARK: - Attributes

    private static func token(
        for kind: Placeholder.Kind, attributes: [String: String], modifiers: [PlaceholderModifier]
    ) -> PlaceholderToken? {
        func allows(_ keys: Set<String>) -> Bool { Set(attributes.keys).isSubset(of: keys) }

        switch kind {
        case .clipboard:
            guard allows(["offset"]) else { return nil }
            guard let raw = attributes["offset"] else { return .clipboard(offset: 0) }
            guard raw.count <= 4, raw.allSatisfy(\.isASCII), let offset = Int(raw), offset >= 0 else { return nil }
            return .clipboard(offset: offset)
        case .selection:
            return attributes.isEmpty ? .selection : nil
        case .uuid:
            return attributes.isEmpty ? .uuid : nil
        case .cursor:
            // Modifiers can't apply to a caret position.
            return attributes.isEmpty && modifiers.isEmpty ? .cursor : nil
        case .snippet:
            guard allows(["name"]), let name = attributes["name"]?.trimmingCharacters(in: .whitespaces),
                !name.isEmpty
            else { return nil }
            return .snippet(name: name)
        case .argument:
            guard allows(["name", "default", "options"]) else { return nil }
            var argument = PlaceholderArgument(id: .unnamed(0))
            if let name = attributes["name"] {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
                argument.id = .named(trimmed)
            }
            argument.defaultValue = attributes["default"]
            if let options = attributes["options"] {
                var seen = Set<String>()
                argument.options = options.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }
                guard !argument.options.isEmpty else { return nil }
            }
            return .argument(argument)
        case .date, .time, .datetime, .day:
            guard allows(["offset", "format", "locale"]) else { return nil }
            let style: PlaceholderDateToken.Style =
                switch kind {
                case .time: .time
                case .datetime: .dateTime
                case .day: .weekday
                default: .date
                }
            var token = PlaceholderDateToken(style: style)
            if let offset = attributes["offset"] {
                guard let offsets = PlaceholderDateOffset.parse(offset) else { return nil }
                token.offsets = offsets
            }
            // The reference treats format and locale as mutually exclusive.
            guard attributes["format"] == nil || attributes["locale"] == nil else { return nil }
            if let format = attributes["format"] {
                guard !format.isEmpty, format.count <= 200 else { return nil }
                token.format = format
            }
            if let locale = attributes["locale"] {
                guard isRecognizedLocale(locale) else { return nil }
                token.locale = locale
            }
            return .date(token)
        case .calculator:
            guard allows(["expression"]), let expression = attributes["expression"],
                !expression.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return .calculator(expression: expression)
        case .browserTab:
            return allows(["format", "selector"]) ? .browserTab : nil
        }
    }

    /// A hyphenated BCP 47 tag whose language Foundation knows. `en_US` is rejected,
    /// as in the reference, so templates behave the same in both launchers.
    static func isRecognizedLocale(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first, (2...3).contains(language.count),
            language.allSatisfy({ $0.isASCII && $0.isLetter }),
            parts.dropFirst().allSatisfy({ (1...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
        else { return false }
        guard let code = Locale(identifier: identifier).language.languageCode else { return false }
        return Locale.LanguageCode.isoLanguageCodes.contains(code)
    }
}

/// A forward-only reader over one placeholder.
private struct Cursor {
    let text: String
    var index: String.Index
    let start: String.Index
    private var consumed = 0

    init(text: String, index: String.Index, start: String.Index) {
        self.text = text
        self.index = index
        self.start = start
    }

    var exceededLimit: Bool { consumed > PlaceholderParser.maximumLength }

    var peek: Character? {
        guard index < text.endIndex else { return nil }
        let character = text[index]
        // A placeholder never spans lines.
        return character.isNewline ? nil : character
    }

    mutating func advance() {
        index = text.index(after: index)
        consumed += 1
    }

    mutating func skipSpaces() {
        while let character = peek, character == " " || character == "\t" { advance() }
    }

    /// Letters, digits, `-` and `_`, starting with a letter.
    mutating func identifier() -> String {
        var result = ""
        while let character = peek, character.isASCII,
            character.isLetter || (!result.isEmpty && (character.isNumber || character == "-" || character == "_"))
        {
            result.append(character)
            advance()
            if result.count > 64 { return "" }
        }
        return result
    }

    mutating func value() -> String? {
        guard let first = peek else { return nil }
        switch first {
        case "\"", "“", "”":
            advance()
            return quoted(closing: ["\"", "”", "“"], escapes: true)
        case "'":
            advance()
            return quoted(closing: ["'"], escapes: false)
        default:
            var result = ""
            while let character = peek, !character.isWhitespace, character != "|", character != "}" {
                guard character != "\"", character != "'", character != "{" else { return nil }
                result.append(character)
                advance()
                if exceededLimit { return nil }
            }
            return result.isEmpty ? nil : result
        }
    }

    private mutating func quoted(closing: Set<Character>, escapes: Bool) -> String? {
        var result = ""
        while let character = peek {
            advance()
            if exceededLimit { return nil }
            if closing.contains(character) { return result }
            if escapes, character == "\\", let next = peek, next == "\"" || next == "\\" {
                result.append(next)
                advance()
                continue
            }
            result.append(character)
        }
        return nil
    }
}
