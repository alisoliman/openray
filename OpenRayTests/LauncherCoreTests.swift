import AppKit
import Testing

@testable import OpenRay

/// A provider whose command takes arguments and whose rows carry nested actions.
@MainActor
final class ArgumentsProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(id: "test.args", bindablePrefixes: ["test.args."]) {
        ArgumentsProvider()
    }
    let id = "test.args"
    var runs: [[String: String]] = []
    var opened: [String] = []

    init() {}

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: "test.args.translate", title: "Quokka Translate", subtitle: "Three arguments", kind: .command,
                symbol: "character.book.closed",
                arguments: [
                    ArgumentSpec(name: "text", placeholder: "Text"),
                    ArgumentSpec(name: "token", placeholder: "Token", type: .password, isOptional: true),
                    ArgumentSpec(
                        name: "language", placeholder: "Language",
                        type: .dropdown([.init(title: "German", value: "de"), .init(title: "French", value: "fr")])),
                ],
                mode: .noView),
            CommandDescriptor(
                id: "test.args.menu", title: "Quokka Menu", subtitle: "Nested actions", kind: .command, symbol: "list.bullet",
                mode: .noView),
        ]
    }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) { runs.append(ref.arguments) }

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        guard ref.id == "test.args.menu" else { return [] }
        return [
            ActionEntry(
                id: "openWith", title: "Open With", symbol: "arrow.up.forward.app", group: .item, section: "Open",
                children: [
                    ActionEntry(id: "openWith.preview", title: "Preview", symbol: "eye", group: .item) { [weak self] in
                        self?.opened.append("Preview")
                    },
                    ActionEntry(id: "openWith.textEdit", title: "TextEdit", symbol: "doc", group: .item) { [weak self] in
                        self?.opened.append("TextEdit")
                    },
                ]
            ) { [weak self] in self?.opened.append("default") }
        ]
    }
}

@MainActor
struct LauncherCoreTests {
    private func model(_ providers: [any CommandProvider]? = nil, store: LibraryStore = LibraryStore(fileURL: nil))
        -> LauncherModel
    {
        LauncherModel(
            store: store, ai: AIChatModel(engine: TestAIEngine()), pasteboard: NSPasteboard.withUniqueName(),
            registry: providers.map { CommandRegistry(providers: $0) } ?? CommandRegistry())
    }

    private func withRegistrations<T>(_ body: () throws -> T) rethrows -> T {
        try CuratedCommand.$registrations.withValue(
            CommandProviders.all + [ArgumentsProvider.registration], operation: body)
    }

    // MARK: Aliases

