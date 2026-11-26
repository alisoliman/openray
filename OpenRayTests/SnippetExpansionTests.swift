import Foundation
import Testing

@testable import OpenRay

@MainActor
private final class RecordingInserter: SnippetInserting {
    var plans: [(SnippetExpansionPlan, pid_t)] = []
    var result = KeystrokeScript.Result.completed
    /// Shared with the values provider, to check what happens first.
    var log: [String] = []
    private var processID: pid_t = 0

    func target(for processID: pid_t) -> any KeystrokeTarget {
        log.append("target")
        self.processID = processID
        return FakeEditor(text: "")
    }

    func insert(_ plan: SnippetExpansionPlan, on target: any KeystrokeTarget) throws -> KeystrokeScript.Result {
        log.append("insert")
        plans.append((plan, processID))
        return result
    }
}

/// A text field that records events and applies them to its own text, so tests
/// can check where text and caret end up without sending any real input.
@MainActor
private final class FakeEditor: KeystrokeTarget {
    enum Event: Equatable { case delete, type(String), setCaret(Int) }

    var text: String
    /// UTF-16 caret location.
    var caret: Int
    var events: [Event] = []
    var reportsCaret = true
    var allowsSettingCaret = true
    /// False for a field whose text can't be read, such as one without Accessibility support.
    var readsText = true
    /// Typed text the app hasn't shown yet; it appears after the first pause.
    var lagging = ""
    var selectionLength = 0
    private(set) var pauses = 0
    /// The focus changes once this many events have been sent.
    var focusLostAfter: Int?

    init(text: String) {
        self.text = text
        caret = text.utf16.count
    }

    func isUnchanged() -> Bool { focusLostAfter.map { events.count < $0 } ?? true }

    func pressDelete() throws {
        events.append(.delete)
        let units = Array(text.utf16)
        let before = String(decoding: units[..<caret], as: UTF16.self)
        let after = String(decoding: units[caret...], as: UTF16.self)
        let trimmed = String(before.dropLast())
        text = trimmed + after
        caret = trimmed.utf16.count
    }

    func type(_ chunk: [UInt16]) throws {
        let typed = String(decoding: chunk, as: UTF16.self)
        events.append(.type(typed))
        let units = Array(text.utf16)
        text = String(decoding: units[..<caret], as: UTF16.self) + typed + String(decoding: units[caret...], as: UTF16.self)
        caret += chunk.count
    }

    func precedingText(utf16Count: Int) -> PrecedingText {
        guard readsText else { return .unreadable }
        guard selectionLength == 0 else { return .selection }
        guard caret >= utf16Count else { return .text("") }
        return .text(String(decoding: Array(text.utf16)[(caret - utf16Count)..<caret], as: UTF16.self))
    }

    func settle() {
        pauses += 1
        guard !lagging.isEmpty else { return }
        text += lagging
        caret = text.utf16.count
        lagging = ""
    }

    func caretLocation() -> Int? { reportsCaret ? caret : nil }
    func waitForCaret(at location: Int) -> Bool { reportsCaret && caret == location }

    func setCaretLocation(_ location: Int) -> Bool {
        guard allowsSettingCaret else { return false }
        events.append(.setCaret(location))
        caret = location
        return true
    }

    var textBeforeCaret: String { String(decoding: Array(text.utf16)[..<caret], as: UTF16.self) }
}

private let greeting = Snippet(name: "Greeting", keyword: ";hi", content: "Hello!")

private func feed(_ matcher: inout SnippetMatcher, _ keys: [String], snippets: [Snippet]) -> SnippetTrigger? {
    var last: SnippetTrigger?
    for key in keys { last = matcher.trigger(for: key, snippets: snippets) }
    return last
}

private func typing(_ text: String) -> [String] { text.map(String.init) }

struct SnippetMatcherTests {
    @Test func immediateModeKeepsTheOriginalBehavior() {
        var matcher = SnippetMatcher()
        #expect(feed(&matcher, typing("x;hi"), snippets: [greeting]) == nil)
        #expect(feed(&matcher, typing(" ;hi"), snippets: [greeting]) == SnippetTrigger(snippet: greeting, delimiter: nil))
        #expect(matcher.buffer.isEmpty)
        #expect(feed(&matcher, typing(";hi"), snippets: [greeting])?.snippet == greeting)
    }

