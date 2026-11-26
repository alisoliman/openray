import SwiftUI

/// What a provider shows in the preview pane beside its scope's list.
struct ProvidedPreview {
    /// The media or text at the top of the pane.
    var content: AnyView? = nil
    /// Label–value rows under a hairline, as the built-in previews show.
    var metadata: [(label: String, value: String)] = []
}

/// How a provider removes one of its rows after the person confirms.
enum ProvidedDeletion {
    /// The row lives in `library.json`. The launcher runs the mutation and clears the row's
    /// favorite and usage records in the same save, so they succeed or fail together.
    case library((inout LibraryDatabase) throws -> Void)
    /// The row lives in the provider's own store. Return false, after setting `model.feedback`
    /// to say why, when it couldn't be removed. The launcher then clears the favorite and usage
    /// records, and retries that cleanup on later saves if it fails.
    case store(@MainActor () -> Bool)
}

/// A question asked in the action bar before something runs. ↩ calls `perform`; esc cancels.
struct ProvidedConfirmation {
    var id: String
    /// This instance's identity. Asking the same question again makes a new one, so an approval
    /// meant for an earlier prompt can't answer it.
    let token = UUID()
    var question: String
    var detail: String
    var confirmTitle: String
    var symbol = "exclamationmark.triangle"
    /// Drawn in the danger style; Return approves only while the prompt is on screen.
    var isDestructive = false
    var perform: @MainActor () -> Void

    init(id: String, _ text: CommandConfirmation, perform: @escaping @MainActor () -> Void) {
        self.id = id
        question = text.question
        detail = text.detail
        confirmTitle = text.confirmTitle
        symbol = text.symbol
        isDestructive = text.isDestructive
        self.perform = perform
    }
}

/// A fallback the person can choose in Settings, described without a search.
struct FallbackCandidate: Identifiable, Equatable, Sendable {
    /// The fallback row's id, `fallback.` included.
    var id: String
    var title: String
    var symbol: String
    var kind: Kind
}

/// What an empty provided scope says.
struct ProvidedEmptyState: Equatable {
    var title: String
    var detail: String
    var symbol: String? = nil
}

/// Draws one tile of a grid group. The launcher adds the selection fill, hover, click and
/// accessibility around it, so the renderer draws only the tile's content.
struct GridTileRenderer {
    var render: @MainActor (_ item: LauncherItem, _ selected: Bool) -> AnyView

    /// The row's glyph over its title, for grids without a custom look.
    static let standard = GridTileRenderer { item, _ in AnyView(StandardGridTile(item: item)) }
}

/// A source of commands and rows. Register one with a line in `CommandProviders.all`.
///
/// Every requirement except `id` and `commands(in:)` has a default, so a provider implements
/// only what it offers. Rows a provider builds carry `.provided(ProvidedRef)` actions whose
/// `provider` is this provider's `id`; the launcher routes ↩, ⌘↩, ⌘K, the preview, delete and
/// edit for those rows back here. Everything runs on the main actor, with the launcher's model.
@MainActor
protocol CommandProvider: AnyObject {
    /// Matches the registration's id.
    var id: String { get }
    /// The heading Settings › Commands lists this provider's commands under. Defaults to the id.
    var title: String { get }

    /// The commands this provider offers. Each becomes a root-search row that can be a favorite,
    /// a recent, and the target of an alias or hotkey (if the registration accepts its id).
    func commands(in model: LauncherModel) -> [CommandDescriptor]

    /// Extra root-search rows for a query, beyond the commands: answers, matching content.
    /// They're ranked with everything else unless their ref sets `rank`. `query` is trimmed and may be empty.
    func rootItems(for query: String, in model: LauncherModel) -> [LauncherItem]

    /// Rebuilds a row from its item id, so favorites and recents of non-command rows still show.
    func item(withID id: String, in model: LauncherModel) -> LauncherItem?

