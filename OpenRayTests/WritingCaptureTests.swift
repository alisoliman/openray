import AppKit
import Testing

@testable import OpenRay

/// A pasteboard item whose promised type never arrives: a board that can't be read whole.
private final class SilentProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
}

/// The writing rebuild's clipboard work (work items 2 and 6, review blocker 1 and majors 2–5): the
/// ⌘C selection fallback and the paste back, both on private pasteboards with fake key posters and
/// clocks, so nothing reaches another app or the person's clipboard.
@MainActor
struct WritingCaptureTests {
    /// Another app's process, which the fakes never touch: the fallback refuses OpenRay itself.
    private var otherApp: NSRunningApplication {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.first { $0.processIdentifier != me } ?? .current
    }

    private func pasteboard(with items: [[(String, Data)]]) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.writeObjects(
            items.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
                return item
            })
        return board
    }

    /// Rich text, plain text, a private type, and a second item: what restore must keep.
    private var mixedContents: [[(String, Data)]] {
        [
            [
                (NSPasteboard.PasteboardType.string.rawValue, Data("Earlier copy".utf8)),
                (NSPasteboard.PasteboardType.rtf.rawValue, Data("{\\rtf1 Earlier copy}".utf8)),
                ("com.example.private", Data([1, 2, 3])),
            ],
            [(NSPasteboard.PasteboardType.string.rawValue, Data("Second item".utf8))],
        ]
    }

    /// Someone else writing to the board: another app, or the person.
    private func write(_ text: String, to board: NSPasteboard) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// What the fakes saw, and whether the launcher was disturbed.
    @MainActor
    private final class Recorder {
        var posted: [pid_t] = []
        var polls = 0
        var disturbed = false
        var finished = 0
        /// The app the fake reports in front (OpenRay's panel, over the source app), and when the
        /// fake's last key or click was.
        var front: pid_t? = ProcessInfo.processInfo.processIdentifier
        var lastInput: TimeInterval = 0
        /// Runs on each poll, before the poll looks at the board.
        var onPoll: (Int) -> Void = { _ in }
    }

    /// A copy environment that never touches the Mac: `copy` stands in for the app's ⌘C.
    private func environment(
        _ seen: Recorder = Recorder(), copy: @escaping @MainActor (pid_t) -> Void = { _ in }
    ) -> SelectionCopy.Environment {
        var environment = SelectionCopy.Environment()
        environment.checkAllowed = {}
        environment.isTrusted = { true }
        environment.secureInput = { false }
        environment.postCopy = { pid in
            seen.posted.append(pid)
            copy(pid)
        }
        environment.timeout = .milliseconds(60)
        environment.lateAnswerWindow = .milliseconds(60)
        environment.pollInterval = .milliseconds(20)
        environment.sleep = { _ in
            try Task.checkCancellation()
            seen.polls += 1
            seen.onPoll(seen.polls)
        }
        environment.isUndisturbed = { !seen.disturbed }
        environment.didFinish = { seen.finished += 1 }
        // ⌘C goes at 10 on the fake clock; any key or click after that is the person's.
        environment.frontmostProcess = { seen.front }
        environment.lastInputAt = { seen.lastInput }
        environment.now = { 10 }
        environment.focusedValue = { _ in nil }
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

    // MARK: The app's answer

    @Test func theAppsAnswerIsReadAndTheClipboardPutBackWhole() async throws {
        let board = pasteboard(with: mixedContents)
        let before = try PasteboardSnapshot.capture(board)
        let seen = Recorder()
        let app = otherApp
        let outcome = try await SelectionCopy.read(
            from: app, sourceName: "Editor", pasteboard: board, snapshot: before,
            environment: environment(seen, copy: { _ in self.write("Selected words", to: board) }))
        guard case .answered(let text, let restored) = outcome else {
            Issue.record("Expected an answer, got \(outcome)")
            return
        }
        #expect(text == "Selected words")
        #expect(seen.posted == [app.processIdentifier])
        // Put back right after the read: every item and type, in order.
        #expect(restored == board.changeCount)
        #expect(try PasteboardSnapshot.capture(board).items == before.items)
        #expect(board.pasteboardItems?.count == 2)
        #expect(board.pasteboardItems?.first?.data(forType: .rtf) == Data("{\\rtf1 Earlier copy}".utf8))
    }

    @Test func noAnswerLeavesTheClipboardAlone() async throws {
        let board = pasteboard(with: mixedContents)
        let generation = board.changeCount
        let seen = Recorder()
        let outcome = try await SelectionCopy.read(
            from: otherApp, sourceName: "Editor", pasteboard: board, snapshot: try PasteboardSnapshot.capture(board),
            environment: environment(seen))
        guard case .unanswered = outcome else {
            Issue.record("Expected no answer, got \(outcome)")
            return
        }
        // Waited the whole timeout (60 ms in 20 ms polls), and wrote nothing.
        #expect(seen.polls == 3)
        #expect(board.changeCount == generation)
        #expect(SelectionReadError.nothingSelected(app: "Editor").errorDescription == "Nothing selected in Editor.")
    }

    @Test func anAnswerOnTheLastPollIsStillTheApps() async throws {
        let board = pasteboard(with: mixedContents)
        let before = try PasteboardSnapshot.capture(board)
        let seen = Recorder()
        seen.onPoll = { poll in if poll == 3 { self.write("Late words", to: board) } }
        let outcome = try await SelectionCopy.read(
            from: otherApp, sourceName: "Editor", pasteboard: board, snapshot: before, environment: environment(seen))
        guard case .answered(let text, _) = outcome else {
            Issue.record("Expected an answer, got \(outcome)")
            return
        }
        #expect(text == "Late words")
        #expect(try PasteboardSnapshot.capture(board).items == before.items)
    }

    // MARK: Someone else's copy always wins (review blocker 1)

    @Test func aCopyMadeDuringTheWaitIsNeverReadOrUndone() async throws {
        let board = pasteboard(with: mixedContents)
        let seen = Recorder()
        // The person types or clicks in OpenRay, then copies, while the app hasn't answered.
        seen.onPoll = { poll in
            if poll == 2 {
                seen.disturbed = true
                self.write("The person's own copy", to: board)
            }
        }
        await #expect(throws: CancellationError.self) {
            try await SelectionCopy.read(
                from: self.otherApp, sourceName: "Editor", pasteboard: board,
                snapshot: try PasteboardSnapshot.capture(board), environment: self.environment(seen))
        }
        #expect(board.string(forType: .string) == "The person's own copy")
    }

    @Test func aDisturbedCaptureSendsNoCopy() async throws {
        let board = pasteboard(with: mixedContents)
        let seen = Recorder()
        seen.disturbed = true
        await #expect(throws: CancellationError.self) {
            try await SelectionCopy.read(
                from: self.otherApp, sourceName: "Editor", pasteboard: board,
                snapshot: try PasteboardSnapshot.capture(board), environment: self.environment(seen))
        }
        #expect(seen.posted.isEmpty)
    }

    @Test func aLateAnswerInsideTheWindowIsPutBackAndKeptOutOfHistory() async throws {
        let store = LibraryStore(fileURL: nil)
        #expect(store.update { $0.preferences.clipboardEnabled = true })
        let board = pasteboard(with: mixedContents)
        let before = try PasteboardSnapshot.capture(board)
        let service = service(board, store: store)
        let seen = Recorder()
        // Three polls time the copy out; it lands during the 300 ms-style window after them.
        seen.onPoll = { poll in if poll == 5 { self.write("Late words", to: board) } }
        await #expect(throws: SelectionReadError.nothingSelected(app: "Editor")) {
            try await service.readSelectionByCopying(from: self.otherApp, sourceName: "Editor", environment: self.environment(seen))
        }
        await service.poll()
        await service.lateCopyWatch?.value
        #expect(try PasteboardSnapshot.capture(board).items == before.items)
        #expect(seen.finished == 1)
        await service.poll()
        #expect(!store.database.clipboard.contains { $0.plainText == "Late words" })
    }

    @Test func aCopyAfterTheWindowStaysAndGoesToHistory() async throws {
        let store = LibraryStore(fileURL: nil)
        #expect(store.update { $0.preferences.clipboardEnabled = true })
        let board = pasteboard(with: mixedContents)
        let service = service(board, store: store)
        let seen = Recorder()
        await #expect(throws: SelectionReadError.nothingSelected(app: "Editor")) {
            try await service.readSelectionByCopying(from: self.otherApp, sourceName: "Editor", environment: self.environment(seen))
        }
        await service.lateCopyWatch?.value
        #expect(seen.polls == 6)
        // Nothing watches any more: the person's copy is theirs.
        write("Copied afterwards", to: board)
        await service.poll()
        #expect(board.string(forType: .string) == "Copied afterwards")
        #expect(store.database.clipboard.contains { $0.plainText == "Copied afterwards" })
    }

    @Test func dismissalEndsTheLateWindowSoALaterCopyStaysButOutOfHistory() async throws {
        let store = LibraryStore(fileURL: nil)
        #expect(store.update { $0.preferences.clipboardEnabled = true })
        let board = pasteboard(with: mixedContents)
        let service = service(board, store: store)
        let seen = Recorder()
        // The panel closes during the late window, then a copy lands.
        seen.onPoll = { poll in
            if poll == 4 {
                seen.disturbed = true
                self.write("Copied after closing", to: board)
            }
        }
        await #expect(throws: SelectionReadError.nothingSelected(app: "Editor")) {
            try await service.readSelectionByCopying(from: self.otherApp, sourceName: "Editor", environment: self.environment(seen))
        }
        await service.lateCopyWatch?.value
        #expect(board.string(forType: .string) == "Copied after closing")
        // It may be the app's late answer, so History leaves it out (re-review #10).
        await service.poll()
        #expect(!store.database.clipboard.contains { $0.plainText == "Copied after closing" })
    }

    // MARK: Snapshots and the guard (review major 3, minor rule 4)

    @Test func anIncompleteClipboardIsNeverBorrowed() async throws {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString("Visible", forType: .string)
        item.setDataProvider(SilentProvider(), forTypes: [NSPasteboard.PasteboardType("com.example.promised")])
        board.writeObjects([item])
        #expect(throws: PasteboardBorrowError.unreadable) { try PasteboardSnapshot.capture(board) }
        let seen = Recorder()
        await #expect(throws: PasteboardBorrowError.unreadable) {
            try await self.service(board).readSelectionByCopying(
                from: self.otherApp, sourceName: "Editor", environment: self.environment(seen))
        }
        #expect(seen.posted.isEmpty)
        #expect(board.string(forType: .string) == "Visible")
    }

    @Test func restoreGoesOnlyOverItsOwnGenerationAndNeverOnTheGeneralBoardWhileInert() throws {
        let board = pasteboard(with: mixedContents)
        let snapshot = try PasteboardSnapshot.capture(board)
        write("Newer copy", to: board)
        #expect(try snapshot.restore(to: board, over: board.changeCount - 1) == nil)
        #expect(board.string(forType: .string) == "Newer copy")
        #expect(try snapshot.restore(to: board, over: board.changeCount) != nil)
        #expect(try PasteboardSnapshot.capture(board).items == snapshot.items)
        // The process's own rule refuses the general pasteboard before touching it.
        #expect(throws: SideEffectGuard.Blocked.self) {
            try snapshot.restore(to: .general, over: NSPasteboard.general.changeCount)
        }
    }

    @Test func refusalsSendNoKey() async throws {
        let board = pasteboard(with: mixedContents)
        let snapshot = try PasteboardSnapshot.capture(board)
        let seen = Recorder()
        var environment = environment(seen)
        environment.secureInput = { true }
        await #expect(throws: SelectionReadError.secureInput) {
            try await SelectionCopy.read(
                from: self.otherApp, sourceName: "Editor", pasteboard: board, snapshot: snapshot, environment: environment)
        }
        environment.secureInput = { false }
        environment.isTrusted = { false }
        await #expect(throws: SelectionReadError.accessibilityOff) {
            try await SelectionCopy.read(
                from: self.otherApp, sourceName: "Editor", pasteboard: board, snapshot: snapshot, environment: environment)
        }
        // The default guard in the test host refuses before any key.
        environment.isTrusted = { true }
        environment.checkAllowed = SelectionCopy.Environment().checkAllowed
        await #expect(throws: SideEffectGuard.Blocked.self) {
            try await SelectionCopy.read(
                from: self.otherApp, sourceName: "Editor", pasteboard: board, snapshot: snapshot, environment: environment)
        }
        // OpenRay never copies from itself.
        environment.checkAllowed = {}
        await #expect(throws: SelectionReadError.noSourceApp) {
            try await SelectionCopy.read(from: .current, sourceName: "OpenRay", pasteboard: board, snapshot: snapshot, environment: environment)
        }
        #expect(seen.posted.isEmpty)
    }

    @Test func theSecureInputMessageNeverAsksForAccessibility() {
        let message = SelectionReadError.secureInput.errorDescription ?? ""
        #expect(message.contains("Secure Input"))
        #expect(!message.contains("Accessibility"))
        #expect(SelectionReadError.secureInput.allowsCopyFallback == false)
        #expect(SelectionReadError.notExposed(app: "Slack").allowsCopyFallback)
        // An empty selection Accessibility can see gets no ⌘C: some editors would copy the line.
        #expect(!SelectionReadError.nothingSelected(app: "Slack").allowsCopyFallback)
    }

    // MARK: Borrowing (review major 4)

    @MainActor
    private final class Gate {
        var log: [String] = []
        var waiter: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { waiter = $0 } }
        func open() { waiter?.resume() }
    }

    @Test func borrowingsTakeTurnsSoNeitherRestoresTheOthersContents() async {
        let service = service(pasteboard(with: mixedContents))
        let gate = Gate()
        let first = Task {
            await service.borrowing {
                gate.log.append("first")
                await gate.wait()
                gate.log.append("first done")
            }
        }
        for _ in 0..<20 where gate.waiter == nil { await Task.yield() }
        let second = Task { await service.borrowing { gate.log.append("second") } }
        for _ in 0..<20 { await Task.yield() }
        #expect(gate.log == ["first"])
        gate.open()
        await first.value
        await second.value
        #expect(gate.log == ["first", "first done", "second"])
    }

    @Test func theAnswerAndTheRestoreStayOutOfHistory() async throws {
        let store = LibraryStore(fileURL: nil)
        #expect(store.update { $0.preferences.clipboardEnabled = true })
        let board = pasteboard(with: [[(NSPasteboard.PasteboardType.string.rawValue, Data("Earlier copy".utf8))]])
        let service = service(board, store: store)
        await service.poll()
        let entries = store.database.clipboard.count
        let text = try await service.readSelectionByCopying(
            from: otherApp, sourceName: "Editor", environment: environment(copy: { _ in self.write("Selected words", to: board) }))
        #expect(text == "Selected words")
        await service.poll()
        #expect(store.database.clipboard.count == entries)
        #expect(!store.database.clipboard.contains { $0.plainText == "Selected words" })
    }

    @Test func anExcludedCopyStaysExcludedAndAnAllowedOneUsableAfterARestore() async throws {
        let store = LibraryStore(fileURL: nil)
        #expect(store.update {
            $0.preferences.clipboardEnabled = true
            $0.preferences.excludedClipboardBundleIDs = ["com.example.vault"]
        })
        let board = NSPasteboard.withUniqueName()
        let excluded = service(board, store: store, source: "com.example.vault")
        // Copied from the excluded app once the service is watching.
        write("Secret", to: board)
        await excluded.poll()
        #expect(excluded.placeholderText() == nil)
        _ = try await excluded.readSelectionByCopying(
            from: otherApp, sourceName: "Editor", environment: environment(copy: { _ in self.write("Selected words", to: board) }))
        // Put back under a new generation, and still never offered to {clipboard}.
        #expect(board.string(forType: .string) == "Secret")
        #expect(excluded.placeholderText() == nil)

        let allowedBoard = NSPasteboard.withUniqueName()
        let allowed = service(allowedBoard, store: store)
        write("Allowed", to: allowedBoard)
        await allowed.poll()
        #expect(allowed.placeholderText(unattributedIsExcluded: true) == "Allowed")
        let log = PasteLog()
        let outcome = await PasteBack.run(
            "Improved", into: .current, clipboard: allowed, validate: {}, environment: pasteEnvironment(log, board: allowedBoard))
        #expect(outcome == .pasted(restored: true))
        // Still attributed after the paste back, so a quicklink can use it.
        #expect(allowed.placeholderText(unattributedIsExcluded: true) == "Allowed")
    }

    // MARK: Paste back

    @MainActor
    private final class PasteLog {
        var posted: [pid_t] = []
        var activated: [pid_t] = []
        /// What the clipboard held when ⌘V went: its items and their types.
        var pastedText: String?
        var pastedItems: [[String]] = []
        var sleeps: [Duration] = []
        var frontmostReads = 0
    }

    private func pasteEnvironment(
        _ log: PasteLog, board: NSPasteboard,
        frontmost: @escaping @MainActor () -> pid_t? = { NSRunningApplication.current.processIdentifier },
        secureInput: Bool = false, pause: @escaping @MainActor () -> Void = {}
    ) -> PasteBack.Environment {
        var paste = SyntheticInput.PasteEnvironment()
        paste.checkAllowed = {}
        paste.isTrusted = { true }
        paste.activate = { log.activated.append($0.processIdentifier) }
        paste.frontmostProcess = {
            log.frontmostReads += 1
            return frontmost()
        }
        paste.secureInput = { secureInput }
        paste.pause = { pause() }
        paste.postPaste = { pid in
            log.posted.append(pid)
            log.pastedText = board.string(forType: .string)
            log.pastedItems = (board.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
        }
        var environment = PasteBack.Environment()
        environment.paste = paste
        environment.restoreDelay = .milliseconds(400)
        environment.sleep = { log.sleeps.append($0) }
        return environment
    }

    @Test func theResultIsPublishedMarkedInOneItemThenTheClipboardComesBack() async throws {
        let board = pasteboard(with: mixedContents)
        let before = try PasteboardSnapshot.capture(board)
        let service = service(board)
        let log = PasteLog()
        let me = NSRunningApplication.current
        let seen = Recorder()
        let outcome = await PasteBack.run(
            "Improved text", into: me, clipboard: service, validate: {},
            environment: pasteEnvironment(log, board: board), willPaste: { seen.finished += 1 })
        #expect(outcome == .pasted(restored: true))
        #expect(seen.finished == 1)
        #expect(log.activated == [me.processIdentifier])
        #expect(log.posted == [me.processIdentifier])
        #expect(log.pastedText == "Improved text")
        // One item, with both markers from its first write.
        #expect(log.pastedItems.count == 1)
        #expect(Set(log.pastedItems.first ?? []).isSuperset(of: ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"]))
        #expect(log.sleeps == [.milliseconds(400)])
        #expect(try PasteboardSnapshot.capture(board).items == before.items)
    }

    @Test func aRefusedPasteLeavesTheResultCopiedAndSaysPressCommandV() async {
        let board = pasteboard(with: mixedContents)
        let log = PasteLog()
        // Another app came to the front.
        let outcome = await PasteBack.run(
            "Improved text", into: .current, clipboard: service(board), validate: {},
            environment: pasteEnvironment(log, board: board, frontmost: { 1 }))
        guard case .copied = outcome else {
            Issue.record("Expected the result to be copied, got \(outcome)")
            return
        }
        #expect(log.posted.isEmpty)
        #expect(log.sleeps.isEmpty)
        #expect(board.string(forType: .string) == "Improved text")
    }

    @Test func secureInputRefusesThePaste() async {
        let board = pasteboard(with: mixedContents)
        let log = PasteLog()
        let outcome = await PasteBack.run(
            "Improved text", into: .current, clipboard: service(board), validate: {},
            environment: pasteEnvironment(log, board: board, secureInput: true))
        #expect(outcome == .copied("Secure Input is on, so nothing was pasted."))
        #expect(log.posted.isEmpty)
    }

    @Test func aCopyMadeWhileTheAppComesForwardIsNeverClaimed() async {
        let board = pasteboard(with: mixedContents)
        let log = PasteLog()
        // The app takes a moment to come forward; meanwhile the person copies.
        let environment = pasteEnvironment(
            log, board: board, frontmost: { log.frontmostReads > 1 ? NSRunningApplication.current.processIdentifier : 1 },
            pause: { self.write("The person's own copy", to: board) })
        let outcome = await PasteBack.run("Improved text", into: .current, clipboard: service(board), validate: {}, environment: environment)
        // ⌘V would paste their copy, so the result isn't said to be on the clipboard.
        guard case .notPasted = outcome else {
            Issue.record("Expected not pasted, got \(outcome)")
            return
        }
        #expect(log.posted.isEmpty)
        #expect(board.string(forType: .string) == "The person's own copy")
    }

    @Test func aCopyMadeBeforeTheRestoreIsThePersonsStaysAndGoesToHistory() async {
        let store = LibraryStore(fileURL: nil)
        #expect(store.update { $0.preferences.clipboardEnabled = true })
        let board = pasteboard(with: mixedContents)
        let service = service(board, store: store)
        let log = PasteLog()
        var environment = pasteEnvironment(log, board: board)
        environment.sleep = { _ in self.write("Copied meanwhile", to: board) }
        let outcome = await PasteBack.run("Improved text", into: .current, clipboard: service, validate: {}, environment: environment)
        #expect(outcome == .pasted(restored: true))
        #expect(board.string(forType: .string) == "Copied meanwhile")
        await service.poll()
        #expect(store.database.clipboard.contains { $0.plainText == "Copied meanwhile" })
    }

    @Test func anUnattendedPasteNeverTakesFocusOrTheClipboard() async {
        let board = pasteboard(with: mixedContents)
        let generation = board.changeCount
        let log = PasteLog()
        let outcome = await PasteBack.run(
            "Improved text", into: .current, clipboard: service(board), validate: {}, activates: false,
            environment: pasteEnvironment(log, board: board, frontmost: { 1 }))
        guard case .notPasted = outcome else {
            Issue.record("Expected not pasted, got \(outcome)")
            return
        }
        #expect(log.activated.isEmpty)
        #expect(log.posted.isEmpty)
        #expect(board.changeCount == generation)
    }

    @Test func theLenientCheckRefusesOnlyAnotherFocusedField() throws {
        try SelectedTextContext.verifyFocus(true, sourceName: "Notes")
        // Focus that can't be read doesn't stop an explicit ↵.
        try SelectedTextContext.verifyFocus(nil, sourceName: "Notes")
        #expect(throws: LibraryValidationError.self) { try SelectedTextContext.verifyFocus(false, sourceName: "Notes") }
    }

    @Test func formattedPasteTurnsMarkdownIntoRichTextAndLeavesPlainTextAlone() throws {
        #expect(AIFormattedText.attributedString(fromMarkdown: "Just a sentence.") == nil)
        #expect(AIFormattedText.richText(fromMarkdown: "Just a sentence.") == nil)
        let attributed = try #require(AIFormattedText.attributedString(fromMarkdown: "## Plan\n- **Bold** step\n- `code`"))
        #expect(attributed.string == "Plan\n• Bold step\n• code")
        let bold = attributed.attribute(.font, at: (attributed.string as NSString).range(of: "Bold").location, effectiveRange: nil)
        #expect((bold as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let rich = try #require(AIFormattedText.richText(fromMarkdown: "Some **bold** words"))
        #expect(rich.rtf != nil)
        #expect(rich.html.map { String(decoding: $0, as: UTF8.self).contains("bold") } == true)
    }
}