    @Test func expandingWithinWordsIsOptional() {
        var matcher = SnippetMatcher(settings: .init(expandsWithinWords: true))
        #expect(feed(&matcher, typing("word;hi"), snippets: [greeting])?.snippet == greeting)
    }

    @Test func quotesBackticksAndBracketsAreWordBoundaries() {
        for prefix in ["(", "[", "{", "\"", "'", "`", "“", "‘"] {
            var matcher = SnippetMatcher()
            #expect(feed(&matcher, typing(prefix + ";hi"), snippets: [greeting])?.snippet == greeting, "\(prefix)")
        }
        for prefix in ["a", ".", "@", "1"] {
            var matcher = SnippetMatcher()
            #expect(feed(&matcher, typing(prefix + ";hi"), snippets: [greeting]) == nil, "\(prefix)")
        }
    }

    @Test func delimiterModeWaitsForAPrintableDelimiter() {
        var matcher = SnippetMatcher(settings: .init(mode: .afterDelimiterKeeping))
        #expect(feed(&matcher, typing(";hi"), snippets: [greeting]) == nil)
        #expect(matcher.trigger(for: " ", snippets: [greeting]) == SnippetTrigger(snippet: greeting, delimiter: " "))
        for delimiter in [".", ",", "!", "?", ";", ":", ")", "\"", "]", "\u{A0}"] {
            var matcher = SnippetMatcher(settings: .init(mode: .afterDelimiterDiscarding))
            let trigger = feed(&matcher, typing(";hi") + [delimiter], snippets: [greeting])
            #expect(trigger?.delimiter == Character(delimiter), "\(delimiter.debugDescription)")
        }
        var noDelimiter = SnippetMatcher(settings: .init(mode: .afterDelimiterKeeping))
        #expect(feed(&noDelimiter, typing(";hix"), snippets: [greeting]) == nil)
    }

    @Test(arguments: ["\t", "\r", "\n", "\u{3}", "\u{1b}", "\u{F702}", "\u{F703}"])
    func controlKeysNeverExpandAndEndTheWord(_ key: String) {
        for mode in SnippetExpansionMode.allCases {
            var matcher = SnippetMatcher(settings: .init(mode: mode))
            #expect(feed(&matcher, typing(" ;h"), snippets: [greeting]) == nil)
            if mode.waitsForDelimiter { _ = matcher.trigger(for: "i", snippets: [greeting]) }
            #expect(matcher.trigger(for: key, snippets: [greeting]) == nil, "\(mode)")
            #expect(matcher.buffer.isEmpty)
        }
        #expect(!SnippetKeywordRules.isDelimiter(Character(key)))
    }

    @Test func delimiterModeTellsSimilarKeywordsApart() {
        let high = Snippet(name: "High", keyword: ";high", content: "High!")
        var matcher = SnippetMatcher(settings: .init(mode: .afterDelimiterKeeping))
        #expect(feed(&matcher, typing(";high "), snippets: [greeting, high])?.snippet == high)
        #expect(feed(&matcher, typing(";hi "), snippets: [greeting, high])?.snippet == greeting)
    }

    @Test func navigationKeysResetTheBuffer() {
        var matcher = SnippetMatcher()
        _ = feed(&matcher, typing(" ;h"), snippets: [greeting])
        #expect(matcher.trigger(for: "\u{F702}", snippets: [greeting]) == nil)  // ←
        #expect(matcher.buffer.isEmpty)
        // After a reset the next keyword starts a word.
        #expect(feed(&matcher, typing(";hi"), snippets: [greeting])?.snippet == greeting)
    }

    @Test func backspaceEditsTheBuffer() {
        var matcher = SnippetMatcher(settings: .init(mode: .afterDelimiterKeeping))
        #expect(feed(&matcher, typing(";hiz") + ["\u{7f}", " "], snippets: [greeting])?.snippet == greeting)
    }

