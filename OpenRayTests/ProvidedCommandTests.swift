import AppKit
import Testing

@testable import OpenRay

/// A live provider whose searches wait until the test releases them, to check ordering,
/// independence and cancellation without timing guesses.
@MainActor
final class SuspendingLiveProvider: CommandProvider {
    let id: String
    lazy var scope = ProvidedScope(
        id: "\(id).scope", provider: id, title: "Slow \(id)", symbol: "hourglass", kind: .command,
        placeholder: "Search slowly", itemNoun: "result")
    var started: [String] = []
    var loadingGroup = false
    /// Queries that find nothing.
    var emptyQueries: Set<String> = []
    private var waiting: [(query: String, continuation: CheckedContinuation<Void, Never>)] = []

    init(id: String) { self.id = id }

    func commands(in model: LauncherModel) -> [CommandDescriptor] { [] }

    var providesLiveItems: Bool { true }
    var liveGroupTitle: String { "Live \(id)" }

    func liveItems(for query: String, scope: ProvidedScope?, in model: LauncherModel) async -> [LauncherItem] {
        started.append(query)
        await withCheckedContinuation { waiting.append((query, $0)) }
        if emptyQueries.contains(query) { return [] }
        return [
            LauncherItem(
                id: "\(id).\(query)", title: "\(query) \(id)", subtitle: "", symbol: "bolt", badge: "Live",
                action: .provided(ProvidedRef(provider: id, id: query)))
        ]
    }

    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup]? {
        guard loadingGroup else { return nil }
        return [
            LauncherResultGroup(
                id: "pending", title: "Pending", isLoading: model.isLoadingProvidedItems, items: items)
        ]
    }

    func release(_ query: String) {
        while let index = waiting.firstIndex(where: { $0.query == query }) {
            waiting.remove(at: index).continuation.resume()
        }
    }

    func releaseAll() {
        for entry in waiting { entry.continuation.resume() }
        waiting = []
    }
}

/// Rows stored in `library.json` (window layout records), deleted in the same save as their
/// favorite and usage records.
@MainActor
final class LibraryRowsProvider: CommandProvider {
    let id = "test.library"

    init() {}

    func commands(in model: LauncherModel) -> [CommandDescriptor] { [] }

    func rows(in model: LauncherModel) -> [LauncherItem] {
        model.store.database.windowLayouts.map { record in
            LauncherItem(
                id: "test.layout.\(record.id)", title: "Layout \(record.id.uuidString.prefix(4))", subtitle: "",
                symbol: "rectangle.3.group", badge: "Layout",
                action: .provided(ProvidedRef(provider: id, id: record.id.uuidString, traits: [.favorite, .delete])))
        }
    }

    func item(withID id: String, in model: LauncherModel) -> LauncherItem? { rows(in: model).first { $0.id == id } }

    func deletion(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedDeletion? {
        .library { database in database.windowLayouts.removeAll { $0.id.uuidString == ref.id } }
    }
}

/// A scope that words its own empty state.
@MainActor
final class QuietProvider: CommandProvider {
    static let scope = ProvidedScope(
        id: "test.quiet.scope", provider: "test.quiet", title: "Quiet", symbol: "moon", kind: .command,
        placeholder: "Search")
    let id = "test.quiet"

    init() {}

    func commands(in model: LauncherModel) -> [CommandDescriptor] { [] }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?
    {
        ProvidedEmptyState(title: "All quiet", detail: query.isEmpty ? "Nothing scheduled." : "No “\(query)”.")
    }
}

/// Records what a real Carbon registration would do, without touching the system.
final class RecordingHotKeyBackend: GlobalHotKeyBackend {
    var active: [UInt32: CommandShortcut] = [:]

    func installHandler(_ action: @escaping (UInt32) -> Void) throws {}

    func register(_ shortcut: CommandShortcut, identifier: UInt32) throws {
        guard !active.values.contains(shortcut) else { throw LibraryValidationError("Already registered.") }
        active[identifier] = shortcut
    }

