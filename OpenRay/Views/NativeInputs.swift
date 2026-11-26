import AppKit
import SwiftUI

/// Floating NSHostingView panels don't have SwiftUI's scene focus lifecycle.
/// These controls restore the real first responder without resigning an active
/// editor, which would commit stale text or drop keystrokes during navigation.
struct LauncherSearchInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusRequest: Int
    var submit: () -> Void
    var move: (Int) -> Void
    var cancel: () -> Void
    var paste: () -> Void
    var tab: () -> Void = {}
    /// ⌫ on an empty field. Return true to consume it (removing a token).
    var deleteOnEmpty: () -> Bool = { false }
    /// ← and →. Return true when they moved a grid selection instead of the caret.
    var moveHorizontally: (Int) -> Bool = { _ in false }
    /// ⌘↑ and ⌘↓: jump between result sections. Nil leaves them to the field.
    var jump: ((Int) -> Void)? = nil
    /// ⇧Tab. Nil leaves it to the field.
    var backtab: (() -> Void)? = nil
    /// ⌥↩. Nil makes it act like ↩.
    var tertiary: (() -> Void)? = nil
    var selectsAllOnFocus = false
    var didSelectAll: () -> Void = {}
    /// False for fields that should take the keyboard only when asked, such as all but the
    /// focused argument field; otherwise each new field would take it as it appears.
    var autoFocus = true
    /// Masks the text, for password arguments.
    var secure = false
    /// Called when the field becomes first responder, as when it's clicked.
    var onFocus: (() -> Void)? = nil
    /// Keeps keyboard focus for Return and Esc, but takes no text and shows no caret.
    var readOnly = false
    var fontSize: CGFloat = 20
    var accessibilityLabel = "Search OpenRay"
    var identifier = "launcher.search"

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> FocusedSearchField {
        let field = secure ? FocusedSecureSearchField() : FocusedSearchField()
        field.takesFocusAutomatically = autoFocus
        context.coordinator.attach(to: field)
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = OR.NS.text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(accessibilityLabel)
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    func updateNSView(_ field: FocusedSearchField, context: Context) {
        context.coordinator.parent = self
        field.takesFocusAutomatically = autoFocus
        field.onBecomeFirstResponder = onFocus
        if field.isReadOnly != readOnly {
            field.isReadOnly = readOnly
            (field.currentEditor() as? NSTextView).map(field.configure)
        }
        // Setting placeholderString would replace the text-3 attributed placeholder.
        if field.placeholderAttributedString?.string != placeholder {
            let attributed = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: OR.NS.text3, .font: NSFont.systemFont(ofSize: fontSize)])
            field.placeholderAttributedString = attributed
            // While editing, the field editor draws its own copy of the placeholder, taken when
            // editing began, so a scope changing under the focused field left the old text
            // showing. Update that copy too, if this macOS still has it.
            if let editor = field.currentEditor() as? NSTextView,
                editor.responds(to: Selector(("setPlaceholderAttributedString:")))
            {
                editor.setValue(attributed, forKey: "placeholderAttributedString")
                editor.needsDisplay = true
            }
        }
        let editor = field.currentEditor() as? NSTextView
        // An input method's marked text isn't in the model until it's committed, so compare
        // only the committed text; otherwise every update would wipe a composition.
        if (editor.map(Self.committedText) ?? field.stringValue) != text {
            context.coordinator.isApplyingModel = true
            field.stringValue = text
            context.coordinator.isApplyingModel = false
            // Replacing the text selects all of it; put the caret at the end instead.
            editor?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        if field.focusRequest != focusRequest {
            field.focusRequest = focusRequest
            // Only a field that should hold the keyboard takes it; a field losing focus never does.
            if autoFocus { field.focusIfNeeded() }
            if selectsAllOnFocus, field.currentEditor() != nil {
                field.currentEditor()?.selectAll(nil)
                DispatchQueue.main.async { didSelectAll() }
            }
        }
    }

    /// An editor's text without the input method's marked (uncommitted) range.
    static func committedText(of editor: NSTextView) -> String {
        guard editor.hasMarkedText() else { return editor.string }
        return (editor.string as NSString).replacingCharacters(in: editor.markedRange(), with: "")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusedSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: ceil(fontSize * 1.4))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LauncherSearchInput
        /// Set while the model's text is written into the field, so the write isn't echoed back.
        var isApplyingModel = false
        init(parent: LauncherSearchInput) { self.parent = parent }

        func attach(to field: NSTextField) {
            field.delegate = self
            field.target = self
            field.action = #selector(submitted(_:))
            field.cell?.sendsActionOnEndEditing = false
            field.isContinuous = false
        }

        @objc func submitted(_ sender: Any?) {
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true { parent.paste() } else { parent.submit() }
            if let field = sender as? NSTextField {
                synchronizeQuery(in: field, editor: field.currentEditor() as? NSTextView)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isApplyingModel, let field = notification.object as? NSTextField else { return }
            if parent.readOnly {
                synchronizeQuery(in: field, editor: field.currentEditor() as? NSTextView)
                return
            }
            parent.text = field.stringValue
            // The model can transform the query, such as turning “web ” into a token.
            if parent.text != field.stringValue {
                synchronizeQuery(in: field, editor: field.currentEditor() as? NSTextView)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveLeft(_:)):
                guard parent.moveHorizontally(-1) else { return false }
            case #selector(NSResponder.moveRight(_:)):
                guard parent.moveHorizontally(1) else { return false }
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            case #selector(NSResponder.insertTab(_:)): parent.tab()
            case #selector(NSResponder.insertBacktab(_:)):
                guard let backtab = parent.backtab else { return false }
                backtab()
            case #selector(NSResponder.moveToBeginningOfDocument(_:)):
                guard let jump = parent.jump else { return false }
                jump(-1)
            case #selector(NSResponder.moveToEndOfDocument(_:)):
                guard let jump = parent.jump else { return false }
                jump(1)
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // ⌥↩ runs the tertiary action where there is one.
                if let tertiary = parent.tertiary { tertiary() } else { submitted(control) }
            case #selector(NSResponder.deleteBackward(_:)):
                guard textView.string.isEmpty else { return false }
                // Holding ⌫ to clear the query must not go on to remove tokens.
                if isRepeatedKeyDown { return true }
                guard parent.deleteOnEmpty() else { return false }
            case #selector(NSResponder.insertNewline(_:)):
                submitted(control)
            default: return false
            }
            if let field = control as? NSTextField { synchronizeQuery(in: field, editor: textView) }
            return true
        }

        private func synchronizeQuery(in field: NSTextField, editor: NSTextView?) {
            // Navigation can replace the query before SwiftUI updates this view.
            // Clear the live editor now so the next keystroke cannot restore stale text.
            let query = parent.text
            // While editing, the field reads its text from the editor, marked text included.
            let editorText = editor.map(LauncherSearchInput.committedText)
            let fieldText = editor?.hasMarkedText() == true ? editorText ?? "" : field.stringValue
            guard fieldText != query || (editorText.map { $0 != query } ?? false) else { return }
            // Setting stringValue selects all of it, so a restored keyword would be
            // replaced by the next key. Leave the caret at the end, ready to edit.
            isApplyingModel = true
            defer { isApplyingModel = false }
            if field.stringValue != query { field.stringValue = query }
            if let editor {
                if editor.string != query { editor.string = query }
                editor.setSelectedRange(NSRange(location: query.utf16.count, length: 0))
            }
        }
    }
}

