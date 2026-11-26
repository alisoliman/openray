import Foundation

struct Snippet: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var keyword: String
    var content: String
    /// Per-snippet keyword expansion. Missing means on, subject to the master switch.
    var expandsKeyword: Bool? = nil
    /// Labels for search and filtering. Missing in libraries from before tags.
    var tags: [String]? = nil
    /// The placeholder syntax `content` is written in. 1: before dynamic placeholders,
    /// when only exact `{date}` and `{time}` were filled in; saved snippets without a
    /// version decode as 1 and keep that behavior, text untouched. 2: the engine.
    var placeholderVersion = Snippet.currentPlaceholderVersion

    /// The longest snippet text, as in the public reference.
    static let maximumLength = 65_000
    /// Version 2: the dynamic placeholder engine.
    static let currentPlaceholderVersion = 2

    var expandsAsYouType: Bool { expandsKeyword ?? true }
    var tagList: [String] { tags ?? [] }

    /// True for snippets written with dynamic placeholders.
    var usesDynamicPlaceholders: Bool { placeholderVersion >= Self.currentPlaceholderVersion }

    /// The engine's view of the content, or nil for a snippet from before dynamic
    /// placeholders, which renders with `legacyExpanded` instead.
    var dynamicTemplate: PlaceholderTemplate? {
        usesDynamicPlaceholders ? PlaceholderTemplate(content, context: .snippet) : nil
    }

    /// Old content in the new syntax: every placeholder except exact `{date}` and
    /// `{time}` escaped. The editor shows this, and saves it as version 2.
    static func migratingLegacyContent(_ content: String) -> String {
        PlaceholderParser.escaping(content, context: .snippet) { $0.source == "{date}" || $0.source == "{time}" }
    }

    /// What the editor shows and saves: the content, in the new syntax.
    var editableContent: String { usesDynamicPlaceholders ? content : Self.migratingLegacyContent(content) }

    /// Exactly what OpenRay did before dynamic placeholders: every `{date}` and
    /// `{time}` replaced, wherever it is, and nothing else touched.
    func legacyExpanded(at date: Date = .now, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = timeZone
        dateFormatter.dateStyle = .medium
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.timeZone = timeZone
        timeFormatter.timeStyle = .short
        return content.replacingOccurrences(of: "{date}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: date))
    }

    /// How a referencing snippet sees this one: dynamic content as written, or an old
    /// snippet's output as literal text, so nothing in it becomes a placeholder.
    func referenceSource(now: Date = .now) -> String {
        usesDynamicPlaceholders
            ? content : PlaceholderParser.escaping(legacyExpanded(at: now), context: .snippet) { _ in false }
    }

    /// The text with what needs nothing from the library filled in: dates, times,
    /// UUIDs and argument defaults. `{clipboard}` and other inputs render empty;
    /// the launcher renders with `LauncherModel.runSnippet` instead.
    func expanded(at date: Date = .now, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let template = dynamicTemplate else { return legacyExpanded(at: date, locale: locale, timeZone: timeZone) }
        var calendar = locale.calendar
        calendar.timeZone = timeZone
        return template.render(PlaceholderValues(now: date, calendar: calendar, locale: locale)).text
    }

    func validate(against others: [Snippet]) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryValidationError("Give this snippet a name.")
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.count <= Self.maximumLength
        else {
            throw LibraryValidationError("Snippet text must contain between 1 and 65,000 characters.")
        }
        if !keyword.isEmpty {
            guard keyword.count >= 2, SnippetKeywordRules.isValid(keyword) else {
                throw LibraryValidationError(
                    "Use a 2–32 character keyword without spaces, quotes or brackets, such as ;email.")
            }
            guard !others.contains(where: { $0.id != id && $0.keyword == keyword }) else {
                throw LibraryValidationError("Another snippet already uses this keyword.")
            }
        }
        // Old snippets keep their old meaning, so the new placeholder rules don't apply to them.
        if let issue = dynamicTemplate?.validationIssues.first(where: \.blocksExecution) {
            throw LibraryValidationError(issue.message)
        }
        try LibraryTags.validate(tags)
    }
}

/// Tags on snippets and quicklinks.
enum LibraryTags {
    static let maximumCount = 16
    static let maximumLength = 32

    /// Trimmed, non-empty and unique (ignoring case), in the order typed.
    static func normalized(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func validate(_ tags: [String]?) throws {
        guard let tags else { return }
        guard tags.count <= maximumCount,
            tags.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0.count <= maximumLength && !$0.contains(",") })
        else {
            throw LibraryValidationError("Use up to 16 tags of up to 32 characters each.")
        }
    }
}

extension Snippet {
    private enum CodingKeys: String, CodingKey {
        case id, name, keyword, content, expandsKeyword, tags, placeholderVersion
    }

    /// Snippets without a placeholder version were written before dynamic placeholders.
    /// They keep their text and their old behavior (version 1); nothing is rewritten,
    /// so nothing can grow past a limit or change meaning.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        keyword = try container.decode(String.self, forKey: .keyword)
        let content = try container.decode(String.self, forKey: .content)
        expandsKeyword = try container.decodeIfPresent(Bool.self, forKey: .expandsKeyword)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        self.content = content
        placeholderVersion = try container.decodeIfPresent(Int.self, forKey: .placeholderVersion) ?? 1
    }
}
