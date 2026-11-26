import Foundation

// Tools over OpenRay's own data: clipboard history, notes, snippets, quicklinks, files and
// the calculator. Reads run on their own; the create tools change the library, so they
// ask first (`AIToolPermission.auto`). Calendar, windows and system commands join here once
// Slices 5 and 6 land, as `.system` tools behind `SideEffectGuard`.

private func clipped(_ text: String, to limit: Int = 400) -> String {
    let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
}

private func matches(_ query: String?, _ fields: String?...) -> Bool {
    guard let query, !query.isEmpty else { return true }
    let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
    let haystack = fields.compactMap { $0?.lowercased() }.joined(separator: " ")
    return terms.allSatisfy { haystack.contains($0) }
}

private let queryParameter = AIToolParameter(
    name: "query", description: "Words to look for. Leave empty for the most recent.", isOptional: true)

@MainActor
struct ClipboardSearchTool: AIToolExecutor {
    let store: LibraryStore
    let spec = AIToolSpec(
        id: "searchClipboard", extensionID: "clipboard", title: "Search Clipboard History", symbol: "list.clipboard",
        summary: "Finds text the person copied recently. Returns up to eight entries, newest first.",
        parameters: [queryParameter])

    func describe(_ arguments: AIToolArguments) -> String {
        arguments["query"].map { "Search clipboard history for “\($0)”" } ?? "Read recent clipboard history"
    }

    func run(_ arguments: AIToolArguments) async throws -> String {
        let entries = store.database.clipboard.sorted { $0.copiedAt > $1.copiedAt }
            .filter { matches(arguments["query"], $0.plainText, $0.recognizedText, $0.sourceName) }
            .compactMap { entry in (entry.plainText ?? entry.recognizedText).map { (entry, $0) } }
            .prefix(8)
        guard !entries.isEmpty else { return "No clipboard entries matched." }
        return entries.enumerated().map { index, pair in
            "\(index + 1). From \(pair.0.sourceName), \(pair.0.copiedAt.formatted(date: .abbreviated, time: .shortened)): \(clipped(pair.1))"
        }
        .joined(separator: "\n")
    }
}

@MainActor
struct NotesSearchTool: AIToolExecutor {
    let store: LibraryStore
    let spec = AIToolSpec(
        id: "searchNotes", extensionID: "notes", title: "Search Notes", symbol: "note.text",
        summary: "Finds the person's OpenRay notes by words in their title or text.", parameters: [queryParameter])

    func describe(_ arguments: AIToolArguments) -> String {
        arguments["query"].map { "Search notes for “\($0)”" } ?? "Read recent notes"
    }

    func run(_ arguments: AIToolArguments) async throws -> String {
        let notes = store.database.notes.sorted { $0.modifiedAt > $1.modifiedAt }
            .filter { matches(arguments["query"], $0.title, $0.content) }.prefix(6)
        guard !notes.isEmpty else { return "No notes matched." }
        return notes.map { "## \($0.title)\n\(clipped($0.content, to: 600))" }.joined(separator: "\n\n")
    }
}

@MainActor
struct CreateNoteTool: AIToolExecutor {
    let store: LibraryStore
    let spec = AIToolSpec(
        id: "createNote", extensionID: "notes", title: "Create Note", symbol: "note.text.badge.plus",
        summary: "Saves a new note in OpenRay. Use only when the person asks to save or note something.",
        parameters: [
            AIToolParameter(name: "title", description: "A short title.", isOptional: true),
            AIToolParameter(name: "content", description: "The note's text."),
        ], effect: .library)

    func describe(_ arguments: AIToolArguments) -> String {
        "Create a note titled “\(arguments["title"] ?? QuickNote.derivedTitle(from: arguments["content"] ?? ""))”"
    }

    func run(_ arguments: AIToolArguments) async throws -> String {
        guard let content = arguments["content"] else { throw AIToolError.missingArgument("content") }
        let note = QuickNote(title: arguments["title"] ?? "", content: content)
        guard store.save(note) else { throw AIToolError.failed(store.errorMessage ?? "The note couldn't be saved.") }
        return "Saved the note “\(store.database.notes.first { $0.id == note.id }?.title ?? note.title)”."
    }
}

@MainActor
struct SnippetsSearchTool: AIToolExecutor {
    let store: LibraryStore
    let spec = AIToolSpec(
        id: "searchSnippets", extensionID: "snippets", title: "Search Snippets", symbol: "text.quote",
        summary: "Finds the person's saved text snippets by name, keyword or text.", parameters: [queryParameter])

    func describe(_ arguments: AIToolArguments) -> String {
        arguments["query"].map { "Search snippets for “\($0)”" } ?? "List snippets"
    }

    func run(_ arguments: AIToolArguments) async throws -> String {
        let snippets = store.database.snippets.filter { matches(arguments["query"], $0.name, $0.keyword, $0.content) }
            .prefix(8)
        guard !snippets.isEmpty else { return "No snippets matched." }
        return snippets.map { snippet in
            let keyword = snippet.keyword.isEmpty ? "" : " (keyword \(snippet.keyword))"
            return "- \(snippet.name)\(keyword): \(clipped(snippet.content, to: 300))"
        }
        .joined(separator: "\n")
    }
}

