import Foundation
import Observation

/// Daily reference rates against one base currency, as a source published them.
struct CurrencyRateTable: Codable, Equatable, Sendable {
    /// The currency every rate is quoted against. ECB rates are per euro.
    var base: String
    /// The day the rates are for, as published ("2026-11-25").
    var publishedOn: String
    /// When OpenRay downloaded them.
    var fetchedAt: Date
    /// Units of each currency per one `base`. The base itself is 1.
    var rates: [String: Double]
    var source: String

    init(base: String = "EUR", publishedOn: String, fetchedAt: Date, rates: [String: Double], source: String = "ECB") {
        self.base = base
        self.publishedOn = publishedOn
        self.fetchedAt = fetchedAt
        var rates = rates
        rates[base] = 1
        self.rates = rates
        self.source = source
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            base: try container.decodeIfPresent(String.self, forKey: .base) ?? "EUR",
            publishedOn: try container.decode(String.self, forKey: .publishedOn),
            fetchedAt: try container.decode(Date.self, forKey: .fetchedAt),
            rates: try container.decode([String: Double].self, forKey: .rates),
            source: try container.decodeIfPresent(String.self, forKey: .source) ?? "ECB")
    }

    var codes: [String] { rates.keys.sorted() }

    func rate(for code: String) -> Double? {
        rates[code.uppercased()]
    }

    func convert(_ amount: Double, from source: String, to target: String) -> Double? {
        guard let from = rate(for: source), let to = rate(for: target), from > 0 else { return nil }
        return amount / from * to
    }

    /// "Nov 25, 2026" for the published day, never shifted by the local time zone.
    func publishedLabel(locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        calendar.timeZone = utc
        let parts = publishedOn.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return publishedOn }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: utc)
        style = style.month(.abbreviated).day().year()
        return CalendarFormat.clean(date.formatted(style))
    }
}

// MARK: - Names and symbols

enum CurrencyCatalog {
    /// The ISO code a word, code or symbol names, such as "usd", "$", "euros" or "zł".
    static func code(for word: String) -> String? {
        let key = word.lowercased().trimmingCharacters(in: .whitespaces)
        if let code = aliases[key] { return code }
        if key.count == 3, key.allSatisfy(\.isLetter), isoCodes.contains(key.uppercased()) { return key.uppercased() }
        return nil
    }

    /// Words that only name a currency next to another currency: "100 pounds in eur".
    static func contextualCode(for word: String) -> String? {
        ["pound": "GBP", "pounds": "GBP", "quid": "GBP", "franc": "CHF", "francs": "CHF", "pesos": "MXN", "peso": "MXN"][
            word.lowercased()]
    }

    /// Whether a word looks like money, for explaining why a conversion failed.
    static func isCurrencyWord(_ word: String) -> Bool {
        code(for: word) != nil || ["dollar", "dollars", "euro", "euros", "yen"].contains(word.lowercased())
    }

    static func name(for code: String) -> String {
        Locale(identifier: "en_US").localizedString(forCurrencyCode: code) ?? code
    }

