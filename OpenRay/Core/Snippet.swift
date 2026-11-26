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
    /// The placeholder syntax `content` is written in. Snippets saved before dynamic
    /// placeholders had none; decoding migrates them (see `init(from:)`).
    var placeholderVersion = Snippet.currentPlaceholderVersion

    /// The longest snippet text, as in the public reference.
    static let maximumLength = 65_000
    /// Version 2: the dynamic placeholder engine.
    static let currentPlaceholderVersion = 2

    var expandsAsYouType: Bool { expandsKeyword ?? true }
    var tagList: [String] { tags ?? [] }

    var template: PlaceholderTemplate { PlaceholderTemplate(content, context: .snippet) }

    /// Content written for OpenRay before 2.x filled in only exact `{date}` and `{time}`.
    /// Every other placeholder in it is escaped, so it still shows as written, and
    /// a library with, say, four literal `{argument}` tokens still loads.
    static func migratingLegacyContent(_ content: String) -> String {
        PlaceholderParser.escaping(content, context: .snippet) { $0.source == "{date}" || $0.source == "{time}" }
    }

    /// The text with what needs nothing from the library filled in: dates, times,
    /// UUIDs and argument defaults. `{clipboard}` and other inputs render empty;
    /// the launcher renders with `LauncherModel.renderSnippet(_:)` instead.
    func expanded(at date: Date = .now, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
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
        if let issue = template.validationIssues.first(where: \.blocksExecution) {
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
    /// Their content is migrated once, in memory, and saved as version 2 with the next save.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        keyword = try container.decode(String.self, forKey: .keyword)
        let content = try container.decode(String.self, forKey: .content)
        expandsKeyword = try container.decodeIfPresent(Bool.self, forKey: .expandsKeyword)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        let version = try container.decodeIfPresent(Int.self, forKey: .placeholderVersion) ?? 1
        self.content = version < Self.currentPlaceholderVersion ? Self.migratingLegacyContent(content) : content
        placeholderVersion = max(version, Self.currentPlaceholderVersion)
    }
}
