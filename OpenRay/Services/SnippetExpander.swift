import AppKit
import ApplicationServices
import Carbon

// MARK: - Settings

/// When a typed keyword expands.
enum SnippetExpansionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// As soon as the last character of the keyword is typed.
    case immediately
    /// After the next delimiter (space, punctuation, a quote or bracket), which stays in the text.
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

    /// A printable character that completes a keyword in the delimiter modes.
    /// Return, Tab and other control keys never do: the passive monitor can't
    /// stop them, and they can submit a form or move focus before expansion runs.
    static func isDelimiter(_ character: Character) -> Bool {
        !isControl(character) && (isWordBoundary(character) || delimiterPunctuation.contains(character))
    }

    static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value)
        }
    }

    /// A keyword of 1–32 characters made of letters, digits, punctuation, and math,
    /// currency or modifier symbols, so imported keywords such as `@@`, `!email` or
    /// `€x` work. Whitespace, quotes, backticks, brackets, emoji and other symbols
    /// and control characters can't appear.
    static func isValid(_ keyword: String) -> Bool {
        (1...maximumLength).contains(keyword.count)
            && keyword.allSatisfy { character in
                !isWordBoundary(character) && !isControl(character)
                    && character.unicodeScalars.allSatisfy { scalar in
                        switch scalar.properties.generalCategory {
                        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                            .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber,
                            .connectorPunctuation, .dashPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol,
                            .modifierSymbol:
                            true
                        default: false
                        }
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
        // Return, Tab, arrows and function keys end the word and never expand.
        guard !text.isEmpty, !text.contains(where: SnippetKeywordRules.isControl) else {
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
        return trigger
    }

    private func match(in text: Substring, snippets: [Snippet]) -> Snippet? {
        for snippet in snippets.sorted(by: { $0.keyword.count > $1.keyword.count }) where !snippet.keyword.isEmpty {
            guard text.hasSuffix(snippet.keyword) else { continue }
            let prefix = text.dropLast(snippet.keyword.count)
            guard
                settings.expandsWithinWords || prefix.isEmpty
                    || prefix.last.map(SnippetKeywordRules.isWordBoundary) == true
            else { continue }
            return snippet
        }
        return nil
    }
}

// MARK: - Plans

/// Exactly what to do in the target app: delete, type, then place the caret.
struct SnippetExpansionPlan: Equatable, Sendable {
    /// Longer expansions are refused before anything is deleted.
    static let maximumTextUTF16 = 65_536

    /// What was typed and is replaced: the keyword and, in the delimiter modes, the
    /// delimiter. It must sit right before the caret before anything is deleted.
    var deletedText: String
    var text: String
    /// Characters after `{cursor}`.
    var caretLeft: Int
    /// The same in UTF-16 code units, for setting the caret by offset.
    var caretUTF16Left: Int

    /// Backspaces to remove `deletedText`.
    var deleteCount: Int { deletedText.count }
    var deleteUTF16Count: Int { deletedText.utf16.count }

    init(deletedText: String, text: String, caretLeft: Int = 0, caretUTF16Left: Int? = nil) {
        self.deletedText = deletedText
        self.text = text
        self.caretLeft = caretLeft
        self.caretUTF16Left = caretUTF16Left ?? caretLeft
    }

    init(trigger: SnippetTrigger, rendering: PlaceholderRendering, mode: SnippetExpansionMode) {
        var deleted = trigger.snippet.keyword
        var text = rendering.text
        var caretLeft = rendering.charactersAfterCursor ?? 0
        var caretUTF16Left = rendering.utf16AfterCursor ?? 0
        if let delimiter = trigger.delimiter {
            deleted.append(delimiter)
            if mode == .afterDelimiterKeeping {
                text.append(delimiter)
                if rendering.cursorUTF16Offset != nil {
                    caretLeft += 1
                    caretUTF16Left += String(delimiter).utf16.count
                }
            }
        }
        self.init(deletedText: deleted, text: text, caretLeft: caretLeft, caretUTF16Left: caretUTF16Left)
    }

    var exceedsLimit: Bool { text.utf16.count > Self.maximumTextUTF16 }

    /// Right-to-left text in the insertion. The caret is only ever set by text offset.
    var hasRightToLeftText: Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF,
                0x200F, 0x202B, 0x202E, 0x2067:
                true
            default: false
            }
        }
    }
}

