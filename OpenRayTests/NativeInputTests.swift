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
