import Foundation
import Testing

@testable import OpenRay

/// Loads test fixtures from the test bundle, or from the source tree beside this file.
enum TestFixture {
    private final class Token {}

    static func data(_ name: String, _ ext: String) throws -> Data {
        if let url = Bundle(for: Token.self).url(forResource: name, withExtension: ext) {
            return try Data(contentsOf: url)
        }
        let source = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures").appending(path: "\(name).\(ext)")
        return try Data(contentsOf: source)
    }
}

/// Answers every request with fixed data and records nothing beyond the call count.
private struct FixtureLoader: HTTPDataLoading {
    var data: Data
    var status = 200
    let calls = CallCount()

    func data(from url: URL) async throws -> (Data, URLResponse) {
        await calls.increment()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }
}

actor CallCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct FakeRateProvider: CurrencyRateProvider {
    var result: Result<CurrencyRateTable, CurrencyRateError>
    let calls = CallCount()

    func fetchRates() async throws -> CurrencyRateTable {
        await calls.increment()
        return try result.get()
    }
}

struct CurrencyRatesTests {
    private typealias Clock = CalculatorClock

    static func fixtureRates(fetchedAt: Date = CalculatorClock.now) throws -> CurrencyRateTable {
        try ECBRateProvider.parse(TestFixture.data("ecb-eurofxref-fixture", "xml"), fetchedAt: fetchedAt)
    }

    private func context(locale: Locale = Locale(identifier: "en_US_POSIX")) throws -> CalculatorContext {
        Clock.context(locale: locale, rates: try Self.fixtureRates())
    }

    @Test func parsesTheECBDailyFile() throws {
        let table = try Self.fixtureRates()
        #expect(table.base == "EUR")
        #expect(table.publishedOn == "2026-11-25")
        #expect(table.source == "ECB")
        #expect(table.rates.count == 12)
        #expect(table.rate(for: "usd") == 1.05)
        #expect(table.rate(for: "EUR") == 1)
        #expect(table.publishedLabel(locale: Locale(identifier: "en_US_POSIX")) == "Nov 25, 2026")
    }