    /// Minor-unit digits: 2 for USD, 0 for JPY.
    static func fractionDigits(for code: String) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.currencyCode = code
        return formatter.maximumFractionDigits
    }

    /// Symbols that can stand before or after an amount, longest first.
    static let symbols: [(String, String)] = [
        ("us$", "USD"), ("ca$", "CAD"), ("au$", "AUD"), ("nz$", "NZD"), ("hk$", "HKD"), ("r$", "BRL"), ("c$", "CAD"),
        ("a$", "AUD"), ("s$", "SGD"), ("zł", "PLN"), ("kč", "CZK"), ("$", "USD"), ("€", "EUR"), ("£", "GBP"),
        ("¥", "JPY"), ("₹", "INR"), ("₩", "KRW"), ("₺", "TRY"), ("₪", "ILS"), ("₱", "PHP"), ("฿", "THB"), ("₽", "RUB"),
        ("₫", "VND"), ("₦", "NGN"), ("₴", "UAH"),
    ]

    private static let isoCodes = Set(Locale.commonISOCurrencyCodes)

    private static let aliases: [String: String] = {
        var table = Dictionary(symbols, uniquingKeysWith: { first, _ in first })
        let names: [String: [String]] = [
            "USD": ["dollar", "dollars", "us dollar", "us dollars", "buck", "bucks"],
            "EUR": ["euro", "euros"],
            "GBP": ["sterling", "pound sterling", "pounds sterling", "british pound", "british pounds"],
            "JPY": ["yen", "japanese yen"],
            "CNY": ["yuan", "rmb", "renminbi"],
            "INR": ["rupee", "rupees", "indian rupee", "indian rupees"],
            "KRW": ["won", "korean won"],
            "CHF": ["swiss franc", "swiss francs"],
            "CAD": ["canadian dollar", "canadian dollars"],
            "AUD": ["australian dollar", "australian dollars"],
            "NZD": ["new zealand dollar", "new zealand dollars"],
            "HKD": ["hong kong dollar", "hong kong dollars"],
            "SGD": ["singapore dollar", "singapore dollars"],
            "MXN": ["mexican peso", "mexican pesos"],
            "BRL": ["real", "reais", "brazilian real"],
            "IDR": ["rupiah"],
            "PLN": ["zloty", "zlotys", "złoty", "zl"],
            "SEK": ["krona", "kronor", "swedish krona"],
            "NOK": ["krone", "kroner", "norwegian krone"],
            "DKK": ["danish krone", "danish kroner"],
            "CZK": ["koruna", "czech koruna"],
            "HUF": ["forint", "forints"],
            "TRY": ["lira", "turkish lira"],
            "ZAR": ["rand"],
            "MYR": ["ringgit"],
            "THB": ["baht"],
            "ILS": ["shekel", "shekels"],
            "ISK": ["icelandic krona"],
            "PHP": ["philippine peso", "philippine pesos"],
            "RON": ["leu", "lei"],
        ]
        for (code, words) in names {
            for word in words { table[word] = code }
        }
        return table
    }()
}

// MARK: - Conversion

/// "100 usd in eur", "€20 to $", "$1.5k in gbp", and "100 usd" into the local currency.
enum CurrencyConversion {
    struct Request: Equatable, Sendable {
        var amount: String
        var source: String
        var target: String?
    }

