import AppKit
import SwiftUI
import Testing

@testable import OpenRay

@MainActor
struct NativeInputTests {
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
        let menu = LauncherActionsMenu.Coordinator.makeMenu(entries: [
            .heading("Calculator"),
            .action(title: "Open", symbol: "return") { actions.append("open") },
            .action(title: "Favorite", symbol: "star") { actions.append("favorite") },
            .separator,
            .action(title: "Settings", symbol: "gearshape") { actions.append("settings") },
        ])

        #expect(menu.items.map(\.title) == ["Calculator", "Open", "Favorite", "", "Settings"])
        #expect(menu.items[0].isEnabled == false)
        #expect(menu.items[3].isSeparatorItem)
        #expect(menu.items[2].isEnabled)
        menu.performActionForItem(at: 2)
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
