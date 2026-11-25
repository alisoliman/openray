import Foundation
import Testing

@testable import OpenRay

@MainActor
private final class RecordingInserter: SnippetInserting {
    var plans: [(SnippetExpansionPlan, pid_t)] = []
    func insert(_ plan: SnippetExpansionPlan, into processID: pid_t) throws { plans.append((plan, processID)) }
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

    @Test func delimiterModeWaitsForADelimiter() {
        var matcher = SnippetMatcher(settings: .init(mode: .afterDelimiterKeeping))
        #expect(feed(&matcher, typing(";hi"), snippets: [greeting]) == nil)
        #expect(matcher.trigger(for: " ", snippets: [greeting]) == SnippetTrigger(snippet: greeting, delimiter: " "))
        for delimiter in [".", ",", "!", "?", ";", ":", ")", "\t", "\r", "\n", "\""] {
            var matcher = SnippetMatcher(settings: .init(mode: .afterDelimiterDiscarding))
            let trigger = feed(&matcher, typing(";hi") + [delimiter], snippets: [greeting])
            #expect(trigger?.delimiter == Character(delimiter), "\(delimiter.debugDescription)")
        }
        var noDelimiter = SnippetMatcher(settings: .init(mode: .afterDelimiterKeeping))
        #expect(feed(&noDelimiter, typing(";hix"), snippets: [greeting]) == nil)
    }

    @Test func delimiterModeTellsSimilarKeywordsApart() {
        let high = Snippet(name: "High", keyword: ";high", content: "High!")
        var matcher = SnippetMatcher(settings: .init(mode: .afterDelimiterKeeping))
        #expect(feed(&matcher, typing(";high "), snippets: [greeting, high])?.snippet == high)
        #expect(feed(&matcher, typing(";hi "), snippets: [greeting, high])?.snippet == greeting)
    }

    @Test func keypadEnterActsAsReturn() {
        var matcher = SnippetMatcher(settings: .init(mode: .afterDelimiterKeeping))
        #expect(feed(&matcher, typing(";hi") + ["\u{3}"], snippets: [greeting])?.delimiter == "\r")
    }

