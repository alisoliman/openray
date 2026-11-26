import AppKit
import SwiftUI

/// Inline argument fields in the search bar: up to three, for a command whose descriptor
/// declares `ArgumentSpec`s, or for anything a slice starts with `beginArguments(…)`.
struct ArgumentSession {
    /// The row the arguments are for. Results show only it while the fields are open.
    var item: LauncherItem
    var specs: [ArgumentSpec]
    /// Typed values by `ArgumentSpec.name`. Dropdowns hold the chosen option's value.
    var values: [String: String]
    /// The field holding the keyboard.
    var focus = 0
    /// Changes whenever focus moves, so the newly focused field takes the keyboard.
    var focusToken = 1
    /// Runs with the resolved values: defaults applied, text trimmed, every check passed.
    var run: @MainActor ([String: String]) -> Void

    static let maximumFields = 3

    func value(at index: Int) -> String { specs.indices.contains(index) ? values[specs[index].name] ?? "" : "" }
}

/// A launcher key that isn't text editing: ⌘Esc, ⌘W, and ⌃J/⌃K with Vim navigation on.
enum LauncherKeyCommand: Equatable {
    case popToRoot, closeWindow, moveDown, moveUp

    /// The command for a key press, from its hardware key code and modifiers. Pure, so it's
    /// tested without events.
    static func command(keyCode: UInt16, modifiers: ShortcutModifiers, vim: Bool) -> LauncherKeyCommand? {
        switch (keyCode, modifiers) {
        case (53, .command): .popToRoot
        case (13, .command): .closeWindow
        case (38, .control) where vim: .moveDown
        case (40, .control) where vim: .moveUp
        default: nil
        }
    }
}

extension LauncherModel {
    // MARK: - Ranking

    /// How much picking a row for a query lifts it the next time: enough to pass rows that
    /// matched as well, never so much that a scattered match beats an exact title.
    nonisolated static func learnedBoost(_ picks: Int) -> Int { min(picks, 3) * 150 }

    /// The score a row's alias earns for a partial query: just below an exact title, above
    /// title prefixes. An exact alias isn't scored here; it wins outright in `results`.
    func aliasPrefixScore(for item: LauncherItem, query: String) -> Int? {
        guard let alias = CommandBinding.normalizedAlias(store.database.binding(for: item.id)?.alias),
            let typed = CommandBinding.normalizedAlias(query), !typed.contains(where: \.isWhitespace),
            alias.hasPrefix(typed), alias != typed, canBind(item)
        else { return nil }
        return 950 - min(alias.count - typed.count, 50)
    }

    /// Learns the pick and the search when a row is run from a root search.
    func noteQueryPick(for item: LauncherItem) {
        guard destination == .search, argumentLink == nil, argumentSession == nil, section == .home,
            !item.id.hasPrefix("fallback."), !item.id.hasPrefix("argument."), item.id != "calculation"
        else { return }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let remembersHistory = store.database.preferences.remembersSearchHistory
        memory.update { memory in
            memory.recordPick(of: item.id, for: term)
            if remembersHistory { memory.recordSearch(term) }
        }
        historyCursor = nil
    }

    func canResetRanking(_ item: LauncherItem) -> Bool {
        memory.memory.hasLearned(item.id) || store.database.usage.contains { $0.id == item.id }
    }

    /// Forgets what was learned about a row: its query picks and its recent use.
    func resetRanking(for item: LauncherItem) {
        memory.update { $0.resetRanking(of: item.id) }
        if store.database.usage.contains(where: { $0.id == item.id }) {
            store.update { $0.usage.removeAll { $0.id == item.id } }
        }
        toast("Ranking reset for “\(item.title.truncatedForFeedback)”")
    }

    func resetAllRanking() {
        memory.update { $0.resetRanking() }
        toast("Ranking reset")
    }

    func clearSearchHistory() {
        memory.update { $0.history = [] }
        historyCursor = nil
    }

