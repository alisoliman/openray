import Foundation

// Import and export of snippets and quicklinks as plain data.
//
// Formats and sources:
// - Snippet JSON, as documented at https://manual.raycast.com/snippets: an array
//   of objects with `name` and `text` (required) and `keyword` (optional). A
//   single object is accepted too.
// - Quicklink JSON, as documented at https://manual.raycast.com/quicklinks: an
//   array of objects with `name` and `link` (required) and `iconName` and
//   `openWith` (optional). `openWith` is an app name such as "Finder" or a
//   bundle identifier.
// - macOS Text Replacements: Apple's "Back up and share text replacements"
//   guide (support.apple.com/guide/mac-help/mchl2a7bd795) says dragging
//   replacements from the Text Replacements window to the desktop creates
//   "property list.plist". The guide doesn't list its keys; this reader expects
//   an array of dictionaries with the string keys `phrase` (the replacement)
//   and `shortcut` (what you type), XML or binary.
//
// Encrypted `.rayconfig` archives are refused and never parsed.

/// A snippet read from a file, before it becomes a `Snippet`.
struct ImportedSnippet: Codable, Equatable, Sendable {
    var name: String
    var text: String
    var keyword: String?

    init(name: String, text: String, keyword: String? = nil) {
        self.name = name
        self.text = text
        self.keyword = keyword?.isEmpty == true ? nil : keyword
    }

    init(_ snippet: Snippet) {
        self.init(name: snippet.name, text: snippet.content, keyword: snippet.keyword)
    }
}

/// A quicklink read from a file, before it becomes a `Quicklink`.
struct ImportedQuicklink: Codable, Equatable, Sendable {
    var name: String
    var link: String
    var iconName: String?
    var openWith: String?

    init(name: String, link: String, iconName: String? = nil, openWith: String? = nil) {
        self.name = name
        self.link = link
        self.iconName = iconName?.isEmpty == true ? nil : iconName
        self.openWith = openWith?.isEmpty == true ? nil : openWith
    }

    /// Exports write `{argument name="query"}` rather than OpenRay's older `{query}`.
    init(_ quicklink: Quicklink, openWith: String? = nil) {
        self.init(name: quicklink.name, link: QuicklinkTemplate(quicklink.template).modernizedLink, openWith: openWith)
    }
}

enum LibraryImportError: LocalizedError, Equatable {
    case encryptedArchive
    case fileTooLarge
    case unreadable
    case noEntries

    var errorDescription: String? {
        switch self {
        case .encryptedArchive:
            "Encrypted settings archives can't be imported. Export snippets or quicklinks as JSON instead."
        case .fileTooLarge: "This file is too large to import."
        case .unreadable: "This file isn't a snippet or quicklink export OpenRay can read."
        case .noEntries: "This file doesn't contain any snippets or quicklinks."
        }
    }
}

/// Entries read from a file. Entries missing a required field are counted, not imported.
struct LibraryImportFile<Item: Equatable & Sendable>: Equatable, Sendable {
    var items: [Item]
    var invalidCount: Int
}

enum LibraryImport {
    static let maximumBytes = 10_000_000
    static let maximumItems = 10_000

    /// Refuses files OpenRay must not read, by name. Call before reading the file.
    static func checkFileName(_ name: String) throws {
        if (name as NSString).pathExtension.lowercased() == "rayconfig" { throw LibraryImportError.encryptedArchive }
    }

    // MARK: Snippets

    /// Reads snippet JSON or a Text Replacements property list, whichever `data` is.
    static func snippets(from data: Data, fileName: String? = nil) throws -> LibraryImportFile<ImportedSnippet> {
        if let fileName { try checkFileName(fileName) }
        return isPropertyList(data) ? try textReplacements(from: data) : try snippetJSON(from: data)
    }

    static func snippetJSON(from data: Data) throws -> LibraryImportFile<ImportedSnippet> {
        try parse(objects: jsonObjects(data)) { object in
            guard let name = string(object["name"]), let text = object["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return ImportedSnippet(name: name, text: text, keyword: string(object["keyword"]))
        }
    }

    static func textReplacements(from data: Data) throws -> LibraryImportFile<ImportedSnippet> {
        try checkSize(data)
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            throw LibraryImportError.unreadable
        }
        let objects: [Any]
        if let array = list as? [Any] {
            objects = array
        } else if let dictionary = list as? [String: Any] {
            objects = [dictionary]
        } else {
            throw LibraryImportError.unreadable
        }
        return try parse(objects: objects) { object in
            guard let phrase = object["phrase"] as? String,
                !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let shortcut = string(object["shortcut"])
            return ImportedSnippet(name: Self.name(for: phrase), text: phrase, keyword: shortcut)
        }
    }

