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

    @Test(arguments: [false, true]) func searchTabOnlyTakesOverWhenAIEntryIsAccepted(accepts: Bool) {
        var query = "Rewrite this passage"
        var entries = 0
        var submissions = 0
        let input = LauncherSearchInput(
            text: Binding(get: { query }, set: { query = $0 }), placeholder: "Search", focusRequest: 0,
            submit: { submissions += 1 }, move: { _ in }, cancel: {}, paste: {},
            enterAI: {
                entries += 1
                if accepts { query = "" }
                return accepts
            })
        let coordinator = input.makeCoordinator()
        let field = FocusedSearchField()
        coordinator.attach(to: field)
        field.stringValue = query
        let editor = NSTextView()
        editor.string = query

        #expect(
            coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))) == accepts)
        #expect(entries == 1)
        #expect(submissions == 0)
        #expect(field.stringValue == (accepts ? "" : "Rewrite this passage"))
        #expect(editor.string == field.stringValue)
    }

    @Test func searchShiftTabKeepsNativeFocusNavigation() {
        var entries = 0
        let input = LauncherSearchInput(
            text: .constant("A question"), placeholder: "Search", focusRequest: 0,
            submit: {}, move: { _ in }, cancel: {}, paste: {},
            enterAI: {
                entries += 1
                return true
            })
        let coordinator = input.makeCoordinator()
        let field = FocusedSearchField()
        let editor = NSTextView()
        editor.string = "A question"

        #expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(entries == 0)
        #expect(editor.string == "A question")
    }

    @Test(arguments: [false, true]) func composerTabCyclesToolsInBothDirectionsWhenAccepted(accepts: Bool) {
        var directions: [Int] = []
        var submissions = 0
        let input = AIComposerInput(
            text: .constant("An unfinished draft"), focusRequest: 0, submit: { submissions += 1 },
            cycleAction: {
                directions.append($0)
                return accepts
            })
        let coordinator = input.makeCoordinator()
        let editor = NSTextView()
        editor.string = "An unfinished draft"

        #expect(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertTab(_:))) == accepts)
        #expect(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))) == accepts)
        #expect(directions == [1, -1])
        #expect(submissions == 0)
        #expect(editor.string == "An unfinished draft")
    }

    @Test func composerReturnStillInsertsANewlineAndEscapeGoesBack() {
        var submissions = 0
        var cancellations = 0
        let input = AIComposerInput(
            text: .constant("An unfinished draft"), focusRequest: 0, submit: { submissions += 1 },
            cancel: { cancellations += 1 })
        let coordinator = input.makeCoordinator()
        let editor = NSTextView()

        #expect(!coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(submissions == 0)
        #expect(coordinator.textView(editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(cancellations == 1)
    }

    @Test func composerSwitchesTheLiveDraftBeforeTheNextNativeKeystroke() {
        var session = "ask"
        var drafts = ["ask": "An Ask draft 🍎", "rewrite": "A Rewrite draft 🍇"]
        let input = AIComposerInput(
            text: Binding(get: { drafts[session] ?? "" }, set: { drafts[session] = $0 }),
            focusRequest: 0, submit: {},
            cycleAction: { direction in
                session = direction == 1 ? "rewrite" : "ask"
                return true
            }, sessionIdentity: { session })
        let coordinator = input.makeCoordinator()
        let editor = NSTextView()
        editor.delegate = coordinator
        editor.string = drafts[session] ?? ""

        #expect(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(editor.string == "A Rewrite draft 🍇")
        #expect(editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" now", replacementRange: editor.selectedRange())
        #expect(drafts["rewrite"] == "A Rewrite draft 🍇 now")
        #expect(drafts["ask"] == "An Ask draft 🍎")

        #expect(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(editor.string == "An Ask draft 🍎")
        editor.insertText(" again", replacementRange: editor.selectedRange())
        #expect(drafts["ask"] == "An Ask draft 🍎 again")
        #expect(drafts["rewrite"] == "A Rewrite draft 🍇 now")
    }

    @Test func switchingComposerSessionsClearsUndoEvenWhenTheirTextMatches() {
        var session = "ask"
        var drafts = ["ask": "A passage", "rewrite": "A passage edited"]
        let input = AIComposerInput(
            text: Binding(get: { drafts[session] ?? "" }, set: { drafts[session] = $0 }),
            focusRequest: 0, submit: {},
            cycleAction: { _ in
                session = "rewrite"
                return true
            }, sessionIdentity: { session })
        let coordinator = input.makeCoordinator()
        let editor = UndoableInputTextView()
        editor.delegate = coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        coordinator.synchronizeEditor(editor)
        editor.history.beginUndoGrouping()
        editor.insertText(" edited", replacementRange: editor.selectedRange())
        editor.history.endUndoGrouping()
        #expect(editor.history.canUndo)
        #expect(drafts["ask"] == "A passage edited")

        #expect(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(editor.string == "A passage edited")
        #expect(!editor.history.canUndo)
        editor.history.beginUndoGrouping()
        editor.insertText(" in Rewrite", replacementRange: editor.selectedRange())
        editor.history.endUndoGrouping()
        #expect(drafts["rewrite"] == "A passage edited in Rewrite")
        editor.history.undo()
        #expect(editor.string == "A passage edited")
        #expect(drafts["rewrite"] == "A passage edited")
        #expect(drafts["ask"] == "A passage edited")
        editor.history.redo()
        #expect(editor.string == "A passage edited in Rewrite")
        #expect(drafts["rewrite"] == "A passage edited in Rewrite")
        #expect(drafts["ask"] == "A passage edited")
    }

    @Test func nativeInsertionSynchronizesAnExternallySelectedComposerSession() {
        var session = "ask"
        var drafts = ["ask": "A long Ask draft", "rewrite": "Rewrite"]
        let input = AIComposerInput(
            text: Binding(get: { drafts[session] ?? "" }, set: { drafts[session] = $0 }),
            focusRequest: 0, submit: {}, sessionIdentity: { session })
        let coordinator = input.makeCoordinator()
        let editor = FocusedComposerTextView()
        editor.delegate = coordinator
        editor.prepareForInput = { [weak editor] in
            if let editor { coordinator.synchronizeEditor(editor) }
        }
        coordinator.synchronizeEditor(editor)

        session = "rewrite"
        editor.insertText(" now", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(editor.string == "Rewrite now")
        #expect(drafts["rewrite"] == "Rewrite now")
        #expect(drafts["ask"] == "A long Ask draft")
    }

    @Test func synchronizingTypingWithinOneComposerSessionPreservesNativeUndo() {
        var draft = "A passage"
        let input = AIComposerInput(
            text: Binding(get: { draft }, set: { draft = $0 }), focusRequest: 0, submit: {})
        let coordinator = input.makeCoordinator()
        let editor = UndoableInputTextView()
        editor.delegate = coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        coordinator.synchronizeEditor(editor)
        editor.history.beginUndoGrouping()
        editor.insertText(" edited", replacementRange: editor.selectedRange())
        editor.history.endUndoGrouping()
        #expect(draft == "A passage edited")

        coordinator.synchronizeEditor(editor)

        #expect(editor.history.canUndo)
        editor.history.undo()
        #expect(editor.string == "A passage")
        #expect(draft == "A passage")
        editor.history.redo()
        #expect(editor.string == "A passage edited")
        #expect(draft == "A passage edited")
    }

    @Test func searchCommandsLeaveInputMethodCompositionAlone() {
        var actions: [String] = []
        let input = LauncherSearchInput(
            text: .constant(""), placeholder: "Search", focusRequest: 0,
            submit: { actions.append("submit") }, move: { _ in actions.append("move") },
            cancel: { actions.append("cancel") }, paste: { actions.append("paste") },
            enterAI: {
                actions.append("AI")
                return true
            })
        let coordinator = input.makeCoordinator()
        let field = FocusedSearchField()
        let editor = NSTextView()
        editor.setMarkedText(
            "に", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        #expect(editor.hasMarkedText())

        for command in [
            #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
            #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)),
            #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)),
        ] {
            #expect(!coordinator.control(field, textView: editor, doCommandBy: command))
        }
        #expect(actions.isEmpty)
        #expect(editor.hasMarkedText())
        #expect(editor.string == "に")
    }

    @Test func composerCommandsLeaveInputMethodCompositionAlone() {
        var actions: [String] = []
        let input = AIComposerInput(
            text: .constant(""), focusRequest: 0, submit: { actions.append("submit") },
            cycleAction: { _ in
                actions.append("cycle")
                return true
            }, cancel: { actions.append("cancel") })
        let coordinator = input.makeCoordinator()
        let editor = NSTextView()
        editor.setMarkedText(
            "に", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        #expect(editor.hasMarkedText())

        for command in [
            #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
            #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)),
        ] {
            #expect(!coordinator.textView(editor, doCommandBy: command))
        }
        // Marked text has not called textDidChange yet, so the binding still
        // contains the old draft when a render or the next key synchronizes it.
        coordinator.synchronizeEditor(editor)
        #expect(actions.isEmpty)
        #expect(editor.hasMarkedText())
        #expect(editor.string == "に")
    }

    @Test func actionsUseNativeMenuItemsWithIndependentRetainedHandlers() {
        var actions: [String] = []
        let presenter = NativeActionsMenu(
            isPresented: .constant(true), title: "Calculator",
            entries: [
                .init(title: "Open", symbol: "return") { actions.append("open") },
                .init(title: "Favorite", symbol: "star") { actions.append("favorite") },
                .init(title: "Settings", symbol: "gearshape") { actions.append("settings") },
            ], didClose: {})
        let coordinator = presenter.makeCoordinator()
        let menu = coordinator.makeMenu()

        #expect(menu.items.filter { !$0.isHidden }.map(\.title) == ["Calculator", "", "Open", "Favorite", "Settings"])
        #expect(menu.items[0].isEnabled == false)
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[3].isEnabled)
        menu.performActionForItem(at: 3)
        #expect(actions == ["favorite"])
        menu.performActionForItem(at: 4)
        #expect(actions == ["favorite", "settings"])
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

@MainActor
private final class UndoableInputTextView: NSTextView {
    let history = UndoManager()
    override var undoManager: UndoManager? { history }
}
