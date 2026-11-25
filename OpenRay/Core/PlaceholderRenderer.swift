import Foundation

/// Renders a parsed template against a data source. One renderer renders one
/// template; it collects arguments, issues and the caret position as it goes.
struct PlaceholderRenderer<Source: PlaceholderDataSource> {
    let source: Source
    let options: PlaceholderRenderOptions
    private var collector = PlaceholderArgumentCollector()
    private var issues: [PlaceholderIssue] = []
    private var cursorUTF16Offset: Int?

    /// Referenced snippets and calculator expressions render one level deep.
    private static var maximumDepth: Int { 2 }

    init(source: Source, options: PlaceholderRenderOptions) {
        self.source = source
        self.options = options
    }

    mutating func render(_ template: PlaceholderTemplate) -> PlaceholderRendering {
        issues = template.parseIssues
        var output = ""
        append(template.segments, context: template.context, depth: 0, to: &output)
        var seen = Set<PlaceholderIssue>()
        return PlaceholderRendering(
            text: output, cursorUTF16Offset: cursorUTF16Offset, arguments: collector.arguments,
            issues: issues.filter { seen.insert($0).inserted })
    }

    // MARK: - Segments

    /// `depth` 0 is the template itself. Deeper text, from a referenced snippet or a
    /// calculator expression, is inserted as one value, so the outer placeholder's
    /// modifiers and context formatting apply to it as a whole.
    private mutating func append(
        _ segments: [PlaceholderTemplate.Segment], context: PlaceholderContext, depth: Int, to output: inout String
    ) {
        for segment in segments {
            switch segment {
            case .literal(let text):
                output += text
            case .placeholder(let placeholder):
                if placeholder.token == .cursor {
                    placeCursor(context: context, depth: depth, at: output.utf16.count)
                    continue
                }
                guard let value = value(of: placeholder, context: context, depth: depth) else {
                    output += placeholder.source
                    continue
                }
                output += format(
                    String(value.prefix(options.maximumValueLength)), of: placeholder, context: context,
                    formats: depth == 0)
            }
        }
    }

    private mutating func placeCursor(context: PlaceholderContext, depth: Int, at offset: Int) {
        // A referenced snippet's caret is dropped; only the outer template places one.
        guard depth == 0 else { return }
        guard context == .snippet else {
            issues.append(.notHonored(.cursor))
            return
        }
        guard cursorUTF16Offset == nil else {
            issues.append(.duplicateCursor)
            return
        }
        cursorUTF16Offset = offset
    }

    /// The unformatted value, or nil to keep the placeholder as literal text.
    private mutating func value(of placeholder: Placeholder, context: PlaceholderContext, depth: Int) -> String? {
        switch placeholder.token {
        case .clipboard(let offset):
            guard let text = source.clipboardText(offset: offset) else {
                issues.append(.unavailable(.clipboard))
                return ""
            }
            return text
        case .selection:
            guard let text = source.selectedText() else {
                issues.append(.unavailable(.selection))
                return ""
            }
            return text
        case .snippet(let name):
            guard depth == 0 else {
                issues.append(.nestedSnippet(name))
                return ""
            }
            guard let text = source.snippetText(named: name) else {
                issues.append(.missingSnippet(name))
                return ""
            }
            var nested = ""
            append(
                PlaceholderTemplate(text, context: .snippet).segments, context: context, depth: depth + 1, to: &nested)
            return nested
        case .argument(let argument):
            guard let registered = collector.register(argument, source: placeholder.source) else {
                issues.append(.tooManyArguments(placeholder.source))
                return nil
            }
            if let value = source.value(for: registered), !value.isEmpty { return value }
            if let fallback = registered.defaultValue { return fallback }
            issues.append(.missingArgument(registered.title))
            return ""
        case .cursor:
            return ""
        case .date(let token):
            guard let text = formattedDate(token) else {
                issues.append(.invalid(placeholder.source))
                return nil
            }
            return text
        case .uuid:
            return source.makeUUID().uuidString
        case .calculator(let expression):
            guard depth < Self.maximumDepth else {
                issues.append(.invalid(placeholder.source))
                return ""
            }
            var rendered = ""
            append(
                PlaceholderTemplate(expression, context: context).segments, context: context, depth: depth + 1,
                to: &rendered)
            guard let result = source.calculate(rendered) else {
                issues.append(.calculationFailed(rendered))
                return ""
            }
            return result
        case .browserTab:
            issues.append(.unsupported(.browserTab))
            return ""
        }
    }

    // MARK: - Formatting

    private func format(
        _ value: String, of placeholder: Placeholder, context: PlaceholderContext, formats: Bool
    ) -> String {
        let modifiers = placeholder.modifiers
        let modified = modifiers.reduce(value) { $1.apply(to: $0) }
        guard formats, options.appliesContextFormatting, !modifiers.contains(.raw) else { return modified }
        switch context {
        case .quicklink:
            return modifiers.contains(.percentEncode) ? modified : PlaceholderEncoding.percentEncoded(modified)
        case .aiCommand:
            let isContent = [.clipboard, .selection, .argument, .snippet].contains(placeholder.kind)
            guard isContent, !modified.isEmpty, !modifiers.contains(.jsonStringify) else { return modified }
            return "\"\"\"" + modified + "\"\"\""
        case .snippet, .text:
            return modified
        }
    }

    private func formattedDate(_ token: PlaceholderDateToken) -> String? {
        let calendar = source.calendar
        var date = source.now
        for offset in token.offsets {
            guard let next = calendar.date(byAdding: offset.unit.component, value: offset.amount, to: date) else {
                return nil
            }
            date = next
        }
        let formatter = DateFormatter()
        if let format = token.format {
            formatter.locale = source.locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            return formatter.string(from: date)
        }
        if let identifier = token.locale {
            let locale = Locale(identifier: identifier)
            var localeCalendar = locale.calendar
            localeCalendar.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.calendar = localeCalendar
        } else {
            formatter.locale = source.locale
            formatter.calendar = calendar
        }
        formatter.timeZone = calendar.timeZone
        switch token.style {
        case .date:
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        case .time:
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        case .dateTime:
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        case .weekday:
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        }
        return formatter.string(from: date)
    }
}
