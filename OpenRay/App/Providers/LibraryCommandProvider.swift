import Foundation

/// Slice 2's commands: import and export of snippets and quicklinks, plus the run
/// commands that carry fields for quicklinks and snippets needing typed values.
///
/// A run command declares the item's `ArgumentSpec`s from its full placeholder plan,
/// so the registry resolves `ref.arguments` before `perform`, and Slice 1's argument
/// fields (Step 0 contract §10.2) open on ↩ when a required value is missing. Run
/// commands are hidden from search and never bindable: aliases and hotkeys belong to
/// the item's own row (`quicklink.<UUID>`, `snippet.<UUID>`), which Slice 1 registers.
@MainActor
final class LibraryCommandProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(
        id: "library", bindablePrefixes: ["library.import", "library.export"]
    ) { LibraryCommandProvider() }

    /// Outside every bindable prefix, so no binding can ever target a run command.
    nonisolated static let runPrefix = "library.run."

    nonisolated static func commandID(for link: Quicklink) -> String { runPrefix + "quicklink." + link.id.uuidString }

    nonisolated static func commandID(for snippet: Snippet, action: ContentPrimaryAction) -> String {
        runPrefix + (action == .paste ? "pasteSnippet." : "copySnippet.") + snippet.id.uuidString
    }

    /// Picks files for import and export. Tests replace it.
    var files: any LibraryFileAccess

    var id: String { Self.registration.id }

    /// Field lists by item, kept while the item's text and the snippets it references
    /// are unchanged, so building the command list on every keystroke never re-plans everything.
    private var fieldCache: [UUID: (source: String, references: [String: String?], specs: [ArgumentSpec])] = [:]

    init() { files = PanelLibraryFileAccess() }

    init(files: any LibraryFileAccess) { self.files = files }

    enum Command: String, CaseIterable {
        case importSnippets = "library.importSnippets"
        case exportSnippets = "library.exportSnippets"
        case importQuicklinks = "library.importQuicklinks"
        case exportQuicklinks = "library.exportQuicklinks"

        var kind: LibraryTransferKind { self == .importSnippets || self == .exportSnippets ? .snippets : .quicklinks }
        var isImport: Bool { self == .importSnippets || self == .importQuicklinks }
    }

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        let transfers = Command.allCases.map { command in
            CommandDescriptor(
                id: command.rawValue, title: "\(command.isImport ? "Import" : "Export") \(command.kind.title)",
                subtitle: command.isImport
                    ? (command.kind == .snippets ? "From JSON or macOS Text Replacements" : "From a JSON export")
                    : "As a JSON file",
                kind: command.kind == .snippets ? .snippet : .quicklink,
                symbol: command.isImport ? "square.and.arrow.down" : "square.and.arrow.up",
                keywords: ["library", "backup", "json", command.kind.title.lowercased()]
                    + (command.kind == .snippets && command.isImport ? ["text replacements", "raycast"] : []),
                mode: .noView)
        }
        let database = model.store.database
        let lookup = PlaceholderValues.snippetLookup(database)
        var live = Set<UUID>()
        // A quicklink with more than one field can't run from one typed term.
        let quicklinks: [CommandDescriptor] = database.quicklinks.compactMap { link in
            live.insert(link.id)
            let specs = fields(for: link.id, source: link.template, lookup: lookup) { link.plan(snippets: lookup) }
            guard specs.count > 1 else { return nil }
            return CommandDescriptor(
                id: Self.commandID(for: link), title: link.name, subtitle: "Quicklink · \(specs.count) values",
                kind: .quicklink, symbol: "link", keywords: [link.keyword] + link.tagList, arguments: specs,
                mode: .noView, badge: "Quicklink", showsInRoot: false, isBindable: false)
        }
        // A snippet with fields runs as copy or paste, as ↩ and ⌘↩ do on its row.
        let snippets: [CommandDescriptor] = database.snippets.flatMap { snippet -> [CommandDescriptor] in
            live.insert(snippet.id)
            let specs = fields(for: snippet.id, source: snippet.content, lookup: lookup) {
                snippet.template.plan(snippets: lookup)
            }
            guard !specs.isEmpty else { return [] }
            return [ContentPrimaryAction.copy, .paste].map { action in
                CommandDescriptor(
                    id: Self.commandID(for: snippet, action: action), title: snippet.name,
                    subtitle: action == .copy ? "Snippet · copy" : "Snippet · paste", kind: .snippet, symbol: "curlybraces",
                    keywords: [snippet.keyword] + snippet.tagList, arguments: specs, mode: .noView, badge: "Snippet",
                    showsInRoot: false, isBindable: false)
            }
        }
        fieldCache = fieldCache.filter { live.contains($0.key) }
        return transfers + quicklinks + snippets
    }

    private func fields(
        for id: UUID, source: String, lookup: (String) -> String?, plan: () -> PlaceholderPlan
    ) -> [ArgumentSpec] {
        // The cache comes first: unchanged text compares equal at once, so a keystroke
        // costs one check per item. Items without fields are cached too.
        if let cached = fieldCache[id], cached.source == source,
            cached.references.allSatisfy({ lookup($0.key) == $0.value })
        {
            return cached.specs
        }
        guard source.contains("{") else {
            fieldCache[id] = (source, [:], [])
            return []
        }
        let built = plan()
        let references = Dictionary(uniqueKeysWithValues: built.requirements.snippets.map { ($0, lookup($0)) })
        fieldCache[id] = (source, references, built.argumentSpecs)
        return built.argumentSpecs
    }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        if let command = Command(rawValue: ref.id) {
            model.store.recordUse(of: item.id)
            if command.isImport { model.runImport(command.kind, files: files) } else { model.runExport(command.kind, files: files) }
            return
        }
        let database = model.store.database
        if let link = database.quicklinks.first(where: { Self.commandID(for: $0) == ref.id }) {
            model.openQuicklink(link, arguments: ref.arguments)
            return
        }
        for snippet in database.snippets {
            for action in [ContentPrimaryAction.copy, .paste] where Self.commandID(for: snippet, action: action) == ref.id {
                model.runSnippet(snippet, arguments: ref.arguments, action: action)
                return
            }
        }
    }
}
