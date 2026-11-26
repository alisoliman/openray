import AppKit
import Carbon
import Testing

@testable import OpenRay

/// A provider whose live search returns a row for its own destructive command, as a system
/// provider's “shut” search would.
@MainActor
final class LiveCommandRowProvider: CommandProvider {
    let id = "test.livecmd"
    var withdrawn = false
    var performed: [String] = []
    init() {}

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        guard !withdrawn else { return [] }
        var confirmation = CommandConfirmation(question: "Shut down?", detail: "Apps will quit.", confirmTitle: "Shut Down")
        confirmation.isDestructive = true
        return [
            CommandDescriptor(
                id: "test.livecmd.shutdown", title: "Quokka Shut Down", subtitle: "", kind: .command, symbol: "power",
                mode: .noView, confirmation: confirmation)
        ]
    }

    var providesLiveItems: Bool { true }

    func liveItems(for query: String, scope: ProvidedScope?, in model: LauncherModel) async -> [LauncherItem] {
        guard !withdrawn else { return [] }
        // An ordinary ref, without the descriptor mark, as a provider might build it.
        return [
            LauncherItem(
                id: "test.livecmd.row", title: "Quokka Shut Down Now", subtitle: "", symbol: "power", badge: "Live",
                action: .provided(ProvidedRef(provider: id, id: "test.livecmd.shutdown")))
        ]
    }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) { performed.append(ref.id) }
}

/// A Hyper tap macOS can disable on purpose.
@MainActor
final class DisablableHyperTap: HyperEventTap {
    var map: (@Sendable (UInt64) -> UInt64)?
    var starts = 0
    var isDisabledByUser = false
    var isRunning: Bool { map != nil && !isDisabledByUser }
    func start(map: @escaping @Sendable (UInt64) -> UInt64) -> Bool {
        starts += 1
        isDisabledByUser = false
        self.map = map
        return true
    }
    func stop() { map = nil }
}

/// A key backend that can't register some shortcuts, as when another app owns them.
final class PickyHotKeyBackend: GlobalHotKeyBackend {
    var active: [UInt32: CommandShortcut] = [:]
    var refused: Set<CommandShortcut> = []
    func installHandler(_ action: @escaping (UInt32) -> Void) throws {}
    func register(_ shortcut: CommandShortcut, identifier: UInt32) throws {
        if refused.contains(shortcut) { throw LibraryValidationError("Taken by another app.") }
        active[identifier] = shortcut
    }
    func unregister(identifier: UInt32) { active[identifier] = nil }
    func removeHandler() {}
}

/// A provider whose fallback rows exist only through the original `fallbackItems` hook.
@MainActor
final class LegacyFallbackProvider: CommandProvider {
    let id = "test.legacyfallback"
    init() {}
    func commands(in model: LauncherModel) -> [CommandDescriptor] { [] }
    func fallbackItems(for query: String, in model: LauncherModel) -> [LauncherItem] {
        // Only for some searches, so Settings' placeholder search finds nothing to list.
        guard query.hasPrefix("def ") else { return [] }
        return [
            LauncherItem(
                id: "fallback.legacy", title: "Legacy Lookup", subtitle: query, symbol: "book", badge: "Fallback",
                action: .provided(ProvidedRef(provider: id, id: "lookup", payload: query)))
        ]
    }
}

extension LauncherModel {
    /// Test seam: the pending prompt has been on a visible, revealed panel for long enough, and
    /// the next key press is a fresh one.
    func showPendingPromptLongEnough() {
        confirmationSurfaceVisibleSince = { .distantPast }
        currentKeyPressIsFresh = { true }
        guard let instance = confirmationInstanceID else { return }
        confirmationShown = (instance, .distantPast)
    }
}

@MainActor
struct LauncherRereviewTests {
    private func model(
        _ providers: [any CommandProvider]? = nil, store: LibraryStore = LibraryStore(fileURL: nil), hotKey: GlobalHotKey? = nil,
        hyperKey: HyperKey? = nil
    ) -> LauncherModel {
        LauncherModel(
            store: store, ai: AIChatModel(engine: TestAIEngine()), pasteboard: NSPasteboard.withUniqueName(),
            registry: providers.map { CommandRegistry(providers: $0) } ?? CommandRegistry(), hotKey: hotKey,
            hyperKey: hyperKey)
    }