    @Test func plansDeleteTheKeywordAndPlaceTheCaret() {
        let logger = Snippet(name: "Log", keyword: ";log", content: "console.log({cursor});")
        let rendering = Placeholders.render(logger.content, context: .snippet, source: PlaceholderValues())
        let immediate = SnippetExpansionPlan(
            trigger: .init(snippet: logger, delimiter: nil), rendering: rendering, mode: .immediately)
        #expect(immediate == SnippetExpansionPlan(deletedText: ";log", text: "console.log();", caretLeft: 2))
        let keeping = SnippetExpansionPlan(
            trigger: .init(snippet: logger, delimiter: " "), rendering: rendering, mode: .afterDelimiterKeeping)
        #expect(keeping == SnippetExpansionPlan(deletedText: ";log ", text: "console.log(); ", caretLeft: 3))
        let discarding = SnippetExpansionPlan(
            trigger: .init(snippet: logger, delimiter: "."), rendering: rendering, mode: .afterDelimiterDiscarding)
        #expect(discarding == SnippetExpansionPlan(deletedText: ";log.", text: "console.log();", caretLeft: 2))

        let emoji = Placeholders.render("😀{cursor}😀é", context: .snippet, source: PlaceholderValues())
        let plan = SnippetExpansionPlan(trigger: .init(snippet: logger, delimiter: nil), rendering: emoji, mode: .immediately)
        #expect(plan.caretLeft == 2 && plan.caretUTF16Left == 3)
        #expect(!plan.hasRightToLeftText)
        #expect(SnippetExpansionPlan(deletedText: "", text: "שלום", caretLeft: 0).hasRightToLeftText)
    }

    @Test(arguments: ["@@", ";;addr", "!email", "/sig", "€x", "a", "x+y=z", "ü1", String(repeating: "k", count: 32)])
    func keywordRulesAcceptPunctuationAndSymbols(_ keyword: String) {
        #expect(SnippetKeywordRules.isValid(keyword))
    }

    @Test(arguments: ["", "has space", "q'uote", "`x", "(x", "x\"", "tab\t", "new\nline", String(repeating: "k", count: 33), "\u{F702}"])
    func keywordRulesRejectBoundaries(_ keyword: String) {
        #expect(!SnippetKeywordRules.isValid(keyword))
    }

    @Test func modesHaveTitles() {
        #expect(SnippetExpansionMode.allCases.map(\.waitsForDelimiter) == [false, true, true])
        #expect(Set(SnippetExpansionMode.allCases.map(\.title)).count == 3)
        #expect(SnippetExpansionSettings() == SnippetExpansionSettings(mode: .immediately, expandsWithinWords: false))
    }
}

@MainActor
struct KeystrokeScriptTests {
    @Test func typesInChunksAndSetsTheCaretByOffset() throws {
        let editor = FakeEditor(text: "Say ;log")
        let text = "console.log(" + String(repeating: "x", count: 30) + ");"
        let plan = SnippetExpansionPlan(deletedText: ";log", text: text, caretLeft: 2)
        #expect(try KeystrokeScript.run(plan, on: editor) == .completed)
        #expect(editor.text == "Say " + text)
        #expect(editor.textBeforeCaret == "Say " + text.dropLast(2))
        #expect(editor.events.filter { if case .type = $0 { true } else { false } }.count == 3)
        #expect(editor.events.last == .setCaret(("Say " + text.dropLast(2)).utf16.count))
    }

    @Test func emojiCaretOffsetsUseUTF16() throws {
        let editor = FakeEditor(text: "x ;s")
        let plan = SnippetExpansionPlan(deletedText: ";s", text: "<😀>", caretLeft: 2, caretUTF16Left: 3)
        #expect(try KeystrokeScript.run(plan, on: editor) == .completed)
        #expect(editor.text == "x <😀>")
        #expect(editor.textBeforeCaret == "x <")
    }

    @Test func withoutAnOffsetTheCaretStaysAtTheEnd() throws {
        // Arrow keys move visually, which isn't the logical offset in right-to-left
        // paragraphs, so they're never used, whatever the inserted text.
        for text in ["שלום עולם", "plain ascii"] {
            let editor = FakeEditor(text: ";h")
            editor.reportsCaret = false
            #expect(try KeystrokeScript.run(SnippetExpansionPlan(deletedText: ";h", text: text, caretLeft: 4), on: editor) == .completed)
            #expect(editor.caret == editor.text.utf16.count)
            #expect(!editor.events.contains { if case .setCaret = $0 { true } else { false } })
        }
        let capable = FakeEditor(text: ";h")
        #expect(try KeystrokeScript.run(SnippetExpansionPlan(deletedText: ";h", text: "שלום עולם", caretLeft: 4), on: capable) == .completed)
        #expect(capable.textBeforeCaret == "שלום ")
    }