    @Test func rejectsUnreadableFiles() {
        #expect(throws: CurrencyRateError.unreadable) {
            try ECBRateProvider.parse(Data("<html>Maintenance</html>".utf8), fetchedAt: Clock.now)
        }
    }

    @Test(arguments: [
        ("100 eur in usd", "105.00 USD", "105.00"),
        ("100 usd in eur", "95.24 EUR", "95.24"),
        ("100 USD to EUR", "95.24 EUR", "95.24"),
        ("€20 to $", "21.00 USD", "21.00"),
        ("20€ in $", "21.00 USD", "21.00"),
        ("$100 in gbp", "80.00 GBP", "80.00"),
        ("100 eur in jpy", "16000 JPY", "16000"),
        ("1000 jpy in eur", "6.25 EUR", "6.25"),
        ("10k usd in eur", "9523.81 EUR", "9523.81"),
        ("usd 50 in chf", "44.29 CHF", "44.29"),
        ("100usd in eur", "95.24 EUR", "95.24"),
        ("100 dollars in euros", "95.24 EUR", "95.24"),
        ("100 pounds in eur", "119.05 EUR", "119.05"),
        ("50 zl to eur", "11.76 EUR", "11.76"),
        ("(10 + 10) eur in usd", "21.00 USD", "21.00"),
    ])
    func convertsCurrencies(input: String, result: String, value: String) throws {
        let calculation = try #require(Calculator.evaluate(input, context: try context()), "\(input)")
        #expect(calculation.result == result)
        #expect(calculation.value == value)
        #expect(calculation.kind == .currency)
    }

    @Test func currencyResultsNameTheRateDate() throws {
        let calculation = try #require(Calculator.evaluate("100 eur in usd", context: try context()))
        #expect(calculation.detail == "Currency · ECB rate for Nov 25, 2026 · Return to copy")
        #expect(calculation.swapQuery == "100 USD in EUR")
        #expect(calculation.conversion?.source.name == "Euro")
        #expect(calculation.conversion?.target.name == "US Dollar")
        #expect(calculation.conversion?.related.map(\.symbol) == ["GBP", "JPY", "CHF", "CAD"])
        #expect(calculation.conversion?.related.first?.value == "84.00")
        #expect(Calculator.swapped(calculation, context: try context())?.result == "95.24 EUR")
    }

    @Test func aLoneAmountConvertsToTheLocalCurrency() throws {
        let british = try context(locale: Locale(identifier: "en_GB"))
        #expect(Calculator.evaluate("100 USD", context: british)?.result == "80.00 GBP")
        #expect(Calculator.evaluate("$100", context: british)?.result == "80.00 GBP")
        #expect(Calculator.evaluate("100 dollars", context: british)?.result == "80.00 GBP")
        // The local currency itself converts to euros.
        #expect(Calculator.evaluate("£84", context: british)?.result == "100.00 EUR")
        // A lowercase three-letter word alone reads as prose, not Turkish lira.
        #expect(Calculator.evaluate("5 try", context: british) == nil)
    }

    @Test func withoutRatesCurrencyStaysUnsupported() {
        #expect(Calculator.issue(for: "100 usd in eur", context: Clock.context()) == .unsupportedCurrencyConversion)
        #expect(Calculator.issue(for: "€20 to $", context: Clock.context()) == .unsupportedCurrencyConversion)
        #expect(Calculator.evaluate("100 USD", context: Clock.context()) == nil)
    }

    @Test func unknownCurrenciesAreIssues() throws {
        #expect(Calculator.issue(for: "100 usd in aed", context: try context()) == .unknownCurrency)
        #expect(Calculator.searchIssue(for: "100 usd in aed", context: try context()) == .unknownCurrency)
    }

    @Test func unitsWinOverCurrencyCodes() throws {
        // CUP is also the Cuban peso.
        #expect(Calculator.evaluate("1 cup in ml", context: try context())?.result == "236.588 mL")
        #expect(Calculator.evaluate("10 lb in kg", context: try context())?.kind == .conversion)
    }

    @Test(arguments: [
        ("100 usd in eur", "100", "USD", "EUR"), ("€20 to $", "20", "EUR", "USD"), ("$ 5 in £", "5", "USD", "GBP"),
        ("1.5k eur to usd", "1.5k", "EUR", "USD"), ("100 USD", "100", "USD", nil),
    ])
    func parsesMoneyPhrases(input: String, amount: String, source: String, target: String?) {
        #expect(CurrencyConversion.parse(input) == .init(amount: amount, source: source, target: target))
    }

    @Test(arguments: ["2 days to go", "100 + 5", "hello in euros", "100 km in mi", "5 all"])
    func nonMoneyIsNotParsed(_ input: String) {
        #expect(CurrencyConversion.parse(input) == nil)
    }

    @Test func providerFetchesThroughTheLoader() async throws {
        let loader = FixtureLoader(data: try TestFixture.data("ecb-eurofxref-fixture", "xml"))
        let provider = ECBRateProvider(loader: loader, now: { CalculatorClock.now })
        let table = try await provider.fetchRates()
        #expect(table.fetchedAt == Clock.now)
        #expect(table.rate(for: "GBP") == 0.84)
        #expect(await loader.calls.value == 1)

        let failing = ECBRateProvider(loader: FixtureLoader(data: Data(), status: 503))
        await #expect(throws: CurrencyRateError.badResponse(503)) { try await failing.fetchRates() }
    }

    @Test func cacheRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "openray-currency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CurrencyRateCache(fileURL: directory.appending(path: "currency-rates.json"))
        #expect(cache.load() == nil)
        let table = try Self.fixtureRates()
        try cache.save(table)
        #expect(cache.load() == table)
    }

    @MainActor @Test func storeNeverFetchesWhileDisabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "openray-currency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CurrencyRateCache(fileURL: directory.appending(path: "rates.json"))
        try cache.save(try Self.fixtureRates(fetchedAt: Clock.now.addingTimeInterval(-86_400 * 3)))
        let provider = FakeRateProvider(result: .success(try Self.fixtureRates()))
        let store = CurrencyRateStore(provider: provider, cache: cache, now: { CalculatorClock.now })
        #expect(store.isEnabled == false)
        #expect(store.table != nil)
        #expect(store.activeRates == nil)
        await store.refreshIfStale()
        await store.refresh()
        #expect(await provider.calls.value == 0)
    }

    @MainActor @Test func storeRefreshesStaleRatesOnceEnabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "openray-currency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CurrencyRateCache(fileURL: directory.appending(path: "rates.json"))
        let fresh = try Self.fixtureRates(fetchedAt: Clock.now)
        let provider = FakeRateProvider(result: .success(fresh))
        let store = CurrencyRateStore(isEnabled: true, provider: provider, cache: cache, now: { CalculatorClock.now })
        #expect(store.isStale)
        await store.refreshIfStale()
        #expect(store.activeRates == fresh)
        #expect(cache.load() == fresh)
        // Fresh rates don't fetch again until they're 12 hours old.
        await store.refreshIfStale()
        #expect(await provider.calls.value == 1)
        // Refresh Currencies always fetches.
        await store.refresh()
        #expect(await provider.calls.value == 2)
    }

    @MainActor @Test func failedRefreshKeepsTheLastRates() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "openray-currency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CurrencyRateCache(fileURL: directory.appending(path: "rates.json"))
        let old = try Self.fixtureRates(fetchedAt: Clock.now.addingTimeInterval(-86_400))
        try cache.save(old)
        let provider = FakeRateProvider(result: .failure(.badResponse(500)))
        let store = CurrencyRateStore(isEnabled: true, provider: provider, cache: cache, now: { CalculatorClock.now })
        await store.refreshIfStale()
        #expect(store.table == old)
        #expect(store.lastError == "The rate source answered with HTTP 500.")
        #expect(store.isRefreshing == false)
    }
}
