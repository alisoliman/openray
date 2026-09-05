import Foundation

enum LauncherSection: String, CaseIterable, Identifiable, Sendable {
    case home, applications, files, clipboard, snippets, quicklinks, notes, calculator, windows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Everything"
        case .applications: "Applications"
        case .files: "Files"
        case .clipboard: "Clipboard History"
        case .snippets: "Snippets"
        case .quicklinks: "Quicklinks"
        case .notes: "Notes"
        case .calculator: "Calculator & Conversions"
        case .windows: "Window Management"
        }
    }

    var symbol: String {
        switch self {
        case .home: "magnifyingglass"
        case .applications: "square.grid.2x2"
        case .files: "folder"
        case .clipboard: "clipboard"
        case .snippets: "text.quote"
        case .quicklinks: "link"
        case .notes: "note.text"
        case .calculator: "equal.square"
        case .windows: "rectangle.split.2x1"
        }
    }

    var placeholder: String {
        switch self {
        case .home: "Search apps and commands…"
        case .applications: "Search your applications…"
        case .files: "Search files and folders…"
        case .clipboard: "Search your clipboard history…"
        case .snippets: "Search snippets by name, keyword, or content…"
        case .quicklinks: "Search quicklinks…"
        case .notes: "Search your notes…"
        case .calculator: "Type a calculation or conversion…"
        case .windows: "Search window commands…"
        }
    }
}

enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum LauncherHotKey: String, Codable, CaseIterable, Identifiable, Sendable {
    case optionSpace, controlSpace, controlOptionSpace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlSpace: "⌃ Space"
        case .controlOptionSpace: "⌃ ⌥ Space"
        }
    }
}

struct AppPreferences: Codable, Equatable, Sendable {
    var appearance: AppAppearance = .dark
    var hotKey: LauncherHotKey = .optionSpace
    var clipboardEnabled = false
    // Missing fields in a version-1 library mean media capture was never approved.
    var clipboardImagesEnabled: Bool? = true
    var clipboardFilesEnabled: Bool? = true
    var clipboardRetentionDays = 7
    var clipboardLimit = 100
    var snippetExpansionEnabled = false
    var excludedClipboardBundleIDs = [
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.apple.Passwords", "org.keepassxc.keepassxc",
    ]

    var capturesClipboardImages: Bool { clipboardImagesEnabled ?? false }
    var capturesClipboardFiles: Bool { clipboardFilesEnabled ?? false }
}

struct Quicklink: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var template: String
    var keyword: String

    var needsQuery: Bool { template.contains("{query}") }

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
            throw LibraryValidationError("Use an http(s) URL, mailto link, or an absolute file path.")
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

struct Snippet: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var keyword: String
    var content: String

    func expanded(at date: Date = .now, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = timeZone
        dateFormatter.dateStyle = .medium
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.timeZone = timeZone
        timeFormatter.timeStyle = .short
        return
            content
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: date))
    }

    func validate(against others: [Snippet]) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryValidationError("Give this snippet a name.")
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.count <= 32_000 else {
            throw LibraryValidationError("Snippet text must contain between 1 and 32,000 characters.")
        }
        if !keyword.isEmpty {
            let allowed = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789;:/._-")
            guard (2...32).contains(keyword.count), keyword.unicodeScalars.allSatisfy(allowed.contains) else {
                throw LibraryValidationError("Use a 2–32 character keyword without spaces, such as ;email.")
            }
            guard !others.contains(where: { $0.id != id && $0.keyword == keyword }) else {
                throw LibraryValidationError("Another snippet already uses this keyword.")
            }
        }
    }
}

struct QuickNote: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var content: String
    var modifiedAt: Date = .now
}

struct UsageRecord: Codable, Equatable, Sendable {
    var id: String
    var count: Int = 1
    var lastUsed: Date = .now
}

struct LibraryDatabase: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    var schemaVersion = LibraryDatabase.currentSchemaVersion
    var preferences = AppPreferences()
    var quicklinks = Quicklink.defaults
    var snippets: [Snippet] = []
    var notes: [QuickNote] = []
    var clipboard: [ClipboardEntry] = []
    var favoriteIDs: Set<String> = ["section.clipboard", "ai.chat", "section.notes"]
    var usage: [UsageRecord] = []

    func validate() throws {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw LibraryValidationError("This library requires a newer version of OpenRay.")
        }
        let identities = [
            quicklinks.map { $0.id.uuidString }, snippets.map { $0.id.uuidString },
            notes.map { $0.id.uuidString }, clipboard.map { $0.id.uuidString }, usage.map(\.id),
        ]
        guard identities.allSatisfy({ Set($0).count == $0.count }) else {
            throw LibraryValidationError("The library contains duplicate item identifiers.")
        }
        guard (1...500).contains(preferences.clipboardLimit), (1...365).contains(preferences.clipboardRetentionDays),
            usage.allSatisfy({ (1...10_000).contains($0.count) })
        else {
            throw LibraryValidationError("The library contains invalid history limits or usage records.")
        }
        for link in quicklinks { try link.validate() }
        for snippet in snippets { try snippet.validate(against: snippets) }
        guard clipboard.allSatisfy(\.isValid) else {
            throw LibraryValidationError("The library contains invalid clipboard content.")
        }
    }
}

struct LibraryValidationError: LocalizedError, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
