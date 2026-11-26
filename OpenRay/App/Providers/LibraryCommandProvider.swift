import Foundation

/// Slice 2's commands: import and export of snippets and quicklinks, and one command
/// per quicklink that needs several values.
///
/// A quicklink command declares the link's `argumentSpecs`, so the registry resolves
/// `ref.arguments` before `perform` and warns about a missing required value. It's
/// hidden from search: the quicklink's own row stays the one people see, and its ↩
/// runs this command when one typed term isn't enough. Slice 1's argument fields fill
/// `ref.arguments` and call `model.perform` on it.
@MainActor
final class LibraryCommandProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(
        id: "library", bindablePrefixes: ["library.", quicklinkPrefix]
    ) { LibraryCommandProvider() }

    nonisolated static let quicklinkPrefix = "quicklink.run."

    nonisolated static func commandID(for link: Quicklink) -> String { quicklinkPrefix + link.id.uuidString }

    /// Picks files for import and export. Tests replace it.
    var files: any LibraryFileAccess

    var id: String { Self.registration.id }

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
        let quicklinks = model.store.database.quicklinks.filter(\.needsSeveralValues).map { link in
            CommandDescriptor(
                id: Self.commandID(for: link), title: link.name,
                subtitle: "Quicklink · \(link.placeholderArguments.count) values", kind: .quicklink, symbol: "link",
                keywords: [link.keyword] + link.tagList, arguments: link.argumentSpecs, mode: .noView,
                badge: "Quicklink", showsInRoot: false)
        }
        return transfers + quicklinks
    }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        if let command = Command(rawValue: ref.id) {
            model.store.recordUse(of: item.id)
            if command.isImport { model.runImport(command.kind, files: files) } else { model.runExport(command.kind, files: files) }
            return
        }
        guard ref.id.hasPrefix(Self.quicklinkPrefix),
            let link = model.store.database.quicklinks.first(where: { Self.commandID(for: $0) == ref.id })
        else { return }
        model.openQuicklink(link, arguments: ref.arguments)
    }
}
