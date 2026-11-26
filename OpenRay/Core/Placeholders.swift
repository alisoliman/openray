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
// `if x { return }` is never changed. A closed but malformed placeholder stays
// literal as one span, so nothing inside it is expanded. A backslash directly
// before a placeholder (`\{clipboard}`) keeps it as literal text and drops the backslash.
//
// Three steps, so nothing is read before it's needed:
//
//     let template = PlaceholderTemplate(text, context: .snippet)
//     let plan = template.plan(snippets: { name in library.snippetText(named: name) })
//     plan.arguments      // ask the person for these
//     plan.requirements   // read only these: clipboard offsets, selection, …
//     plan.issues         // show in an editor; `blocksExecution` ones stop a run
//     let result = plan.render(PlaceholderValues(arguments: [.named("who"): "Ann"]))
//
// `template.render(source)` does all three at once when laziness doesn't matter.

/// Where a template is rendered. The context decides the default formatting of
/// inserted values and which placeholders are honored.
enum PlaceholderContext: String, CaseIterable, Sendable {
    /// Inserted values are not encoded. `{cursor}` sets the caret position.
    case snippet
    /// Inserted values are percent-encoded unless a placeholder uses `raw` or
    /// `percent-encode`. `{query}` and bare `{Name}` act as named arguments, for
    /// templates written before arguments had their own syntax.
    case quicklink
    /// Inserted content (clipboard, selection, arguments, snippets) is fenced so a
    /// prompt can tell it apart from instructions, unless `raw` is used. See
    /// `PlaceholderEncoding.fenced(_:)`.
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
    /// quicklinks, fencing in AI commands). It doesn't change the value.
    case raw

    /// The longest chain a placeholder may use; longer chains are invalid.
    static let maximumChain = 8

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

    /// The UTF-8 size of `percentEncoded(value)`, computed without allocating it.
    static func percentEncodedSize(_ value: String) -> Int {
        value.utf8.reduce(0) { size, byte in
            let isUnreserved =
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 45 || byte == 46 || byte == 95 || byte == 126
            return size + (isUnreserved ? 1 : 3)
        }
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

    /// An upper bound on the UTF-8 size of `jsonString(value)`, computed without allocating it.
    static func jsonStringSize(_ value: String) -> Int {
        2
            + value.unicodeScalars.reduce(0) { size, scalar in
                switch scalar.value {
                case 0x22, 0x5C, 0x08, 0x0C, 0x0A, 0x0D, 0x09: size + 2
                case 0..<0x20, 0x2028, 0x2029, 0x7F: size + 6
                default: size + String(scalar).utf8.count
                }
            }
    }

    /// Content between fences of double quotes on their own lines. The fence is
    /// longer than any run of quotes inside, so the content can't close it early,
    /// and the content itself is unchanged:
    ///
    ///     """
    ///     the value
    ///     """
    static func fenced(_ value: String) -> String {
        let fence = String(repeating: "\"", count: fenceLength(for: value))
        return fence + "\n" + value + "\n" + fence
    }

    static func fenceLength(for value: String) -> Int {
        var longest = 0
        var run = 0
        for scalar in value.unicodeScalars {
            run = scalar == "\"" ? run + 1 : 0
            longest = max(longest, run)
        }
        return max(3, longest + 1)
    }
}

/// A date or time offset such as `+2y +5M -3d`. Units: `m` minutes, `h` hours,
/// `d` days, `M` months, `y` years. Each term needs a sign directly before its
/// digits, as in the reference.
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
            guard let sign = term.first, sign == "+" || sign == "-", let last = term.last,
                let unit = Unit(rawValue: last)
            else { return nil }
            let digits = term.dropFirst().dropLast()
            guard (1...6).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                let value = Int(digits)
            else { return nil }
            result.append(PlaceholderDateOffset(amount: sign == "-" ? -value : value, unit: unit))
        }
        return result
    }
}