// MARK: - Typing

/// The field an expansion types into. The live target posts events to one
/// process and compares its focused element through Accessibility; tests use a
/// recording fake.
@MainActor
protocol KeystrokeTarget {
    /// The same app is frontmost, the same element has focus (when the app reports one)
    /// as when the keyword was completed, and no secure field is active.
    func isUnchanged() -> Bool
    /// What's right before the caret in the focused field, as far as Accessibility can tell.
    func precedingText(utf16Count: Int) -> PrecedingText
    /// A short pause for the app to catch up on keys it was sent: Accessibility can
    /// report a field's text a moment after the key event.
    func settle()
    func pressDelete() throws
    /// Types up to 20 UTF-16 code units.
    func type(_ chunk: [UInt16]) throws
    /// The caret's UTF-16 location in the focused text, or nil when the editor doesn't report it.
    func caretLocation() -> Int?
    /// Waits briefly until the editor reports the caret at `location`, so it has
    /// processed everything typed. False on timeout.
    func waitForCaret(at location: Int) -> Bool
    /// Sets the caret by text offset. False when the editor doesn't allow it.
    func setCaretLocation(_ location: Int) -> Bool
}

/// What Accessibility reports right before the caret.
enum PrecedingText: Equatable, Sendable {
    /// The text before a collapsed caret.
    case text(String)
    /// Something is selected, so typing didn't end at a caret there.
    case selection
    /// The field doesn't report its text: terminals, many Electron apps and others.
    case unreadable
}

/// Runs a plan against a target, re-checking the target before every event and
/// stopping at the first change.
///
/// Before deleting anything it checks it's in the right place:
/// - Where Accessibility reports the text before the caret, that text must end with
///   the typed keyword. A mismatch or a selection refuses, after a few short retries,
///   since apps can update their text a moment after the key event.
/// - Where it doesn't (terminals, VS Code, Slack and other Electron apps), expansion
///   works as it always has: the same frontmost app, the same focused element when it
///   can be read, no Secure Input and no focus change since the keyword was typed.
enum KeystrokeScript {
    /// Reads of the preceding text before a mismatch refuses.
    static let confirmationAttempts = 8
    enum Result: Equatable, Sendable {
        case completed
        /// Focus or the frontmost app changed; nothing more was sent.
        case interrupted
        /// The typed keyword wasn't right before the caret in the focused field, or the
        /// field couldn't be read. Nothing was sent.
        case unconfirmed
    }

    /// True when the keyword is right before the caret, or when the field never reports
    /// its text and the base checks (`isUnchanged`) carry the decision. Once a read has
    /// shown different text or a selection, only the expected text confirms: a later
    /// unreadable answer refuses.
    @MainActor static func confirm(_ plan: SnippetExpansionPlan, on target: some KeystrokeTarget) -> Bool {
        var sawEvidence = false
        for attempt in 0..<confirmationAttempts {
            switch target.precedingText(utf16Count: plan.deleteUTF16Count) {
            case .unreadable:
                if !sawEvidence { return true }
            case .text(let text) where text == plan.deletedText: return true
            case .text, .selection:
                sawEvidence = true
            }
            if attempt < confirmationAttempts - 1 { target.settle() }
        }
        return false
    }

    @MainActor static func run(_ plan: SnippetExpansionPlan, on target: some KeystrokeTarget) throws -> Result {
        guard target.isUnchanged() else { return .interrupted }
        guard confirm(plan, on: target) else { return .unconfirmed }
        guard target.isUnchanged() else { return .interrupted }
        let start = plan.caretLeft > 0 ? target.caretLocation() : nil
        for _ in 0..<plan.deleteCount {
            guard target.isUnchanged() else { return .interrupted }
            try target.pressDelete()
        }
        var chunk: [UInt16] = []
        for scalar in plan.text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 20 {
                guard target.isUnchanged() else { return .interrupted }
                try target.type(chunk)
                chunk = []
            }
            chunk += units
        }
        if !chunk.isEmpty {
            guard target.isUnchanged() else { return .interrupted }
            try target.type(chunk)
        }
        guard plan.caretLeft > 0 else { return .completed }
        guard target.isUnchanged() else { return .interrupted }
        // The caret moves only by text offset, once the editor shows it has the whole
        // insertion. Where that isn't possible it stays at the end: arrow keys move
        // visually, which isn't the logical offset in right-to-left paragraphs.
        if let start {
            let end = start - plan.deleteUTF16Count + plan.text.utf16.count
            if end - plan.caretUTF16Left >= 0, target.waitForCaret(at: end) {
                guard target.isUnchanged() else { return .interrupted }
                _ = target.setCaretLocation(end - plan.caretUTF16Left)
            }
        }
        return .completed
    }
}

