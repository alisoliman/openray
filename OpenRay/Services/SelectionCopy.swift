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

    @MainActor static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let changeCount = pasteboard.changeCount
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { Representation(type: type.rawValue, data: $0) } }
        }
        return PasteboardSnapshot(items: items, changeCount: changeCount)
    }

    /// Writes the items back as they were. An empty snapshot leaves the pasteboard empty.
    @MainActor func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let objects = items.map { representations in
            let item = NSPasteboardItem()
            for representation in representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        }
        if !objects.isEmpty { pasteboard.writeObjects(objects) }
    }
}

/// The selection fallback for apps whose selection Accessibility can't see (work item 2): ⌘C goes
/// to the source app alone, the copied text is read, and the clipboard is put back exactly. The
/// copy is marked transient and concealed as soon as it lands, so clipboard managers skip it.
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
        /// How long after an unanswered copy (a timeout, or a cancel) a late copy is still caught
        /// and put back, so it never stays on the person's clipboard.
        var lateCopyGrace: Duration = .milliseconds(1_000)
        var pollInterval: Duration = .milliseconds(15)
        var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        /// Called with the app's copy, marked, right before the clipboard is put back. Tests read it.
        var willRestore: @MainActor (NSPasteboard) -> Void = { _ in }

        static var live: Environment { Environment() }
    }

    /// The text the app copied. Throws `SelectionReadError.nothingSelected` when the copy didn't
    /// change the clipboard in time, or left no text; the clipboard is the person's either way.
    /// An unanswered copy hands its snapshot to `unanswered`, which watches for a late one
    /// (`putBackLateCopy`).
    static func read(
        from application: NSRunningApplication?, sourceName: String, pasteboard: NSPasteboard,
        environment: Environment = .live, unanswered: (PasteboardSnapshot) -> Void = { _ in }
    ) async throws -> String {
        try environment.checkAllowed()
        guard environment.isTrusted() else { throw SelectionReadError.accessibilityOff }
        guard !environment.secureInput() else { throw SelectionReadError.secureInput }
        guard let application, !application.isTerminated,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { throw SelectionReadError.noSourceApp }
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        func changed() -> Bool { pasteboard.changeCount != snapshot.changeCount }
        try environment.postCopy(application.processIdentifier)
        let attempts = max(1, Int((environment.timeout / environment.pollInterval).rounded(.up)))
        var attempt = 0
        var cancelled = false
        while !changed(), attempt < attempts {
            do { try await environment.sleep(environment.pollInterval) } catch {
                cancelled = true
                break
            }
            attempt += 1
        }
        guard changed() else {
            unanswered(snapshot)
            if cancelled { throw CancellationError() }
            throw SelectionReadError.nothingSelected(app: sourceName)
        }
        let text = takeCopy(over: snapshot, from: pasteboard, environment: environment)
        if cancelled { throw CancellationError() }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelectionReadError.nothingSelected(app: sourceName)
        }
        return text
    }

    /// Watches, for `lateCopyGrace`, for a copy that lands after the fallback gave up, and puts the
    /// clipboard back when one does. The first change in that time is taken to be the app's copy:
    /// the launcher is in front, so it's very unlikely to be the person's own.
    static func putBackLateCopy(over snapshot: PasteboardSnapshot, on pasteboard: NSPasteboard, environment: Environment)
        async
    {
        let attempts = max(1, Int((environment.lateCopyGrace / environment.pollInterval).rounded(.up)))
        for _ in 0..<attempts {
            try? await environment.sleep(environment.pollInterval)
            guard pasteboard.changeCount == snapshot.changeCount else {
                _ = takeCopy(over: snapshot, from: pasteboard, environment: environment)
                return
            }
        }
    }

    /// Marks the app's copy transient and concealed, reads its text and puts the snapshot back.
    private static func takeCopy(over snapshot: PasteboardSnapshot, from pasteboard: NSPasteboard, environment: Environment)
        -> String?
    {
        pasteboard.addTypes([transientType, concealedType], owner: nil)
        pasteboard.setData(Data(), forType: transientType)
        pasteboard.setData(Data(), forType: concealedType)
        let text = pasteboard.string(forType: .string)
        environment.willRestore(pasteboard)
        snapshot.restore(to: pasteboard)
        return text
    }
}