/// An argument a template asks for. Arguments with the same name share one value.
struct PlaceholderArgument: Hashable, Sendable, Identifiable {
    enum ID: Hashable, Sendable {
        /// `{argument name="…"}`, `{query}` or a bare quicklink `{Name}`.
        case named(String)
        /// Each `{argument}` without a name in the template itself, numbered from 1.
        /// The numbering never depends on referenced snippets.
        case unnamed(Int)
        /// An `{argument}` without a name inside the referenced snippet `snippet`,
        /// numbered from 1 within that snippet.
        case snippetUnnamed(snippet: String, index: Int)
    }

    /// At most three distinct arguments per template, including referenced snippets.
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

        /// Values an AI command fences as quoted content.
        var isContent: Bool { [.clipboard, .selection, .argument, .snippet, .browserTab].contains(self) }

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
    /// A quicklink `{query}` or `{Name}` written before arguments had their own syntax.
    var isLegacyArgument = false

    var kind: Kind { token.kind }
}

/// A problem found while planning or rendering. Invalid placeholders stay in the
/// output as literal text; an editor can show these next to the field.
enum PlaceholderIssue: Hashable, Sendable {
    /// Text that names a placeholder but has bad syntax or attributes, e.g. an
    /// unknown locale or both `format` and `locale`. It stays literal.
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
    /// Nothing was available for `{clipboard}` or `{selection}`. It renders empty,
    /// as the reference documents for an empty clipboard.
    case unavailable(Placeholder.Kind)
    /// The output passed `PlaceholderRenderOptions.maximumOutputBytes`. Rendering stopped.
    case outputTooLong
    /// Planning stopped: referenced snippets expand to more than `PlaceholderPlan.maximumNodes`
    /// placeholders and text runs. Nothing is read or rendered.
    case tooComplex
    /// A malformed placeholder whose quoted text is never closed, or that runs past the
    /// scan limit. What follows can't be told apart from what's inside it, so it blocks.
    case unterminated(String)

    /// Whether a command should refuse to run. Missing inputs it can't make up,
    /// failed lookups and oversized output block. Invalid syntax stays literal and
    /// doesn't block on its own, because code snippets often contain braces; a
    /// consumer that can't accept literal braces, such as a URL, checks for it.
    var blocksExecution: Bool {
        switch self {
        case .tooManyArguments, .missingSnippet, .nestedSnippet, .missingArgument, .calculationFailed, .outputTooLong,
            .tooComplex, .unterminated:
            true
        case .invalid, .notHonored, .unsupported, .duplicateCursor, .unavailable:
            false
        }
    }
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
        case .outputTooLong: "The result is too long."
        case .tooComplex: "This template expands to too much text. Use fewer snippet references."
        case .unterminated(let text): "“\(text)” is never closed. Close its quotes and brace, or escape the brace with \\."
        }
    }
}

/// The values placeholders read. Every requirement has a default, so a source
/// only implements what it can provide. A plan calls each method only when the
/// template needs it; `PlaceholderPlan.requirements` says which ahead of time.
protocol PlaceholderDataSource {
    var now: Date { get }
    /// The calendar for offsets and formatting. Its time zone is used for output.
    var calendar: Calendar { get }
    var locale: Locale { get }
    /// Text copied `offset` entries ago; 0 is the current clipboard.
    func clipboardText(offset: Int) -> String?
    func selectedText() -> String?
    /// The raw text of the snippet with this name. Planning calls only this.
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

/// An immutable snapshot of placeholder values. Tests and simple callers use it
/// directly; the app fills it from `PlaceholderPlan.requirements` at the moment
/// a command runs.
struct PlaceholderValues: PlaceholderDataSource, Sendable {
    var now: Date
    var calendar: Calendar
    var locale: Locale
    /// What `{clipboard}` inserts. Nil when the clipboard holds no readable text.
    var currentClipboard: String?
    /// Earlier copies, newest first: `{clipboard offset=1}` is the first.
    var clipboardHistory: [String]
    var selection: String?
    /// Snippet text by name. Lookup is exact first, then case-insensitive.
    var snippets: [String: String]
    var arguments: [PlaceholderArgument.ID: String]
    var calculator: (@Sendable (String) -> String?)?
    var uuid: @Sendable () -> UUID

