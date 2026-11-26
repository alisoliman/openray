import AppKit
import Testing

@testable import OpenRay

@MainActor
struct CommandDispatchTests {
    private func model() -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName())
    }

    @Test func exactAliasesWinGloballyOverTitlesFavoritesAndCalculator() {
        let model = model()
        defer { model.stop() }
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "notes")))
        model.store.toggleFavorite("file./Users/example/Notes")
        model.query = "  NoTeS  "
        #expect(model.results.map(\.id) == ["section.clipboard"])
        model.navigate(to: .snippets)
        model.query = "notes"
        #expect(model.results.map(\.id) == ["section.clipboard"])
        model.performSelected()
        #expect(model.section == .clipboard)
        #expect(model.store.database.usage.contains { $0.id == "section.clipboard" })

        #expect(model.store.saveCommandBinding(CommandBinding(targetID: "section.notes", alias: "42")))
        model.navigate(to: .calculator)
        model.query = "42"
        #expect(model.results.map(\.id) == ["section.notes"])
    }

    @Test func aliasPrefixesRankFirstExactAliasesWinAndActionsKeepTheirRouting() {
        let model = model()
        defer { model.stop() }
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "zzclip")))
        // A prefix of an alias ranks its command first; only the exact alias makes it the sole result.
        model.query = "zzcli"
        #expect(model.results.first?.id == "section.clipboard")
        model.query = "zzclip"
        model.showActions = true
        model.performSelected()
        #expect(model.section == .home)
        #expect(model.showActions)
        model.showActions = false
        model.performSelected()
        #expect(model.section == .clipboard)
    }

    @Test func curatedTargetsAreExplicitIncludeWritingCommandsAndExcludeContent() {
        let model = model()
        defer { model.stop() }
        // The original twenty lead in their order; registered providers may add more after them.
        #expect(Array(model.bindableCommands.map(\.id).prefix(CuratedCommand.targetIDs.count)) == CuratedCommand.targetIDs)
        #expect(CuratedCommand.targetIDs.count == 20)
        // Only the legacy registrations: later slices may make more ids bindable through their own.
        let legacy = [AIWritingCommandProvider.registration]
        for action in AIAction.allCases where action != .chat {
            #expect(CuratedCommand.supports("ai.\(action.id)", registrations: legacy))
        }
        #expect(!CuratedCommand.supports("window.nextDisplay", registrations: legacy))
        #expect(!CuratedCommand.supports("quicklink.any", registrations: legacy))
        #expect(!CuratedCommand.supports("clipboard.any", registrations: legacy))
    }

    @Test func mainsPomodoroAndCaffeinateCommandsJoinTheCatalogUnderTheIDsMainSaved() {
        let model = model()
        defer { model.stop() }
        // main appended these to the curated list; here the providers' namespaces accept them, so
        // bindings, favorites and usage saved by main's builds keep working.
        let ids = [
            "pomodoro.open", "pomodoro.start", "caffeinate.open", "caffeinate.start", "caffeinate.stop",
            "caffeinate.toggle",
        ]
        #expect(CuratedCommand.targetIDs.count == 20)
        let bindable = model.bindableCommands.map(\.id)
        for id in ids {
            #expect(CuratedCommand.supports(id))
            #expect(bindable.contains(id))
        }
        #expect(bindable.filter(ids.contains) == ids)
        // An alias runs them from any scope.
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: "pomodoro.open", alias: "pom")))
        model.navigate(to: .snippets)
        model.query = "pom"
        #expect(model.results.map(\.id) == ["pomodoro.open"])
        model.performSelected()
        #expect(model.section.providedScope?.id == PomodoroCommandProvider.scope.id)
    }

    @Test func boundInvocationUsesSharedDispatchAndRemovedBindingsCannotRun() {
        let model = model()
        defer { model.stop() }
        let binding = CommandBinding(
            targetID: "section.notes", alias: "nt",
            shortcut: CommandShortcut(keyCode: 45, modifiers: [.control, .option]))
        #expect(model.store.saveCommandBinding(binding))
        model.showActions = true
        model.performBoundCommand(targetID: binding.targetID)
        #expect(model.section == .notes)
        #expect(!model.showActions)
        #expect(model.store.database.usage.first?.id == binding.targetID)
        #expect(model.removeCommandBinding(for: binding.targetID))
        model.navigate(to: .home)
        model.performBoundCommand(targetID: binding.targetID)
        #expect(model.section == .home)
        #expect(model.store.database.aliasTarget(for: "nt") == nil)
    }

    @Test func shortcutRecordingAndOpenEditorsPreventCommandExecution() {
        let model = model()
        defer { model.stop() }
        let binding = CommandBinding(
            targetID: "section.notes", shortcut: CommandShortcut(keyCode: 45, modifiers: [.control, .option]))
        #expect(model.store.saveCommandBinding(binding))
        model.beginShortcutRecording()
        model.performBoundCommand(targetID: binding.targetID)
        #expect(model.section == .home)
        model.endShortcutRecording()
        model.endShortcutRecording()
        model.beginCommandBindingEditing()
        model.performBoundCommand(targetID: binding.targetID)
        #expect(model.section == .home)
        model.endCommandBindingEditing()
        let note = QuickNote(title: "Unsaved draft", content: "Keep me")
        model.editor = .note(note)
        model.performBoundCommand(targetID: binding.targetID)
        #expect(model.editor?.id == "note.\(note.id)")
        #expect(model.section == .home)
        #expect(model.message?.contains("Save or cancel") == true)
        model.editor = nil
        model.performBoundCommand(targetID: binding.targetID)
        #expect(model.section == .notes)
    }

    @Test func conflictsAreDisclosedAndRequireExplicitSaveAnyway() {
        let model = model()
        defer { model.stop() }
        let shortcut = CommandShortcut(keyCode: 40, modifiers: [.command])
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: "section.notes", shortcut: shortcut)))
        let duplicate = CommandBinding(targetID: "section.clipboard", alias: "clip", shortcut: shortcut)
        #expect(model.bindingWarnings(for: duplicate).contains { $0.contains("Notes") })
        #expect(!model.saveCommandBinding(duplicate))
        #expect(model.store.database.binding(for: duplicate.targetID) == nil)
        #expect(model.saveCommandBinding(duplicate, allowConflicts: true))
        #expect(model.store.database.binding(for: duplicate.targetID)?.shortcut == shortcut)
        let launcherConflict = CommandBinding(
            targetID: "section.files", shortcut: model.store.database.preferences.hotKey.shortcut)
        #expect(model.bindingWarnings(for: launcherConflict).contains { $0.contains("launcher") })
    }

    @Test func saveAnywayCannotBypassReservedShortcutsOrAliasUniqueness() {
        let model = model()
        defer { model.stop() }
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: "section.notes", alias: "nt")))
        #expect(
            !model.saveCommandBinding(
                CommandBinding(targetID: "section.clipboard", alias: "NT"), allowConflicts: true))
        #expect(
            !model.saveCommandBinding(
                CommandBinding(
                    targetID: "section.clipboard", shortcut: CommandShortcut(keyCode: 49, modifiers: [.command])),
                allowConflicts: true))
        #expect(model.store.database.commandBindings.count == 1)
    }
}
