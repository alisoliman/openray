import SwiftUI

/// Search Emoji & Symbols: a grid scope over the bundled Unicode catalog.
///
/// Browsing shows Pinned, Frequently Used and every category; searching shows ranked results.
/// The groups come from the catalog itself rather than the launcher's 100-row scope cap, so
/// every category can be browsed. Tiles repeat across Pinned, Frequently Used and their
/// category, so each tile's id is scoped to its section (`emoji.<section>.<emoji>`).
/// ↩ copies and ⌘↩ pastes through `AnswerDelivery`; pins, frecency and custom keywords live in
/// `LibraryDatabase.emojiUsage`, and the default skin tone and column count in
/// `commandPreferences["emoji.search"]`.
@MainActor
final class EmojiProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(id: "emoji", bindablePrefixes: ["emoji."]) {
        EmojiProvider()
    }

    nonisolated static let searchID = "emoji.search"
    nonisolated static let keywordsID = "emoji.keywords"
    nonisolated static let preferencesKey = "emoji.search"

    static let scope = ProvidedScope(
        id: searchID, provider: "emoji", title: "Emoji & Symbols", symbol: "face.smiling", kind: .command,
        placeholder: "Search emoji and symbols", summary: "Copy or paste emoji, arrows, math and other symbols",
        shortTitle: "Emoji", itemNoun: "emoji", style: .grid, ranksItems: false, columns: GridColumns.defaultCount)

    static let keywordScope = ProvidedScope(
        id: keywordsID, provider: "emoji", title: "Custom Keywords", symbol: "tag", kind: .command,
        placeholder: "Keywords, separated by commas", itemNoun: "keyword", ranksItems: false)

    var id: String { Self.registration.id }

    let catalog: EmojiCatalog
    private let now: () -> Date
    /// The last groups built, reused while the query and preferences don't change, because the
    /// launcher asks for groups several times per keystroke and selection move.
    private var cache: (query: String, preferences: EmojiPreferences, groups: [LauncherResultGroup])?

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

    func update(in model: LauncherModel, _ change: (inout EmojiPreferences) -> Void) {
        var preferences = preferences(in: model)
        change(&preferences)
        save(preferences, in: model)
    }

    // MARK: Commands and scope

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: Self.searchID, title: "Search Emoji & Symbols", subtitle: Self.scope.summary, kind: .command,
                symbol: "face.smiling", keywords: ["emoji", "symbols", "unicode", "arrows", "math", "currency", "picker"],
                mode: .view(.provided(Self.scope)))
        ]
    }

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        guard scope.id == Self.keywordsID, let glyph = scope.arguments["emoji"], let entry = catalog.entry(for: glyph) else {
            return []
        }
        let keywords = Self.keywords(from: query)
        let title =
            keywords.isEmpty
            ? "Remove Custom Keywords for \(entry.glyph)"
            : "Save “\(keywords.joined(separator: ", ").truncatedForFeedback)” for \(entry.glyph)"
        return [
            LauncherItem(
                id: "emoji.keywords.save", title: title, subtitle: entry.title, symbol: "tag", kind: .command,
                badge: "Keywords",
                action: .provided(ProvidedRef(provider: id, id: "saveKeywords", payload: entry.id, primaryTitle: "Save Keywords", traits: [])))
        ]
    }

    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup]? {
        guard scope.id == Self.searchID else { return nil }
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferences = preferences(in: model)
        if let cache, cache.query == query, cache.preferences == preferences { return cache.groups }
        let columns = preferences.columns
        let renderer = GridTileRenderer { item, _ in AnyView(GridGlyph(glyph: item.title, columns: columns)) }
        let groups = catalog.sections(query: query, preferences: preferences, now: now()).map { section in
            LauncherResultGroup(
                id: "emoji.\(section.id)", title: section.title, style: .grid,
                items: section.entries.map { item(for: $0, section: section.id, tone: preferences.defaultSkinTone) },
                columns: columns, tile: renderer)
        }
        cache = (query, preferences, groups)
        return groups
    }

    /// A tile. Its title is the glyph in the default skin tone, which ↩ and ⌘↩ use.
    func item(for entry: EmojiEntry, section: String, tone: SkinTone) -> LauncherItem {
        let glyph = entry.glyph(for: tone)
        return LauncherItem(
            id: "emoji.\(section).\(entry.id)", title: glyph, subtitle: entry.title, symbol: "face.smiling",
            kind: .command, badge: entry.category.title, keywords: entry.keywords.joined(separator: " "),
            action: .provided(
                ProvidedRef(
                    provider: id, id: "emoji", payload: entry.id, copyText: glyph,
                    primaryTitle: "Copy \(entry.category.isTextSymbol ? "Symbol" : "Emoji")", traits: [.paste, .edit])))
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?
    {
        guard scope.id == Self.searchID else { return nil }
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
        case "saveKeywords":
            guard let base = ref.payload else { return }
            let keywords = Self.keywords(from: model.query)
            update(in: model) { $0.setKeywords(keywords, for: base) }
            model.navigate(to: .provided(Self.scope))
            model.toast(keywords.isEmpty ? "Removed custom keywords for \(base)" : "Saved keywords for \(base)")
        default: break
        }
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        guard ref.id == "emoji" else { return nil }
        return AnswerDelivery.primaryTitle(copy: ref.primaryTitle ?? "Copy Emoji", in: model)
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        ref.id == "emoji" ? "doc.on.doc" : "checkmark"
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

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        guard ref.id == "emoji", let base = ref.payload, let entry = catalog.entry(for: base) else { return [] }
        let preferences = preferences(in: model)
        var entries: [ActionEntry] = []
        if entry.supportsSkinTones {
            let tones = SkinTone.allCases
            entries.append(
                ActionEntry(
                    id: "emoji.pasteTone", title: "Paste with Skin Tone…", symbol: "hand.raised",
                    shortcut: KeyShortcut(["⌥", "⌘", "V"]), key: "v", modifiers: [.option, .command], group: .item,
                    children: tones.map { tone in
                        ActionEntry(id: "emoji.pasteTone.\(tone.rawValue)", title: "\(entry.glyph(for: tone))  \(tone.title)", symbol: "hand.raised", group: .item) {
                            [weak self, weak model] in
                            guard let model else { return }
                            model.paste(entry.glyph(for: tone), label: entry.glyph(for: tone))
                            self?.recordUse(base, in: model)
                        }
                    }
                ) { [weak self, weak model] in
                    guard let model else { return }
                    model.paste(entry.glyph(for: preferences.defaultSkinTone), label: entry.title)
                    self?.recordUse(base, in: model)
                })
            entries.append(
                ActionEntry(
                    id: "emoji.copyTone", title: "Copy with Skin Tone…", symbol: "hand.raised",
                    shortcut: KeyShortcut(["⌥", "⌘", "C"]), key: "c", modifiers: [.option, .command], group: .item,
                    children: tones.map { tone in
                        ActionEntry(id: "emoji.copyTone.\(tone.rawValue)", title: "\(entry.glyph(for: tone))  \(tone.title)", symbol: "hand.raised", group: .item) {
                            [weak self, weak model] in
                            guard let model else { return }
                            if model.copy(entry.glyph(for: tone)) { self?.recordUse(base, in: model) }
                        }
                    }
                ) { [weak self, weak model] in
                    guard let model else { return }
                    if model.copy(entry.glyph(for: preferences.defaultSkinTone)) { self?.recordUse(base, in: model) }
                })
        }
        let codepoints = entry.codepoints(for: preferences.defaultSkinTone)
        entries.append(
            ActionEntry(
                id: "emoji.copyUnicode", title: "Copy Unicode", symbol: "number",
                shortcut: KeyShortcut(["⌥", "⇧", "⌘", "C"]), key: "c", modifiers: [.option, .shift, .command],
                group: .item
            ) { [weak model] in model?.copy(codepoints) })
        entries.append(
            ActionEntry(
                id: "emoji.copyName", title: "Copy Name", symbol: "textformat", group: .item
            ) { [weak model] in model?.copy(entry.title) })
        let pinned = preferences.isPinned(base)
        entries.append(
            ActionEntry(
                id: "emoji.pin", title: pinned ? "Unpin" : "Pin", symbol: pinned ? "pin.slash" : "pin",
                shortcut: .command("."), key: ".", modifiers: .command, group: .organize
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                self.update(in: model) { $0.togglePin(base) }
                model.toast(pinned ? "Unpinned \(base)" : "Pinned \(base)")
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
        if !(preferences.customKeywords[base] ?? []).isEmpty || preferences.usage.records[base] != nil {
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
