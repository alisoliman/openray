import AppKit
import Carbon

/// Every item and type on a pasteboard, in order, so the person's clipboard can be put back
/// exactly after OpenRay borrows it (work items 2 and 6).
struct PasteboardSnapshot: Equatable, Sendable {
    struct Representation: Equatable, Sendable {
        var type: String
        var data: Data
    }

    var items: [[Representation]]
    /// The pasteboard generation it was read from.
    var changeCount: Int
    /// What the clipboard service knew about that generation: a copy from an app the person
    /// excluded, and one whose source it had classified. Carried to the generation it's put back as.
    var wasExcluded = false
    var wasAttributed = false

    /// The whole board, or an error when any item or type can't be read, or the board changes
    /// while it's read: an incomplete copy can't be put back, so nothing may be borrowed then.
    @MainActor static func capture(_ pasteboard: NSPasteboard) throws -> PasteboardSnapshot {
        let changeCount = pasteboard.changeCount
        guard let pasteboardItems = pasteboard.pasteboardItems else { throw PasteboardBorrowError.unreadable }
        var items: [[Representation]] = []
        for item in pasteboardItems {
            var representations: [Representation] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { throw PasteboardBorrowError.unreadable }
                representations.append(Representation(type: type.rawValue, data: data))
            }
            items.append(representations)
        }
        guard pasteboard.changeCount == changeCount else { throw PasteboardBorrowError.unreadable }
        return PasteboardSnapshot(items: items, changeCount: changeCount)
    }

    /// Writes the items back over `generation`, and only over it: a generation OpenRay wrote, or
    /// the source app's answer to its ⌘C. Anything newer is someone else's copy and stays.
    /// Returns the generation put back, or nil when a newer copy stayed. The process's own rule
    /// guards the write, so no injected configuration can let it touch the general pasteboard
    /// while inert.
    @MainActor func restore(to pasteboard: NSPasteboard, over generation: Int) throws -> Int? {
        try SideEffectGuard.checkWrite(to: pasteboard)
        guard pasteboard.changeCount == generation else { return nil }
        let restored = pasteboard.clearContents()
        let objects = items.map { representations in
            let item = NSPasteboardItem()
            for representation in representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        }
        if !objects.isEmpty, !pasteboard.writeObjects(objects) { throw PasteboardBorrowError.notRestored }
        return restored
    }
}

/// Why borrowing the clipboard stopped.
enum PasteboardBorrowError: LocalizedError, Equatable {
    /// The clipboard couldn't be read whole, so it couldn't be put back.
    case unreadable
    /// The clipboard couldn't be written back.
    case notRestored

    var errorDescription: String? {
        switch self {
        case .unreadable: "OpenRay couldn't keep a full copy of your clipboard, so it left it alone."
        case .notRestored: "OpenRay couldn't put your clipboard back."
        }
    }
}

/// The selection fallback for apps whose selection Accessibility can't see (work item 2): ⌘C goes
/// to the source app alone, and only its answer is read and put back.
///
/// A clipboard change counts as that answer only while the launcher is still waiting for it:
/// within the timeout, before the panel closes and before the person types, clicks or copies.
/// Anything else is someone's own copy; it's never read, and nothing is put back over it. The
/// answer is put back right after it's read. The source app writes it, so it carries no privacy
/// markers, and clipboard managers that poll quickly may still see it, as with Raycast.
@MainActor
enum SelectionCopy {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// What the fallback does on the Mac. The live one is guarded; tests pass a fake key poster
    /// that writes to a private pasteboard, and their own clock.
    struct Environment {
        var checkAllowed: @MainActor () throws -> Void = {
            try SideEffectGuard.check("copying the selection in another app")
        }
        var isTrusted: @MainActor () -> Bool = { AXIsProcessTrusted() }
        var secureInput: @MainActor () -> Bool = { IsSecureEventInputEnabled() }
        /// Delivers ⌘C to the app's process without activating it.
        var postCopy: @MainActor (pid_t) throws -> Void = { try SyntheticInput.postCopy(toProcess: $0) }
        /// How long the app has to answer the copy.
        var timeout: Duration = .milliseconds(300)
        /// How long after the timeout a late answer is still taken as the app's and put back.
        var lateAnswerWindow: Duration = .milliseconds(300)
        var pollInterval: Duration = .milliseconds(15)
        var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        /// Whether the launcher is still waiting: false once the panel closed or the person typed,
        /// clicked or copied. The launcher sets it; then no change counts as the app's answer.
        var isUndisturbed: @MainActor () -> Bool = { true }
        /// Called with the answer, right before the clipboard is put back. Tests read it.
        var willRestore: @MainActor (NSPasteboard) -> Void = { _ in }
        /// Called once the fallback is over, late-answer window included.
        var didFinish: @MainActor () -> Void = {}