/// Performs an expansion in another app.
@MainActor
protocol SnippetInserting {
    /// The target for a completed keyword: `field` is the focused field sampled while it
    /// was typed (nil where the app doesn't report one), so a later change is caught.
    func target(for processID: pid_t, field: FocusedField?) -> any KeystrokeTarget
    func insert(_ plan: SnippetExpansionPlan, on target: any KeystrokeTarget) throws -> KeystrokeScript.Result
}

enum SnippetInserters {
    /// The inserter the app should use: an inert one in the test host and in
    /// verification runs, live keyboard events otherwise.
    @MainActor static func makeDefault(sideEffects: SideEffectGuard = .current) -> any SnippetInserting {
        let sideEffects = sideEffects.restrictedByProcess
        return sideEffects.isInert
            ? InertSnippetInserter(sideEffects: sideEffects) : LiveSnippetInserter(sideEffects: sideEffects)
    }
}

/// Refuses every expansion, and reads nothing from other apps.
struct InertSnippetInserter: SnippetInserting {
    var sideEffects = SideEffectGuard.current

    func target(for processID: pid_t, field: FocusedField?) -> any KeystrokeTarget {
        InertKeystrokeTarget(sideEffects: sideEffects)
    }

    func insert(_ plan: SnippetExpansionPlan, on target: any KeystrokeTarget) throws -> KeystrokeScript.Result {
        throw SideEffectGuard.Blocked(what: "typing into other apps", mode: sideEffects.mode)
    }
}

/// A target that never reads or sends anything.
struct InertKeystrokeTarget: KeystrokeTarget {
    var sideEffects: SideEffectGuard

    func isUnchanged() -> Bool { false }
    func precedingText(utf16Count: Int) -> PrecedingText { .unreadable }
    func settle() {}
    func pressDelete() throws { throw SideEffectGuard.Blocked(what: "typing into other apps", mode: sideEffects.mode) }
    func type(_ chunk: [UInt16]) throws { throw SideEffectGuard.Blocked(what: "typing into other apps", mode: sideEffects.mode) }
    func caretLocation() -> Int? { nil }
    func waitForCaret(at location: Int) -> Bool { false }
    func setCaretLocation(_ location: Int) -> Bool { false }
}

/// Types into the focused field of `processID` with synthetic key events.
struct LiveSnippetInserter: SnippetInserting {
    var sideEffects = SideEffectGuard.current

    /// Never sends anything.
    func target(for processID: pid_t, field: FocusedField?) -> any KeystrokeTarget {
        let sideEffects = sideEffects.restrictedByProcess
        guard !sideEffects.isInert else { return InertKeystrokeTarget(sideEffects: sideEffects) }
        return AccessibilityKeystrokeTarget(processID: processID, field: field, sideEffects: sideEffects)
    }

    func insert(_ plan: SnippetExpansionPlan, on target: any KeystrokeTarget) throws -> KeystrokeScript.Result {
        try sideEffects.restrictedByProcess.check("typing into other apps")
        return try KeystrokeScript.run(plan, on: target)
    }
}

/// The live target: events go to one process only, and its focused element must
/// stay the one that had focus when the keyword was completed.
@MainActor
final class AccessibilityKeystrokeTarget: KeystrokeTarget {
    let processID: pid_t
    private let sideEffects: SideEffectGuard
    private let application: AXUIElement
    private let focused: AXUIElement?