    /// The rows of one of this provider's scopes. Ranked by the shared matcher unless the scope
    /// sets `ranksItems = false`. `scope.arguments` holds the opening command's argument values.
    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem]

    /// Groups for a scope's rows, already ranked or filtered. Nil shows one untitled group in the
    /// scope's `style` and `columns`. Groups with no rows are dropped unless they're `isLoading`.
    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup]?

    /// What the scope says when it has no rows. `isLoading` is true while a live search is
    /// still running. Nil uses a generic searching, empty or no-matches message.
    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?

    /// True when `liveItems` has anything to say, so the launcher starts a search for it.
    var providesLiveItems: Bool { get }
    /// The root-search group title for this provider's live rows.
    var liveGroupTitle: String { get }
    /// Rows that take time. The launcher starts each provider's search on its own task on every
    /// query change, cancels it when the query changes or search is left, and drops results
    /// for an earlier query. `scope` is nil in root search, where the rows never become the
    /// Top Hit and appear in their own group; in a scope they follow the scope's rows.
    func liveItems(for query: String, scope: ProvidedScope?, in model: LauncherModel) async -> [LauncherItem]

    /// Rows offered under “Use … with” when root search has a query. Their ids must start with
    /// `fallback.`; the registry adds the prefix when it's missing.
    func fallbackItems(for query: String, in model: LauncherModel) -> [LauncherItem]

    /// The fallbacks this provider can offer, described for Settings › Commands, whatever is typed.
    /// The default describes the rows `fallbackItems` returns for a placeholder search; override it
    /// when your rows depend on the query. Ids match the rows' (`fallback.` is added when missing).
    func fallbackDescriptors(in model: LauncherModel) -> [FallbackCandidate]

    /// ↩ on one of this provider's rows. Commands with `mode: .view(scope)` never get here: the
    /// registry opens their scope. Arguments arrive resolved: defaults applied, text trimmed.
    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel)

    /// The action bar's ↩ label. Nil uses the ref's `primaryTitle`.
    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String?
    /// The ⌘K symbol beside the ↩ entry. Nil picks one from the command's mode.
    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String?

    /// The ⌘↩ label in the action bar and ⌘K, or nil for no secondary action. The default
    /// offers text paste (“Paste to Notes”) for rows with the `.paste` trait and a `copyText`.
    func secondaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String?
    /// ⌘↩, from the keyboard, the action bar or ⌘K. The default pastes `copyText`.
    func performSecondary(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel)

    /// Extra ⌘K entries for a row. They follow ↩ and ⌘↩ and come before Edit, Favorite and Delete,
    /// which the launcher adds from the ref's traits. Use `section` and `children` to structure them.
    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry]

    /// The preview pane for a row, in scopes with `showsPreview`.
    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview?

    /// The noun in “Delete …”, capitalized: “Script”, “Chat”.
    func itemNoun(for ref: ProvidedRef) -> String
    /// How to remove a row with the `.delete` trait, once the person confirms. Nil can't delete it.
    func deletion(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedDeletion?
    /// Opens an editor for a row with the `.edit` trait.
    func edit(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel)
}