    func unregister(identifier: UInt32) { active[identifier] = nil }
    func removeHandler() {}
}

@MainActor
struct ProvidedCommandTests {
    private func model(
        _ providers: [any CommandProvider], store: LibraryStore = LibraryStore(fileURL: nil), hotKey: GlobalHotKey? = nil
    ) -> LauncherModel {
        LauncherModel(
            store: store, ai: AIChatModel(engine: TestAIEngine()), pasteboard: NSPasteboard.withUniqueName(),
            registry: CommandRegistry(providers: providers), hotKey: hotKey)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for a condition")
    }

    /// Lets queued main-actor work run, so a wrongly published result would show up.
    private func settle() async throws {
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(2)) }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayProvided-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Makes every later save fail: an atomic write can't replace a non-empty directory.
    private func blockWrites(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appending(path: "blocker"))
    }

    private func unblockWrites(to url: URL) throws { try FileManager.default.removeItem(at: url) }

    // MARK: Arguments (#3)

    @Test func argumentsReachTheProviderResolvedAndScopesCarryThem() throws {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        let command = try #require(model.commandItems.first { $0.id == "test.args" })
        var typed = command
        typed.action = .provided(ProvidedRef(provider: "test.fake", id: "test.args", arguments: ["name": "  Ada  "]))
        model.perform(typed)
        // Trimmed, with the optional argument's default filled in.
        #expect(fake.performedArguments == [["name": "Ada", "greeting": "Hello"]])

        typed.action = .provided(
            ProvidedRef(provider: "test.fake", id: "test.args", arguments: ["name": "Bo", "greeting": "  Hi "]))
        model.perform(typed)
        #expect(fake.performedArguments.last == ["name": "Bo", "greeting": "Hi"])

        let scoped = try #require(model.commandItems.first { $0.id == "test.scoped" })
        model.perform(scoped)
        #expect(model.section == .provided(FakeCommandProvider.scope))
        #expect(model.section.providedScope?.arguments == ["filter": "all"])
        _ = model.results
        #expect(fake.scopeArguments.last == ["filter": "all"])
    }

    // MARK: Live rows (#5)

    @Test func liveProvidersRunIndependentlyAndStaleAnswersAreDropped() async throws {
        let alpha = SuspendingLiveProvider(id: "alpha")
        let beta = SuspendingLiveProvider(id: "beta")
        let model = model([alpha, beta])
        defer {
            alpha.releaseAll()
            beta.releaseAll()
            model.stop()
        }
        model.query = "zebra one"
        // Both start at once; neither waits for the other.
        try await waitUntil { alpha.started == ["zebra one"] && beta.started == ["zebra one"] }
        beta.release("zebra one")
        try await waitUntil { model.providedLiveItems["beta"] != nil }
        #expect(model.providedLiveItems["alpha"] == nil)
        #expect(model.pendingLiveProviderIDs == ["alpha"])

        // A new query drops what's shown and ignores the late answer for the old one.
        model.query = "zebra two"
        #expect(model.providedLiveItems.isEmpty)
        alpha.release("zebra one")
        try await settle()
        #expect(model.providedLiveItems["alpha"] == nil)
        try await waitUntil { alpha.started.last == "zebra two" && beta.started.last == "zebra two" }
        beta.release("zebra two")
        alpha.release("zebra two")
        try await waitUntil { !model.isLoadingProvidedItems }
        // Groups follow registration order, whichever answered first.
        #expect(model.groups.map(\.id).filter { $0.hasPrefix("live.") } == ["live.alpha", "live.beta"])
        #expect(model.groups.first { $0.id == "live.alpha" }?.items.map(\.id) == ["alpha.zebra two"])
    }

    @Test func leavingSearchStopsPendingLiveWork() async throws {
        let alpha = SuspendingLiveProvider(id: "alpha")
        let model = model([alpha])
        defer {
            alpha.releaseAll()
            model.stop()
        }
        model.query = "zebra hide"
        try await waitUntil { alpha.started == ["zebra hide"] }
        model.panelDidHide()
        #expect(!model.isLoadingProvidedItems)
        alpha.release("zebra hide")
        try await settle()
        #expect(model.providedLiveItems.isEmpty)

        model.resumeSearch()
        try await waitUntil { alpha.started.count == 2 }
        model.openAI(.chat)
        #expect(!model.isLoadingProvidedItems)
        alpha.releaseAll()
        try await settle()
        #expect(model.providedLiveItems.isEmpty)

        model.leaveAI()
        try await waitUntil { alpha.started.count == 3 }
        model.query = String(repeating: "z", count: 513)
        #expect(!model.isLoadingProvidedItems)
    }

    // MARK: Secondary action (#6)

    @Test func providersOwnTheSecondaryActionOnEveryPath() throws {
        let fake = FakeCommandProvider()
        fake.imageRows = true
        let model = model([fake])
        defer { model.stop() }
        model.navigate(to: .provided(FakeCommandProvider.scope))
        let image = try #require(model.results.first { $0.id == "test.image" })
        #expect(!image.supportsPaste)
        // Action bar label and ⌘↩ from the keyboard.
        #expect(model.secondaryTitle(for: image) == "Paste Image to Your App")
        model.selectedID = image.id
        model.pasteSelected()
        #expect(fake.secondaryPerformed == ["Image Row"])
        // ⌘K.
        let entry = try #require(model.actions(for: image).first { $0.id == "paste" })
        #expect(entry.title == "Paste Image to Your App")
        entry.perform()
        #expect(fake.secondaryPerformed == ["Image Row", "Image Row"])
        #expect(model.clipboard.readText() == nil)
    }

    @Test func textPasteStaysTheDefaultSecondaryAction() throws {
        let model = model([FakeCommandProvider()])
        defer { model.stop() }
        model.navigate(to: .provided(FakeCommandProvider.scope))
        let row = try #require(model.results.first { $0.title == "Beta Row" })
        #expect(model.secondaryTitle(for: row) == "Paste to Your App")
        model.selectedID = row.id
        model.pasteSelected()
        // The isolated test pasteboard gets the text; nothing reaches another app.
        #expect(model.clipboard.readText() == "Beta Row")
        #expect(model.feedback?.style == .info)
    }

    // MARK: Deletion (#7)

    @Test func libraryBackedDeletesSaveTheRowAndItsHistoryTogether() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        let kept = WindowLayoutRecord()
        let doomed = WindowLayoutRecord()
        #expect(store.update { $0.windowLayouts = [kept, doomed] })
        let provider = LibraryRowsProvider()
        let model = model([provider], store: store)
        defer { model.stop() }
        let item = try #require(provider.item(withID: "test.layout.\(doomed.id)", in: model))
        #expect(item.canDelete)
        #expect(store.toggleFavorite(item.id))
        store.recordUse(of: item.id)

        // A failed save changes nothing: the row, its favorite and its usage all stay.
        try blockWrites(to: url)
        model.confirm(.delete(item))
        #expect(model.feedback?.style == .error)
        #expect(store.database.windowLayouts.count == 2)
        #expect(store.database.favoriteIDs.contains(item.id))

        try unblockWrites(to: url)
        model.confirm(.delete(item))
        #expect(model.feedback?.style == .success)
        #expect(store.database.windowLayouts == [kept])
        #expect(!store.database.favoriteIDs.contains(item.id))
        #expect(!store.database.usage.contains { $0.id == item.id })
        #expect(LibraryStore(fileURL: url).database.windowLayouts == [kept])
    }

    @Test func storeDeletesKeepProviderFeedbackAndRetryTheirCleanup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        let fake = FakeCommandProvider()
        let model = model([fake], store: store)
        defer { model.stop() }
        model.navigate(to: .provided(FakeCommandProvider.scope))
        let beta = try #require(model.results.first { $0.title == "Beta Row" })
        #expect(store.toggleFavorite(beta.id))
        store.recordUse(of: beta.id)

        // The provider's own explanation survives.
        fake.failDeletion = true
        model.confirm(.delete(beta))
        #expect(model.feedback?.text == "The fake store refused.")
        #expect(fake.rows.contains("Beta Row"))

        // The row is gone from its store, but the library can't be saved: say so, and retry.
        fake.failDeletion = false
        try blockWrites(to: url)
        model.confirm(.delete(beta))
        #expect(fake.deleted == ["Beta Row"])
        #expect(model.feedback?.style == .warning)
        #expect(store.pendingForgottenIDs == [beta.id])
        #expect(!model.favoriteItems.contains { $0.id == beta.id })

        try unblockWrites(to: url)
        store.recordUse(of: "section.notes")
        #expect(store.pendingForgottenIDs.isEmpty)
        #expect(!store.database.favoriteIDs.contains(beta.id))
        #expect(!store.database.usage.contains { $0.id == beta.id })
    }

    // MARK: Grids and confirmations (#8)

    @Test func gridGroupsShareTheirColumnsWithKeyboardNavigation() throws {
        let model = model([FakeCommandProvider()])
        defer { model.stop() }
        model.navigate(to: .provided(FakeCommandProvider.wideGridScope))
        let group = try #require(model.groups.first)
        #expect(group.columns == 3)
        #expect(LauncherModel.columns(for: group) == 3)
        #expect(group.tile != nil)
        let ids = group.items.map(\.id)
        model.selectedID = ids[0]
        model.moveSelection(1)
        #expect(model.selectedID == ids[3])
        #expect(model.moveSelectionHorizontally(1))
        #expect(model.selectedID == ids[4])
        // Window layouts keep their own tiles and four columns.
        model.navigate(to: .windows)
        let windows = try #require(model.groups.first)
        #expect(windows.tile == nil)
        #expect(LauncherModel.columns(for: windows) == 4)
    }

    @Test func confirmationsAskFirstFromSearchAndFromHotkeys() throws {
        try CuratedCommand.$registrations.withValue(CommandProviders.all + [FakeCommandProvider.registration]) {
            let fake = FakeCommandProvider()
            let model = model([fake])
            defer { model.stop() }
            let command = try #require(model.commandItems.first { $0.id == "test.confirm" })
            model.perform(command)
            #expect(fake.performed.isEmpty)
            #expect(model.confirmation?.id.hasPrefix("provided.test.confirm.") == true)
            #expect(model.confirmation?.question == "Really run it?")
            #expect(model.confirmation?.confirmTitle == "Run")
            model.performSelected()
            #expect(fake.performed == ["test.confirm"])
            #expect(model.confirmation == nil)

            let shortcut = CommandShortcut(keyCode: 15, modifiers: [.control, .option])
            #expect(model.store.saveCommandBinding(CommandBinding(targetID: "test.confirm", shortcut: shortcut)))
            #expect(model.runsWithoutPanel(command))
            model.performBoundCommand(targetID: "test.confirm")
            #expect(fake.performed == ["test.confirm"])
            #expect(model.confirmation?.id.hasPrefix("provided.test.confirm.") == true)
            model.performSelected()
            #expect(fake.performed == ["test.confirm", "test.confirm"])
        }
    }

    // MARK: Bindings (#4, #9)

    @Test func nonLegacyBindingsSaveReopenAndRun() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let shortcut = CommandShortcut(keyCode: 4, modifiers: [.control, .option])
        try CuratedCommand.$registrations.withValue(CommandProviders.all + [FakeCommandProvider.registration]) {
            let fake = FakeCommandProvider()
            let first = model([fake], store: LibraryStore(fileURL: url))
            defer { first.stop() }
            // One catalog, in registration order, hidden commands in their declared place.
            let fakeIDs = fake.commands(in: first).map(\.id)
            #expect(first.bindableCommands.map(\.id).filter { $0.hasPrefix("test.") } == fakeIDs)
            #expect(fakeIDs.firstIndex(of: "test.hidden")! < fakeIDs.firstIndex(of: "test.args")!)
            try first.validateCommandBinding(CommandBinding(targetID: "test.hidden", alias: "hid", shortcut: shortcut))
            #expect(first.store.saveCommandBinding(CommandBinding(targetID: "test.hidden", alias: "hid", shortcut: shortcut)))

            let reopened = LibraryStore(fileURL: url)
            #expect(reopened.database.binding(for: "test.hidden")?.alias == "hid")
            let model = model([fake], store: reopened)
            defer { model.stop() }
            model.query = "HID"
            #expect(model.results.map(\.id) == ["test.hidden"])
            model.performSelected()
            #expect(fake.performed == ["test.hidden"])
            model.performBoundCommand(targetID: "test.hidden")
            #expect(fake.performed == ["test.hidden", "test.hidden"])
        }
        // Without its registration, the binding isn't accepted, as before the registry.
        #expect(LibraryStore(fileURL: url).database.binding(for: "test.hidden") == nil)
    }

    @Test func hotkeysFollowTheCatalogAsCommandsComeAndGo() {
        CuratedCommand.$registrations.withValue(CommandProviders.all + [FakeCommandProvider.registration]) {
            let backend = RecordingHotKeyBackend()
            let fake = FakeCommandProvider()
            fake.scripts = ["backup"]
            let model = model([fake], hotKey: GlobalHotKey(backend: backend, reservedShortcuts: { [] }))
            defer { model.stop() }
            model.isStarted = true
            let shortcut = CommandShortcut(keyCode: 11, modifiers: [.control, .option])
            #expect(model.store.saveCommandBinding(CommandBinding(targetID: "test.script.backup", shortcut: shortcut)))
            #expect(backend.active.values.contains(shortcut))

            // The script disappears: its binding stays saved, but it stops holding the shortcut.
            fake.scripts = []
            model.commandCatalogDidChange()
            #expect(!backend.active.values.contains(shortcut))
            #expect(model.store.database.binding(for: "test.script.backup")?.shortcut == shortcut)
            #expect(!model.registrableCommandBindings.contains { $0.targetID == "test.script.backup" })
            // A missing command can't take a new binding, but its old one can be cleared.
            #expect(throws: LibraryValidationError.self) {
                try model.validateCommandBinding(CommandBinding(targetID: "test.script.gone", alias: "gone"))
            }

            // It comes back, and so does its shortcut.
            fake.scripts = ["backup"]
            model.commandCatalogDidChange()
            #expect(backend.active.values.contains(shortcut))
        }
    }

    // MARK: Empty and loading scopes (#11)

    @Test func emptyAndLoadingScopesExplainThemselves() async throws {
        let slow = SuspendingLiveProvider(id: "slow")
        let model = model([slow])
        defer {
            slow.releaseAll()
            model.stop()
        }
        model.navigate(to: .provided(slow.scope))
        try await waitUntil { slow.started == [""] }
        #expect(model.isLoadingProvidedItems)
        #expect(model.isAwaitingResults)
        #expect(model.groups.isEmpty)
        #expect(model.providedEmptyState(for: slow.scope).title == "Searching Slow slow…")

        // A provider's own loading group stays while it's pending, even with no rows.
        slow.loadingGroup = true
        #expect(model.groups.map(\.id) == ["pending"])
        #expect(model.groups.first?.isLoading == true)
        slow.loadingGroup = false

        slow.release("")
        try await waitUntil { !model.isLoadingProvidedItems }
        #expect(model.results.map(\.id) == ["slow."])
        slow.loadingGroup = true
        #expect(model.groups.first?.isLoading == false)
        slow.loadingGroup = false

        slow.emptyQueries = ["zzz"]
        model.query = "zzz"
        try await waitUntil { slow.started.last == "zzz" }
        slow.release("zzz")
        try await waitUntil { !model.isLoadingProvidedItems }
        #expect(model.groups.isEmpty)
        #expect(model.providedEmptyState(for: slow.scope).title == "No matches for “zzz”")
        model.query = ""
        try await waitUntil { slow.started.count == 3 }
        #expect(model.providedEmptyState(for: slow.scope).title == "Searching Slow slow…")
    }

    @Test func providersCanWordTheirOwnEmptyState() {
        let model = model([QuietProvider()])
        defer { model.stop() }
        model.navigate(to: .provided(QuietProvider.scope))
        #expect(model.groups.isEmpty)
        #expect(
            model.providedEmptyState(for: QuietProvider.scope)
                == ProvidedEmptyState(title: "All quiet", detail: "Nothing scheduled."))
    }
}
