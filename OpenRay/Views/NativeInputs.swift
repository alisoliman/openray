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
            switch commandSelector {
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
    var focusRequest: Int
    var submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let editor = FocusedComposerTextView()
        editor.delegate = context.coordinator
        editor.isRichText = false
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
        if editor.string != text {
            editor.string = text
            let end = NSRange(location: text.utf16.count, length: 0)
            editor.setSelectedRange(end)
            editor.scrollRangeToVisible(end)
        }
        if editor.focusRequest != focusRequest {
            editor.focusRequest = focusRequest
            editor.focusIfNeeded()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIComposerInput
        init(parent: AIComposerInput) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)),
                NSApp.currentEvent?.modifierFlags.contains(.command) == true
            {
                parent.submit()
                return true
            }
            return false
        }
    }
}

final class FocusedComposerTextView: NSTextView {
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
        guard let window, window.isKeyWindow, window.attachedSheet == nil, window.firstResponder !== self else {
            return
        }
        window.makeFirstResponder(self)
    }

    @objc private func windowBecameKey(_ notification: Notification) { focusIfNeeded() }
}
