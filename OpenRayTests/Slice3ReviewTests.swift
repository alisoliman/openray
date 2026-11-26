import AppKit
import Foundation
import Testing

@testable import OpenRay

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private actor FetchCount {
    var value = 0
    func increment() { value += 1 }
}

private struct CountingRates: CurrencyRateProvider {
    var table: CurrencyRateTable
    let count = FetchCount()
    func fetchRates() async throws -> CurrencyRateTable {
        await count.increment()
        return table
    }
}

/// Regressions from the Phase B review: inert defaults, the pending-search ↩, answer
/// snapshots, rates, history, bindings and shortcuts.
@MainActor
struct Slice3ReviewTests {
    private let pasteboard = NSPasteboard.withUniqueName()

    private func calculator(clock: TestClock = TestClock(CalculatorClock.now), rates: CurrencyRateStore? = nil)
        -> CalculatorProvider
    {
        let store =
            rates
            ?? CurrencyRateStore(
                provider: InertRateProvider(), cache: CurrencyRateCache(fileURL: nil), now: { clock.date })
        return CalculatorProvider(rates: store, now: { clock.date })
    }

    private func model(
        _ providers: [any CommandProvider], store: LibraryStore = LibraryStore(fileURL: nil), hotKey: GlobalHotKey? = nil
    ) -> LauncherModel {
        LauncherModel(
            store: store, ai: AIChatModel(engine: TestAIEngine()), pasteboard: pasteboard,
            registry: CommandRegistry(providers: providers), hotKey: hotKey)
    }

    private func search(_ model: LauncherModel, _ query: String) {
        model.query = query
        model.files.stop()
        model.synchronizeSelection()
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for a condition")
    }

    // MARK: Inert in the test host

