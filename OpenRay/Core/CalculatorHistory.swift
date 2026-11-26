import Foundation

/// Past calculations, newest first, for Show History. A value type: the library
/// persists it, and every change goes through `add`, `remove` or `prune`.
struct CalculatorHistory: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable, Identifiable {
        var id: UUID
        /// What was typed, such as "10 km in mi".
        var expression: String
        /// The answer as shown, such as "6.21371 mi".
        var result: String
        /// The answer Return copies, such as "6.21371192237".
        var value: String
        var kind: Calculation.Kind
        var date: Date

        init(id: UUID = UUID(), expression: String, result: String, value: String, kind: Calculation.Kind, date: Date) {
            self.id = id
            self.expression = expression
            self.result = result
            self.value = value
            self.kind = kind
            self.date = date
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            expression = try container.decode(String.self, forKey: .expression)
            result = try container.decode(String.self, forKey: .result)
            value = try container.decodeIfPresent(String.self, forKey: .value) ?? result
            kind = (try? container.decodeIfPresent(Calculation.Kind.self, forKey: .kind)) ?? .arithmetic
            date = try container.decode(Date.self, forKey: .date)
        }
    }

    static let defaultLimit = 200
    /// Entries older than three months fall out, like the calculator history people expect.
    static let retentionMonths = 3

    private(set) var entries: [Entry]
    var limit: Int

    init(entries: [Entry] = [], limit: Int = defaultLimit) {
        self.entries = entries
        self.limit = max(1, limit)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        limit = max(1, try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit)
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Records a calculation. Repeating an expression moves it to the top with its newest
    /// answer instead of adding a duplicate. Plain numbers, whose answer is the input, aren't kept.
    mutating func add(_ calculation: Calculation, at date: Date, id: UUID = UUID()) {
        let expression = calculation.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, Self.key(expression) != Self.key(calculation.result) else { return }
        let key = Self.key(expression)
        let existing = entries.firstIndex { Self.key($0.expression) == key }
        let keptID = existing.map { entries[$0].id } ?? id
        if let existing { entries.remove(at: existing) }
        entries.insert(
            Entry(
                id: keptID, expression: expression, result: calculation.result, value: calculation.value,
                kind: calculation.kind, date: date),
            at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// Drops entries older than the retention period, and any beyond the limit.
    mutating func prune(now: Date, calendar: Calendar = .autoupdatingCurrent) {
        if let cutoff = calendar.date(byAdding: .month, value: -Self.retentionMonths, to: now) {
            entries.removeAll { $0.date < cutoff }
        }
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    /// Entries whose expression or answer contains every word of the query.
    func matching(_ query: String) -> [Entry] {
        let words = Self.key(query).split(separator: " ")
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = Self.key(entry.expression + " " + entry.result)
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// The history in `LibraryDatabase.calculatorHistory`, which stores it newest first.
    /// Incomplete records are skipped.
    init(records: [CalculatorHistoryRecord], limit: Int = defaultLimit) {
        let entries = records.compactMap { record -> Entry? in
            guard let expression = record.expression, let result = record.result, let date = record.date else {
                return nil
            }
            return Entry(
                id: record.id, expression: expression, result: result, value: record.value ?? result,
                kind: record.kind.flatMap(Calculation.Kind.init(rawValue:)) ?? .arithmetic, date: date)
        }
        self.init(entries: entries, limit: limit)
    }

    /// The records to store, newest first.
    var records: [CalculatorHistoryRecord] {
        entries.map { entry in
            CalculatorHistoryRecord(
                id: entry.id, expression: entry.expression, result: entry.result, value: entry.value,
                kind: entry.kind.rawValue, date: entry.date)
        }
    }

    /// Case-, width- and spacing-insensitive, so "10 KM in mi" repeats "10 km  in mi".
    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
