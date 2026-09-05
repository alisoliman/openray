import Foundation

enum SearchMatcher {
    /// Exact matches outrank prefixes, word prefixes, substrings, then ordered fuzzy matches.
    static func score(_ query: String, in value: String) -> Int? {
        let query = normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalize(value)
        guard !query.isEmpty else { return 0 }
        if value == query { return 1_000 }
        if value.hasPrefix(query) { return 850 - min(value.count - query.count, 100) }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let words = value.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var total = 0
        for term in terms {
            if words.contains(term) {
                total += 700
            } else if words.contains(where: { $0.hasPrefix(term) }) {
                total += 600
            } else if value.contains(term) {
                total += 450
            } else {
                var cursor = value.startIndex
                var gaps = 0
                for character in term {
                    guard let match = value[cursor...].firstIndex(of: character) else { return nil }
                    gaps += value.distance(from: cursor, to: match)
                    cursor = value.index(after: match)
                }
                total += max(50, 250 - gaps * 4)
            }
        }
        return total / max(terms.count, 1)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
