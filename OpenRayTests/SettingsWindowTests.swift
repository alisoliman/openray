import AppKit
import SwiftUI
import Testing

@testable import OpenRay

@MainActor
struct SettingsWindowTests {
    private func model() -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName())
    }

    @Test func panelRoutesEscapeFromInlineEditorsAndAIToTheModel() throws {
        let model = model()
        defer { model.stop() }
        let panel = LauncherPanel()
        panel.escapeAction = {
            model.goBack()
            return true
        }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        panel.contentView = editor
        #expect(panel.makeFirstResponder(editor))
        model.navigate(to: .notes)
        model.editor = .note(QuickNote(title: "", content: ""))
        #expect(panel.handleEscapeKey(try keyEvent(code: 53)))
        #expect(model.editor == nil)
        #expect(model.section == .notes)
        model.openAI()
        #expect(panel.handleEscapeKey(try keyEvent(code: 53)))
        #expect(model.destination == .search)
        #expect(model.section == .notes)
        model.files.stop()
    }

    @Test func panelLeavesModifiedEscapeAndInputMethodsToNativeResponders() throws {
        let panel = LauncherPanel()
        var navigations = 0
        panel.escapeAction = {
            navigations += 1
            return true
        }
        #expect(!panel.handleEscapeKey(try keyEvent(code: 53, modifiers: .command)))
        #expect(!panel.handleEscapeKey(try keyEvent(code: 125)))
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        panel.contentView = editor
        #expect(panel.makeFirstResponder(editor))
        editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(!panel.handleEscapeKey(try keyEvent(code: 53)))
        #expect(navigations == 0)
    }

    @Test func dirtyEditorsAskBeforeDiscardingAndReturnConfirms() {
        let model = model()
        defer { model.stop() }
        model.navigate(to: .snippets)
        model.createItem()
        model.draft?.name = "Signature"
        model.goBack()
        #expect(model.editor != nil)
        #expect(model.confirmation?.id == "discard")
        model.goBack()
        #expect(model.confirmation == nil)
        #expect(model.editor != nil)
        model.goBack()
        // Discarding loses the edits, so the prompt must have been on screen before Return answers.
        model.showPendingPromptLongEnough()
        model.performSelected()
        #expect(model.editor == nil)
        model.files.stop()
    }

    @Test func sidebarSearchPicksTheBestPaneFromWholeWordKeywords() {
        #expect(SettingsSearch.bestPane(for: "login") == .permissions)
        #expect(SettingsSearch.bestPane(for: "export") == .library)
        #expect(SettingsSearch.bestPane(for: "alias") == .shortcuts)
        // A pane title outranks another pane's keyword.
        #expect(SettingsSearch.bestPane(for: "files") == .files)
        // Keywords need word prefixes, never scattered letters, and fold case and accents.
        #expect(SettingsSearch.wordPrefixScore("lgn", in: SettingsPane.permissions.keywords) == nil)
        #expect(SettingsSearch.wordPrefixScore("Éxpo", in: SettingsPane.library.keywords) != nil)
        #expect(SettingsSearch.wordPrefixScore("export backup", in: SettingsPane.library.keywords) != nil)
        #expect(SettingsSearch.wordPrefixScore("export login", in: SettingsPane.library.keywords) == nil)
    }

    @Test func mainsPomodoroAndCaffeinatePanesAreListedAndFoundByTitleAndKeywords() {
        // main: pomodoro, caffeinate. Their panes follow the slices', in this order.
        let mine: [SettingsPane] = [.pomodoro, .caffeinate]
        #expect(SettingsPane.primary.filter(mine.contains) == mine)
        #expect(SettingsPane(rawValue: "pomodoro") == .pomodoro)
        #expect(SettingsPane(rawValue: "caffeinate") == .caffeinate)
        // Focus lists "pomodoro" as a keyword, but Pomodoro's own title wins.
        #expect(SettingsSearch.bestPane(for: "pomodoro") == .pomodoro)
        #expect(SettingsSearch.bestPane(for: "caffeinate") == .caffeinate)
        #expect(SettingsSearch.bestPane(for: "daily goal") == .pomodoro)
        #expect(SettingsSearch.bestPane(for: "awake") == .caffeinate)
    }

    @Test func sidebarSearchKeepsShortcutsForMatchingCommandsOnly() {
        let commands = ["Left Half", "Clipboard History cb"]
        #expect(SettingsSearch.score(.shortcuts, query: "left") == nil)
        #expect(SettingsSearch.score(.shortcuts, query: "left", commands: commands) != nil)
        #expect(SettingsSearch.bestPane(for: "left", commands: commands) == .shortcuts)
        #expect(SettingsSearch.score(.general, query: "left", commands: commands) == nil)
        // A command alias matches too, but a pane's own title still wins.
        #expect(SettingsSearch.score(.shortcuts, query: "cb", commands: commands) != nil)
        #expect(SettingsSearch.bestPane(for: "clipboard", commands: commands) == .clipboard)
        #expect(SettingsSearch.bestPane(for: "zzzz", commands: commands) == nil)
    }

    @Test func settingsSearchTextIncludesTheCommandAlias() throws {
        let model = model()
        defer { model.stop() }
        let command = try #require(model.bindableCommands.first)
        #expect(model.settingsSearchText(for: command) == command.title)
        #expect(model.saveCommandBinding(CommandBinding(targetID: command.id, alias: "zq")))
        #expect(model.settingsSearchText(for: command) == command.title + " zq")
        model.files.stop()
    }

    @Test func sharedAppearancePolicySupportsBothExplicitModesAndSystemFallback() {
        #expect(AppAppearance.light.colorScheme == .light)
        #expect(AppAppearance.dark.colorScheme == .dark)
        #expect(AppAppearance.system.colorScheme == nil)
    }

    private func keyEvent(code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
    }
}