    /// `field` is the focused field sampled while the keyword was typed. Without one,
    /// only the app is checked, as for fields that don't report focus.
    init(processID: pid_t, field: FocusedField?, sideEffects: SideEffectGuard = .current) {
        self.processID = processID
        self.sideEffects = sideEffects.restrictedByProcess
        application = AXUIElementCreateApplication(processID)
        focused = field?.element
    }

    /// The focused field of `processID` right now, or nil where it can't be read.
    static func sampleField(processID: pid_t) -> FocusedField? {
        focusedElement(in: AXUIElementCreateApplication(processID)).map { FocusedField(element: $0) }
    }

    func isUnchanged() -> Bool {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
        else { return false }
        // Apps that don't report a focused element are checked by process only.
        guard let focused else { return true }
        guard let current = Self.focusedElement(in: application) else { return false }
        return CFEqual(current, focused)
    }

    func pressDelete() throws {
        try SyntheticInput.postKey(CGKeyCode(kVK_Delete), toProcess: processID, sideEffects: sideEffects)
    }

    func type(_ chunk: [UInt16]) throws {
        try SyntheticInput.postText(chunk, toProcess: processID, sideEffects: sideEffects)
    }

    func precedingText(utf16Count: Int) -> PrecedingText {
        guard let focused, let range = selectedRange() else { return .unreadable }
        guard range.length == 0 else { return .selection }
        // A caret before the keyword's length can't have the keyword before it.
        guard range.location >= utf16Count else { return .text("") }
        var request = CFRange(location: range.location - utf16Count, length: utf16Count)
        guard let parameter = AXValueCreate(.cfRange, &request) else { return .unreadable }
        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                focused, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
            let text = value as? String
        else { return .unreadable }
        return .text(text)
    }

    func settle() { usleep(15_000) }

    func caretLocation() -> Int? { selectedRange()?.location }

