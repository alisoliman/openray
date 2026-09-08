import AppKit
import Testing

@testable import OpenRay

@MainActor
struct WorkspaceShortcutTests {
    @Test func onePanelRoutesCommandSixThenAIToolsWithoutReinstallingHandlers() throws {
        let model = model()
        defer { model.stop() }
        let panel = LauncherPanel()
        panel.workspaceShortcutAction = model.selectWorkspaceShortcut

        #expect(panel.performKeyEquivalent(with: try keyEvent("6")))
        #expect(model.destination == .ai)
        #expect(model.ai.action == .chat)
        #expect(panel.performKeyEquivalent(with: try keyEvent("2")))
        #expect(model.ai.action == .rewrite)
        #expect(panel.performKeyEquivalent(with: try keyEvent("3")))
        #expect(model.ai.action == .summarize)
        #expect(panel.performKeyEquivalent(with: try keyEvent("1")))
        #expect(model.ai.action == .chat)

        model.goBack()
        #expect(panel.performKeyEquivalent(with: try keyEvent("2")))
        #expect(model.destination == .search)
        #expect(model.section == .applications)
    }

    @Test func workspaceNumbersSelectTheDocumentedSearchSectionsAndAITools() {
        let model = model()
        defer { model.stop() }
        let sections: [LauncherSection] = [.home, .applications, .files, .clipboard, .notes]
        for (index, section) in sections.enumerated() {
            #expect(model.selectWorkspaceShortcut(index))
            #expect(model.destination == .search)
            #expect(model.section == section)
        }
        #expect(model.selectWorkspaceShortcut(5))
        #expect(model.destination == .ai)
        let actions: [AIAction] = [.chat, .rewrite, .summarize, .proofread, .shorten, .actionItems]
        for (index, action) in actions.enumerated() {
            #expect(model.selectWorkspaceShortcut(index))
            #expect(model.destination == .ai)
            #expect(model.ai.action == action)
        }
    }

    @Test(arguments: [false, true]) func workspaceNumbersLeaveOverlaysAndInvalidIndicesAlone(inAI: Bool) {
        let model = model()
        defer { model.stop() }
        if inAI { model.openAI() }
        model.query = "Preserve this search"
        model.ai.draft = "Preserve this draft"
        let destination = model.destination
        let focus = model.focusRequest

        #expect(!model.selectWorkspaceShortcut(-1))
        #expect(!model.selectWorkspaceShortcut(6))
        model.showActions = true
        #expect(!model.selectWorkspaceShortcut(1))
        #expect(model.showActions)
        model.showActions = false
        model.editor = .note(QuickNote(title: "Unsaved", content: "Keep this note"))
        #expect(!model.selectWorkspaceShortcut(1))
        #expect(model.editor != nil)
        model.editor = nil
        model.beginCommandBindingEditing()
        #expect(!model.selectWorkspaceShortcut(1))
        model.endCommandBindingEditing()
        model.beginShortcutRecording()
        #expect(!model.selectWorkspaceShortcut(1))
        model.endShortcutRecording()

        #expect(model.destination == destination)
        #expect(model.section == .home)
        #expect(model.ai.action == .chat)
        #expect(model.query == "Preserve this search")
        #expect(model.ai.draft == "Preserve this draft")
        #expect(model.focusRequest == focus)

        model.openSettings()
        #expect(!model.selectWorkspaceShortcut(1))
        #expect(model.destination == .settings)
    }

    @Test func nativeWorkspaceRoutingOnlyClaimsCommandOneThroughSixOnKeyDown() throws {
        let panel = LauncherPanel()
        var handled: [Int] = []
        panel.workspaceShortcutAction = {
            handled.append($0)
            return true
        }
        let otherModifiers: [NSEvent.ModifierFlags] = [
            [], .shift, .control, .option, [.command, .shift], [.command, .control], [.command, .option],
        ]
        for modifiers in otherModifiers {
            #expect(!panel.handleWorkspaceShortcut(try keyEvent("2", modifiers: modifiers)))
        }
        for characters in ["0", "7", "a", ""] {
            #expect(!panel.handleWorkspaceShortcut(try keyEvent(characters)))
        }
        #expect(!panel.handleWorkspaceShortcut(try keyEvent("2", type: .keyUp)))
        #expect(handled.isEmpty)
        #expect(panel.handleWorkspaceShortcut(try keyEvent("2")))
        #expect(handled == [1])
        panel.workspaceShortcutAction = { _ in false }
        #expect(!panel.handleWorkspaceShortcut(try keyEvent("2")))
    }

    @Test func nativeWorkspaceRoutingLeavesMarkedTextAndSheetsAlone() throws {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless,
            backing: .buffered, defer: false)
        var invocations = 0
        panel.workspaceShortcutAction = { _ in
            invocations += 1
            return true
        }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        panel.contentView = editor
        #expect(panel.makeFirstResponder(editor))
        editor.setMarkedText(
            "に", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        #expect(!panel.handleWorkspaceShortcut(try keyEvent("2")))
        #expect(editor.hasMarkedText())
        #expect(editor.string == "に")

        editor.unmarkText()
        let sheet = NSPanel()
        // AppKit queues a sheet until its parent is ordered onscreen. Keep
        // both transparent while exercising the actual attachment lifecycle.
        panel.alphaValue = 0
        sheet.alphaValue = 0
        panel.orderFront(nil)
        panel.beginSheet(sheet)
        defer {
            panel.endSheet(sheet)
            sheet.orderOut(nil)
            panel.orderOut(nil)
        }
        #expect(panel.attachedSheet === sheet)
        #expect(!panel.handleWorkspaceShortcut(try keyEvent("2")))
        #expect(invocations == 0)
    }

    private func model() -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(), aiFactory: { AIChatModel(engine: TestAIEngine()) })
    }

    private func keyEvent(
        _ characters: String, modifiers: NSEvent.ModifierFlags = .command, type: NSEvent.EventType = .keyDown
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 0))
    }
}
