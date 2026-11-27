import AppKit
import Testing

@testable import OpenRay

/// Regression tests for the final review of the writing branch (`_orch/reviews/writing-final.md`):
/// positive attribution of a selection copy, ⌘↵ in both primary modes, the windowless run's own
/// app, the whole-field focus identity, publication over the snapshot, and the source of a copy
/// borrowed before History saw it. Every key, paste and clipboard goes through fakes and private
/// pasteboards.
@MainActor
struct WritingFinalReviewTests {
    private var runningApps: [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != me }
    }

    private func write(_ text: String, to board: NSPasteboard, extra: [(String, String)] = []) {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for (type, value) in extra { item.setString(value, forType: NSPasteboard.PasteboardType(type)) }
        board.writeObjects([item])
    }

    private func board(_ text: String) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        write(text, to: board)
        return board
    }

    private func installHUD(on model: LauncherModel) -> FakeHUDPresenter {
        let presenter = FakeHUDPresenter()
        model.hud = HUDController(
            presenter: presenter, screenFrame: { CGRect(x: 0, y: 0, width: 1_440, height: 900) }, schedule: { _, _ in })
        return presenter
    }

    // MARK: Fakes

    @MainActor
    final class Fakes {
        var posted: [pid_t] = []
        var polls = 0
        var disturbed = false
        /// The app the copy environment reports in front; nil stands for OpenRay's own panel.
        var front: pid_t?
        var lastInput: TimeInterval = 0
        var focusedValue: String?
        var onPoll: (Int) -> Void = { _ in }
        /// The app the paste environment reports in front.
        var pasteFront: pid_t?
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
        environment.frontmostProcess = { fakes.front ?? ProcessInfo.processInfo.processIdentifier }
        environment.lastInputAt = { fakes.lastInput }
        environment.now = { 10 }
        environment.focusedValue = { _ in fakes.focusedValue }
        return environment
    }

    /// A paste environment that records instead of posting keys; activation brings the app forward.
    private func pasteEnvironment(_ fakes: Fakes, front: NSRunningApplication? = nil) -> PasteBack.Environment {
        fakes.pasteFront = front?.processIdentifier
        var paste = SyntheticInput.PasteEnvironment()
        paste.checkAllowed = {}
        paste.isTrusted = { true }
        paste.activate = { fakes.pasteFront = $0.processIdentifier }
        paste.frontmostProcess = { fakes.pasteFront }
        paste.secureInput = { false }
        paste.pause = {}
        paste.postPaste = { fakes.posted.append($0) }
        var environment = PasteBack.Environment()
        environment.paste = paste
        environment.restoreDelay = .zero
        environment.sleep = { _ in }
        return environment
    }

    /// Reads with `answer` standing in for whatever lands after ⌘C.
    private func read(
        from app: NSRunningApplication, _ fakes: Fakes, board: NSPasteboard,
        answer: @escaping @MainActor (NSPasteboard) -> Void
    ) async throws -> SelectionCopy.Outcome {
        try await SelectionCopy.read(
            from: app, sourceName: "Editor", pasteboard: board, snapshot: try PasteboardSnapshot.capture(board),
            environment: copyEnvironment(fakes) { _ in answer(board) })
    }

    // MARK: Blocker 1: only a change every check attributes is the selection

    @Test func aCopyMarkedAsFromAnotherDeviceOrAppIsNeverTakenOrPutBackOver() async throws {
        // Any app but a password manager, whose own marker would be its own.
        let app = try #require(
            runningApps.first { app in
                app.bundleIdentifier.map { !$0.hasPrefix("com.agilebits.") && !$0.hasPrefix("com.1password.") } ?? false
            })
        let bundle = try #require(app.bundleIdentifier)
        let marked: [[(String, String)]] = [
            [("com.apple.is-remote-clipboard", "1")],
            [("org.nspasteboard.source", "com.example.sync")],
            [("com.agilebits.onepassword", "1")],
        ]
        for extra in marked {
            let board = board("Earlier copy")
            await #expect(throws: SelectionReadError.copyUnattributable(app: "Editor")) {
                try await self.read(from: app, Fakes(), board: board) { self.write("Synced text", to: $0, extra: extra) }
            }
            // Left exactly as it landed.
            #expect(board.string(forType: .string) == "Synced text")
            #expect(board.string(forType: NSPasteboard.PasteboardType(extra[0].0)) == extra[0].1)
        }
        // A copy that names the source app itself is its answer.
        let own = board("Earlier copy")
        let outcome = try await read(from: app, Fakes(), board: own) {
            self.write("Selected words", to: $0, extra: [("org.nspasteboard.source", bundle)])
        }
        #expect(outcome == .answered(text: "Selected words", restored: own.changeCount))
        #expect(own.string(forType: .string) == "Earlier copy")
    }

    @Test func noCopyIsSentOrTakenUnlessTheSourceAppOrOpenRayIsInFront() async throws {
        let apps = runningApps
        try #require(apps.count >= 2)
        let (appA, appB) = (apps[0], apps[1])
        // B is in front already: no ⌘C goes at all.
        let board = board("Earlier copy")
        let elsewhere = Fakes()
        elsewhere.front = appB.processIdentifier
        await #expect(throws: SelectionReadError.copyUnattributable(app: "Editor")) {
            try await self.read(from: appA, elsewhere, board: board) { self.write("Never sent", to: $0) }
        }
        #expect(elsewhere.posted.isEmpty)
        #expect(board.string(forType: .string) == "Earlier copy")
        // The source app itself in front, as on a windowless hotkey run: its answer is taken.
        let windowless = Fakes()
        windowless.front = appA.processIdentifier
        let answered = try await read(from: appA, windowless, board: board) { self.write("Selected words", to: $0) }
        guard case .answered(let text, _) = answered else {
            Issue.record("Expected an answer, got \(answered)")
            return
        }
        #expect(text == "Selected words")
    }

    @Test func aCopyTheFocusedFieldDoesntHoldIsNeverTaken() async throws {
        let app = try #require(runningApps.first)
        let fakes = Fakes()
        fakes.focusedValue = "Dear team,\n\nThe  report is ready.\nThanks"
        // Text the field doesn't hold: someone else's, left as it is.
        let board = board("Earlier copy")
        await #expect(throws: SelectionReadError.copyUnattributable(app: "Editor")) {
            try await self.read(from: app, fakes, board: board) { self.write("A synced password", to: $0) }
        }
        #expect(board.string(forType: .string) == "A synced password")
        // Text it holds, with line breaks and spaces copied differently, is the selection.
        let held = self.board("Earlier copy")
        let outcome = try await read(from: app, fakes, board: held) { self.write("Dear team, The report\tis ready.", to: $0) }
        guard case .answered(let text, _) = outcome else {
            Issue.record("Expected an answer, got \(outcome)")
            return
        }
        #expect(text == "Dear team, The report\tis ready.")
        #expect(held.string(forType: .string) == "Earlier copy")
        // A field that doesn't share its value can't rule anything out.
        fakes.focusedValue = nil
        let unshared = self.board("Earlier copy")
        _ = try await read(from: app, fakes, board: unshared) { self.write("Anything", to: $0) }
        #expect(unshared.string(forType: .string) == "Earlier copy")
    }

    @Test func aLateChangeIsPutBackOverOnlyWhenEveryCheckHolds() async throws {
        let app = try #require(runningApps.first)
        let store = LibraryStore(fileURL: nil)
        let board = board("Earlier copy")
        let service = ClipboardService(
            store: store, pasteboard: board,
            captureContext: { ClipboardCaptureContext(sourceName: "Editor", sourceBundleID: "com.example.editor", secureInput: false) },
            textRecognizer: nil)
        let fakes = Fakes()
        fakes.focusedValue = "Only this text is in the field."
        // No answer within the timeout; then, in the late window, text the field doesn't hold.
        fakes.onPoll = { poll in if poll == 4 { self.write("A clipboard sync", to: board) } }
        await #expect(throws: SelectionReadError.nothingSelected(app: "Editor")) {
            try await service.readSelectionByCopying(from: app, sourceName: "Editor", environment: self.copyEnvironment(fakes))
        }
        await service.lateCopyWatch?.value
        #expect(board.string(forType: .string) == "A clipboard sync")
    }

    @Test func anUnattributableCopyOffersTheClipboardOrTypingAndLeavesTheClipboardAlone() async throws {
        let app = try #require(runningApps.first)
        let board = board("Earlier copy")
        let model = LauncherModel(store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: board)
        defer { model.stop() }
        model.previousApplication = app
        model.inputMonitoring = WritingReviewTests.FakeInput()
        model.selectionContextReader = { throw SelectionReadError.notExposed(app: "Slack") }
        let fakes = Fakes()
        fakes.focusedValue = "What the field holds."
        model.selectionCopyEnvironment = copyEnvironment(fakes) { _ in self.write("A remote copy", to: board, extra: [("com.apple.is-remote-clipboard", "1")]) }
        model.openAI(.rewrite)
        await model.selectionCaptureTask?.value
        await model.clipboard.lateCopyWatch?.value
        #expect(model.ai.messages.isEmpty)
        #expect(model.selectionNotice?.contains("couldn't be sure the copy came from") == true)
        #expect(model.actions(for: nil).contains { $0.id == "attachClipboard" && $0.title == "Use Clipboard" })
        #expect(board.string(forType: .string) == "A remote copy")
    }

    // MARK: Major 11: ⌘↵ is Copy Response in both modes, everywhere

    @Test func commandReturnCopiesInBothPrimaryModesOnEveryResult() async throws {
        let app = try #require(runningApps.first)
        for primary in AIPrimaryAction.allCases {
            let engine = RecordingAIEngine()
            engine.replies = ["Fixed text."]
            let model = Slice7Fixtures.launcher(engine: engine, selection: "Teh text.")
            defer { model.stop() }
            _ = installHUD(on: model)
            let fakes = Fakes()
            model.pasteBackEnvironment = pasteEnvironment(fakes, front: app)
            #expect(model.aiHub.updateSettings { $0.primaryAction = primary })
            model.previousApplication = app

            func commandReturnCopies(_ result: String) throws {
                // Registered where no field takes the key, as the hidden shortcut buttons are.
                let shortcut = try #require(
                    ActionShortcutButtons.entries(for: model, selected: nil).first {
                        $0.key == .return && $0.modifiers == .command
                    })
                #expect(shortcut.title == "Copy Response")
                _ = model.clipboard.copy("Something else")
                shortcut.perform()
                #expect(model.clipboard.readText() == result)
                // And in ⌘K, whatever row is highlighted.
                _ = model.clipboard.copy("Something else")
                model.showActions = true
                model.performCommandReturnAction()
                #expect(!model.showActions)
                #expect(model.clipboard.readText() == result)
            }

            // A writing command's result.
            model.openAI(.proofread)
            await model.ai.waitForResponse()
            try commandReturnCopies("Fixed text.")
            // A custom AI Command's result, which has no follow-up field.
            let record = AICommandRecord(name: "Haiku", prompt: "Write a haiku about autumn.")
            #expect(model.store.update { $0.aiCommands.append(record) })
            model.commandCatalogDidChange()
            engine.replies = ["Leaves fall."]
            model.perform(try #require(model.commandItems.first { $0.id == AICommand.id(for: record.id) }))
            await model.ai.waitForResponse()
            #expect(model.ai.command != nil)
            try commandReturnCopies("Leaves fall.")
            #expect(fakes.posted.isEmpty)
        }
    }

    // MARK: Windowless focus: the app the run was invoked in

    @Test func aWindowlessRunComparesAgainstTheAppItWasInvokedIn() async throws {
        let apps = runningApps
        try #require(apps.count >= 2)
        let (appA, appB) = (apps[0], apps[1])
        for switches in [true, false] {
            for copies in [true, false] {
                let model = Slice7Fixtures.launcher(engine: RecordingAIEngine())
                defer { model.stop() }
                let hud = installHUD(on: model)
                let record = AICommandRecord(name: "Formal", prompt: "Formal: {selection}", output: "replaceSelection")
                #expect(model.store.update { $0.aiCommands.append(record) })
                model.commandCatalogDidChange()
                model.panelVisibility = { false }
                model.previousApplication = appA
                let screen = Fakes()
                screen.front = appA.processIdentifier
                model.frontmostProcess = { screen.front }
                model.selectionContextReader = { throw SelectionReadError.notExposed(app: "App A") }
                model.selectionCopyReader = { _ in
                    // A copy with no place to replace, or none.
                    guard copies else { throw SelectionReadError.nothingSelected(app: "App A") }
                    return SelectedTextContext(text: "morning team", application: appA, sourceName: "App A") {}
                }
                model.perform(try #require(model.commandItems.first { $0.id == AICommand.id(for: record.id) }))
                if switches {
                    // The person moves to B before A's copy comes back: the launcher's source follows.
                    model.previousApplication = appB
                    screen.front = appB.processIdentifier
                }
                await model.selectionCaptureTask?.value
                if switches {
                    #expect(model.writingSourceApplication?.processIdentifier == appB.processIdentifier)
                    #expect(model.destination == .search)
                    #expect(model.feedback == nil)
                    #expect(hud.presented.last?.message.style == .info)
                } else if copies {
                    #expect(model.destination == .ai)
                } else {
                    #expect(model.feedback?.text.contains("Nothing selected in App A") == true)
                }
            }
        }
    }

    // MARK: Whole-field Quick Fix: the focus's identity is the last check

    @MainActor
    final class FieldLog {
        var events: [String] = []
    }

    @Test func theLastCheckBeforeAWholeFieldPasteIsTheFocusIdentity() async throws {
        let app = try #require(runningApps.first)
        for stillFocused in [false, true] {
            let engine = RecordingAIEngine()
            engine.replies = ["The text."]
            let model = Slice7Fixtures.launcher(engine: engine)
            defer { model.stop() }
            model.selectionReader = nil
            model.unattendedChatFactory = { [unowned model] in AIChatModel(engine: engine, hub: model.ai.hub) }
            _ = installHUD(on: model)
            let fakes = Fakes()
            model.pasteBackEnvironment = pasteEnvironment(fakes, front: app)
            model.selectionContextReader = { throw SelectionReadError.nothingSelected(app: "Mail") }
            let log = FieldLog()
            model.focusedFieldIsSecure = { _ in
                log.events.append("secure")
                return false
            }
            model.focusedFieldReader = {
                // Another ordinary field took the keyboard while the old one was read.
                FocusedFieldContext(
                    text: "Teh text.", application: app, sourceName: "Mail",
                    validate: { log.events.append("validate") },
                    replaceValue: { _ in false },
                    selectAll: {
                        log.events.append("selectAll")
                        return true
                    },
                    isStillFocused: {
                        log.events.append("identity")
                        return stillFocused
                    })
            }
            model.runQuickFix()
            await model.inPlaceTask?.value
            #expect(log.events.last == "identity")
            #expect(Array(log.events.suffix(4)) == ["selectAll", "secure", "validate", "identity"])
            #expect(fakes.posted == (stillFocused ? [app.processIdentifier] : []))
        }
    }

    // MARK: Major 3: published only over the snapshot, right before the clear

    @Test func aCopyLandingRightBeforeOrAfterTheClearIsNeverOverwritten() async throws {
        for stage in [ClipboardService.WriteStage.beforeGenerationCheck, .afterClear] {
            let board = board("Earlier copy")
            let service = ClipboardService(store: LibraryStore(fileURL: nil), pasteboard: board, textRecognizer: nil)
            let snapshot = try service.snapshot()
            service.writeStageHook = { moment in
                if moment == stage { self.write("Copied at that moment", to: board) }
            }
            #expect(service.copyTransient("Improved", over: snapshot.changeCount) == .superseded)
            #expect(board.string(forType: .string) == "Copied at that moment")
            #expect(board.pasteboardItems?.count == 1)
            #expect(board.pasteboardItems?.first?.types.contains(SelectionCopy.transientType) == false)
            // A paste back stops there too, and says the new copy stays.
            let fakes = Fakes()
            let outcome = await PasteBack.run(
                "Improved", into: .current, clipboard: service, validate: {},
                environment: pasteEnvironment(fakes, front: .current))
            #expect(outcome == .notPasted("Something was copied just now, so nothing was pasted and that copy stays on your clipboard."))
            #expect(fakes.posted.isEmpty)
            #expect(board.string(forType: .string) == "Copied at that moment")
        }
        // An ordinary copy that loses after the clear says so.
        let board = board("Earlier copy")
        let service = ClipboardService(store: LibraryStore(fileURL: nil), pasteboard: board, textRecognizer: nil)
        service.writeStageHook = { if $0 == .afterClear { self.write("Theirs", to: board) } }
        #expect(!service.copy("Mine"))
        #expect(service.lastCopyError != nil)
        #expect(board.string(forType: .string) == "Theirs")
    }

    // MARK: Major 4: a copy borrowed before History saw it keeps its first source

    @MainActor
    final class Front {
        var bundle = "com.example.editor"
    }

    @Test func aCopyBorrowedBeforeHistorySawItKeepsTheSourceItWasClassifiedWith() async throws {
        let store = LibraryStore(fileURL: nil)
        #expect(store.update {
            $0.preferences.clipboardEnabled = true
            $0.preferences.excludedClipboardBundleIDs = ["com.example.vault"]
        })
        let front = Front()
        func service(_ board: NSPasteboard) -> ClipboardService {
            ClipboardService(
                store: store, pasteboard: board,
                captureContext: { ClipboardCaptureContext(sourceName: front.bundle, sourceBundleID: front.bundle, secureInput: false) },
                textRecognizer: nil)
        }
        // Copied in the excluded app, borrowed before History's poll ran.
        let vaultBoard = NSPasteboard.withUniqueName()
        let vault = service(vaultBoard)
        write("Secret", to: vaultBoard)
        front.bundle = "com.example.vault"
        let fakes = Fakes()
        _ = await PasteBack.run(
            "Improved", into: .current, clipboard: vault, validate: {}, environment: pasteEnvironment(fakes, front: .current))
        #expect(vaultBoard.string(forType: .string) == "Secret")
        // Withheld from {clipboard} before any poll, and still once another app is in front.
        #expect(vault.placeholderText() == nil)
        front.bundle = "com.example.editor"
        await vault.poll()
        #expect(vault.placeholderText() == nil)
        #expect(!store.database.clipboard.contains { $0.plainText == "Secret" })

        // An allowed copy keeps its source: History credits the app it was classified with.
        let editorBoard = NSPasteboard.withUniqueName()
        let editor = service(editorBoard)
        write("Fresh copy", to: editorBoard)
        _ = await PasteBack.run(
            "Improved", into: .current, clipboard: editor, validate: {}, environment: pasteEnvironment(fakes, front: .current))
        #expect(editor.placeholderText(unattributedIsExcluded: true) == "Fresh copy")
        front.bundle = "com.example.other"
        await editor.poll()
        let entry = try #require(store.database.clipboard.first { $0.plainText == "Fresh copy" })
        #expect(entry.sourceBundleID == "com.example.editor")
    }
}
