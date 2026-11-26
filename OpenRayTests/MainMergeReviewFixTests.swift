import AppKit
import SwiftUI
import Testing

@testable import OpenRay

/// Regression tests for the review of the main merge (`_orch/reviews/main-merge.md`). Finding 1
/// (archives and Pomodoro) is in `LibrarySchemaMainMergeTests`.
@MainActor
struct MainMergeReviewFixTests {
    private func model(engine: TestAIEngine = TestAIEngine()) -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine), pasteboard: NSPasteboard.withUniqueName())
    }

    private func selection(_ text: String, source: String = "Source editor", ranged: Bool = true) -> SelectedTextContext {
        var context = SelectedTextContext(text: text, application: nil, sourceName: source, validateForPaste: {})
        if ranged { context.range = NSRange(location: 0, length: (text as NSString).length) }
        return context
    }

    // MARK: 2. Replace needs the selection's place, then and now

    @Test func replaceNeedsARangeAtCaptureAndTheSameRangeBeforePasting() throws {
        func verify(captured: NSRange?, current: NSRange?, sameElement: Bool = true, text: String? = "Hello") throws {
            try SelectedTextContext.verifyUnchanged(
                capturedText: "Hello", capturedRange: captured, appIsRunning: true, sameElement: sameElement,
                currentText: text, currentRange: current, sourceName: "Notes")
        }
        let range = NSRange(location: 4, length: 5)
        try verify(captured: range, current: range)
        #expect(throws: LibraryValidationError.self) { try verify(captured: nil, current: range) }
        #expect(throws: LibraryValidationError.self) { try verify(captured: nil, current: nil) }
        // The same text selected elsewhere in the same field is a different selection.
        #expect(throws: LibraryValidationError.self) { try verify(captured: range, current: NSRange(location: 20, length: 5)) }
        #expect(throws: LibraryValidationError.self) { try verify(captured: range, current: nil) }
        #expect(throws: LibraryValidationError.self) { try verify(captured: range, current: range, sameElement: false) }
        #expect(throws: LibraryValidationError.self) { try verify(captured: range, current: range, text: "Hullo") }
    }

    @Test func aSelectionWithoutARangeIsReadAndCopiedButNeverReplaced() async {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("Unranged passage", ranged: false))
        model.openAI(.rewrite)
        #expect(model.ai.attachments.first?.text == "Unranged passage")
        #expect(model.aiReplaceTarget == nil)
        model.submitAI()
        await model.ai.waitForResponse()
        #expect(model.aiAcceptTitle == "Copy Result")
        model.submitAI()
        #expect(model.clipboard.readText() == "A helpful reply.")
    }

    @Test func aFailedValidationSendsNoKey() async throws {
        let posted = PostedKeys()
        var environment = SyntheticInput.PasteEnvironment()
        environment.checkAllowed = {}
        environment.isTrusted = { true }
        environment.activate = { _ in }
        let me = NSRunningApplication.current
        environment.frontmostProcess = { me.processIdentifier }
        environment.changeCount = { 7 }
        environment.secureInput = { false }
        environment.pause = {}
        environment.postPaste = { posted.pids.append($0) }

        await #expect(throws: LibraryValidationError.self) {
            try await SyntheticInput.paste(
                into: me, expectedChangeCount: 7, validateTarget: { throw LibraryValidationError("changed") },
                environment: environment)
        }
        #expect(posted.pids.isEmpty)
        // A clipboard that changed meanwhile stops it before validation, too.
        await #expect(throws: LibraryValidationError.self) {
            try await SyntheticInput.paste(into: me, expectedChangeCount: 8, environment: environment)
        }
        #expect(posted.pids.isEmpty)
        try await SyntheticInput.paste(into: me, expectedChangeCount: 7, environment: environment)
        #expect(posted.pids == [me.processIdentifier])
    }

    @Test func onlyANonEmptyRangeAsLongAsTheTextCanBeReplaced() {
        #expect(SelectedTextContext.isUsable(NSRange(location: 3, length: 5), for: "Hello"))
        #expect(!SelectedTextContext.isUsable(NSRange(location: 3, length: 0), for: "Hello"))
        #expect(!SelectedTextContext.isUsable(NSRange(location: 3, length: 4), for: "Hello"))
        #expect(!SelectedTextContext.isUsable(NSRange(location: NSNotFound, length: 5), for: "Hello"))
        #expect(!SelectedTextContext.isUsable(nil, for: "Hello"))
        // UTF-16, as Accessibility counts: an emoji is two units.
        #expect(SelectedTextContext.isUsable(NSRange(location: 0, length: 3), for: "a🍎"))
        var caret = selection("Hello", source: "Notes")
        caret.range = NSRange(location: 7, length: 0)
        #expect(!caret.canReplace)
        #expect(throws: LibraryValidationError.self) {
            try SelectedTextContext.verifyUnchanged(
                capturedText: "Hello", capturedRange: NSRange(location: 7, length: 0), appIsRunning: true,
                sameElement: true, currentText: "Hello", currentRange: NSRange(location: 7, length: 0), sourceName: "Notes")
        }
    }

    @Test func theLastCheckRereadsFocusRangeTextAndTheFrontmostApp() throws {
        let range = NSRange(location: 4, length: 5)
        let reads = ProbeScript()
        let probe = SelectedTextContext.Probe(
            frontmostProcess: { reads.frontmost },
            focusIsOriginal: { reads.nextFocus() },
            text: { reads.text },
            range: { reads.range })
        func validate() throws {
            try SelectedTextContext.validate(
                capturedText: "Hello", capturedRange: range, process: 42, appIsRunning: true, sourceName: "Notes",
                probe: probe)
        }
        reads.reset(range: range)
        try validate()
        // Focus moved while the text and range were being read.
        reads.reset(range: range, focus: [true, false])
        #expect(throws: LibraryValidationError.self) { try validate() }
        // Another app came to the front.
        reads.reset(range: range, frontmost: 7)
        #expect(throws: LibraryValidationError.self) { try validate() }
        // Any value that can't be read refuses.
        reads.reset(range: range, focus: [nil, true])
        #expect(throws: LibraryValidationError.self) { try validate() }
        reads.reset(range: range, text: nil)
        #expect(throws: LibraryValidationError.self) { try validate() }
        reads.reset(range: nil)
        #expect(throws: LibraryValidationError.self) { try validate() }
        // The same text at another place in the field.
        reads.reset(range: NSRange(location: 20, length: 5))
        #expect(throws: LibraryValidationError.self) { try validate() }
    }

    // MARK: 3. The target belongs to the source that was chosen

    @Test func aClipboardPassageWithTheSameTextNeverInheritsTheSelectionsTarget() async {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("Same text"))
        model.openAI(.rewrite)
        #expect(model.aiReplaceTarget != nil)
        _ = model.clipboard.copy("Same text")
        model.attachClipboardToAI()
        #expect(model.ai.attachments.first?.source == .clipboard)
        #expect(model.aiReplaceTarget == nil)
        model.submitAI()
        await model.ai.waitForResponse()
        #expect(model.aiAcceptTitle == "Copy Result")
        #expect(!model.aiReplacesSource)
    }

    @Test func aTypedPassageWithTheSameTextNeverInheritsTheSelectionsTarget() async throws {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("Same text"))
        model.openAI(.rewrite)
        let attachment = try #require(model.ai.attachments.first)
        model.ai.removeAttachment(attachment.id)
        model.ai.draft = "Same text"
        #expect(model.aiReplaceTarget == nil)
        model.submitAI()
        await model.ai.waitForResponse()
        #expect(model.ai.lastSource == "Same text")
        #expect(model.aiReplaceTarget == nil)
        #expect(model.aiAcceptTitle == "Copy Result")
    }

    // MARK: 4. Writing work survives reopening and detours

    @Test func reopeningAfterBackToEverythingKeepsTheResultAndTheUnsentFollowUp() async throws {
        let model = model()
        defer { model.stop() }
        #expect(model.store.update { $0.preferences.popToRoot = .immediately })
        model.setCapturedSelection(selection("First passage"))
        model.openAI(.rewrite)
        model.submitAI()
        await model.ai.waitForResponse()
        model.ai.instruction = "Make it warmer"
        model.panelDidHide()
        model.panelWillShow()
        #expect(model.destination == .search)

        model.setCapturedSelection(selection("Second passage"))
        model.openAI(.rewrite)
        #expect(model.ai.messages.count == 2)
        #expect(model.ai.instruction == "Make it warmer")
        #expect(model.ai.attachments.first?.text == "First passage")
        #expect(model.pendingNewSelection?.text == "Second passage")
        #expect(model.actions(for: nil).contains { $0.id == "useNewSelection" })

        model.usePendingSelection()
        #expect(model.ai.messages.isEmpty)
        #expect(model.ai.attachments.first?.text == "Second passage")
        #expect(model.aiReplaceTarget?.text == "Second passage")
    }

    @Test func anOversizedNewSelectionIsRefusedBeforeItReplacesAnything() async {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("A passage"))
        model.openAI(.rewrite)
        model.submitAI()
        await model.ai.waitForResponse()
        model.setCapturedSelection(selection(String(repeating: "a", count: AIChatModel.inputLimit + 1)))
        model.openAI(.rewrite)
        model.usePendingSelection()
        #expect(model.ai.errorMessage?.contains("longer than") == true)
        #expect(model.ai.messages.count == 2)
        #expect(model.ai.attachments.first?.text == "A passage")
    }

    @Test func switchingCommandsOrToChatPutsWorkAwayAndBringsItBack() {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("Passage A"))
        model.openAI(.rewrite)
        model.ai.instruction = "Make it formal"

        model.setCapturedSelection(selection("Passage B"))
        model.openAI(.summarize)
        #expect(model.ai.action == .summarize)
        #expect(model.ai.attachments.first?.text == "Passage B")
        model.openAI()
        #expect(model.ai.action == .chat)

        model.openAI(.rewrite)
        #expect(model.ai.action == .rewrite)
        #expect(model.ai.attachments.first?.text == "Passage A")
        #expect(model.ai.instruction == "Make it formal")
        #expect(model.aiReplaceTarget?.text == "Passage A")
        model.openAI(.summarize)
        #expect(model.ai.attachments.first?.text == "Passage B")
    }

    @Test func aTimerOpenedFromAIGoesBackToTheWorkItLeft() throws {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("A passage"))
        model.openAI(.rewrite)
        model.ai.instruction = "Keep it short"
        let pomodoro = try #require(model.bindableCommands.first { $0.id == PomodoroCommandProvider.openID })
        model.perform(pomodoro)
        #expect(model.section.providedScope?.id == PomodoroCommandProvider.scope.id)
        model.goBack()
        #expect(model.destination == .ai)
        #expect(model.ai.instruction == "Keep it short")
        #expect(model.ai.attachments.first?.text == "A passage")
        // Esc from AI then returns to search as before.
        model.goBack()
        #expect(model.destination == .search)
        #expect(model.section == .home)
    }

    @Test func anInsertedResultIsNotWorkSoANewSelectionStartsFresh() async throws {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("First passage"))
        model.openAI(.rewrite)
        model.submitAI()
        await model.ai.waitForResponse()
        let text = try #require(model.ai.messages.last?.text)
        model.insertedAIResult = (model.ai.conversationToken, text)
        model.setCapturedSelection(selection("Second passage"))
        model.openAI(.rewrite)
        #expect(model.ai.messages.isEmpty)
        #expect(model.ai.attachments.first?.text == "Second passage")
        #expect(model.pendingNewSelection == nil)
    }

    @Test func aHotkeyRunNeverResendsResumedWork() async {
        let engine = TestAIEngine()
        let model = model(engine: engine)
        defer { model.stop() }
        model.setCapturedSelection(selection("A passage"))
        model.openAI(.rewrite)
        model.submitAI()
        await model.ai.waitForResponse()
        let provider = AICommandProvider()
        provider.run(commandID: "ai.rewrite", arguments: [:], in: model, startsWritingCommands: true)
        await model.ai.waitForResponse()
        #expect(engine.prompts.count == 1)
        #expect(model.ai.messages.count == 2)
    }

    @Test func quickFixNeverRunsAResumedPassageFromAnotherApp() {
        let engine = TestAIEngine()
        let model = model(engine: engine)
        defer { model.stop() }
        // An unsent passage selected in app A.
        model.setCapturedSelection(selection("Same text", source: "App A"))
        model.openAI(.rewrite)
        // Quick Fix from app B, where the same words are selected.
        var other = selection("Same text", source: "App B")
        other.range = NSRange(location: 10, length: 9)
        model.setCapturedSelection(other)
        AICommandProvider().run(commandID: "ai.rewrite", arguments: [:], in: model, startsWritingCommands: true)
        #expect(engine.prompts.isEmpty)
        #expect(!model.ai.isGenerating)
        #expect(model.aiReplaceTarget?.sourceName == "App A")
        // Same text, but another app and place: offered, never applied on its own.
        #expect(model.pendingNewSelection?.sourceName == "App B")
    }

    @Test func quickFixRunsASelectionItJustCaptured() async {
        let engine = TestAIEngine()
        let model = model(engine: engine)
        defer { model.stop() }
        model.setCapturedSelection(selection("Fresh passage"))
        AICommandProvider().run(commandID: "ai.rewrite", arguments: [:], in: model, startsWritingCommands: true)
        await model.ai.waitForResponse()
        #expect(engine.prompts == ["Fresh passage"])
        // The very same selection again (app, element, range, text) isn't offered as new.
        model.openAI(.rewrite)
        #expect(model.pendingNewSelection == nil)
    }

    @Test func reopeningWhileAReplyIsWrittenNeverChangesItsPassageOrTarget() async {
        let engine = TestAIEngine()
        engine.delay = .milliseconds(50)
        let model = model(engine: engine)
        defer { model.stop() }
        model.setCapturedSelection(selection("Passage A", source: "App A"))
        model.openAI(.rewrite)
        model.submitAI()
        #expect(model.ai.isGenerating)

        model.setCapturedSelection(selection("Passage B", source: "App B"))
        model.openAI(.rewrite)
        #expect(model.ai.attachments.map(\.text) == ["Passage A"])
        #expect(model.aiReplaceTarget?.sourceName == "App A")
        #expect(model.pendingNewSelection == nil)
        model.openAI(.rewrite, attachment: AIAttachment(source: .clipboard, text: "Passage C"))
        #expect(model.ai.attachments.map(\.text) == ["Passage A"])
        _ = model.clipboard.copy("Passage D")
        model.attachClipboardToAI()
        model.attachSelectionFromPreviousApp(reportErrors: true)
        #expect(model.ai.attachments.map(\.text) == ["Passage A"])
        #expect(model.aiReplaceTarget?.sourceName == "App A")

        await model.ai.waitForResponse()
        #expect(model.ai.lastSource == "Passage A")
        #expect(model.aiAcceptTitle == "Replace in App A")
    }

    @Test func sendingAFileToAIChatPutsUnsentWritingWorkAway() async throws {
        let model = model()
        defer { model.stop() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "OpenRaySendToAI-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "notes.txt")
        try Data("Meeting notes".utf8).write(to: file)

        model.setCapturedSelection(selection("A passage"))
        model.openAI(.rewrite)
        model.ai.instruction = "Keep it short"
        await model.sendFileToAI(file).value
        #expect(model.ai.action == .chat)

        model.openAI(.rewrite)
        #expect(model.ai.attachments.first?.text == "A passage")
        #expect(model.ai.instruction == "Keep it short")
        #expect(model.aiReplaceTarget?.text == "A passage")
    }

    // MARK: 5. A changed Files query drops what can't be matched afresh

    @Test func aChangedQueryDropsContentOnlyMatchesAndUnmatchableRows() async {
        let metadata = ReviewStubQuery()
        var queries = [metadata, metadata, metadata, metadata]
        let home = FileManager.default.temporaryDirectory.appending(path: "OpenRayReview-\(UUID())")
        let service = FileSearchService(home: home, queryFactory: { queries.removeFirst() }, debounce: .zero)
        defer { service.stop() }
        // Files matches contents: "budget" finds notes.txt by its text and budget-plan.txt by name.
        service.search("budget", showRecent: true)
        await service.waitForPendingSearch()
        metadata.finish(with: ["notes.txt", "budget-plan.txt"], in: home)
        await service.waitForResults()
        #expect(service.results.first { $0.name == "notes.txt" }?.matchedContent == true)

        service.search("plan", showRecent: true)
        #expect(service.results.map(\.name) == ["budget-plan.txt"])
        let ranked = LauncherModel.rankedFileResults(service.results, query: FileQuery.parse("plan"), sort: .relevance)
        #expect(!ranked.contains { $0.name == "notes.txt" })
        // A query the old rows can't be matched against by name alone shows nothing meanwhile.
        service.search("content:plan", showRecent: true)
        #expect(service.results.isEmpty)
        await service.waitForPendingSearch()
        metadata.finish(with: ["budget-plan.txt"], in: home)
        await service.waitForResults()
        // Root search (names only) is another mode: nothing carries over.
        service.search("budget")
        #expect(service.results.isEmpty)
    }

    @Test func turningContentSearchOffWithTheSameQueryDropsContentRows() async {
        let metadata = ReviewStubQuery()
        var queries = [metadata, metadata]
        let home = FileManager.default.temporaryDirectory.appending(path: "OpenRayReview-\(UUID())")
        let service = FileSearchService(home: home, queryFactory: { queries.removeFirst() }, debounce: .zero)
        defer { service.stop() }
        let setting = ContentSetting()
        service.options = {
            var options = FileSearchOptions()
            options.matchesContent = setting.on
            return options
        }
        service.search("budget", showRecent: true)
        await service.waitForPendingSearch()
        metadata.finish(with: ["notes.txt", "budget-plan.txt"], in: home)
        await service.waitForResults()
        #expect(service.results.contains { $0.matchedContent })
        // Settings › Files turns content search off; the Files scope asks the same query again.
        setting.on = false
        service.search("budget", showRecent: true)
        #expect(service.results.isEmpty)
    }

    // MARK: 6. ⌘↩ in ⌘K runs only what's bound to it

    @Test func commandReturnInAIActionsNeverPastes() async {
        let model = model()
        defer { model.stop() }
        model.openAI(.rewrite, attachment: AIAttachment(source: .clipboard, text: "A passage"))
        model.submitAI()
        await model.ai.waitForResponse()
        model.showActions = true
        #expect(model.actionEntries.contains { $0.id == "paste" })
        #expect(!model.actionEntries.contains { $0.shortcut == .commandReturn })
        model.performCommandReturnAction()
        #expect(model.clipboard.readText() == nil)
        model.actionFilter = "zzz"
        model.performCommandReturnAction()
        #expect(model.clipboard.readText() == nil)
        // Choosing Paste is still possible.
        model.actionFilter = ""
        if let paste = model.actionEntries.first(where: { $0.id == "paste" }) { model.performAction(paste) }
        #expect(model.clipboard.readText() == "A helpful reply.")
    }

    @Test func commandReturnInLauncherActionsRunsTheBoundSecondaryAction() throws {
        let model = model()
        defer { model.stop() }
        let snippet = Snippet(name: "Greeting", keyword: "hi", content: "Hello there")
        #expect(model.store.save(snippet))
        model.navigate(to: .snippets)
        model.selectedID = try #require(model.results.first?.id)
        model.showActions = true
        let bound = try #require(model.actionEntries.first { $0.shortcut == .commandReturn })
        #expect(bound.id == "paste")
        model.performCommandReturnAction()
        #expect(!model.showActions)
    }

    // MARK: Minor follow-ups

    @Test func searchFieldsLeaveCompositionKeysToTheInputMethodButKeepArrows() {
        var actions: [String] = []
        let input = LauncherSearchInput(
            text: .constant(""), placeholder: "Search", focusRequest: 0,
            submit: { actions.append("submit") }, move: { _ in actions.append("move") },
            cancel: { actions.append("cancel") }, paste: {}, tab: { actions.append("tab") },
            backtab: { actions.append("backtab") })
        let coordinator = input.makeCoordinator()
        let field = FocusedSearchField()
        let editor = NSTextView()
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        for command in [
            #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.insertBacktab(_:)), #selector(NSResponder.cancelOperation(_:)),
        ] {
            #expect(!coordinator.control(field, textView: editor, doCommandBy: command))
        }
        #expect(actions.isEmpty)
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(actions == ["move"])
    }

    @Test func anActionItemsFollowUpIsTextNotAnEmptyChecklist() async {
        let engine = TestAIEngine()
        engine.snapshots = ["- Lee: Book the room"]
        let model = model(engine: engine)
        defer { model.stop() }
        model.openAI(.actionItems, attachment: AIAttachment(source: .clipboard, text: "Lee will book the room."))
        model.submitAI()
        await model.ai.waitForResponse()
        #expect(!model.aiResultIsUnchanged)
        engine.snapshots = ["Lee will book the room tomorrow."]
        model.ai.instruction = "Write it as one sentence"
        model.submitAI()
        await model.ai.waitForResponse()
        let reply = model.ai.messages[model.ai.messages.count - 1]
        #expect(model.ai.repliesToRevision(reply))
        #expect(!model.aiResultIsUnchanged)
        #expect(model.canAcceptAIResponse)
    }

    @Test func typedMinutesTakeOneOptionalUnit() {
        #expect(CaffeinateCommandProvider.typedMinutes("45") == 45)
        #expect(CaffeinateCommandProvider.typedMinutes("45m") == 45)
        #expect(CaffeinateCommandProvider.typedMinutes(" 45 min ") == 45)
        #expect(CaffeinateCommandProvider.typedMinutes("90 minutes") == 90)
        #expect(CaffeinateCommandProvider.typedMinutes("1m2") == nil)
        #expect(CaffeinateCommandProvider.typedMinutes("m45") == nil)
        #expect(CaffeinateCommandProvider.typedMinutes("45 mm") == nil)
    }

    @Test func commandPeriodStopsCaffeinateInItsListAndAIElsewhere() throws {
        let assertions = ReviewAssertions()
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(),
            caffeinate: CaffeinateService(assertions: assertions, automaticallyMonitors: false))
        defer { model.stop() }
        #expect(model.caffeinate.start())
        model.navigate(to: .notes)
        model.performStopShortcut()
        #expect(model.caffeinate.isActive)
        model.navigate(to: .provided(CaffeinateCommandProvider.scope))
        model.performStopShortcut()
        #expect(!model.caffeinate.isActive)
        #expect(model.feedback?.text == "Caffeinate is off")
    }

    @Test func anInertLaunchNeverReadsAnotherAppsSelection() {
        let model = model()
        defer { model.stop() }
        #expect(throws: SideEffectGuard.Blocked.self) { try model.captureSelection() }
    }
}

