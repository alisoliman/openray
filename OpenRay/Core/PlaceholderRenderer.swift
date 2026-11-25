import Foundation

/// A template with its referenced snippets resolved and its arguments final.
/// Building a plan reads no values: only snippet text, through the lookup given
/// to `PlaceholderTemplate.plan(snippets:)`. Rendering then reads exactly what
/// `requirements` lists, and resolves each argument once before substituting,
/// so every occurrence of a name gets the same value.
struct PlaceholderPlan: Hashable, Sendable {
    indirect enum Node: Hashable, Sendable {
        case literal(String)
        case cursor
        /// Clipboard, selection, dates, UUID and browser-tab.
        case value(Placeholder)
        case argument(Placeholder, PlaceholderArgument.ID)
        /// Nil when the snippet is missing or can't nest; it renders empty.
        case snippet(Placeholder, [Node]?)
        /// Nil when nested too deeply; it renders empty.
        case calculator(Placeholder, [Node]?)
    }

    let context: PlaceholderContext
    let nodes: [Node]
    /// Final specs, in order of first appearance: a later occurrence's default or
    /// options apply to every occurrence of the same argument.
    let arguments: [PlaceholderArgument]
    /// Parse and structure issues, including those inside referenced snippets and
    /// calculator expressions. Rendering adds value issues such as missing arguments.
    let issues: [PlaceholderIssue]
    let requirements: PlaceholderRequirements

    init(template: PlaceholderTemplate, snippets: (String) -> String?) {
        var builder = PlanBuilder(context: template.context)
        nodes = builder.build(template, depth: 0, snippet: nil, lookup: snippets)
        context = template.context
        arguments = builder.collector.arguments
        var seen = Set<PlaceholderIssue>()
        issues = builder.issues.filter { seen.insert($0).inserted }
        requirements = builder.requirements
    }

    /// Blocking issues known before any value is read.
    var blockingIssues: [PlaceholderIssue] { issues.filter(\.blocksExecution) }

    func render(_ source: some PlaceholderDataSource, options: PlaceholderRenderOptions = .init())
        -> PlaceholderRendering
    {
        var renderer = PlanRenderer(plan: self, source: source, options: options)
        return renderer.run()
    }
}

// MARK: - Planning

private struct PlanBuilder {
    let context: PlaceholderContext
    var collector = PlaceholderArgumentCollector()
    var issues: [PlaceholderIssue] = []
    var requirements = PlaceholderRequirements()
    private var topLevelUnnamed = 0
    private var snippetUnnamed = 0
    private var sawCursor = false

    /// Referenced snippets plan one level deep; calculator expressions two.
    private static let maximumDepth = 2

    init(context: PlaceholderContext) {
        self.context = context
    }

    mutating func build(
        _ template: PlaceholderTemplate, depth: Int, snippet: String?, lookup: (String) -> String?
    ) -> [PlaceholderPlan.Node] {
        issues += template.parseIssues
        var nodes: [PlaceholderPlan.Node] = []
        for segment in template.segments {
            let placeholder: Placeholder
            switch segment {
            case .literal(let text):
                nodes.append(.literal(text))
                continue
            case .placeholder(let value):
                placeholder = value
            }
            switch placeholder.token {
            case .cursor:
                // A referenced snippet's caret is dropped; only the template itself places one.
                guard depth == 0 else { continue }
                if context != .snippet {
                    issues.append(.notHonored(.cursor))
                } else if sawCursor {
                    issues.append(.duplicateCursor)
                } else {
                    sawCursor = true
                    nodes.append(.cursor)
                }
            case .clipboard(let offset):
                requirements.clipboardOffsets.insert(offset)
                nodes.append(.value(placeholder))
            case .selection:
                requirements.selection = true
                nodes.append(.value(placeholder))
            case .date:
                requirements.clock = true
                nodes.append(.value(placeholder))
            case .uuid:
                requirements.uuid = true
                nodes.append(.value(placeholder))
            case .browserTab:
                issues.append(.unsupported(.browserTab))
                nodes.append(.value(placeholder))
            case .argument(var argument):
                if case .unnamed = argument.id {
                    if let snippet {
                        snippetUnnamed += 1
                        argument.id = .snippetUnnamed(snippet: snippet, index: snippetUnnamed)
                    } else {
                        topLevelUnnamed += 1
                        argument.id = .unnamed(topLevelUnnamed)
                    }
                }
                if collector.register(argument) {
                    nodes.append(.argument(placeholder, argument.id))
                } else {
                    issues.append(.tooManyArguments(placeholder.source))
                    nodes.append(.literal(placeholder.source))
                }
            case .snippet(let name):
                requirements.snippets.append(name)
                guard depth == 0 else {
                    issues.append(.nestedSnippet(name))
                    nodes.append(.snippet(placeholder, nil))
                    continue
                }
                guard let text = lookup(name) else {
                    issues.append(.missingSnippet(name))
                    nodes.append(.snippet(placeholder, nil))
                    continue
                }
                // Each reference numbers its unnamed arguments from 1, so two
                // references to one snippet share their values.
                snippetUnnamed = 0
                let nested = build(
                    PlaceholderTemplate(text, context: .snippet), depth: depth + 1, snippet: name, lookup: lookup)
                nodes.append(.snippet(placeholder, nested))
            case .calculator(let expression):
                requirements.calculator = true
                guard depth < Self.maximumDepth else {
                    issues.append(.invalid(placeholder.source))
                    nodes.append(.calculator(placeholder, nil))
                    continue
                }
                let nested = build(
                    PlaceholderTemplate(expression, context: template.context), depth: depth + 1, snippet: snippet,
                    lookup: lookup)
                nodes.append(.calculator(placeholder, nested))
            }
        }
        return nodes
    }
}