    @Test func navigationKeysAndLineBreaksResetTheBuffer() {
        var matcher = SnippetMatcher()
        _ = feed(&matcher, typing(" ;h"), snippets: [greeting])
        #expect(matcher.trigger(for: "\u{F702}", snippets: [greeting]) == nil)  // ←
        #expect(matcher.buffer.isEmpty)
        _ = feed(&matcher, typing("x;h"), snippets: [greeting])
        #expect(matcher.trigger(for: "\r", snippets: [greeting]) == nil)
        #expect(matcher.buffer.isEmpty)
        // After a reset the next keyword starts a word.
        #expect(feed(&matcher, typing(";hi"), snippets: [greeting])?.snippet == greeting)

        var delimited = SnippetMatcher(settings: .init(mode: .afterDelimiterKeeping))
        #expect(feed(&delimited, typing("abc") + ["\r"], snippets: [greeting]) == nil)
        #expect(delimited.buffer.isEmpty)
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
        #expect(immediate == SnippetExpansionPlan(deleteCount: 4, text: "console.log();", caretLeft: 2))
        let keeping = SnippetExpansionPlan(
            trigger: .init(snippet: logger, delimiter: " "), rendering: rendering, mode: .afterDelimiterKeeping)
        #expect(keeping == SnippetExpansionPlan(deleteCount: 5, text: "console.log(); ", caretLeft: 3))
        let discarding = SnippetExpansionPlan(
            trigger: .init(snippet: logger, delimiter: "."), rendering: rendering, mode: .afterDelimiterDiscarding)
        #expect(discarding == SnippetExpansionPlan(deleteCount: 5, text: "console.log();", caretLeft: 2))

        let plain = Placeholders.render("Hello!", context: .snippet, source: PlaceholderValues())
        let kept = SnippetExpansionPlan(trigger: .init(snippet: greeting, delimiter: "!"), rendering: plain, mode: .afterDelimiterKeeping)
        #expect(kept == SnippetExpansionPlan(deleteCount: 4, text: "Hello!!", caretLeft: 0))
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
struct SnippetExpanderTests {
    private let now = Date(timeIntervalSince1970: 1_655_300_679)

    private func makeExpander(
        snippets: [Snippet], clipboard: [String] = [], secure: Bool = false, enabled: Bool = true
    ) -> (SnippetExpander, RecordingInserter, LibraryStore) {
        let store = LibraryStore(fileURL: nil)
        store.update {
            $0.preferences.snippetExpansionEnabled = enabled
            $0.snippets = snippets
            $0.preferences.clipboardEnabled = true
            $0.clipboard = clipboard.enumerated().map { index, text in
                ClipboardEntry(text: text, copiedAt: .now.addingTimeInterval(-Double(index)), sourceName: "F")
            }
        }
        let inserter = RecordingInserter()
        let now = now
        let expander = SnippetExpander(
            store: store, inserter: inserter, isSecureInputEnabled: { secure },
            placeholderValues: { database in
                var values = PlaceholderValues(library: database, now: now)
                values.calendar = Calendar(identifier: .gregorian)
                values.calendar.timeZone = TimeZone(identifier: "UTC")!
                values.locale = Locale(identifier: "en_US")
                return values
            })
        return (expander, inserter, store)
    }

    private func type(_ text: String, into expander: SnippetExpander, pid: pid_t = 42, bundle: String? = "com.apple.TextEdit")
        -> SnippetExpansionPlan?
    {
        var last: SnippetExpansionPlan?
        for character in text {
            last = expander.handle(SnippetKeyInput(characters: String(character), processID: pid, bundleIdentifier: bundle))
        }
        return last
    }

    @Test func expandsThroughThePlaceholderEngine() {
        let snippet = Snippet(
            name: "Reply", keyword: ";re",
            content: "On {date format=\"yyyy-MM-dd\"} you wrote: {clipboard} / {snippet name=\"Sig\"}{cursor}!")
        let signature = Snippet(name: "Sig", keyword: "", content: "Ann")
        let (expander, inserter, _) = makeExpander(snippets: [snippet, signature], clipboard: ["newest", "older"])
        let plan = type(" ;re", into: expander)
        #expect(plan == SnippetExpansionPlan(deleteCount: 3, text: "On 2022-06-15 you wrote: newest / Ann!", caretLeft: 1))
        #expect(inserter.plans.count == 1)
        #expect(inserter.plans.first?.1 == 42)
    }

    @Test func delimiterSettingsApply() {
        let (expander, inserter, _) = makeExpander(snippets: [greeting])
        expander.settings = SnippetExpansionSettings(mode: .afterDelimiterDiscarding, expandsWithinWords: true)
        #expect(type("abc;hi", into: expander) == nil)
        #expect(type(".", into: expander) == SnippetExpansionPlan(deleteCount: 4, text: "Hello!", caretLeft: 0))
        #expect(inserter.plans.count == 1)
    }

    @Test func argumentsTakeTheirDefaultsWhileTyping() {
        let snippet = Snippet(name: "Tone", keyword: ";t", content: "Feeling {argument name=\"mood\" default=\"fine\"}{argument}")
        let (expander, _, _) = makeExpander(snippets: [snippet])
        #expect(type(";t", into: expander)?.text == "Feeling fine")
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

    @Test func libraryValuesComeNewestFirst() {
        var database = LibraryDatabase()
        database.clipboard = [
            ClipboardEntry(text: "newest", sourceName: "F"),
            ClipboardEntry(content: .files([URL(fileURLWithPath: "/tmp/x")]), sourceName: "F"),
            ClipboardEntry(text: "older", sourceName: "F"),
        ]
        database.snippets = [
            Snippet(name: "Sig", keyword: "", content: "First"), Snippet(name: "Sig", keyword: "", content: "Second"),
        ]
        let values = PlaceholderValues(library: database)
        #expect(values.clipboard == ["newest", "older"])
        #expect(values.snippetText(named: "sig") == "First")
        #expect(PlaceholderValues(library: database, currentClipboard: "live").clipboard == ["live", "newest", "older"])
        #expect(PlaceholderValues(library: database, currentClipboard: "newest").clipboard == ["newest", "older"])
    }
}
