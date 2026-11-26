import AppKit
import Carbon
import Testing

@testable import OpenRay

/// A provider whose fallback depends on what's typed, as a translator's or a script's would.
@MainActor
final class QueryFallbackProvider: CommandProvider {
    let id = "test.qfallback"
    init() {}
    func commands(in model: LauncherModel) -> [CommandDescriptor] { [] }
    func fallbackItems(for query: String, in model: LauncherModel) -> [LauncherItem] {
        guard query.hasPrefix("tr ") else { return [] }
        return [
            LauncherItem(
                id: "fallback.translate", title: "Translate", subtitle: query, symbol: "character.book.closed", badge: "Fallback",
                action: .provided(ProvidedRef(provider: id, id: "translate", payload: query)))
        ]
    }
    func fallbackDescriptors(in model: LauncherModel) -> [FallbackCandidate] {
        [FallbackCandidate(id: "fallback.translate", title: "Translate", symbol: "character.book.closed", kind: .command)]
    }
}

/// Two submenus whose children share ids, three levels deep.
@MainActor
final class NestedActionsProvider: CommandProvider {
    let id = "test.nested"
    init() {}
    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        [CommandDescriptor(id: "test.nested.cmd", title: "Wallaby Nested", subtitle: "", kind: .command, symbol: "list.bullet", mode: .noView)]
    }
    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        func leaf(_ title: String) -> ActionEntry { ActionEntry(id: "leaf", title: title, symbol: "doc", group: .item) {} }
        return [
            ActionEntry(id: "a", title: "Alpha", symbol: "a.circle", group: .item, children: [leaf("Shared one")]) {},
            ActionEntry(
                id: "b", title: "Beta", symbol: "b.circle", group: .item,
                children: [ActionEntry(id: "deeper", title: "Deeper", symbol: "c.circle", group: .item, children: [leaf("Shared two")]) {}]
            ) {},
        ]
    }
}

@MainActor
struct LauncherReviewFixTests {
    private func model(
        _ providers: [any CommandProvider]? = nil, store: LibraryStore = LibraryStore(fileURL: nil), hotKey: GlobalHotKey? = nil
    ) -> LauncherModel {
        LauncherModel(
            store: store, ai: AIChatModel(engine: TestAIEngine()), pasteboard: NSPasteboard.withUniqueName(),
            registry: providers.map { CommandRegistry(providers: $0) } ?? CommandRegistry(), hotKey: hotKey)
    }