class FocusedSearchField: NSTextField {
    var focusRequest = -1
    var onBecomeFirstResponder: (() -> Void)?
    /// Whether the field takes the keyboard when it appears or its window becomes key.
    var takesFocusAutomatically = true
    /// Keeps first responder, so Return, Esc and ⌫ still reach the delegate, but the
    /// field editor accepts no text or composition and shows no caret.
    var isReadOnly = false

    func configure(_ editor: NSTextView) {
        editor.isEditable = !isReadOnly
        // The caret is one of the few places the accent appears.
        editor.insertionPointColor = isReadOnly ? .clear : OR.NS.accentFill
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowBecameKey(_:)),
                name: NSWindow.didBecomeKeyNotification, object: window)
        }
        if takesFocusAutomatically { focusIfNeeded() }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let editor = currentEditor() as? NSTextView { configure(editor) }
        // Reported a turn later: focus can change during a view update, which mustn't mutate state.
        if became, let report = onBecomeFirstResponder { DispatchQueue.main.async { report() } }
        return became
    }

    func focusIfNeeded() {
        guard let window, window.isKeyWindow, window.attachedSheet == nil, currentEditor() == nil else { return }
        // Becoming first responder selects all, so typing would replace the query.
        guard window.makeFirstResponder(self), let editor = currentEditor() else { return }
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        if takesFocusAutomatically { focusIfNeeded() }
    }
}

