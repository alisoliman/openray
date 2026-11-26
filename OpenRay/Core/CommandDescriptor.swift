import Foundation

// Value types for the command registry. They are Sendable and nonisolated, so the library
// can ask about bindings while decoding. The provider protocol and the registry itself,
// which need LauncherModel, live in App/CommandRegistry.swift.

/// How a command runs. The cases follow the command modes in Raycast's public developer docs.
enum CommandMode: Hashable, Sendable {
    /// Pushes a list: a built-in scope such as `.snippets`, or a provider's own `.provided(scope)`.
    case view(LauncherSection)
    /// Runs without a list, then closes the panel or reports in a toast.
    case noView
    /// Opens the AI view.
    case ai
    /// Shows its output as a root-search row. `refresh` is how often it updates; nil means on each search.
    case inline(refresh: Duration?)
    /// Lives in the menu bar.
    case menuBar
}

/// One command a provider offers. The registry turns each descriptor into a root-search row
/// that can be a favorite, a recent, and the target of an alias or hotkey.
struct CommandDescriptor: Identifiable, Hashable, Sendable {
    /// Globally unique and stable, because favorites, usage and bindings store it.
    /// Namespace it by provider: `window.leftHalf`, `system.lock`, `emoji.search`.
    var id: String
    var title: String
    var subtitle: String
    var kind: Kind
    var symbol: String
    /// Extra words search matches, below the title.
    var keywords: [String] = []
    /// Inputs typed after the command's name. Model only until Slice 1 builds the fields.
    var arguments: [ArgumentSpec] = []
    var mode: CommandMode
    /// The row's trailing label.
    var badge = "Command"
    /// What the command does, in one line. Search matches it like a keyword, and when a search
    /// matches it but not the title, the row shows it in place of the subtitle.
    var detail: String? = nil
    /// False keeps the command out of root search; it still works from favorites, aliases and hotkeys.
    var showsInRoot = true
    /// Dimmed, with `subtitle` saying why: a missing permission, or AI that isn't ready.
    var isUnavailable = false
    /// False keeps the command out of Settings › Shortcuts and refuses aliases and hotkeys for it,
    /// even when its registration accepts the id.
    var isBindable = true
    /// Asked in the action bar before the command runs, from search and from a hotkey alike.
    var confirmation: CommandConfirmation? = nil

    /// What ↩ does, said in VoiceOver hints. The action bar asks the provider, which can be more specific.
    var primaryTitle: String {
        switch mode {
        case .view(let scope): "Open \(scope.title)"
        case .ai, .noView, .inline: "Run Command"
        case .menuBar: "Open Command"
        }
    }
}

/// The question a command asks before it runs: “Shut down now?” · “Open apps may ask to save.”
struct CommandConfirmation: Hashable, Sendable {
    var question: String
    var detail: String
    /// The ↩ button's title: “Shut Down”.
    var confirmTitle: String
    var symbol = "exclamationmark.triangle"
    /// Shut Down, Restart, Empty Trash and the like: the approve button is drawn in the danger
    /// style, and Return approves only while the prompt is on screen.
    var isDestructive = false
}

/// The payload of `LauncherItem.Action.provided`: which provider owns a row, and what the
/// row can do. The provider fills it in when it builds the item.
///
/// The capability flags live here, not behind a registry call, because `LauncherItem`'s
/// flags (`canFavorite`, `canDelete`, …) are plain value properties read from any context.
struct ProvidedRef: Hashable, Sendable {
    struct Traits: OptionSet, Hashable, Sendable {
        let rawValue: Int
        /// A command: it groups under Commands in root search and gets the exact-title boost.
        static let command = Traits(rawValue: 1 << 0)
        /// Can be added to Favorites.
        static let favorite = Traits(rawValue: 1 << 1)
        /// ⌘↩ pastes `copyText` into the frontmost app.
        static let paste = Traits(rawValue: 1 << 2)
        /// ⌘⌫ asks, then calls the provider's `delete`.
        static let delete = Traits(rawValue: 1 << 3)
        /// ⌘E calls the provider's `edit`.
        static let edit = Traits(rawValue: 1 << 4)
        /// Dimmed in lists. The subtitle should say why.
        static let unavailable = Traits(rawValue: 1 << 5)
        /// Set by `CommandDescriptor.item(provider:)`: the row stands for a catalog command, so
        /// ↩ re-resolves the command and refuses when it no longer exists.
        static let descriptor = Traits(rawValue: 1 << 6)
    }

