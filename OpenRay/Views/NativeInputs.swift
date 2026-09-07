import AppKit
import SwiftUI

enum LauncherMenuEntry {
    case heading(String)
    case separator
    case action(title: String, symbol: String, perform: @MainActor () -> Void)
}

/// Native menu tracking owns keyboard navigation and accessibility while the
/// launcher search field remains the panel's normal first responder.
struct LauncherActionsMenu: NSViewRepresentable {
    @Binding var isPresented: Bool
    var entries: [LauncherMenuEntry]

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if isPresented {
            coordinator.present(in: view)
        } else {
            coordinator.menu?.cancelTracking()
        }
    }

    @MainActor
    final class Coordinator {
        var parent: LauncherActionsMenu
        var menu: NSMenu?
        private var presentationScheduled = false

        init(parent: LauncherActionsMenu) { self.parent = parent }

        func present(in view: NSView) {
            guard menu == nil, !presentationScheduled else { return }
            presentationScheduled = true
            // Wait for SwiftUI to finish updating the anchor and its binding.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                self.presentationScheduled = false
                guard self.parent.isPresented else { return }
                guard let view, view.window?.isVisible == true else {
                    self.parent.isPresented = false
                    return
                }
                let menu = Self.makeMenu(entries: self.parent.entries)
                self.menu = menu
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
                self.menu = nil
                self.parent.isPresented = false
            }
        }

        static func makeMenu(entries: [LauncherMenuEntry]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for entry in entries {
                switch entry {
                case .heading(let title):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                case .separator:
                    menu.addItem(.separator())
                case .action(let title, let symbol, let perform):
                    let target = MenuActionTarget(perform: perform)
                    let item = NSMenuItem(
                        title: title, action: #selector(MenuActionTarget.invoke(_:)), keyEquivalent: "")
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                    item.target = target
                    item.representedObject = target
                    menu.addItem(item)
                }
            }
            return menu
        }
    }

    @MainActor
    private final class MenuActionTarget: NSObject {
        let perform: @MainActor () -> Void
        init(perform: @escaping @MainActor () -> Void) { self.perform = perform }
        @objc func invoke(_ sender: Any?) { perform() }
    }
}

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
            return true
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