    private func withFakeRegistration<T>(_ body: () throws -> T) rethrows -> T {
        try CuratedCommand.$registrations.withValue(CommandProviders.all + [FakeCommandProvider.registration], operation: body)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayReview-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Destructive confirmations

    @Test func aDestructivePromptIsApprovedOnlyOnceThisInstanceWasShownOnAVisibleSurface() throws {
        let fake = FakeCommandProvider()
        fake.confirmDestructive = true
        let model = model([fake])
        defer { model.stop() }
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        var visibleSince: Date?
        model.promptClock = { now }
        model.confirmationSurfaceVisibleSince = { visibleSince }
        model.currentKeyPressIsFresh = { true }
        let command = try #require(model.commandItems.first { $0.id == "test.confirm" })
        model.perform(command)
        let first = try #require(model.confirmationInstanceID)
        // Drawn, but the panel is hidden: a fresh Return does nothing.
        model.confirmationDidAppear(first)
        now += 5
        #expect(model.confirmFromReturn(isRepeat: false))
        #expect(fake.performed.isEmpty)
        // The panel starts revealing: its reveal doesn't count as exposure.
        visibleSince = now
        #expect(model.confirmFromReturn(isRepeat: false))
        #expect(fake.performed.isEmpty)
        // A text submission without a fresh key behind it never answers it.
        now += 5
        model.currentKeyPressIsFresh = { false }
        model.performSelected()
        #expect(fake.performed.isEmpty)
        // The prompt is asked again: the old button can't answer the new one, which isn't shown yet.
        model.currentKeyPressIsFresh = { true }
        model.perform(command)
        let second = try #require(model.confirmationInstanceID)
        #expect(second != first)
        model.approveConfirmation(id: first)
        #expect(fake.performed.isEmpty)
        model.performSelected()
        #expect(fake.performed.isEmpty)
        // Shown just now, still fading in: its own button waits out the exposure.
        model.confirmationDidAppear(second)
        model.approveConfirmation(id: second)
        #expect(fake.performed.isEmpty)
        now += LauncherModel.minimumPromptExposure
        model.approveConfirmation(id: second)
        #expect(fake.performed == ["test.confirm"])
    }

    @Test func aDestructiveHotkeyWaitsForItsVisiblePrompt() throws {
        try withFakeRegistration {
            let fake = FakeCommandProvider()
            fake.confirmDestructive = true
            let model = model([fake])
            defer { model.stop() }
            var now = Date(timeIntervalSinceReferenceDate: 1_000)
            var visibleSince: Date?
            model.promptClock = { now }
            model.confirmationSurfaceVisibleSince = { visibleSince }
            let shortcut = CommandShortcut(keyCode: 15, modifiers: [.control, .option])
            #expect(model.store.saveCommandBinding(CommandBinding(targetID: "test.confirm", shortcut: shortcut)))
            model.performBoundCommand(targetID: "test.confirm")
            let prompt = try #require(model.confirmationInstanceID)
            #expect(model.confirmFromReturn(isRepeat: false))
            #expect(fake.performed.isEmpty)
            visibleSince = now
            model.confirmationDidAppear(prompt)
            #expect(model.confirmFromReturn(isRepeat: false))
            #expect(fake.performed.isEmpty)
            now += LauncherModel.minimumPromptExposure
            #expect(model.confirmFromReturn(isRepeat: false))
            #expect(fake.performed == ["test.confirm"])
        }
    }

    @Test func aCustomRowForACommandIsRefusedOnceTheCommandIsGone() throws {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        // A provider's own row pointing at a command, without the descriptor mark.
        let custom = LauncherItem(
            id: "test.custom", title: "Custom Confirm", subtitle: "", symbol: "bolt", badge: "Custom",
            action: .provided(ProvidedRef(provider: "test.fake", id: "test.confirm")))
        model.perform(custom)
        #expect(model.confirmation != nil)
        model.confirmation = nil
        let snapshot = try #require(model.actions(for: custom).first { $0.id == "primary" })
        fake.withdrawn = ["test.confirm"]
        snapshot.perform()
        #expect(fake.performed.isEmpty)
        #expect(model.feedback?.style == .error)
    }

    @Test func aDisabledCommandIsRefusedFromSnapshotsAndPendingPrompts() throws {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        let run = try #require(model.commandItems.first { $0.id == "test.run" })
        let snapshot = try #require(model.actions(for: run).first { $0.id == "primary" })
        #expect(model.setCommand("test.run", enabled: false))
        snapshot.perform()
        #expect(fake.performed.isEmpty)
        #expect(model.feedback?.style == .warning)
        // Turned off while its question is pending.
        let confirm = try #require(model.commandItems.first { $0.id == "test.confirm" })
        model.perform(confirm)
        #expect(model.setCommand("test.confirm", enabled: false))
        model.performSelected()
        #expect(fake.performed.isEmpty)
    }

    // MARK: Modifier shortcuts

    @Test func rollingFromOneChordToAnotherOrClickingIsntAGesture() {
        var detector = ModifierGestureDetector(gestures: [
            "three": .modifiersOnly([.control, .option, .command]), "two": .modifiersOnly([.option, .command]),
        ])
        // ⌥⌘, let go of ⌥, then ⌃: never all three at once.
        _ = detector.handle(.flags([.leftOption, .leftCommand], time: 0))
        _ = detector.handle(.flags(.leftCommand, time: 0.1))
        _ = detector.handle(.flags([.leftCommand, .leftControl], time: 0.2))
        #expect(detector.handle(.flags([], time: 0.3)).isEmpty)
        // ⌥⌘-click.
        _ = detector.handle(.flags([.leftOption, .leftCommand], time: 1))
        _ = detector.handle(.key(time: 1.05))
        #expect(detector.handle(.flags([], time: 1.1)).isEmpty)
        // All three together still works.
        _ = detector.handle(.flags([.leftOption], time: 2))
        _ = detector.handle(.flags([.leftOption, .leftCommand, .leftControl], time: 2.05))
        #expect(detector.handle(.flags([], time: 2.1)) == ["three"])
    }

    @Test func aSingleAndADoubleTapOfOneKeyCantBothBeActive() {
        let source = FakeModifierSource()
        let registry = GlobalHotKey(
            backend: SilentHotKeyBackend(), reservedShortcuts: { [] }, modifierHotKeys: ModifierHotKeys(source: source))
        let issues = registry.synchronize(
            launcherShortcut: LauncherHotKey.optionSpace.shortcut,
            bindings: [
                CommandBinding(targetID: "section.notes", shortcut: .modifiersOnly(.command, sides: .rightCommand)),
                CommandBinding(targetID: "section.files", shortcut: .doubleTap(.command)),
            ],
            onLauncher: {}, onCommand: { _ in })
        #expect(issues.map(\.targetID) == ["section.files"])
        #expect(issues.first?.message.contains("overlaps") == true)
        #expect(registry.modifierHotKeys.registeredIDs == ["section.notes"])
        #expect(CommandShortcut.doubleTap(.command).gestureOverlaps(.modifiersOnly(.command, sides: .rightCommand)))
        #expect(!CommandShortcut.doubleTap(.option).gestureOverlaps(.modifiersOnly(.command, sides: .rightCommand)))
        #expect(CommandShortcut.doubleTap(.command, side: .leftCommand).gestureOverlaps(.doubleTap(.command)))
        registry.unregister()
    }

    @Test func aModifierLauncherWithoutAccessibilityKeepsAWorkingPresetAndRecovers() {
        let source = FakeModifierSource()
        source.delivers = false
        let backend = SilentHotKeyBackend()
        let model = model(hotKey: GlobalHotKey(backend: backend, reservedShortcuts: { [] }, modifierHotKeys: ModifierHotKeys(source: source)))
        defer { model.stop() }
        model.isStarted = true
        #expect(model.setLauncherShortcut(.doubleTap(.command)))
        // The gesture can't be delivered yet, so a preset still opens OpenRay, and that's explained.
        #expect(!backend.active.isEmpty)
        #expect(model.shortcutError?.contains("Until then") == true)
        #expect(!model.hotKey.modifierHotKeys.isDelivering)
        // Accessibility allowed: the next sync starts the gesture and drops the fallback.
        source.delivers = true
        model.synchronizeCommandHotKeys()
        #expect(model.hotKey.modifierHotKeys.isDelivering)
        #expect(backend.active.isEmpty)
        #expect(model.shortcutError == nil)
        #expect(source.startCount == 2)
    }

    // MARK: Content bindings

    @Test func theFirstAliasOrHotkeyForContentSavesThroughTheModel() throws {
        let model = model()
        defer { model.stop() }
        #expect(model.store.save(Snippet(name: "Sign-off", keyword: "", content: "Best, A.")))
        let snippet = try #require(model.snippetItems.first)
        let link = try #require(model.quicklinkItems.first)
        for row in [snippet, link] {
            let binding = CommandBinding(targetID: row.id, alias: "zz\(row.id.prefix(3))")
            try model.validateCommandBinding(binding)
            #expect(model.saveCommandBinding(binding))
        }
        #expect(model.bindableCommands.contains { $0.id == snippet.id })
        // An app that isn't installed can't take one.
        #expect(throws: LibraryValidationError.self) {
            try model.validateCommandBinding(CommandBinding(targetID: "app.example.missing", alias: "nope"))
        }
    }

