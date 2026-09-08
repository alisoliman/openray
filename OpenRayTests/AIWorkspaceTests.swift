import AppKit
import Testing

@testable import OpenRay

@MainActor
struct AIWorkspaceTests {
    private func model(engine: TestAIEngine = TestAIEngine()) -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine),
            pasteboard: NSPasteboard.withUniqueName(),
            aiFactory: { AIChatModel(engine: TestAIEngine()) })
    }

    @Test func tabHandsSearchToAnEditablePromptWithoutGeneratingOrReadingClipboard() {
        let engine = TestAIEngine()
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("Private clipboard text", forType: .string)
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine), pasteboard: pasteboard,
            aiFactory: { AIChatModel(engine: TestAIEngine()) })
        defer { model.stop() }
        let query = "  Help me describe this idea clearly.  "
        model.query = query
        let focus = model.focusRequest

        #expect(model.quickAI())

        #expect(model.destination == .ai)
        #expect(model.ai.action == .chat)
        #expect(model.ai.draft == query)
        #expect(model.ai.messages.isEmpty)
        #expect(!model.ai.isGenerating)
        #expect(engine.prompts.isEmpty)
        #expect(pasteboard.string(forType: .string) == "Private clipboard text")
        #expect(model.focusRequest == focus + 1)
    }

    @Test(arguments: ["AI", "Ask AI", "Rewrite", "Fix Spelling & Grammar", " Settings ", "chat"])
    func commandSearchesAreNotImportedAsPassages(query: String) {
        let model = model()
        defer { model.stop() }
        model.query = query
        #expect(model.quickAI())
        #expect(model.ai.draft.isEmpty)
        #expect(model.ai.messages.isEmpty)
    }

    @Test func commandAliasesAreNotImportedAsPassages() {
        let model = model()
        defer { model.stop() }
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: "ai.chat", alias: "assistant")))
        model.query = " Assistant "
        #expect(model.quickAI())
        #expect(model.ai.draft.isEmpty)
    }

    @Test func quickEntryOnlyHandlesTabAtRootWithoutAnOverlay() {
        let model = model()
        defer { model.stop() }
        model.query = "An unsent question"
        model.showActions = true
        #expect(!model.quickAI())
        #expect(model.showActions)
        model.showActions = false
        model.editor = .note(QuickNote(title: "Unsaved note", content: "Keep me"))
        #expect(!model.quickAI())
        model.editor = nil
        model.beginCommandBindingEditing()
        #expect(!model.quickAI())
        model.endCommandBindingEditing()
        model.beginShortcutRecording()
        #expect(!model.quickAI())
        model.endShortcutRecording()
        #expect(model.query == "An unsent question")
        #expect(model.ai.draft.isEmpty)
        model.navigate(to: .snippets)
        #expect(!model.quickAI())
        model.openAI()
        #expect(!model.quickAI())
        model.openSettings()
        #expect(!model.quickAI())
    }

    @Test func tabsCycleBothWaysAndWrapInWorkspaceOrder() {
        let model = model()
        defer { model.stop() }
        #expect(!model.cycleAIAction(1))
        model.openAI()
        let focus = model.focusRequest
        #expect(model.cycleAIAction(-1))
        #expect(model.ai.action == .actionItems)
        #expect(model.cycleAIAction(1))
        #expect(model.ai.action == .chat)
        #expect(model.cycleAIAction(1))
        #expect(model.ai.action == .rewrite)
        #expect(model.cycleAIAction(1))
        #expect(model.ai.action == .summarize)
        #expect(model.focusRequest == focus + 4)
    }

    @Test func tabsDoNotSwitchBehindActionsOrAnEditor() {
        let model = model()
        defer { model.stop() }
        model.openAI()
        let focus = model.focusRequest
        model.showActions = true
        #expect(!model.cycleAIAction(1))
        model.switchAIAction(.rewrite)
        #expect(model.ai.action == .chat)
        model.showActions = false
        model.editor = .note(QuickNote(title: "Unsaved note", content: "Keep me"))
        #expect(!model.cycleAIAction(1))
        model.switchAIAction(.rewrite)
        #expect(model.ai.action == .chat)
        #expect(model.focusRequest == focus)
    }

    @Test func freshModesCarryTheDraftAndPreviouslyVisitedModesRestoreTheirOwnDraft() {
        let model = model()
        defer { model.stop() }
        model.openAI()
        model.ai.draft = "  Original passage\n\n"
        let chat = model.ai
        model.switchAIAction(.rewrite)
        #expect(model.ai.draft == chat.draft)
        model.ai.draft = "Rewrite draft"
        let rewrite = model.ai
        model.switchAIAction(.summarize)
        #expect(model.ai.draft == "Rewrite draft")
        model.ai.draft = "Summary draft"
        model.switchAIAction(.chat)
        #expect(model.ai === chat)
        #expect(model.ai.draft == "  Original passage\n\n")
        model.switchAIAction(.rewrite)
        #expect(model.ai === rewrite)
        #expect(model.ai.draft == "Rewrite draft")
        model.ai.draft = ""
        model.switchAIAction(.summarize)
        #expect(model.ai.draft == "Summary draft")
        model.switchAIAction(.rewrite)
        #expect(model.ai.draft.isEmpty)
    }

    @Test func switchingPreservesConversationAndTheChatEngineSession() async {
        let engine = TestAIEngine()
        let model = model(engine: engine)
        defer { model.stop() }
        model.openAI()
        model.ai.draft = "Remember the first question"
        model.ai.send()
        await model.ai.waitForResponse()
        let chat = model.ai
        let history = chat.messages
        model.switchAIAction(.rewrite)
        #expect(model.ai.messages.isEmpty)
        model.ai.draft = "A passage to rewrite"
        model.ai.send()
        await model.ai.waitForResponse()
        let rewrite = model.ai
        let rewritten = rewrite.messages
        model.switchAIAction(.chat)
        #expect(model.ai === chat)
        #expect(model.ai.messages == history)
        #expect(engine.resetCount == 0)
        model.ai.draft = "A follow-up question"
        model.ai.send()
        await model.ai.waitForResponse()
        #expect(engine.prompts == ["Remember the first question", "A follow-up question"])
        #expect(engine.resetCount == 0)
        #expect(model.ai.messages.count == 4)
        model.openAI(.rewrite)
        #expect(model.ai === rewrite)
        #expect(model.ai.messages == rewritten)
    }

    @Test func generatingBlocksSwitchesAndExplainsWhyWithoutDiscardingTheSession() async {
        let engine = TestAIEngine()
        engine.delay = .seconds(10)
        let model = model(engine: engine)
        defer { model.stop() }
        model.openAI()
        let chat = model.ai
        model.ai.draft = "Generate something"
        model.ai.send()
        let focus = model.focusRequest
        #expect(model.cycleAIAction(1))
        #expect(model.ai === chat)
        #expect(model.ai.action == .chat)
        #expect(model.message?.contains("Stop the current response") == true)
        model.switchAIAction(.shorten)
        #expect(model.ai === chat)
        #expect(model.focusRequest == focus)
        model.openAI(.proofread)
        #expect(model.ai === chat)
        #expect(model.message?.contains("Stop the current response") == true)
        model.ai.cancel()
        await model.ai.waitForResponse()
        #expect(model.cycleAIAction(1))
        #expect(model.ai.action == .rewrite)
        #expect(model.message == nil)
    }

    @Test func escapeRestoresTheSearchAndSelectionAfterModeChanges() {
        let model = model()
        defer { model.stop() }
        model.query = "AI"
        model.selectedID = "ai.rewrite"
        #expect(model.quickAI())
        model.switchAIAction(.rewrite)
        model.ai.draft = "Keep this draft"
        model.showActions = true
        model.goBack()
        #expect(model.destination == .ai)
        #expect(!model.showActions)
        let focus = model.focusRequest
        model.goBack()
        #expect(model.destination == .search)
        #expect(model.section == .home)
        #expect(model.query == "AI")
        #expect(model.selectedID == "ai.rewrite")
        #expect(model.focusRequest == focus + 1)
        #expect(model.ai.draft == "Keep this draft")
        model.goBack()
        #expect(model.query.isEmpty)
    }

    @Test func quickEntryPreservesAnExistingDraftAndKeepsTheNewQueryOnReturn() {
        let model = model()
        defer { model.stop() }
        model.ai.draft = "An earlier unsent draft"
        model.query = "A new question from search"
        #expect(model.quickAI())
        #expect(model.ai.draft == "An earlier unsent draft")
        #expect(model.message?.contains("previous draft") == true)
        model.goBack()
        #expect(model.query == "A new question from search")
    }

    @Test func directNavigationClearsTheQuickEntryReturnContext() {
        let model = model()
        defer { model.stop() }
        model.query = "Keep this query only for this visit"
        #expect(model.quickAI())
        model.openAI(.rewrite)
        model.goBack()
        #expect(model.destination == .search)
        #expect(model.query.isEmpty)
        model.query = "Another question"
        #expect(model.quickAI())
        model.navigate(to: .notes)
        model.openAI()
        model.goBack()
        #expect(model.query.isEmpty)
    }
}
