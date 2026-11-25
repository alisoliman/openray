import AppKit
import Testing

@testable import OpenRay

/// Rows backed by `library.json` that are also commands, so deleting one withdraws a command
/// that may hold a hotkey.
@MainActor
final class LayoutCommandProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(id: "test.layouts", bindablePrefixes: ["test."]) {
        LayoutCommandProvider()
    }
    static let scope = ProvidedScope(
        id: "test.layouts.scope", provider: "test.layouts", title: "Layouts", symbol: "rectangle.3.group",
        kind: .window, placeholder: "Search layouts")
    let id = "test.layouts"

    init() {}

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        model.store.database.windowLayouts.map { record in
            CommandDescriptor(
                id: "test.layout.\(record.id)", title: "Apply Layout", subtitle: "", kind: .window,
                symbol: "rectangle.3.group", mode: .noView)
        }
    }

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        model.store.database.windowLayouts.map { record in
            LauncherItem(
                id: "test.layout.\(record.id)", title: "Layout", subtitle: "", symbol: "rectangle.3.group", badge: "Layout",
                action: .provided(ProvidedRef(provider: id, id: record.id.uuidString, traits: [.favorite, .delete])))
        }
    }

    func deletion(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedDeletion? {
        .library { database in database.windowLayouts.removeAll { $0.id.uuidString == ref.id } }
    }
}

/// A list scope whose provider groups part of it as a grid without naming a tile renderer.
@MainActor
final class GridGroupProvider: CommandProvider {
    static let scope = ProvidedScope(
        id: "test.mixed", provider: "test.mixed", title: "Mixed", symbol: "square.grid.2x2", kind: .command,
        placeholder: "Search")
    let id = "test.mixed"

    init() {}

    func commands(in model: LauncherModel) -> [CommandDescriptor] { [] }

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        (1...6).map { index in
            LauncherItem(
                id: "test.mixed.\(index)", title: "Tile \(index)", subtitle: "", symbol: "square", badge: "Tile",
                action: .provided(ProvidedRef(provider: id, id: "\(index)")))
        }
    }

    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup]? {
        [LauncherResultGroup(id: "tiles", title: "Tiles", style: .grid, items: items, columns: 3)]
    }
}

/// Fixes from the Step 0 re-review (`_orch/reviews/step0-rereview.md`).
@MainActor
struct Step0FollowUpTests {
    private func model(
        _ providers: [any CommandProvider], store: LibraryStore = LibraryStore(fileURL: nil), hotKey: GlobalHotKey? = nil
    ) -> LauncherModel {
        LauncherModel(
            store: store, ai: AIChatModel(engine: TestAIEngine()), pasteboard: NSPasteboard.withUniqueName(),
            registry: CommandRegistry(providers: providers), hotKey: hotKey)
    }

    private func withTestRegistrations<T>(_ body: () throws -> T) rethrows -> T {
        try CuratedCommand.$registrations.withValue(
            CommandProviders.all + [FakeCommandProvider.registration, LayoutCommandProvider.registration], operation: body)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayFollowUp-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func blockWrites(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appending(path: "blocker"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for a condition")
    }

    // MARK: Confirmation

    @Test func aHotkeyConfirmationOverTheClipboardOptInIsAnsweredNotTurnOn() {
        withTestRegistrations {
            let fake = FakeCommandProvider()
            let model = model([fake])
            defer { model.stop() }
            #expect(model.store.saveCommandBinding(
                CommandBinding(targetID: "test.confirm", shortcut: CommandShortcut(keyCode: 15, modifiers: [.control, .option]))))
            model.navigate(to: .clipboard)
            #expect(model.showsClipboardOptIn)
            model.performBoundCommand(targetID: "test.confirm")
            #expect(model.confirmation?.id == "provided.test.confirm")
            #expect(fake.performed.isEmpty)
            // Return answers the question shown in the opt-in bar; it doesn't turn on clipboard history.
            #expect(model.confirmFromReturn(isRepeat: false))
            #expect(fake.performed == ["test.confirm"])
            #expect(!model.store.database.preferences.clipboardEnabled)
            #expect(model.showsClipboardOptIn)
        }
    }

