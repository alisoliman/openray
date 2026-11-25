import Foundation

enum SearchMatcher {
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")
    /// Note, snippet and clipboard bodies can run to 128 KB. Scoring reads a bounded
    /// window of them, so a keystroke never folds and splits whole bodies.
    private static let scoredHeadLength = 8_000
    /// The end is kept too: searchable text can close with metadata, such as a
    /// clipboard entry's source app.
    private static let scoredTailLength = 200

    /// Exact matches outrank prefixes, word prefixes, substrings, then ordered fuzzy matches.
    static func score(_ query: String, in value: String) -> Int? {
        let query = normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return 0 }
        let value = normalize(scoredWindow(of: value))
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
                // Fuzzy matches must begin at a word start, so “notes” doesn't match
                // letters scattered across “Epson Connect Printer Setup”.
                guard let first = term.first,
                    let start = value.indices.first(where: { index in
                        value[index] == first
                            && (index == value.startIndex
                                || !(value[value.index(before: index)].isLetter
                                    || value[value.index(before: index)].isNumber))
                    })
                else { return nil }
                var cursor = start
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

    /// Character offsets in `value` that a query matched, for bolding.
    /// Prefers whole-term matches at a word start, then any substring, then the fuzzy path.
    static func matchedOffsets(_ query: String, in value: String) -> Set<Int> {
        let characters = Array(value)
        guard !characters.isEmpty, characters.count <= 400 else { return [] }
        let folded = characters.map { normalize(String($0)) }
        var result = Set<Int>()
        for term in normalize(query).split(whereSeparator: \.isWhitespace) {
            let term = term.map { String($0) }
            guard !term.isEmpty else { continue }
            var best: Int?
            if folded.count >= term.count {
                for start in 0...(folded.count - term.count)
                where (0..<term.count).allSatisfy({ folded[start + $0] == term[$0] }) {
                    let boundary =
                        start == 0 || !(characters[start - 1].isLetter || characters[start - 1].isNumber)
                    if boundary {
                        best = start
                        break
                    }
                    if best == nil { best = start }
                }
            }
            if let best {
                result.formUnion(best..<(best + term.count))
                continue
            }
            var cursor = 0
            var hits: [Int] = []
            for character in term {
                guard let index = (cursor..<folded.count).first(where: { folded[$0] == character }) else {
                    hits = []
                    break
                }
                hits.append(index)
                cursor = index + 1
            }
            result.formUnion(hits)
        }
        return result
    }

    /// The part of `value` that scoring reads: the head, plus the tail of a long value.
    static func scoredWindow(of value: String) -> String {
        // The UTF-8 count is stored, so short values skip the character walk.
        guard value.utf8.count > scoredHeadLength else { return value }
        let head = value.prefix(scoredHeadLength)
        guard head.endIndex < value.endIndex else { return value }
        return String(head) + " " + String(value[head.endIndex...].suffix(scoredTailLength))
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldingLocale)
    }
}