    /// ↑ at the top of Everything, with an empty field or a recalled search, steps back
    /// through earlier searches; ↓ steps forward again. Returns whether it moved.
    func recallSearchHistory(_ offset: Int) -> Bool {
        guard destination == .search, section == .home, argumentLink == nil, argumentSession == nil,
            store.database.preferences.remembersSearchHistory
        else { return false }
        let history = memory.memory.history
        guard !history.isEmpty else { return false }
        let recalling = historyCursor.map { history.indices.contains($0) && history[$0] == query } ?? false
        guard isQueryBlank || recalling else { return false }
        // Only from the top of the list, so ↑ still moves through results.
        let items = orderedResults
        let atTop = items.isEmpty || items.first?.id == selectedID || selectedID == nil
        guard atTop else { return false }
        let next = (recalling ? historyCursor! : -1) + (offset < 0 ? 1 : -1)
        if next < 0 {
            guard recalling else { return false }
            historyCursor = nil
            query = ""
            return true
        }
        guard history.indices.contains(next) else { return recalling }
        query = history[next]
        historyCursor = next
        selectsQueryOnFocus = true
        focusRequest += 1
        return true
    }

    /// Whether a command opens a list, so Tab can step into it.
    static func opensScope(_ descriptor: CommandDescriptor?) -> Bool {
        if case .view? = descriptor?.mode { return true }
        return false
    }

    /// A provided row that stands for a registered command keeps that identity in snapshots (⌘K,
    /// argument fields), so it's refused rather than run unconfirmed if the command goes away.
    func markingCommandIdentity(_ item: LauncherItem) -> LauncherItem {
        guard case .provided(var ref) = item.action, !ref.has(.descriptor),
            registry.descriptor(for: ref, in: self) != nil
        else { return item }
        ref.traits.insert(.descriptor)
        var marked = item
        marked.action = .provided(ref)
        return marked
    }

    // MARK: - Sections

    /// ⌘↓ and ⌘↑: the first row of the next or previous group.
    func jumpSection(_ offset: Int) {
        guard !showActions, destination == .search else { return }
        let groups = groups.filter { !$0.items.isEmpty }
        guard !groups.isEmpty else { return }
        let current = groups.firstIndex { group in group.items.contains { $0.id == selectedID } } ?? 0
        let target = min(max(current + offset, 0), groups.count - 1)
        guard target != current || groups[target].items.first?.id != selectedID else { return }
        selectedID = groups[target].items.first?.id
    }

    // MARK: - Favorites

    func canMoveFavorite(_ item: LauncherItem, by offset: Int) -> Bool {
        let order = store.database.orderedFavoriteIDs
        guard let index = order.firstIndex(of: item.id) else { return false }
        return order.indices.contains(index + offset)
    }

    /// Move Favorite Up and Down, which also renumbers ⌘1–⌘8.
    func moveFavorite(_ item: LauncherItem, by offset: Int) {
        var order = store.database.orderedFavoriteIDs
        guard let index = order.firstIndex(of: item.id), order.indices.contains(index + offset) else { return }
        order.insert(order.remove(at: index), at: index + offset)
        if store.update({ $0.favoriteOrder = order }) {
            selectedID = item.id
        } else {
            feedback = .error(store.errorMessage ?? "Favorites couldn't be reordered.")
        }
    }

    // MARK: - Disabled commands

    /// Every command row, including disabled ones, for Settings.
    var allCommandItems: [LauncherItem] { commandItems + registry.hiddenCommandItems(in: self) }

    /// Commands that can be turned off: built-in commands and registered commands.
    func isDisableable(_ item: LauncherItem) -> Bool {
        guard !item.id.hasPrefix("fallback."), !item.id.hasPrefix("argument.") else { return false }
        if case .provided(let ref) = item.action { return ref.has(.descriptor) }
        return item.isBuiltInCommand
    }

    func isCommandEnabled(_ id: String) -> Bool { !store.database.disabledCommandIDs.contains(id) }

    /// Turns a command off or on. Off removes it from search, favorites, recents, aliases and hotkeys.
    @discardableResult
    func setCommand(_ id: String, enabled: Bool) -> Bool {
        let saved = store.update { database in
            if enabled { database.disabledCommandIDs.remove(id) } else { database.disabledCommandIDs.insert(id) }
        }
        if saved { commandCatalogDidChange() } else { feedback = .error(store.errorMessage ?? "The command couldn't be changed.") }
        return saved
    }

