import AppKit
import SwiftUI
import Testing

@testable import OpenRay

/// A provider that records what the launcher asks of it. It isn't in `CommandProviders.all`,
/// so its commands can't hold bindings; the writing commands cover that path.
@MainActor
final class FakeCommandProvider: CommandProvider {
    /// Accepts every `test.` id. Tests opt in with `CuratedCommand.$registrations.withValue(…)`.
    nonisolated static let registration = CommandProviderRegistration(id: "test.fake", bindablePrefixes: ["test."]) {
        FakeCommandProvider()
    }
    static let scope = ProvidedScope(
        id: "test.list", provider: "test.fake", title: "Fake List", symbol: "list.bullet", kind: .note,
        placeholder: "Search fake rows", summary: "Rows for tests", itemNoun: "row", showsPreview: true)
    static let gridScope = ProvidedScope(
        id: "test.grid", provider: "test.fake", title: "Fake Grid", symbol: "square.grid.3x3", kind: .command,
        placeholder: "Search tiles", style: .grid, ranksItems: false)
    static let wideGridScope = ProvidedScope(
        id: "test.grid3", provider: "test.fake", title: "Three Columns", symbol: "square.grid.3x3", kind: .command,
        placeholder: "Search tiles", style: .grid, ranksItems: false, columns: 3)
    static let confirmation = CommandConfirmation(
        question: "Really run it?", detail: "Fake commands can't be undone.", confirmTitle: "Run")

    let id = "test.fake"
    var performed: [String] = []
    var performedArguments: [[String: String]] = []
    var edited: [String] = []
    var deleted: [String] = []
    var rows = ["Alpha Row", "Beta Row", "Gamma Row"]
    var liveRows: [String] = []
    var liveQueries: [String] = []
    var available = true
    /// Dynamic commands, as a script folder would list them: `test.script.<name>`.
    var scripts: [String] = []
    var imageRows = false
    var secondaryPerformed: [String] = []
    var failDeletion = false
    var scopeArguments: [[String: String]] = []
    /// Commands the provider has withdrawn since a row or prompt was built.
    var withdrawn: Set<String> = []
    /// Replaces test.confirm's question, as an update to the command would.
    var confirmQuestion: String? = nil
    /// Makes test.run ask first, as if the provider started requiring it.
    var confirmRun = false
    /// Adds commands that opt out of bindings: one under the accepted prefix, one under a curated id.
    var optOuts = false