    /// `clipboard` lists copies newest first: the current clipboard, then history.
    init(
        now: Date = .now, calendar: Calendar = .current, locale: Locale = .current, clipboard: [String] = [],
        selection: String? = nil, snippets: [String: String] = [:], arguments: [PlaceholderArgument.ID: String] = [:],
        calculator: (@Sendable (String) -> String?)? = nil, uuid: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
        currentClipboard = clipboard.first
        clipboardHistory = Array(clipboard.dropFirst())
        self.selection = selection
        self.snippets = snippets
        self.arguments = arguments
        self.calculator = calculator
        self.uuid = uuid
    }

    func clipboardText(offset: Int) -> String? {
        if offset == 0 { return currentClipboard }
        return clipboardHistory.indices.contains(offset - 1) ? clipboardHistory[offset - 1] : nil
    }

    func selectedText() -> String? { selection }

    func snippetText(named name: String) -> String? {
        if let exact = snippets[name] { return exact }
        return snippets.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func value(for argument: PlaceholderArgument) -> String? { arguments[argument.id] }
    func calculate(_ expression: String) -> String? { calculator?(expression) }
    func makeUUID() -> UUID { uuid() }
}

/// What a plan will read when it renders, including referenced snippets and
/// calculator expressions. Gather exactly these before rendering.
struct PlaceholderRequirements: Hashable, Sendable {
    var clipboardOffsets: Set<Int> = []
    var selection = false
    var calculator = false
    var uuid = false
    /// Dates and times read the clock, calendar and locale.
    var clock = false
    /// Names of referenced snippets, resolved or not, in order.
    var snippets: [String] = []

    var clipboard: Bool { !clipboardOffsets.isEmpty }
}

/// Where one placeholder's value landed in the output, for callers that want
/// structured content instead of the formatted text, e.g. an AI prompt builder.
struct PlaceholderSubstitution: Equatable, Sendable {
    var kind: Placeholder.Kind
    /// UTF-16 offsets into `PlaceholderRendering.text`, after formatting.
    var range: Range<Int>
    /// The value after modifiers, before the context's default formatting.
    var value: String
}

/// The output of rendering a plan.
struct PlaceholderRendering: Equatable, Sendable {
    var text: String
    /// Where `{cursor}` was, as a UTF-16 offset into `text` (an `NSRange` location).
    var cursorUTF16Offset: Int?
    /// Every argument the plan needs, in order of first appearance.
    var arguments: [PlaceholderArgument]
    var issues: [PlaceholderIssue]
    var substitutions: [PlaceholderSubstitution] = []

    /// The caret position in characters from the start of `text`.
    var cursorOffset: Int? {
        cursorIndex.map { text.distance(from: text.startIndex, to: $0) }
    }

    /// How many characters follow the caret.
    var charactersAfterCursor: Int? {
        cursorIndex.map { text[$0...].count }
    }

    /// How many UTF-16 code units follow the caret.
    var utf16AfterCursor: Int? {
        cursorUTF16Offset.map { text.utf16.count - $0 }
    }

    var cursorIndex: String.Index? {
        guard let offset = cursorUTF16Offset, (0...text.utf16.count).contains(offset) else { return nil }
        return String.Index(utf16Offset: offset, in: text)
    }

    /// Issues that should stop a command from using this text.
    var blockingIssues: [PlaceholderIssue] { issues.filter(\.blocksExecution) }

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

    /// Resolves referenced snippets with `snippets`, the only lookup planning does,
    /// and works out arguments, issues and requirements without reading any value.
    func plan(snippets: (String) -> String?) -> PlaceholderPlan {
        PlaceholderPlan(template: self, snippets: snippets)
    }

    /// The arguments written in this template and its calculator expressions.
    /// IDs match a full plan's; referenced snippets add their own `.snippetUnnamed`
    /// or named arguments, so use `plan(snippets:)` to see those too.
    var arguments: [PlaceholderArgument] { plan(snippets: { _ in nil }).arguments }

    /// Issues an editor should show before saving: syntax, too many arguments, a
    /// second `{cursor}` and placeholders this context ignores. Snippet references
    /// aren't looked up; use `plan(snippets:).issues` for those.
    var validationIssues: [PlaceholderIssue] {
        plan(snippets: { _ in nil }).issues.filter {
            if case .missingSnippet = $0 { false } else { true }
        }
    }