    /// The owning provider's registration id.
    var provider: String
    /// The provider's own identifier for the row, often the descriptor id.
    var id: String
    /// Anything else the provider needs to act on the row, such as an emoji or a path.
    var payload: String? = nil
    /// Argument values by `ArgumentSpec.name`.
    var arguments: [String: String] = [:]
    /// The text ⌘↩ pastes, and the row's `copyText`.
    var copyText: String? = nil
    /// What ↩ does, for VoiceOver hints. The action bar asks the provider's `primaryTitle`.
    var primaryTitle: String? = nil
    /// Shown in place of the subtitle when a search matches it but not the title.
    var matchDetail: String? = nil
    /// A fixed search score. Rows that answer the query, such as a conversion, use it to skip
    /// the matcher; 1,000 ties an exact title match. Nil ranks the row like any other.
    var rank: Int? = nil
    var traits: Traits = [.favorite]

    func has(_ trait: Traits) -> Bool { traits.contains(trait) }
}

/// A provider's own list, pushed like a built-in scope. Navigate with
/// `model.navigate(to: .provided(scope))`, or give a command `mode: .view(.provided(scope))`.
/// Scopes are equal when their ids are.
struct ProvidedScope: Hashable, Sendable {
    /// Unique among scopes. Namespace it like command ids: `emoji.search`.
    var id: String
    /// The owning provider's registration id.
    var provider: String
    var title: String
    var symbol: String
    var kind: Kind
    var placeholder: String
    /// The one-line description used as a command subtitle.
    var summary = ""
    /// A compact name for favorites tiles.
    var shortTitle: String? = nil
    var itemNoun = "item"
    /// How the default single group is drawn: `.list` or `.grid`.
    var style: LauncherResultGroup.Style = .list
    var showsPreview = false
    /// True ranks the provider's rows with the shared matcher, as built-in scopes do.
    /// False shows them in the provider's order; the provider filters for itself.
    var ranksItems = true
    /// Columns in the default group when `style` is `.grid`. Nil uses the launcher's default (4).
    var columns: Int? = nil
    /// The resolved argument values of the command that opened the scope, by `ArgumentSpec.name`.
    /// Not part of the scope's identity.
    var arguments: [String: String] = [:]

    static func == (lhs: ProvidedScope, rhs: ProvidedScope) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A provider's line in `CommandProviders.all`. It answers which commands can hold an alias
/// or hotkey without creating the provider, because the library asks while it decodes,
/// before any provider exists. A binding whose target no registration accepts is dropped.
struct CommandProviderRegistration: Sendable {
    /// Matches the provider's `id` and every `ProvidedRef.provider` it builds.
    var id: String
    /// Commands that can hold an alias or hotkey, in the order Settings lists them.
    var bindableIDs: [String] = []
    /// Namespaces whose every command can hold an alias or hotkey, such as `system.` or `script.`.
    /// Declare your namespace here once, and new commands under it need no further declaration.
    /// Bindings for commands that are missing right now are kept, inactive, until they return.
    var bindablePrefixes: [String] = []
    var make: @MainActor @Sendable () -> any CommandProvider

    func acceptsBinding(_ targetID: String) -> Bool {
        bindableIDs.contains(targetID) || bindablePrefixes.contains { targetID.hasPrefix($0) }
    }
}

extension CommandDescriptor {
    /// The command's row: a favorite-able command whose ↩ goes to its provider.
    func item(provider: String) -> LauncherItem {
        var traits: ProvidedRef.Traits = [.command, .favorite, .descriptor]
        if isUnavailable { traits.insert(.unavailable) }
        return LauncherItem(
            id: id, title: title, subtitle: subtitle, symbol: symbol, kind: kind, badge: badge,
            keywords: (keywords + [detail].compactMap { $0 }.filter { !keywords.contains($0) }).joined(separator: " "),
            action: .provided(
                ProvidedRef(provider: provider, id: id, primaryTitle: primaryTitle, matchDetail: detail, traits: traits)))
    }
}