    @Test func aliasPrefixesRankAboveTitlesAndAnExactAliasWins() {
        let model = model()
        defer { model.stop() }
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: "section.notes", alias: "nn")))
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: "section.snippets", alias: "nnsnip")))
        // A prefix of two aliases: the shorter (closer) alias ranks first.
        model.query = "nn"
        #expect(model.results.map(\.id) == ["section.notes"])
        model.query = "nns"
        #expect(model.results.first?.id == "section.snippets")
        model.files.stop()
    }

    @Test func appsQuicklinksAndSnippetsTakeAliases() throws {
        let model = model()
        defer { model.stop() }
        let snippet = Snippet(name: "Sign-off", keyword: "", content: "Best, A.")
        #expect(model.store.save(snippet))
        let row = try #require(model.snippetItems.first)
        #expect(model.canBind(row))
        #expect(model.actions(for: row).contains { $0.id == "assign" })
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: row.id, alias: "bye")))
        #expect(model.aliasChip(for: row) == "bye")
        #expect(model.bindableCommands.contains { $0.id == row.id })
        model.query = "bye"
        #expect(model.results.map(\.id) == [row.id])
        // Settings lists an unbound one only when it was opened for it.
        let link = try #require(model.quicklinkItems.first)
        #expect(!model.bindingRows(focusing: nil).contains { $0.id == link.id })
        #expect(model.bindingRows(focusing: link.id).contains { $0.id == link.id })
    }

    @Test func anAliasAndASpaceOpenTheCommandsArguments() throws {
        try withRegistrations {
            let provider = ArgumentsProvider()
            let model = model([provider])
            defer { model.stop() }
            #expect(model.store.saveCommandBinding(CommandBinding(targetID: "test.args.translate", alias: "tr")))
            model.query = "tr "
            let session = try #require(model.argumentSession)
            #expect(session.item.id == "test.args.translate")
            #expect(session.specs.count == 3)
            #expect(model.query.isEmpty)
        }
    }

    // MARK: Arguments

    @Test func argumentFieldsResolveThroughTheirSpecsAndFillTheRef() throws {
        let provider = ArgumentsProvider()
        let model = model([provider])
        defer { model.stop() }
        let command = try #require(model.commandItems.first { $0.id == "test.args.translate" })
        // ↩ on a command that still needs an argument opens the fields.
        model.perform(command)
        var session = try #require(model.argumentSession)
        #expect(model.results.map(\.id) == ["test.args.translate"])
        // The required dropdown starts on its first option.
        #expect(session.values["language"] == "de")
        // Running with the text missing says why and keeps the fields.
        model.submitArguments()
        #expect(provider.runs.isEmpty)
        #expect(model.feedback?.style == .warning)
        #expect(model.argumentSession?.focus == 0)

        model.setArgumentValue("  Good morning ", at: 0)
        model.moveArgumentFocus(1)
        #expect(model.argumentSession?.focus == 1)
        model.setArgumentValue("s3cret", at: 1)
        model.handleTab()
        #expect(model.argumentSession?.focus == 2)
        #expect(model.cycleArgumentOption(1))
        session = try #require(model.argumentSession)
        #expect(session.values["language"] == "fr")
        // ⇧Tab wraps back.
        model.moveArgumentFocus(1)
        #expect(model.argumentSession?.focus == 0)
        model.submitArguments()
        #expect(model.argumentSession == nil)
        #expect(provider.runs == [["text": "Good morning", "token": "s3cret", "language": "fr"]])
    }

    @Test func argumentFieldsCloseWithEscOrDeleteAndCapAtThree() throws {
        let model = model([ArgumentsProvider()])
        defer { model.stop() }
        let command = try #require(model.commandItems.first { $0.id == "test.args.translate" })
        #expect(model.beginArguments(for: command))
        model.moveArgumentFocus(1)
        #expect(model.deleteBackwardOnEmptyField())
        #expect(model.argumentSession?.focus == 0)
        #expect(model.deleteBackwardOnEmptyField())
        #expect(model.argumentSession == nil)
        #expect(model.beginArguments(for: command))
        model.goBack()
        #expect(model.argumentSession == nil)
        // Slices can open fields for anything, at most three.
        let many = (1...5).map { ArgumentSpec(name: "a\($0)", placeholder: "A\($0)") }
        var ran: [String: String]?
        model.beginArguments(item: command, specs: many, initial: "first") { ran = $0 }
        #expect(model.argumentSession?.specs.count == 3)
        model.setArgumentValue("second", at: 1)
        model.setArgumentValue("third", at: 2)
        model.submitArguments()
        #expect(ran == ["a1": "first", "a2": "second", "a3": "third"])
    }

    // MARK: Fallbacks

    @Test func fallbacksDefaultToAskAIAndTheWebThenFollowTheChosenOrder() throws {
        let model = model()
        defer { model.stop() }
        model.query = "zzzz nothing matches"
        model.files.stop()
        #expect(model.groups.last?.items.map(\.id) == ["fallback.ai", "fallback.web"])
        #expect(model.fallbackCandidates.map(\.id).contains("fallback.files"))
        // Adding one makes the order the person's own.
        #expect(model.setFallback("fallback.files", enabled: true))
        #expect(model.usesCustomFallbacks)
        #expect(model.store.database.fallbackOrder == ["fallback.ai", "fallback.web", "fallback.files"])
        #expect(model.moveFallback("fallback.files", by: -2))
        #expect(model.groups.last?.items.map(\.id) == ["fallback.files", "fallback.ai", "fallback.web"])
        #expect(model.setFallback("fallback.ai", enabled: false))
        #expect(model.groups.last?.items.map(\.id) == ["fallback.files", "fallback.web"])
        // Removing every one leaves none, not the defaults.
        #expect(model.setFallback("fallback.files", enabled: false))
        #expect(model.setFallback("fallback.web", enabled: false))
        #expect(!model.groups.contains { $0.id == "fallbacks" })
        model.resetFallbacks()
        #expect(model.groups.last?.items.map(\.id) == ["fallback.ai", "fallback.web"])
    }

    @Test func fallbackActionsAddRemoveAndMove() throws {
        let model = model()
        defer { model.stop() }
        let github = try #require(model.quicklinkItems.first { $0.title == "Search GitHub" })
        let add = try #require(model.actions(for: github).first { $0.id == "fallbackAdd" })
        #expect(add.section == "Fallbacks")
        add.perform()
        let id = model.fallbackID(for: try #require(model.store.database.quicklinks.first { $0.keyword == "gh" }))
        #expect(model.enabledFallbackIDs == ["fallback.ai", "fallback.web", id])
        model.query = "zzzz nothing"
        model.files.stop()
        let row = try #require(model.groups.last?.items.last)
        #expect(row.id == id)
        let actions = model.actions(for: row)
        #expect(actions.contains { $0.id == "fallbackUp" && $0.shortcut?.caps == ["⌥", "⌘", "↑"] })
        #expect(!actions.contains { $0.id == "fallbackDown" })
        actions.first { $0.id == "fallbackUp" }?.perform()
        #expect(model.enabledFallbackIDs == ["fallback.ai", id, "fallback.web"])
        model.actions(for: row).first { $0.id == "fallbackRemove" }?.perform()
        #expect(!model.enabledFallbackIDs.contains(id))
    }

    @Test func theSearchFilesFallbackSearchesFilesForTheQuery() throws {
        let model = model()
        defer { model.stop() }
        #expect(model.setFallback("fallback.files", enabled: true))
        model.query = "quarterly report"
        let row = try #require(model.groups.last?.items.first { $0.id == "fallback.files" })
        model.perform(row)
        #expect(model.section == .files)
        #expect(model.query == "quarterly report")
        model.files.stop()
    }

    // MARK: Ranking and history

    @Test func whatYouPickForAQueryRanksFirstNextTime() throws {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        model.query = "zebra fake"
        model.files.stop()
        let before = model.results.map(\.id)
        // The shorter title matches more closely, so Run comes first.
        #expect(Array(before.prefix(2)) == ["test.run", "test.open"])
        let pick = try #require(model.results.first { $0.id == "test.open" })
        model.perform(pick)
        model.navigate(to: .home)
        model.query = "zebra fake"
        model.files.stop()
        #expect(model.results.first?.id == "test.open")
        #expect(model.memory.memory.pickCount(of: "test.open", for: "Zebra  FAKE") == 1)
        // Reset Ranking forgets it, and the recent use with it.
        let reset = try #require(model.actions(for: pick).first { $0.id == "resetRanking" })
        reset.perform()
        #expect(model.memory.memory.pickCount(of: "test.open", for: "zebra fake") == 0)
        #expect(!model.store.database.usage.contains { $0.id == "test.open" })
        model.query = "zebra fake"
        model.files.stop()
        #expect(model.results.map(\.id) == before)
        // Searching it was remembered, for ↑.
        #expect(model.memory.memory.history.first == "zebra fake")
    }

    @Test func upInAnEmptyFieldRecallsEarlierSearches() throws {
        let model = model()
        defer { model.stop() }
        for search in ["clipboard", "notes"] {
            model.query = search
            model.files.stop()
            model.perform(try #require(model.results.first))
            model.navigate(to: .home)
        }
        #expect(model.memory.memory.history == ["notes", "clipboard"])
        #expect(model.query.isEmpty)
        model.moveSelection(-1)
        #expect(model.query == "notes")
        model.moveSelection(-1)
        #expect(model.query == "clipboard")
        model.moveSelection(1)
        #expect(model.query == "notes")
        model.moveSelection(1)
        #expect(model.query.isEmpty)
        model.files.stop()
        model.clearSearchHistory()
        #expect(model.memory.memory.history.isEmpty)
    }

    @Test func launcherMemoryNormalizesQueriesAndKeepsItsLimits() {
        var memory = LauncherMemory()
        memory.recordPick(of: "a", for: "  Café  Notes ")
        #expect(memory.pickCount(of: "a", for: "cafe notes") == 1)
        for index in 0..<(LauncherMemory.historyLimit + 5) { memory.recordSearch("query \(index)") }
        #expect(memory.history.count == LauncherMemory.historyLimit)
        memory.recordSearch("QUERY 60")
        #expect(memory.history.first == "QUERY 60")
        #expect(memory.history.filter { LauncherMemory.normalize($0) == "query 60" }.count == 1)
        memory.resetRanking(of: "a")
        #expect(!memory.hasLearned("a"))
    }

    // MARK: Disabled commands

    @Test func aDisabledCommandLeavesSearchFavoritesAliasesAndHotkeys() throws {
        let model = model()
        defer { model.stop() }
        let notes = try #require(model.commandItems.first { $0.id == "section.notes" })
        #expect(model.isDisableable(notes))
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: "section.notes", alias: "nt")))
        let disable = try #require(model.actions(for: notes).first { $0.id == "disable" })
        #expect(model.actions(for: notes).contains { $0.id == "configure" && $0.section == "Command" })
        disable.perform()
        #expect(!model.isCommandEnabled("section.notes"))
        model.query = "notes"
        model.files.stop()
        #expect(!model.results.contains { $0.id == "section.notes" })
        model.query = "nt"
        #expect(!model.results.contains { $0.id == "section.notes" })
        #expect(!model.favoriteItems.contains { $0.id == "section.notes" })
        #expect(!model.bindableCommands.contains { $0.id == "section.notes" })
        // Settings still lists it, to turn it back on.
        #expect(model.commandCatalog.flatMap(\.commands).contains { $0.id == "section.notes" })
        #expect(model.setCommand("section.notes", enabled: true))
        model.query = "nt"
        #expect(model.results.map(\.id) == ["section.notes"])
        model.files.stop()
    }

    // MARK: Action panel

    @Test func submenusOpenWithReturnOrRightAndCloseWithLeftOrEsc() throws {
        let provider = ArgumentsProvider()
        let model = model([provider])
        defer { model.stop() }
        model.query = "quokka menu"
        model.files.stop()
        #expect(model.selectedItem?.id == "test.args.menu")
        model.showActions = true
        let index = try #require(model.filteredActionEntries.firstIndex { $0.id == "openWith" })
        #expect(model.filteredActionEntries[index].section == "Open")
        model.actionSelection = index
        // ↩ opens the submenu rather than running the parent.
        model.performActionSelection()
        #expect(model.showActions)
        #expect(model.actionPath.map(\.id) == ["openWith"])
        #expect(model.filteredActionEntries.map(\.id) == ["openWith.preview", "openWith.textEdit"])
        // Esc closes the submenu first, then the panel.
        model.goBack()
        #expect(model.actionPath.isEmpty)
        #expect(model.showActions)
        model.actionSelection = index
        #expect(model.moveActionSelectionHorizontally(1))
        #expect(model.actionPath.count == 1)
        model.actionFilter = "text"
        #expect(model.filteredActionEntries.map(\.id) == ["openWith.textEdit"])
        // ← moves the caret while there's a filter, and closes the submenu once it's empty.
        #expect(!model.moveActionSelectionHorizontally(-1))
        model.actionFilter = ""
        #expect(model.moveActionSelectionHorizontally(-1))
        #expect(model.actionPath.isEmpty)
        // Searching from the top reaches submenu entries, titled with their path.
        model.actionFilter = "preview"
        #expect(model.filteredActionEntries.map(\.title) == ["Open With › Preview"])
        model.performActionSelection()
        #expect(!model.showActions)
        #expect(provider.opened == ["Preview"])
        model.goBack()
        #expect(!model.showActions)
    }

    @Test func theThirdActionRunsWithOptionReturn() throws {
        let model = model()
        defer { model.stop() }
        model.query = "2+2"
        model.files.stop()
        let calculation = try #require(model.selectedItem)
        #expect(calculation.id == "calculation")
        let actions = model.actions(for: calculation)
        let marked = actions.filter { $0.shortcut == LauncherModel.tertiaryShortcut }
        #expect(marked.map(\.id) == ["copyExpression"])
        // ⌥↩ runs it without opening ⌘K.
        model.performTertiary()
        #expect(model.clipboard.readText() == "2+2")
    }

    // MARK: Navigation

    @Test func commandArrowsJumpBetweenSections() throws {
        let model = model()
        defer { model.stop() }
        model.query = "s"
        model.files.stop()
        let groups = model.groups.filter { !$0.items.isEmpty }
        #expect(groups.count >= 2)
        model.selectedID = groups[0].items[0].id
        model.jumpSection(1)
        #expect(model.selectedID == groups[1].items[0].id)
        model.jumpSection(-1)
        #expect(model.selectedID == groups[0].items[0].id)
        model.jumpSection(-1)
        #expect(model.selectedID == groups[0].items[0].id)
    }

    @Test func favoritesMoveUpAndDown() throws {
        let model = model()
        defer { model.stop() }
        let order = model.store.database.orderedFavoriteIDs
        let second = try #require(model.favoriteItems.first { $0.id == order[1] })
        #expect(model.canMoveFavorite(second, by: -1))
        model.actions(for: second).first { $0.id == "favoriteUp" }?.perform()
        #expect(model.store.database.orderedFavoriteIDs.prefix(2) == [order[1], order[0]])
        let last = try #require(model.favoriteItems.last)
        #expect(!model.actions(for: last).contains { $0.id == "favoriteDown" })
    }

    @Test func tabStepsIntoAProvidersList() throws {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        model.query = "zebra fake list"
        model.files.stop()
        model.handleTab()
        #expect(model.section == .provided(FakeCommandProvider.scope))
    }

    @Test func windowKeysMapToCommandsOnlyWhereTheyApply() {
        #expect(LauncherKeyCommand.command(keyCode: 53, modifiers: .command, vim: false) == .popToRoot)
        #expect(LauncherKeyCommand.command(keyCode: 13, modifiers: .command, vim: false) == .closeWindow)
        #expect(LauncherKeyCommand.command(keyCode: 38, modifiers: .control, vim: false) == nil)
        #expect(LauncherKeyCommand.command(keyCode: 38, modifiers: .control, vim: true) == .moveDown)
        #expect(LauncherKeyCommand.command(keyCode: 40, modifiers: .control, vim: true) == .moveUp)
        #expect(LauncherKeyCommand.command(keyCode: 53, modifiers: [], vim: true) == nil)
        #expect(LauncherKeyCommand.command(keyCode: 13, modifiers: [.command, .shift], vim: true) == nil)
    }

    @Test func commandEscapePopsToAnEmptyEverything() {
        let model = model([FakeCommandProvider()])
        defer { model.stop() }
        model.navigate(to: .provided(FakeCommandProvider.scope))
        model.query = "beta"
        model.showActions = true
        #expect(model.handle(.popToRoot))
        #expect(model.section == .home)
        #expect(model.query.isEmpty)
        #expect(!model.showActions)
        // Vim keys move the selection.
        model.query = "s"
        model.files.stop()
        let first = model.selectedItem?.id
        #expect(model.handle(.moveDown))
        #expect(model.selectedID != first)
    }

    @Test func escapeGoesBackUnlessClosingIsChosen() {
        let model = model()
        defer { model.stop() }
        model.navigate(to: .notes)
        model.escape()
        #expect(model.section == .home)
        #expect(model.store.update { $0.preferences.escapeBehavior = .closeWindow })
        model.navigate(to: .notes)
        model.showActions = true
        // A panel still closes first.
        model.escape()
        #expect(!model.showActions)
        #expect(model.section == .notes)
    }

    @Test func preferencesDefaultToTheirPreviousBehavior() {
        let preferences = AppPreferences()
        #expect(preferences.popToRootDelay == .seconds90)
        #expect(!preferences.escapeClosesWindow)
        #expect(!preferences.usesVimNavigation)
        #expect(preferences.screen == .mouse)
        #expect(preferences.size == .standard)
        #expect(!preferences.primaryActionPastes)
        #expect(preferences.launcherHotKeyShortcut == LauncherHotKey.optionSpace.shortcut)
        #expect(preferences.customFallbacks == nil)
        #expect(!preferences.hyper.isEnabled)
        var legacy = AppPreferences()
        legacy.rememberLastQuery = false
        #expect(legacy.popToRootDelay == .immediately)
        #expect(PopToRootDelay.never.interval == nil)
        #expect(PopToRootDelay.minutes3.interval == 180)
    }
}
