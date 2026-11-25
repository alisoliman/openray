import SwiftUI

/// What a provider shows in the preview pane beside its scope's list.
struct ProvidedPreview {
    /// The media or text at the top of the pane.
    var content: AnyView? = nil
    /// Label–value rows under a hairline, as the built-in previews show.
    var metadata: [(label: String, value: String)] = []
}

/// A source of commands and rows. Register one with a line in `CommandProviders.all`.
///
/// Every requirement except `id` and `commands(in:)` has a default, so a provider implements
/// only what it offers. Rows a provider builds carry `.provided(ProvidedRef)` actions whose
/// `provider` is this provider's `id`; the launcher routes ↩, ⌘K, the preview, delete and edit
/// for those rows back here. Everything runs on the main actor, with the launcher's model.
@MainActor
protocol CommandProvider: AnyObject {
    /// Matches the registration's id.
    var id: String { get }

    /// The commands this provider offers. Each becomes a root-search row that can be a favorite,
    /// a recent, and the target of an alias or hotkey (if the registration accepts its id).
    func commands(in model: LauncherModel) -> [CommandDescriptor]

    /// Extra root-search rows for a query, beyond the commands: answers, matching content.
    /// They're ranked with everything else unless their ref sets `rank`. `query` is trimmed and may be empty.
    func rootItems(for query: String, in model: LauncherModel) -> [LauncherItem]

    /// Rebuilds a row from its item id, so favorites and recents of non-command rows still show.
    func item(withID id: String, in model: LauncherModel) -> LauncherItem?

    /// The rows of one of this provider's scopes. Ranked by the shared matcher unless the scope
    /// sets `ranksItems = false`.
    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem]

    /// Groups for a scope's rows, already ranked or filtered. Nil shows one untitled group in
    /// the scope's `style`.
    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup]?

    /// True when `liveItems` has anything to say, so the launcher starts a search for it.
    var providesLiveItems: Bool { get }
    /// The root-search group title for this provider's live rows.
    var liveGroupTitle: String { get }
    /// Rows that take time: a search the launcher starts on each query change and cancels when
    /// the query changes again. `scope` is nil in root search, where the rows never become the
    /// Top Hit and appear in their own group; in a scope they follow the scope's rows.
    func liveItems(for query: String, scope: ProvidedScope?, in model: LauncherModel) async -> [LauncherItem]

    /// Rows offered under “Use … with” when root search has a query. Their ids must start with
    /// `fallback.`; the registry adds the prefix when it's missing.
    func fallbackItems(for query: String, in model: LauncherModel) -> [LauncherItem]

    /// ↩ on one of this provider's rows. Commands with `mode: .view(scope)` never get here:
    /// the registry opens their scope.
    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel)

    /// The action bar's ↩ label. Nil uses the ref's `primaryTitle`.
    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String?
    /// The ⌘K symbol beside the ↩ entry. Nil picks one from the command's mode.
    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String?

    /// Extra ⌘K entries for a row. They follow ↩ and ⌘↩ and come before Edit, Favorite and Delete,
    /// which the launcher adds from the ref's traits. Use `section` and `children` to structure them.
    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry]

    /// The preview pane for a row, in scopes with `showsPreview`.
    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview?

    /// The noun in “Delete …”, capitalized: “Script”, “Chat”.
    func itemNoun(for ref: ProvidedRef) -> String
    /// Removes a row with the `.delete` trait after the person confirms. Return false, and set
    /// `model.feedback`, when it couldn't be removed. The launcher then forgets its favorite and usage.
    func delete(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> Bool
    /// Opens an editor for a row with the `.edit` trait.
    func edit(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel)
}

extension CommandProvider {
    func rootItems(for query: String, in model: LauncherModel) -> [LauncherItem] { [] }
    func item(withID id: String, in model: LauncherModel) -> LauncherItem? { nil }
    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] { [] }
    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup]? {
        nil
    }
    var providesLiveItems: Bool { false }
    var liveGroupTitle: String { "Results" }
    func liveItems(for query: String, scope: ProvidedScope?, in model: LauncherModel) async -> [LauncherItem] { [] }
    func fallbackItems(for query: String, in model: LauncherModel) -> [LauncherItem] { [] }
    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {}
    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? { nil }
    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? { nil }
    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] { [] }
    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview? { nil }
    func itemNoun(for ref: ProvidedRef) -> String { "Item" }
    func delete(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> Bool { false }
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

    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup] {
        if let groups = provider(id: scope.provider)?.scopeGroups(scope, items: items, in: model) {
            return groups.filter { !$0.items.isEmpty }
        }
        return [LauncherResultGroup(id: scope.id, title: nil, style: scope.style, items: items)].filter { !$0.items.isEmpty }
    }

    func fallbackItems(for query: String, in model: LauncherModel) -> [LauncherItem] {
        providers.flatMap { $0.fallbackItems(for: query, in: model) }.map { item in
            var item = item
            if !item.id.hasPrefix("fallback.") { item.id = "fallback." + item.id }
            return item
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

    /// Runs a row. Commands that push a scope open it here; required arguments are checked
    /// first; everything else goes to the provider.
    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        guard let provider = provider(id: ref.provider) else {
            model.feedback = .error("“\(item.title.truncatedForFeedback)” is no longer available.")
            return
        }
        if let descriptor = provider.commands(in: model).first(where: { $0.id == ref.id }) {
            do {
                _ = try ArgumentSpec.resolve(descriptor.arguments, typed: ref.arguments)
            } catch {
                model.feedback = .warning(error.localizedDescription)
                return
            }
            if case .view(let scope) = descriptor.mode {
                model.store.recordUse(of: item.id)
                model.navigate(to: scope)
                return
            }
        }
        provider.perform(item, ref: ref, in: model)
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

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        provider(id: ref.provider)?.actions(for: item, ref: ref, in: model) ?? []
    }

    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview? {
        provider(id: ref.provider)?.preview(for: item, ref: ref, in: model)
    }

    func itemNoun(for ref: ProvidedRef) -> String { provider(id: ref.provider)?.itemNoun(for: ref) ?? "Item" }

    func delete(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> Bool {
        provider(id: ref.provider)?.delete(item, ref: ref, in: model) ?? false
    }

    func edit(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        provider(id: ref.provider)?.edit(item, ref: ref, in: model)
    }
}
