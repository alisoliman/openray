import AppKit
import Foundation
import Testing

@testable import OpenRay

/// Commands with fixed titles, standing in for apps, files and commands named like a word.
@MainActor
final class TitledCommandsProvider: CommandProvider {
    let id = "test.titled"
    let titles: [String]

    init(titles: [String]) { self.titles = titles }

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        titles.map { title in
            CommandDescriptor(
                id: "test.titled.\(title.lowercased())", title: title, subtitle: "", kind: .command, symbol: "app",
                mode: .noView)
        }
    }
}

private struct FixedRates: CurrencyRateProvider {
    var table: CurrencyRateTable
    func fetchRates() async throws -> CurrencyRateTable { table }
}

@MainActor
struct CalculatorProviderTests {
    private let pasteboard = NSPasteboard.withUniqueName()

    private func calculator(rates: CurrencyRateStore? = nil) -> CalculatorProvider {
        let directory = FileManager.default.temporaryDirectory.appending(path: "openray-calc-\(UUID().uuidString)")
        let store =
            rates
            ?? CurrencyRateStore(
                provider: FixedRates(table: (try? CurrencyRatesTests.fixtureRates()) ?? .init(publishedOn: "", fetchedAt: .now, rates: [:])),
                cache: CurrencyRateCache(fileURL: directory.appending(path: "rates.json")), now: { CalculatorClock.now })
        return CalculatorProvider(rates: store, now: { CalculatorClock.now })
    }

    private func model(_ providers: [any CommandProvider], store: LibraryStore = LibraryStore(fileURL: nil)) -> LauncherModel {
        LauncherModel(
            store: store, ai: AIChatModel(engine: TestAIEngine()), pasteboard: pasteboard,
            registry: CommandRegistry(providers: providers))
    }

    private func search(_ model: LauncherModel, _ query: String) {
        model.query = query
        model.files.stop()
        model.synchronizeSelection()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for a condition")
    }

    // MARK: Root search

    @Test func unambiguousAnswersLeadAsTheCard() throws {
        let model = model([calculator()])
        defer { model.stop() }
        search(model, "10 km in mi")
        let first = try #require(model.groups.first)
        #expect(first.id == "calculator")
        #expect(first.style == .calculator)
        let answer = try #require(first.items.first)
        #expect(answer.id == CalculatorProvider.answerID)
        guard case .provided(let ref) = answer.action else {
            Issue.record("The answer should be a provider row")
            return
        }
        #expect(ref.provider == "calculator")
        #expect(answer.calculatorAnswer(in: model)?.result == "6.21371 mi")
        #expect(model.selectedItem?.id == CalculatorProvider.answerID)
    }

    @Test func aWordAnswerNeverTakesTheTopHitFromAMatchingTitle() throws {
        let model = model([calculator(), TitledCommandsProvider(titles: ["Time Machine Backup", "Today"])])
        defer { model.stop() }
        search(model, "time")
        #expect(model.groups.first?.id == "top")
        #expect(model.selectedItem?.title == "Time Machine Backup")
        let calculatorGroup = try #require(model.groups.first { $0.id == "calculator" })
        #expect(calculatorGroup.style == .list)
        #expect(calculatorGroup.items.map(\.id) == [CalculatorProvider.wordAnswerID])

        search(model, "today")
        #expect(model.selectedItem?.title == "Today")
        // ↩ opens the command, not the date.
        #expect(model.groups.firstIndex { $0.id == "calculator" }! > model.groups.firstIndex { $0.id == "top" }!)
    }

    @Test func aWordAnswerIsSelectedWhenNothingElseMatches() {
        let model = model([calculator()])
        defer { model.stop() }
        search(model, "time in tokyo")
        #expect(model.selectedItem?.id == CalculatorProvider.wordAnswerID)
        #expect(model.selectedItem?.calculatorAnswer(in: model)?.kind == .time)
    }

    @Test func aLateMatchAboveAWordAnswerTakesTheSelection() async throws {
        let live = SuspendingLiveProvider(id: "late")
        let model = model([calculator(), live])
        defer {
            live.releaseAll()
            model.stop()
        }
        search(model, "time in tokyo")
        #expect(model.selectedItem?.id == CalculatorProvider.wordAnswerID)
        try await waitUntil { live.started.contains("time in tokyo") }
        live.release("time in tokyo")
        try await waitUntil { model.groups.contains { $0.id == "live.late" } }
        model.synchronizeSelection()
        let groupIDs = model.groups.map(\.id)
        #expect(groupIDs.firstIndex(of: "live.late")! < groupIDs.firstIndex(of: "calculator")!)
        #expect(model.selectedItem?.id == "late.time in tokyo")
    }

