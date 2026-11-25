import Foundation

// Dynamic placeholders: one engine for snippets, quicklinks, AI commands and
// script commands. Syntax follows the public reference at
// https://manual.raycast.com/dynamic-placeholders so templates written for
// either launcher render the same way.
//
//     {clipboard}  {clipboard offset=1}         {selection}
//     {snippet name="Signature"}                 {cursor}
//     {argument name="tone" default="happy" options="happy, sad"}
//     {date}  {time}  {datetime}  {day}  with offset="+3d -2h", format="…" or locale="fr-FR"
//     {uuid}  {calculator expression="2 * 21"}   {browser-tab} (not supported)
//     {clipboard | trim | uppercase}             modifiers chain left to right
//
// Text that doesn't form a placeholder stays literal, so code such as
// `if x { return }` is never changed. A backslash directly before a placeholder
// (`\{clipboard}`) keeps the placeholder as literal text and drops the backslash.
//
// Usage:
//
//     let template = PlaceholderTemplate("Hi {argument name=\"who\"}", context: .snippet)
//     template.arguments                    // ask the person for these
//     let result = template.render(PlaceholderValues(arguments: [.named("who"): "Ann"]))
//     result.text                           // "Hi Ann"

/// Where a template is rendered. The context decides the default formatting of
/// inserted values and which placeholders are honored.
enum PlaceholderContext: String, CaseIterable, Sendable {
    /// Inserted values are not encoded. `{cursor}` sets the caret position.
    case snippet
    /// Inserted values are percent-encoded unless a placeholder uses `raw` or
    /// `percent-encode`. `{query}` and bare `{Name}` act as named arguments, for
    /// templates written before arguments had their own syntax.
    case quicklink
    /// Inserted content (clipboard, selection, arguments, snippets) is wrapped in
    /// `"""` so a prompt can tell it apart from instructions, unless `raw` is used.
    case aiCommand
    /// Plain text: no encoding and no caret. Script commands and anything else.
    case text
}

/// A transformation applied to a placeholder's value, written after `|`.
enum PlaceholderModifier: String, CaseIterable, Hashable, Sendable {
    case uppercase, lowercase, trim
    case percentEncode = "percent-encode"
    case jsonStringify = "json-stringify"
    /// Opts out of the context's default formatting (percent-encoding in
    /// quicklinks, quoting in AI commands). It doesn't change the value.
    case raw

    func apply(to value: String) -> String {
        switch self {
        case .uppercase: value.uppercased()
        case .lowercase: value.lowercased()
        case .trim: value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .percentEncode: PlaceholderEncoding.percentEncoded(value)
        case .jsonStringify: PlaceholderEncoding.jsonString(value)
        case .raw: value
        }
    }
}

enum PlaceholderEncoding {
    /// RFC 3986 unreserved characters stay as they are; everything else is encoded.
    static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// A JSON string literal, including the surrounding quotes.
    static func jsonString(_ value: String) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
            let string = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return string
    }
}

/// A date or time offset such as `+2y +5M -3d`. Units: `m` minutes, `h` hours,
/// `d` days, `M` months, `y` years. There is no space between sign and number.
struct PlaceholderDateOffset: Hashable, Sendable {
    enum Unit: Character, CaseIterable, Sendable {
        case minute = "m", hour = "h", day = "d", month = "M", year = "y"

        var component: Calendar.Component {
            switch self {
            case .minute: .minute
            case .hour: .hour
            case .day: .day
            case .month: .month
            case .year: .year
            }
        }
    }

    var amount: Int
    var unit: Unit

    /// Parses whitespace-separated terms. Returns nil if any term is malformed.
    static func parse(_ text: String) -> [PlaceholderDateOffset]? {
        let terms = text.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty, terms.count <= 12 else { return nil }
        var result: [PlaceholderDateOffset] = []
        for term in terms {
            guard let last = term.last, let unit = Unit(rawValue: last) else { return nil }
            var digits = term.dropLast()
            var sign = 1
            if digits.first == "+" || digits.first == "-" {
                sign = digits.first == "-" ? -1 : 1
                digits = digits.dropFirst()
            }
            guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy(\.isASCII), let value = Int(digits) else {
                return nil
            }
            result.append(PlaceholderDateOffset(amount: sign * value, unit: unit))
        }
        return result
    }
}

/// An argument a template asks for. Arguments with the same name share one value.
struct PlaceholderArgument: Hashable, Sendable, Identifiable {
    enum ID: Hashable, Sendable {
        /// `{argument name="…"}`, `{query}` or a bare quicklink `{Name}`.
        case named(String)
        /// Each `{argument}` without a name is its own input, numbered from 1.
        case unnamed(Int)
    }

    /// At most three distinct arguments per template.
    static let limit = 3

    var id: ID
    var defaultValue: String?
    /// Choices offered for the value, in the order written.
    var options: [String] = []