    init() {}

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        allCommands.filter { !withdrawn.contains($0.id) }
    }

    private var allCommands: [CommandDescriptor] {
        var confirmation = Self.confirmation
        if let confirmQuestion { confirmation.question = confirmQuestion }
        let optOutCommands =
            optOuts
            ? [
                CommandDescriptor(
                    id: "test.optout", title: "Yak Opt Out", subtitle: "Never bound", kind: .command, symbol: "nosign",
                    mode: .noView, isBindable: false),
                CommandDescriptor(
                    id: "ai.summarize", title: "Yak Curated Opt Out", subtitle: "A curated id, opted out",
                    kind: .command, symbol: "nosign", mode: .noView, isBindable: false),
            ] : []
        return [
            CommandDescriptor(
                id: "test.run", title: "Zebra Fake Run", subtitle: "Runs without a view", kind: .command, symbol: "bolt",
                keywords: ["quagga"], mode: .noView, detail: "Does the yodel thing", isUnavailable: !available,
                confirmation: confirmRun ? Self.confirmation : nil),
            CommandDescriptor(
                id: "test.open", title: "Zebra Fake List", subtitle: "Opens a list", kind: .note, symbol: "list.bullet",
                mode: .view(.provided(Self.scope))),
            CommandDescriptor(
                id: "test.hidden", title: "Zebra Hidden", subtitle: "Only by hotkey", kind: .command,
                symbol: "eye.slash", mode: .noView, showsInRoot: false),
            CommandDescriptor(
                id: "test.args", title: "Zebra Needs Argument", subtitle: "Takes a name", kind: .command,
                symbol: "character.cursor.ibeam",
                arguments: [
                    ArgumentSpec(name: "name", placeholder: "Name"),
                    ArgumentSpec(name: "greeting", placeholder: "Greeting", isOptional: true, defaultValue: "Hello"),
                ],
                mode: .noView),
            CommandDescriptor(
                id: "test.confirm", title: "Yak Confirm", subtitle: "Asks first", kind: .command,
                symbol: "exclamationmark.triangle", mode: .noView, confirmation: confirmation),
            CommandDescriptor(
                id: "test.scoped", title: "Yak Scoped List", subtitle: "Opens a filtered list", kind: .note,
                symbol: "line.3.horizontal.decrease",
                arguments: [ArgumentSpec(name: "filter", placeholder: "Filter", isOptional: true, defaultValue: "all")],
                mode: .view(.provided(Self.scope))),
        ]
            + scripts.map { name in
                CommandDescriptor(
                    id: "test.script.\(name)", title: "Script \(name)", subtitle: "A script", kind: .command,
                    symbol: "terminal", mode: .noView)
            } + optOutCommands
    }

    func rootItems(for query: String, in model: LauncherModel) -> [LauncherItem] {
        guard query == "two plus two" else { return [] }
        return [
            LauncherItem(
                id: "test.answer", title: "Four", subtitle: "An answer", symbol: "equal", kind: .calculator,
                badge: "Answer", action: .provided(ProvidedRef(provider: id, id: "answer", copyText: "4", rank: 2_000, traits: [.paste])))
        ]
    }

    func row(_ title: String) -> LauncherItem {
        LauncherItem(
            id: "test.row.\(title)", title: title, subtitle: "A fake row", symbol: "doc", kind: .note, badge: "Fake",
            action: .provided(
                ProvidedRef(
                    provider: id, id: title, copyText: title, primaryTitle: "Use Row",
                    traits: [.favorite, .paste, .delete, .edit])))
    }

    /// A row whose ⌘↩ isn't text paste: it has no `.paste` trait and its own secondary action.
    func imageRow() -> LauncherItem {
        LauncherItem(
            id: "test.image", title: "Image Row", subtitle: "A picture", symbol: "photo", kind: .file, badge: "Image",
            action: .provided(ProvidedRef(provider: id, id: "Image Row", payload: "image")))
    }

    func item(withID id: String, in model: LauncherModel) -> LauncherItem? {
        guard id.hasPrefix("test.row.") else { return nil }
        let title = String(id.dropFirst("test.row.".count))
        return rows.contains(title) ? row(title) : nil
    }

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        scopeArguments.append(scope.arguments)
        if scope == Self.gridScope { return ["Zulu", "Alpha"].map(row) }
        if scope == Self.wideGridScope { return (1...7).map { row("Tile \($0)") } }
        return rows.map(row) + (imageRows ? [imageRow()] : [])
    }

    var providesLiveItems: Bool { true }
    var liveGroupTitle: String { "Fake Live" }

    func liveItems(for query: String, scope: ProvidedScope?, in model: LauncherModel) async -> [LauncherItem] {
        liveQueries.append(query)
        return liveRows.map(row)
    }

    func fallbackItems(for query: String, in model: LauncherModel) -> [LauncherItem] {
        [
            LauncherItem(
                id: "shout", title: "Shout", subtitle: query, symbol: "megaphone", kind: .command, badge: "Fake",
                action: .provided(ProvidedRef(provider: id, id: "shout", payload: query)))
        ]
    }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        performed.append(ref.id)
        performedArguments.append(ref.arguments)
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        ref.id == "test.run" ? "Run Fake" : nil
    }

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        [
            ActionEntry(
                id: "fake.share", title: "Share", symbol: "square.and.arrow.up", group: .item, section: "Share",
                children: [
                    ActionEntry(id: "fake.share.mail", title: "Mail", symbol: "envelope", group: .item) { [weak self] in
                        self?.performed.append("mail")
                    }
                ]
            ) { [weak self] in self?.performed.append("share") }
        ]
    }

    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview? {
        ProvidedPreview(content: AnyView(Text(item.title)), metadata: [("Name", item.title)])
    }

    func secondaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        ref.payload == "image" ? model.pasteTitle("Paste Image to") : model.textPasteTitle(for: item)
    }

    func performSecondary(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        if ref.payload == "image" { secondaryPerformed.append(ref.id) } else { model.pasteText(of: item) }
    }

    func itemNoun(for ref: ProvidedRef) -> String { "Row" }

    func deletion(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedDeletion? {
        .store { [weak self, weak model] in
            guard let self else { return false }
            if self.failDeletion {
                model?.feedback = .error("The fake store refused.")
                return false
            }
            self.deleted.append(ref.id)
            self.rows.removeAll { $0 == ref.id }
            return true
        }
    }

    func edit(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) { edited.append(ref.id) }
}

