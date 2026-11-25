import AppKit
import Carbon

// MARK: - Settings

/// When a typed keyword expands.
enum SnippetExpansionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// As soon as the last character of the keyword is typed.
    case immediately
    /// After the next delimiter (space, punctuation, Return…), which stays in the text.
    case afterDelimiterKeeping
    /// After the next delimiter, which is removed.
    case afterDelimiterDiscarding

    var id: String { rawValue }

    var title: String {
        switch self {
        case .immediately: "Immediately"
        case .afterDelimiterKeeping: "After Delimiter (keep it)"
        case .afterDelimiterDiscarding: "After Delimiter (remove it)"
        }
    }

    var waitsForDelimiter: Bool { self != .immediately }
}

/// Keyword expansion options. These apply to every snippet. Until the library
/// stores them, the defaults match OpenRay's original behavior.
struct SnippetExpansionSettings: Codable, Equatable, Sendable {
    var mode: SnippetExpansionMode = .immediately
    /// Expand a keyword even when it's typed at the end of a longer word.
    var expandsWithinWords = false

    init(mode: SnippetExpansionMode = .immediately, expandsWithinWords: Bool = false) {
        self.mode = mode
        self.expandsWithinWords = expandsWithinWords
    }
}

/// Which characters separate words for keyword matching.
enum SnippetKeywordRules {
    /// Characters that end a word: whitespace, quotes, backticks and brackets.
    /// A keyword can't contain them.
    static let wordBoundaries: Set<Character> = [
        "`", "\"", "'", "“", "”", "‘", "’", "„", "«", "»", "(", ")", "[", "]", "{", "}",
    ]
    /// Punctuation that also triggers expansion in the delimiter modes. Keywords
    /// may contain it, e.g. `;addr` or `!email`.
    static let delimiterPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":"]
    static let maximumLength = 32

    static func isWordBoundary(_ character: Character) -> Bool {
        character.isWhitespace || wordBoundaries.contains(character)
    }

    static func isDelimiter(_ character: Character) -> Bool {
        isWordBoundary(character) || delimiterPunctuation.contains(character)
    }

    /// A keyword of 1–32 characters without whitespace, quotes, backticks,
    /// brackets or control characters. Letters, digits and other punctuation,
    /// math and currency symbols are fine, so imported keywords such as `@@` work.
    static func isValid(_ keyword: String) -> Bool {
        (1...maximumLength).contains(keyword.count)
            && keyword.allSatisfy { character in
                !isWordBoundary(character)
                    && !character.unicodeScalars.contains {
                        CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value)
                    }
            }
    }
}

// MARK: - Matching

/// A keyword the person just finished typing.
struct SnippetTrigger: Equatable, Sendable {
    var snippet: Snippet
    /// The delimiter typed after the keyword, in the delimiter modes.
    var delimiter: Character?
}

/// Exactly what to do in the target app: delete, type, then move the caret.
struct SnippetExpansionPlan: Equatable, Sendable {
    /// Backspaces to remove the keyword and, in the delimiter modes, the delimiter.
    var deleteCount: Int
    var text: String
    /// ← presses after typing, to put the caret where `{cursor}` was.
    var caretLeft: Int

    init(deleteCount: Int, text: String, caretLeft: Int) {
        self.deleteCount = deleteCount
        self.text = text
        self.caretLeft = caretLeft
    }

    init(trigger: SnippetTrigger, rendering: PlaceholderRendering, mode: SnippetExpansionMode) {
        var deleteCount = trigger.snippet.keyword.count
        var text = rendering.text
        var caretLeft = rendering.charactersAfterCursor ?? 0
        if let delimiter = trigger.delimiter {
            deleteCount += 1
            if mode == .afterDelimiterKeeping {
                text.append(delimiter)
                if rendering.cursorUTF16Offset != nil { caretLeft += 1 }
            }
        }
        self.init(deleteCount: deleteCount, text: text, caretLeft: caretLeft)
    }
}

/// Only the last keyword-sized suffix is held in memory; typed text is never persisted.
struct SnippetMatcher {
    private(set) var buffer = ""
    var settings: SnippetExpansionSettings

    init(settings: SnippetExpansionSettings = .init()) { self.settings = settings }

    mutating func reset() { buffer = "" }

    mutating func consume(_ text: String, snippets: [Snippet]) -> Snippet? {
        trigger(for: text, snippets: snippets)?.snippet
    }

    /// Feeds the characters of one key press. Returns the snippet whose keyword
    /// was just completed, and clears the buffer when it does.
    mutating func trigger(for text: String, snippets: [Snippet]) -> SnippetTrigger? {
        if text == "\u{7f}" || text == "\u{8}" {
            if !buffer.isEmpty { buffer.removeLast() }
            return nil
        }
        // Keypad Enter types U+0003; treat it like Return.
        let text = text == "\u{3}" ? "\r" : text
        let isLineOrTab = text == "\r" || text == "\n" || text == "\t"
        guard !text.isEmpty,
            !text.unicodeScalars.contains(where: {
                // Arrow and function keys arrive as private-use characters.
                (!isLineOrTab && CharacterSet.controlCharacters.contains($0)) || (0xF700...0xF8FF).contains($0.value)
            })
        else {
            reset()
            return nil
        }
        if isLineOrTab && !settings.mode.waitsForDelimiter {
            reset()
            return nil
        }
        buffer += text
        buffer = String(buffer.suffix(64))
        let trigger: SnippetTrigger?
        if settings.mode.waitsForDelimiter {
            guard let last = buffer.last, SnippetKeywordRules.isDelimiter(last) else { return nil }
            trigger = match(in: buffer.dropLast(), snippets: snippets).map { SnippetTrigger(snippet: $0, delimiter: last) }
        } else {
            trigger = match(in: buffer[...], snippets: snippets).map { SnippetTrigger(snippet: $0, delimiter: nil) }
        }
        if trigger != nil { reset() }
        if isLineOrTab && trigger == nil { reset() }
        return trigger
    }