        static var live: Environment { Environment() }
    }

    enum Outcome: Equatable {
        /// The app answered: its text, and the generation the snapshot was put back as (nil when
        /// a newer copy was already there and stayed).
        case answered(text: String?, restored: Int?)
        /// No answer within the timeout.
        case unanswered
    }

    /// Sends ⌘C and waits for the app's answer. `snapshot` must be the board as it is now. Throws
    /// `CancellationError` when the wait is disturbed or cancelled: nothing is read then, and
    /// nothing is put back.
    static func read(
        from application: NSRunningApplication?, sourceName: String, pasteboard: NSPasteboard,
        snapshot: PasteboardSnapshot, environment: Environment = .live
    ) async throws -> Outcome {
        try environment.checkAllowed()
        guard environment.isTrusted() else { throw SelectionReadError.accessibilityOff }
        guard !environment.secureInput() else { throw SelectionReadError.secureInput }
        guard let application, !application.isTerminated,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { throw SelectionReadError.noSourceApp }
        // The clipboard was just taken; the person may have moved on while it was.
        try Task.checkCancellation()
        guard environment.isUndisturbed() else { throw CancellationError() }
        guard pasteboard.changeCount == snapshot.changeCount else { throw PasteboardBorrowError.unreadable }
        try environment.postCopy(application.processIdentifier)
        guard let answer = try await waitForAnswer(after: snapshot.changeCount, within: environment.timeout, pasteboard, environment)
        else { return .unanswered }
        let text = pasteboard.string(forType: .string)
        // Read within the answer's own generation: anything written after it is someone else's.
        guard pasteboard.changeCount == answer else { throw SelectionReadError.copyInterrupted(app: sourceName) }
        environment.willRestore(pasteboard)
        return .answered(text: text, restored: try snapshot.restore(to: pasteboard, over: answer))
    }

    /// After a timeout, waits `lateAnswerWindow` more for a late answer and puts the clipboard back
    /// over it, as long as the launcher is still undisturbed. Returns the generation put back.
    static func putBackLateAnswer(
        over snapshot: PasteboardSnapshot, on pasteboard: NSPasteboard, environment: Environment
    ) async -> Int? {
        guard
            let answer = try? await waitForAnswer(
                after: snapshot.changeCount, within: environment.lateAnswerWindow, pasteboard, environment)
        else { return nil }
        return try? snapshot.restore(to: pasteboard, over: answer)
    }

    /// The first new generation while the launcher waits undisturbed, or nil after `window`.
    private static func waitForAnswer(
        after generation: Int, within window: Duration, _ pasteboard: NSPasteboard, _ environment: Environment
    ) async throws -> Int? {
        let attempts = max(1, Int((window / environment.pollInterval).rounded(.up)))
        for _ in 0..<attempts {
            try await environment.sleep(environment.pollInterval)
            try Task.checkCancellation()
            guard environment.isUndisturbed() else { throw CancellationError() }
            if pasteboard.changeCount != generation { return pasteboard.changeCount }
        }
        return nil
    }
}