    @Test func deletingBoundContentRemovesItsBindingAndHotkey() throws {
        let backend = SilentHotKeyBackend()
        let model = model(hotKey: GlobalHotKey(backend: backend, reservedShortcuts: { [] }, modifierHotKeys: ModifierHotKeys(source: FakeModifierSource())))
        defer { model.stop() }
        model.isStarted = true
        #expect(model.store.save(Snippet(name: "Sign-off", keyword: "", content: "Best, A.")))
        let snippet = try #require(model.snippetItems.first)
        let shortcut = CommandShortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: [.control, .option])
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: snippet.id, alias: "bye", shortcut: shortcut)))
        #expect(backend.active.values.contains(shortcut))
        #expect(model.delete(snippet))
        #expect(model.store.database.binding(for: snippet.id) == nil)
        #expect(!backend.active.values.contains(shortcut))
    }

    // MARK: Argument fields

    @Test func argumentFieldsOwnTheListAndRunOnlyThroughTheForm() throws {
        try CuratedCommand.$registrations.withValue(CommandProviders.all + [ArgumentsProvider.registration]) {
            let provider = ArgumentsProvider()
            let model = model([provider])
            defer { model.stop() }
            #expect(model.store.saveCommandBinding(CommandBinding(targetID: "test.args.translate", alias: "tr")))
            model.query = "tr "
            let session = try #require(model.argumentSession)
            // The query is empty, but the list is the command, not Favorites, and the bar stays open.
            #expect(model.groups.map(\.id) == ["argument.session"])
            #expect(!model.isCollapsedToBar)
            // Clicking the row's Run button runs the form, so missing values are asked for.
            model.perform(session.item)
            #expect(provider.runs.isEmpty)
            #expect(model.argumentSession != nil)
            #expect(model.feedback?.style == .warning)
            // ⌘K offers only running or closing it; ⌘↩ does nothing.
            #expect(model.actions(for: session.item).map(\.id) == ["primary", "cancelArguments"])
            model.pasteSelected()
            #expect(provider.runs.isEmpty)
            // Leaving clears it, password and all.
            model.setArgumentValue("secret", at: 1)
            model.navigate(to: .notes)
            #expect(model.argumentSession == nil)
        }
    }

    @Test func argumentFieldsOpenOnlyWhereTheyCanBeTyped() throws {
        let provider = ArgumentsProvider()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model([provider], store: LibraryStore(fileURL: directory.appending(path: "library.json")))
        defer { model.stop() }
        let command = try #require(model.commandItems.first { $0.id == "test.args.translate" })
        // During setup: refused, and said so.
        model.beginOnboardingIfNeeded()
        #expect(model.onboarding != nil)
        #expect(!model.beginArguments(for: command))
        #expect(model.feedback?.style == .warning)
        model.finishOnboarding()
        // From AI: back to search first.
        model.openAI(.chat)
        #expect(model.beginArguments(for: command))
        #expect(model.destination == .search)
        // A focused field reports itself; dropdowns change their own field.
        model.argumentFieldDidFocus(2)
        #expect(model.argumentSession?.focus == 2)
        let token = model.argumentSession?.focusToken
        model.argumentFieldDidFocus(0)
        #expect(model.argumentSession?.focusToken == token)
        #expect(model.cycleArgumentOption(1, at: 2))
        #expect(model.argumentSession?.values["language"] == "fr")
        #expect(!model.cycleArgumentOption(1, at: 0))
    }

    @Test func aHotkeyForACommandWithArgumentsOpensItsFields() throws {
        try CuratedCommand.$registrations.withValue(CommandProviders.all + [ArgumentsProvider.registration]) {
            let model = model([ArgumentsProvider()])
            defer { model.stop() }
            let shortcut = CommandShortcut(keyCode: 17, modifiers: [.control, .option])
            #expect(model.store.saveCommandBinding(CommandBinding(targetID: "test.args.translate", shortcut: shortcut)))
            let command = try #require(model.bindableCommands.first { $0.id == "test.args.translate" })
            #expect(model.runsWithoutPanel(command))
            #expect(model.needsArguments(command))
            model.performBoundCommand(targetID: "test.args.translate")
            #expect(model.argumentSession?.item.id == "test.args.translate")
        }
    }

    // MARK: Fallbacks

    @Test func queryDependentFallbacksAndEarlierSavedOrdersAreKept() throws {
        let model = model([QueryFallbackProvider()])
        defer { model.stop() }
        model.query = "tr hello"
        model.files.stop()
        #expect(model.groups.last?.items.map(\.id) == ["fallback.ai", "fallback.web", "fallback.translate"])
        model.query = "hello"
        model.files.stop()
        #expect(model.groups.last?.items.map(\.id) == ["fallback.ai", "fallback.web"])
        #expect(model.fallbackCandidates.contains { $0.id == "fallback.translate" })
        // A saved order without the newer flag is the person's choice.
        #expect(model.store.update { $0.fallbackOrder = ["fallback.translate", "fallback.ai"] })
        #expect(model.usesCustomFallbacks)
        model.query = "tr hello"
        model.files.stop()
        #expect(model.groups.last?.items.map(\.id) == ["fallback.translate", "fallback.ai"])
        // An emptied custom list stays empty.
        #expect(model.setFallback("fallback.translate", enabled: false))
        #expect(model.setFallback("fallback.ai", enabled: false))
        #expect(model.usesCustomFallbacks)
        #expect(!model.groups.contains { $0.id == "fallbacks" })
    }

    // MARK: Cleanup after deletions elsewhere

    @Test func whenNothingCanBeRecordedTheDeletionDoesntHappen() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appending(path: "Library")
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        let fake = FakeCommandProvider()
        let model = model([fake], store: store)
        defer { model.stop() }
        model.navigate(to: .provided(FakeCommandProvider.scope))
        let beta = try #require(model.results.first { $0.title == "Beta Row" })
        #expect(store.toggleFavorite(beta.id))
        // The whole folder becomes unwritable: neither the library nor the record can be saved.
        try FileManager.default.removeItem(at: directory)
        try Data("not a folder".utf8).write(to: directory)
        model.confirm(.delete(beta))
        #expect(fake.deleted.isEmpty)
        #expect(fake.rows.contains("Beta Row"))
        #expect(model.feedback?.style == .error)
        #expect(store.journaledCleanup.isEmpty)
    }

    @Test func aQuitBetweenRecordingAndDeletingKeepsRowsThatStillExist() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        #expect(store.toggleFavorite("test.row.Beta Row"))
        #expect(store.toggleFavorite("test.row.Gamma Row"))
        // Recorded, then OpenRay quit: Beta was deleted, Gamma's deletion never happened.
        try store.journalCleanup(of: "test.row.Beta Row", provider: "test.fake")
        try store.journalCleanup(of: "test.row.Gamma Row", provider: "test.fake")
        let fake = FakeCommandProvider()
        fake.rows = ["Alpha Row", "Gamma Row"]
        let reopened = LibraryStore(fileURL: url)
        let model = model([fake], store: reopened)
        defer { model.stop() }
        #expect(!reopened.database.favoriteIDs.contains("test.row.Beta Row"))
        #expect(reopened.database.favoriteIDs.contains("test.row.Gamma Row"))
        #expect(reopened.journaledCleanup.isEmpty)
        // A provider that isn't here keeps its records for later.
        try reopened.journalCleanup(of: "other.row", provider: "absent.provider")
        let later = self.model([fake], store: LibraryStore(fileURL: url))
        defer { later.stop() }
        #expect(later.store.journaledCleanup["other.row"] == "absent.provider")
    }

    // MARK: Minors

    @Test func settingsSearchOpensThePaneThatShowsTheCommand() {
        CuratedCommand.$registrations.withValue(CommandProviders.all + [FakeCommandProvider.registration]) {
            let fake = FakeCommandProvider()
            fake.optOuts = true
            let model = model([fake])
            defer { model.stop() }
            let shortcuts = model.bindingRows(focusing: nil).map { model.settingsSearchText(for: $0) }
            let catalog = model.commandCatalog.flatMap(\.commands).map { model.settingsSearchText(for: $0) }
            // A command that can't hold a binding is only in Commands.
            #expect(SettingsSearch.bestPane(for: "yak opt", commands: shortcuts, catalog: catalog) == .commands)
            // One that can is found in Shortcuts first.
            #expect(SettingsSearch.bestPane(for: "zebra fake run", commands: shortcuts, catalog: catalog) == .shortcuts)
        }
    }

    @Test func submenuEntriesFoundBySearchKeepDistinctIdentities() throws {
        let model = model([NestedActionsProvider()])
        defer { model.stop() }
        model.query = "wallaby nested"
        model.files.stop()
        model.showActions = true
        model.actionFilter = "shared"
        let found = model.filteredActionEntries
        #expect(found.map(\.title) == ["Alpha › Shared one", "Beta › Deeper › Shared two"])
        #expect(Set(found.map(\.id)).count == 2)
    }

    @Test func aMissingCommandsSavedShortcutDoesntBlockTheLauncher() {
        withFakeRegistration {
            let fake = FakeCommandProvider()
            fake.scripts = ["backup"]
            let model = model([fake])
            defer { model.stop() }
            let shortcut = CommandShortcut(keyCode: UInt32(kVK_ANSI_U), modifiers: [.control, .option])
            #expect(model.store.saveCommandBinding(CommandBinding(targetID: "test.script.backup", shortcut: shortcut)))
            #expect(!model.setLauncherShortcut(shortcut))
            fake.scripts = []
            #expect(model.setLauncherShortcut(shortcut))
            #expect(model.store.database.preferences.launcherHotKeyTitle == shortcut.title)
        }
    }

    @Test func untitledLoadingGroupsAndPendingCountsSaySearching() {
        #expect(LauncherResultGroup(id: "pending", title: nil, isLoading: true, items: []).showsLoadingHeader)
        #expect(!LauncherResultGroup(id: "pending", title: "Pending", isLoading: true, items: []).showsLoadingHeader)
        #expect(SearchActionBar.countStatus(resultCount: 0, isSearching: true, isQueryBlank: true) == "Searching…")
        #expect(SearchActionBar.countStatus(resultCount: 0, isSearching: false, isQueryBlank: true) == "0 items")
        #expect(SearchActionBar.countStatus(resultCount: 1, isSearching: true, isQueryBlank: false) == "1 result")
    }

    @Test func interfaceSizesScaleTheDesignFromOne() {
        #expect(InterfaceSize.standard.scale == 1)
        #expect(InterfaceSize.compact.scale < 1 && InterfaceSize.large.scale > 1)
        #expect(OR.interfaceScale == 1)
        #expect(OR.Metric.field == 60)
        #expect(OR.scaledLength(44) == 44)
        #expect(AppPreferences().size == .standard)
    }
}
