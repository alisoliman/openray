import Foundation

struct Quicklink: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var template: String
    var keyword: String

    var needsQuery: Bool { template.contains("{query}") }

    /// The arguments this link asks for: today only `{query}`. Its value goes through
    /// `resolvedURL(query:)`, which is still the path the launcher uses.
    var argumentSpecs: [ArgumentSpec] { needsQuery ? [.query] : [] }

    func argument(in input: String) -> String? {
        guard !keyword.isEmpty else { return nil }
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(
            maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first, String(first).caseInsensitiveCompare(keyword) == .orderedSame else { return nil }
        return parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    func resolvedURL(query: String = "") throws -> URL {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryValidationError("Enter a URL or an absolute file path.") }
        if needsQuery && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LibraryValidationError("Enter a search term for this quicklink.")
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            guard !needsQuery else {
                throw LibraryValidationError("Query placeholders are only supported in web links.")
            }
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        // Only RFC 3986 unreserved characters may remain unescaped inside a query.
        let unreserved = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        let substituted = trimmed.replacingOccurrences(of: "{query}", with: encoded)
        guard let url = URL(string: substituted),
            let scheme = url.scheme?.lowercased(),
            ["https", "http", "file", "mailto"].contains(scheme),
            !["http", "https"].contains(scheme) || url.host?.isEmpty == false
        else {
            throw LibraryValidationError("Use an http(s) URL, a mailto link or an absolute file path.")
        }
        return url
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryValidationError("Give this quicklink a name.")
        }
        guard keyword.count <= 32, !keyword.contains(where: \.isWhitespace) else {
            throw LibraryValidationError("Use a quicklink keyword of up to 32 characters without spaces.")
        }
        _ = try resolvedURL(query: needsQuery ? "test" : "")
        let withoutPlaceholder = template.replacingOccurrences(of: "{query}", with: "")
        guard !withoutPlaceholder.contains("{") && !withoutPlaceholder.contains("}") else {
            throw LibraryValidationError("The supported placeholder is {query}.")
        }
    }

    static let defaults = [
        Quicklink(name: "Search the Web", template: "https://duckduckgo.com/?q={query}", keyword: "web"),
        Quicklink(name: "Search GitHub", template: "https://github.com/search?q={query}", keyword: "gh"),
    ]
}