    @Test func readableFieldsMustHaveTheKeywordBeforeTheCaret() throws {
        let plan = SnippetExpansionPlan(deletedText: ";hi", text: "Hello!")
        // Another field: different text before its caret. Retried, then refused.
        let other = FakeEditor(text: "unrelated")
        #expect(try KeystrokeScript.run(plan, on: other) == .unconfirmed)
        #expect(other.events.isEmpty && other.text == "unrelated")
        #expect(other.pauses == KeystrokeScript.confirmationAttempts - 1)
        // A selection means typing didn't end at a caret there.
        let selected = FakeEditor(text: "x ;hi")
        selected.selectionLength = 2
        #expect(try KeystrokeScript.run(plan, on: selected) == .unconfirmed)
        #expect(selected.events.isEmpty)
        // A match expands.
        let match = FakeEditor(text: "x ;hi")
        #expect(try KeystrokeScript.run(plan, on: match) == .completed)
        #expect(match.text == "x Hello!")
    }

    @Test func aFieldThatShowsTheLastKeyLateStillExpands() throws {
        let editor = FakeEditor(text: "x ;h")
        editor.lagging = "i"
        #expect(try KeystrokeScript.run(SnippetExpansionPlan(deletedText: ";hi", text: "Hello!"), on: editor) == .completed)
        #expect(editor.text == "x Hello!")
        #expect(editor.pauses == 1)
    }

    /// Terminals, VS Code, Slack and other fields without Accessibility text: expansion
    /// works on the base checks, as it did before and as other launchers do.
    @Test func fieldsWithoutAccessibilityTextStillExpand() throws {
        let terminal = FakeEditor(text: "$ ;hi")
        terminal.readsText = false
        #expect(try KeystrokeScript.run(SnippetExpansionPlan(deletedText: ";hi", text: "Hello!"), on: terminal) == .completed)
        #expect(terminal.text == "$ Hello!")
        #expect(terminal.pauses == 0)

        // A focus change since the keyword still stops it before anything is sent.
        let moved = FakeEditor(text: "$ ;hi")
        moved.readsText = false
        moved.focusLostAfter = 0
        #expect(try KeystrokeScript.run(SnippetExpansionPlan(deletedText: ";hi", text: "Hello!"), on: moved) == .interrupted)
        #expect(moved.events.isEmpty)

        // And during posting.
        let midway = FakeEditor(text: "$ ;hi")
        midway.readsText = false
        midway.focusLostAfter = 2
        #expect(try KeystrokeScript.run(SnippetExpansionPlan(deletedText: ";hi", text: "Hello!"), on: midway) == .interrupted)
        #expect(midway.events == [.delete, .delete])
    }

    @Test func stopsAtTheFirstFocusChange() throws {
        let editor = FakeEditor(text: ";hi")
        editor.focusLostAfter = 2
        let plan = SnippetExpansionPlan(deletedText: ";hi", text: "Hello!")
        #expect(try KeystrokeScript.run(plan, on: editor) == .interrupted)
        #expect(editor.events == [.delete, .delete])

        let gone = FakeEditor(text: ";hi")
        gone.focusLostAfter = 0
        #expect(try KeystrokeScript.run(plan, on: gone) == .interrupted)
        #expect(gone.events.isEmpty)

        let midText = FakeEditor(text: ";hi")
        midText.focusLostAfter = 4
        let long = SnippetExpansionPlan(deletedText: ";hi", text: String(repeating: "y", count: 100))
        #expect(try KeystrokeScript.run(long, on: midText) == .interrupted)
        #expect(midText.events.count == 4)

        // Focus that moves while the caret waits leaves the old field's selection alone.
        let placing = FakeEditor(text: ";c")
        placing.focusLostAfter = 2
        #expect(try KeystrokeScript.run(SnippetExpansionPlan(deletedText: ";c", text: "a", caretLeft: 1), on: placing) == .interrupted)
        #expect(!placing.events.contains { if case .setCaret = $0 { true } else { false } })
    }
}

@MainActor
struct SnippetExpanderTests {
    private let now = Date(timeIntervalSince1970: 1_655_300_679)

