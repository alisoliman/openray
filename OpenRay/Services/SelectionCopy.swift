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
    /// A copy the capture poll hadn't classified yet. It's put back unclassified, so the poll still
    /// takes it to History, or keeps it out, as it would have.
    var wasPending = false

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
/// A clipboard change counts as that answer only while it can be told apart from anyone else's
/// copy: within the timeout, before the panel closes and before the person types, clicks or copies
/// in OpenRay. OpenRay can't see input made in other apps, as on a windowless hotkey run, so the
/// app in front must also be the one that was when ⌘C went, and no key or click may have reached
/// the Mac since (re-review #1). A change that can't be attributed is never read, nothing is put
/// back over it, and the person is asked for the text instead. The answer is put back right after
/// it's read. The source app writes it, so it carries no privacy markers, and clipboard managers
/// that poll quickly may still see it, as with Raycast.
@MainActor
enum SelectionCopy {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// The bundle id of the app that wrote a copy, where the app follows nspasteboard.org's convention.
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    /// What the fallback does on the Mac. The live one is guarded; tests pass a fake key poster
    /// that writes to a private pasteboard, and their own clock and input record.
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
        /// How long after the timeout a late answer is still taken as the app's and put back. After
        /// a capture that ended unsure, how long whatever lands is kept out of History.
        var lateAnswerWindow: Duration = .milliseconds(300)
        var pollInterval: Duration = .milliseconds(15)
        var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        /// Whether the launcher is still waiting: false once the panel closed or the person typed,
        /// clicked or copied. The launcher sets it; then no change counts as the app's answer.
        var isUndisturbed: @MainActor () -> Bool = { true }
        /// The app in front. Once another one comes forward, a change may be its copy.
        var frontmostProcess: @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        /// When a key or click last reached the Mac from a keyboard, mouse or trackpad, on the
        /// uptime clock. OpenRay's own ⌘C, posted to one app, isn't counted.
        var lastInputAt: @MainActor () -> TimeInterval = { HardwareInput.lastKeyOrClick() }
        var now: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        /// Called with the answer, right before the clipboard is put back. Tests read it.
        var willRestore: @MainActor (NSPasteboard) -> Void = { _ in }
        /// Puts the snapshot back over a generation; see `PasteboardSnapshot.restore(to:over:)`,
        /// which keeps the process's own guard. Tests pass one that fails.
        var restore: @MainActor (PasteboardSnapshot, NSPasteboard, Int) throws -> Int? = {
            try $0.restore(to: $1, over: $2)
        }
        /// Called once the fallback is over, late-answer window included.
        var didFinish: @MainActor () -> Void = {}
        /// Called with why, when a late answer couldn't be put back. The launcher says so.
        var didFailToRestore: @MainActor (String) -> Void = { _ in }

