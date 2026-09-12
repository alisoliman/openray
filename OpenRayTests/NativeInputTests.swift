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

    @Test func composerTabTraversesControlsWithoutChangingItsDraft() {
        var submissions = 0
        let input = AIComposerInput(
            text: .constant("An unfinished draft"), focusRequest: 0, submit: { submissions += 1 })
        let coordinator = input.makeCoordinator()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: .titled,
            backing: .buffered, defer: false)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let next = NSTextField(frame: NSRect(x: 0, y: 110, width: 200, height: 24))
        let previous = NSTextField(frame: NSRect(x: 0, y: 140, width: 200, height: 24))
        window.contentView?.addSubview(editor)
        window.contentView?.addSubview(next)
        window.contentView?.addSubview(previous)
        editor.string = "An unfinished draft"
        editor.nextKeyView = next
        next.nextKeyView = previous
        previous.nextKeyView = editor
        #expect(window.makeFirstResponder(editor))

        #expect(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(next.currentEditor() === window.firstResponder)
        #expect(window.makeFirstResponder(editor))
        #expect(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(previous.currentEditor() === window.firstResponder)
        #expect(submissions == 0)
        #expect(editor.string == "An unfinished draft")
    }

    @Test func composerTabReachesAndActivatesASwiftUIButtonInAHostingView() async throws {
        var activations = 0
        let host = NSHostingView(
            rootView: VStack {
                AIComposerInput(text: .constant("An unfinished draft"), focusRequest: 0, submit: {})
                    .frame(height: 80)
                AIKeyboardButton("Next action") { activations += 1 }
            }.frame(width: 400, height: 150))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 150), styleMask: .titled,
            backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let editor = try #require(findComposer(in: host))
        window.recalculateKeyViewLoop()
        #expect(window.makeFirstResponder(editor))

        window.sendEvent(composerKeyEvent(keyCode: 48, characters: "\t", windowNumber: window.windowNumber))
        await Task.yield()

        #expect(window.firstResponder !== editor)
        window.sendEvent(composerKeyEvent(keyCode: 49, characters: " ", windowNumber: window.windowNumber))
        await Task.yield()
        #expect(activations == 1)
        window.sendEvent(composerReturnEvent(windowNumber: window.windowNumber))
        await Task.yield()
        #expect(activations == 2)
        window.sendEvent(
            composerKeyEvent(keyCode: 48, characters: "\t", modifiers: .shift, windowNumber: window.windowNumber))
        await Task.yield()
        #expect(window.firstResponder === editor)
        #expect(editor.string == "An unfinished draft")
    }

    @Test func composerReturnSendsAndEscapeGoesBack() {
        var submissions = 0
        var cancellations = 0
        let input = AIComposerInput(
            text: .constant("An unfinished draft"), focusRequest: 0, submit: { submissions += 1 },
            cancel: { cancellations += 1 })
        let coordinator = input.makeCoordinator()
        let editor = NSTextView()

        #expect(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(submissions == 1)
        #expect(coordinator.textView(editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(cancellations == 1)
    }

    @Test(arguments: [UInt16(36), UInt16(76)])
    func nativeReturnSendsAndSynchronizesBeforeTheNextKeystroke(keyCode: UInt16) {
        var draft = "Please improve this 🍎"
        var sent: [String] = []
        let input = AIComposerInput(
            text: Binding(get: { draft }, set: { draft = $0 }), focusRequest: 0,
            submit: {
                sent.append(draft)
                draft = ""
            })
        let coordinator = input.makeCoordinator()
        let editor = FocusedComposerTextView()
        editor.delegate = coordinator
        editor.prepareForInput = { [weak editor] in
            if let editor { coordinator.synchronizeEditor(editor) }
        }
        coordinator.synchronizeEditor(editor)

        editor.keyDown(with: composerReturnEvent(keyCode: keyCode))

        #expect(sent == ["Please improve this 🍎"])
        #expect(draft.isEmpty)
        #expect(editor.string.isEmpty)
        editor.keyDown(with: composerReturnEvent(keyCode: keyCode, isARepeat: true))
        #expect(sent.count == 1)
        #expect(editor.string.isEmpty)
        editor.insertText("Make it shorter", replacementRange: editor.selectedRange())
        #expect(draft == "Make it shorter")
        #expect(editor.string == "Make it shorter")
    }

    @Test(arguments: [false, true])
    func nativeCommandReturnInsertsANewlineWithoutSending(asKeyEquivalent: Bool) {
        var draft = "First Second"
        var submissions = 0
        let input = AIComposerInput(
            text: Binding(get: { draft }, set: { draft = $0 }), focusRequest: 0,
            submit: { submissions += 1 })
        let coordinator = input.makeCoordinator()
        let editor = FocusedComposerTextView()
        editor.delegate = coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: .titled,
            backing: .buffered, defer: false)
        window.contentView = editor
        coordinator.synchronizeEditor(editor)
        editor.setSelectedRange(NSRange(location: 5, length: 1))
        let event = composerReturnEvent(modifiers: .command)

        editor.undoManager?.beginUndoGrouping()
        if asKeyEquivalent {
            #expect(editor.performKeyEquivalent(with: event))
        } else {
            editor.keyDown(with: event)
        }
        editor.undoManager?.endUndoGrouping()

        #expect(draft == "First\nSecond")
        #expect(editor.string == "First\nSecond")
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
        #expect(submissions == 0)
        #expect(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        #expect(editor.string == "First Second")
        #expect(draft == "First Second")
    }

    @Test func submittingClearsPreviousDraftUndoBeforeTheNextNativeEdit() {
        var draft = "A passage"
        let input = AIComposerInput(
            text: Binding(get: { draft }, set: { draft = $0 }), focusRequest: 0,
            submit: { draft = "" })
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

        #expect(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))

        #expect(editor.string.isEmpty)
        #expect(draft.isEmpty)
        #expect(!editor.history.canUndo)
        editor.history.beginUndoGrouping()
        editor.insertText("A follow-up", replacementRange: editor.selectedRange())
        editor.history.endUndoGrouping()
        editor.history.undo()
        #expect(editor.string.isEmpty)
        #expect(draft.isEmpty)
    }

    @Test func nativeReturnDuringInputMethodCompositionDoesNotSend() {
        var draft = "Original "
        var submissions = 0
        let input = AIComposerInput(
            text: Binding(get: { draft }, set: { draft = $0 }), focusRequest: 0,
            submit: { submissions += 1 })
        let coordinator = input.makeCoordinator()
        let editor = FocusedComposerTextView()
        editor.delegate = coordinator
        editor.prepareForInput = { [weak editor] in
            if let editor { coordinator.synchronizeEditor(editor) }
        }
        coordinator.synchronizeEditor(editor)
        editor.setMarkedText(
            "に", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        #expect(editor.hasMarkedText())

        editor.keyDown(with: composerReturnEvent())

        #expect(submissions == 0)
        // Synchronization must not restore the pre-composition binding while
        // AppKit handles Return and may have already cleared its marked range.
        #expect(editor.string == "Original に")
    }

    @Test func composerSwitchesTheLiveDraftBeforeTheNextNativeKeystroke() {
        let state = ComposerDraftState(["ask": "An Ask draft 🍎", "rewrite": "A Rewrite draft 🍇"])
        let input = AIComposerInput(
            text: Binding(get: { state.drafts[state.session] ?? "" }, set: { state.drafts[state.session] = $0 }),
            focusRequest: 0, submit: {}, sessionIdentity: { state.session })
        let coordinator = input.makeCoordinator()
        let editor = NSTextView()
        editor.delegate = coordinator
        editor.string = state.drafts[state.session] ?? ""

        state.session = "rewrite"
        coordinator.synchronizeEditor(editor)
        #expect(editor.string == "A Rewrite draft 🍇")
        #expect(editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" now", replacementRange: editor.selectedRange())
        #expect(state.drafts["rewrite"] == "A Rewrite draft 🍇 now")
        #expect(state.drafts["ask"] == "An Ask draft 🍎")

        state.session = "ask"
        coordinator.synchronizeEditor(editor)
        #expect(editor.string == "An Ask draft 🍎")
        editor.insertText(" again", replacementRange: editor.selectedRange())
        #expect(state.drafts["ask"] == "An Ask draft 🍎 again")
        #expect(state.drafts["rewrite"] == "A Rewrite draft 🍇 now")
    }

    @Test func switchingComposerSessionsClearsUndoEvenWhenTheirTextMatches() {
        let state = ComposerDraftState(["ask": "A passage", "rewrite": "A passage edited"])
        let input = AIComposerInput(
            text: Binding(get: { state.drafts[state.session] ?? "" }, set: { state.drafts[state.session] = $0 }),
            focusRequest: 0, submit: {}, sessionIdentity: { state.session })
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
        #expect(state.drafts["ask"] == "A passage edited")

        state.session = "rewrite"
        coordinator.synchronizeEditor(editor)
        #expect(editor.string == "A passage edited")
        #expect(!editor.history.canUndo)
        editor.history.beginUndoGrouping()
        editor.insertText(" in Rewrite", replacementRange: editor.selectedRange())
        editor.history.endUndoGrouping()
        #expect(state.drafts["rewrite"] == "A passage edited in Rewrite")
        editor.history.undo()
        #expect(editor.string == "A passage edited")
        #expect(state.drafts["rewrite"] == "A passage edited")
        #expect(state.drafts["ask"] == "A passage edited")
        editor.history.redo()
        #expect(editor.string == "A passage edited in Rewrite")
        #expect(state.drafts["rewrite"] == "A passage edited in Rewrite")
        #expect(state.drafts["ask"] == "A passage edited")
    }

    @Test func nativeInsertionSynchronizesAnExternallySelectedComposerSession() {
        let state = ComposerDraftState(["ask": "A long Ask draft", "rewrite": "Rewrite"])
        let input = AIComposerInput(
            text: Binding(get: { state.drafts[state.session] ?? "" }, set: { state.drafts[state.session] = $0 }),
            focusRequest: 0, submit: {}, sessionIdentity: { state.session })
        let coordinator = input.makeCoordinator()
        let editor = FocusedComposerTextView()
        editor.delegate = coordinator
        editor.prepareForInput = { [weak editor] in
            if let editor { coordinator.synchronizeEditor(editor) }
        }
        coordinator.synchronizeEditor(editor)

        state.session = "rewrite"
        editor.insertText(" now", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(editor.string == "Rewrite now")
        #expect(state.drafts["rewrite"] == "Rewrite now")
        #expect(state.drafts["ask"] == "A long Ask draft")
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
            cancel: { actions.append("cancel") })
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

    @Test func panelCancelHidesFromAnOrdinaryTextEditor() {
        let panel = LauncherPanel()
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        panel.contentView = editor
        #expect(panel.makeFirstResponder(editor))
        var cancellations = 0
        panel.onCancel = { cancellations += 1 }
        panel.cancelOperation(nil)
        #expect(cancellations == 1)
    }

    @Test func panelCancelPreservesInputMethodComposition() {
        let panel = LauncherPanel()
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        panel.contentView = editor
        #expect(panel.makeFirstResponder(editor))
        editor.setMarkedText(
            "に", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        #expect(editor.hasMarkedText())
        var cancellations = 0
        panel.onCancel = { cancellations += 1 }

        panel.cancelOperation(nil)

        #expect(cancellations == 0)
        #expect(editor.string == "に")
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

@MainActor
private func composerReturnEvent(
    keyCode: UInt16 = 36, modifiers: NSEvent.ModifierFlags = [], isARepeat: Bool = false, windowNumber: Int = 0
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: windowNumber,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: isARepeat,
        keyCode: keyCode)!
}

@MainActor
private func composerKeyEvent(
    keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], windowNumber: Int = 0
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
        keyCode: keyCode)!
}

@MainActor
private func findComposer(in view: NSView) -> FocusedComposerTextView? {
    if let editor = view as? FocusedComposerTextView { return editor }
    return view.subviews.lazy.compactMap { findComposer(in: $0) }.first
}

@MainActor
private final class ComposerDraftState {
    var session = "ask"
    var drafts: [String: String]

    init(_ drafts: [String: String]) { self.drafts = drafts }
}
