import AppKit
import Testing

@testable import OpenRay

/// The writing rebuild's clipboard work (work items 2 and 6): the ⌘C selection fallback and the
/// paste back, both on private pasteboards with fake key posters, so nothing reaches another app
/// or the person's clipboard.
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

    /// What the fakes saw.
    @MainActor
    private final class Recorder {
        var posted: [pid_t] = []
        var markedTypes: Set<String> = []
        var polls = 0
        var closed = false
    }

    /// A copy environment that never touches the Mac: `copy` stands in for the app's ⌘C.
    private func environment(
        timeout: Duration = .milliseconds(60), copy: @escaping @MainActor (pid_t) -> Void = { _ in },
        sleeps: SleepLog = SleepLog()
    ) -> SelectionCopy.Environment {
        var environment = SelectionCopy.Environment()
        environment.checkAllowed = {}
        environment.isTrusted = { true }
        environment.secureInput = { false }
        environment.postCopy = { copy($0) }
        environment.timeout = timeout
        environment.pollInterval = .milliseconds(20)
        environment.sleep = { sleeps.record($0) }
        return environment
    }

    // MARK: Selection fallback

    @Test func theCopyFallbackReadsTheAppsCopyMarksItAndRestoresEveryItemAndType() async throws {
        let board = pasteboard(with: mixedContents)
        let before = PasteboardSnapshot.capture(board)
        let seen = Recorder()
        var environment = environment(copy: { pid in
            seen.posted.append(pid)
            board.clearContents()
            board.setString("Selected words", forType: .string)
        })
        environment.willRestore = { seen.markedTypes = Set(($0.types ?? []).map(\.rawValue)) }
        let app = otherApp
        let text = try await SelectionCopy.read(from: app, sourceName: "Editor", pasteboard: board, environment: environment)
        #expect(text == "Selected words")
        #expect(seen.posted == [app.processIdentifier])
        // The copy was marked before anything else could keep it.
        #expect(seen.markedTypes.isSuperset(of: ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"]))
        // Every item and type is back, in order.
        #expect(PasteboardSnapshot.capture(board).items == before.items)
        #expect(board.pasteboardItems?.count == 2)
        #expect(board.pasteboardItems?.first?.data(forType: .rtf) == Data("{\\rtf1 Earlier copy}".utf8))
    }

    @Test func nothingSelectedLeavesTheClipboardAloneAndSaysWhere() async {
        let board = pasteboard(with: mixedContents)
        let generation = board.changeCount
        let sleeps = SleepLog()
        await #expect(throws: SelectionReadError.nothingSelected(app: "Editor")) {
            try await SelectionCopy.read(
                from: otherApp, sourceName: "Editor", pasteboard: board, environment: environment(sleeps: sleeps))
        }
        // Waited the whole timeout (60 ms in 20 ms polls), then left the clipboard as it was.
        #expect(sleeps.durations == [.milliseconds(20), .milliseconds(20), .milliseconds(20)])
        #expect(board.changeCount == generation)
        #expect(board.pasteboardItems?.first?.string(forType: .string) == "Earlier copy")
        #expect(SelectionReadError.nothingSelected(app: "Editor").errorDescription == "Nothing selected in Editor.")
    }

    @Test func aCopyThatLandsJustBeforeTheTimeoutIsReadAndPutBack() async throws {
        let board = pasteboard(with: mixedContents)
        let before = PasteboardSnapshot.capture(board)
        var environment = environment()
        let seen = Recorder()
        environment.sleep = { _ in
            seen.polls += 1
            // The app answers on the last poll.
            if seen.polls == 3 {
                board.clearContents()
                board.setString("Late words", forType: .string)
            }
        }
        let text = try await SelectionCopy.read(from: otherApp, sourceName: "Editor", pasteboard: board, environment: environment)
        #expect(text == "Late words")
        #expect(PasteboardSnapshot.capture(board).items == before.items)
    }

    @Test func aCopyWithoutTextIsNothingSelectedAndStillPutBack() async {
        let board = pasteboard(with: mixedContents)
        let before = PasteboardSnapshot.capture(board)
        let environment = environment(copy: { _ in
            board.clearContents()
            board.setData(Data([9]), forType: .png)
        })
        await #expect(throws: SelectionReadError.nothingSelected(app: "Finder")) {
            try await SelectionCopy.read(from: self.otherApp, sourceName: "Finder", pasteboard: board, environment: environment)
        }
        #expect(PasteboardSnapshot.capture(board).items == before.items)
    }

    @Test func secureInputMissingAccessibilityAndAnInertLaunchSendNoKey() async {
        let board = pasteboard(with: mixedContents)
        let seen = Recorder()
        var environment = environment(copy: { seen.posted.append($0) })
        environment.secureInput = { true }
        await #expect(throws: SelectionReadError.secureInput) {
            try await SelectionCopy.read(from: self.otherApp, sourceName: "Editor", pasteboard: board, environment: environment)
        }
        environment.secureInput = { false }
        environment.isTrusted = { false }
        await #expect(throws: SelectionReadError.accessibilityOff) {
            try await SelectionCopy.read(from: self.otherApp, sourceName: "Editor", pasteboard: board, environment: environment)
        }
        // The default guard in the test host refuses before any key.
        environment.isTrusted = { true }
        environment.checkAllowed = SelectionCopy.Environment().checkAllowed
        await #expect(throws: SideEffectGuard.Blocked.self) {
            try await SelectionCopy.read(from: self.otherApp, sourceName: "Editor", pasteboard: board, environment: environment)
        }
        // OpenRay never copies from itself.
        environment.checkAllowed = {}
        await #expect(throws: SelectionReadError.noSourceApp) {
            try await SelectionCopy.read(from: .current, sourceName: "OpenRay", pasteboard: board, environment: environment)
        }
        #expect(seen.posted.isEmpty)
    }

    @Test func theSecureInputMessageNeverAsksForAccessibility() {
        let message = SelectionReadError.secureInput.errorDescription ?? ""
        #expect(message.contains("Secure Input"))
        #expect(!message.contains("Accessibility"))
        #expect(SelectionReadError.secureInput.allowsCopyFallback == false)
        #expect(SelectionReadError.notExposed(app: "Slack").allowsCopyFallback)
        #expect(SelectionReadError.nothingSelected(app: "Slack").allowsCopyFallback)
    }

    @Test func theClipboardServiceKeepsTheBorrowedCopyAndTheRestoreOutOfHistory() async throws {
        let store = LibraryStore(fileURL: nil)
        #expect(store.update { $0.preferences.clipboardEnabled = true })
        let board = pasteboard(with: [[(NSPasteboard.PasteboardType.string.rawValue, Data("Earlier copy".utf8))]])
        let service = ClipboardService(
            store: store, pasteboard: board,
            captureContext: { ClipboardCaptureContext(sourceName: "Editor", sourceBundleID: "com.example.editor", secureInput: false) },
            textRecognizer: nil)
        await service.poll()
        let entries = store.database.clipboard.count
        let environment = environment(copy: { _ in
            board.clearContents()
            board.setString("Selected words", forType: .string)
        })
        let text = try await service.readSelectionByCopying(from: otherApp, sourceName: "Editor", environment: environment)
        #expect(text == "Selected words")
        await service.poll()
        #expect(store.database.clipboard.count == entries)
        #expect(!store.database.clipboard.contains { $0.plainText == "Selected words" })
    }

    // MARK: Paste back

    @MainActor
    private final class PasteLog {
        var posted: [pid_t] = []
        var activated: [pid_t] = []
        /// What the clipboard held when ⌘V went: its text and types.
        var pastedText: String?
        var pastedTypes: Set<String> = []
        var sleeps: [Duration] = []
    }

    private func pasteEnvironment(
        _ log: PasteLog, board: NSPasteboard, frontmost: @escaping @MainActor () -> pid_t? = {
            NSRunningApplication.current.processIdentifier
        }, secureInput: Bool = false
    ) -> PasteBack.Environment {
        var paste = SyntheticInput.PasteEnvironment()
        paste.checkAllowed = {}
        paste.isTrusted = { true }
        paste.activate = { log.activated.append($0.processIdentifier) }
        paste.frontmostProcess = frontmost
        paste.secureInput = { secureInput }
        paste.pause = {}
        paste.postPaste = { pid in
            log.posted.append(pid)
            log.pastedText = board.string(forType: .string)
            log.pastedTypes = Set((board.types ?? []).map(\.rawValue))
        }
        var environment = PasteBack.Environment()
        environment.paste = paste
        environment.restoreDelay = .milliseconds(400)
        environment.sleep = { log.sleeps.append($0) }
        return environment
    }

    @Test func pastingBackMarksTheResultTransientThenRestoresTheClipboard() async {
        let board = pasteboard(with: mixedContents)
        let before = PasteboardSnapshot.capture(board)
        let service = ClipboardService(store: LibraryStore(fileURL: nil), pasteboard: board, textRecognizer: nil)
        let log = PasteLog()
        let me = NSRunningApplication.current
        let seen = Recorder()
        let outcome = await PasteBack.run(
            "Improved text", into: me, clipboard: service, validate: {},
            environment: pasteEnvironment(log, board: board), willPaste: { seen.closed = true })
        #expect(outcome == .pasted)
        #expect(seen.closed)
        #expect(log.activated == [me.processIdentifier])
        #expect(log.posted == [me.processIdentifier])
        #expect(log.pastedText == "Improved text")
        #expect(log.pastedTypes.contains("org.nspasteboard.TransientType"))
        // The paste had its moment, then the person's clipboard came back whole.
        #expect(log.sleeps == [.milliseconds(400)])
        #expect(PasteboardSnapshot.capture(board).items == before.items)
    }

    @Test func aFailedPasteLeavesTheResultCopiedAndNothingRestored() async {
        let board = pasteboard(with: mixedContents)
        let service = ClipboardService(store: LibraryStore(fileURL: nil), pasteboard: board, textRecognizer: nil)
        let log = PasteLog()
        // Another app came to the front.
        let outcome = await PasteBack.run(
            "Improved text", into: .current, clipboard: service, validate: {},
            environment: pasteEnvironment(log, board: board, frontmost: { 1 }))
        guard case .copied = outcome else {
            Issue.record("Expected the result to be copied, got \(outcome)")
            return
        }
        #expect(log.posted.isEmpty)
        #expect(log.sleeps.isEmpty)
        #expect(board.string(forType: .string) == "Improved text")
    }

    @Test func secureInputRefusesThePasteAndSaysSo() async {
        let board = pasteboard(with: mixedContents)
        let service = ClipboardService(store: LibraryStore(fileURL: nil), pasteboard: board, textRecognizer: nil)
        let log = PasteLog()
        let outcome = await PasteBack.run(
            "Improved text", into: .current, clipboard: service, validate: {},
            environment: pasteEnvironment(log, board: board, secureInput: true))
        #expect(outcome == .copied("Secure Input is on, so nothing was pasted. Your text is copied; paste it with ⌘V."))
        #expect(log.posted.isEmpty)
    }

    @Test func aCopyMadeBeforeTheRestoreIsThePersonsAndStays() async {
        let board = pasteboard(with: mixedContents)
        let service = ClipboardService(store: LibraryStore(fileURL: nil), pasteboard: board, textRecognizer: nil)
        let log = PasteLog()
        var environment = pasteEnvironment(log, board: board)
        environment.sleep = { _ in
            board.clearContents()
            board.setString("Copied meanwhile", forType: .string)
        }
        let outcome = await PasteBack.run("Improved text", into: .current, clipboard: service, validate: {}, environment: environment)
        #expect(outcome == .pasted)
        #expect(board.string(forType: .string) == "Copied meanwhile")
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
