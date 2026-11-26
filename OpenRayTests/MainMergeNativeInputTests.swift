import AppKit
import SwiftUI
import Testing

@testable import OpenRay

/// main #12/#13's native input behavior on the 2.0 controls. Keys inside AI follow main (an
/// owner decision): ↩ sends, ⌘↩ and ⇧↩ insert a new line, a held ↩ never sends twice, and an
/// input method's composition always gets its keys first.
@MainActor
struct MainMergeNativeInputTests {
    private func composer(
        _ draft: Binding<String>, submit: @escaping () -> Void = {}, session: @escaping () -> String = { "composer" }
    ) -> (AIComposerInput.Coordinator, FocusedComposerTextView) {
        let input = AIComposerInput(text: draft, focusRequest: 0, submit: submit, sessionIdentity: session)
        let coordinator = input.makeCoordinator()
        let editor = FocusedComposerTextView()
        editor.delegate = coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        editor.prepareForInput = { [weak editor] in
            if let editor { coordinator.synchronizeEditor(editor) }
        }
        coordinator.synchronizeEditor(editor)
        return (coordinator, editor)
    }

    @Test(arguments: [UInt16(36), UInt16(76)])
    func returnSendsOncePerPressAndClearsTheEditorBeforeTheNextKey(keyCode: UInt16) {
        var draft = "Please improve this 🍎"
        var sent: [String] = []
        let (_, editor) = composer(
            Binding(get: { draft }, set: { draft = $0 }),
            submit: {
                sent.append(draft)
                draft = ""
            })
        editor.keyDown(with: returnEvent(keyCode: keyCode))
        #expect(sent == ["Please improve this 🍎"])
        #expect(editor.string.isEmpty)
        // A held ↩ never sends again (and so never goes on to accept a result).
        editor.keyDown(with: returnEvent(keyCode: keyCode, isARepeat: true))
        #expect(sent.count == 1)
        editor.insertText("Make it shorter", replacementRange: editor.selectedRange())
        #expect(draft == "Make it shorter")
    }

    @Test(arguments: [NSEvent.ModifierFlags.command, .shift])
    func commandAndShiftReturnInsertANewLineWithoutSending(modifier: NSEvent.ModifierFlags) {
        var draft = "First Second"
        var submissions = 0
        let (_, editor) = composer(Binding(get: { draft }, set: { draft = $0 }), submit: { submissions += 1 })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = editor
        #expect(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 5, length: 1))

        editor.undoManager?.beginUndoGrouping()
        if modifier == .command {
            #expect(editor.performKeyEquivalent(with: returnEvent(modifiers: modifier)))
        } else {
            editor.keyDown(with: returnEvent(modifiers: modifier))
        }
        editor.undoManager?.endUndoGrouping()
        #expect(draft == "First\nSecond")
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
        #expect(submissions == 0)
        // It went through the typing path, so undo takes it back.
        editor.undoManager?.undo()
        #expect(editor.string == "First Second")
        #expect(draft == "First Second")
    }

    @Test func returnDuringAnInputMethodCompositionNeverSends() {
        var draft = "Original "
        var submissions = 0
        let (_, editor) = composer(Binding(get: { draft }, set: { draft = $0 }), submit: { submissions += 1 })
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        #expect(editor.hasMarkedText())
        editor.keyDown(with: returnEvent())
        #expect(submissions == 0)
        // Whatever the input method made of the key, the draft follows the editor; synchronizing
        // never puts back the text from before the composition.
        #expect(editor.string != "Original ")
        #expect(draft == editor.string)
    }

    @Test func composerCommandsLeaveAnInputMethodCompositionAlone() {
        var submissions = 0
        let (coordinator, _) = composer(.constant(""), submit: { submissions += 1 })
        let editor = NSTextView()
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        for command in [
            #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
            #selector(NSResponder.insertNewline(_:)),
        ] {
            #expect(!coordinator.textView(editor, doCommandBy: command))
        }
        coordinator.synchronizeEditor(editor)
        #expect(submissions == 0)
        #expect(editor.hasMarkedText())
        #expect(editor.string == "に")
    }

    @Test func sendingOrSwitchingConversationStartsAFreshUndoHistory() {
        var draft = "A passage"
        var session = "first"
        let (coordinator, _) = composer(
            Binding(get: { draft }, set: { draft = $0 }), submit: { draft = "" }, session: { session })
        let undoable = UndoableComposer()
        let history = undoable.history
        undoable.delegate = coordinator
        undoable.isRichText = false
        undoable.allowsUndo = true
        coordinator.synchronizeEditor(undoable)
        history.beginUndoGrouping()
        undoable.insertText(" edited", replacementRange: undoable.selectedRange())
        history.endUndoGrouping()
        #expect(draft == "A passage edited")
        // Typing within one conversation keeps its undo.
        coordinator.synchronizeEditor(undoable)
        #expect(history.canUndo)

        #expect(coordinator.textView(undoable, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(undoable.string.isEmpty)
        #expect(!history.canUndo)

        draft = "Same text"
        coordinator.synchronizeEditor(undoable)
        history.beginUndoGrouping()
        undoable.insertText("!", replacementRange: undoable.selectedRange())
        history.endUndoGrouping()
        session = "second"
        coordinator.synchronizeEditor(undoable)
        #expect(!history.canUndo)
    }

    @Test func tabMovesFocusInsteadOfTypingATab() {
        var draft = "A draft"
        let (coordinator, editor) = composer(Binding(get: { draft }, set: { draft = $0 }))
        #expect(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(draft == "A draft")
    }

    private func returnEvent(
        keyCode: UInt16 = 36, modifiers: NSEvent.ModifierFlags = [], isARepeat: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: isARepeat, keyCode: keyCode)!
    }
}

private final class UndoableComposer: NSTextView {
    let history = UndoManager()
    override var undoManager: UndoManager? { history }
}
