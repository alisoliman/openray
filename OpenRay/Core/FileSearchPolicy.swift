import Foundation

/// How Files orders what it finds. Relevance ranks by how well the name matches.
enum FileSortOrder: String, CaseIterable, Codable, Identifiable, Sendable {
    case relevance, dateModified, name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance: "Relevance"
        case .dateModified: "Date Modified"
        case .name: "Name"
        }
    }

    /// The next order in the ⇧⌘P cycle.
    var next: FileSortOrder {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// What Settings › Files chose. Pure values, so the policy and the parsers can be tested
/// without Spotlight or a home folder.
struct FileSearchOptions: Equatable, Sendable {
    /// Dotfiles and hidden folders, except `.git` and `.Trash`, which stay out.
    var includesHiddenFiles = false
    /// Honors `.gitignore`, `.ignore` and `.openrayignore` files in the searched folders.
    var usesIgnoreFiles = true
    /// Global patterns in gitignore syntax. They match at any depth unless they start with `/`.
    var ignorePatterns: [String] = []
    /// Folders and files left out with “Exclude from Search”, as absolute paths.
    var excludedPaths: [String] = []
    /// Extra folders searched alongside Home, such as an external drive or iCloud Drive.
    var extraScopes: [URL] = []
    /// Matches file contents through Spotlight as well as names.
    var matchesContent = false
    var sort: FileSortOrder = .relevance
}

enum FileSearchPolicy {
    /// Spotlight doesn't reliably honor kMDItemPath predicates. Always enforce
    /// scope on returned URLs as well, including hidden ancestors and app bundles.
    static func accepts(_ url: URL, home: URL) -> Bool {
        accepts(url, home: home, options: FileSearchOptions(), ignoreFiles: nil)
    }

    /// Whether a found file belongs in the results: inside Home or one of the extra scopes,
    /// outside private and noisy folders, and not excluded by a pattern or ignore file.
    /// `ignoreFiles` reads the ignore rules of one folder; nil skips ignore files.
    static func accepts(
        _ url: URL, home: URL, options: FileSearchOptions, ignoreFiles: IgnoreFileReading?
    ) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        guard let root = root(containing: path, home: home, options: options) else { return false }
        let rootPath = root.standardizedFileURL.path
        let relative = rootPath == "/" ? String(path.dropFirst()) : String(path.dropFirst(rootPath.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return false }
        // Your Library is private and noisy, unless a scope inside it was chosen on purpose.
        if rootPath == home.standardizedFileURL.path, components.first == "Library" { return false }
        let noisy = components.contains { component in
            component == "node_modules" || component == "DerivedData" || component.hasSuffix(".app")
                || component == ".git" || component == ".Trash"
                || (!options.includesHiddenFiles && component.hasPrefix("."))
        }
        guard !noisy else { return false }
        if options.excludedPaths.contains(where: { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) {
            return false
        }
        var rules: [IgnoreRuleSet] = []
        let global = options.ignorePatterns.compactMap { IgnorePattern(line: $0, global: true) }
        if !global.isEmpty { rules.append(IgnoreRuleSet(base: [], patterns: global)) }
        if options.usesIgnoreFiles, let ignoreFiles {
            // Every folder from the root down to the file's own folder can hold rules.
            var folder = root.standardizedFileURL
            for depth in 0..<components.count {
                let patterns = ignoreFiles.patterns(inFolder: folder)
                if !patterns.isEmpty {
                    rules.append(IgnoreRuleSet(base: Array(components.prefix(depth)), patterns: patterns))
                }
                folder.append(path: components[depth], directoryHint: .isDirectory)
            }
        }
        guard !rules.isEmpty else { return true }
        return !IgnoreRuleSet.isIgnored(components, isDirectory: url.hasDirectoryPath, by: rules)
    }

    /// The scope a path belongs to. A chosen scope wins over Home, so a scope inside
    /// `~/Library` (such as iCloud Drive) isn't hidden by the Library rule.
    static func root(containing path: String, home: URL, options: FileSearchOptions) -> URL? {
        func contains(_ root: URL) -> Bool {
            let rootPath = root.standardizedFileURL.path
            return rootPath == "/" ? path != "/" : path.hasPrefix(rootPath + "/")
        }
        let scopes = options.extraScopes.filter(contains).sorted { $0.path.count > $1.path.count }
        if let scope = scopes.first { return scope }
        return contains(home) ? home : nil
    }

    /// The folders a Home search covers: Home, then the extra scopes outside it. Scopes inside
    /// Home are already covered; the Library rule is lifted for them by the predicate and `root`.
    static func searchRoots(home: URL, options: FileSearchOptions) -> [URL] {
        var roots = [home]
        let homePath = home.standardizedFileURL.path
        for scope in options.extraScopes {
            let path = scope.standardizedFileURL.path
            let insideHome = path == homePath || path.hasPrefix(homePath + "/")
            if !insideHome, !roots.contains(where: { $0.standardizedFileURL.path == path }) { roots.append(scope) }
        }
        return roots
    }
}

// MARK: - Ignore patterns

/// Reads the ignore rules one folder declares. The live reader caches each folder for one pass.
protocol IgnoreFileReading {
    func patterns(inFolder folder: URL) -> [IgnorePattern]
}

/// Reads `.gitignore`, `.ignore` and `.openrayignore` (and `.rayignore`, for people who keep
/// those already) from disk, once per folder per search.
final class IgnoreFileReader: IgnoreFileReading {
    static let fileNames = [".gitignore", ".ignore", ".openrayignore", ".rayignore"]
    /// Bigger files are skipped rather than read on every search.
    static let maximumBytes = 256_000
    private var cache: [String: [IgnorePattern]] = [:]

    init() {}

    func patterns(inFolder folder: URL) -> [IgnorePattern] {
        if let cached = cache[folder.path] { return cached }
        var patterns: [IgnorePattern] = []
        for name in Self.fileNames {
            let file = folder.appending(path: name, directoryHint: .notDirectory)
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maximumBytes,
                let text = try? String(contentsOf: file, encoding: .utf8)
            else { continue }
            patterns += IgnorePattern.parse(text)
        }
        cache[folder.path] = patterns
        return patterns
    }
}

/// One line of an ignore file, with gitignore semantics: `*`, `?`, `[…]` and `**`, a
/// trailing `/` for folders only, a leading `!` to include again, and a `/` at the start
/// or in the middle to anchor the pattern to its folder.
struct IgnorePattern: Equatable, Sendable {
    var components: [String]
    var negated: Bool
    var directoryOnly: Bool
    /// Anchored patterns match the path from the rules' folder; others match any one name.
    var anchored: Bool

    /// Nil for blank lines and comments. `global` patterns (from Settings) match at any
    /// depth unless they start with `/`, even when they contain a slash, as `build/**` does.
    init?(line: String, global: Bool = false) {
        var text = line
        // Trailing spaces are ignored unless escaped.
        while text.hasSuffix(" "), !text.hasSuffix("\\ ") { text.removeLast() }
        text = text.trimmingCharacters(in: .newlines)
        if global { text = text.trimmingCharacters(in: .whitespaces) }
        guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
        negated = text.hasPrefix("!")
        if negated { text.removeFirst() }
        if text.hasPrefix("\\#") || text.hasPrefix("\\!") { text.removeFirst() }
        directoryOnly = text.hasSuffix("/")
        while text.hasSuffix("/") { text.removeLast() }
        let leadingSlash = text.hasPrefix("/")
        while text.hasPrefix("/") { text.removeFirst() }
        guard !text.isEmpty else { return nil }
        var parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if global && !leadingSlash {
            anchored = parts.count > 1
            if anchored, parts.first != "**" { parts.insert("**", at: 0) }
        } else {
            anchored = leadingSlash || parts.count > 1
        }
        components = parts
    }

    static func parse(_ text: String) -> [IgnorePattern] {
        text.split(whereSeparator: \.isNewline).compactMap { IgnorePattern(line: String($0)) }
    }

    /// Whether the pattern matches a path, given as names relative to the rules' folder.
    func matches(_ path: [String], isDirectory: Bool) -> Bool {
        guard let last = path.last else { return false }
        if directoryOnly && !isDirectory { return false }
        guard anchored else { return components.count == 1 && Glob.matches(components[0], last) }
        return Self.match(components[...], path[...])
    }

    private static func match(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard let head = pattern.first else { return path.isEmpty }
        if head == "**" {
            let rest = pattern.dropFirst()
            // `**` takes zero or more names.
            var remaining = path
            while true {
                if match(rest, remaining) { return true }
                guard !remaining.isEmpty else { return false }
                remaining = remaining.dropFirst()
            }
        }
        guard let name = path.first, Glob.matches(head, name) else { return false }
        return match(pattern.dropFirst(), path.dropFirst())
    }
}

/// The rules of one folder: patterns that apply to paths below `base`.
struct IgnoreRuleSet: Equatable, Sendable {
    /// The folder's names relative to the search root.
    var base: [String]
    var patterns: [IgnorePattern]

    /// Gitignore's rule: the last matching pattern decides, and nothing inside an ignored
    /// folder can be included again. Each ancestor is checked before the path itself.
    static func isIgnored(_ path: [String], isDirectory: Bool, by sets: [IgnoreRuleSet]) -> Bool {
        guard !path.isEmpty else { return false }
        for length in 1...path.count {
            let prefix = Array(path.prefix(length))
            let directory = length < path.count || isDirectory
            var ignored = false
            for set in sets where set.base.count < length && Array(prefix.prefix(set.base.count)) == set.base {
                let relative = Array(prefix.dropFirst(set.base.count))
                for pattern in set.patterns where pattern.matches(relative, isDirectory: directory) {
                    ignored = !pattern.negated
                }
            }
            if ignored { return true }
        }
        return false
    }
}

/// Shell-style matching of one file name: `*`, `?`, `[abc]`, `[a-z]`, `[!x]` and `\` escapes.
/// A `*` never crosses a `/`, since names never contain one.
enum Glob {
    static func matches(_ pattern: String, _ name: String) -> Bool {
        match(Array(pattern), 0, Array(name), 0)
    }

    private static func match(_ pattern: [Character], _ p: Int, _ name: [Character], _ n: Int) -> Bool {
        var p = p
        var n = n
        while p < pattern.count {
            switch pattern[p] {
            case "*":
                // Collapse runs of stars, then try every split.
                while p < pattern.count, pattern[p] == "*" { p += 1 }
                if p == pattern.count { return true }
                for start in n...name.count where match(pattern, p, name, start) { return true }
                return false
            case "?":
                guard n < name.count else { return false }
                p += 1
                n += 1
            case "[":
                guard n < name.count, let (matched, next) = bracket(pattern, p, name[n]) else {
                    // An unclosed bracket is a literal “[”.
                    guard n < name.count, name[n] == "[" else { return false }
                    p += 1
                    n += 1
                    continue
                }
                guard matched else { return false }
                p = next
                n += 1
            case "\\" where p + 1 < pattern.count:
                guard n < name.count, name[n] == pattern[p + 1] else { return false }
                p += 2
                n += 1
            default:
                guard n < name.count, name[n] == pattern[p] else { return false }
                p += 1
                n += 1
            }
        }
        return n == name.count
    }

    /// Matches one character against `[…]` at `start`. Nil when the bracket never closes.
    private static func bracket(_ pattern: [Character], _ start: Int, _ character: Character) -> (Bool, Int)? {
        var index = start + 1
        var negate = false
        if index < pattern.count, pattern[index] == "!" || pattern[index] == "^" {
            negate = true
            index += 1
        }
        var matched = false
        var first = true
        while index < pattern.count {
            let current = pattern[index]
            if current == "]" && !first { return (matched != negate, index + 1) }
            first = false
            if index + 2 < pattern.count, pattern[index + 1] == "-", pattern[index + 2] != "]" {
                if pattern[index] <= character && character <= pattern[index + 2] { matched = true }
                index += 3
            } else {
                if current == character { matched = true }
                index += 1
            }
        }
        return nil
    }
}

// MARK: - Queries

/// A Files search split into name terms and filters: `report content:"net revenue"`.
/// `content:` matches the text inside files through Spotlight; everything else matches names.
struct FileQuery: Equatable, Sendable {
    var nameTerms: [String] = []
    var contentTerms: [String] = []

    /// True when the search asks for contents, so only Files answers it.
    var hasFilters: Bool { !contentTerms.isEmpty }
    var nameText: String { nameTerms.joined(separator: " ") }
    var isEmpty: Bool { nameTerms.isEmpty && contentTerms.isEmpty }

    static func parse(_ text: String) -> FileQuery {
        var query = FileQuery()
        for token in QueryTokenizer.tokens(text) {
            if let value = token.value(for: "content") {
                if !value.isEmpty { query.contentTerms.append(value) }
            } else if !token.text.isEmpty {
                query.nameTerms.append(token.text)
            }
        }
        return query
    }
}

/// Splits a query into words, keeping `key:"quoted words"` and `"quoted words"` together.
enum QueryTokenizer {
    struct Token: Equatable, Sendable {
        var key: String?
        var text: String

        /// The value when this is `key:value`, lowercased key.
        func value(for name: String) -> String? { key == name ? text : nil }
    }

    /// `keys` limits which prefixes count as filters; other `a:b` words stay plain text.
    static func tokens(_ text: String, keys: Set<String> = ["content", "text", "name", "date"]) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var quoted = false
        func flush() {
            defer { current = "" }
            guard !current.isEmpty else { return }
            if let colon = current.firstIndex(of: ":") {
                let key = current[..<colon].lowercased()
                if keys.contains(key) {
                    let value = String(current[current.index(after: colon)...])
                    tokens.append(Token(key: key, text: unquoted(value)))
                    return
                }
            }
            tokens.append(Token(key: nil, text: unquoted(current)))
        }
        for character in text {
            if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character.isWhitespace && !quoted {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return tokens
    }

    private static func unquoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
    }
}

/// A typed path: `~/Documents/rep` lists `~/Documents` and filters it by “rep”.
/// Typing `~/` or `/` in Everything or Files browses folders; Tab enters one, ⇧Tab goes up.
struct FilePathQuery: Equatable, Sendable {
    /// The folder to list.
    var directory: URL
    /// The partial name after the last slash.
    var filter: String

    /// Nil unless the text starts with `~/` or `/`.
    static func parse(_ text: String, home: URL) -> FilePathQuery? {
        guard text.hasPrefix("~/") || text.hasPrefix("/"), !text.contains("\n") else { return nil }
        let expanded = text.hasPrefix("~/") ? home.standardizedFileURL.path + "/" + text.dropFirst(2) : text
        guard let slash = expanded.lastIndex(of: "/") else { return nil }
        let folder = String(expanded[...slash])
        let filter = String(expanded[expanded.index(after: slash)...])
        let directory = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
        return FilePathQuery(directory: directory, filter: filter)
    }

    /// What to type to list a folder: `~/Documents/`, or `/Volumes/` outside Home.
    static func text(for directory: URL, home: URL) -> String {
        let path = directory.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~/" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) + "/" }
        return path == "/" ? "/" : path + "/"
    }

    /// The text that lists this folder with no filter.
    func folderText(home: URL) -> String { Self.text(for: directory, home: home) }

    /// ⇧Tab: the enclosing folder's listing. Nil at `/`.
    func parentText(home: URL) -> String? {
        let path = directory.standardizedFileURL.path
        guard path != "/" else { return nil }
        return Self.text(for: directory.deletingLastPathComponent(), home: home)
    }

    /// Tab on a row: a folder opens its listing; a file completes its name.
    static func completion(for url: URL, isFolder: Bool, home: URL) -> String {
        if isFolder { return text(for: url, home: home) }
        return text(for: url.deletingLastPathComponent(), home: home) + url.lastPathComponent
    }

    /// Orders a listing: matches for the filter first when ranking by relevance, folders
    /// before files when the filter is empty.
    static func ordered(
        _ entries: [FileSearchResult], filter: String, sort: FileSortOrder
    ) -> [FileSearchResult] {
        let filter = filter.trimmingCharacters(in: .whitespaces)
        var scored: [(FileSearchResult, Int)] = entries.compactMap { entry in
            guard !filter.isEmpty else { return (entry, 0) }
            return SearchMatcher.score(filter, in: entry.name).map { (entry, $0) }
        }
        scored.sort { lhs, rhs in
            switch sort {
            case .relevance:
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if filter.isEmpty, lhs.0.isDirectory != rhs.0.isDirectory { return lhs.0.isDirectory }
            case .dateModified:
                let left = lhs.0.modifiedAt ?? .distantPast
                let right = rhs.0.modifiedAt ?? .distantPast
                if left != right { return left > right }
            case .name: break
            }
            return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
        }
        return scored.map(\.0)
    }
}

// MARK: - Settings

/// Settings stored as small strings in `commandPreferences` under keys that are never command
/// ids, so they need no schema change: lists one per line, flags as "true"/"false".
enum PreferenceValues {
    static func list(_ value: String?) -> [String] {
        (value ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func string(_ list: [String]) -> String? {
        var seen = Set<String>()
        let unique = list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: "\n")
    }

    static func flag(_ value: String?, default fallback: Bool) -> Bool {
        switch value {
        case "true": true
        case "false": false
        default: fallback
        }
    }
}

/// Settings › Files, kept in `commandPreferences[FilesSettings.key]`.
struct FilesSettings: Equatable, Sendable {
    static let key = "settings.files"

    var includesHiddenFiles = false
    var usesIgnoreFiles = true
    /// Comma- or newline-separated globs, as typed.
    var ignorePatterns: [String] = []
    var excludedPaths: [String] = []
    var extraScopes: [String] = []
    var matchesContent = false
    var sort: FileSortOrder = .relevance
    /// The app “Open in Terminal” uses.
    var terminalBundleID = FilesSettings.defaultTerminal

    static let defaultTerminal = "com.apple.Terminal"

    init() {}

    init(_ values: [String: String]?) {
        let values = values ?? [:]
        includesHiddenFiles = PreferenceValues.flag(values["hidden"], default: false)
        usesIgnoreFiles = PreferenceValues.flag(values["ignoreFiles"], default: true)
        ignorePatterns = Self.patterns(values["patterns"] ?? "")
        excludedPaths = PreferenceValues.list(values["excluded"])
        extraScopes = PreferenceValues.list(values["scopes"])
        matchesContent = PreferenceValues.flag(values["content"], default: false)
        sort = values["sort"].flatMap(FileSortOrder.init(rawValue:)) ?? .relevance
        terminalBundleID = values["terminal"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultTerminal
    }

    /// What's stored. Defaults are left out, so an untouched setting stays absent.
    var values: [String: String] {
        var values: [String: String] = [:]
        if includesHiddenFiles { values["hidden"] = "true" }
        if !usesIgnoreFiles { values["ignoreFiles"] = "false" }
        values["patterns"] = PreferenceValues.string(ignorePatterns)
        values["excluded"] = PreferenceValues.string(excludedPaths)
        values["scopes"] = PreferenceValues.string(extraScopes)
        if matchesContent { values["content"] = "true" }
        if sort != .relevance { values["sort"] = sort.rawValue }
        if terminalBundleID != Self.defaultTerminal { values["terminal"] = terminalBundleID }
        return values
    }

    /// Splits typed patterns on commas and new lines.
    static func patterns(_ text: String) -> [String] {
        text.split { $0 == "," || $0.isNewline }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var options: FileSearchOptions {
        FileSearchOptions(
            includesHiddenFiles: includesHiddenFiles, usesIgnoreFiles: usesIgnoreFiles,
            ignorePatterns: ignorePatterns, excludedPaths: excludedPaths,
            extraScopes: extraScopes.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) },
            matchesContent: matchesContent, sort: sort)
    }
}

// MARK: - Safety helpers

/// Who a file is, beyond its path: the same device and inode, and for files the same size and
/// modification time. A prompt freezes it, and approval checks it again, so a file replaced at
/// the same path after the person reviewed it is never the one acted on.
struct FileIdentity: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    var isDirectory: Bool
    var size: Int64
    var modified: TimeInterval

    /// The identity of what's at `url` now, without following a final symlink. Nil when nothing is.
    static func of(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        return FileIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino), isDirectory: isDirectory,
            size: Int64(info.st_size), modified: modified)
    }

    /// Whether `current` is the same item. A folder's own size and time change as its contents
    /// do, so folders compare by device and inode only.
    func isSameItem(as current: FileIdentity?) -> Bool {
        guard let current, current.device == device, current.inode == inode, current.isDirectory == isDirectory
        else { return false }
        return isDirectory || (current.size == size && current.modified == modified)
    }
}

/// While inert (tests and isolated verification), live readers may open only fixtures under
/// the temporary folder, so a verification run never lists or reads the person's real files.
enum InertReadBoundary {
    static func allows(_ url: URL, sideEffects: SideEffectGuard = .current) -> Bool {
        // An injected live rule never widens what an inert process may read.
        guard SideEffectGuard.atLeastCurrent(sideEffects).isInert else { return true }
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == temporary || path.hasPrefix(temporary + "/")
    }

    static func check(_ url: URL, sideEffects: SideEffectGuard = .current) throws {
        guard allows(url, sideEffects: sideEffects) else {
            throw SideEffectGuard.Blocked(
                what: "reading \(url.lastPathComponent)", mode: SideEffectGuard.atLeastCurrent(sideEffects).mode)
        }
    }
}

extension SideEffectGuard {
    /// A rule passed into a live adapter, never weaker than this process's own: an inert
    /// process stays inert even when a caller injects a live rule.
    static func atLeastCurrent(_ injected: SideEffectGuard) -> SideEffectGuard {
        injected.isInert || !current.isInert ? injected : current
    }
}
