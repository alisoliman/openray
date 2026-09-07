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

    @Test func aliasMatchingIsExactAndActionsKeepTheirExistingRouting() {
        let model = model()
        defer { model.stop() }
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "zzclip")))
        model.query = "zzcli"
        #expect(model.results.isEmpty)
        model.query = "zzclip"
        model.showActions = true
        model.performSelected()
        #expect(model.section == .home)
        #expect(model.showActions)
        model.showActions = false
        model.performSelected()
        #expect(model.section == .clipboard)
    }

    @Test func curatedTargetsAreExplicitAndExcludeContentAndOtherAICommands() {
        let model = model()
        defer { model.stop() }
        #expect(model.bindableCommands.map(\.id) == CuratedCommand.targetIDs)
        #expect(model.bindableCommands.count == 15)
        #expect(!CuratedCommand.supports("ai.summarize"))
        #expect(!CuratedCommand.supports("window.nextDisplay"))
        #expect(!CuratedCommand.supports("quicklink.any"))
        #expect(!CuratedCommand.supports("clipboard.any"))
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