    /// Pretty-printed JSON with keys in a stable order.
    static func exportSnippets(_ snippets: [ImportedSnippet]) throws -> Data {
        try encoder.encode(snippets)
    }

    /// A Text Replacements property list (`phrase`, `shortcut`), in the format
    /// `textReplacements(from:)` reads. A replacement needs a shortcut, so
    /// snippets without a keyword are left out.
    static func exportTextReplacements(_ snippets: [ImportedSnippet]) throws -> Data {
        let entries = snippets.compactMap { snippet in
            snippet.keyword.map { ["phrase": snippet.text, "shortcut": $0] }
        }
        return try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
    }

    // MARK: Quicklinks

    static func quicklinks(from data: Data, fileName: String? = nil) throws -> LibraryImportFile<ImportedQuicklink> {
        if let fileName { try checkFileName(fileName) }
        return try parse(objects: jsonObjects(data)) { object in
            guard let name = string(object["name"]), let link = string(object["link"]) else { return nil }
            return ImportedQuicklink(
                name: name, link: link, iconName: string(object["iconName"]), openWith: string(object["openWith"]))
        }
    }

    static func exportQuicklinks(_ quicklinks: [ImportedQuicklink]) throws -> Data {
        try encoder.encode(quicklinks)
    }

    // MARK: Parsing helpers

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func checkSize(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw LibraryImportError.fileTooLarge }
    }

    private static func isPropertyList(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return data.starts(with: Data("bplist".utf8)) || head.hasPrefix("<?xml") || head.hasPrefix("<plist")
            || head.hasPrefix("<!DOCTYPE plist")
    }

    private static func jsonObjects(_ data: Data) throws -> [Any] {
        try checkSize(data)
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw LibraryImportError.unreadable }
        if let array = json as? [Any] { return array }
        if let object = json as? [String: Any] { return [object] }
        throw LibraryImportError.unreadable
    }

    private static func parse<Item>(objects: [Any], _ make: ([String: Any]) -> Item?) throws -> LibraryImportFile<Item> {
        guard !objects.isEmpty else { throw LibraryImportError.noEntries }
        var items: [Item] = []
        var invalid = 0
        for object in objects.prefix(maximumItems) {
            if let dictionary = object as? [String: Any], let item = make(dictionary) {
                items.append(item)
            } else {
                invalid += 1
            }
        }
        invalid += max(0, objects.count - maximumItems)
        guard !items.isEmpty || invalid > 0 else { throw LibraryImportError.noEntries }
        return LibraryImportFile(items: items, invalidCount: invalid)
    }

    /// A trimmed, non-empty string, or nil.
    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    /// A Text Replacement has no name, so its first line stands in.
    static func name(for phrase: String) -> String {
        let line = phrase.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let trimmed = (line.map(String.init) ?? phrase).trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed
    }
}

// MARK: - Conflicts

/// What to do when an imported snippet's keyword is already taken.
enum ImportKeywordConflictPolicy: String, CaseIterable, Sendable {
    /// Import it without the keyword; the existing snippet keeps it.
    case dropKeyword
    /// Leave the imported snippet out.
    case skip
    /// Merge: replace the name and text of the snippet that holds the keyword.
    case replaceExisting
}

struct SnippetImportPlan: Equatable, Sendable {
    struct Replacement: Equatable, Sendable {
        var existingID: UUID
        var snippet: ImportedSnippet
    }

    /// New snippets, with keywords removed where they conflicted or were invalid.
    var additions: [ImportedSnippet] = []
    var replacements: [Replacement] = []
    /// Identical to a snippet already in the library or earlier in the file.
    var duplicates: [ImportedSnippet] = []
    /// Snippets whose keyword was already taken, as they appeared in the file.
    var keywordConflicts: [ImportedSnippet] = []
    /// Conflicting snippets left out under the `skip` policy.
    var skippedConflicts: [ImportedSnippet] = []
    /// Snippets imported without their keyword: conflicting or not a valid keyword.
    var keywordsDropped: [ImportedSnippet] = []
    /// Empty or too long.
    var invalid: [ImportedSnippet] = []

    var skippedCount: Int { duplicates.count + invalid.count + skippedConflicts.count }

    var summary: String {
        var parts = ["\(additions.count) added"]
        if !replacements.isEmpty { parts.append("\(replacements.count) updated") }
        if skippedCount > 0 { parts.append("\(skippedCount) skipped") }
        if !keywordsDropped.isEmpty { parts.append("\(keywordsDropped.count) without keyword") }
        return parts.joined(separator: ", ")
    }
}