        static var live: Environment { Environment() }
    }

    /// What tells the source app's answer apart from anyone else's copy: the app in front when ⌘C
    /// went, when it went, and the source app.
    struct Attribution: Equatable {
        var front: pid_t?
        var postedAt: TimeInterval
        var bundleIdentifier: String?

        /// Whether a change seen now can still be the source app's: no key or click anywhere since
        /// ⌘C went, and the same app in front, or OpenRay, whose panel may still be coming forward.
        @MainActor func holds(_ environment: Environment) -> Bool {
            let current = environment.frontmostProcess()
            guard current == front || current == ProcessInfo.processInfo.processIdentifier else { return false }
            return environment.lastInputAt() <= postedAt
        }

        /// Whether the copy on the board says another app wrote it.
        @MainActor func isClaimedElsewhere(on pasteboard: NSPasteboard) -> Bool {
            guard let writer = pasteboard.string(forType: SelectionCopy.sourceType), !writer.isEmpty else { return false }
            return writer != bundleIdentifier
        }
    }

    enum Outcome: Equatable {
        /// The app answered: its text, and the generation the snapshot was put back as (nil when
        /// a newer copy was already there and stayed).
        case answered(text: String?, restored: Int?)
        /// No answer within the timeout; the late-answer watch goes on with the attribution.
        case unanswered(Attribution)
    }

    /// How the watch after a capture ended.
    enum LateAnswer: Equatable {
        /// Nothing new landed.
        case none
        /// The app's late answer was put back over, as this generation.
        case restored(Int)
        /// Something landed that can't be told apart from someone's own copy: it stays, as this
        /// generation, and History leaves it out.
        case ambiguous(Int)
        /// The app's late answer couldn't be put back.
        case notRestored
    }

    /// Sends ⌘C and waits for the app's answer. `snapshot` must be the board as it is now. Throws
    /// `CancellationError` when the wait is disturbed or cancelled, and `copyUnattributable` when a
    /// change could be someone else's: nothing is read then, and nothing is put back.
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
        let attribution = Attribution(
            front: environment.frontmostProcess(), postedAt: environment.now(),
            bundleIdentifier: application.bundleIdentifier)
        try environment.postCopy(application.processIdentifier)
        guard
            let answer = try await waitForAnswer(
                after: snapshot.changeCount, within: environment.timeout, attribution, sourceName, pasteboard, environment)
        else { return .unanswered(attribution) }
        let text = pasteboard.string(forType: .string)
        // Read within the answer's own generation: anything written after it is someone else's.
        guard pasteboard.changeCount == answer else { throw SelectionReadError.copyInterrupted(app: sourceName) }
        guard !attribution.isClaimedElsewhere(on: pasteboard) else {
            throw SelectionReadError.copyUnattributable(app: sourceName)
        }
        environment.willRestore(pasteboard)
        // The process's own rule first, whatever restore was injected.
        try SideEffectGuard.checkWrite(to: pasteboard)
        return .answered(text: text, restored: try environment.restore(snapshot, pasteboard, answer))
    }

    /// Watches `lateAnswerWindow` more after a capture that got no certain answer. With an
    /// `attribution` (a timeout), a late answer that can still be attributed to the app is put
    /// back over. Once the launcher is disturbed, a change can't be attributed, or without one (a
    /// capture that ended unsure), nothing is put back: the watch waits out the window, and
    /// whatever landed by then is reported ambiguous. A later copy is never undone.
    static func watchLate(
        over snapshot: PasteboardSnapshot, attribution: Attribution?, on pasteboard: NSPasteboard,
        environment: Environment
    ) async -> LateAnswer {
        var attributable = attribution != nil
        let attempts = max(1, Int((environment.lateAnswerWindow / environment.pollInterval).rounded(.up)))
        for _ in 0..<attempts {
            do { try await environment.sleep(environment.pollInterval) } catch { break }
            if Task.isCancelled || !environment.isUndisturbed() || attribution?.holds(environment) != true {
                attributable = false
            }
            let generation = pasteboard.changeCount
            guard attributable, let attribution, generation != snapshot.changeCount else { continue }
            guard !attribution.isClaimedElsewhere(on: pasteboard) else {
                attributable = false
                continue
            }
            do {
                try SideEffectGuard.checkWrite(to: pasteboard)
                guard let restored = try environment.restore(snapshot, pasteboard, generation) else {
                    attributable = false
                    continue
                }
                return .restored(restored)
            } catch {
                return .notRestored
            }
        }
        let generation = pasteboard.changeCount
        return generation == snapshot.changeCount ? .none : .ambiguous(generation)
    }

    /// The first new generation while the launcher waits undisturbed and the change can still be
    /// the app's, or nil after `window`.
    private static func waitForAnswer(
        after generation: Int, within window: Duration, _ attribution: Attribution, _ sourceName: String,
        _ pasteboard: NSPasteboard, _ environment: Environment
    ) async throws -> Int? {
        let attempts = max(1, Int((window / environment.pollInterval).rounded(.up)))
        for _ in 0..<attempts {
            try await environment.sleep(environment.pollInterval)
            try Task.checkCancellation()
            guard environment.isUndisturbed() else { throw CancellationError() }
            // Another app in front, or a key or click anywhere: a change now could be anyone's.
            guard attribution.holds(environment) else { throw SelectionReadError.copyUnattributable(app: sourceName) }
            if pasteboard.changeCount != generation { return pasteboard.changeCount }
        }
        return nil
    }
}

/// When the person last pressed a key or clicked, from the HID system's own record, so only real
/// input counts: events OpenRay posts to one app aren't in it. Reading it changes nothing.
enum HardwareInput {
    static func lastKeyOrClick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let since = types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        return now - since
    }
}
