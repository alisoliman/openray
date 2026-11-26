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

    /// The longest snippet text, as in the public reference.
    static let maximumLength = 65_000

    var expandsAsYouType: Bool { expandsKeyword ?? true }
    var tagList: [String] { tags ?? [] }

    var template: PlaceholderTemplate { PlaceholderTemplate(content, context: .snippet) }

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