    private func selectedRange() -> CFRange? {
        guard let focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    func waitForCaret(at location: Int) -> Bool {
        for _ in 0..<20 {
            if caretLocation() == location { return true }
            usleep(10_000)
        }
        return false
    }

    func setCaretLocation(_ location: Int) -> Bool {
        guard (try? sideEffects.check("moving the caret in other apps")) != nil, let focused else { return false }
        var range = CFRange(location: location, length: 0)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private static func focusedElement(in application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}

// MARK: - Values

extension PlaceholderValues {
    /// The app's calculator, for `{calculator}`.
    static let appCalculator: @Sendable (String) -> String? = { expression in
        Calculator.evaluate(expression).map { $0.conversion == nil ? $0.value : $0.result }
    }

    /// The values one run needs, read now and only if `requirements` lists them.
    /// `{clipboard}` is the current clipboard, read once through `currentClipboard`.
    /// Earlier offsets come from history only while capture is on, skipping its
    /// newest entry when that is the current clipboard.
    static func snapshot(
        library database: LibraryDatabase, requirements: PlaceholderRequirements,
        currentClipboard: () -> String?, now: Date = .now
    ) -> PlaceholderValues {
        var values = PlaceholderValues(now: now)
        let needsHistory =
            database.preferences.clipboardEnabled && requirements.clipboardOffsets.contains(where: { $0 > 0 })
        // The current clipboard is read only for `{clipboard}`, or to line history up with it.
        if requirements.clipboardOffsets.contains(0) || needsHistory {
            let current = currentClipboard()
            values.currentClipboard = current
            if needsHistory {
                var history = database.clipboard.compactMap(\.plainText)
                if let current, history.first == current { history.removeFirst() }
                values.clipboardHistory = history
            }
        }
        if requirements.calculator { values.calculator = appCalculator }
        return values
    }

    /// Snippet text by name, exact first, then case-insensitive. The index is built once,
    /// so each lookup is constant time however many snippets the library has.
    static func snippetLookup(_ database: LibraryDatabase) -> (String) -> String? {
        var exact: [String: String] = [:]
        var folded: [String: String] = [:]
        let now = Date.now
        for snippet in database.snippets {
            let source = snippet.referenceSource(now: now)
            if exact[snippet.name] == nil { exact[snippet.name] = source }
            let key = snippet.name.lowercased()
            if folded[key] == nil { folded[key] = source }
        }
        return { name in exact[name] ?? folded[name.lowercased()] }
    }
}

// MARK: - Expander

/// What happened to a completed keyword.
enum SnippetExpansionOutcome: Equatable, Sendable {
    case inserted(SnippetExpansionPlan)
    /// Nothing was deleted or typed: a required value was missing, a calculation
    /// or snippet lookup failed, or the result was too long.
    case refused([PlaceholderIssue])
    /// Focus moved during insertion; typing stopped there.
    case interrupted(SnippetExpansionPlan)
    case failed(SnippetExpansionPlan, String)
}

/// The field that had focus when a key arrived. Its identity is compared from key to
/// key; live input also keeps the Accessibility element, to read and check it later.
struct FocusedField: Hashable, @unchecked Sendable {
    private enum Identity {
        case element(AXUIElement)
        case stand(Int)
    }

    private let identity: Identity

    init(element: AXUIElement) { identity = .element(element) }

    /// A stand-in for tests.
    init(id: Int) { identity = .stand(id) }

    var element: AXUIElement? { if case .element(let element) = identity { element } else { nil } }

    static func == (a: FocusedField, b: FocusedField) -> Bool {
        switch (a.identity, b.identity) {
        case (.element(let x), .element(let y)): CFEqual(x, y)
        case (.stand(let x), .stand(let y)): x == y
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch identity {
        case .element(let element): hasher.combine(CFHash(element))
        case .stand(let id): hasher.combine(id)
        }
    }
}

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
    /// The focused field when the key arrived, nil where the app doesn't report one.
    var field: FocusedField?
}

@MainActor
final class SnippetExpander {
    typealias ValuesProvider = @MainActor (LibraryDatabase, PlaceholderRequirements) -> PlaceholderValues

    /// Expansions render at most this much before they're refused.
    static let renderOptions = PlaceholderRenderOptions(maximumOutputBytes: 262_144)

    private let store: LibraryStore
    private let inserter: any SnippetInserting
    private let isSecureInputEnabled: @MainActor () -> Bool
    private let valuesOverride: ValuesProvider?
    private let failureFeedback: @MainActor () -> Void
    private let sideEffects: SideEffectGuard
    /// Reads the current clipboard for `{clipboard}`, only when a run needs it. The
    /// launcher sets it to its clipboard service, which also skips copies from
    /// excluded apps; the default reads the general pasteboard, never while inert.
    var clipboardReader: @MainActor () -> String?
    private var monitor: Any?
    private var mouseMonitor: Any?
    private var matcher = SnippetMatcher()
    private var previousPID: pid_t?
    private var previousField: FocusedField?

    /// Overrides the saved expansion options; nil uses `AppPreferences.snippetExpansion`,
    /// which defaults to OpenRay's original behavior.
    var settings: SnippetExpansionSettings? {
        didSet { matcher.reset() }
    }

    private var effectiveSettings: SnippetExpansionSettings {
        settings ?? store.database.preferences.snippetExpansion ?? SnippetExpansionSettings()
    }

    /// Defaults come from `sideEffects`: inert executors in the test host and in
    /// verification runs, so a default expander never types, beeps, watches keys
    /// or reads the person's clipboard there.
    init(
        store: LibraryStore, inserter: (any SnippetInserting)? = nil,
        isSecureInputEnabled: @escaping @MainActor () -> Bool = { IsSecureEventInputEnabled() },
        values: ValuesProvider? = nil, failureFeedback: (@MainActor () -> Void)? = nil,
        sideEffects: SideEffectGuard = .current
    ) {
        self.store = store
        let sideEffects = sideEffects.restrictedByProcess
        self.sideEffects = sideEffects
        self.inserter = inserter ?? SnippetInserters.makeDefault(sideEffects: sideEffects)
        self.isSecureInputEnabled = isSecureInputEnabled
        valuesOverride = values
        self.failureFeedback = failureFeedback ?? Self.alertSound(sideEffects: sideEffects)
        clipboardReader = { sideEffects.isInert ? nil : ClipboardPolicy.placeholderText(from: .general) }
    }

    static func alertSound(sideEffects: SideEffectGuard) -> @MainActor () -> Void {
        let sideEffects = sideEffects.restrictedByProcess
        return {
            guard (try? sideEffects.check("playing the alert sound")) != nil else { return }
            NSSound.beep()
        }
    }

    func configure() {
        stop()
        guard (try? sideEffects.check("watching keystrokes")) != nil,
            store.database.preferences.snippetExpansionEnabled, AXIsProcessTrusted()
        else { return }
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
        let isSynthetic = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == SyntheticInput.marker
        handle(
            SnippetKeyInput(
                characters: event.characters,
                hasShortcutModifiers: !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                isSynthetic: isSynthetic, processID: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                // Sampled with every key, so a keyword counts only if it was typed in one field.
                field: isSynthetic ? nil : AccessibilityKeystrokeTarget.sampleField(processID: app.processIdentifier)))
    }

    /// Feeds one key press. When it completes a keyword, plans and renders the
    /// snippet, then inserts it unless something required is missing.
    @discardableResult
    func handle(_ input: SnippetKeyInput) -> SnippetExpansionOutcome? {
        guard !input.isSynthetic else { return nil }
        let database = store.database
        let preferences = database.preferences
        guard preferences.snippetExpansionEnabled, !isSecureInputEnabled(), !input.hasShortcutModifiers,
            let text = input.characters
        else {
            matcher.reset()
            return nil
        }
        // A keyword counts only if it was typed in one app and one field.
        if previousPID != input.processID || previousField != input.field {
            matcher.reset()
            previousPID = input.processID
            previousField = input.field
        }
        guard
            ClipboardPolicy.shouldCapture(
                types: [], sourceBundleID: input.bundleIdentifier,
                excluded: preferences.effectiveClipboardExclusions, secureInput: false)
        else {
            matcher.reset()
            return nil
        }
        let settings = effectiveSettings
        if matcher.settings != settings {
            matcher.settings = settings
            matcher.reset()
        }
        guard let trigger = matcher.trigger(for: text, snippets: database.snippets.filter(\.expandsAsYouType))
        else { return nil }
        // Where the keyword was typed: the field sampled with its keys, before anything renders.
        let target = inserter.target(for: input.processID, field: input.field)
        // Old snippets expand exactly as they always did.
        guard let template = trigger.snippet.dynamicTemplate else {
            let rendering = PlaceholderRendering(
                text: trigger.snippet.legacyExpanded(), cursorUTF16Offset: nil, arguments: [], issues: [])
            return insert(SnippetExpansionPlan(trigger: trigger, rendering: rendering, mode: settings.mode), on: target, pid: input.processID)
        }
        // Arguments can't be asked for mid-typing: optional ones take their
        // defaults, and a required one refuses the expansion.
        let plan = template.plan(snippets: PlaceholderValues.snippetLookup(database))
        // Nothing is read for a template that can't run.
        guard plan.blockingIssues.isEmpty else {
            failureFeedback()
            return .refused(plan.blockingIssues)
        }
        let values =
            valuesOverride?(database, plan.requirements)
            ?? PlaceholderValues.snapshot(library: database, requirements: plan.requirements, currentClipboard: clipboardReader)
        let rendering = plan.render(values, options: Self.renderOptions)
        let expansion = SnippetExpansionPlan(trigger: trigger, rendering: rendering, mode: settings.mode)
        var blocking = rendering.blockingIssues
        if expansion.exceedsLimit && !blocking.contains(.outputTooLong) { blocking.append(.outputTooLong) }
        guard blocking.isEmpty else {
            failureFeedback()
            return .refused(blocking)
        }
        return insert(expansion, on: target, pid: input.processID)
    }

    private func insert(_ expansion: SnippetExpansionPlan, on target: any KeystrokeTarget, pid: pid_t)
        -> SnippetExpansionOutcome
    {
        guard !expansion.exceedsLimit else {
            failureFeedback()
            return .refused([.outputTooLong])
        }
        do {
            switch try inserter.insert(expansion, on: target) {
            case .completed: return .inserted(expansion)
            case .interrupted, .unconfirmed:
                failureFeedback()
                return .interrupted(expansion)
            }
        } catch {
            // A failed global expansion must not interrupt the user's active application.
            failureFeedback()
            return .failed(expansion, error.localizedDescription)
        }
    }
}