    private func makeExpander(
        snippets: [Snippet], history: [String] = [], current: String? = nil, captures: Bool = true,
        secure: Bool = false, enabled: Bool = true
    ) -> (SnippetExpander, RecordingInserter, Counter) {
        let store = LibraryStore(fileURL: nil)
        store.update {
            $0.preferences.snippetExpansionEnabled = enabled
            $0.snippets = snippets
            $0.preferences.clipboardEnabled = true
            $0.clipboard = history.enumerated().map { index, text in
                ClipboardEntry(text: text, copiedAt: .now.addingTimeInterval(-Double(index)), sourceName: "F")
            }
            $0.preferences.clipboardEnabled = captures
        }
        let inserter = RecordingInserter()
        let counter = Counter()
        let now = now
        let expander = SnippetExpander(
            store: store, inserter: inserter, isSecureInputEnabled: { secure },
            values: { database, requirements in
                var values = PlaceholderValues.snapshot(library: database, requirements: requirements, currentClipboard: {
                    counter.clipboardReads += 1
                    return current
                }, now: now)
                values.calendar = Calendar(identifier: .gregorian)
                values.calendar.timeZone = TimeZone(identifier: "UTC")!
                values.locale = Locale(identifier: "en_US")
                return values
            },
            failureFeedback: { counter.failures += 1 })
        return (expander, inserter, counter)
    }

    @MainActor final class Counter {
        var clipboardReads = 0
        var failures = 0
    }

    private func type(_ text: String, into expander: SnippetExpander, pid: pid_t = 42, bundle: String? = "com.apple.TextEdit")
        -> SnippetExpansionOutcome?
    {
        var last: SnippetExpansionOutcome?
        for character in text {
            last = expander.handle(SnippetKeyInput(characters: String(character), processID: pid, bundleIdentifier: bundle))
        }
        return last
    }