    static func evaluate(_ input: String, context: CalculatorContext) throws -> Calculation? {
        guard let request = parse(input) else { return nil }
        guard let table = context.currencyRates else {
            if request.target == nil { return nil }
            throw Calculator.Issue.unsupportedCurrencyConversion
        }
        let fallback = context.locale.currency?.identifier ?? "USD"
        let target = request.target ?? (fallback == request.source ? (request.source == "EUR" ? "USD" : "EUR") : fallback)
        let amount = try Calculator.parse(scaled(request.amount))
        guard let converted = table.convert(amount, from: request.source, to: target) else {
            if request.target == nil { return nil }
            throw Calculator.Issue.unknownCurrency
        }
        guard converted.isFinite else { throw Calculator.Issue.resultOutOfRange }
        let digits = CurrencyCatalog.fractionDigits(for: target)
        let shown = Calculator.format(converted, fractionDigits: digits)
        let related = ["USD", "EUR", "GBP", "JPY", "CHF", "CAD", "AUD", "CNY"]
            .filter { $0 != request.source && $0 != target }
            .compactMap { code -> Calculation.Quantity? in
                guard let value = table.convert(amount, from: request.source, to: code) else { return nil }
                let digits = CurrencyCatalog.fractionDigits(for: code)
                return .init(
                    value: value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(digits))),
                    symbol: code, name: CurrencyCatalog.name(for: code),
                    copyValue: Calculator.format(value, fractionDigits: digits))
            }
            .prefix(4)
        let sourceDigits = CurrencyCatalog.fractionDigits(for: request.source)
        return Calculation(
            expression: input, result: "\(shown) \(target)",
            detail: "Currency · \(table.source) rate for \(table.publishedLabel(locale: context.locale)) · Return to copy",
            value: shown,
            conversion: .init(
                source: .init(
                    value: Calculator.format(amount, fractionDigits: sourceDigits), symbol: request.source,
                    name: CurrencyCatalog.name(for: request.source)),
                target: .init(value: shown, symbol: target, name: CurrencyCatalog.name(for: target)),
                related: Array(related)),
            kind: .currency, swapQuery: "\(request.amount) \(target) in \(request.source)")
    }

    /// The amount and currencies in a query, or nil when it doesn't name money.
    static func parse(_ input: String) -> Request? {
        let text = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard text.count <= 80 else { return nil }
        for split in Calculator.conversionSplits(of: text) where !split.right.isEmpty {
            if let explicit = CurrencyCatalog.code(for: split.right), let money = money(split.left, contextual: true) {
                return Request(amount: money.amount, source: money.code, target: explicit)
            }
            if let money = money(split.left, contextual: false), let target = CurrencyCatalog.contextualCode(for: split.right)
            {
                return Request(amount: money.amount, source: money.code, target: target)
            }
        }
        // Without a target, a lowercase three-letter word ("try", "all") is too likely to be prose.
        guard !text.contains(" in "), !text.contains(" to "), let money = money(text, contextual: false),
            money.isUnambiguous || input.contains(money.code)
        else { return nil }
        return Request(amount: money.amount, source: money.code, target: nil)
    }

    /// "100 usd", "usd 100", "$100", "100$", "€ 20", "10k eur". A symbol or a currency's
    /// name is unambiguous; a bare three-letter code isn't.
    private static func money(_ text: String, contextual: Bool) -> (amount: String, code: String, isUnambiguous: Bool)? {
        let text = text.trimmingCharacters(in: .whitespaces)
        for (symbol, code) in CurrencyCatalog.symbols {
            if text.hasPrefix(symbol), let amount = amount(String(text.dropFirst(symbol.count))) {
                return (amount, code, true)
            }
            if text.hasSuffix(symbol), let amount = amount(String(text.dropLast(symbol.count))) {
                return (amount, code, true)
            }
        }
        let words = text.split(separator: " ").map(String.init)
        if words.count >= 2 {
            for count in (1...min(3, words.count - 1)).reversed() {
                let suffix = words.suffix(count).joined(separator: " ")
                if let code = CurrencyCatalog.code(for: suffix) ?? (contextual ? CurrencyCatalog.contextualCode(for: suffix) : nil),
                    let amount = amount(words.dropLast(count).joined(separator: " "))
                {
                    return (amount, code, suffix.count != 3)
                }
                let prefix = words.prefix(count).joined(separator: " ")
                if let code = CurrencyCatalog.code(for: prefix), let amount = amount(words.dropFirst(count).joined(separator: " ")) {
                    return (amount, code, prefix.count != 3)
                }
            }
        }
        // "100usd", "usd100"
        if let groups = attached.groups(in: text), let number = groups[1], let letters = groups[2],
            let code = CurrencyCatalog.code(for: letters), letters.count == 3, let amount = amount(number)
        {
            return (amount, code, false)
        }
        if let groups = leading.groups(in: text), let letters = groups[1], let number = groups[2],
            letters.count == 3, let code = CurrencyCatalog.code(for: letters), let amount = amount(number)
        {
            return (amount, code, false)
        }
        return nil
    }

    /// An amount: digits, decimals and a k, m or bn multiplier, or a parenthesized expression.
    private static func amount(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.first?.isLetter == false, amountShape.groups(in: trimmed) != nil else {
            return nil
        }
        return trimmed
    }

    /// "1.5k" → "1.5*1000".
    private static func scaled(_ amount: String) -> String {
        let lower = amount.lowercased()
        for (suffix, factor) in [("bn", "1000000000"), ("k", "1000"), ("m", "1000000")] where lower.hasSuffix(suffix) {
            let number = lower.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            if Double(number) != nil { return "\(number)*\(factor)" }
        }
        return amount
    }

    private static let attached = CalculatorPattern(#"^([\d.,]+(?:k|m|bn)?)\s*([a-z]{3})$"#)
    private static let leading = CalculatorPattern(#"^([a-z]{3})\s*([\d.]+(?:k|m|bn)?)$"#)
    private static let amountShape = CalculatorPattern(#"^[\d.()+\-*/\s^%]+(?:k|m|bn)?$"#)
}

// MARK: - Fetching

/// Where currency rates come from. Only the opt-in daily fetch talks to the network.
protocol CurrencyRateProvider: Sendable {
    func fetchRates() async throws -> CurrencyRateTable
}

/// A network seam, so tests never reach the network.
protocol HTTPDataLoading: Sendable {
    func data(from url: URL) async throws -> (Data, URLResponse)
}

struct URLSessionDataLoader: HTTPDataLoading {
    private static let session = URLSession(configuration: .ephemeral)

    func data(from url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        return try await Self.session.data(for: request)
    }
}

enum CurrencyRateError: Error, Equatable, Sendable {
    case badResponse(Int)
    case unreadable

    var message: String {
        switch self {
        case .badResponse(let status): "The rate source answered with HTTP \(status)."
        case .unreadable: "The rate file couldn't be read."
        }
    }
}

/// The European Central Bank's daily euro reference rates: about 30 currencies,
/// published on working days around 16:00 CET.
struct ECBRateProvider: CurrencyRateProvider {
    static let dailyURL = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!

    var loader: any HTTPDataLoading = URLSessionDataLoader()
    var now: @Sendable () -> Date = { Date() }

    func fetchRates() async throws -> CurrencyRateTable {
        let (data, response) = try await loader.data(from: Self.dailyURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CurrencyRateError.badResponse(http.statusCode)
        }
        return try Self.parse(data, fetchedAt: now())
    }

    static func parse(_ data: Data, fetchedAt: Date) throws -> CurrencyRateTable {
        let reader = ECBRateReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), let day = reader.day, !reader.rates.isEmpty else { throw CurrencyRateError.unreadable }
        return CurrencyRateTable(base: "EUR", publishedOn: day, fetchedAt: fetchedAt, rates: reader.rates, source: "ECB")
    }
}

/// Reads `<Cube time="…">` and `<Cube currency="USD" rate="1.05"/>` elements.
private final class ECBRateReader: NSObject, XMLParserDelegate {
    var day: String?
    var rates: [String: Double] = [:]

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        guard elementName == "Cube" else { return }
        if let time = attributes["time"] { day = time }
        if let currency = attributes["currency"], let text = attributes["rate"], let rate = Double(text), rate > 0,
            currency.count == 3
        {
            rates[currency.uppercased()] = rate
        }
    }
}