    @Test func onboardingShowsAConfirmationAndReturnAnswersIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeCommandProvider()
        let model = model([fake], store: LibraryStore(fileURL: directory.appending(path: "library.json")))
        defer { model.stop() }
        model.beginOnboardingIfNeeded()
        #expect(model.onboarding == .shortcut)
        let command = try #require(model.commandItems.first { $0.id == "test.confirm" })
        model.perform(command)
        #expect(model.confirmation != nil)
        model.performSelected()
        #expect(fake.performed == ["test.confirm"])
        // Answering didn't also advance onboarding.
        #expect(model.onboarding == .shortcut)
    }

    @Test func heldReturnNeverApprovesTheQuestionItAsked() throws {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        model.query = "yak confirm"
        #expect(model.selectedItem?.id == "test.confirm")
        // The first press asks.
        model.performSelected()
        #expect(model.confirmation != nil)
        // Its autorepeats are swallowed, however many arrive.
        for _ in 0..<3 { #expect(model.confirmFromReturn(isRepeat: true)) }
        #expect(fake.performed.isEmpty)
        #expect(model.confirmation != nil)
        // A fresh press answers.
        #expect(model.confirmFromReturn(isRepeat: false))
        #expect(fake.performed == ["test.confirm"])
        // With nothing pending, Return isn't handled here.
        #expect(!model.confirmFromReturn(isRepeat: false))
    }

    @Test func approvalRechecksThatTheCommandStillExistsAndStillAsks() throws {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        let command = try #require(model.commandItems.first { $0.id == "test.confirm" })

        model.perform(command)
        fake.withdrawn = ["test.confirm"]
        model.performSelected()
        #expect(fake.performed.isEmpty)
        #expect(model.feedback?.style == .error)

        fake.withdrawn = []
        model.perform(command)
        fake.confirmQuestion = "Something else entirely?"
        model.performSelected()
        #expect(fake.performed.isEmpty)
        #expect(model.feedback?.style == .warning)

        // Asked again with the current question, it runs.
        model.perform(command)
        #expect(model.confirmation?.question == "Something else entirely?")
        model.performSelected()
        #expect(fake.performed == ["test.confirm"])
    }

    @Test func aStaleActionPanelRowCantSkipTheQuestion() throws {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        let run = try #require(model.commandItems.first { $0.id == "test.run" })
        let snapshot = try #require(model.actions(for: run).first { $0.id == "primary" })
        // The command now asks first: the old snapshot asks too.
        fake.confirmRun = true
        snapshot.perform()
        #expect(fake.performed.isEmpty)
        #expect(model.confirmation?.id == "provided.test.run")
        model.confirmation = nil
        // The command is gone: the old snapshot can't run it.
        fake.withdrawn = ["test.run"]
        snapshot.perform()
        #expect(fake.performed.isEmpty)
        #expect(model.confirmation == nil)
        #expect(model.feedback?.style == .error)
    }

    // MARK: #4 Hotkeys of deleted commands

    @Test func deletingALibraryBackedCommandReleasesItsHotkeyAndItsConflicts() throws {
        try withTestRegistrations {
            let backend = RecordingHotKeyBackend()
            let store = LibraryStore(fileURL: nil)
            let record = WindowLayoutRecord()
            #expect(store.update { $0.windowLayouts = [record] })
            let model = model(
                [LayoutCommandProvider()], store: store, hotKey: GlobalHotKey(backend: backend, reservedShortcuts: { [] }))
            defer { model.stop() }
            model.isStarted = true
            let commandID = "test.layout.\(record.id)"
            let shortcut = CommandShortcut(keyCode: 37, modifiers: [.control, .option])
            #expect(store.saveCommandBinding(CommandBinding(targetID: commandID, shortcut: shortcut)))
            #expect(backend.active.values.contains(shortcut))

            model.navigate(to: .provided(LayoutCommandProvider.scope))
            let row = try #require(model.results.first)
            model.confirm(.delete(row))
            #expect(store.database.windowLayouts.isEmpty)
            // Released at once, without waiting for another catalog change.
            #expect(!backend.active.values.contains(shortcut))
            // Its saved shortcut isn't a conflict for another command while it's gone.
            #expect(store.database.binding(for: commandID)?.shortcut == shortcut)
            let other = CommandBinding(targetID: "section.notes", shortcut: shortcut)
            #expect(!model.bindingWarnings(for: other).contains { $0.contains("also assigned") })
        }
    }

    // MARK: #5 Live searches

    @Test func aQueryReplacedInTheSameTurnNeverReachesTheProvider() async throws {
        let slow = SuspendingLiveProvider(id: "slow")
        let model = model([slow])
        defer {
            slow.releaseAll()
            model.stop()
        }
        model.query = "zebra first"
        model.query = "zebra second"
        try await waitUntil { !slow.started.isEmpty }
        try await Task.sleep(for: .milliseconds(20))
        #expect(slow.started == ["zebra second"])
    }

    // MARK: #7 Pending cleanup

    @Test func pendingCleanupSurvivesQuittingAndAppliesOnTheNextLaunch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let fake = FakeCommandProvider()
        let store = LibraryStore(fileURL: url)
        let model = model([fake], store: store)
        defer { model.stop() }
        model.navigate(to: .provided(FakeCommandProvider.scope))
        let beta = try #require(model.results.first { $0.title == "Beta Row" })
        #expect(store.toggleFavorite(beta.id))
        store.recordUse(of: beta.id)

        try blockWrites(to: url)
        model.confirm(.delete(beta))
        #expect(store.pendingForgottenIDs == [beta.id])
        let sidecar = try #require(store.pendingCleanupURL)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))

        // Quit before any save succeeds, then launch again with a writable library.
        try FileManager.default.removeItem(at: url)
        var saved = LibraryDatabase()
        saved.favoriteIDs.insert(beta.id)
        saved.usage = [UsageRecord(id: beta.id)]
        try JSONEncoder().encode(saved).write(to: url)
        let reopened = LibraryStore(fileURL: url)
        #expect(!reopened.database.favoriteIDs.contains(beta.id))
        #expect(!reopened.database.usage.contains { $0.id == beta.id })
        #expect(reopened.pendingForgottenIDs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test func aRowRestoredBeforeTheRetryKeepsItsNewUsage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let fake = FakeCommandProvider()
        let store = LibraryStore(fileURL: url)
        let model = model([fake], store: store)
        defer { model.stop() }
        model.navigate(to: .provided(FakeCommandProvider.scope))
        let beta = try #require(model.results.first { $0.title == "Beta Row" })
        #expect(store.toggleFavorite(beta.id))
        store.recordUse(of: beta.id)
        try blockWrites(to: url)
        model.confirm(.delete(beta))
        #expect(store.pendingForgottenIDs == [beta.id])

        // The provider restores the row under the same id, and it's used before any retry.
        fake.rows.append("Beta Row")
        try FileManager.default.removeItem(at: url)
        store.recordUse(of: beta.id)
        #expect(store.pendingForgottenIDs.isEmpty)
        #expect(store.database.usage.contains { $0.id == beta.id })
        #expect(!store.database.favoriteIDs.contains(beta.id))
    }

    // MARK: #8 Grids

    @Test func providerGridGroupsDefaultToTheStandardTileAndUseArrows() throws {
        let model = model([GridGroupProvider()])
        defer { model.stop() }
        model.navigate(to: .provided(GridGroupProvider.scope))
        let group = try #require(model.groups.first)
        #expect(group.tile != nil)
        // The scope is a list, but the selection is in a grid, so ← and → move it.
        #expect(model.arrowsMoveSelection)
        model.selectedID = group.items[0].id
        #expect(model.moveSelectionHorizontally(1))
        #expect(model.selectedID == group.items[1].id)
    }

    // MARK: #9 Eligibility

    @Test func aBindingOptOutHoldsEverywhereTheLauncherShowsBindings() throws {
        try withTestRegistrations {
            let fake = FakeCommandProvider()
            fake.optOuts = true
            let model = model([fake])
            defer { model.stop() }
            let optOut = try #require(model.commandItems.first { $0.id == "test.optout" })
            let curatedOptOut = try #require(model.commandItems.first { $0.id == "ai.summarize" })
            // A binding saved for it (the prefix accepts the id) is neither shown nor offered.
            #expect(model.store.saveCommandBinding(
                CommandBinding(targetID: "test.optout", alias: "opt", shortcut: CommandShortcut(keyCode: 31, modifiers: [.control, .option]))))
            #expect(!model.canBind(optOut))
            #expect(model.aliasChip(for: optOut) == nil)
            #expect(model.boundShortcut(for: optOut) == nil)
            #expect(!model.actions(for: optOut).contains { $0.id == "assign" })
            // A provided command under one of the original twenty ids opts out the same way.
            #expect(!model.canBind(curatedOptOut))
            #expect(!model.bindableCommands.contains { $0.id == "ai.summarize" })
            // A bindable one still offers it.
            let run = try #require(model.commandItems.first { $0.id == "test.run" })
            #expect(model.actions(for: run).contains { $0.id == "assign" })
        }
    }
}