extension CommandProvider {
    var title: String {
        id.split(separator: ".").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
    func rootItems(for query: String, in model: LauncherModel) -> [LauncherItem] { [] }
    func item(withID id: String, in model: LauncherModel) -> LauncherItem? { nil }
    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] { [] }
    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup]? {
        nil
    }
    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?
    { nil }
    var providesLiveItems: Bool { false }
    var liveGroupTitle: String { "Results" }
    func liveItems(for query: String, scope: ProvidedScope?, in model: LauncherModel) async -> [LauncherItem] { [] }
    func fallbackItems(for query: String, in model: LauncherModel) -> [LauncherItem] { [] }
    func fallbackDescriptors(in model: LauncherModel) -> [FallbackCandidate] {
        fallbackItems(for: "…", in: model).map {
            FallbackCandidate(id: $0.id, title: $0.title, symbol: $0.symbol, kind: $0.kind)
        }
    }
    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {}
    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? { nil }
    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? { nil }
    func secondaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        model.textPasteTitle(for: item)
    }
    func performSecondary(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        model.pasteText(of: item)
    }
    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] { [] }
    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview? { nil }
    func itemNoun(for ref: ProvidedRef) -> String { "Item" }
    func deletion(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedDeletion? { nil }
    func edit(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {}

    /// A command's row, as the registry builds it.
    func item(for descriptor: CommandDescriptor) -> LauncherItem { descriptor.item(provider: id) }
}

/// The registered providers, and the launcher's one way to reach them.
@MainActor
final class CommandRegistry {
    let providers: [any CommandProvider]

    /// Every provider in `CommandProviders.all`.
    convenience init() {
        self.init(providers: CommandProviders.all.map { $0.make() })
    }

    /// Specific providers, for tests.
    init(providers: [any CommandProvider]) {
        self.providers = providers
    }

    func provider(id: String) -> (any CommandProvider)? { providers.first { $0.id == id } }

    // MARK: Rows

    /// Every provider's commands, as root-search rows, in registration order.
    func commandItems(in model: LauncherModel) -> [LauncherItem] {
        providers.flatMap { provider in provider.commands(in: model).filter(\.showsInRoot).map(provider.item(for:)) }
    }

    /// Commands that stay out of root search but can still be favorites, recents or binding targets.
    func hiddenCommandItems(in model: LauncherModel) -> [LauncherItem] {
        providers.flatMap { provider in provider.commands(in: model).filter { !$0.showsInRoot }.map(provider.item(for:)) }
    }

    /// The commands that can hold an alias or hotkey right now, shown or hidden, in registration
    /// order and then each provider's own order. This is the one catalog Settings, aliases and
    /// hotkey registration share.
    func bindableCommandItems(in model: LauncherModel) -> [LauncherItem] {
        providers.flatMap { provider in
            provider.commands(in: model).filter { $0.isBindable && CuratedCommand.supports($0.id) }
                .map(provider.item(for:))
        }
    }

    func rootItems(for query: String, in model: LauncherModel) -> [LauncherItem] {
        providers.flatMap { $0.rootItems(for: query, in: model) }
    }

    /// A row by item id: a command first, then whatever a provider rebuilds.
    func item(withID id: String, in model: LauncherModel) -> LauncherItem? {
        for provider in providers {
            if let descriptor = provider.commands(in: model).first(where: { $0.id == id }) {
                return provider.item(for: descriptor)
            }
            if let item = provider.item(withID: id, in: model) { return item }
        }
        return nil
    }

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        provider(id: scope.provider)?.scopeItems(scope, query: query, in: model) ?? []
    }

    /// A scope's groups. Provider groups that are loading stay, even while empty. The default
    /// group appears only with rows, so an empty scope shows its empty state.
    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup] {
        if let groups = provider(id: scope.provider)?.scopeGroups(scope, items: items, in: model) {
            // Provider grids never fall through to the window layout tiles.
            return groups.filter { !$0.items.isEmpty || $0.isLoading }.map { group in
                var group = group
                if group.style == .grid, group.tile == nil { group.tile = .standard }
                return group
            }
        }
        var group = LauncherResultGroup(id: scope.id, title: nil, style: scope.style, items: items)
        if scope.style == .grid {
            group.columns = scope.columns
            group.tile = .standard
        }
        return [group].filter { !$0.items.isEmpty }
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?
    {
        provider(id: scope.provider)?.emptyState(for: scope, query: query, isLoading: isLoading, in: model)
    }

    func fallbackItems(for query: String, in model: LauncherModel) -> [LauncherItem] {
        providers.flatMap { $0.fallbackItems(for: query, in: model) }.map { item in
            var item = item
            if !item.id.hasPrefix("fallback.") { item.id = "fallback." + item.id }
            return item
        }
    }

    func fallbackDescriptors(in model: LauncherModel) -> [FallbackCandidate] {
        providers.flatMap { $0.fallbackDescriptors(in: model) }.map { candidate in
            var candidate = candidate
            if !candidate.id.hasPrefix("fallback.") { candidate.id = "fallback." + candidate.id }
            return candidate
        }
    }

    /// Providers with a live search for this place: all of them in root search, the owner in its scope.
    func liveProviders(for scope: ProvidedScope?) -> [any CommandProvider] {
        guard let scope else { return providers.filter(\.providesLiveItems) }
        return provider(id: scope.provider).map { $0.providesLiveItems ? [$0] : [] } ?? []
    }

    // MARK: Dispatch

    /// The descriptor behind a command row, when the row is one.
    func descriptor(for ref: ProvidedRef, in model: LauncherModel) -> CommandDescriptor? {
        provider(id: ref.provider)?.commands(in: model).first { $0.id == ref.id }
    }

    /// Runs a row. For a command, the declared arguments are resolved first: defaults applied,
    /// text trimmed, required ones checked. A command with a confirmation asks it in the action
    /// bar. A command that pushes a scope opens it, carrying the argument values. Everything
    /// else goes to the provider, with the resolved values in `ref.arguments`.
    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        guard let provider = provider(id: ref.provider) else {
            model.feedback = .error("“\(item.title.truncatedForFeedback)” is no longer available.")
            return
        }
        guard let descriptor = provider.commands(in: model).first(where: { $0.id == ref.id }) else {
            // A command row from an older snapshot (⌘K, a favorite) whose command is gone must not
            // run, and above all must not skip a confirmation it would have asked.
            guard !ref.has(.descriptor) else {
                model.feedback = .error("“\(item.title.truncatedForFeedback)” is no longer available.")
                return
            }
            provider.perform(item, ref: ref, in: model)
            return
        }
        guard model.isCommandEnabled(descriptor.id) else {
            model.feedback = .warning("“\(item.title.truncatedForFeedback)” is turned off. Turn it on in Settings › Commands.")
            return
        }
        var resolved = ref
        if !descriptor.arguments.isEmpty {
            do {
                let values = try ArgumentSpec.resolve(descriptor.arguments, typed: ref.arguments)
                let declared = Set(descriptor.arguments.map(\.name))
                resolved.arguments = ref.arguments.filter { !declared.contains($0.key) }.merging(values) { _, new in new }
            } catch {
                model.feedback = .warning(error.localizedDescription)
                return
            }
        }
        let run: @MainActor () -> Void = { [weak model] in
            guard let model else { return }
            switch descriptor.mode {
            case .view(let section):
                model.store.recordUse(of: item.id)
                if case .provided(var scope) = section {
                    scope.arguments = resolved.arguments
                    model.navigate(to: .provided(scope))
                } else {
                    model.navigate(to: section)
                }
            default:
                provider.perform(item, ref: resolved, in: model)
            }
        }
        if let question = descriptor.confirmation {
            // Approval re-checks the catalog: the command must still exist and still ask the same question.
            let approve: @MainActor () -> Void = { [weak self, weak model] in
                guard let self, let model else { return }
                let current = self.provider(id: ref.provider)?.commands(in: model).first { $0.id == ref.id }
                guard let current else {
                    model.feedback = .error("“\(item.title.truncatedForFeedback)” is no longer available.")
                    return
                }
                guard model.isCommandEnabled(current.id) else {
                    model.feedback = .warning("“\(item.title.truncatedForFeedback)” was turned off.")
                    return
                }
                guard current.confirmation == question else {
                    model.feedback = .warning("“\(item.title.truncatedForFeedback)” changed. Run it again to confirm.")
                    return
                }
                run()
            }
            model.selectedID = item.id
            model.presentConfirmation(.provided(ProvidedConfirmation(id: descriptor.id, question, perform: approve)))
        } else {
            run()
        }
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String {
        provider(id: ref.provider)?.primaryTitle(for: item, ref: ref, in: model) ?? item.primaryActionTitle
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String {
        if let symbol = provider(id: ref.provider)?.primarySymbol(for: item, ref: ref, in: model) { return symbol }
        switch descriptor(for: ref, in: model)?.mode {
        case .ai?: return "sparkles"
        case .view?: return "arrow.right.circle"
        default: return ref.has(.paste) ? "doc.on.doc" : "arrow.up.forward.app"
        }
    }

    func secondaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        guard let provider = provider(id: ref.provider) else { return nil }
        return provider.secondaryTitle(for: item, ref: ref, in: model)
    }

    func performSecondary(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        provider(id: ref.provider)?.performSecondary(item, ref: ref, in: model)
    }

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        provider(id: ref.provider)?.actions(for: item, ref: ref, in: model) ?? []
    }

    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview? {
        provider(id: ref.provider)?.preview(for: item, ref: ref, in: model)
    }

    func itemNoun(for ref: ProvidedRef) -> String { provider(id: ref.provider)?.itemNoun(for: ref) ?? "Item" }

    func deletion(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedDeletion? {
        provider(id: ref.provider)?.deletion(for: item, ref: ref, in: model)
    }

    func edit(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        provider(id: ref.provider)?.edit(item, ref: ref, in: model)
    }
}
