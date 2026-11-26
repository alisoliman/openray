import Foundation

struct Quicklink: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var template: String
    var keyword: String
    /// The app the link opens in. Nil uses the default browser or app.
    var openWith: QuicklinkApplication? = nil
    /// Labels for search and filtering. Missing in libraries from before tags.
    var tags: [String]? = nil

    var linkTemplate: QuicklinkTemplate { QuicklinkTemplate(template) }
    var tagList: [String] { tags ?? [] }

    /// The arguments written in the link itself, in order: `{argument …}`
    /// placeholders and the legacy `{query}` and `{Name}`. Links that reference
    /// snippets can ask for more; use `plan(snippets:)` for every field.
    var placeholderArguments: [PlaceholderArgument] { linkTemplate.arguments }

    /// True when the link takes at least one typed value.
    var needsQuery: Bool { !placeholderArguments.isEmpty }

    /// One spec per argument written in the link. A `{query}` link keeps
    /// `[ArgumentSpec.query]`. `plan(snippets:).argumentSpecs` includes referenced snippets.
    var argumentSpecs: [ArgumentSpec] { placeholderArguments.map(\.argumentSpec) }

    /// The one plan for this link's fields, value conversion and rendering.
    func plan(snippets: (String) -> String?) -> PlaceholderPlan { linkTemplate.template.plan(snippets: snippets) }

    func argument(in input: String) -> String? {
        guard !keyword.isEmpty else { return nil }
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(
            maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first, String(first).caseInsensitiveCompare(keyword) == .orderedSame else { return nil }
        return parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// The URL for one typed term, which fills the only argument. Placeholders that
    /// read the clipboard or selection render empty.
    func resolvedURL(query: String = "") throws -> URL {
        try resolution(query: query, values: PlaceholderValues()).url
    }

    /// One typed term for the link's first argument, resolved like a form field: a
    /// blank term takes the default, a dropdown must get one of its options. Links
    /// with more than one field go through `resolution(arguments:values:)`.
    func resolution(query: String, values: PlaceholderValues) throws -> QuicklinkResolution {
        let plan = plan(snippets: values.snippetText(named:))
        guard let first = plan.arguments.first else { return try resolution(plan: plan, typed: [:], values: values) }
        return try resolution(plan: plan, typed: [first.id.specName: query], values: values)
    }

    /// Values by `ArgumentSpec.name`, as `ProvidedRef.arguments` carries them, for every
    /// field of the full plan, including arguments in referenced snippets.
    func resolution(arguments: [String: String], values: PlaceholderValues) throws -> QuicklinkResolution {
        try resolution(plan: plan(snippets: values.snippetText(named:)), typed: arguments, values: values)
    }

    private func resolution(plan: PlaceholderPlan, typed: [String: String], values: PlaceholderValues) throws
        -> QuicklinkResolution
    {
        var values = values
        do {
            values.arguments = try plan.resolveArguments(typed)
        } catch {
            // The legacy search term keeps its familiar sentence.
            if plan.arguments.count == 1, plan.arguments.first?.id == .named("query"),
                (typed["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                throw LibraryValidationError("Enter a search term for this quicklink.")
            }
            throw error
        }
        return try linkTemplate.resolve(plan: plan, values: values)
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryValidationError("Give this quicklink a name.")
        }
        guard keyword.count <= 32, !keyword.contains(where: \.isWhitespace) else {
            throw LibraryValidationError("Use a quicklink keyword of up to 32 characters without spaces.")
        }
        try linkTemplate.validate()
        try LibraryTags.validate(tags)
    }

    static let defaults = [
        Quicklink(name: "Search the Web", template: "https://duckduckgo.com/?q={query}", keyword: "web"),
        Quicklink(name: "Search GitHub", template: "https://github.com/search?q={query}", keyword: "gh"),
    ]
}