    var name: String? {
        if case .named(let name) = id { name } else { nil }
    }

    /// A label for the input field.
    var title: String { name ?? "Argument" }

    /// Arguments with a default may be left empty.
    var isRequired: Bool { defaultValue == nil }
}

/// What a well-formed placeholder inserts.
enum PlaceholderToken: Hashable, Sendable {
    case clipboard(offset: Int)
    case selection
    case snippet(name: String)
    case argument(PlaceholderArgument)
    case cursor
    case date(PlaceholderDateToken)
    case uuid
    case calculator(expression: String)
    case browserTab

    var kind: Placeholder.Kind {
        switch self {
        case .clipboard: .clipboard
        case .selection: .selection
        case .snippet: .snippet
        case .argument: .argument
        case .cursor: .cursor
        case .date(let date): date.style.kind
        case .uuid: .uuid
        case .calculator: .calculator
        case .browserTab: .browserTab
        }
    }
}

struct PlaceholderDateToken: Hashable, Sendable {
    enum Style: Hashable, Sendable {
        case date, time, dateTime, weekday

        var kind: Placeholder.Kind {
            switch self {
            case .date: .date
            case .time: .time
            case .dateTime: .datetime
            case .weekday: .day
            }
        }
    }

    var style: Style
    var offsets: [PlaceholderDateOffset] = []
    /// A Unicode date pattern such as `yyyy-MM-dd`. Never set together with `locale`.
    var format: String?
    /// A BCP 47 identifier such as `fr-FR` or `en-US-u-hc-h23`.
    var locale: String?
}

/// One placeholder as written in a template.
struct Placeholder: Hashable, Sendable {
    enum Kind: String, CaseIterable, Hashable, Sendable {
        case clipboard, selection, snippet, argument, cursor, date, time, datetime, day, uuid, calculator
        case browserTab = "browser-tab"

        /// A display name for editor chips and messages.
        var title: String {
            switch self {
            case .clipboard: "Clipboard Text"
            case .selection: "Selected Text"
            case .snippet: "Snippet"
            case .argument: "Argument"
            case .cursor: "Cursor Position"
            case .date: "Date"
            case .time: "Time"
            case .datetime: "Date & Time"
            case .day: "Weekday"
            case .uuid: "UUID"
            case .calculator: "Calculator"
            case .browserTab: "Focused Browser Tab"
            }
        }

        /// The text an editor inserts for this placeholder.
        var insertionText: String {
            switch self {
            case .snippet: "{snippet name=\"\"}"
            case .argument: "{argument name=\"\"}"
            case .calculator: "{calculator expression=\"\"}"
            default: "{\(rawValue)}"
            }
        }

        /// Whether rendering in `context` produces a value. `{cursor}` only works in
        /// snippets, and `{browser-tab}` needs a browser integration OpenRay doesn't have.
        func isHonored(in context: PlaceholderContext) -> Bool {
            switch self {
            case .cursor: context == .snippet
            case .browserTab: false
            default: true
            }
        }

        /// Placeholders an editor offers as chips in `context`.
        static func suggested(in context: PlaceholderContext) -> [Kind] {
            allCases.filter { $0.isHonored(in: context) }
        }
    }

    var token: PlaceholderToken
    var modifiers: [PlaceholderModifier] = []
    /// The placeholder exactly as written, including braces.
    var source: String
    /// Where the placeholder sits in the template's source text.
    var range: Range<String.Index>

    var kind: Kind { token.kind }
}

/// A problem found while parsing or rendering. Invalid placeholders stay in the
/// output as literal text; an editor can show these next to the field.
enum PlaceholderIssue: Hashable, Sendable {
    /// Text that names a placeholder but has bad syntax or attributes, e.g. an
    /// unknown locale or both `format` and `locale`.
    case invalid(String)
    /// More than three distinct arguments. Extra ones stay literal.
    case tooManyArguments(String)
    /// A placeholder this context doesn't honor, e.g. `{cursor}` outside snippets. It renders empty.
    case notHonored(Placeholder.Kind)
    /// A placeholder OpenRay can't provide, e.g. `{browser-tab}`. It renders empty.
    case unsupported(Placeholder.Kind)
    /// Only the first `{cursor}` counts; later ones render empty.
    case duplicateCursor
    case missingSnippet(String)
    /// `{snippet}` inside a referenced snippet. Snippets don't nest further.
    case nestedSnippet(String)
    /// A required argument without a value. It renders empty.
    case missingArgument(String)
    case calculationFailed(String)
    /// Nothing was available for `{clipboard}` or `{selection}`. It renders empty.
    case unavailable(Placeholder.Kind)
}