    func disableCommand(_ item: LauncherItem) {
        guard setCommand(item.id, enabled: false) else { return }
        toast("Disabled “\(item.title.truncatedForFeedback)”. Turn it on again in Settings › Commands.")
    }

    /// Removes disabled commands from a list of rows.
    func withoutDisabledCommands(_ items: [LauncherItem]) -> [LauncherItem] {
        let disabled = store.database.disabledCommandIDs
        guard !disabled.isEmpty else { return items }
        return items.filter { !disabled.contains($0.id) || !isDisableable($0) }
    }

    // MARK: - Fallbacks

    var webSearchQuicklink: Quicklink? {
        let links = store.database.quicklinks.filter(\.needsQuery)
        return links.first { $0.keyword.lowercased() == "web" } ?? links.first
    }

    /// The fallback id a quicklink stands for: the web search link keeps its built-in id.
    func fallbackID(for link: Quicklink) -> String {
        link.id == webSearchQuicklink?.id ? "fallback.web" : "fallback.quicklink.\(link.id)"
    }

    /// The built-in fallback rows for a search: Ask AI, each search quicklink, Search Files.
    private func builtInFallbackItems(for term: String) -> [LauncherItem] {
        var items = [
            LauncherItem(
                id: "fallback.ai", title: "Ask AI", subtitle: ai.availability.isAvailable ? "" : "Not available yet",
                symbol: "sparkles", kind: .ai, badge: "Ask AI", action: .askAI(term))
        ]
        let web = webSearchQuicklink
        let searchLinks = store.database.quicklinks.filter(\.needsQuery)
        let links = searchLinks.filter { $0.id == web?.id } + searchLinks.filter { $0.id != web?.id }
        for link in links {
            items.append(
                LauncherItem(
                    id: fallbackID(for: link), title: link.name, subtitle: Self.siteName(for: link),
                    symbol: link.id == web?.id ? "globe" : "link", kind: .quicklink, badge: "Quicklink",
                    action: .quicklink(link, term)))
        }
        if registry.provider(id: LauncherCommandProvider.registration.id) != nil {
            items.append(
                LauncherItem(
                    id: "fallback.files", title: "Search Files", subtitle: "Spotlight", symbol: "folder", kind: .file,
                    badge: "Files",
                    action: .provided(
                        ProvidedRef(
                            provider: LauncherCommandProvider.registration.id, id: LauncherCommandProvider.searchFilesID,
                            payload: term, primaryTitle: "Search Files"))))
        }
        return items
    }

    /// Every fallback row for this search, built-in then the providers'. Providers may offer
    /// different rows for different searches; these are the real ones for `term`.
    func fallbackCandidateItems(for term: String) -> [LauncherItem] {
        builtInFallbackItems(for: term) + registry.fallbackItems(for: term, in: self)
    }

    /// True once fallbacks were chosen by hand. A saved order from before the flag existed counts.
    var usesCustomFallbacks: Bool {
        store.database.preferences.customFallbacks ?? !store.database.fallbackOrder.isEmpty
    }

    /// Whether a row is on by default: Ask AI, the web search, and every provider's fallback.
    private func isDefaultFallback(_ id: String, providerIDs: Set<String>) -> Bool {
        id == "fallback.ai" || id == "fallback.web" || providerIDs.contains(id)
    }

    /// The fallbacks in use, in order, for Settings and ⌘K: the saved choice, or the defaults.
    var enabledFallbackIDs: [String] {
        guard !usesCustomFallbacks else { return store.database.fallbackOrder }
        let providerIDs = Set(registry.fallbackDescriptors(in: self).map(\.id))
        return fallbackCandidates.map(\.id).filter { isDefaultFallback($0, providerIDs: providerIDs) }
    }