    private func match(in text: Substring, snippets: [Snippet]) -> Snippet? {
        for snippet in snippets.sorted(by: { $0.keyword.count > $1.keyword.count }) where !snippet.keyword.isEmpty {
            guard text.hasSuffix(snippet.keyword) else { continue }
            let prefix = text.dropLast(snippet.keyword.count)
            guard settings.expandsWithinWords || prefix.isEmpty || prefix.last.map(SnippetKeywordRules.isWordBoundary) == true
            else { continue }
            return snippet
        }
        return nil
    }
}

// MARK: - Expansion

/// One key press, reduced to what expansion needs. Built from an `NSEvent` in the
/// app and by hand in tests.
struct SnippetKeyInput: Equatable, Sendable {
    var characters: String?
    /// ⌘, ⌃ or ⌥ was held, so the key is a shortcut rather than typing.
    var hasShortcutModifiers = false
    /// The event came from OpenRay's own synthetic input.
    var isSynthetic = false
    var processID: pid_t
    var bundleIdentifier: String?
}

/// Performs an expansion in another app. The live inserter sends keyboard events,
/// so tests always inject a fake.
@MainActor
protocol SnippetInserting {
    func insert(_ plan: SnippetExpansionPlan, into processID: pid_t) throws
}

/// Types the expansion with synthetic key events. It re-checks Accessibility,
/// Secure Input and the frontmost app before acting.
struct SyntheticSnippetInserter: SnippetInserting {
    func insert(_ plan: SnippetExpansionPlan, into processID: pid_t) throws {
        try SyntheticInput.replace(
            deleting: plan.deleteCount, with: plan.text, caretLeft: plan.caretLeft, in: processID)
    }
}

extension PlaceholderValues {
    /// Values from the library: text clipboard history, newest first, and snippets by name.
    /// `currentClipboard` is used when history capture is off.
    init(library database: LibraryDatabase, currentClipboard: String? = nil, now: Date = .now) {
        var clipboard = database.clipboard.compactMap(\.plainText)
        if let currentClipboard, clipboard.first != currentClipboard { clipboard.insert(currentClipboard, at: 0) }
        self.init(
            now: now, clipboard: clipboard,
            snippets: Dictionary(database.snippets.map { ($0.name, $0.content) }, uniquingKeysWith: { first, _ in first }))
    }
}

@MainActor
final class SnippetExpander {
    private let store: LibraryStore
    private let inserter: any SnippetInserting
    private let isSecureInputEnabled: @MainActor () -> Bool
    private let placeholderValues: @MainActor (LibraryDatabase) -> PlaceholderValues
    private var monitor: Any?
    private var mouseMonitor: Any?
    private var matcher = SnippetMatcher()
    private var previousPID: pid_t?

    /// Expansion options; the library doesn't store them yet, so this defaults to
    /// OpenRay's original behavior.
    var settings = SnippetExpansionSettings() {
        didSet { matcher.reset() }
    }

    init(
        store: LibraryStore, inserter: any SnippetInserting = SyntheticSnippetInserter(),
        isSecureInputEnabled: @escaping @MainActor () -> Bool = { IsSecureEventInputEnabled() },
        placeholderValues: @escaping @MainActor (LibraryDatabase) -> PlaceholderValues = {
            PlaceholderValues(library: $0)
        }
    ) {
        self.store = store
        self.inserter = inserter
        self.isSecureInputEnabled = isSecureInputEnabled
        self.placeholderValues = placeholderValues
    }

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
        guard let app = NSWorkspace.shared.frontmostApplication else {
            matcher.reset()
            return
        }
        handle(
            SnippetKeyInput(
                characters: event.characters,
                hasShortcutModifiers: !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                isSynthetic: event.cgEvent?.getIntegerValueField(.eventSourceUserData) == SyntheticInput.marker,
                processID: app.processIdentifier, bundleIdentifier: app.bundleIdentifier))
    }

    /// Feeds one key press. When it completes a keyword, renders the snippet,
    /// hands the plan to the inserter and returns it.
    @discardableResult
    func handle(_ input: SnippetKeyInput) -> SnippetExpansionPlan? {
        guard !input.isSynthetic else { return nil }
        let preferences = store.database.preferences
        guard preferences.snippetExpansionEnabled, !isSecureInputEnabled(), !input.hasShortcutModifiers,
            let text = input.characters
        else {
            matcher.reset()
            return nil
        }
        if previousPID != input.processID {
            matcher.reset()
            previousPID = input.processID
        }
        guard
            ClipboardPolicy.shouldCapture(
                types: [], sourceBundleID: input.bundleIdentifier,
                excluded: preferences.effectiveClipboardExclusions, secureInput: false)
        else {
            matcher.reset()
            return nil
        }
        matcher.settings = settings
        guard let trigger = matcher.trigger(for: text, snippets: store.database.snippets.filter(\.expandsAsYouType))
        else { return nil }
        // Arguments can't be asked for mid-typing, so they take their defaults.
        let rendering = Placeholders.render(
            trigger.snippet.content, context: .snippet, source: placeholderValues(store.database))
        let plan = SnippetExpansionPlan(trigger: trigger, rendering: rendering, mode: settings.mode)
        do {
            try inserter.insert(plan, into: input.processID)
        } catch {
            // A failed global expansion must not interrupt the user's active application.
            NSSound.beep()
        }
        return plan
    }
}
