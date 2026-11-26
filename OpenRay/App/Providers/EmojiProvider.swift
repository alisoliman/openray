import SwiftUI

/// Search Emoji & Symbols: a grid scope over the bundled Unicode catalog.
///
/// Every tile comes through `scopeItems`, so the launcher's shared paths apply: the query
/// length guard, global aliases and the 100-row scope cap. To stay under the cap, browsing is
/// paged by category: the scope's first screen shows Pinned, Frequently Used and one tile per
/// category; a category shows 96 tiles a page, with tiles for the next and previous pages.
/// Searching shows the best 96 matches, within the open category if there is one. Tiles
/// repeat across Pinned, Frequently Used and their category, so each tile's id is scoped to
/// its section (`emoji-tile.<section>.<emoji>`), outside the bindable `emoji.` namespace.
///
/// ↩ copies and ⌘↩ pastes through `AnswerDelivery`. Pins, frecency and custom keywords live in
/// `LibraryDatabase.emojiUsage`; the default skin tone and column count in
/// `commandPreferences["emoji.search"]`.
@MainActor
final class EmojiProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(id: "emoji", bindablePrefixes: ["emoji."]) {
        EmojiProvider()
    }

    nonisolated static let searchID = "emoji.search"
    nonisolated static let keywordsID = "emoji.keywords"
    nonisolated static let tonesID = "emoji.tones"
    nonisolated static let preferencesKey = "emoji.search"
    /// Tiles per page: with up to three navigation tiles, a page stays under the scope cap.
    nonisolated static let pageSize = 96
    nonisolated static let browseLimit = 16
    /// Emoji names are short; longer pasted text isn't searched.
    nonisolated static let maximumQueryLength = 64

    static let scope = ProvidedScope(
        id: searchID, provider: "emoji", title: "Emoji & Symbols", symbol: "face.smiling", kind: .command,
        placeholder: "Search emoji and symbols", summary: "Copy or paste emoji, arrows, math and other symbols",
        shortTitle: "Emoji", itemNoun: "emoji", style: .grid, ranksItems: false, columns: GridColumns.defaultCount)

    static let keywordScope = ProvidedScope(
        id: keywordsID, provider: "emoji", title: "Custom Keywords", symbol: "tag", kind: .command,
        placeholder: "Keywords, separated by commas", itemNoun: "keyword", ranksItems: false)

    static let toneScope = ProvidedScope(
        id: tonesID, provider: "emoji", title: "Choose a Skin Tone", symbol: "hand.raised", kind: .command,
        placeholder: "Choose a skin tone", itemNoun: "skin tone", style: .grid, ranksItems: false,
        columns: SkinTone.allCases.count)

    var id: String { Self.registration.id }

    let catalog: EmojiCatalog
    private let now: () -> Date

    init() {
        catalog = .bundled
        now = { Date() }
    }

    init(catalog: EmojiCatalog, now: @escaping () -> Date = { Date() }) {
        self.catalog = catalog
        self.now = now
    }

    // MARK: Preferences

    func preferences(in model: LauncherModel) -> EmojiPreferences {
        let database = model.store.database
        let settings = database.commandPreferences[Self.preferencesKey] ?? [:]
        return EmojiPreferences(
            records: database.emojiUsage,
            defaultSkinTone: settings["skinTone"].flatMap(Int.init).flatMap(SkinTone.init(rawValue:)) ?? .none,
            columns: settings["columns"].flatMap(Int.init) ?? GridColumns.defaultCount)
    }

    @discardableResult
    func save(_ preferences: EmojiPreferences, in model: LauncherModel) -> Bool {
        model.store.update { database in
            database.emojiUsage = preferences.records
            database.commandPreferences[Self.preferencesKey, default: [:]]["skinTone"] = "\(preferences.defaultSkinTone.rawValue)"
            database.commandPreferences[Self.preferencesKey, default: [:]]["columns"] = "\(preferences.columns)"
        }
    }

    /// Changes the preferences and saves them. On failure the model says why and nothing changes.
    @discardableResult
    func update(in model: LauncherModel, _ change: (inout EmojiPreferences) -> Void) -> Bool {
        var preferences = preferences(in: model)
        change(&preferences)
        guard save(preferences, in: model) else {
            model.feedback = .error(model.store.errorMessage ?? "Couldn't save the change to your library.")
            return false
        }
        return true
    }

    // MARK: Commands

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: Self.searchID, title: "Search Emoji & Symbols", subtitle: Self.scope.summary, kind: .command,
                symbol: "face.smiling", keywords: ["emoji", "symbols", "unicode", "arrows", "math", "currency", "picker"],
                mode: .view(.provided(Self.scope)))
        ]
    }

    // MARK: Rows

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        switch scope.id {
        case Self.searchID: return searchItems(scope, query: query, in: model)
        case Self.keywordsID: return keywordItems(scope, query: query)
        case Self.tonesID: return toneItems(scope)
        default: return []
        }
    }

    private func searchItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        let preferences = preferences(in: model)
        let tone = preferences.defaultSkinTone
        let category = scope.arguments["category"].flatMap(EmojiCategory.init(rawValue:))
        if !query.isEmpty {
            guard query.count <= Self.maximumQueryLength else { return [] }
            return catalog.search(query, preferences: preferences, category: category, now: now())
                .prefix(Self.pageSize).map { tile($0, section: "results", tone: tone) }
        }
        if let category {
            let entries = catalog.entries(in: category)
            let pages = max(1, (entries.count + Self.pageSize - 1) / Self.pageSize)
            let page = min(max(scope.arguments["page"].flatMap(Int.init) ?? 0, 0), pages - 1)
            let start = page * Self.pageSize
            var items = [navigationTile("all", title: "All Categories", symbol: "square.grid.2x2", section: "start")]
            if page > 0 {
                items.append(
                    navigationTile("\(category.rawValue)/\(page - 1)", title: "Previous", symbol: "chevron.left", section: "start"))
            }
            items += entries[start..<min(start + Self.pageSize, entries.count)].map { tile($0, section: category.rawValue, tone: tone) }
            if page < pages - 1 {
                items.append(navigationTile("\(category.rawValue)/\(page + 1)", title: "More", symbol: "chevron.right", section: "end"))
            }
            return items
        }
        let pinned = preferences.pinned.compactMap { catalog.entry(for: $0) }.prefix(Self.browseLimit)
        let pinnedIDs = Set(pinned.map(\.id))
        let frequent = preferences.usage.ranked(at: now(), limit: Self.browseLimit + pinnedIDs.count)
            .compactMap { catalog.entry(for: $0) }.filter { !pinnedIDs.contains($0.id) }.prefix(Self.browseLimit)
        return pinned.map { tile($0, section: "pinned", tone: tone) }
            + frequent.map { tile($0, section: "frequent", tone: tone) }
            + EmojiCategory.allCases.filter { !catalog.entries(in: $0).isEmpty }.map { category in
                navigationTile("\(category.rawValue)/0", title: category.title, symbol: category.systemImage, section: "categories")
            }
    }

    /// A tile. Its title is the glyph in the default skin tone, which ↩ and ⌘↩ use.
    func tile(_ entry: EmojiEntry, section: String, tone: SkinTone) -> LauncherItem {
        let glyph = entry.glyph(for: tone)
        return LauncherItem(
            id: "emoji-tile.\(section).\(entry.id)", title: glyph, subtitle: entry.title, symbol: "face.smiling",
            kind: .command, badge: entry.category.title, keywords: entry.keywords.joined(separator: " "),
            action: .provided(
                ProvidedRef(
                    provider: id, id: "emoji", payload: entry.id, copyText: glyph,
                    primaryTitle: "Copy \(entry.category.isTextSymbol ? "Symbol" : "Emoji")", traits: [.paste, .edit])))
    }

    /// A tile that browses: a category's first page ("smileys-emotion/0"), another page, or "all".
    private func navigationTile(_ destination: String, title: String, symbol: String, section: String) -> LauncherItem {
        LauncherItem(
            id: "emoji-nav.\(section).\(destination)", title: title, subtitle: "", symbol: symbol, kind: .command,
            badge: "Browse",
            action: .provided(ProvidedRef(provider: id, id: "browse", payload: destination, primaryTitle: "Show \(title)", traits: [])))
    }

    private func keywordItems(_ scope: ProvidedScope, query: String) -> [LauncherItem] {
        guard let glyph = scope.arguments["emoji"], let entry = catalog.entry(for: glyph) else { return [] }
        let keywords = Self.keywords(from: query)
        let title =
            keywords.isEmpty
            ? "Remove Custom Keywords for \(entry.glyph)"
            : "Save “\(keywords.joined(separator: ", ").truncatedForFeedback)” for \(entry.glyph)"
        return [
            LauncherItem(
                id: "emoji-keywords.save", title: title, subtitle: entry.title, symbol: "tag", kind: .command,
                badge: "Keywords",
                action: .provided(
                    ProvidedRef(provider: id, id: "saveKeywords", payload: entry.id, primaryTitle: "Save Keywords", traits: [])))
        ]
    }

    private func toneItems(_ scope: ProvidedScope) -> [LauncherItem] {
        guard let base = scope.arguments["emoji"], let entry = catalog.entry(for: base) else { return [] }
        return SkinTone.allCases.map { tone in
            let glyph = entry.glyph(for: tone)
            return LauncherItem(
                id: "emoji-tone.\(tone.rawValue)", title: glyph, subtitle: tone.title, symbol: "hand.raised",
                kind: .command, badge: tone.title,
                action: .provided(
                    ProvidedRef(
                        provider: id, id: "tone", payload: entry.id, arguments: scope.arguments, copyText: glyph,
                        primaryTitle: scope.arguments["mode"] == "paste" ? "Paste \(tone.title)" : "Copy \(tone.title)",
                        traits: [])))
        }
    }

    // MARK: Groups

    /// Grid groups from the pipeline's rows, one per section in order. Rows that aren't tiles
    /// (a global alias's command) keep the default group.
    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup]? {
        guard scope.id == Self.searchID || scope.id == Self.tonesID else { return nil }
        guard !items.isEmpty, items.allSatisfy({ Self.section(of: $0) != nil }) else { return nil }
        let columns = scope.id == Self.tonesID ? SkinTone.allCases.count : preferences(in: model).columns
        let renderer = GridTileRenderer { item, _ in
            if item.id.hasPrefix("emoji-nav.") { return AnyView(StandardGridTile(item: item)) }
            return AnyView(GridGlyph(glyph: item.title, columns: columns))
        }
        var groups: [LauncherResultGroup] = []
        for item in items {
            let section = Self.section(of: item) ?? ""
            if groups.last?.id == "emoji.\(section)" {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append(
                    LauncherResultGroup(
                        id: "emoji.\(section)", title: title(of: section, scope: scope), style: .grid, items: [item],
                        columns: columns, tile: renderer))
            }
        }
        return groups
    }

    /// The section part of a tile's id, or nil for rows this provider didn't make.
    nonisolated static func section(of item: LauncherItem) -> String? {
        for prefix in ["emoji-tile.", "emoji-nav.", "emoji-tone."] where item.id.hasPrefix(prefix) {
            if prefix == "emoji-tone." { return "tones" }
            return item.id.dropFirst(prefix.count).split(separator: ".", maxSplits: 1).first.map(String.init)
        }
        return nil
    }

    private func title(of section: String, scope: ProvidedScope) -> String? {
        switch section {
        case "results": return "Results"
        case "pinned": return "Pinned"
        case "frequent": return "Frequently Used"
        case "categories": return "Categories"
        case "start", "end", "tones": return nil
        default:
            guard let category = EmojiCategory(rawValue: section) else { return nil }
            let count = catalog.entries(in: category).count
            guard count > Self.pageSize else { return category.title }
            let page = scope.arguments["page"].flatMap(Int.init) ?? 0
            let start = page * Self.pageSize
            return "\(category.title) · \(start + 1)–\(min(start + Self.pageSize, count)) of \(count)"
        }
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?
    {
        guard scope.id == Self.searchID else { return nil }
        if query.count > Self.maximumQueryLength {
            return ProvidedEmptyState(
                title: "That's too long to search", detail: "Emoji names are short, such as “thumbs up” or “arrow”.",
                symbol: "face.smiling")
        }
        return ProvidedEmptyState(
            title: "No emoji or symbols match “\(query.truncatedForFeedback)”",
            detail: "Search by name, such as “thumbs up” or “arrow”, or add your own keywords with ⌘E.",
            symbol: "face.smiling")
    }

    func itemNoun(for ref: ProvidedRef) -> String { "Emoji" }

    // MARK: ↩, ⌘↩ and ⌘K

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        switch ref.id {
        case "emoji":
            guard let text = ref.copyText, let base = ref.payload else { return }
            if AnswerDelivery.primary(text, label: text, in: model) { recordUse(base, in: model) }
        case "browse":
            browse(ref.payload ?? "all", in: model)
        case "tone":
            guard let text = ref.copyText, let base = ref.payload else { return }
            if ref.arguments["mode"] == "paste" {
                model.paste(text, label: text)
                recordUse(base, in: model)
            } else if model.copy(text, label: text) {
                recordUse(base, in: model)
                model.navigate(to: .provided(Self.scope))
                model.toast("Copied “\(text)”")
            }
        case "saveKeywords":
            guard let base = ref.payload else { return }
            let keywords = Self.keywords(from: model.query)
            // A failed save keeps the editor open with the store's reason.
            guard update(in: model, { $0.setKeywords(keywords, for: base) }) else { return }
            model.navigate(to: .provided(Self.scope))
            model.toast(keywords.isEmpty ? "Removed custom keywords for \(base)" : "Saved keywords for \(base)")
        default: break
        }
    }

    /// Opens a category page ("smileys-emotion/2") or the first screen ("all").
    private func browse(_ destination: String, in model: LauncherModel) {
        var scope = Self.scope
        let parts = destination.split(separator: "/")
        if let first = parts.first, let category = EmojiCategory(rawValue: String(first)) {
            scope.arguments = ["category": category.rawValue, "page": parts.count > 1 ? String(parts[1]) : "0"]
            scope.title = category.title
        }
        model.navigate(to: .provided(scope))
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        guard ref.id == "emoji" else { return ref.primaryTitle }
        return AnswerDelivery.primaryTitle(copy: ref.primaryTitle ?? "Copy Emoji", in: model)
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        switch ref.id {
        case "emoji", "tone": "doc.on.doc"
        case "browse": "arrow.right.circle"
        default: "checkmark"
        }
    }

    func secondaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        guard ref.id == "emoji" else { return nil }
        return AnswerDelivery.secondaryTitle(copy: ref.primaryTitle ?? "Copy Emoji", for: item, in: model)
    }

    func performSecondary(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        guard ref.id == "emoji", let text = ref.copyText, let base = ref.payload else { return }
        if AnswerDelivery.secondary(text, label: text, in: model) { recordUse(base, in: model) }
    }

    /// ⌘E: the search field becomes the keyword list, and ↩ saves it.
    func edit(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        guard let base = ref.payload else { return }
        var scope = Self.keywordScope
        scope.title = "Keywords for \(base)"
        scope.arguments = ["emoji": base]
        let existing = preferences(in: model).customKeywords[base] ?? []
        model.navigate(to: .provided(scope))
        model.query = existing.joined(separator: ", ")
    }

    /// Opens the skin-tone chooser; nothing is copied or pasted until a tone is chosen.
    func chooseTone(for base: String, mode: String, in model: LauncherModel) {
        var scope = Self.toneScope
        scope.arguments = ["emoji": base, "mode": mode]
        scope.title = mode == "paste" ? "Paste with Skin Tone" : "Copy with Skin Tone"
        model.navigate(to: .provided(scope))
    }

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        guard ref.id == "emoji", let base = ref.payload, let entry = catalog.entry(for: base) else { return [] }
        let preferences = preferences(in: model)
        var entries: [ActionEntry] = []
        if entry.supportsSkinTones {
            // The parents open the chooser. Their children are the same choices, for when the
            // action panel draws submenus (Slice 1).
            for mode in ["paste", "copy"] {
                let paste = mode == "paste"
                entries.append(
                    ActionEntry(
                        id: "emoji.\(mode)Tone", title: paste ? "Paste with Skin Tone…" : "Copy with Skin Tone…",
                        symbol: "hand.raised", shortcut: KeyShortcut(["⌥", "⌘", paste ? "V" : "C"]),
                        key: paste ? "v" : "c", modifiers: [.option, .command], group: .item,
                        children: SkinTone.allCases.map { tone in
                            let glyph = entry.glyph(for: tone)
                            return ActionEntry(
                                id: "emoji.\(mode)Tone.\(tone.rawValue)", title: "\(glyph)  \(tone.title)",
                                symbol: "hand.raised", group: .item
                            ) { [weak self, weak model] in
                                guard let self, let model else { return }
                                if paste {
                                    model.paste(glyph, label: glyph)
                                    self.recordUse(base, in: model)
                                } else if model.copy(glyph, label: glyph) {
                                    self.recordUse(base, in: model)
                                }
                            }
                        }
                    ) { [weak self, weak model] in
                        guard let self, let model else { return }
                        self.chooseTone(for: base, mode: mode, in: model)
                    })
            }
        }
        let codepoints = entry.codepoints(for: preferences.defaultSkinTone)
        entries.append(
            ActionEntry(
                id: "emoji.copyUnicode", title: "Copy Unicode", symbol: "number",
                shortcut: KeyShortcut(["⌥", "⇧", "⌘", "C"]), key: "c", modifiers: [.option, .shift, .command],
                group: .item
            ) { [weak model] in model?.copy(codepoints) })
        entries.append(
            ActionEntry(id: "emoji.copyName", title: "Copy Name", symbol: "textformat", group: .item) { [weak model] in
                model?.copy(entry.title)
            })
        let pinned = preferences.isPinned(base)
        // ⇧⌘P, because the panel's ⌘. already stops AI.
        entries.append(
            ActionEntry(
                id: "emoji.pin", title: pinned ? "Unpin" : "Pin", symbol: pinned ? "pin.slash" : "pin",
                shortcut: .command("P", shift: true), key: "p", modifiers: [.command, .shift], group: .organize
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                if self.update(in: model, { $0.togglePin(base) }) { model.toast(pinned ? "Unpinned \(base)" : "Pinned \(base)") }
            })
        entries.append(
            ActionEntry(
                id: "emoji.larger", title: "Larger Tiles", symbol: "plus.magnifyingglass", shortcut: .command("+"),
                key: "=", modifiers: .command, group: .panel
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                self.update(in: model) { $0.columns = GridColumns.zoomedIn($0.columns) }
            })
        entries.append(
            ActionEntry(
                id: "emoji.smaller", title: "Smaller Tiles", symbol: "minus.magnifyingglass", shortcut: .command("-"),
                key: "-", modifiers: .command, group: .panel
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                self.update(in: model) { $0.columns = GridColumns.zoomedOut($0.columns) }
            })
        if preferences.columns != GridColumns.defaultCount {
            entries.append(
                ActionEntry(
                    id: "emoji.resetSize", title: "Default Tile Size", symbol: "arrow.counterclockwise",
                    shortcut: .command("0"), key: "0", modifiers: .command, group: .panel
                ) { [weak self, weak model] in
                    guard let self, let model else { return }
                    self.update(in: model) { $0.columns = GridColumns.defaultCount }
                })
        }
        if preferences.usage.records[base] != nil {
            entries.append(
                ActionEntry(id: "emoji.forget", title: "Reset Ranking", symbol: "arrow.uturn.backward", group: .organize) {
                    [weak self, weak model] in
                    guard let self, let model else { return }
                    self.update(in: model) { $0.usage.forget(base) }
                })
        }
        return entries
    }

    func recordUse(_ base: String, in model: LauncherModel) {
        let date = now()
        update(in: model) { $0.recordUse(base, at: date) }
    }

    /// "lit, fire  ,hot" → ["lit", "fire", "hot"].
    nonisolated static func keywords(from text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