    /// The fallback rows for a search, from that search's real candidates: in the saved order once
    /// chosen, otherwise the default ones in their usual order.
    func orderedFallbackItems(for term: String) -> [LauncherItem] {
        let builtIn = builtInFallbackItems(for: term)
        let provided = registry.fallbackItems(for: term, in: self)
        guard usesCustomFallbacks else {
            return builtIn.filter { isDefaultFallback($0.id, providerIDs: []) } + provided
        }
        let index = Dictionary((builtIn + provided).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return store.database.fallbackOrder.compactMap { index[$0] }
    }

    /// Every fallback the person can choose, for Settings: stable names, whatever is typed.
    var fallbackCandidates: [FallbackCandidate] {
        builtInFallbackItems(for: "").map {
            FallbackCandidate(id: $0.id, title: $0.title, symbol: $0.symbol, kind: $0.kind)
        } + registry.fallbackDescriptors(in: self)
    }

    /// The fallback a result row could be added as: a search quicklink, or a fallback row itself.
    func fallbackCandidateID(for item: LauncherItem) -> String? {
        if item.id.hasPrefix("fallback.") { return item.id }
        if case .quicklink(let link, _) = item.action, link.needsQuery, item.id.hasPrefix("quicklink.") {
            return fallbackID(for: link)
        }
        return nil
    }

    func isFallbackEnabled(_ id: String) -> Bool { enabledFallbackIDs.contains(id) }

    /// Saves a fallback order, which from then on is the person's choice.
    private func saveFallbacks(_ ids: [String]) -> Bool {
        let saved = store.update { database in
            database.fallbackOrder = ids
            database.preferences.customFallbacks = true
        }
        if !saved { feedback = .error(store.errorMessage ?? "Fallbacks couldn't be saved.") }
        return saved
    }

    @discardableResult
    func setFallback(_ id: String, enabled: Bool) -> Bool {
        var ids = enabledFallbackIDs
        if enabled {
            guard !ids.contains(id) else { return true }
            ids.append(id)
        } else {
            ids.removeAll { $0 == id }
        }
        return saveFallbacks(ids)
    }

    func canMoveFallback(_ id: String, by offset: Int) -> Bool {
        guard let index = enabledFallbackIDs.firstIndex(of: id) else { return false }
        return enabledFallbackIDs.indices.contains(index + offset)
    }

    @discardableResult
    func moveFallback(_ id: String, by offset: Int) -> Bool {
        var ids = enabledFallbackIDs
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return false }
        ids.insert(ids.remove(at: index), at: index + offset)
        let saved = saveFallbacks(ids)
        if saved, id.hasPrefix("fallback."), orderedResults.contains(where: { $0.id == id }) { selectedID = id }
        return saved
    }

    /// ⌘K entries for fallbacks: Add to or Remove from Fallbacks for a candidate row, and moving
    /// an enabled fallback row up or down.
    func fallbackActions(for item: LauncherItem) -> [ActionEntry] {
        guard let id = fallbackCandidateID(for: item) else { return [] }
        var entries: [ActionEntry] = []
        let enabled = isFallbackEnabled(id)
        entries.append(
            ActionEntry(
                id: enabled ? "fallbackRemove" : "fallbackAdd", title: enabled ? "Remove from Fallbacks" : "Add to Fallbacks",
                symbol: enabled ? "minus.circle" : "plus.circle", group: .organize, section: "Fallbacks"
            ) { [weak self] in
                guard let self, self.setFallback(id, enabled: !enabled) else { return }
                self.toast(enabled ? "Removed from Fallbacks" : "Added to Fallbacks")
            })
        guard enabled, item.id.hasPrefix("fallback.") else { return entries }
        if canMoveFallback(id, by: -1) {
            entries.append(
                ActionEntry(
                    id: "fallbackUp", title: "Move Up in Fallbacks", symbol: "arrow.up",
                    shortcut: KeyShortcut(["⌥", "⌘", "↑"]), key: .upArrow, modifiers: [.command, .option],
                    group: .organize, section: "Fallbacks"
                ) { [weak self] in self?.moveFallback(id, by: -1) })
        }
        if canMoveFallback(id, by: 1) {
            entries.append(
                ActionEntry(
                    id: "fallbackDown", title: "Move Down in Fallbacks", symbol: "arrow.down",
                    shortcut: KeyShortcut(["⌥", "⌘", "↓"]), key: .downArrow, modifiers: [.command, .option],
                    group: .organize, section: "Fallbacks"
                ) { [weak self] in self?.moveFallback(id, by: 1) })
        }
        return entries
    }

