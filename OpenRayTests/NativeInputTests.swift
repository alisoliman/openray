import AppKit
import SwiftUI
import Testing

@testable import OpenRay

@MainActor
struct NativeInputTests {
    @Test(arguments: [false, true]) func navigationClearsTheNativeEditorBeforeTheNextKeystroke(submitting: Bool) {
        var query = "previous query"
        let input = LauncherSearchInput(
            text: Binding(get: { query }, set: { query = $0 }), placeholder: "Search", focusRequest: 0,
            submit: { query = "" }, move: { _ in }, cancel: { query = "" }, paste: {})
        let coordinator = input.makeCoordinator()
        let field = FocusedSearchField()
        coordinator.attach(to: field)
        field.stringValue = query
        let editor = NSTextView()
        editor.string = query
        let command = submitting ? #selector(NSResponder.insertNewline(_:)) : #selector(NSResponder.cancelOperation(_:))
        #expect(coordinator.control(field, textView: editor, doCommandBy: command))
        #expect(query.isEmpty)
        #expect(field.stringValue.isEmpty)
        #expect(editor.string.isEmpty)
    }

    /// Korean, Japanese and Chinese input keep uncommitted text out of the model. Syncing the
    /// query must leave that composition alone rather than treat it as a mismatch.
    @Test func syncingTheQueryKeepsAnInputMethodComposition() {
        var query = "한"
        let input = LauncherSearchInput(
            text: Binding(get: { query }, set: { query = $0 }), placeholder: "Search", focusRequest: 0,
            submit: {}, move: { _ in }, cancel: {}, paste: {})
        let coordinator = input.makeCoordinator()
        let field = FocusedSearchField()
        coordinator.attach(to: field)
        field.stringValue = query
        let editor = NSTextView()
        editor.string = query
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "한ㄱ")
        #expect(LauncherSearchInput.committedText(of: editor) == "한")
        // ↓ moves the selection and then syncs the field with the model.
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(editor.hasMarkedText())
        #expect(editor.string == "한ㄱ")
        #expect(query == "한")
    }

    @Test func emptySearchHasANativeReturnActionWithoutRequiringTextEditing() {
        var submissions = 0
        let input = LauncherSearchInput(
            text: .constant(""), placeholder: "Search", focusRequest: 0,
            submit: { submissions += 1 }, move: { _ in }, cancel: {}, paste: {})
        let coordinator = input.makeCoordinator()
        let field = FocusedSearchField()
        coordinator.attach(to: field)
        field.stringValue = "a previous search"
        field.stringValue = ""
        #expect(field.action != nil)
        #expect(field.target === coordinator)
        #expect(field.cell?.sendsActionOnEndEditing == false)
        #expect(!field.isContinuous)
        #expect(field.sendAction(field.action, to: field.target))
        #expect(submissions == 1)
    }

    @Test func actionPanelFiltersAndRunsTheHighlightedEntry() {
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName())
        defer { model.stop() }
        model.query = "Snippets"
        model.files.stop()
        model.synchronizeSelection()
        model.showActions = true
        #expect(model.actionEntries.first?.shortcut == .return)
        #expect(model.actionEntries.contains { $0.id == "favorite" && $0.shortcut?.caps == ["⇧", "⌘", "F"] })
        model.actionFilter = "favor"
        // Move Favorite Up matches too; the toggle comes first and is highlighted.
        #expect(model.filteredActionEntries.first?.id == "favorite")
        let wasFavorite = model.store.database.favoriteIDs.contains("section.snippets")
        model.performActionSelection()
        #expect(!model.showActions)
        #expect(model.store.database.favoriteIDs.contains("section.snippets") != wasFavorite)
        #expect(model.section == .home)
    }

    @Test func tabAndDeleteOnTheSearchFieldReachTheModel() {
        var tabs = 0
        var deletes = 0
        let input = LauncherSearchInput(
            text: .constant(""), placeholder: "Search", focusRequest: 0,
            submit: {}, move: { _ in }, cancel: {}, paste: {},
            tab: { tabs += 1 }, deleteOnEmpty: {
                deletes += 1
                return true
            })
        let coordinator = input.makeCoordinator()
        let field = FocusedSearchField()
        coordinator.attach(to: field)
        let editor = NSTextView()
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        editor.string = "query"
        #expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        #expect(tabs == 1)
        #expect(deletes == 1)
    }

    @Test func shortcutCapsFollowMacOrderAndKeepMultiWordKeysWhole() {
        #expect(KeyShortcut.command("F", shift: true).caps == ["⇧", "⌘", "F"])
        #expect(CommandShortcut(keyCode: 116, modifiers: [.command, .shift]).caps == ["⇧", "⌘", "Page Up"])
        #expect(CommandShortcut(keyCode: 83, modifiers: [.option, .control]).caps == ["⌃", "⌥", "Keypad 1"])
        #expect(CommandShortcut(keyCode: 36, modifiers: .command).caps == ["⌘", "↩"])
        #expect(CommandShortcut(keyCode: 51, modifiers: .option).caps == ["⌥", "⌫"])
        #expect(CommandShortcut(keyCode: 53, modifiers: .control).caps == ["⌃", "esc"])
        // Validation messages keep the worded title.
        #expect(CommandShortcut(keyCode: 36, modifiers: .command).title == "⌘ Return")
        let pageUp = KeyShortcut(CommandShortcut(keyCode: 116, modifiers: [.command, .shift]))
        #expect(pageUp.caps == ["⇧", "⌘", "Page Up"])
        #expect(pageUp.spoken == "Shift Command Page Up")
        #expect(KeyShortcut(CommandShortcut(keyCode: 36, modifiers: .command)).spoken == "Command Return")
    }

    @Test func menuKeyEquivalentsCoverNavigationAndFunctionKeysButNotKeypadOrHelp() {
        func equivalent(_ keyCode: UInt32) -> Character? {
            CommandShortcut(keyCode: keyCode, modifiers: .command).keyEquivalent?.character
        }
        #expect(equivalent(115) == KeyEquivalent.home.character)
        #expect(equivalent(119) == KeyEquivalent.end.character)
        #expect(equivalent(116) == KeyEquivalent.pageUp.character)
        #expect(equivalent(121) == KeyEquivalent.pageDown.character)
        #expect(equivalent(117) == KeyEquivalent.deleteForward.character)
        #expect(equivalent(122) == UnicodeScalar(UInt32(NSF1FunctionKey)).map(Character.init))
        #expect(equivalent(90) == UnicodeScalar(UInt32(NSF1FunctionKey + 19)).map(Character.init))
        #expect(equivalent(83) == nil)
        #expect(equivalent(76) == nil)
        #expect(equivalent(114) == nil)
        // Printable keys use the layout's own, un-uppercased character.
        #expect(equivalent(0).map { !$0.isUppercase } == true)
    }

    @Test func escapeFromPanelRoutesToBackWithoutAnEditingResponder() {
        let panel = LauncherPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        var cancellations = 0
        panel.onCancel = { cancellations += 1 }
        panel.cancelOperation(nil)
        #expect(cancellations == 1)
    }

    @Test func panelCancelLeavesAnActiveTextEditorInPlace() {
        let panel = LauncherPanel()
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        panel.contentView = editor
        #expect(panel.makeFirstResponder(editor))
        var cancellations = 0
        panel.onCancel = { cancellations += 1 }
        panel.cancelOperation(nil)
        #expect(cancellations == 0)
    }

    @Test func assistantMarkdownKeepsParagraphsAndListMarkersAndRendersEmphasis() {
        let message = ChatMessage(role: .assistant, text: "1. **Dog**: A companion.\n\n2. `Cat`: An animal.")
        let rendered = AIMessageText.attributedText(for: message)
        #expect(String(rendered.characters) == "1. Dog: A companion.\n\n2. Cat: An animal.")
        #expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    @Test func userTextStaysVerbatimAndGeneratedLinksAreInert() {
        let source = "**A passage** [example](https://example.com)"
        let user = AIMessageText.attributedText(for: ChatMessage(role: .user, text: source))
        #expect(String(user.characters) == source)
        let assistant = AIMessageText.attributedText(for: ChatMessage(role: .assistant, text: source))
        #expect(String(assistant.characters) == "A passage example")
        #expect(assistant.runs.allSatisfy { $0.link == nil })
    }
}