    private func withFakeRegistration<T>(_ body: () throws -> T) rethrows -> T {
        try CuratedCommand.$registrations.withValue(CommandProviders.all + [FakeCommandProvider.registration], operation: body)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayRereview-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Blocker: built-in destructive prompts

    @Test func deleteNeedsItsOwnVisiblePromptAndAFreshKey() throws {
        let model = model()
        defer { model.stop() }
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        var visibleSince: Date?
        model.promptClock = { now }
        model.confirmationSurfaceVisibleSince = { visibleSince }
        model.currentKeyPressIsFresh = { true }
        #expect(model.store.save(Snippet(name: "Keep Me", keyword: "", content: "Body")))
        let row = try #require(model.snippetItems.first)
        model.requestDelete(row)
        #expect(model.confirmation?.requiresVisibleApproval == true)
        // A fresh press before the prompt was shown, even in a visible panel, deletes nothing.
        visibleSince = now
        now += 5
        model.performSelected()
        #expect(model.confirmFromReturn(isRepeat: false))
        #expect(model.store.database.snippets.count == 1)
        // Shown: still nothing until it has been on screen long enough.
        model.confirmationDidAppear(try #require(model.confirmationInstanceID))
        #expect(model.confirmFromReturn(isRepeat: false))
        #expect(model.store.database.snippets.count == 1)
        now += LauncherModel.minimumPromptExposure
        // insertNewline: from a repeating key binding goes through the same fresh-key check.
        model.currentKeyPressIsFresh = { false }
        model.performSelected()
        #expect(model.store.database.snippets.count == 1)
        model.currentKeyPressIsFresh = { true }
        model.performSelected()
        #expect(model.store.database.snippets.isEmpty)
    }

    @Test func theSameBuiltInQuestionAskedAgainIsANewInstance() throws {
        let model = model()
        defer { model.stop() }
        model.showPendingPromptLongEnough()
        model.presentConfirmation(.clearClipboardHistory(pinnedCount: 0))
        let first = try #require(model.confirmationInstanceID)
        model.confirmationDidAppear(first)
        model.presentConfirmation(.clearClipboardHistory(pinnedCount: 0))
        let second = try #require(model.confirmationInstanceID)
        #expect(first != second)
        // The old button, and the old report, don't carry over.
        model.approveConfirmation(id: first)
        #expect(model.confirmation != nil)
        model.confirmationDidAppear(first)
        #expect(model.confirmFromReturn(isRepeat: false))
        #expect(model.confirmation != nil)
        // A later report of the same instance doesn't restart its exposure.
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        model.promptClock = { now }
        model.confirmationDidAppear(second)
        now += LauncherModel.minimumPromptExposure
        model.confirmationDidAppear(second)
        model.approveConfirmation(id: second)
        #expect(model.confirmation == nil)
    }

    @Test func discardChangesWaitsForItsPromptToBeShown() throws {
        let model = model()
        defer { model.stop() }
        model.confirmation = .discardChanges
        model.confirmationSurfaceVisibleSince = { .distantPast }
        model.currentKeyPressIsFresh = { true }
        // Not reported as shown: neither Return nor a field's submit discards anything.
        #expect(model.confirmFromReturn(isRepeat: false))
        model.performSelected()
        #expect(model.confirmation?.id == "discard")
    }

    // MARK: Partial 6: live rows keep command identity

    @Test func aLiveRowForAWithdrawnCommandIsRefusedBeforeAndAfterActions() async throws {
        let provider = LiveCommandRowProvider()
        let model = model([provider])
        defer { model.stop() }
        model.query = "quokka"
        for _ in 0..<200 where model.isLoadingProvidedItems { try await Task.sleep(for: .milliseconds(5)) }
        let row = try #require(model.providedLiveItems[provider.id]?.first)
        guard case .provided(let ref) = row.action else {
            Issue.record("Expected a provided row")
            return
        }
        #expect(ref.has(.descriptor))
        // While the command exists, the cached row asks first.
        model.perform(row)
        #expect(model.confirmation != nil)
        model.confirmation = nil
        // Withdrawn while the row is still listed: Return refuses it, and so does ⌘K's ↩.
        provider.withdrawn = true
        model.perform(row)
        #expect(provider.performed.isEmpty)
        #expect(model.confirmation == nil)
        #expect(model.feedback?.style == .error)
        let primary = try #require(model.actions(for: row).first { $0.id == "primary" })
        primary.perform()
        #expect(provider.performed.isEmpty)
        // The catalog change drops the row for the withdrawn command, without searching again.
        let searches = model.isLoadingProvidedItems
        model.commandCatalogDidChange()
        #expect(model.isLoadingProvidedItems == searches)
        #expect(model.providedLiveItems[provider.id]?.isEmpty ?? true)
    }

    // MARK: Majors

    @Test func aRightShiftHyperWithoutShiftSendsNoShift() {
        let rightShift: UInt64 = 0x0000_0004
        let leftShift: UInt64 = 0x0000_0002
        let shift = CGEventFlags.maskShift.rawValue
        let others = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
        let settings = HyperKeySettings(isEnabled: true, includesShift: false, trigger: .rightShift)
        let mapped = HyperKeyMapping.flags(rightShift | shift, trigger: .rightShift, modifiers: settings.modifiers)
        #expect(mapped & shift == 0)
        #expect(mapped & rightShift == 0)
        #expect(mapped & others == others)
        // A left ⇧ held as well still counts as ⇧.
        let both = HyperKeyMapping.flags(rightShift | leftShift | shift, trigger: .rightShift, modifiers: settings.modifiers)
        #expect(both & shift == shift)
        #expect(both & leftShift == leftShift)
        // With Shift included, it's all four.
        let all = HyperKeyMapping.flags(rightShift | shift, trigger: .rightShift, modifiers: ShortcutModifiers.all)
        #expect(all & (others | shift) == others | shift)
        // Released: unchanged.
        #expect(HyperKeyMapping.flags(leftShift | shift, trigger: .rightShift, modifiers: settings.modifiers) == leftShift | shift)
    }

    @Test func aHyperTapMacOSTurnedOffStaysOffUntilTheSettingChanges() {
        let tap = DisablableHyperTap()
        let hyper = HyperKey(tap: tap)
        let settings = HyperKeySettings(isEnabled: true)
        hyper.apply(settings, accessibilityAllowed: true)
        #expect(hyper.isActive)
        #expect(tap.starts == 1)
        tap.isDisabledByUser = true
        #expect(!hyper.isActive)
        hyper.apply(settings, accessibilityAllowed: true)
        #expect(tap.starts == 1)
        #expect(hyper.problem != nil)
        // Off and on again resumes it.
        hyper.apply(HyperKeySettings(isEnabled: false), accessibilityAllowed: true)
        hyper.apply(settings, accessibilityAllowed: true)
        #expect(tap.starts == 2)
        #expect(hyper.isActive)
        #expect(hyper.problem == nil)
    }

    @Test func aHotkeyNeverSubmitsAHiddenArgumentDraft() {
        withFakeRegistration {
            let fake = FakeCommandProvider()
            let model = model([fake])
            defer { model.stop() }
            #expect(model.store.saveCommandBinding(
                CommandBinding(targetID: "test.args", shortcut: CommandShortcut(keyCode: 0, modifiers: [.control, .option]))))
            #expect(model.store.saveCommandBinding(
                CommandBinding(targetID: "test.run", shortcut: CommandShortcut(keyCode: 1, modifiers: [.control, .option]))))
            model.performBoundCommand(targetID: "test.args")
            #expect(model.argumentSession?.item.id == "test.args")
            model.setArgumentValue("Ann", at: 0)
            // The panel hides with the form; the same hotkey shows it again and runs nothing.
            model.performBoundCommand(targetID: "test.args")
            #expect(fake.performed.isEmpty)
            #expect(model.argumentSession?.value(at: 0) == "Ann")
            // Another command's hotkey gives the hidden form up instead of submitting or keeping it.
            model.performBoundCommand(targetID: "test.run")
            #expect(model.argumentSession == nil)
            #expect(fake.performed == ["test.run"])
            #expect(fake.performedArguments.allSatisfy { $0["name"] != "Ann" })
        }
    }

    @Test func startupCleanupWaitsUntilTheProviderCanTell() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        #expect(store.toggleFavorite("test.row.Beta Row"))
        try store.journalCleanup(of: "test.row.Beta Row", provider: "test.fake")
        let fake = FakeCommandProvider()
        fake.rows = ["Alpha Row"]
        fake.rowsLoaded = false
        let model = model([fake], store: LibraryStore(fileURL: url))
        defer { model.stop() }
        // Not loaded yet: it can't say, so nothing is cleaned and the record stays.
        #expect(model.store.database.favoriteIDs.contains("test.row.Beta Row"))
        #expect(model.store.journaledCleanup["test.row.Beta Row"] == "test.fake")
        // Loaded and announced: now it's known to be gone.
        fake.rowsLoaded = true
        model.commandCatalogDidChange()
        #expect(!model.store.database.favoriteIDs.contains("test.row.Beta Row"))
        #expect(model.store.journaledCleanup.isEmpty)
    }

    @Test func aFailedRetryKeepsAnEarlierCleanupRecord() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(fileURL: directory.appending(path: "library.json"))
        let fake = FakeCommandProvider()
        let model = model([fake], store: store)
        defer { model.stop() }
        model.navigate(to: .provided(FakeCommandProvider.scope))
        let beta = try #require(model.results.first { $0.title == "Beta Row" })
        #expect(store.toggleFavorite(beta.id))
        // An earlier attempt recorded the cleanup; this retry fails in the provider.
        try store.journalCleanup(of: beta.id, provider: fake.id)
        fake.failDeletion = true
        model.confirm(.delete(beta))
        #expect(store.journaledCleanup[beta.id] == fake.id)
    }

    // MARK: Earlier majors

    @Test func overlappingGesturesFollowTheDetectorsRule() {
        let unsided = CommandShortcut.modifiersOnly([.option, .command])
        let leftPair = CommandShortcut.modifiersOnly([.option, .command], sides: [.leftOption, .leftCommand])
        let mixed = CommandShortcut.modifiersOnly([.option, .command], sides: [.leftOption, .rightCommand])
        #expect(unsided.gestureOverlaps(leftPair))
        #expect(leftPair.gestureOverlaps(unsided))
        #expect(mixed.gestureOverlaps(unsided))
        #expect(!mixed.gestureOverlaps(leftPair))
        #expect(CommandShortcut.doubleTap(.command).gestureOverlaps(.modifiersOnly(.command, sides: .leftCommand)))
        #expect(!CommandShortcut.doubleTap(.command, side: .rightCommand).gestureOverlaps(.doubleTap(.command, side: .leftCommand)))
        // The detector fires both for one press exactly when they overlap.
        var detector = ModifierGestureDetector(gestures: ["a": unsided, "b": leftPair])
        _ = detector.handle(.flags([.leftOption], time: 0))
        _ = detector.handle(.flags([.leftOption, .leftCommand], time: 0.05))
        #expect(detector.handle(.flags([], time: 0.1)) == ["a", "b"])
    }

    @Test func aModifierLauncherThatCantBeDeliveredKeepsTheChordThatWorks() {
        let source = FakeModifierSource()
        source.delivers = false
        let backend = PickyHotKeyBackend()
        backend.refused = Set(LauncherHotKey.allCases.map(\.shortcut))
        let model = model(hotKey: GlobalHotKey(backend: backend, reservedShortcuts: { [] }, modifierHotKeys: ModifierHotKeys(source: source)))
        defer { model.stop() }
        model.isStarted = true
        // No chord ever worked and every preset is taken: the message says so instead of naming one.
        #expect(model.setLauncherShortcut(.doubleTap(.command)))
        #expect(model.hotKey.registeredLauncherChord == nil)
        #expect(model.shortcutError?.contains("menu bar") == true)
        // A recorded chord that works, then a gesture macOS won't deliver: the chord stays.
        let chord = CommandShortcut(keyCode: 40, modifiers: [.control, .option])
        #expect(model.setLauncherShortcut(chord))
        #expect(model.hotKey.registeredLauncherChord == chord)
        #expect(model.setLauncherShortcut(.doubleTap(.command)))
        #expect(model.hotKey.registeredLauncherChord == chord)
        #expect(model.shortcutError?.contains("Until then, \(chord.title) opens OpenRay") == true)
        #expect(model.launcherShortcutInUse == chord)
        // Delivered: the gesture replaces it, and is what the menu shows.
        source.delivers = true
        model.synchronizeCommandHotKeys()
        #expect(model.hotKey.registeredLauncherChord == nil)
        #expect(model.launcherShortcutInUse == .doubleTap(.command))
        #expect(model.shortcutError == nil)
    }

    @Test func providerFallbacksSettingsCantListSurviveEditingTheOthers() throws {
        let model = model([LegacyFallbackProvider()])
        defer { model.stop() }
        #expect(model.orderedFallbackItems(for: "def kiwi").contains { $0.id == "fallback.legacy" })
        #expect(!model.fallbackCandidates.contains { $0.id == "fallback.legacy" })
        #expect(model.setFallback("fallback.ai", enabled: false))
        #expect(model.usesCustomFallbacks)
        #expect(model.orderedFallbackItems(for: "def kiwi").contains { $0.id == "fallback.legacy" })
        #expect(!model.orderedFallbackItems(for: "def kiwi").contains { $0.id == "fallback.ai" })
    }

    @Test func movingAFallbackSkipsSavedIDsThatArentShown() throws {
        let model = model()
        defer { model.stop() }
        #expect(model.store.update { database in
            database.fallbackOrder = ["fallback.ai", "fallback.gone", "fallback.web"]
            database.preferences.customFallbacks = true
        })
        let visible = model.visibleFallbackIDs
        #expect(!visible.contains("fallback.gone"))
        guard visible.count >= 2, let last = visible.last else { return }
        #expect(model.canMoveFallback(last, by: -1))
        #expect(model.moveFallback(last, by: -1))
        #expect(model.visibleFallbackIDs.first == last)
        // The hidden id stays saved.
        #expect(model.store.database.fallbackOrder.contains("fallback.gone"))
    }

    // MARK: Cross-slice wiring

    @Test func thePrimaryActionPreferenceReachesAnswersAndContent() {
        let model = model()
        defer { model.stop() }
        #expect(AnswerPrimaryAction.current(in: model) == .copy)
        #expect(model.contentPrimaryAction == .copy)
        #expect(model.store.update { $0.preferences.primaryAction = .paste })
        #expect(AnswerPrimaryAction.current(in: model) == .paste)
        #expect(model.contentPrimaryAction == .paste)
    }
}
