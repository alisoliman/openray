import AppKit
import Testing

@testable import OpenRay

/// Regression tests for the re-review of the writing branch (`_orch/reviews/writing-rereview.md`):
/// attributable selection copies, run destinations, privacy markers, clipboard generations and
/// classification, paste messages, and the unattended Quick Fix and windowless runs. Every key,
/// paste and clipboard goes through fakes and private pasteboards.
@MainActor
struct WritingRereviewTests {
    private var runningApps: [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != me }
    }

    private func write(_ text: String, to board: NSPasteboard) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private func selection(_ text: String, source: String = "Notes", application: NSRunningApplication?) -> SelectedTextContext {
        var context = SelectedTextContext(text: text, application: application, sourceName: source) {}
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

    // MARK: Fakes

    /// What a fake copy or paste saw, and what it reports about the Mac.
    @MainActor
    final class Fakes {
        var posted: [pid_t] = []
        var activated: [pid_t] = []
        var polls = 0
        var disturbed = false
        var finished = 0
        var restoreFailures: [String] = []
        /// The app the copy environment reports in front, and when its last key or click was.
        var front: pid_t? = 1
        var lastInput: TimeInterval = 0
        /// The app the paste environment reports in front.
        var pasteFront: pid_t?
        var onPoll: (Int) -> Void = { _ in }
        var onPause: () -> Void = {}
    }

    /// A copy environment that never touches the Mac. ⌘C goes at 10 on the fake clock.
    private func copyEnvironment(_ fakes: Fakes, copy: @escaping @MainActor (pid_t) -> Void = { _ in })
        -> SelectionCopy.Environment
    {
        var environment = SelectionCopy.Environment()
        environment.checkAllowed = {}
        environment.isTrusted = { true }
        environment.secureInput = { false }
        environment.postCopy = { pid in
            fakes.posted.append(pid)
            copy(pid)
        }
        environment.timeout = .milliseconds(60)
        environment.lateAnswerWindow = .milliseconds(60)
        environment.pollInterval = .milliseconds(20)
        environment.sleep = { _ in
            fakes.polls += 1
            fakes.onPoll(fakes.polls)
        }
        environment.isUndisturbed = { !fakes.disturbed }
        environment.didFinish = { fakes.finished += 1 }
        environment.didFailToRestore = { fakes.restoreFailures.append($0) }
        environment.frontmostProcess = { fakes.front }
        environment.lastInputAt = { fakes.lastInput }
        environment.now = { 10 }
        return environment
    }

    /// A paste environment that records instead of posting keys. Activation brings the app forward
    /// unless `activationLags`, when it comes forward after the first pause.
    private func pasteEnvironment(_ fakes: Fakes, board: NSPasteboard? = nil, trusted: Bool = true, secureInput: Bool = false, activationLags: Bool = false)
        -> PasteBack.Environment
    {
        var paste = SyntheticInput.PasteEnvironment()
        paste.checkAllowed = {}
        paste.isTrusted = { trusted }
        paste.activate = { app in
            fakes.activated.append(app.processIdentifier)
            if !activationLags { fakes.pasteFront = app.processIdentifier }
        }
        paste.frontmostProcess = { fakes.pasteFront }
        if let board { paste.changeCount = { board.changeCount } }
        paste.secureInput = { secureInput }
        paste.pause = {
            fakes.onPause()
            if activationLags { fakes.pasteFront = fakes.activated.last }
        }
        paste.postPaste = { fakes.posted.append($0) }
        var environment = PasteBack.Environment()
        environment.paste = paste
        environment.restoreDelay = .zero
        environment.sleep = { _ in }
        return environment
    }

    private func service(_ board: NSPasteboard, store: LibraryStore = LibraryStore(fileURL: nil), source: String = "com.example.editor")
        -> ClipboardService
    {
        ClipboardService(
            store: store, pasteboard: board,
            captureContext: { ClipboardCaptureContext(sourceName: "Editor", sourceBundleID: source, secureInput: false) },
            textRecognizer: nil)
    }

    private func board(_ text: String) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        write(text, to: board)
        return board
    }

    // MARK: #1 Only an attributable change is the selection

    @Test func aCopyMadeAfterAnotherAppCameForwardIsNeverReadOrPutBack() async throws {
        let app = try #require(runningApps.first)
        let board = board("Earlier copy")
        let fakes = Fakes()
        // The person switched apps while the source app hadn't answered, and copied there.
        fakes.onPoll = { poll in
            if poll == 2 {
                fakes.front = 2
                self.write("Copied in another app", to: board)
            }
        }
        await #expect(throws: SelectionReadError.copyUnattributable(app: "Editor")) {
            try await SelectionCopy.read(
                from: app, sourceName: "Editor", pasteboard: board, snapshot: try PasteboardSnapshot.capture(board),
                environment: self.copyEnvironment(fakes))
        }
        #expect(board.string(forType: .string) == "Copied in another app")
        // OpenRay's own panel coming forward isn't another app: the answer is still the app's.
        let panelBoard = self.board("Earlier copy")
        let panelFakes = Fakes()
        panelFakes.onPoll = { _ in panelFakes.front = ProcessInfo.processInfo.processIdentifier }
        let outcome = try await SelectionCopy.read(
            from: app, sourceName: "Editor", pasteboard: panelBoard, snapshot: try PasteboardSnapshot.capture(panelBoard),
            environment: copyEnvironment(panelFakes) { _ in self.write("Selected words", to: panelBoard) })
        guard case .answered(let text, _) = outcome else {
            Issue.record("Expected an answer, got \(outcome)")
            return
        }
        #expect(text == "Selected words")
        #expect(panelBoard.string(forType: .string) == "Earlier copy")
    }

    @Test func aKeyOrClickAnywhereDuringTheWaitMeansTheChangeIsNeverTaken() async throws {
        let app = try #require(runningApps.first)
        let board = board("Earlier copy")
        let fakes = Fakes()
        // A key the windowless launcher can't see (⌘C in the source app itself) at 11, after ⌘C went.
        fakes.onPoll = { poll in
            if poll == 2 {
                fakes.lastInput = 11
                self.write("The person's own copy", to: board)
            }
        }
        await #expect(throws: SelectionReadError.copyUnattributable(app: "Editor")) {
            try await SelectionCopy.read(
                from: app, sourceName: "Editor", pasteboard: board, snapshot: try PasteboardSnapshot.capture(board),
                environment: self.copyEnvironment(fakes))
        }
        #expect(board.string(forType: .string) == "The person's own copy")
        // A copy another app says it wrote isn't the source app's answer either.
        let claimed = self.board("Earlier copy")
        await #expect(throws: SelectionReadError.copyUnattributable(app: "Editor")) {
            try await SelectionCopy.read(
                from: app, sourceName: "Editor", pasteboard: claimed, snapshot: try PasteboardSnapshot.capture(claimed),
                environment: self.copyEnvironment(Fakes()) { _ in
                    claimed.clearContents()
                    let item = NSPasteboardItem()
                    item.setString("From a clipboard tool", forType: .string)
                    item.setString("com.example.other", forType: SelectionCopy.sourceType)
                    claimed.writeObjects([item])
                })
        }
        #expect(claimed.string(forType: .string) == "From a clipboard tool")
        #expect(SelectionReadError.copyUnattributable(app: "Editor").errorDescription?.contains("Paste or type") == true)
    }

    @Test func theLateWatchNeverUndoesALaterCopy() async throws {
        let app = try #require(runningApps.first)
        let board = board("Earlier copy")
        let service = service(board)
        let fakes = Fakes()
        // No answer within the timeout (three polls); then the person presses ⌘C themselves.
        fakes.onPoll = { poll in
            if poll == 4 {
                fakes.lastInput = 11
                self.write("Copied by the person", to: board)
            }
        }
        await #expect(throws: SelectionReadError.nothingSelected(app: "Editor")) {
            try await service.readSelectionByCopying(from: app, sourceName: "Editor", environment: self.copyEnvironment(fakes))
        }
        await service.lateCopyWatch?.value
        #expect(board.string(forType: .string) == "Copied by the person")
        #expect(fakes.finished == 1)
    }

    @Test func aWindowlessReplaceSelectionFallsBackToExplicitInputOnAnUnattributableCopy() async throws {
        let app = try #require(runningApps.first)
        let engine = RecordingAIEngine()
        let board = board("Earlier copy")
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine), pasteboard: board,
            registry: CommandRegistry(providers: [AIWritingCommandProvider(), AICommandProvider()]))
        defer { model.stop() }
        _ = installHUD(on: model)
        let record = AICommandRecord(name: "Formal", prompt: "Formal: {selection}", output: "replaceSelection")
        #expect(model.store.update { $0.aiCommands.append(record) })
        model.commandCatalogDidChange()
        // A hotkey in the source app: no panel, and the source app stays in front.
        model.panelVisibility = { false }
        model.previousApplication = app
        model.frontmostProcess = { app.processIdentifier }
        model.inputMonitoring = WritingReviewTests.FakeInput()
        model.selectionContextReader = { throw SelectionReadError.notExposed(app: "Slack") }
        let fakes = Fakes()
        fakes.onPoll = { poll in
            if poll == 2 {
                fakes.lastInput = 11
                self.write("Copied elsewhere", to: board)
            }
        }
        model.selectionCopyEnvironment = copyEnvironment(fakes)
        let row = try #require(model.commandItems.first { $0.id == AICommand.id(for: record.id) })
        model.perform(row)
        await model.selectionCaptureTask?.value
        await model.clipboard.lateCopyWatch?.value
        // Nothing ran on the copy; the panel asks for the text, and the copy stays.
        #expect(fakes.posted == [app.processIdentifier])
        #expect(engine.requests.isEmpty)
        #expect(model.inPlaceTask == nil)
        #expect(model.feedback?.text.contains("couldn't be sure the copy came from") == true)
        #expect(board.string(forType: .string) == "Copied elsewhere")
    }

    // MARK: #6 A run is bound to the app the launcher was opened from

    @Test func theWindowLayoutPickerNeverChangesWhereARunPastes() async throws {
        let apps = runningApps
        try #require(apps.count >= 2)
        let (appA, appB) = (apps[0], apps[1])
        let engine = RecordingAIEngine()
        engine.replies = ["Leaves fall slowly."]
        let model = Slice7Fixtures.launcher(engine: engine)
        defer { model.stop() }
        _ = installHUD(on: model)
        let fakes = Fakes()
        model.pasteBackEnvironment = pasteEnvironment(fakes)
        // Opened from A; B chosen in the window-layout picker; back to Home.
        model.previousApplication = appA
        model.selectTargetWindow(
            WindowManager.TargetWindow(
                pid: appB.processIdentifier, appName: "B", bundleURL: nil,
                element: AXUIElementCreateApplication(appB.processIdentifier), title: "B's window"))
        #expect(model.previousApplication?.processIdentifier == appB.processIdentifier)
        model.navigate(to: .home)
        // A literal-prompt command reads no selection: it's bound to A.
        let record = AICommandRecord(name: "Haiku", prompt: "Write a haiku about autumn.")
        #expect(model.store.update { $0.aiCommands.append(record) })
        model.commandCatalogDidChange()
        model.perform(try #require(model.commandItems.first { $0.id == AICommand.id(for: record.id) }))
        await model.ai.waitForResponse()
        #expect(model.aiRunDestination?.processIdentifier == appA.processIdentifier)
        model.submitAI()
        await model.pasteBackTask?.value
        #expect(fakes.posted == [appA.processIdentifier])
        // A writing command reads its selection from A too, and goes back there.
        model.selectionReader = { "We was ready." }
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        #expect(model.aiReplaceTarget?.application?.processIdentifier == appA.processIdentifier)
        #expect(model.aiRunDestination?.processIdentifier == appA.processIdentifier)
    }

    // MARK: #2 Without Accessibility, the copy carries both markers

    @Test func withoutAccessibilityPasteResponseCopiesWithBothPrivacyMarkers() async throws {
        let app = try #require(runningApps.first)
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: .withUniqueName())
        defer { model.stop() }
        let hud = installHUD(on: model)
        let fakes = Fakes()
        model.pasteBackEnvironment = pasteEnvironment(fakes, trusted: false)
        model.setCapturedSelection(selection("A passage", application: app))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        model.submitAI()
        #expect(model.pasteBackTask == nil)
        #expect(fakes.posted.isEmpty)
        #expect(fakes.activated == [app.processIdentifier])
        #expect(model.clipboard.readText() == "A helpful reply.")
        let types = Set(try model.clipboard.snapshot().items.first?.map(\.type) ?? [])
        #expect(types.isSuperset(of: ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"]))
        #expect(hud.presented.last?.message == LauncherModel.copiedHUD)
    }

    // MARK: #3 Generations at publication, and restore failures

    @Test func aCopyThatArrivedAfterTheSnapshotIsNeverOverwritten() throws {
        let board = board("Earlier copy")
        let service = service(board)
        let snapshot = try service.snapshot()
        write("Copied just now", to: board)
        #expect(service.copyTransient("Improved", over: snapshot.changeCount) == .superseded)
        #expect(board.string(forType: .string) == "Copied just now")
        // Over the snapshot's own generation, it's written.
        guard case .written = service.copyTransient("Improved", over: board.changeCount) else {
            Issue.record("Expected the result to be written")
            return
        }
        #expect(board.string(forType: .string) == "Improved")
    }

    @Test func aLateRestoreThatFailsIsReportedNotDropped() async throws {
        let app = try #require(runningApps.first)
        let board = board("Earlier copy")
        let service = service(board)
        let fakes = Fakes()
        // The app answers late, inside the window; putting the clipboard back fails.
        fakes.onPoll = { poll in if poll == 5 { self.write("Late words", to: board) } }
        var environment = copyEnvironment(fakes)
        environment.restore = { _, _, _ in throw PasteboardBorrowError.notRestored }
        await #expect(throws: SelectionReadError.nothingSelected(app: "Editor")) {
            try await service.readSelectionByCopying(from: app, sourceName: "Editor", environment: environment)
        }
        await service.lateCopyWatch?.value
        #expect(fakes.restoreFailures == ["OpenRay couldn't put your clipboard back."])

        // The launcher says so: in the panel while it shows, with a HUD while it's hidden.
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: .withUniqueName())
        defer { model.stop() }
        let hud = installHUD(on: model)
        model.reportUnrestoredClipboard("OpenRay couldn't put your clipboard back.")
        #expect(model.feedback?.text == "OpenRay couldn't put your clipboard back.")
        model.feedback = nil
        model.panelVisibility = { false }
        model.reportUnrestoredClipboard("OpenRay couldn't put your clipboard back.")
        #expect(model.feedback == nil)
        #expect(hud.presented.last?.message.text == "OpenRay couldn't put your clipboard back.")
    }

    // MARK: #4 A copy History hadn't seen yet stays pending across a borrowing

    @Test func anUnclassifiedCopyKeepsItsPendingStateAcrossAPasteBack() async throws {
        let store = LibraryStore(fileURL: nil)
        #expect(store.update {
            $0.preferences.clipboardEnabled = true
            $0.preferences.excludedClipboardBundleIDs = ["com.example.vault"]
        })
        // An allowed copy, made just before the paste back, before History's poll saw it.
        let board = NSPasteboard.withUniqueName()
        let allowed = service(board, store: store)
        write("Fresh copy", to: board)
        let outcome = await PasteBack.run(
            "Improved", into: .current, clipboard: allowed, validate: {},
            environment: pasteEnvironment(Fakes(), board: board).withFront(.current))
        #expect(outcome == .pasted(restored: true))
        #expect(board.string(forType: .string) == "Fresh copy")
        await allowed.poll()
        #expect(store.database.clipboard.contains { $0.plainText == "Fresh copy" })

        // An excluded app's copy, likewise unseen: still classified, so {clipboard} never has it.
        let vaultBoard = NSPasteboard.withUniqueName()
        let excluded = service(vaultBoard, store: store, source: "com.example.vault")
        write("Secret", to: vaultBoard)
        _ = await PasteBack.run(
            "Improved", into: .current, clipboard: excluded, validate: {},
            environment: pasteEnvironment(Fakes(), board: vaultBoard).withFront(.current))
        #expect(vaultBoard.string(forType: .string) == "Secret")
        await excluded.poll()
        #expect(excluded.placeholderText() == nil)
        #expect(!store.database.clipboard.contains { $0.plainText == "Secret" })
    }

    // MARK: #5 “Paste it with ⌘V” only while the text owns the clipboard

    @Test func theManualPasteInstructionAppearsOnlyWhenTheResultOwnsTheClipboard() async throws {
        let app = try #require(runningApps.first)
        let board = NSPasteboard.withUniqueName()
        let model = LauncherModel(store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: board)
        defer { model.stop() }
        _ = installHUD(on: model)
        let fakes = Fakes()
        model.setCapturedSelection(selection("A passage", application: app))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        // Secure Input refuses the key; the result owns the clipboard, so ⌘V is offered.
        model.pasteBackEnvironment = pasteEnvironment(fakes, secureInput: true)
        model.submitAI()
        await model.pasteBackTask?.value
        #expect(model.feedback?.text == "Secure Input is on, so nothing was pasted. \(LauncherModel.pasteItYourself)")
        // Someone copies while the app comes forward: ⌘V would paste their copy, so it isn't offered.
        fakes.onPause = { self.write("The person's own copy", to: board) }
        fakes.pasteFront = nil
        model.pasteBackEnvironment = pasteEnvironment(fakes, activationLags: true)
        model.feedback = nil
        model.submitAI()
        await model.pasteBackTask?.value
        #expect(fakes.posted.isEmpty)
        let text = try #require(model.feedback?.text)
        #expect(text.contains("nothing was pasted"))
        #expect(!text.contains("⌘V"))
        #expect(board.string(forType: .string) == "The person's own copy")
        // The strict check's own messages never claim it either.
        for range in [nil, NSRange(location: 0, length: 1)] {
            do {
                try SelectedTextContext.verifyUnchanged(
                    capturedText: "A", capturedRange: range, appIsRunning: true, sameElement: false, currentText: "A",
                    currentRange: range, sourceName: "Notes")
                Issue.record("Expected the strict check to refuse")
            } catch {
                #expect(error.localizedDescription.hasSuffix("so nothing was replaced."))
                #expect(!error.localizedDescription.contains("⌘V"))
            }
        }
    }

    // MARK: Whole-field Quick Fix: focus and password fields after select-all

    @MainActor
    final class FieldState {
        var validations = 0
        var selected = false
        var replaced: [String] = []
    }

    private func quickFixModel(_ engine: RecordingAIEngine) -> LauncherModel {
        let model = Slice7Fixtures.launcher(engine: engine)
        model.selectionReader = nil
        model.unattendedChatFactory = { [unowned model] in AIChatModel(engine: engine, hub: model.ai.hub) }
        return model
    }

    /// A text area (no direct set) whose focus moves, or becomes a password field, as its whole
    /// text is selected.
    private func movingField(_ state: FieldState, application: NSRunningApplication, focusMoves: Bool) -> FocusedFieldContext {
        FocusedFieldContext(
            text: "Teh text.", application: application, sourceName: "Mail",
            validate: {
                state.validations += 1
                if focusMoves, state.selected {
                    throw LibraryValidationError("The text in Mail changed, so nothing was replaced.")
                }
            },
            replaceValue: { value in
                state.replaced.append(value)
                return false
            },
            selectAll: {
                state.selected = true
                return true
            })
    }

    @Test func aWholeFieldPasteRechecksFocusAndPasswordFieldsAfterSelectingAll() async throws {
        let app = try #require(runningApps.first)
        for focusMoves in [true, false] {
            let engine = RecordingAIEngine()
            engine.replies = ["The text."]
            let model = quickFixModel(engine)
            defer { model.stop() }
            let hud = installHUD(on: model)
            let fakes = Fakes()
            model.pasteBackEnvironment = pasteEnvironment(fakes).withFront(app)
            let state = FieldState()
            model.selectionContextReader = { throw SelectionReadError.nothingSelected(app: "Mail") }
            model.focusedFieldReader = { self.movingField(state, application: app, focusMoves: focusMoves) }
            // Otherwise a password field takes the keyboard as the text is selected.
            if !focusMoves { model.focusedFieldIsSecure = { _ in state.selected } }
            model.runQuickFix()
            await model.inPlaceTask?.value
            #expect(state.selected)
            #expect(fakes.posted.isEmpty)
            #expect(hud.presented.last?.message != HUDMessage("Fixed", symbol: "checkmark.circle.fill"))
            if focusMoves { #expect(state.validations == 3) }
        }
    }

    // MARK: Windowless delayed copy: no panel over the app you moved to

    @Test func aDelayedCopyNeverBringsThePanelUpOverAnotherApp() async throws {
        let apps = runningApps
        try #require(apps.count >= 2)
        let (appA, appB) = (apps[0], apps[1])
        for stillInFront in [false, true] {
            let engine = RecordingAIEngine()
            let model = Slice7Fixtures.launcher(engine: engine)
            defer { model.stop() }
            let hud = installHUD(on: model)
            let record = AICommandRecord(name: "Formal", prompt: "Formal: {selection}", output: "replaceSelection")
            #expect(model.store.update { $0.aiCommands.append(record) })
            model.commandCatalogDidChange()
            model.panelVisibility = { false }
            model.previousApplication = appA
            // By the time A's copy arrives, the person may be in B.
            model.frontmostProcess = { (stillInFront ? appA : appB).processIdentifier }
            model.selectionContextReader = { throw SelectionReadError.notExposed(app: "App A") }
            model.selectionCopyReader = { _ in
                // Copied, so its place is unknown and it can't be replaced in place.
                SelectedTextContext(text: "morning team", application: appA, sourceName: "App A") {}
            }
            model.perform(try #require(model.commandItems.first { $0.id == AICommand.id(for: record.id) }))
            await model.selectionCaptureTask?.value
            if stillInFront {
                // Still in A: the panel's run, where ↵ can paste over the copied text.
                #expect(model.destination == .ai)
            } else {
                #expect(model.destination == .search)
                #expect(model.ai.messages.isEmpty)
                #expect(hud.presented.last?.message.text == "“Formal” didn't run: App A isn't in front any more.")
                #expect(hud.presented.last?.message.style == .info)
            }
        }
    }

    // MARK: History and a cancelled capture's ambiguous copy

    @Test func aCancelledCapturesCopyStaysOnTheClipboardButOutOfHistory() async throws {
        let app = try #require(runningApps.first { $0.bundleIdentifier != nil })
        let bundle = try #require(app.bundleIdentifier)
        let store = LibraryStore(fileURL: nil)
        #expect(store.update {
            $0.preferences.clipboardEnabled = true
            $0.preferences.excludedClipboardBundleIDs = [bundle]
        })
        let board = board("Earlier copy")
        // History's poll would credit the launcher in front, which isn't excluded.
        let service = service(board, store: store)
        await service.poll()
        let fakes = Fakes()
        // The excluded app answers ⌘C, and the person types in the launcher before the next poll.
        await #expect(throws: CancellationError.self) {
            try await service.readSelectionByCopying(
                from: app, sourceName: "Vault", environment: self.copyEnvironment(fakes) { _ in
                    self.write("Selected secret", to: board)
                    fakes.disturbed = true
                })
        }
        await service.lateCopyWatch?.value
        #expect(board.string(forType: .string) == "Selected secret")
        await service.poll()
        #expect(!store.database.clipboard.contains { $0.plainText == "Selected secret" })
        #expect(service.placeholderText() == nil)
        #expect(fakes.finished == 1)
        // A copy after the window is the person's, and History has it.
        write("Copied afterwards", to: board)
        await service.poll()
        #expect(store.database.clipboard.contains { $0.plainText == "Copied afterwards" })
    }

    // MARK: A retained Quick Fix form checks its command again on submit

    @Test func aRetainedQuickFixFormNeverRunsACommandTurnedOffOrDeleted() async throws {
        let app = try #require(runningApps.first)
        let engine = RecordingAIEngine()
        engine.replies = ["Ahoy."]
        let model = quickFixModel(engine)
        defer { model.stop() }
        _ = installHUD(on: model)
        let fakes = Fakes()
        model.pasteBackEnvironment = pasteEnvironment(fakes).withFront(app)
        let record = AICommandRecord(name: "Persona", prompt: "Rewrite {selection} as {argument name=\"persona\" | raw}.")
        #expect(model.store.update { $0.aiCommands.append(record) })
        model.commandCatalogDidChange()
        let id = AICommand.id(for: record.id)
        #expect(model.aiHub.updateSettings { $0.quickFixCommandID = id })
        model.setCapturedSelection(selection("Just a paragraph.", application: app))
        let quickFix = try #require(model.bindableCommands.first { $0.id == AICommandProvider.quickFixID })

        // Turned off while the form waits.
        model.perform(quickFix)
        #expect(model.argumentSession != nil)
        #expect(model.setCommand(id, enabled: false))
        model.setArgumentValue("a pirate", at: 0)
        model.submitArguments()
        #expect(model.inPlaceTask == nil)
        #expect(model.feedback?.text.contains("turned off") == true)

        // Deleted while the form waits.
        #expect(model.setCommand(id, enabled: true))
        model.perform(quickFix)
        #expect(model.argumentSession != nil)
        #expect(model.store.update { $0.aiCommands.removeAll { $0.id == record.id } })
        model.commandCatalogDidChange()
        model.setArgumentValue("a pirate", at: 0)
        model.submitArguments()
        #expect(model.inPlaceTask == nil)
        #expect(model.feedback?.text.contains("no longer exists") == true)
        #expect(engine.requests.isEmpty)
        #expect(fakes.posted.isEmpty)
    }
}

extension PasteBack.Environment {
    /// The same environment, reporting `application` in front from the start.
    @MainActor fileprivate func withFront(_ application: NSRunningApplication) -> PasteBack.Environment {
        var environment = self
        let pid = application.processIdentifier
        let frontmost = paste.frontmostProcess
        environment.paste.frontmostProcess = { frontmost() ?? pid }
        return environment
    }
}