@MainActor
struct CreateSnippetTool: AIToolExecutor {
    let store: LibraryStore
    let spec = AIToolSpec(
        id: "createSnippet", extensionID: "snippets", title: "Create Snippet", symbol: "text.badge.plus",
        summary: "Saves reusable text as a snippet. Use only when the person asks for a snippet.",
        parameters: [
            AIToolParameter(name: "name", description: "The snippet's name."),
            AIToolParameter(name: "text", description: "The text to save."),
            AIToolParameter(name: "keyword", description: "A short keyword that expands it, if the person gave one.", isOptional: true),
        ], effect: .library)

    func describe(_ arguments: AIToolArguments) -> String {
        "Create a snippet named “\(arguments["name"] ?? "Untitled")”"
    }

    func run(_ arguments: AIToolArguments) async throws -> String {
        guard let name = arguments["name"] else { throw AIToolError.missingArgument("name") }
        guard let text = arguments["text"] else { throw AIToolError.missingArgument("text") }
        let snippet = Snippet(name: name, keyword: arguments["keyword"] ?? "", content: text)
        guard store.save(snippet) else { throw AIToolError.failed(store.errorMessage ?? "The snippet couldn't be saved.") }
        return "Saved the snippet “\(name)”."
    }
}

@MainActor
struct QuicklinksSearchTool: AIToolExecutor {
    let store: LibraryStore
    let spec = AIToolSpec(
        id: "searchQuicklinks", extensionID: "quicklinks", title: "Search Quicklinks", symbol: "link",
        summary: "Finds the person's saved links by name, keyword or address.", parameters: [queryParameter])

    func describe(_ arguments: AIToolArguments) -> String {
        arguments["query"].map { "Search quicklinks for “\($0)”" } ?? "List quicklinks"
    }

    func run(_ arguments: AIToolArguments) async throws -> String {
        let links = store.database.quicklinks.filter { matches(arguments["query"], $0.name, $0.keyword, $0.template) }
            .prefix(8)
        guard !links.isEmpty else { return "No quicklinks matched." }
        return links.map { "- \($0.name): \($0.template)" }.joined(separator: "\n")
    }
}

@MainActor
struct CreateQuicklinkTool: AIToolExecutor {
    let store: LibraryStore
    let spec = AIToolSpec(
        id: "createQuicklink", extensionID: "quicklinks", title: "Create Quicklink", symbol: "link.badge.plus",
        summary: "Saves a link as a quicklink. Use only when the person asks to save a link.",
        parameters: [
            AIToolParameter(name: "name", description: "The quicklink's name."),
            AIToolParameter(name: "link", description: "The address. {query} marks where a search term goes."),
        ], effect: .library)

    func describe(_ arguments: AIToolArguments) -> String {
        "Create a quicklink “\(arguments["name"] ?? "Untitled")” to \(arguments["link"] ?? "an address")"
    }

    func run(_ arguments: AIToolArguments) async throws -> String {
        guard let name = arguments["name"] else { throw AIToolError.missingArgument("name") }
        guard let link = arguments["link"] else { throw AIToolError.missingArgument("link") }
        let quicklink = Quicklink(name: name, template: link, keyword: "")
        guard store.save(quicklink) else { throw AIToolError.failed(store.errorMessage ?? "The quicklink couldn't be saved.") }
        return "Saved the quicklink “\(name)”."
    }
}

@MainActor
struct CalculatorTool: AIToolExecutor {
    var evaluate: @MainActor (String) -> String? = { Calculator.evaluate($0)?.result }
    let spec = AIToolSpec(
        id: "calculate", extensionID: "calculator", title: "Calculate", symbol: "function",
        summary:
            "Works out arithmetic, unit conversions, percentages and date math exactly, such as '12% of 340', '5 km in miles' or 'today + 30 days'. Use it instead of computing yourself.",
        parameters: [AIToolParameter(name: "expression", description: "The calculation, written plainly.")])

    func describe(_ arguments: AIToolArguments) -> String { "Calculate “\(arguments["expression"] ?? "")”" }

    func run(_ arguments: AIToolArguments) async throws -> String {
        guard let expression = arguments["expression"] else { throw AIToolError.missingArgument("expression") }
        return evaluate(expression).map { "\(expression) = \($0)" } ?? "OpenRay couldn't calculate “\(expression)”."
    }
}

/// Finds files by name with Spotlight.
@MainActor
protocol AIFileSearching {
    func search(_ query: String, limit: Int) async -> [URL]
}

/// Spotlight over the home folder, with the same exclusions as File Search.
@MainActor
final class SpotlightFileSearcher: NSObject, AIFileSearching {
    private var query: NSMetadataQuery?
    private var continuation: CheckedContinuation<[URL], Never>?
    private var limit = 10