/// A search field that shows bullets, for password arguments. A secure cell gives it the
/// secure field editor, which keeps the text out of the pasteboard and services.
final class FocusedSecureSearchField: FocusedSearchField {
    override class var cellClass: AnyClass? {
        get { NSSecureTextFieldCell.self }
        set {}
    }
}

/// The AI composers. Keys follow main #12/#13 (an owner decision for the AI view): ↩ sends,
/// ⌘↩ and ⇧↩ insert a new line, a held ↩ never sends twice, Tab and ⇧Tab move focus, and an
/// input method's composition always gets its keys first.
struct AIComposerInput: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
    var submit: () -> Void
    var deleteOnEmpty: () -> Bool = { false }
    var fontSize: CGFloat = 13.5
    /// Reports whether the editor holds the keyboard, so the focus ring follows real focus.
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Changes when the composer starts on another conversation, so undo can't reach into it.
    var sessionIdentity: () -> String = { "composer" }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        let editor = FocusedComposerTextView()
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: fontSize)
        editor.textColor = OR.NS.text
        editor.insertionPointColor = OR.NS.accentFill
        editor.textContainerInset = NSSize(width: 0, height: 2)
        editor.textContainer?.lineFragmentPadding = 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: OR.NS.text, .paragraphStyle: paragraph]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 20)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.setAccessibilityLabel("Message to Apple Intelligence")
        editor.setAccessibilityIdentifier("ai.composer")
        // Focus can change during a view update, so the report waits for the next turn.
        editor.onFocusChange = { [weak coordinator = context.coordinator] focused in
            DispatchQueue.main.async { coordinator?.parent.onFocusChange(focused) }
        }
        editor.prepareForInput = { [weak editor, weak coordinator = context.coordinator] in
            if let editor { coordinator?.synchronizeEditor(editor) }
        }
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? FocusedComposerTextView else { return }
        context.coordinator.synchronizeEditor(editor)
        if editor.focusRequest != focusRequest {
            editor.focusRequest = focusRequest
            editor.focusIfNeeded()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIComposerInput
        private var sessionID: String
        private weak var editor: NSTextView?
        private weak var observedUndoManager: UndoManager?

        init(parent: AIComposerInput) {
            self.parent = parent
            sessionID = parent.sessionIdentity()
        }

        /// Puts the model's draft into the editor before the next key, never during a composition.
        /// A new conversation, or a draft replaced from outside, starts a fresh undo history.
        func synchronizeEditor(_ editor: NSTextView) {
            self.editor = editor
            observeUndoManager(editor.undoManager)
            guard !editor.hasMarkedText(), (editor as? FocusedComposerTextView)?.isHandlingMarkedText != true else {
                return
            }
            let identity = parent.sessionIdentity()
            let text = parent.text
            if sessionID != identity || editor.string != text {
                // Undo ranges belong to the previous conversation or imported passage.
                editor.breakUndoCoalescing()
                editor.undoManager?.removeAllActions()
                sessionID = identity
            }
            if editor.string != text {
                editor.string = text
                let end = NSRange(location: text.utf16.count, length: 0)
                editor.setSelectedRange(end)
                editor.scrollRangeToVisible(end)
            }
        }

        private func observeUndoManager(_ manager: UndoManager?) {
            guard observedUndoManager !== manager else { return }
            let center = NotificationCenter.default
            center.removeObserver(self, name: .NSUndoManagerDidUndoChange, object: nil)
            center.removeObserver(self, name: .NSUndoManagerDidRedoChange, object: nil)
            observedUndoManager = manager
            if let manager {
                for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                    center.addObserver(self, selector: #selector(historyChanged(_:)), name: name, object: manager)
                }
            }
        }

        /// NSTextView can apply undo without calling textDidChange; publish it before a later
        /// SwiftUI update restores the old draft.
        @objc private func historyChanged(_ notification: Notification) {
            guard let editor else { return }
            parent.text = editor.string
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText(), (textView as? FocusedComposerTextView)?.isHandlingMarkedText != true else {
                return false
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                guard (NSApp.currentEvent?.modifierFlags ?? []).intersection([.command, .control, .option]).isEmpty
                else { return false }
                textView.window?.selectNextKeyView(textView)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                guard (NSApp.currentEvent?.modifierFlags ?? []).intersection([.command, .control, .option]).isEmpty
                else { return false }
                textView.window?.selectPreviousKeyView(textView)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.submit()
                // Submission may clear or replace the draft before SwiftUI renders. Publish it to
                // the live editor before another key or undo.
                synchronizeEditor(textView)
                return true
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)), textView.string.isEmpty {
                // Holding ⌫ to clear a message must not leave AI.
                if isRepeatedKeyDown { return true }
                return parent.deleteOnEmpty()
            }
            return false
        }
    }
}