@MainActor
private final class ContentSetting {
    var on = true
}

/// Scripted reads for `SelectedTextContext.Probe`.
@MainActor
private final class ProbeScript {
    var frontmost: pid_t? = 42
    var focus: [Bool?] = [true, true]
    var text: String? = "Hello"
    var range: NSRange?

    func reset(range: NSRange?, focus: [Bool?] = [true, true], frontmost: pid_t? = 42, text: String? = "Hello") {
        self.range = range
        self.focus = focus
        self.frontmost = frontmost
        self.text = text
    }

    func nextFocus() -> Bool? { focus.isEmpty ? nil : focus.removeFirst() }
}

@MainActor
private final class PostedKeys {
    var pids: [pid_t] = []
}

@MainActor
private final class ReviewAssertions: CaffeinatePowerAssertions {
    private var next: UInt32 = 1
    func create() throws -> UInt32 {
        defer { next += 1 }
        return next
    }
    func release(_ id: UInt32) throws {}
}

private final class ReviewStubQuery: NSMetadataQuery {
    var items: [NSMetadataItem] = []
    override var resultCount: Int { items.count }
    override func result(at index: Int) -> Any { items[index] }
    override func start() -> Bool { true }
    override func stop() {}
    override func disableUpdates() {}
    override func enableUpdates() {}

    func finish(with names: [String], in home: URL) {
        items = names.map { ReviewStubItem(fixtureURL: home.appendingPathComponent($0)) }
        NotificationCenter.default.post(name: .NSMetadataQueryDidFinishGathering, object: self)
    }
}

private final class ReviewStubItem: NSMetadataItem {
    let url: URL
    init(fixtureURL url: URL) {
        self.url = url
        super.init()
    }
    override func value(forAttribute key: String) -> Any? { key == NSMetadataItemPathKey ? url.path : nil }
}