    @Test func defaultProvidersAreInertInTheTestHost() async throws {
        #expect(SideEffectGuard.isTestHost)
        #expect(CalculatorProvider().rates.table == nil)
        #expect(CurrencyRateStore().table == nil)
        #expect(CurrencyRateCache.standard().fileURL == nil)
        #expect(CurrencyRateCache.standard(SideEffectGuard(mode: .verification)).fileURL == nil)
        #expect(CurrencyRateCache.standard(SideEffectGuard(mode: .live)).fileURL == CurrencyRateCache.defaultURL)
        #expect(AppleTranslationEngine.standard() is InertTranslationEngine)
        let translator = TranslatorProvider()
        let german = try #require(TranslationLanguages.named("german"))
        #expect(await translator.service.availability(from: TranslationLanguages.english, to: german) == .unsupported)
        await #expect(throws: SideEffectGuard.Blocked.self) {
            _ = try await URLSessionDataLoader().data(from: ECBRateProvider.dailyURL)
        }
        await #expect(throws: SideEffectGuard.Blocked.self) { _ = try await InertRateProvider().fetchRates() }
        await #expect(throws: SideEffectGuard.Blocked.self) {
            _ = try await AppleTranslationEngine(sideEffects: SideEffectGuard(mode: .verification))
                .translate("hi", from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "de"))
        }
        #expect(
            await AppleTranslationEngine(sideEffects: SideEffectGuard(mode: .testHost))
                .availability(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "de")) == .unsupported)
        let downloads = TranslationDownloads()
        let context = TranslationDownloads.Context(search: 1, presentation: 1, scope: "translate")
        downloads.start(source: "en-US", target: "de", context: context) { _ in }
        #expect(downloads.request == nil)
        #expect(downloads.configuration(for: "en-US>de", context: context) == nil)
        #expect(downloads.status(for: "en-US>de") == "Language downloads are off in this mode.")
    }

    // MARK: Words-only answers while search is pending

    @Test func aPendingWordAnswerIsNeverTheDefaultSelection() async throws {
        let live = SuspendingLiveProvider(id: "late")
        live.emptyQueries = ["time in tokyo"]
        let model = model([calculator(), live])
        defer {
            live.releaseAll()
            model.stop()
        }
        search(model, "time in tokyo")
        #expect(model.results.contains { $0.id == CalculatorProvider.pendingWordAnswerID })
        #expect(model.selectedItem?.id == "fallback.ai")
        // ⌘↩ has nothing to do on Ask AI, and nothing is queued for later.
        model.pasteSelected()
        try await waitUntil { live.started.contains("time in tokyo") }
        live.release("time in tokyo")
        try await waitUntil { model.results.contains { $0.id == CalculatorProvider.wordAnswerID } }
        #expect(pasteboard.string(forType: .string) == nil)
        // Once search settles, the untouched selection follows the default: the answer.
        model.synchronizeSelection()
        #expect(model.selectedItem?.id == CalculatorProvider.wordAnswerID)
        let shown = try #require(model.selectedItem?.calculatorAnswer(in: model)?.value)
        model.performSelected()
        #expect(pasteboard.string(forType: .string) == shown)
    }

    @Test func aTitleMatchOrALateRowIsTheDefaultInstead() async throws {
        let live = SuspendingLiveProvider(id: "late")
        let model = model([calculator(), TitledCommandsProvider(titles: ["Time in Tokyo Clock"]), live])
        defer {
            live.releaseAll()
            model.stop()
        }
        search(model, "time in tokyo")
        #expect(model.selectedItem?.title == "Time in Tokyo Clock")
        // "today" matches no title here, so while the live search runs Ask AI is the default.
        search(model, "today")
        #expect(model.results.contains { $0.id == CalculatorProvider.pendingWordAnswerID })
        #expect(model.selectedItem?.id == "fallback.ai")
        try await waitUntil { live.started.contains("today") }
        live.release("today")
        try await waitUntil { model.groups.contains { $0.id == "live.late" } }
        model.synchronizeSelection()
        #expect(model.selectedItem?.id == "late.today")
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func anAnswerChosenByHandActsAtOnceAndStaysChosen() async throws {
        let live = SuspendingLiveProvider(id: "late")
        let model = model([calculator(), TitledCommandsProvider(titles: ["Time in Tokyo Clock"]), live])
        defer {
            live.releaseAll()
            model.stop()
        }
        search(model, "time in tokyo")
        model.moveSelection(1)
        #expect(model.selectedID == CalculatorProvider.pendingWordAnswerID)
        let shown = try #require(model.selectedItem?.calculatorAnswer(in: model)?.value)
        model.performSelected()
        #expect(pasteboard.string(forType: .string) == shown)
        try await waitUntil { live.started.contains("time in tokyo") }
        live.release("time in tokyo")
        try await waitUntil { model.groups.contains { $0.id == "live.late" } }
        model.synchronizeSelection()
        #expect(model.selectedID == CalculatorProvider.wordAnswerID)
    }

    @Test func explicitMathIsPreselectedWhilePending() async throws {
        let live = SuspendingLiveProvider(id: "late")
        let model = model([calculator(), live])
        defer {
            live.releaseAll()
            model.stop()
        }
        search(model, "2 + 3")
        #expect(model.isLoadingProvidedItems)
        #expect(model.selectedItem?.id == CalculatorProvider.answerID)
        model.performSelected()
        #expect(pasteboard.string(forType: .string) == "5")
    }

    // MARK: Snapshots

    @Test func returnCopiesTheAnswerThatWasShown() throws {
        let clock = TestClock(CalculatorClock.now)
        let model = model([calculator(clock: clock)])
        defer { model.stop() }
        search(model, "unix time")
        let shown = try #require(model.selectedItem?.title)
        clock.date += 5
        _ = model.groups
        #expect(model.selectedItem?.calculatorAnswer(in: model)?.result == shown)
        model.performSelected()
        #expect(pasteboard.string(forType: .string) == shown)
        #expect(model.store.database.calculatorHistory.first?.result == shown)
        // A new search takes a new snapshot.
        search(model, "")
        search(model, "unix time")
        #expect(model.selectedItem?.title == "\(Int(clock.date.timeIntervalSince1970))")
    }

    // MARK: Rates

    @Test func currencyOptInReRegistersItsHotkey() throws {
        let backend = RecordingHotKeyBackend()
        let calculator = calculator()
        let model = model([calculator], hotKey: GlobalHotKey(backend: backend, reservedShortcuts: { [] }))
        defer { model.stop() }
        model.isStarted = true
        calculator.setCurrencyRates(true, in: model)
        let shortcut = CommandShortcut(keyCode: 15, modifiers: [.control, .option])
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: CalculatorProvider.refreshID, shortcut: shortcut)))
        #expect(backend.active.values.contains(shortcut))
        calculator.setCurrencyRates(false, in: model)
        #expect(!backend.active.values.contains(shortcut))
        calculator.setCurrencyRates(true, in: model)
        #expect(backend.active.values.contains(shortcut))
    }

    @Test func optedInRatesRefreshWhenTheyAge() async throws {
        let clock = TestClock(CalculatorClock.now)
        let directory = FileManager.default.temporaryDirectory.appending(path: "openray-calc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CurrencyRateCache(fileURL: directory.appending(path: "rates.json"))
        try cache.save(try CurrencyRatesTests.fixtureRates(fetchedAt: clock.date))
        let source = CountingRates(table: try CurrencyRatesTests.fixtureRates(fetchedAt: clock.date))
        let rates = CurrencyRateStore(provider: source, cache: cache, now: { clock.date })
        let calculator = calculator(clock: clock, rates: rates)
        let model = model([calculator])
        defer { model.stop() }
        calculator.setCurrencyRates(true, in: model)
        search(model, "100 eur in usd")
        try await Task.sleep(for: .milliseconds(50))
        #expect(await source.count.value == 0)
        clock.date += 13 * 3_600
        search(model, "100 usd in eur")
        try await waitUntil { await source.count.value == 1 }
        // Within the hour, more searches don't fetch again.
        search(model, "50 usd in eur")
        try await Task.sleep(for: .milliseconds(50))
        #expect(await source.count.value == 1)
    }

    // MARK: History

    private func records(_ count: Int, before date: Date) -> [CalculatorHistoryRecord] {
        (0..<count).map { index in
            CalculatorHistoryRecord(
                expression: "\(index) + 1", result: "\(index + 1)", value: "\(index + 1)", kind: "arithmetic",
                date: date.addingTimeInterval(Double(-index * 60)))
        }
    }

    @Test func expiredHistoryIsHiddenAndDropped() async throws {
        let store = LibraryStore(fileURL: nil)
        let old = CalculatorClock.calendar.date(byAdding: .month, value: -4, to: CalculatorClock.now)!
        store.update { $0.calculatorHistory = self.records(1, before: CalculatorClock.now) + [CalculatorHistoryRecord(expression: "1 + 1", result: "2", value: "2", kind: "arithmetic", date: old)] }
        let model = model([calculator()], store: store)
        defer { model.stop() }
        model.navigate(to: .provided(CalculatorProvider.historyScope))
        model.files.stop()
        #expect(model.results.map(\.title) == ["1"])
        try await waitUntil { model.store.database.calculatorHistory.count == 1 }
    }

    @Test func historyPagesPastTheScopeCap() throws {
        let store = LibraryStore(fileURL: nil)
        store.update { $0.calculatorHistory = self.records(150, before: CalculatorClock.now) }
        let model = model([calculator()], store: store)
        defer { model.stop() }
        model.navigate(to: .provided(CalculatorProvider.historyScope))
        model.files.stop()
        let first = model.results
        #expect(first.count == CalculatorProvider.historyPageSize + 1)
        #expect(first.last?.title == "Older Calculations")
        model.perform(try #require(first.last))
        model.files.stop()
        let second = model.results
        #expect(second.first?.title == "Newer Calculations")
        #expect(second.count == 150 - CalculatorProvider.historyPageSize + 1)
        #expect(second.last?.subtitle == "149 + 1")
    }

    // MARK: Bindings and shortcuts

    @Test func contentRowsAreNotBindable() throws {
        for id in ["emoji-tile.results.👍", "emoji-nav.categories.flags/0", "calculator-history.1", "translation.result",
            "translation.inline", CalculatorProvider.answerID, CalculatorProvider.wordAnswerID]
        {
            #expect(!CuratedCommand.supports(id), "\(id)")
        }
        let emoji = EmojiProvider(catalog: .bundled, now: { CalculatorClock.now })
        let model = model([emoji])
        defer { model.stop() }
        model.navigate(to: .provided(EmojiProvider.scope))
        search(model, "thumbs up")
        let tile = try #require(model.selectedItem)
        #expect(!model.actions(for: tile).contains { $0.id == "assign" })
        let command = try #require(model.registry.commandItems(in: model).first { $0.id == EmojiProvider.searchID })
        #expect(model.actions(for: command).contains { $0.id == "assign" })
    }

    @Test func providerShortcutsAvoidThePanelsGlobalChords() async throws {
        func chord(_ entry: ActionEntry) -> String? {
            guard let key = entry.key else { return nil }
            var parts: [String] = []
            if entry.modifiers.contains(.control) { parts.append("ctrl") }
            if entry.modifiers.contains(.option) { parts.append("opt") }
            if entry.modifiers.contains(.shift) { parts.append("shift") }
            if entry.modifiers.contains(.command) { parts.append("cmd") }
            return (parts + [String(key.character).lowercased()]).joined(separator: "+")
        }
        // GlobalShortcutButtons in LauncherRootView: they win over provider entries.
        var global: Set<String> = ["cmd+/", "cmd+,", "shift+cmd+?", "cmd+k", "cmd+n", "cmd+p", "cmd+."]
        for number in 1...8 { global.insert("cmd+\(number)") }

        let engine = SilentEngine()
        let translator = TranslatorProvider(service: TranslationService(engine: engine, detector: FixedDetector()))
        let model = model([calculator(), EmojiProvider(catalog: .bundled, now: { CalculatorClock.now }), translator])
        defer { model.stop() }
        var entries: [ActionEntry] = []
        search(model, "10 km in mi")
        let answer = try #require(model.selectedItem)
        entries += model.actions(for: answer)
        model.performSelected()
        model.navigate(to: .provided(CalculatorProvider.historyScope))
        model.files.stop()
        let history = try #require(model.selectedItem)
        entries += model.actions(for: history)
        model.navigate(to: .provided(EmojiProvider.scope))
        search(model, "thumbs up")
        let tile = try #require(model.selectedItem)
        entries += model.actions(for: tile)
        translator.open(text: "hello", arguments: ["target": "de"], in: model)
        try await waitUntil { model.results.contains { $0.id == "translation.result" } }
        for item in model.results { entries += model.actions(for: item) }
        let clashes = entries.compactMap(chord).filter(global.contains)
        #expect(clashes.isEmpty, "\(clashes)")
        #expect(entries.contains { $0.id == "emoji.pin" } && entries.contains { $0.id == "translate.pickTarget" })
    }
}

private struct SilentEngine: TranslationEngine {
    func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability {
        .installed
    }

    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        text.uppercased()
    }
}

private struct FixedDetector: LanguageDetecting {
    func dominantLanguage(of text: String) -> Locale.Language? { Locale.Language(identifier: "en") }
}