extension PlaceholderIssue {
    /// A sentence for an editor or an error message.
    var message: String {
        switch self {
        case .invalid(let text): "“\(text)” isn't a valid placeholder."
        case .tooManyArguments: "Use up to \(PlaceholderArgument.limit) different arguments."
        case .notHonored(let kind): "\(kind.title) only works in snippets."
        case .unsupported(let kind): "\(kind.title) isn't supported in OpenRay."
        case .duplicateCursor: "Use only one {cursor} placeholder."
        case .missingSnippet(let name): "There's no snippet named “\(name)”."
        case .nestedSnippet(let name): "“\(name)” can't be inserted inside another snippet."
        case .missingArgument(let title): "Enter a value for “\(title)”."
        case .calculationFailed(let expression): "“\(expression)” couldn't be calculated."
        case .unavailable(let kind): "\(kind.title) wasn't available."
        }
    }
}

/// The values placeholders read. Every requirement has a default, so a source
/// only implements what it can provide. Rendering calls each method only when the
/// template needs it, so an expensive lookup such as the selection stays lazy.
protocol PlaceholderDataSource {
    var now: Date { get }
    /// The calendar for offsets and formatting. Its time zone is used for output.
    var calendar: Calendar { get }
    var locale: Locale { get }
    /// Text copied `offset` entries ago; 0 is the current clipboard.
    func clipboardText(offset: Int) -> String?
    func selectedText() -> String?
    /// The raw text of the snippet with this name.
    func snippetText(named name: String) -> String?
    func value(for argument: PlaceholderArgument) -> String?
    /// The result of a math expression, formatted for insertion.
    func calculate(_ expression: String) -> String?
    func makeUUID() -> UUID
}

extension PlaceholderDataSource {
    var now: Date { .now }
    var calendar: Calendar { .current }
    var locale: Locale { .current }
    func clipboardText(offset: Int) -> String? { nil }
    func selectedText() -> String? { nil }
    func snippetText(named name: String) -> String? { nil }
    func value(for argument: PlaceholderArgument) -> String? { nil }
    func calculate(_ expression: String) -> String? { nil }
    func makeUUID() -> UUID { UUID() }
}

/// A ready-made data source holding plain values. Tests and simple callers use it
/// directly; the app can fill it from the clipboard history and snippet library.
struct PlaceholderValues: PlaceholderDataSource, Sendable {
    var now: Date = .now
    var calendar: Calendar = .current
    var locale: Locale = .current
    /// Most recent first. Index 0 is `{clipboard}`.
    var clipboard: [String] = []
    var selection: String?
    /// Snippet text by name. Lookup is exact first, then case-insensitive.
    var snippets: [String: String] = [:]
    var arguments: [PlaceholderArgument.ID: String] = [:]
    var calculator: (@Sendable (String) -> String?)?
    var uuid: @Sendable () -> UUID = { UUID() }

    func clipboardText(offset: Int) -> String? { clipboard.indices.contains(offset) ? clipboard[offset] : nil }
    func selectedText() -> String? { selection }

    func snippetText(named name: String) -> String? {
        if let exact = snippets[name] { return exact }
        return snippets.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func value(for argument: PlaceholderArgument) -> String? { arguments[argument.id] }
    func calculate(_ expression: String) -> String? { calculator?(expression) }
    func makeUUID() -> UUID { uuid() }
}

/// The output of rendering a template.
struct PlaceholderRendering: Equatable, Sendable {
    var text: String
    /// Where `{cursor}` was, as a UTF-16 offset into `text` (an `NSRange` location).
    var cursorUTF16Offset: Int?
    /// Every argument the template needs, including those of referenced snippets,
    /// in order of first appearance.
    var arguments: [PlaceholderArgument]
    var issues: [PlaceholderIssue]

    /// The caret position in characters from the start of `text`.
    var cursorOffset: Int? {
        cursorIndex.map { text.distance(from: text.startIndex, to: $0) }
    }

    /// How many characters follow the caret, i.e. how many times to press ← after
    /// typing `text` to put the caret where `{cursor}` was.
    var charactersAfterCursor: Int? {
        cursorIndex.map { text[$0...].count }
    }

    var cursorIndex: String.Index? {
        guard let offset = cursorUTF16Offset, (0...text.utf16.count).contains(offset) else { return nil }
        return String.Index(utf16Offset: offset, in: text)
    }

    /// Required arguments that had no value.
    var missingArguments: [String] {
        issues.compactMap { if case .missingArgument(let title) = $0 { title } else { nil } }
    }

    /// Placeholders OpenRay can't provide, such as `browser-tab`.
    var unsupportedPlaceholders: [Placeholder.Kind] {
        issues.compactMap { if case .unsupported(let kind) = $0 { kind } else { nil } }
    }
}

/// A parsed template. Parsing never fails: anything that isn't a placeholder is literal text.
struct PlaceholderTemplate: Hashable, Sendable {
    enum Segment: Hashable, Sendable {
        case literal(String)
        case placeholder(Placeholder)
    }