struct QuicklinkImportPlan: Equatable, Sendable {
    var additions: [ImportedQuicklink] = []
    /// Same name and link as a quicklink already in the library or earlier in the file.
    var duplicates: [ImportedQuicklink] = []
    /// Links OpenRay can't open, such as `javascript:` URLs.
    var invalid: [ImportedQuicklink] = []

    var summary: String {
        var parts = ["\(additions.count) added"]
        if !duplicates.isEmpty { parts.append("\(duplicates.count) duplicates skipped") }
        if !invalid.isEmpty { parts.append("\(invalid.count) invalid skipped") }
        return parts.joined(separator: ", ")
    }
}

extension LibraryImport {
    /// Decides what happens to each imported snippet. Keywords match exactly, as
    /// expansion does. Duplicates are found after a keyword is dropped, so the
    /// same conflicting snippet imported twice, in one file or in two imports,
    /// is added once.
    static func plan(
        snippets incoming: [ImportedSnippet], existing: [Snippet],
        policy: ImportKeywordConflictPolicy = .dropKeyword, maximumTextLength: Int = 32_000,
        isValidKeyword: (String) -> Bool = SnippetKeywordRules.isValid
    ) -> SnippetImportPlan {
        var plan = SnippetImportPlan()
        func same(_ a: ImportedSnippet, _ b: ImportedSnippet) -> Bool {
            a.name == b.name && a.text == b.text && (a.keyword ?? "") == (b.keyword ?? "")
        }
        let library = existing.map(ImportedSnippet.init)
        func isDuplicate(_ candidate: ImportedSnippet) -> Bool {
            library.contains { same($0, candidate) } || plan.additions.contains { same($0, candidate) }
                || plan.replacements.contains { same($0.snippet, candidate) }
        }
        var holders: [String: UUID] = [:]
        for snippet in existing where !snippet.keyword.isEmpty {
            holders[snippet.keyword] = holders[snippet.keyword] ?? snippet.id
        }
        // Keywords taken by earlier snippets in the same file, mapped to their position in `additions`.
        var claimed: [String: Int] = [:]

        for item in incoming {
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.text.count <= maximumTextLength
            else {
                plan.invalid.append(item)
                continue
            }
            guard !isDuplicate(item) else {
                plan.duplicates.append(item)
                continue
            }
            guard let keyword = item.keyword else {
                plan.additions.append(item)
                continue
            }
            let withoutKeyword = ImportedSnippet(name: item.name, text: item.text)
            guard isValidKeyword(keyword) else {
                if isDuplicate(withoutKeyword) {
                    plan.duplicates.append(item)
                } else {
                    plan.keywordsDropped.append(item)
                    plan.additions.append(withoutKeyword)
                }
                continue
            }
            let holder = holders[keyword]
            let earlier = claimed[keyword]
            guard holder != nil || earlier != nil else {
                claimed[keyword] = plan.additions.count
                plan.additions.append(item)
                continue
            }
            switch policy {
            case .dropKeyword:
                if isDuplicate(withoutKeyword) {
                    plan.duplicates.append(item)
                } else {
                    plan.keywordConflicts.append(item)
                    plan.keywordsDropped.append(item)
                    plan.additions.append(withoutKeyword)
                }
            case .skip:
                plan.keywordConflicts.append(item)
                plan.skippedConflicts.append(item)
            case .replaceExisting:
                plan.keywordConflicts.append(item)
                if let holder {
                    plan.replacements.removeAll { $0.existingID == holder }
                    plan.replacements.append(.init(existingID: holder, snippet: item))
                } else if let earlier {
                    plan.additions[earlier] = item
                }
            }
        }
        return plan
    }

    /// Skips quicklinks already in the library (same name and link) and links
    /// OpenRay refuses to open.
    static func plan(quicklinks incoming: [ImportedQuicklink], existing: [Quicklink]) -> QuicklinkImportPlan {
        var plan = QuicklinkImportPlan()
        func key(_ name: String, _ link: String) -> String {
            name.trimmingCharacters(in: .whitespacesAndNewlines) + "\u{0}" + QuicklinkTemplate(link).modernizedLink
        }
        var seen = Set(existing.map { key($0.name, $0.template) })
        for item in incoming {
            guard (try? QuicklinkTemplate(item.link).validate()) != nil else {
                plan.invalid.append(item)
                continue
            }
            guard seen.insert(key(item.name, item.link)).inserted else {
                plan.duplicates.append(item)
                continue
            }
            plan.additions.append(item)
        }
        return plan
    }
}