    /// Back to Ask AI, the web search and every provider's fallback.
    func resetFallbacks() {
        store.update { database in
            database.fallbackOrder = []
            database.preferences.customFallbacks = nil
        }
    }

    // MARK: - Action panel navigation

    /// The entries at the current level: the panel's, or an open submenu's.
    var currentActionEntries: [ActionEntry] { actionPath.last?.children ?? actionEntries }

    /// The entries the panel lists: the current level, or, while filtering at the top level,
    /// every matching entry including those inside submenus, titled with their path.
    func actionEntriesMatching(_ filter: String) -> [ActionEntry] {
        let entries = currentActionEntries
        let filter = filter.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return entries }
        // Entries found inside submenus are titled and identified by their path, so two submenus'
        // children with the same id stay distinct.
        func matches(_ entries: [ActionEntry], path: (title: String, id: String)?) -> [ActionEntry] {
            entries.flatMap { entry -> [ActionEntry] in
                var shown = entry
                if let path {
                    shown.title = "\(path.title) › \(entry.title)"
                    shown.id = "\(path.id)/\(entry.id)"
                }
                let own = SearchMatcher.score(filter, in: entry.title) != nil ? [shown] : []
                return own + matches(entry.children, path: (shown.title, shown.id))
            }
        }
        return matches(entries, path: nil)
    }

    /// Opens a submenu in place. → and ↩ open it; ← and esc go back.
    func openActionSubmenu(_ entry: ActionEntry) {
        guard !entry.children.isEmpty else { return }
        actionPath.append(entry)
        actionFilter = ""
        actionSelection = 0
        announceForVoiceOver(entry.title)
    }

    /// Closes the innermost submenu. Returns false at the top level.
    @discardableResult
    func closeActionSubmenu() -> Bool {
        guard let closed = actionPath.popLast() else { return false }
        actionFilter = ""
        actionSelection = currentActionEntries.firstIndex { $0.id == closed.id } ?? 0
        return true
    }

    /// ← and → in the action panel's field: → opens the highlighted submenu; ← closes the
    /// current one, while the field is empty. Otherwise the caret moves.
    func moveActionSelectionHorizontally(_ offset: Int) -> Bool {
        let entries = filteredActionEntries
        if offset > 0, entries.indices.contains(actionSelection), !entries[actionSelection].children.isEmpty {
            openActionSubmenu(entries[actionSelection])
            return true
        }
        if offset < 0, actionFilter.isEmpty { return closeActionSubmenu() }
        return false
    }

    /// ⌥↩: the entry marked as the tertiary action, if the selection has one.
    func performTertiary() {
        guard confirmation == nil, destination == .search else { return }
        let entries = showActions ? actionEntries : actions(for: selectedItem)
        guard let entry = entries.first(where: { $0.shortcut == Self.tertiaryShortcut }) else { return }
        performAction(entry)
    }

    nonisolated static let tertiaryShortcut = KeyShortcut(["⌥", "↩"])

    /// Marks the first plain item action after ↩ and ⌘↩ as ⌥↩.
    func markingTertiary(_ entries: [ActionEntry]) -> [ActionEntry] {
        var entries = entries
        if let index = entries.firstIndex(where: {
            $0.group == .item && $0.id != "primary" && $0.id != "paste" && $0.shortcut == nil && $0.children.isEmpty
        }) {
            entries[index].shortcut = Self.tertiaryShortcut
        }
        return entries
    }

    // MARK: - Arguments

    /// The arguments a row asks for before it runs: a registered command's declared ones.
    func argumentSpecs(for item: LauncherItem) -> [ArgumentSpec] {
        guard case .provided(let ref) = item.action, ref.arguments.isEmpty,
            let descriptor = registry.descriptor(for: ref, in: self)
        else { return [] }
        return Array(descriptor.arguments.prefix(ArgumentSession.maximumFields))
    }

    /// Whether running a row would need its argument fields first: a required argument with no
    /// default and no value yet.
    func needsArguments(_ item: LauncherItem) -> Bool {
        argumentSession == nil && argumentSpecs(for: item).contains { !$0.isOptional && $0.defaultValue == nil }
    }

    /// Opens a command's argument fields, the first one holding `initial`. Returns false when
    /// the row takes no arguments.
    @discardableResult
    func beginArguments(for item: LauncherItem, initial: String = "") -> Bool {
        let item = markingCommandIdentity(item)
        let specs = argumentSpecs(for: item)
        guard !specs.isEmpty, case .provided(let ref) = item.action else { return false }
        return beginArguments(item: item, specs: specs, initial: initial) { [weak self] values in
            var filled = item
            var resolved = ref
            resolved.arguments = values
            filled.action = .provided(resolved)
            self?.perform(filled)
        }
    }

    /// Opens argument fields for anything: up to three specs, run with the resolved values.
    /// Slices use this for rows that aren't registered commands, such as multi-argument quicklinks.
    @discardableResult
    func beginArguments(
        item: LauncherItem, specs: [ArgumentSpec], initial: String = "",
        run: @escaping @MainActor ([String: String]) -> Void
    ) -> Bool {
        let specs = Array(specs.prefix(ArgumentSession.maximumFields))
        guard !specs.isEmpty else { return false }
        // The fields live in the search bar: not during setup or an editor, and AI makes way.
        guard onboarding == nil, editor == nil else {
            feedback = .warning("Finish what's open first, then run “\(item.title.truncatedForFeedback)” again.")
            return false
        }
        if destination == .ai { leaveAI() }
        var values: [String: String] = [:]
        for spec in specs {
            if case .dropdown(let options) = spec.type {
                values[spec.name] = spec.defaultValue ?? (spec.isOptional ? nil : options.first?.value)
            }
        }
        if case .dropdown = specs[0].type {} else if !initial.isEmpty { values[specs[0].name] = initial }
        showActions = false
        confirmation = nil
        feedback = nil
        argumentSession = ArgumentSession(item: item, specs: specs, values: values, run: run)
        selectedID = item.id
        focusRequest += 1
        return true
    }

    func setArgumentValue(_ value: String, at index: Int) {
        guard var session = argumentSession, session.specs.indices.contains(index) else { return }
        session.values[session.specs[index].name] = value
        // Typing in a field you clicked makes it the focused one.
        session.focus = index
        argumentSession = session
    }

    /// Tab and ⇧Tab. Past the last field Tab wraps to the first.
    func moveArgumentFocus(_ offset: Int) {
        guard var session = argumentSession else { return }
        let count = session.specs.count
        session.focus = (session.focus + offset + count) % count
        session.focusToken += 1
        argumentSession = session
    }

    /// ↑ and ↓ (or ← and →) on a dropdown field choose the previous or next option.
    /// The field that holds the keyboard says so, as when it's clicked. Focus doesn't move again.
    func argumentFieldDidFocus(_ index: Int) {
        guard var session = argumentSession, session.specs.indices.contains(index), session.focus != index else { return }
        session.focus = index
        argumentSession = session
    }

    @discardableResult
    func cycleArgumentOption(_ offset: Int, at field: Int? = nil) -> Bool {
        guard var session = argumentSession else { return false }
        let index = field ?? session.focus
        guard session.specs.indices.contains(index), case .dropdown(let options) = session.specs[index].type,
            !options.isEmpty
        else { return false }
        session.focus = index
        let name = session.specs[index].name
        let current = options.firstIndex { $0.value == session.values[name] }
        let next = current.map { ($0 + offset + options.count) % options.count } ?? (offset > 0 ? 0 : options.count - 1)
        session.values[name] = options[next].value
        argumentSession = session
        return true
    }

    /// ↩ in the fields: resolves the values, then runs. A missing or invalid value says why
    /// and takes the keyboard to its field.
    func submitArguments() {
        guard let session = argumentSession else { return }
        for (index, spec) in session.specs.enumerated() {
            do {
                try spec.validate(spec.value(from: session.values[spec.name]))
            } catch {
                feedback = .warning(error.localizedDescription)
                if index != session.focus { moveArgumentFocus(index - session.focus) }
                return
            }
        }
        guard let values = try? ArgumentSpec.resolve(session.specs, typed: session.values) else { return }
        argumentSession = nil
        session.run(values)
    }

    /// Esc, or ⌫ in the empty first field: closes the fields and puts back the search.
    func cancelArguments() {
        guard argumentSession != nil else { return }
        argumentSession = nil
        feedback = nil
        synchronizeSelection()
        requestFocus()
    }

    /// ⌫ in an empty argument field steps back to the previous one, then closes the fields.
    func deleteBackwardInArguments() -> Bool {
        guard let session = argumentSession else { return false }
        if session.focus > 0 {
            moveArgumentFocus(-1)
        } else {
            cancelArguments()
        }
        return true
    }

    // MARK: - Aliases with arguments

    /// “alias ” (an alias and a space) opens the command's argument fields with the rest of the
    /// text in the first one. Returns whether it did.
    func beginArgumentsFromAlias(in input: String) -> Bool {
        guard let space = input.firstIndex(where: \.isWhitespace) else { return false }
        let alias = String(input[..<space])
        guard let targetID = store.database.aliasTarget(for: alias),
            let command = bindableCommands.first(where: { $0.id == targetID })
        else { return false }
        let rest = String(input[space...]).trimmingCharacters(in: .whitespaces)
        if case .quicklink(let link, _) = command.action, link.needsQuery {
            beginArgument(link)
            query = rest
            return true
        }
        guard !argumentSpecs(for: command).isEmpty else { return false }
        query = ""
        return beginArguments(for: command, initial: rest)
    }

    // MARK: - Window keys

    /// ⌘Esc: back to an empty Everything in one step, keeping the window open.
    func popToRoot() {
        if let draft, !draft.isNote, draft.isDirty {
            confirmation = .discardChanges
            return
        }
        if editor != nil { closeEditor(force: true) }
        showActions = false
        showShortcuts = false
        showsAttachmentPreview = false
        confirmation = nil
        argumentSession = nil
        if destination == .ai { leaveAI() }
        if argumentLink != nil { clearArgument(restoreKeyword: false) }
        if section != .home { navigate(to: .home) }
        if !query.isEmpty { query = "" }
        requestFocus()
    }

    /// Handles a launcher key. Returns whether it was used.
    func handle(_ command: LauncherKeyCommand) -> Bool {
        switch command {
        case .popToRoot:
            guard onboarding == nil else { return false }
            popToRoot()
        case .closeWindow:
            panel?.dismiss()
        case .moveDown, .moveUp:
            let offset = command == .moveDown ? 1 : -1
            if showActions {
                moveActionSelection(offset)
            } else if destination == .search, editor == nil {
                moveSelection(offset)
            } else {
                return false
            }
        }
        return true
    }

    /// Esc from the panel: one layer back, or with "Close the window" chosen, the window,
    /// unless a prompt, a panel or an editor is open, which Esc always closes first.
    func escape() {
        let preferences = store.database.preferences
        guard preferences.escapeClosesWindow, confirmation == nil, !showShortcuts, !showActions,
            !showsAttachmentPreview, editor == nil, onboarding == nil
        else {
            goBack()
            return
        }
        panel?.dismiss()
    }
}

/// Launcher-owned rows that dispatch through the registry: the Search Files fallback. Its
/// registration also makes apps, quicklinks and snippets able to hold aliases and hotkeys.
@MainActor
final class LauncherCommandProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(
        id: "launcher", bindablePrefixes: ["app.", "quicklink.", "snippet."]
    ) { LauncherCommandProvider() }
    nonisolated static let searchFilesID = "searchFiles"

    var id: String { Self.registration.id }

    init() {}

    func commands(in model: LauncherModel) -> [CommandDescriptor] { [] }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        guard ref.id == Self.searchFilesID else { return }
        model.navigate(to: .files)
        model.query = ref.payload ?? ""
    }
}
