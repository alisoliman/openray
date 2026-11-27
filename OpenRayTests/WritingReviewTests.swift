import AppKit
import Testing

@testable import OpenRay

/// Regression tests for the Codex review of the writing branch (`_orch/reviews/writing.md`):
/// run destinations, protected fields, Quick Fix's targets, unattended focus, history, and the
/// selection fallback stopping on dismissal or input. Every paste and key goes through fakes.
@MainActor
struct WritingReviewTests {
    private var runningApps: [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != me }
    }

    private func model(engine: any AIEngine = TestAIEngine(), pasteboard: NSPasteboard = .withUniqueName()) -> LauncherModel {
        LauncherModel(store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine), pasteboard: pasteboard)
    }

    private func selection(
        _ text: String, source: String = "Notes", application: NSRunningApplication?, strictPasses: Bool = true
    ) -> SelectedTextContext {
        var context = SelectedTextContext(text: text, application: application, sourceName: source) {
            if !strictPasses { throw LibraryValidationError("The original selection in \(source) changed.") }
        }
        context.range = NSRange(location: 0, length: (text as NSString).length)
        context.focusIsOriginal = { true }
        return context
    }

    private func installHUD(on model: LauncherModel) -> FakeHUDPresenter {
        let presenter = FakeHUDPresenter()
        model.hud = HUDController(
            presenter: presenter, screenFrame: { CGRect(x: 0, y: 0, width: 1_440, height: 900) }, schedule: { _, _ in })
        return presenter
    }

    @MainActor
    final class PasteLog {
        var posted: [pid_t] = []
        var activated: [pid_t] = []
        var front: pid_t?
    }

    /// A paste back that records instead of posting keys; `log.front` is the app it reports in front.
    private func installPaste(on model: LauncherModel, front: NSRunningApplication?) -> PasteLog {
        let log = PasteLog()
        log.front = front?.processIdentifier
        var paste = SyntheticInput.PasteEnvironment()
        paste.checkAllowed = {}
        paste.isTrusted = { true }
        paste.activate = { app in
            log.activated.append(app.processIdentifier)
            log.front = app.processIdentifier
        }
        paste.frontmostProcess = { log.front }
        paste.secureInput = { false }
        paste.pause = {}
        paste.postPaste = { log.posted.append($0) }
        var environment = PasteBack.Environment()
        environment.paste = paste
        environment.restoreDelay = .zero
        environment.sleep = { _ in }
        model.pasteBackEnvironment = environment
        return log
    }

    // MARK: Blocker 6: a result goes only to the app it's bound to

    @Test func aResultPastesIntoItsOwnAppEvenWhenTheLauncherWasReopenedFromAnother() async throws {
        let apps = runningApps
        try #require(apps.count >= 2)
        let (appA, appB) = (apps[0], apps[1])
        let model = model()
        defer { model.stop() }
        _ = installHUD(on: model)
        let log = installPaste(on: model, front: appB)
        model.setCapturedSelection(selection("We was ready.", source: "App A", application: appA))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        // Reopened from B: ↵ still goes to A, the app the run is bound to.
        model.previousApplication = appB
        #expect(model.aiAcceptTitle == "Paste Response to App A")
        model.submitAI()
        await model.pasteBackTask?.value
        #expect(log.activated == [appA.processIdentifier])
        #expect(log.posted == [appA.processIdentifier])
    }

    @Test func aTypedRunIsBoundToTheAppItStartedFromAndHistoryKeepsIt() async throws {
        let apps = runningApps
        try #require(apps.count >= 2)
        let (appA, appB) = (apps[0], apps[1])
        let model = model()
        defer { model.stop() }
        _ = installHUD(on: model)
        let log = installPaste(on: model, front: appA)
        model.previousApplication = appA
        model.openAI(.rewrite)
        model.ai.draft = "Typed passage"
        model.submitAI()
        await model.ai.waitForResponse()
        // A second run from B, then back to the first with ⌘[.
        model.previousApplication = appB
        model.setCapturedSelection(selection("Other text", source: "App B", application: appB))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        model.showWritingRun(-1)
        #expect(model.ai.lastSource == "Typed passage")
        model.submitAI()
        await model.pasteBackTask?.value
        #expect(log.posted == [appA.processIdentifier])
    }

    @Test func anAppThatQuitIsNeverReplacedByAnother() async throws {
        let apps = runningApps
        try #require(apps.count >= 2)
        let model = model()
        defer { model.stop() }
        _ = installHUD(on: model)
        let log = installPaste(on: model, front: apps[1])
        model.setCapturedSelection(selection("We was ready.", source: "App A", application: apps[0]))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        // Its process is gone (stood in for by another pid): nothing is pasted anywhere.
        model.aiDestination?.processIdentifier = -1
        model.previousApplication = apps[1]
        model.submitAI()
        #expect(model.pasteBackTask == nil)
        #expect(log.posted.isEmpty && log.activated.isEmpty)
        #expect(model.feedback?.text.contains("App A isn't open any more") == true)
        // The result is still there to copy.
        #expect(model.canAcceptAIResponse)
        model.performAISecondary()
        #expect(model.clipboard.readText() == "A helpful reply.")
    }

    // MARK: Major 7: protected fields at delivery

    @Test func aPasswordFieldIsRefusedRightBeforeThePaste() async throws {
        let app = try #require(runningApps.first)
        let model = model()
        defer { model.stop() }
        let hud = installHUD(on: model)
        let log = installPaste(on: model, front: app)
        model.focusedFieldIsSecure = { _ in true }
        model.setCapturedSelection(selection("We was ready.", application: app))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        model.submitAI()
        await model.pasteBackTask?.value
        #expect(log.posted.isEmpty)
        #expect(hud.presented.last?.message == LauncherModel.copiedHUD)
        #expect(model.feedback?.text.contains("password field") == true)
    }

    // MARK: Major 11: the swap is named

    @Test func withCopyAsPrimaryCommandReturnPastesAndSaysWhere() async throws {
        let app = try #require(runningApps.first)
        let model = model()
        defer { model.stop() }
        #expect(model.aiHub.updateSettings { $0.primaryAction = .copy })
        model.setCapturedSelection(selection("A passage", source: "Mail", application: app))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        #expect(model.aiAcceptTitle == "Copy Response")
        #expect(model.aiSecondaryTitle == "Paste Response to Mail")
        let rows = ShortcutsOverlay(model: model, selected: nil).localRows
        #expect(rows.first { $0.0 == "Paste Response to Mail" }?.1 == ["⌘", "↩"])
        #expect(model.actions(for: nil).first { $0.id == "secondary" }?.title == "Paste Response to Mail")
    }

    // MARK: Major 12: drafts never leave a full history

    @Test func historyNeverDropsDraftsOrUnsentWork() async {
        let model = model()
        defer { model.stop() }
        model.openAI(.rewrite)
        model.ai.draft = "A passage I'm still typing"
        for index in 0..<(LauncherModel.writingHistoryLimit + 3) {
            model.setCapturedSelection(selection("Passage \(index)", application: nil))
            model.openAI(.shorten)
            await model.ai.waitForResponse()
        }
        #expect(model.writingRuns.contains { $0.snapshot.draft == "A passage I'm still typing" })
        #expect(model.writingRuns.filter(\.snapshot.isSettled).count == LauncherModel.writingHistoryLimit)
    }

    // MARK: Majors 8, 9, 10, 13: Quick Fix and unattended runs

    @MainActor
    final class FieldLog {
        var replaced: [String] = []
        var selectedAll = 0
        var reads = 0
    }

    private func quickFixModel(_ engine: RecordingAIEngine) -> LauncherModel {
        let model = Slice7Fixtures.launcher(engine: engine)
        model.selectionReader = nil
        model.unattendedChatFactory = { [unowned model] in AIChatModel(engine: engine, hub: model.ai.hub) }
        return model
    }

    private func field(
        _ text: String, application: NSRunningApplication, log: FieldLog, settable: Bool = true, selects: Bool = true
    ) -> FocusedFieldContext {
        FocusedFieldContext(
            text: text, application: application, sourceName: "Mail", validate: {},
            replaceValue: { value in
                guard settable else { return false }
                log.replaced.append(value)
                return true
            },
            selectAll: {
                log.selectedAll += 1
                return selects
            })
    }

    @Test func quickFixNeverWidensOverASelectionItCantRead() async throws {
        let app = try #require(runningApps.first)
        let engine = RecordingAIEngine()
        let model = quickFixModel(engine)
        defer { model.stop() }
        let hud = installHUD(on: model)
        let log = FieldLog()
        model.selectionContextReader = { throw SelectionReadError.notExposed(app: "Mail") }
        model.focusedFieldReader = {
            log.reads += 1
            return self.field("Whole field.", application: app, log: log)
        }
        model.runQuickFix()
        #expect(model.inPlaceTask == nil)
        #expect(log.reads == 0)
        #expect(engine.actionPrompts.isEmpty)
        #expect(hud.presented.last?.message.text == "Mail doesn't share its selected text. Paste or type the text instead.")
    }

    @Test func aWholeFieldPasteChecksItsSelectionRightBeforeTheKey() async throws {
        let app = try #require(runningApps.first)
        let engine = RecordingAIEngine()
        engine.replies = ["Fixed text."]
        let model = quickFixModel(engine)
        defer { model.stop() }
        _ = installHUD(on: model)
        let paste = installPaste(on: model, front: app)
        let log = FieldLog()
        model.selectionContextReader = { throw SelectionReadError.nothingSelected(app: "Mail") }
        // A text area that can't be set; the caret moved, so selecting all doesn't hold.
        model.focusedFieldReader = { self.field("Teh text.", application: app, log: log, settable: false, selects: false) }
        model.runQuickFix()
        await model.inPlaceTask?.value
        #expect(log.selectedAll == 1)
        #expect(paste.posted.isEmpty)
    }

    @Test func anUnattendedRunNeverTakesFocusFromTheAppYouSwitchedTo() async throws {
        let apps = runningApps
        try #require(apps.count >= 2)
        let engine = RecordingAIEngine()
        engine.replies = ["They were late."]
        let model = quickFixModel(engine)
        defer { model.stop() }
        let hud = installHUD(on: model)
        // Quick Fix started in A; B is in front by the time the result is ready.
        let paste = installPaste(on: model, front: apps[1])
        model.setCapturedSelection(selection("They was late.", source: "App A", application: apps[0]))
        let generation = model.clipboard.changeCount
        model.runQuickFix()
        await model.inPlaceTask?.value
        #expect(paste.activated.isEmpty)
        #expect(paste.posted.isEmpty)
        #expect(model.clipboard.changeCount == generation)
        #expect(hud.presented.last?.message.text == "Not replaced: App A isn't in front any more.")
    }

    @Test func quickFixWithNoActionItemsWritesNothing() async throws {
        let app = try #require(runningApps.first)
        let engine = RecordingAIEngine()
        engine.replies = ["No action items found."]
        let model = quickFixModel(engine)
        defer { model.stop() }
        let hud = installHUD(on: model)
        let paste = installPaste(on: model, front: app)
        #expect(model.aiHub.updateSettings { $0.quickFixCommandID = "ai.actionItems" })
        let log = FieldLog()
        model.selectionContextReader = { throw SelectionReadError.nothingSelected(app: "Mail") }
        model.focusedFieldReader = { self.field("The room is bright.", application: app, log: log) }
        model.runQuickFix()
        await model.inPlaceTask?.value
        #expect(log.replaced.isEmpty)
        #expect(paste.posted.isEmpty)
        #expect(hud.presented.last?.message.text == "No action items found")
    }

    @Test func quickFixAsksForArgumentsThenRunsInPlaceOnTheTargetItRead() async throws {
        let app = try #require(runningApps.first)
        let engine = RecordingAIEngine()
        engine.replies = ["Ahoy, the whole field."]
        let model = quickFixModel(engine)
        defer { model.stop() }
        _ = installHUD(on: model)
        _ = installPaste(on: model, front: app)
        let record = AICommandRecord(name: "Persona", prompt: "Rewrite {selection} as {argument name=\"persona\" | raw}.")
        #expect(model.store.update { $0.aiCommands.append(record) })
        model.commandCatalogDidChange()
        #expect(model.aiHub.updateSettings {
            $0.quickFixCommandID = AICommand.id(for: record.id)
            $0.quickFixPrefersSelection = false
        })
        let log = FieldLog()
        model.setCapturedSelection(selection("Just a paragraph.", application: app))
        model.focusedFieldReader = { self.field("The whole field.", application: app, log: log) }
        let quickFix = try #require(model.bindableCommands.first { $0.id == AICommandProvider.quickFixID })
        model.perform(quickFix)
        let session = try #require(model.argumentSession)
        #expect(session.specs.map(\.name) == ["persona"])
        model.setArgumentValue("a pirate", at: 0)
        model.submitArguments()
        await model.inPlaceTask?.value
        // The field Quick Fix read, not the selection, and in place, not in the panel.
        let prompt = try #require(engine.requests.last?.prompt)
        #expect(prompt.contains("The whole field.") && prompt.contains("a pirate"))
        #expect(!prompt.contains("Just a paragraph."))
        #expect(log.replaced == ["Ahoy, the whole field."])
        #expect(model.destination == .search)
    }

    // MARK: Minor: Replace Selection dispatch

    @Test func aReplaceSelectionCommandIsWindowlessWhateverItsPromptReads() async throws {
        let app = try #require(runningApps.first)
        let engine = RecordingAIEngine()
        engine.replies = ["A haiku."]
        let model = Slice7Fixtures.launcher(engine: engine)
        defer { model.stop() }
        _ = installHUD(on: model)
        let paste = installPaste(on: model, front: app)
        model.unattendedChatFactory = { [unowned model] in AIChatModel(engine: engine, hub: model.ai.hub) }
        let record = AICommandRecord(name: "Haiku", prompt: "Write a haiku about autumn.", output: "replaceSelection")
        #expect(model.store.update { $0.aiCommands.append(record) })
        model.commandCatalogDidChange()
        let id = AICommand.id(for: record.id)
        let descriptor = try #require(model.registry.descriptor(for: ProvidedRef(provider: "aicommand", id: id), in: model))
        #expect(descriptor.mode == .noView)
        model.setCapturedSelection(selection("Old words", application: app))
        let row = try #require(model.commandItems.first { $0.id == id })
        model.perform(row)
        await model.inPlaceTask?.value
        #expect(model.destination == .search)
        #expect(paste.posted == [app.processIdentifier])
    }

    // MARK: Blocker 1: the fallback stops on dismissal and on input

    @MainActor
    final class FakeInput: LocalEventMonitoring {
        var handler: ((NSEvent) -> NSEvent?)?
        var removed = 0
        func add(_ mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
            self.handler = handler
            return NSObject()
        }
        func remove(_ monitor: Any) { removed += 1 }
    }

    private func copyModel(board: NSPasteboard, onPoll: @escaping @MainActor (LauncherModel, Int) -> Void) -> (LauncherModel, FakeInput) {
        let model = model(pasteboard: board)
        let input = FakeInput()
        model.inputMonitoring = input
        model.previousApplication = runningApps.first
        model.selectionContextReader = { throw SelectionReadError.notExposed(app: "Slack") }
        var environment = SelectionCopy.Environment()
        environment.checkAllowed = {}
        environment.isTrusted = { true }
        environment.secureInput = { false }
        environment.postCopy = { _ in }
        // The Mac's own input record and front app never reach a test.
        environment.frontmostProcess = { 1 }
        environment.lastInputAt = { 0 }
        environment.now = { 1 }
        environment.timeout = .milliseconds(60)
        environment.lateAnswerWindow = .milliseconds(60)
        environment.pollInterval = .milliseconds(20)
        let polls = PollCount()
        environment.sleep = { [unowned model] _ in
            polls.value += 1
            onPoll(model, polls.value)
        }
        model.selectionCopyEnvironment = environment
        return (model, input)
    }

    @MainActor
    final class PollCount {
        var value = 0
        var input: FakeInput?
    }

    private func write(_ text: String, to board: NSPasteboard) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    @Test func dismissingThePanelStopsTheCopyAndLeavesTheClipboardToThePerson() async {
        let board = NSPasteboard.withUniqueName()
        write("Earlier copy", to: board)
        let (model, input) = copyModel(board: board) { model, poll in
            if poll == 2 {
                model.panelDidHide()
                self.write("Copied after closing", to: board)
            }
        }
        defer { model.stop() }
        model.openAI(.rewrite)
        await model.selectionCaptureTask?.value
        await model.clipboard.lateCopyWatch?.value
        #expect(board.string(forType: .string) == "Copied after closing")
        #expect(model.ai.messages.isEmpty)
        #expect(input.removed == 1)
    }

    @Test func typingInOpenRayStopsTheCopyAndACopyAfterItStays() async throws {
        let board = NSPasteboard.withUniqueName()
        write("Earlier copy", to: board)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        let box = PollCount()
        let (model, fake) = copyModel(board: board) { _, poll in
            if poll == 2 {
                _ = box.input?.handler?(event)
                self.write("Copied by the person", to: board)
            }
        }
        box.input = fake
        defer { model.stop() }
        model.openAI(.rewrite)
        await model.selectionCaptureTask?.value
        await model.clipboard.lateCopyWatch?.value
        #expect(board.string(forType: .string) == "Copied by the person")
        #expect(model.ai.messages.isEmpty)
        #expect(model.selectionNotice?.hasPrefix("Stopped reading the selection") == true)
    }
}
