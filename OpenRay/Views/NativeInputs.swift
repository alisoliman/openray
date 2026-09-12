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
    var enterAI: () -> Bool = { false }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> FocusedSearchField {
        let field = FocusedSearchField()
        context.coordinator.attach(to: field)
        field.font = .systemFont(ofSize: 20)
        field.textColor = .labelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Search OpenRay")
        field.setAccessibilityIdentifier("launcher.search")
        return field
    }

    func updateNSView(_ field: FocusedSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text { field.stringValue = text }
        if field.focusRequest != focusRequest {
            field.focusRequest = focusRequest
            field.focusIfNeeded()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusedSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: 28)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LauncherSearchInput
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
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                guard
                    (NSApp.currentEvent?.modifierFlags ?? []).intersection([.command, .control, .option, .shift])
                        .isEmpty
                else { return false }
                guard parent.enterAI() else { return false }
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
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
            if field.stringValue != query { field.stringValue = query }
            if let editor, editor.string != query {
                editor.string = query
                editor.setSelectedRange(NSRange(location: query.utf16.count, length: 0))
            }
        }
    }
}

final class FocusedSearchField: NSTextField {
    var focusRequest = -1

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
        guard let window, window.isKeyWindow, window.attachedSheet == nil, currentEditor() == nil else { return }
        window.makeFirstResponder(self)
    }

    @objc private func windowBecameKey(_ notification: Notification) { focusIfNeeded() }
}

struct AIComposerInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var focusRequest: Int
    var submit: () -> Void
    var cancel: () -> Void = {}
    var sessionIdentity: () -> String = { "composer" }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let editor = FocusedComposerTextView()
        editor.delegate = context.coordinator
        editor.prepareForInput = { [weak editor, weak coordinator = context.coordinator] in
            if let editor { coordinator?.synchronizeEditor(editor) }
        }
        editor.isRichText = false
        editor.placeholder = placeholder
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 7, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 64)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.frame = NSRect(x: 0, y: 0, width: 100, height: 64)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.setAccessibilityLabel("Message to Apple Intelligence")
        editor.setAccessibilityIdentifier("ai.composer")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? FocusedComposerTextView else { return }
        editor.placeholder = placeholder
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

        func synchronizeEditor(_ editor: NSTextView) {
            self.editor = editor
            observeUndoManager(editor.undoManager)
            guard !editor.hasMarkedText(), (editor as? FocusedComposerTextView)?.isHandlingMarkedText != true else {
                return
            }
            let identity = parent.sessionIdentity()
            let text = parent.text
            if sessionID != identity || editor.string != text {
                // Undo ranges belong to the previous tool or imported passage.
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

        @objc private func historyChanged(_ notification: Notification) {
            // NSTextView can apply native undo without calling textDidChange.
            // Publish it before a later SwiftUI update restores the old draft.
            guard let editor else { return }
            parent.text = editor.string
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            guard (textView as? FocusedComposerTextView)?.isHandlingMarkedText != true else { return false }
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
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.cancel()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.submit()
                // Submission may clear or replace the bound draft before SwiftUI
                // renders. Publish it to the live editor before another key or undo.
                synchronizeEditor(textView)
                return true
            }
            return false
        }
    }
}

final class FocusedComposerTextView: NSTextView {
    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }
    var focusRequest = -1
    var prepareForInput: (() -> Void)?
    private(set) var isHandlingMarkedText = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = textContainerOrigin
        let bounds = NSRect(
            x: origin.x + padding, y: origin.y,
            width: max(0, (textContainer?.containerSize.width ?? frame.width) - padding * 2),
            height: max(0, frame.height - origin.y))
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        if let defaultParagraphStyle { attributes[.paragraphStyle] = defaultParagraphStyle }
        (placeholder as NSString).draw(in: bounds, withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        isHandlingMarkedText = hasMarkedText()
        defer { isHandlingMarkedText = false }
        prepareForInput?()
        if handleReturn(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        prepareForInput?()
        if event.modifierFlags.contains(.command), handleReturn(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleReturn(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
            !hasMarkedText(), !isHandlingMarkedText
        else { return false }
        if event.modifierFlags.contains(.command) {
            // Use NSTextView's insertion path so selection replacement and undo
            // behave exactly like typing; a key equivalent must not send the draft.
            insertText("\n", replacementRange: selectedRange())
        } else if !event.isARepeat {
            doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        return true
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        prepareForInput?()
        super.insertText(insertString, replacementRange: replacementRange)
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
        prepareForInput?()
    }

    func focusIfNeeded() {
        guard let window, window.isKeyWindow, window.attachedSheet == nil, window.firstResponder !== self else {
            return
        }
        window.makeFirstResponder(self)
    }

    @objc private func windowBecameKey(_ notification: Notification) { focusIfNeeded() }
}

/// The launcher is operated from the keyboard even when macOS's optional
/// system-wide button navigation is off. An explicit editing focus target keeps
/// its controls in SwiftUI's focus loop in both settings.
struct AIKeyboardButton<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let action: () -> Void
    @ViewBuilder let label: () -> Content

    var body: some View {
        Button(action: action, label: label)
            .focusable(isEnabled, interactions: .edit)
            .onKeyPress(keys: [.return, .space], phases: .down) { event in
                guard isEnabled, event.modifiers.intersection([.command, .option, .control]).isEmpty else {
                    return .ignored
                }
                action()
                return .handled
            }
    }
}

extension AIKeyboardButton where Content == Text {
    init(_ title: String, action: @escaping () -> Void) {
        self.action = action
        label = { Text(title) }
    }
}

extension AIKeyboardButton where Content == Label<Text, Image> {
    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.action = action
        label = { Label(title, systemImage: systemImage) }
    }
}