/// True while a held key auto-repeats. ⌫ on an empty field removes one token
/// per fresh press only. isARepeat raises for non-key events, so check the type first.
@MainActor private var isRepeatedKeyDown: Bool {
    guard let event = NSApp?.currentEvent, event.type == .keyDown else { return false }
    return event.isARepeat
}

final class FocusedComposerTextView: NSTextView {
    var focusRequest = -1
    var onFocusChange: ((Bool) -> Void)?
    /// Brings the model's draft in before a key is handled.
    var prepareForInput: (() -> Void)?
    /// True while a key that arrived during an input method's composition is being handled.
    private(set) var isHandlingMarkedText = false

    override func keyDown(with event: NSEvent) {
        isHandlingMarkedText = hasMarkedText()
        defer { isHandlingMarkedText = false }
        prepareForInput?()
        if handleReturn(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        prepareForInput?()
        if window?.firstResponder === self, event.modifierFlags.contains(.command), handleReturn(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// ↩ sends once per press; ⌘↩ and ⇧↩ insert a new line through the normal typing path, so
    /// selection replacement and undo behave as typed. Returns whether it handled the key.
    func handleReturn(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76, !hasMarkedText(), !isHandlingMarkedText
        else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command || modifiers == .shift {
            insertText("\n", replacementRange: selectedRange())
        } else if modifiers.isEmpty {
            // A held ↩ must not send and then go on to accept the result.
            if !event.isARepeat { doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        } else {
            return false
        }
        return true
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        prepareForInput?()
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowBecameKey(_:)),
                name: NSWindow.didBecomeKeyNotification, object: window)
        }
        focusIfNeeded()
    }

    func focusIfNeeded() {
        guard let window, window.isKeyWindow, window.attachedSheet == nil, window.firstResponder !== self else {
            return
        }
        window.makeFirstResponder(self)
    }

    @objc private func windowBecameKey(_ notification: Notification) { focusIfNeeded() }
}