    let source: String
    let context: PlaceholderContext
    let segments: [Segment]
    /// Problems found while parsing, e.g. a misspelled modifier.
    let parseIssues: [PlaceholderIssue]

    init(_ source: String, context: PlaceholderContext) {
        self.source = source
        self.context = context
        (segments, parseIssues) = PlaceholderParser(source: source, context: context).parse()
    }

    var placeholders: [Placeholder] {
        segments.compactMap { if case .placeholder(let placeholder) = $0 { placeholder } else { nil } }
    }

    var hasPlaceholders: Bool { !placeholders.isEmpty }

    func contains(_ kind: Placeholder.Kind) -> Bool { placeholders.contains { $0.kind == kind } }

    /// The arguments written directly in this template, deduplicated by name and
    /// capped at three. Use `arguments(using:)` to include referenced snippets.
    var arguments: [PlaceholderArgument] {
        var collector = PlaceholderArgumentCollector()
        for placeholder in placeholders {
            switch placeholder.token {
            case .argument(let argument): _ = collector.register(argument, source: placeholder.source)
            case .calculator(let expression):
                for nested in PlaceholderTemplate(expression, context: context).placeholders {
                    if case .argument(let argument) = nested.token {
                        _ = collector.register(argument, source: nested.source)
                    }
                }
            default: break
            }
        }
        return collector.arguments
    }

    /// The arguments this template needs, including those inside referenced snippets.
    func arguments(using source: some PlaceholderDataSource) -> [PlaceholderArgument] {
        render(source).arguments
    }

    /// Issues an editor should show before saving: bad syntax, too many arguments,
    /// a second `{cursor}`, and placeholders this context ignores.
    var validationIssues: [PlaceholderIssue] {
        var issues = parseIssues
        let argumentSources = placeholders.filter { $0.kind == .argument }
        var collector = PlaceholderArgumentCollector()
        for placeholder in argumentSources {
            if case .argument(let argument) = placeholder.token, collector.register(argument, source: placeholder.source) == nil {
                issues.append(.tooManyArguments(placeholder.source))
            }
        }
        var sawCursor = false
        for placeholder in placeholders {
            if !placeholder.kind.isHonored(in: context) {
                issues.append(
                    placeholder.kind == .browserTab ? .unsupported(.browserTab) : .notHonored(placeholder.kind))
            } else if placeholder.kind == .cursor {
                if sawCursor { issues.append(.duplicateCursor) }
                sawCursor = true
            }
        }
        return issues
    }

    func render(_ source: some PlaceholderDataSource, options: PlaceholderRenderOptions = .init())
        -> PlaceholderRendering
    {
        var renderer = PlaceholderRenderer(source: source, options: options)
        return renderer.render(self)
    }
}

/// Rendering switches that a caller may need beyond the context's defaults.
struct PlaceholderRenderOptions: Equatable, Sendable {
    /// Set to false to skip the context's default formatting, e.g. to render a
    /// quicklink file path whose values must not be percent-encoded.
    var appliesContextFormatting = true
    /// Values longer than this are cut, so a huge clipboard can't blow up a URL or prompt.
    var maximumValueLength = 200_000

    init(appliesContextFormatting: Bool = true, maximumValueLength: Int = 200_000) {
        self.appliesContextFormatting = appliesContextFormatting
        self.maximumValueLength = maximumValueLength
    }
}

enum Placeholders {
    /// Parses and renders in one step.
    static func render(
        _ template: String, context: PlaceholderContext, source: some PlaceholderDataSource,
        options: PlaceholderRenderOptions = .init()
    ) -> PlaceholderRendering {
        PlaceholderTemplate(template, context: context).render(source, options: options)
    }
}

/// Deduplicates arguments by name, numbers unnamed ones, and enforces the limit.
struct PlaceholderArgumentCollector {
    private(set) var arguments: [PlaceholderArgument] = []
    private var unnamedCount = 0

    /// Returns the registered argument, with its final ID and merged default and
    /// options, or nil when the template already has three distinct arguments.
    mutating func register(_ argument: PlaceholderArgument, source: String) -> PlaceholderArgument? {
        var argument = argument
        if case .unnamed = argument.id {
            guard arguments.count < PlaceholderArgument.limit else { return nil }
            unnamedCount += 1
            argument.id = .unnamed(unnamedCount)
            arguments.append(argument)
            return argument
        }
        if let index = arguments.firstIndex(where: { $0.id == argument.id }) {
            if arguments[index].defaultValue == nil { arguments[index].defaultValue = argument.defaultValue }
            if arguments[index].options.isEmpty { arguments[index].options = argument.options }
            return arguments[index]
        }
        guard arguments.count < PlaceholderArgument.limit else { return nil }
        arguments.append(argument)
        return argument
    }
}