    func search(_ text: String, limit: Int) async -> [URL] {
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty, text.count <= 512 else { return [] }
        finish([])
        self.limit = limit
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let query = NSMetadataQuery()
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            query.searchScopes = [home]
            var predicates = [
                NSPredicate(format: "NOT (%K BEGINSWITH %@)", NSMetadataItemPathKey, home + "/Library/"),
                NSPredicate(format: "NOT (%K BEGINSWITH %@)", NSMetadataItemFSNameKey, "."),
            ]
            for term in terms { predicates.append(NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, term)) }
            query.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
            NotificationCenter.default.addObserver(
                self, selector: #selector(didFinish(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
            self.query = query
            if !query.start() { finish([]) }
        }
    }

    @objc private func didFinish(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery, query === self.query else { return }
        query.disableUpdates()
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls: [URL] = []
        for index in 0..<min(query.resultCount, 400) where urls.count < limit {
            guard let item = query.result(at: index) as? NSMetadataItem,
                let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            let url = URL(fileURLWithPath: path)
            if FileSearchPolicy.accepts(url, home: home) { urls.append(url) }
        }
        finish(urls)
    }

    private func finish(_ urls: [URL]) {
        if let query {
            NotificationCenter.default.removeObserver(self, name: nil, object: query)
            query.stop()
        }
        query = nil
        continuation?.resume(returning: urls)
        continuation = nil
    }
}

@MainActor
struct FileSearchTool: AIToolExecutor {
    let searcher: any AIFileSearching
    let spec = AIToolSpec(
        id: "searchFiles", extensionID: "files", title: "Search Files", symbol: "doc.text.magnifyingglass",
        summary: "Finds files in the person's home folder by words in their names. Returns names, folders and dates.",
        parameters: [AIToolParameter(name: "query", description: "Words in the file name.")])

    func describe(_ arguments: AIToolArguments) -> String { "Search files for “\(arguments["query"] ?? "")”" }

    func run(_ arguments: AIToolArguments) async throws -> String {
        guard let query = arguments["query"] else { throw AIToolError.missingArgument("query") }
        let urls = await searcher.search(query, limit: 10)
        guard !urls.isEmpty else { return "No files matched “\(query)”." }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return urls.map { url in
            let folder = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            return "- \(url.lastPathComponent) in \(folder)"
        }
        .joined(separator: "\n")
    }
}

/// The tools OpenRay offers, grouped by @-mention.
enum AIToolCatalog {
    struct ExtensionInfo: Sendable {
        var title: String
        var symbol: String
        var aliases: [String]
    }

    /// Titles and extra mention words, by extension id. Order is the order Settings lists them.
    static let extensionOrder = ["clipboard", "notes", "snippets", "quicklinks", "files", "calculator"]
    static let extensionInfo: [String: ExtensionInfo] = [
        "clipboard": ExtensionInfo(title: "Clipboard History", symbol: "list.clipboard", aliases: []),
        "notes": ExtensionInfo(title: "Notes", symbol: "note.text", aliases: ["note"]),
        "snippets": ExtensionInfo(title: "Snippets", symbol: "text.quote", aliases: ["snippet"]),
        "quicklinks": ExtensionInfo(title: "Quicklinks", symbol: "link", aliases: ["quicklink", "links"]),
        "files": ExtensionInfo(title: "Files", symbol: "doc.text.magnifyingglass", aliases: ["finder", "file-search", "file"]),
        "calculator": ExtensionInfo(title: "Calculator", symbol: "function", aliases: ["math", "calc", "date"]),
    ]

    @MainActor
    static func standard(store: LibraryStore, files: any AIFileSearching) -> [any AIToolExecutor] {
        [
            ClipboardSearchTool(store: store),
            NotesSearchTool(store: store), CreateNoteTool(store: store),
            SnippetsSearchTool(store: store), CreateSnippetTool(store: store),
            QuicklinksSearchTool(store: store), CreateQuicklinkTool(store: store),
            FileSearchTool(searcher: files),
            CalculatorTool(),
        ]
    }

    /// Groups tools into mentionable extensions, in `extensionOrder`, then any others by id.
    static func extensions(for specs: [AIToolSpec]) -> [AIToolExtension] {
        let grouped = Dictionary(grouping: specs, by: \.extensionID)
        let ids = extensionOrder.filter { grouped[$0] != nil } + grouped.keys.filter { !extensionOrder.contains($0) }.sorted()
        return ids.map { id in
            let info = extensionInfo[id] ?? ExtensionInfo(title: id.capitalized, symbol: "wrench.and.screwdriver", aliases: [])
            let tools = (grouped[id] ?? []).sorted { ($0.effect == .read ? 0 : 1, $0.id) < ($1.effect == .read ? 0 : 1, $1.id) }
            return AIToolExtension(id: id, title: info.title, symbol: info.symbol, aliases: info.aliases, tools: tools)
        }
    }
}
