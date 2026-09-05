import AppKit
import Carbon

/// Only the last keyword-sized suffix is held in memory; typed text is never persisted.
struct SnippetMatcher {
    private(set) var buffer = ""

    mutating func reset() { buffer = "" }

    mutating func consume(_ text: String, snippets: [Snippet]) -> Snippet? {
        if text == "\u{7f}" || text == "\u{8}" {
            if !buffer.isEmpty { buffer.removeLast() }
            return nil
        }
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            reset()
            return nil
        }
        buffer += text
        buffer = String(buffer.suffix(64))
        for snippet in snippets.sorted(by: { $0.keyword.count > $1.keyword.count }) where !snippet.keyword.isEmpty {
            guard buffer.hasSuffix(snippet.keyword) else { continue }
            let prefix = buffer.dropLast(snippet.keyword.count)
            guard prefix.isEmpty || prefix.last?.isWhitespace == true else { continue }
            reset()
            return snippet
        }
        return nil
    }
}

@MainActor
final class SnippetExpander {
    private let store: LibraryStore
    private var monitor: Any?
    private var mouseMonitor: Any?
    private var matcher = SnippetMatcher()
    private var previousPID: pid_t?

    init(store: LibraryStore) { self.store = store }

    func configure() {
        stop()
        guard store.database.preferences.snippetExpansionEnabled, AXIsProcessTrusted() else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.consume(event) }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.matcher.reset() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        monitor = nil
        mouseMonitor = nil
        matcher.reset()
    }

    private func consume(_ event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != SyntheticInput.marker else { return }
        guard store.database.preferences.snippetExpansionEnabled, !IsSecureEventInputEnabled(),
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let text = event.characters,
            let app = NSWorkspace.shared.frontmostApplication
        else {
            matcher.reset()
            return
        }
        if previousPID != app.processIdentifier {
            matcher.reset()
            previousPID = app.processIdentifier
        }
        guard
            ClipboardPolicy.shouldCapture(
                types: [], sourceBundleID: app.bundleIdentifier,
                excluded: store.database.preferences.excludedClipboardBundleIDs,
                secureInput: false)
        else {
            matcher.reset()
            return
        }
        if let snippet = matcher.consume(text, snippets: store.database.snippets) {
            do {
                try SyntheticInput.replace(
                    keyword: snippet.keyword, with: snippet.expanded(), in: app.processIdentifier)
            } catch {
                // A failed global expansion must not interrupt the user's active application.
                NSSound.beep()
            }
        }
    }
}