@MainActor
struct CommandRegistryTests {
    private func model(_ providers: [any CommandProvider]? = nil, ai availability: AIAvailability = .available)
        -> LauncherModel
    {
        let engine = TestAIEngine()
        engine.availability = availability
        let registry = providers.map { CommandRegistry(providers: $0) } ?? CommandRegistry()
        return LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine),
            pasteboard: NSPasteboard.withUniqueName(), registry: registry)
    }

    private func ref(_ item: LauncherItem?) -> ProvidedRef? {
        if case .provided(let ref)? = item?.action { ref } else { nil }
    }

    // MARK: Root search and dispatch

    @Test func registeredCommandsJoinRootSearchAndDispatchThroughTheRegistry() throws {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        model.query = "zebra fake run"
        let item = try #require(model.results.first)
        #expect(item.id == "test.run")
        #expect(ref(item)?.provider == "test.fake")
        #expect(item.isBuiltInCommand && item.canFavorite)
        #expect(!item.supportsPaste && !item.canDelete && !item.canEdit && item.copyText == nil)
        #expect(model.groups.first { $0.id == "commands" || $0.id == "top" }?.items.first?.id == "test.run")
        #expect(model.primaryTitle(for: item) == "Run Fake")
        #expect(item.primaryActionTitle == "Run Command")
        #expect(model.secondaryTitle(for: item) == nil)
        model.performSelected()
        #expect(fake.performed == ["test.run"])

        // Keywords and the description are searchable; the description explains the match.
        model.query = "quagga"
        #expect(model.results.map(\.id) == ["test.run"])
        model.query = "yodel"
        #expect(model.results.first?.id == "test.run")
        #expect(model.results.first?.subtitle == "Does the yodel thing")
    }

    @Test func hiddenCommandsStayOutOfSearchButResolveAsFavorites() {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        model.query = "zebra hidden"
        #expect(!model.results.contains { $0.id == "test.hidden" })
        #expect(model.registry.hiddenCommandItems(in: model).map(\.id) == ["test.hidden"])
        #expect(model.store.toggleFavorite("test.hidden"))
        #expect(model.store.toggleFavorite("test.row.Beta Row"))
        let favorites = model.favoriteItems.map(\.id)
        #expect(favorites.contains("test.hidden"))
        #expect(favorites.contains("test.row.Beta Row"))
    }

    @Test func unavailableCommandsCarryTheTrait() {
        let fake = FakeCommandProvider()
        fake.available = false
        let model = model([fake])
        defer { model.stop() }
        let item = model.commandItems.first { $0.id == "test.run" }
        #expect(ref(item)?.has(.unavailable) == true)
        #expect(ref(model.commandItems.first { $0.id == "test.open" })?.has(.unavailable) == false)
    }

    @Test func requiredArgumentsAreCheckedBeforeTheProviderRuns() throws {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        let item = try #require(model.commandItems.first { $0.id == "test.args" })
        // Without its required argument, the command opens its argument fields instead of running.
        model.perform(item)
        #expect(fake.performed.isEmpty)
        #expect(model.argumentSession?.item.id == "test.args")
        model.cancelArguments()
        // A stale row that skips the fields is still refused by the registry.
        model.registry.perform(item, ref: ProvidedRef(provider: "test.fake", id: "test.args", traits: [.descriptor]), in: model)
        #expect(fake.performed.isEmpty)
        #expect(model.feedback?.style == .warning)
        var filled = item
        filled.action = .provided(ProvidedRef(provider: "test.fake", id: "test.args", arguments: ["name": "Ada"]))
        model.perform(filled)
        #expect(fake.performed == ["test.args"])
        #expect(fake.performedArguments == [["name": "Ada", "greeting": "Hello"]])
    }

    @Test func answerRowsUseTheirFixedRankAndFallbacksArePrefixed() throws {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        model.query = "two plus two"
        #expect(model.results.first?.id == "test.answer")
        let answer = try #require(model.results.first)
        #expect(answer.copyText == "4")
        #expect(answer.supportsPaste)
        let fallbacks = try #require(model.groups.first { $0.id == "fallbacks" })
        #expect(fallbacks.items.map(\.id) == ["fallback.ai", "fallback.web", "fallback.shout"])
        let shout = try #require(fallbacks.items.last)
        // Fallback rows stand in for the query, so they can't be favorites.
        #expect(!shout.canFavorite)
        model.perform(shout)
        #expect(fake.performed == ["shout"])
    }

    @Test func liveRowsArriveInTheirOwnGroupAndNeverTakeTheTopHit() async throws {
        let fake = FakeCommandProvider()
        fake.liveRows = ["Zebra Live One", "Zebra Live Two"]
        let model = model([fake])
        defer { model.stop() }
        model.query = "zebra live"
        try await waitForLiveItems(model)
        #expect(fake.liveQueries.last == "zebra live")
        let groups = model.groups
        let live = try #require(groups.first { $0.id == "live.test.fake" })
        #expect(live.title == "Fake Live")
        #expect(live.items.map(\.id) == ["test.row.Zebra Live One", "test.row.Zebra Live Two"])
        #expect(live.items.filter { !$0.isLiveResult }.isEmpty)
        #expect(groups.first { $0.id == "top" }?.items.first?.isLiveResult != true)
        model.query = ""
        #expect(model.providedLiveItems.isEmpty)
    }

    // MARK: Provided scopes

    @Test func viewCommandsPushTheProvidersScope() throws {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        model.query = "zebra fake list"
        #expect(model.selectedItem?.id == "test.open")
        #expect(model.primaryTitle(for: try #require(model.selectedItem)) == "Open Fake List")
        model.performSelected()
        #expect(fake.performed.isEmpty)
        #expect(model.section == .provided(FakeCommandProvider.scope))
        #expect(model.section.title == "Fake List")
        #expect(model.section.placeholder == "Search fake rows")
        #expect(model.section.showsPreview)
        #expect(model.section.itemNoun == "row")
        #expect(model.store.database.usage.contains { $0.id == "test.open" })
        #expect(model.results.map(\.title) == ["Alpha Row", "Beta Row", "Gamma Row"])
        #expect(model.groups.map(\.id) == ["test.list"])
        model.query = "beta"
        #expect(model.results.map(\.title) == ["Beta Row"])
        // Esc leaves the scope and puts back the search that found it.
        model.goBack()
        #expect(model.section == .home)
        #expect(model.query == "zebra fake list")
    }

    @Test func unrankedGridScopesKeepTheProvidersOrderAndUseArrows() {
        let model = model([FakeCommandProvider()])
        defer { model.stop() }
        model.navigate(to: .provided(FakeCommandProvider.gridScope))
        model.query = "nothing matches this"
        #expect(model.results.map(\.title) == ["Zulu", "Alpha"])
        #expect(model.groups.first?.style == .grid)
        #expect(model.arrowsMoveSelection)
    }

    @Test func providedRowsGetPreviewEditDeleteAndStructuredActions() throws {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        model.navigate(to: .provided(FakeCommandProvider.scope))
        let item = try #require(model.results.first { $0.title == "Beta Row" })
        #expect(item.canFavorite && item.canDelete && item.canEdit && item.supportsPaste)
        #expect(item.copyText == "Beta Row")
        #expect(item.primaryActionTitle == "Use Row")
        #expect(model.primaryTitle(for: item) == "Use Row")
        #expect(model.secondaryTitle(for: item) != nil)
        let itemRef = try #require(ref(item))
        let preview = try #require(model.registry.preview(for: item, ref: itemRef, in: model))
        #expect(preview.metadata.map(\.value) == ["Beta Row"])
        #expect(preview.content != nil)

        model.selectedID = item.id
        let actions = model.actions(for: item)
        let ids = actions.map(\.id)
        #expect(ids.first == "primary")
        #expect(ids.contains("paste"))
        let share = try #require(actions.first { $0.id == "fake.share" })
        #expect(share.section == "Share")
        #expect(share.children.map(\.title) == ["Mail"])
        #expect(ids.firstIndex(of: "fake.share")! < ids.firstIndex(of: "edit")!)
        #expect(actions.first { $0.id == "delete" }?.title == "Delete Row…")
        #expect(actions.first { $0.id == "primary" }?.symbol == "doc.on.doc")
        share.children[0].perform()
        #expect(fake.performed == ["mail"])

        model.edit(item)
        #expect(fake.edited == ["Beta Row"])
        #expect(model.editor == nil)

        #expect(model.store.toggleFavorite(item.id))
        model.store.recordUse(of: item.id)
        #expect(model.delete(item))
        #expect(fake.deleted == ["Beta Row"])
        #expect(!model.store.database.favoriteIDs.contains(item.id))
        #expect(!model.store.database.usage.contains { $0.id == item.id })
        #expect(model.results.map(\.title) == ["Alpha Row", "Gamma Row"])
    }

    @Test func aRowFromAMissingProviderReportsInsteadOfRunning() {
        let model = model([])
        defer { model.stop() }
        let orphan = LauncherItem(
            id: "gone", title: "Gone", subtitle: "", symbol: "questionmark", badge: "Gone",
            action: .provided(ProvidedRef(provider: "nobody", id: "gone")))
        model.perform(orphan)
        #expect(model.feedback?.style == .error)
    }

    // MARK: Bindings

    @Test func bindingSupportIsARegistryQueryThatNeedsNoProviderInstance() {
        let registration = CommandProviderRegistration(
            id: "test.registration", bindableIDs: ["test.one"], bindablePrefixes: ["script."]
        ) { FakeCommandProvider() }
        #expect(CuratedCommand.supports("test.one", registrations: [registration]))
        #expect(CuratedCommand.supports("script.backup", registrations: [registration]))
        #expect(!CuratedCommand.supports("test.two", registrations: [registration]))
        #expect(CuratedCommand.supports("section.notes", registrations: []))
        // The original twenty need no registration.
        #expect(CuratedCommand.supports("ai.summarize", registrations: []))
        let writing = CommandProviders.all.first { $0.id == "ai.writing" }
        #expect(
            writing?.bindableIDs == ["ai.summarize", "ai.rewrite", "ai.proofread", "ai.shorten", "ai.actionItems"])
        #expect(Set(CommandProviders.all.map(\.id)).count == CommandProviders.all.count)
    }

    @Test func aliasAndHotkeyReachAProvidedCommand() throws {
        let model = model()
        defer { model.stop() }
        let command = try #require(model.bindableCommands.first { $0.id == "ai.summarize" })
        #expect(ref(command)?.provider == "ai.writing")
        let shortcut = CommandShortcut(keyCode: 1, modifiers: [.control, .option])
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: "ai.summarize", alias: "sum", shortcut: shortcut)))
        #expect(model.boundShortcut(for: command) == shortcut)
        #expect(model.aliasChip(for: command) == "sum")

        // The alias wins the whole query and runs through the registry.
        model.query = "SUM"
        #expect(model.results.map(\.id) == ["ai.summarize"])
        #expect(model.actions(for: model.selectedItem).contains { $0.id == "assign" })
        model.performSelected()
        #expect(model.destination == .ai)
        #expect(model.ai.action == .summarize)
        #expect(model.store.database.usage.first?.id == "ai.summarize")

        // The hotkey uses the same dispatch.
        model.leaveAI()
        model.ai.newConversation(action: .chat)
        model.ai.open(.chat)
        #expect(model.destination == .search)
        model.performBoundCommand(targetID: "ai.summarize")
        #expect(model.destination == .ai)
        #expect(model.ai.action == .summarize)
        #expect(!model.runsWithoutPanel(command))
    }

    @Test func storedBindingsForProvidedCommandsSurviveReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayRegistry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        let shortcut = CommandShortcut(keyCode: 2, modifiers: [.control, .option])
        #expect(store.saveCommandBinding(CommandBinding(targetID: "ai.rewrite", alias: "rw", shortcut: shortcut)))
        // Unknown targets can't be saved, and are dropped when a library is read.
        #expect(!store.saveCommandBinding(CommandBinding(targetID: "test.run", alias: "tr")))
        let reopened = LibraryStore(fileURL: url)
        #expect(reopened.database.aliasTarget(for: "rw") == "ai.rewrite")
        #expect(reopened.database.binding(for: "ai.rewrite")?.shortcut == shortcut)
    }

    // MARK: The writing commands, ported

    @Test(arguments: [AIAvailability.available, .notEnabled])
    func writingCommandRowsMatchTheBuiltInRowsTheyReplace(availability: AIAvailability) {
        let model = model(ai: availability)
        defer { model.stop() }
        let available = availability.isAvailable
        // The ported writing commands only, by their provider; other AI commands may join later.
        let rows = model.commandItems.filter { ref($0)?.provider == AIWritingCommandProvider.registration.id }
        #expect(rows.map(\.id) == AIAction.allCases.filter { $0 != .chat }.map { "ai.\($0.id)" })
        for (row, action) in zip(rows, AIAction.allCases.filter { $0 != .chat }) {
            #expect(row.title == action.title)
            #expect(row.subtitle == (available ? LauncherModel.aiCommandSubtitle : "Not available yet"))
            #expect(row.symbol == action.kindSymbol)
            #expect(row.kind == .ai)
            #expect(row.badge == "AI command")
            #expect(row.keywords == "AI writing text " + action.subtitle)
            #expect(row.isBuiltInCommand && row.canFavorite)
            #expect(!row.supportsPaste && !row.canDelete && !row.canEdit)
            #expect(row.primaryActionTitle == "Run Command")
            #expect(model.primaryTitle(for: row) == "Run Command")
            #expect(model.secondaryTitle(for: row) == nil)
            #expect(model.actions(for: row).first?.symbol == "sparkles")
            #expect(ref(row)?.has(.unavailable) == !available)
        }
        // Found by what it does, a row says so; an unavailable one keeps saying it's unavailable.
        model.query = "meeting notes"
        let match = model.results.first { $0.id == "ai.actionItems" }
        #expect(match?.subtitle == (available ? AIAction.actionItems.subtitle : "Not available yet"))
    }

    @Test func bindableCommandsKeepTheirOrderAfterThePort() {
        let model = model()
        defer { model.stop() }
        // The original twenty lead, in order; later registrations may follow them.
        let ids = model.bindableCommands.map(\.id)
        #expect(Array(ids.prefix(CuratedCommand.targetIDs.count)) == CuratedCommand.targetIDs)
        let writing = AIAction.allCases.filter { $0 != .chat }.map { "ai.\($0.id)" }
        #expect(model.commandItems.map(\.id).filter(writing.contains) == writing)
    }

    private func waitForLiveItems(_ model: LauncherModel) async throws {
        for _ in 0..<200 where model.isLoadingProvidedItems {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!model.isLoadingProvidedItems)
    }
}