    @Test func aWordAnswerChosenByHandKeepsTheSelection() async throws {
        let live = SuspendingLiveProvider(id: "late")
        let model = model([calculator(), TitledCommandsProvider(titles: ["Time in Tokyo Clock"]), live])
        defer {
            live.releaseAll()
            model.stop()
        }
        search(model, "time in tokyo")
        #expect(model.selectedItem?.title == "Time in Tokyo Clock")
        model.moveSelection(1)
        #expect(model.selectedID == CalculatorProvider.wordAnswerID)
        try await waitUntil { live.started.contains("time in tokyo") }
        live.release("time in tokyo")
        try await waitUntil { model.groups.contains { $0.id == "live.late" } }
        model.synchronizeSelection()
        #expect(model.selectedID == CalculatorProvider.wordAnswerID)
    }

    @Test func theCalculatorScopeShowsWordAnswersAsTheCard() {
        let model = model([calculator()])
        defer { model.stop() }
        model.navigate(to: .calculator)
        search(model, "time in tokyo")
        #expect(model.groups.first?.style == .calculator)
        #expect(model.groups.first?.items.first?.id == CalculatorProvider.wordAnswerID)
    }

    // MARK: ↩, ⌘↩ and history

    @Test func returnCopiesAndRecordsTheAnswer() throws {
        let model = model([calculator()])
        defer { model.stop() }
        search(model, "10 km in mi")
        model.performSelected()
        #expect(pasteboard.string(forType: .string) == "6.21371192237")
        let records = model.store.database.calculatorHistory
        #expect(records.count == 1)
        #expect(records.first?.expression == "10 km in mi")
        #expect(records.first?.result == "6.21371 mi")
        #expect(records.first?.value == "6.21371192237")
        #expect(records.first?.date == CalculatorClock.now)
        // Copying the same question again moves it to the top instead of adding it.
        model.performSelected()
        #expect(model.store.database.calculatorHistory.count == 1)
    }

    @Test func commandReturnPastesThroughTheSecondaryHook() throws {
        let model = model([calculator()])
        defer { model.stop() }
        search(model, "6 * 7")
        let item = try #require(model.selectedItem)
        #expect(model.primaryTitle(for: item) == "Copy Answer")
        #expect(model.secondaryTitle(for: item) != nil)
        model.pasteSelected()
        // The isolated pasteboard copies instead of pasting into another app.
        #expect(pasteboard.string(forType: .string) == "42")
        #expect(model.store.database.calculatorHistory.first?.expression == "6 * 7")
    }

    @Test func putAnswerAndSwapUnitsEditTheSearchBar() throws {
        let model = model([calculator()])
        defer { model.stop() }
        search(model, "10 km in mi")
        let item = try #require(model.selectedItem)
        let actions = model.actions(for: item)
        try #require(actions.first { $0.id == "calculator.swap" }).perform()
        #expect(model.query == "10 mi in km")
        model.files.stop()
        let swapped = try #require(model.selectedItem)
        try #require(model.actions(for: swapped).first { $0.id == "calculator.putAnswer" }).perform()
        #expect(model.query == "16.09344")
        model.files.stop()
        // Plain math has nothing to swap.
        search(model, "6 * 7")
        let math = try #require(model.selectedItem)
        #expect(model.actions(for: math).contains { $0.id == "calculator.swap" } == false)
    }

    @Test func copyQuestionAndAnswer() throws {
        let model = model([calculator()])
        defer { model.stop() }
        search(model, "50 + 20%")
        let item = try #require(model.selectedItem)
        try #require(model.actions(for: item).first { $0.id == "calculator.copyQuestion" }).perform()
        #expect(pasteboard.string(forType: .string) == "50 + 20% = 60")
    }

