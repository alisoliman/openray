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

    /// The arguments the link asks for, in order: `{argument …}` placeholders, plus
    /// the legacy `{query}` and `{Name}` forms.
    var placeholderArguments: [PlaceholderArgument] { linkTemplate.arguments }

    /// True when the link takes at least one typed value.
    var needsQuery: Bool { !placeholderArguments.isEmpty }

    /// One spec per argument, named by `PlaceholderArgument.ID.specName`. A `{query}`
    /// link keeps `[ArgumentSpec.query]`.
    var argumentSpecs: [ArgumentSpec] { placeholderArguments.map(\.argumentSpec) }

    /// The argument a single typed term fills: the first one.
    var primaryArgument: PlaceholderArgument? { placeholderArguments.first }

    /// More than one argument needs a value, so the one-term path can't open it on
    /// its own; it needs every field (`resolution(arguments:values:)`).
    var needsSeveralValues: Bool { placeholderArguments.filter(\.isRequired).count > 1 }

    func argument(in input: String) -> String? {
        guard !keyword.isEmpty else { return nil }
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(
            maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first, String(first).caseInsensitiveCompare(keyword) == .orderedSame else { return nil }
        return parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// The URL for one typed term, which fills the first argument; other arguments
    /// use their defaults. Placeholders that read the clipboard or selection render empty.
    func resolvedURL(query: String = "") throws -> URL {
        try resolution(query: query, values: PlaceholderValues()).url
    }

    /// One typed term for the first argument, with the rest of the values from `values`.
    func resolution(query: String, values: PlaceholderValues) throws -> QuicklinkResolution {
        guard let primary = primaryArgument else { return try resolution(arguments: [:], values: values) }
        return try resolution(arguments: [primary.id.specName: query], values: values)
    }

    /// Values by `ArgumentSpec.name`, as `ProvidedRef.arguments` carries them.
    func resolution(arguments: [String: String], values: PlaceholderValues) throws -> QuicklinkResolution {
        var values = values
        for argument in placeholderArguments {
            if let value = arguments[argument.id.specName] { values.arguments[argument.id] = value }
        }
        return try linkTemplate.resolve(using: values)
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