    @Test func expandsWithTheCurrentClipboardNotStaleHistory() {
        let snippet = Snippet(
            name: "Reply", keyword: ";re",
            content: "On {date format=\"yyyy-MM-dd\"} you wrote: {clipboard} / {snippet name=\"Sig\"}{cursor}!")
        let signature = Snippet(name: "Sig", keyword: "", content: "Ann")
        let (expander, inserter, counter) = makeExpander(snippets: [snippet, signature], history: ["stale"], current: "fresh")
        #expect(
            type(" ;re", into: expander)
                == .inserted(SnippetExpansionPlan(deletedText: ";re", text: "On 2022-06-15 you wrote: fresh / Ann!", caretLeft: 1)))
        #expect(inserter.plans.map(\.1) == [42])
        #expect(counter.clipboardReads == 1)
        #expect(counter.failures == 0)
    }

    @Test func theTargetIsNotedBeforeAnythingIsRendered() {
        let store = LibraryStore(fileURL: nil)
        store.update {
            $0.preferences.snippetExpansionEnabled = true
            $0.snippets = [Snippet(name: "Clip", keyword: ";c", content: "{clipboard}")]
        }
        let inserter = RecordingInserter()
        let expander = SnippetExpander(
            store: store, inserter: inserter, isSecureInputEnabled: { false },
            values: { database, requirements in
                inserter.log.append("values")
                return PlaceholderValues.snapshot(library: database, requirements: requirements) { "x" }
            })
        _ = expander.handle(SnippetKeyInput(characters: ";c", processID: 7, bundleIdentifier: "com.apple.Terminal"))
        #expect(inserter.log == ["target", "values", "insert"])
        #expect(inserter.plans.map(\.1) == [7])
    }

    @Test func theClipboardIsReadOnlyWhenNeeded() {
        let (expander, _, counter) = makeExpander(snippets: [greeting], current: "fresh")
        #expect(type(";hi", into: expander) == .inserted(SnippetExpansionPlan(deletedText: ";hi", text: "Hello!", caretLeft: 0)))
        #expect(counter.clipboardReads == 0)
    }

    @Test func clipboardOffsetsUseHistoryOnlyWhileCaptureIsOn() {
        let snippet = Snippet(name: "Older", keyword: ";o", content: "[{clipboard offset=1}]")
        // The newest history entry is the current clipboard, so offset 1 skips it.
        let (on, _, _) = makeExpander(snippets: [snippet], history: ["now", "before"], current: "now")
        #expect(type(";o", into: on) == .inserted(SnippetExpansionPlan(deletedText: ";o", text: "[before]", caretLeft: 0)))
        // A copy not captured yet is still the current clipboard; history starts at offset 1.
        let (pending, _, _) = makeExpander(snippets: [snippet], history: ["now", "before"], current: "newer")
        #expect(type(";o", into: pending) == .inserted(SnippetExpansionPlan(deletedText: ";o", text: "[now]", caretLeft: 0)))
        let (off, _, _) = makeExpander(snippets: [snippet], history: ["now", "before"], current: "now", captures: false)
        #expect(type(";o", into: off) == .inserted(SnippetExpansionPlan(deletedText: ";o", text: "[]", caretLeft: 0)))
    }

    @Test func missingInputsRefuseBeforeAnythingIsDeleted() {
        let required = Snippet(name: "Tone", keyword: ";t", content: "Feeling {argument name=\"mood\"}")
        let calculation = Snippet(name: "Calc", keyword: ";c", content: "= {calculator expression=\"not math\"}")
        let missing = Snippet(name: "Ref", keyword: ";r", content: "{snippet name=\"Gone\"}")
        let (expander, inserter, counter) = makeExpander(snippets: [required, calculation, missing])
        #expect(type(";t", into: expander) == .refused([.missingArgument("mood")]))
        #expect(type(" ;c", into: expander) == .refused([.calculationFailed("not math")]))
        #expect(type(" ;r", into: expander) == .refused([.missingSnippet("Gone")]))
        #expect(inserter.plans.isEmpty)
        #expect(counter.failures == 3)
    }

    @Test func optionalArgumentsAndTheAppCalculatorWork() {
        let snippet = Snippet(
            name: "Tone", keyword: ";t",
            content: "Feeling {argument name=\"mood\" default=\"fine\"}, {calculator expression=\"2 * 21\"}")
        let (expander, _, _) = makeExpander(snippets: [snippet])
        #expect(type(";t", into: expander) == .inserted(SnippetExpansionPlan(deletedText: ";t", text: "Feeling fine, 42", caretLeft: 0)))
    }

    @Test func oversizedExpansionsAreRefused() {
        let snippet = Snippet(name: "Big", keyword: ";b", content: String(repeating: "{clipboard}", count: 30))
        let (expander, inserter, _) = makeExpander(snippets: [snippet], current: String(repeating: "x", count: 10_000))
        #expect(type(";b", into: expander) == .refused([.outputTooLong]))
        #expect(inserter.plans.isEmpty)
    }

    @Test func interruptedAndFailedInsertionsAreReported() {
        let (expander, inserter, counter) = makeExpander(snippets: [greeting])
        inserter.result = .interrupted
        #expect(type(";hi", into: expander) == .interrupted(SnippetExpansionPlan(deletedText: ";hi", text: "Hello!", caretLeft: 0)))
        #expect(counter.failures == 1)
    }

    @Test func delimiterSettingsApply() {
        let (expander, inserter, _) = makeExpander(snippets: [greeting])
        expander.settings = SnippetExpansionSettings(mode: .afterDelimiterDiscarding, expandsWithinWords: true)
        #expect(type("abc;hi", into: expander) == nil)
        #expect(type(".", into: expander) == .inserted(SnippetExpansionPlan(deletedText: ";hi.", text: "Hello!", caretLeft: 0)))
        #expect(type(";hi\t", into: expander) == nil)
        #expect(inserter.plans.count == 1)
    }

    @Test func nothingExpandsWhenItMustNot() {
        let (expander, inserter, _) = makeExpander(snippets: [greeting])
        // Shortcuts, OpenRay's own events, password managers and missing characters.
        #expect(expander.handle(.init(characters: ";hi", hasShortcutModifiers: true, processID: 1)) == nil)
        #expect(expander.handle(.init(characters: ";hi", isSynthetic: true, processID: 1)) == nil)
        #expect(type(";hi", into: expander, bundle: "com.1password.1password") == nil)
        #expect(type(";hi", into: expander, bundle: "com.bitwarden.desktop.helper") == nil)
        #expect(expander.handle(.init(characters: nil, processID: 1)) == nil)
        #expect(inserter.plans.isEmpty)

        let (secure, secureInserter, _) = makeExpander(snippets: [greeting], secure: true)
        #expect(type(";hi", into: secure) == nil)
        #expect(secureInserter.plans.isEmpty)

        let (disabled, disabledInserter, _) = makeExpander(snippets: [greeting], enabled: false)
        #expect(type(";hi", into: disabled) == nil)
        #expect(disabledInserter.plans.isEmpty)

        var off = greeting
        off.expandsKeyword = false
        let (perSnippet, perSnippetInserter, _) = makeExpander(snippets: [off])
        #expect(type(";hi", into: perSnippet) == nil)
        #expect(perSnippetInserter.plans.isEmpty)
    }

    @Test func switchingAppsStartsANewWord() {
        let (expander, inserter, _) = makeExpander(snippets: [greeting])
        #expect(type(";h", into: expander, pid: 1) == nil)
        #expect(type("i", into: expander, pid: 2) == nil)
        // The "i" typed in the second app now starts its buffer, so a keyword needs a new word.
        #expect(type(";hi", into: expander, pid: 2) == nil)
        #expect(type(" ;hi", into: expander, pid: 2) != nil)
        #expect(inserter.plans.map(\.1) == [2])
    }

    @Test(arguments: [SideEffectGuard.Mode.testHost, .verification])
    func inertModesGetInertDefaults(_ mode: SideEffectGuard.Mode) {
        let sideEffects = SideEffectGuard(mode: mode)
        #expect(SideEffectGuard.isTestHost)
        #expect(SnippetInserters.makeDefault(sideEffects: sideEffects) is InertSnippetInserter)
        #expect(throws: SideEffectGuard.Blocked(what: "typing into other apps", mode: mode)) {
            let inserter = InertSnippetInserter(sideEffects: sideEffects)
            _ = try inserter.insert(SnippetExpansionPlan(deletedText: "x", text: "x"), on: inserter.target(for: 1))
        }
        // A default expander reaches only the inert inserter and never reads the real clipboard.
        let store = LibraryStore(fileURL: nil)
        store.update {
            $0.preferences.snippetExpansionEnabled = true
            $0.snippets = [Snippet(name: "Clip", keyword: ";c", content: "{clipboard}")]
        }
        let expander = SnippetExpander(store: store, isSecureInputEnabled: { false }, sideEffects: sideEffects)
        let outcome = expander.handle(SnippetKeyInput(characters: ";c", processID: 1, bundleIdentifier: "com.apple.TextEdit"))
        #expect(
            outcome
                == .failed(
                    SnippetExpansionPlan(deletedText: ";c", text: "", caretLeft: 0),
                    SideEffectGuard.Blocked(what: "typing into other apps", mode: mode).localizedDescription))
    }

    @Test func injectingALivePolicyCantLiftTheTestHosts() {
        // An injected policy can only add restrictions; this process stays inert.
        #expect(SideEffectGuard(mode: .live).restrictedByProcess == .current)
        #expect(SnippetInserters.makeDefault(sideEffects: SideEffectGuard(mode: .live)) is InertSnippetInserter)
        #expect(SnippetInserters.makeDefault() is InertSnippetInserter)
        #expect(throws: SideEffectGuard.Blocked.self) {
            let live = LiveSnippetInserter(sideEffects: SideEffectGuard(mode: .live))
            // Inert here, so the target it notes reads nothing from other apps.
            let target = live.target(for: 1)
            #expect(target is InertKeystrokeTarget)
            _ = try live.insert(SnippetExpansionPlan(deletedText: "x", text: "y"), on: target)
        }
    }

    @Test func snapshotsReadOnlyWhatThePlanNeeds() {
        var database = LibraryDatabase()
        database.preferences.clipboardEnabled = true
        database.clipboard = [
            ClipboardEntry(text: "newest", sourceName: "F"),
            ClipboardEntry(content: .files([URL(fileURLWithPath: "/tmp/x")]), sourceName: "F"),
            ClipboardEntry(text: "older", sourceName: "F"),
        ]
        var reads = 0
        let none = PlaceholderValues.snapshot(library: database, requirements: .init()) {
            reads += 1
            return "live"
        }
        #expect(reads == 0 && none.currentClipboard == nil && none.clipboardHistory.isEmpty && none.calculator == nil)
        let both = PlaceholderValues.snapshot(library: database, requirements: .init(clipboardOffsets: [0, 2])) {
            reads += 1
            return "newest"
        }
        #expect(reads == 1)
        #expect(both.clipboardText(offset: 0) == "newest" && both.clipboardText(offset: 1) == "older")
        let currentOnly = PlaceholderValues.snapshot(library: database, requirements: .init(clipboardOffsets: [0])) { nil }
        #expect(currentOnly.clipboardHistory.isEmpty && currentOnly.clipboardText(offset: 0) == nil)

        database.snippets = [Snippet(name: "Sig", keyword: "", content: "First"), Snippet(name: "sig", keyword: "", content: "Second")]
        let lookup = PlaceholderValues.snippetLookup(database)
        #expect(lookup("sig") == "Second" && lookup("SIG") == "First" && lookup("none") == nil)
    }
}