/// The last downloaded rates, kept on disk so conversions work offline.
struct CurrencyRateCache: Sendable {
    var fileURL: URL

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "OpenRay", directoryHint: .isDirectory)
            .appending(path: "currency-rates.json")
    }

    func load() -> CurrencyRateTable? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CurrencyRateTable.self, from: data)
    }

    func save(_ table: CurrencyRateTable) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(table).write(to: fileURL, options: .atomic)
    }
}

/// Holds the rates the calculator uses. Off by default: while disabled it never
/// fetches and offers no rates, so currency stays unsupported.
@MainActor
@Observable
final class CurrencyRateStore {
    private(set) var table: CurrencyRateTable?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    var isEnabled: Bool

    /// Rates older than this refresh on the next use.
    static let maximumAge: TimeInterval = 12 * 3_600

    @ObservationIgnored private let provider: any CurrencyRateProvider
    @ObservationIgnored private let cache: CurrencyRateCache
    @ObservationIgnored private let now: @Sendable () -> Date

    init(
        isEnabled: Bool = false, provider: any CurrencyRateProvider = ECBRateProvider(),
        cache: CurrencyRateCache = CurrencyRateCache(fileURL: CurrencyRateCache.defaultURL),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.isEnabled = isEnabled
        self.provider = provider
        self.cache = cache
        self.now = now
        table = cache.load()
    }

    /// What calculations see: nothing while rates are off.
    var activeRates: CurrencyRateTable? { isEnabled ? table : nil }

    var isStale: Bool {
        guard let table else { return true }
        return now().timeIntervalSince(table.fetchedAt) > Self.maximumAge
    }

    /// Fetches once a day at most, and only while enabled.
    func refreshIfStale() async {
        guard isEnabled, isStale else { return }
        await refresh()
    }

    /// The Refresh Currencies action. Does nothing while rates are off.
    func refresh() async {
        guard isEnabled, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await provider.fetchRates()
            table = fresh
            lastError = nil
            try? cache.save(fresh)
        } catch let error as CurrencyRateError {
            lastError = error.message
        } catch {
            lastError = "Rates couldn't be refreshed. OpenRay keeps using the last saved rates."
        }
    }
}