    @Test func historyScopeListsSearchesAndDeletes() throws {
        let model = model([calculator()])
        defer { model.stop() }
        for query in ["10 km in mi", "6 * 7"] {
            search(model, query)
            model.performSelected()
        }
        model.navigate(to: .provided(CalculatorProvider.historyScope))
        model.files.stop()
        #expect(model.results.map(\.title) == ["42", "6.21371 mi"])
        search(model, "km")
        let row = try #require(model.results.first)
        #expect(row.title == "6.21371 mi")
        guard case .provided(let ref) = row.action else {
            Issue.record("History rows are provider rows")
            return
        }
        let provider = try #require(model.registry.provider(id: "calculator"))
        guard case .library(let mutation) = try #require(provider.deletion(for: row, ref: ref, in: model)) else {
            Issue.record("History rows live in the library")
            return
        }
        #expect(model.store.update { try mutation(&$0) })
        #expect(model.store.database.calculatorHistory.map(\.expression) == ["6 * 7"])
    }

    @Test func clearHistoryAsksFirst() throws {
        let calculator = calculator()
        let model = model([calculator])
        defer { model.stop() }
        search(model, "6 * 7")
        model.performSelected()
        calculator.confirmClear(in: model)
        guard case .provided(let confirmation) = try #require(model.confirmation) else {
            Issue.record("Clearing asks in the action bar")
            return
        }
        #expect(model.store.database.calculatorHistory.count == 1)
        confirmation.perform()
        #expect(model.store.database.calculatorHistory.isEmpty)
    }

    @Test func historyCommandOpensTheScope() throws {
        let model = model([calculator()])
        defer { model.stop() }
        let command = try #require(model.registry.commandItems(in: model).first { $0.id == CalculatorProvider.historyID })
        model.perform(command)
        #expect(model.section == .provided(CalculatorProvider.historyScope))
        #expect(model.providedEmptyState(for: CalculatorProvider.historyScope).title == "No calculations yet")
    }

    // MARK: Currency

    @Test func currencyNeedsTheOptIn() throws {
        let model = model([calculator()])
        defer { model.stop() }
        search(model, "100 eur in usd")
        #expect(model.groups.contains { $0.id == "calculator" } == false)
        #expect(model.registry.commandItems(in: model).contains { $0.id == CalculatorProvider.refreshID } == false)
    }

    @Test func optedInRatesConvertWithTheirDate() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "openray-calc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CurrencyRateCache(fileURL: directory.appending(path: "rates.json"))
        try cache.save(try CurrencyRatesTests.fixtureRates())
        let rates = CurrencyRateStore(
            provider: FixedRates(table: try CurrencyRatesTests.fixtureRates()), cache: cache, now: { CalculatorClock.now })
        let calculator = calculator(rates: rates)
        let model = model([calculator])
        defer { model.stop() }
        calculator.setCurrencyRates(true, in: model)
        #expect(model.store.database.commandPreferences["calculator"]?["currencyRates"] == "on")
        search(model, "100 eur in usd")
        let answer = try #require(model.selectedItem?.calculatorAnswer(in: model))
        #expect(answer.result == "105.00 USD")
        #expect(answer.detail.contains("ECB rate for"))
        #expect(model.registry.commandItems(in: model).contains { $0.id == CalculatorProvider.refreshID })
        calculator.setCurrencyRates(false, in: model)
        search(model, "100 eur in usd")
        #expect(model.groups.contains { $0.id == "calculator" } == false)
    }

    @Test func remSizeIsASetting() throws {
        let calculator = calculator()
        let model = model([calculator])
        defer { model.stop() }
        calculator.setPixelsPerEm(10, in: model)
        search(model, "2 rem in px")
        #expect(model.selectedItem?.title == "20 px")
        #expect(CalculatorProvider.pixelsPerEm(in: model.store.database) == 10)
    }

    // MARK: Records

    @Test func historyRecordsRoundTripAndSkipIncompleteOnes() throws {
        var history = CalculatorHistory()
        history.add(try #require(CalculatorClock.evaluate("10 km in mi")), at: CalculatorClock.now)
        let records = history.records
        #expect(CalculatorHistory(records: records) == history)
        #expect(CalculatorHistory(records: records + [CalculatorHistoryRecord()]).entries.count == 1)
        let data = try JSONEncoder().encode(records)
        #expect(try JSONDecoder().decode([CalculatorHistoryRecord].self, from: data) == records)
    }
}