    /// Plans with `source`'s snippets, then renders from `source`.
    func render(_ source: some PlaceholderDataSource, options: PlaceholderRenderOptions = .init())
        -> PlaceholderRendering
    {
        plan(snippets: source.snippetText(named:)).render(source, options: options)
    }
}

/// Limits and switches for rendering. Immutable, so limits are always validated.
struct PlaceholderRenderOptions: Equatable, Sendable {
    /// Set to false to skip the context's default formatting, e.g. to render a
    /// quicklink file path whose values must not be percent-encoded.
    let appliesContextFormatting: Bool
    /// Characters kept from each inserted value before modifiers. Never negative.
    let maximumValueLength: Int
    /// The UTF-8 size the whole output may reach, counting literals, modifiers,
    /// formatting and referenced snippets. Past it, rendering stops with `.outputTooLong`.
    let maximumOutputBytes: Int

    init(appliesContextFormatting: Bool = true, maximumValueLength: Int = 200_000, maximumOutputBytes: Int = 1_000_000) {
        self.appliesContextFormatting = appliesContextFormatting
        self.maximumValueLength = max(0, maximumValueLength)
        self.maximumOutputBytes = max(0, maximumOutputBytes)
    }
}

enum Placeholders {
    /// Parses, plans and renders in one step.
    static func render(
        _ template: String, context: PlaceholderContext, source: some PlaceholderDataSource,
        options: PlaceholderRenderOptions = .init()
    ) -> PlaceholderRendering {
        PlaceholderTemplate(template, context: context).render(source, options: options)
    }
}

/// Deduplicates arguments by ID, merges defaults and options across occurrences,
/// and enforces the limit.
struct PlaceholderArgumentCollector {
    private(set) var arguments: [PlaceholderArgument] = []

    /// Returns false when the template already has three distinct arguments.
    mutating func register(_ argument: PlaceholderArgument) -> Bool {
        if let index = arguments.firstIndex(where: { $0.id == argument.id }) {
            if arguments[index].defaultValue == nil { arguments[index].defaultValue = argument.defaultValue }
            if arguments[index].options.isEmpty { arguments[index].options = argument.options }
            return true
        }
        guard arguments.count < PlaceholderArgument.limit else { return false }
        arguments.append(argument)
        return true
    }
}

// MARK: - Command arguments

extension PlaceholderArgument.ID {
    /// The `ArgumentSpec.name` for this argument. The three kinds never collide:
    /// - a name as written, so `{query}` stays `query`; a name starting with `#`
    ///   becomes `#=` plus the name;
    /// - `#1` for the template's first unnamed argument (`#` and digits only);
    /// - `#1@Signature` for the first unnamed argument inside the snippet "Signature".
    var specName: String {
        switch self {
        case .named(let name): name.hasPrefix("#") ? "#=" + name : name
        case .unnamed(let index): "#\(index)"
        case .snippetUnnamed(let snippet, let index): "#\(index)@\(snippet)"
        }
    }
}

extension PlaceholderArgument {
    /// The field a command shows for this argument. A plain `{query}` keeps
    /// `ArgumentSpec.query`, so the single-argument path and stored specs don't change.
    var argumentSpec: ArgumentSpec {
        if id == .named("query"), defaultValue == nil, options.isEmpty { return .query }
        let placeholder: String =
            switch id {
            case .named(let name): name
            case .unnamed(let index): "Argument \(index)"
            case .snippetUnnamed(let snippet, let index): "\(snippet) \(index)"
            }
        var type = ArgumentSpec.InputType.text
        if !options.isEmpty {
            var choices = options
            // A default outside the options would never validate; offer it too.
            if let defaultValue, !choices.contains(defaultValue) { choices.insert(defaultValue, at: 0) }
            type = .dropdown(choices.map { ArgumentSpec.Option(title: $0, value: $0) })
        }
        return ArgumentSpec(
            name: id.specName, placeholder: placeholder, type: type, isOptional: !isRequired,
            defaultValue: defaultValue)
    }
}
