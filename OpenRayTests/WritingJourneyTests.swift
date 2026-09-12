import AppKit
import Testing

@testable import OpenRay

@MainActor
struct WritingJourneyTests {
    private func model() -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(), aiFactory: { AIChatModel(engine: TestAIEngine()) })
    }

    private func selection(_ text: String, source: String = "Source editor") -> SelectedTextContext {
        SelectedTextContext(text: text, application: nil, sourceName: source, validateForPaste: {})
    }

    @Test func selectedPassageRunsOnceAndReturnCopiesCompletedResult() async {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("We was ready yesterday."))
        model.openAI(.rewrite)
        #expect(model.ai.messages.first?.text == "We was ready yesterday.")
        #expect(!model.canAcceptAIResponse)
        await model.ai.waitForResponse()
        #expect(model.canAcceptAIResponse)
        #expect(model.aiAcceptTitle == "Replace in Source editor")
        model.submitAI()
        #expect(model.clipboard.readText() == "A helpful reply.")
        #expect(model.ai.messages.count == 2)
        model.openAI(.rewrite)
        #expect(model.ai.messages.count == 2)
    }

    @Test func selectedPassageTakesPriorityOverAnotherToolsDraftWithoutLosingIt() async {
        let model = model()
        defer { model.stop() }
        model.ai.draft = "Keep my unrelated question"
        model.setCapturedSelection(selection("Selected passage"))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        #expect(model.ai.sourcePassage == "Selected passage")
        model.switchAIAction(.chat)
        #expect(model.ai.draft == "Keep my unrelated question")
    }

    @Test func followUpSubmitsInsteadOfAcceptingAndOriginSurvivesOtherAppSelection() async {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("Original passage", source: "Original app"))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        model.setCapturedSelection(selection("Other selected text", source: "Another app"))
        model.ai.draft = "Make it warmer"
        #expect(!model.canAcceptAIResponse)
        model.submitAI()
        await model.ai.waitForResponse()
        #expect(model.ai.messages.count == 4)
        #expect(model.ai.messages.last(where: { $0.role == .user })?.text == "Make it warmer")
        #expect(model.aiSource?.sourceName == "Original app")
        #expect(model.hasNewSelectedText)
        #expect(model.ai.sourcePassage == "Original passage")
    }

    @Test func existingDraftIsNotReplacedWhenSelectionChanges() {
        let model = model()
        defer { model.stop() }
        model.openAI(.rewrite)
        model.ai.draft = "An unsent passage"
        model.setCapturedSelection(selection("New selection"))
        model.openAI(.rewrite)
        #expect(model.ai.draft == "An unsent passage")
        #expect(model.ai.messages.isEmpty)
        #expect(model.hasNewSelectedText)
    }

    @Test func chatNeverAutomaticallySubmitsCapturedSelection() {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("Selected passage"))
        model.openAI()
        #expect(model.ai.messages.isEmpty)
        #expect(model.ai.draft.isEmpty)
        #expect(!model.canAcceptAIResponse)
    }

    @Test func newConversationDropsPasteTargetAndClipboardImportStartsFresh() async {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("Source passage"))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        model.ai.newConversation()
        #expect(model.aiSource == nil)
        model.importAIText("An independent passage")
        model.submitAI()
        await model.ai.waitForResponse()
        #expect(model.ai.sourcePassage == "An independent passage")
        #expect(model.aiAcceptTitle == "Copy result")
        #expect(model.aiSource == nil)
    }

    @Test func failedFollowUpNeverAcceptsThePreviousResultByDefault() async {
        let engine = TestAIEngine()
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine),
            pasteboard: NSPasteboard.withUniqueName())
        defer { model.stop() }
        model.ai.open(.rewrite)
        model.ai.draft = "Original passage"
        model.ai.send()
        await model.ai.waitForResponse()
        engine.failure = .contextFull
        model.ai.draft = "Make it warmer"
        model.ai.send()
        await model.ai.waitForResponse()
        model.ai.draft = ""
        #expect(!model.canAcceptAIResponse)
        model.submitAI()
        #expect(model.clipboard.readText() == nil)
    }

    @Test func hideAndResumeKeepsDestinationQuerySelectionAndDraft() {
        let model = model()
        defer { model.stop() }
        model.navigate(to: .notes)
        model.query = "Meeting"
        model.selectedID = "note.selected"
        model.ai.draft = "Unsent question"
        let now = Date(timeIntervalSince1970: 1_000)
        model.didHide(at: now)
        model.didHide(at: now.addingTimeInterval(100))
        #expect(model.hiddenAt == now)
        model.prepareToShow(at: now.addingTimeInterval(299))
        #expect(model.section == .notes)
        #expect(model.query == "Meeting")
        #expect(model.selectedID == "note.selected")
        #expect(model.ai.draft == "Unsent question")
        #expect(model.hiddenAt == nil)
    }

    @Test func longPauseResetsNavigationButPreservesWritingSessions() async {
        let model = model()
        defer { model.stop() }
        model.openAI(.rewrite)
        model.ai.draft = "A passage"
        model.ai.send()
        await model.ai.waitForResponse()
        model.ai.draft = "An unsent revision"
        let session = model.ai
        let now = Date(timeIntervalSince1970: 1_000)
        model.didHide(at: now)
        model.prepareToShow(at: now.addingTimeInterval(300))
        #expect(model.destination == .search)
        #expect(model.section == .home)
        model.openAI(.rewrite)
        #expect(model.ai === session)
        #expect(model.ai.messages.count == 2)
        #expect(model.ai.draft == "An unsent revision")
    }

    @Test func unsavedEditorIsNeverExpired() {
        let model = model()
        defer { model.stop() }
        model.navigate(to: .notes)
        model.editor = .note(QuickNote(title: "Unsaved", content: "Keep this"))
        let identity = model.editor?.id
        let now = Date(timeIntervalSince1970: 1_000)
        model.didHide(at: now)
        model.prepareToShow(at: now.addingTimeInterval(600))
        #expect(model.section == .notes)
        #expect(model.editor?.id == identity)
    }

    @Test func settingsAndTimersReturnToThePreviousWorkspaceAndSearch() {
        let model = model()
        defer { model.stop() }
        model.navigate(to: .notes)
        model.query = "Meeting"
        model.openAI(.rewrite)
        model.ai.draft = "Keep this revision"
        model.openSettings()
        model.settingsExclusionsDraft = "com.example.unsaved"
        model.goBack()
        #expect(model.destination == .ai)
        #expect(model.ai.draft == "Keep this revision")
        model.openPomodoro()
        model.goBack()
        #expect(model.destination == .ai)
        model.goBack()
        #expect(model.section == .notes)
        #expect(model.query == "Meeting")
        model.openSettings()
        #expect(model.settingsExclusionsDraft == "com.example.unsaved")
    }

    @Test func explicitNavigationAfterExpiryWinsOverResume() {
        let model = model()
        defer { model.stop() }
        let old = Date(timeIntervalSinceNow: -600)
        model.didHide(at: old)
        model.openAI(.rewrite)
        model.prepareToShow()
        #expect(model.destination == .ai)
        model.didHide(at: old)
        model.openSettings()
        model.prepareToShow()
        #expect(model.destination == .settings)
    }

    @Test func scopeNarrowingAndBackPreserveTheSearchAndSameScopeDoesNothing() {
        let model = model()
        defer { model.stop() }
        model.query = "Meeting"
        let focus = model.focusRequest
        model.selectSearchScope(.home)
        #expect(model.query == "Meeting")
        #expect(model.focusRequest == focus)
        model.selectSearchScope(.notes)
        #expect(model.query == "Meeting")
        #expect(model.section == .notes)
        model.goBack()
        #expect(model.section == .home)
        #expect(model.query == "Meeting")
    }

    @Test func settingsDetourRemembersTheOriginalAITool() {
        let model = model()
        defer { model.stop() }
        model.openAI(.rewrite)
        let rewrite = model.ai
        model.openSettings()
        model.openAI(.chat)
        model.goBack()
        #expect(model.destination == .settings)
        model.goBack()
        #expect(model.destination == .ai)
        #expect(model.ai === rewrite)
    }

    @Test func importingSelectionIntoAskPreservesConversation() async {
        let model = model()
        defer { model.stop() }
        model.openAI()
        model.ai.draft = "Remember this"
        model.ai.send()
        await model.ai.waitForResponse()
        let identity = model.ai.conversationID
        model.setCapturedSelection(selection("New selected context"))
        model.useSelectionForAI()
        #expect(model.ai.conversationID == identity)
        #expect(model.ai.messages.count == 2)
        #expect(model.ai.draft == "New selected context")
    }

    @Test func rejectedOversizedImportKeepsTheExistingResultUsable() async {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("Original selected passage"))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        let identity = model.ai.conversationID
        model.importAIText(String(repeating: "x", count: AIChatModel.inputLimit + 1))
        #expect(model.ai.conversationID == identity)
        #expect(model.aiSource?.text == "Original selected passage")
        #expect(model.canAcceptAIResponse)
    }

    @Test func continueFromResultResetsModelContextWithoutLosingThePasteTarget() async {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("Original selected passage"))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        let identity = model.ai.conversationID
        let result = model.ai.latestCompletedResponse
        model.continueAIFromResult()
        #expect(model.ai.conversationID != identity)
        #expect(model.ai.messages.isEmpty)
        #expect(model.ai.draft == result)
        #expect(model.aiSource?.text == "Original selected passage")
        #expect(!model.canAcceptAIResponse)
    }

    @Test func anotherSelectedPassageAutomaticallyRunsAfterACompletedRewrite() async {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("First selected passage"))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        let firstID = model.ai.conversationID
        model.setCapturedSelection(selection("Second selected passage"))
        model.openAI(.rewrite)
        #expect(model.ai.isGenerating)
        await model.ai.waitForResponse()
        #expect(model.ai.conversationID != firstID)
        #expect(model.ai.sourcePassage == "Second selected passage")
        #expect(model.ai.messages.count == 2)
    }

    @Test func resumeAndToolBrowsingNeverSubmitANewPassageOverACompletedResult() async {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("First selected passage"))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        let firstID = model.ai.conversationID
        model.setCapturedSelection(selection("Second selected passage"))
        model.didHide()
        model.prepareToShow()
        #expect(model.ai.conversationID == firstID)
        model.switchAIAction(.chat)
        model.switchAIAction(.rewrite)
        #expect(model.ai.conversationID == firstID)
        #expect(model.ai.sourcePassage == "First selected passage")
        #expect(!model.ai.isGenerating)
    }

    @Test func sameSelectionAndOversizedNewSelectionDoNotRegenerateOrDiscardCompletedWork() async {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("First selected passage"))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        let firstID = model.ai.conversationID
        model.setCapturedSelection(selection("First selected passage"))
        model.openAI(.rewrite)
        #expect(model.ai.conversationID == firstID)
        #expect(!model.ai.isGenerating)
        model.setCapturedSelection(selection(String(repeating: "x", count: AIChatModel.inputLimit + 1)))
        model.openAI(.rewrite)
        #expect(model.ai.conversationID == firstID)
        #expect(model.ai.sourcePassage == "First selected passage")
        #expect(model.canAcceptAIResponse)
    }

    @Test func quickAIBackReturnsToTheImmediateOriginBeforeEarlierScopes() {
        let model = model()
        defer { model.stop() }
        model.query = "Meeting"
        model.selectSearchScope(.notes)
        model.selectSearchScope(.home)
        #expect(model.quickAI())
        model.goBack()
        #expect(model.destination == .search)
        #expect(model.section == .home)
        #expect(model.query == "Meeting")
        model.goBack()
        #expect(model.section == .notes)
    }

    @Test func restoredFileSelectionWaitsForRefreshAndNeverExecutesAFallbackResult() {
        let model = model()
        defer { model.stop() }
        model.query = "Settings"
        let selectedFileID = "file./Users/example/Settings.txt"
        model.selectedID = selectedFileID
        model.selectSearchScope(.files)
        model.goBack()
        #expect(model.files.isSearching)
        model.synchronizeSelection()
        #expect(model.selectedID == selectedFileID)
        #expect(model.selectedItem == nil)
        model.performSelected()
        #expect(model.destination == .search)
        model.store.toggleFavorite(selectedFileID)
        model.synchronizeSelection()
        #expect(model.selectedItem?.id == selectedFileID)
        model.files.stop()
    }

    @Test func newSearchCancelsPendingFileSelectionRestoration() {
        let model = model()
        defer { model.stop() }
        model.query = "Settings"
        model.selectedID = "file./Users/example/Settings.txt"
        model.selectSearchScope(.files)
        model.goBack()
        #expect(model.selectedItem == nil)
        model.query = "Notes"
        model.synchronizeSelection()
        #expect(model.selectedItem?.id == "section.notes")
    }
}