// MARK: - Rendering

private struct PlanRenderer<Source: PlaceholderDataSource> {
    let plan: PlaceholderPlan
    let source: Source
    let options: PlaceholderRenderOptions
    private var issues: [PlaceholderIssue]
    private var resolved: [PlaceholderArgument.ID: String] = [:]
    private var cursorUTF16Offset: Int?
    private var substitutions: [PlaceholderSubstitution] = []
    private var overflowed = false

    init(plan: PlaceholderPlan, source: Source, options: PlaceholderRenderOptions) {
        self.plan = plan
        self.source = source
        self.options = options
        issues = plan.issues
    }

    mutating func run() -> PlaceholderRendering {
        // Each argument resolves once, from its final spec.
        for argument in plan.arguments {
            if let value = source.value(for: argument), !value.isEmpty {
                resolved[argument.id] = value
            } else if let fallback = argument.defaultValue {
                resolved[argument.id] = fallback
            } else {
                issues.append(.missingArgument(argument.title))
                resolved[argument.id] = ""
            }
        }
        var output = ""
        append(plan.nodes, depth: 0, limit: options.maximumOutputBytes, to: &output)
        if overflowed { issues.append(.outputTooLong) }
        var seen = Set<PlaceholderIssue>()
        return PlaceholderRendering(
            text: output, cursorUTF16Offset: cursorUTF16Offset, arguments: plan.arguments,
            issues: issues.filter { seen.insert($0).inserted }, substitutions: substitutions)
    }

    /// Appends rendered nodes while `output` stays within `limit` UTF-8 bytes.
    /// Text from a referenced snippet or calculator expression is inserted as one
    /// value, so the outer placeholder's modifiers and formatting apply to it whole.
    private mutating func append(
        _ nodes: [PlaceholderPlan.Node], depth: Int, limit: Int, to output: inout String
    ) {
        for node in nodes {
            guard !overflowed else { return }
            let room = limit - output.utf8.count
            switch node {
            case .literal(let text):
                guard text.utf8.count <= room else {
                    overflowed = true
                    return
                }
                output += text
            case .cursor:
                cursorUTF16Offset = output.utf16.count
            case .value(let placeholder):
                insert(rawValue(of: placeholder), for: placeholder, depth: depth, room: room, into: &output)
            case .argument(let placeholder, let id):
                insert(resolved[id] ?? "", for: placeholder, depth: depth, room: room, into: &output)
            case .snippet(let placeholder, let nested):
                var text = ""
                if let nested { append(nested, depth: depth + 1, limit: room, to: &text) }
                insert(text, for: placeholder, depth: depth, room: room, into: &output)
            case .calculator(let placeholder, let nested):
                guard let nested else {
                    insert("", for: placeholder, depth: depth, room: room, into: &output)
                    continue
                }
                var expression = ""
                append(nested, depth: depth + 1, limit: room, to: &expression)
                guard !overflowed else { return }
                let result: String
                if let value = source.calculate(expression) {
                    result = value
                } else {
                    issues.append(.calculationFailed(expression))
                    result = ""
                }
                insert(result, for: placeholder, depth: depth, room: room, into: &output)
            }
        }
    }

    private mutating func insert(
        _ value: String, for placeholder: Placeholder, depth: Int, room: Int, into output: inout String
    ) {
        guard !overflowed else { return }
        guard let (formatted, modified) = format(value, of: placeholder, formats: depth == 0, room: room) else {
            overflowed = true
            return
        }
        let start = output.utf16.count
        output += formatted
        if depth == 0 {
            substitutions.append(
                PlaceholderSubstitution(kind: placeholder.kind, range: start..<output.utf16.count, value: modified))
        }
    }

    private mutating func rawValue(of placeholder: Placeholder) -> String {
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
        case .date(let token):
            guard let text = formattedDate(token) else {
                issues.append(.invalid(placeholder.source))
                return ""
            }
            return text
        case .uuid:
            return source.makeUUID().uuidString
        case .browserTab, .cursor, .argument, .snippet, .calculator:
            return ""
        }
    }

    // MARK: Formatting

    /// The formatted value and the value after modifiers, or nil when either would
    /// pass `room` bytes. Sizes of expanding steps are checked before allocating.
    private func format(_ value: String, of placeholder: Placeholder, formats: Bool, room: Int)
        -> (String, String)?
    {
        var text = String(value.prefix(options.maximumValueLength))
        guard text.utf8.count <= room else { return nil }
        let modifiers = placeholder.modifiers
        for modifier in modifiers {
            switch modifier {
            case .percentEncode: guard PlaceholderEncoding.percentEncodedSize(text) <= room else { return nil }
            case .jsonStringify: guard PlaceholderEncoding.jsonStringSize(text) <= room else { return nil }
            case .uppercase, .lowercase, .trim, .raw: break
            }
            text = modifier.apply(to: text)
            guard text.utf8.count <= room else { return nil }
        }
        let modified = text
        guard formats, options.appliesContextFormatting, !modifiers.contains(.raw) else { return (text, modified) }
        switch plan.context {
        case .quicklink:
            guard !modifiers.contains(.percentEncode) else { return (text, modified) }
            guard PlaceholderEncoding.percentEncodedSize(text) <= room else { return nil }
            text = PlaceholderEncoding.percentEncoded(text)
        case .aiCommand:
            guard placeholder.kind.isContent, !text.isEmpty, !modifiers.contains(.jsonStringify) else {
                return (text, modified)
            }
            guard text.utf8.count + 2 * (PlaceholderEncoding.fenceLength(for: text) + 1) <= room else { return nil }
            text = PlaceholderEncoding.fenced(text)
        case .snippet, .text:
            break
        }
        return (text, modified)
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
