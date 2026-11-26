import CoreText
import Foundation

/// A group in the Emoji & Symbols grid. The first nine follow Unicode's emoji groups;
/// the rest are text symbols.
enum EmojiCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case smileysEmotion = "smileys-emotion"
    case peopleBody = "people-body"
    case animalsNature = "animals-nature"
    case foodDrink = "food-drink"
    case travelPlaces = "travel-places"
    case activities
    case objects
    case symbols
    case flags
    case arrows
    case math
    case currency
    case punctuation
    case letterlike
    case keyboard
    case shapes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smileysEmotion: "Smileys & Emotion"
        case .peopleBody: "People & Body"
        case .animalsNature: "Animals & Nature"
        case .foodDrink: "Food & Drink"
        case .travelPlaces: "Travel & Places"
        case .activities: "Activities"
        case .objects: "Objects"
        case .symbols: "Symbols"
        case .flags: "Flags"
        case .arrows: "Arrows"
        case .math: "Math"
        case .currency: "Currency"
        case .punctuation: "Punctuation"
        case .letterlike: "Letterlike"
        case .keyboard: "Keyboard"
        case .shapes: "Shapes"
        }
    }

    /// Text symbols rather than emoji.
    var isTextSymbol: Bool {
        switch self {
        case .arrows, .math, .currency, .punctuation, .letterlike, .keyboard, .shapes: true
        default: false
        }
    }
}

/// The default skin tone for emoji that support Fitzpatrick modifiers.
enum SkinTone: Int, CaseIterable, Codable, Sendable, Identifiable {
    case none = 0, light, mediumLight, medium, mediumDark, dark

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: "Default"
        case .light: "Light"
        case .mediumLight: "Medium-Light"
        case .medium: "Medium"
        case .mediumDark: "Medium-Dark"
        case .dark: "Dark"
        }
    }

    /// A raised hand in this tone, for pickers.
    var sample: String {
        guard let modifier else { return "✋" }
        return "✋" + String(modifier)
    }

    var modifier: Character? {
        switch self {
        case .none: nil
        case .light: "\u{1F3FB}"
        case .mediumLight: "\u{1F3FC}"
        case .medium: "\u{1F3FD}"
        case .mediumDark: "\u{1F3FE}"
        case .dark: "\u{1F3FF}"
        }
    }
}

struct EmojiEntry: Identifiable, Hashable, Sendable {
    /// The base glyph, without a skin tone. Pins, usage and custom keywords key on it.
    var id: String { glyph }
    var glyph: String
    /// The Unicode short name, such as "thumbs up".
    var name: String
    var keywords: [String]
    var category: EmojiCategory
    /// Light to dark, when the emoji takes a skin tone.
    var skinTones: [String] = []

    var supportsSkinTones: Bool { skinTones.count == SkinTone.allCases.count - 1 }

    func glyph(for tone: SkinTone) -> String {
        guard tone != .none, supportsSkinTones else { return glyph }
        return skinTones[tone.rawValue - 1]
    }

    /// "Thumbs Up".
    var title: String {
        name.split(separator: " ").map { word in
            word.first.map { String($0).uppercased() + word.dropFirst() } ?? ""
        }.joined(separator: " ")
    }

    /// "U+1F44D", or every scalar for a sequence, for Copy Unicode.
    func codepoints(for tone: SkinTone = .none) -> String {
        glyph(for: tone).unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }
}

struct EmojiSection: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var entries: [EmojiEntry]
}

/// Frecency: each use adds one point, and points halve every `halfLife`, so recent,
/// frequent picks rise and old ones fade without a cutoff.
struct EmojiUsage: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        var score: Double
        var count: Int
        var lastUsed: Date
    }

    static let halfLife: TimeInterval = 14 * 86_400
    static let maximumRecords = 300

    private(set) var records: [String: Record] = [:]

    init(records: [String: Record] = [:]) {
        self.records = records
    }

    mutating func record(_ id: String, at date: Date) {
        let previous = records[id]
        let decayed = previous.map { Self.decay($0.score, from: $0.lastUsed, to: date) } ?? 0
        records[id] = Record(score: decayed + 1, count: (previous?.count ?? 0) + 1, lastUsed: max(date, previous?.lastUsed ?? date))
        if records.count > Self.maximumRecords { prune(keeping: Self.maximumRecords, at: date) }
    }

    mutating func forget(_ id: String) {
        records[id] = nil
    }

    func score(for id: String, at date: Date) -> Double {
        guard let record = records[id] else { return 0 }
        return Self.decay(record.score, from: record.lastUsed, to: date)
    }

    /// The most used ids, highest frecency first; ties go to the most recent.
    func ranked(at date: Date, limit: Int) -> [String] {
        let scored: [(id: String, score: Double, lastUsed: Date)] = records.map { id, record in
            (id, score(for: id, at: date), record.lastUsed)
        }
        let sorted = scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed }
            return a.id < b.id
        }
        return sorted.prefix(limit).map(\.id)
    }

    mutating func prune(keeping count: Int, at date: Date) {
        let kept = Set(ranked(at: date, limit: count))
        records = records.filter { kept.contains($0.key) }
    }

    private static func decay(_ score: Double, from start: Date, to end: Date) -> Double {
        let elapsed = max(0, end.timeIntervalSince(start))
        return score * pow(0.5, elapsed / halfLife)
    }
}

/// Everything a person changes about the emoji picker. A value type; the library persists it.
struct EmojiPreferences: Codable, Equatable, Sendable {
    /// Pinned emoji, in the order they show at the top of the grid.
    var pinned: [String] = []
    /// Extra search words per emoji id.
    var customKeywords: [String: [String]] = [:]
    var usage = EmojiUsage()
    var defaultSkinTone: SkinTone = .none
    var columns: Int = GridColumns.defaultCount

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try container.decodeIfPresent([String].self, forKey: .pinned) ?? []
        customKeywords = try container.decodeIfPresent([String: [String]].self, forKey: .customKeywords) ?? [:]
        usage = try container.decodeIfPresent(EmojiUsage.self, forKey: .usage) ?? EmojiUsage()
        defaultSkinTone = (try? container.decodeIfPresent(SkinTone.self, forKey: .defaultSkinTone)) ?? .none
        columns = GridColumns.clamped(try container.decodeIfPresent(Int.self, forKey: .columns) ?? GridColumns.defaultCount)
    }

    /// Preferences from `LibraryDatabase.emojiUsage` and two settings kept elsewhere.
    init(records: [EmojiUsageRecord], defaultSkinTone: SkinTone = .none, columns: Int = GridColumns.defaultCount) {
        var usage: [String: EmojiUsage.Record] = [:]
        for record in records {
            if let score = record.score, let lastUsed = record.lastUsed, score.isFinite, score > 0 {
                usage[record.id] = EmojiUsage.Record(score: score, count: record.count ?? 1, lastUsed: lastUsed)
            }
            if let keywords = record.keywords, !keywords.isEmpty { customKeywords[record.id] = keywords }
        }
        self.usage = EmojiUsage(records: usage)
        pinned = records.filter { $0.pinOrder != nil }.sorted { ($0.pinOrder ?? 0) < ($1.pinOrder ?? 0) }.map(\.id)
        self.defaultSkinTone = defaultSkinTone
        self.columns = GridColumns.clamped(columns)
    }

    /// One record per emoji with usage, a pin or custom keywords, sorted by emoji.
    var records: [EmojiUsageRecord] {
        let ids = Set(usage.records.keys).union(pinned).union(customKeywords.keys)
        return ids.sorted().map { id in
            let use = usage.records[id]
            return EmojiUsageRecord(
                id: id, score: use?.score, count: use?.count, lastUsed: use?.lastUsed,
                pinOrder: pinned.firstIndex(of: id), keywords: customKeywords[id])
        }
    }

    func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    mutating func togglePin(_ id: String) {
        if let index = pinned.firstIndex(of: id) {
            pinned.remove(at: index)
        } else {
            pinned.append(id)
        }
    }

    /// Replaces an emoji's custom keywords. Words are trimmed, lowercased and deduplicated.
    mutating func setKeywords(_ keywords: [String], for id: String) {
        var seen = Set<String>()
        let cleaned = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        customKeywords[id] = cleaned.isEmpty ? nil : cleaned
    }

    mutating func recordUse(_ id: String, at date: Date) {
        usage.record(id, at: date)
    }
}

/// The bundled emoji and symbol catalog, generated from Unicode data by
/// scripts/generate-emoji-data.py.
struct EmojiCatalog: Sendable {
    let entries: [EmojiEntry]
    /// Which Unicode data produced the catalog.
    let source: String
    private let index: [String: Int]
    private let fields: [SearchFields]

    private struct SearchFields: Sendable {
        var name: String
        var nameWords: [String]
        /// Whole keywords, some of them phrases ("light bulb").
        var keywords: [String]
        /// Every word of every keyword, for multiword and prefix matches.
        var keywordWords: [String]
        var categoryWords: [String]
    }

    private struct File: Decodable {
        struct Category: Decodable {
            var id: String
            var items: [Item]
        }

        struct Item: Decodable {
            var e: String
            var n: String
            var k: [String]?
            var t: [String]?
        }

        var source: String
        var categories: [Category]
    }

    /// Reads the generated JSON. `isRenderable` drops emoji this Mac can't draw yet.
    init(data: Data, isRenderable: (String) -> Bool = { _ in true }) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        var entries: [EmojiEntry] = []
        for category in file.categories {
            guard let kind = EmojiCategory(rawValue: category.id) else { continue }
            for item in category.items where kind.isTextSymbol || isRenderable(item.e) {
                entries.append(
                    EmojiEntry(glyph: item.e, name: item.n, keywords: item.k ?? [], category: kind, skinTones: item.t ?? []))
            }
        }
        self.init(entries: entries, source: file.source)
    }

    init(entries: [EmojiEntry], source: String = "") {
        var unique: [EmojiEntry] = []
        var index: [String: Int] = [:]
        for entry in entries where index[entry.glyph] == nil {
            index[entry.glyph] = unique.count
            for variant in entry.skinTones where index[variant] == nil { index[variant] = unique.count }
            unique.append(entry)
        }
        self.entries = unique
        self.source = source
        self.index = index
        fields = unique.map { entry in
            let name = Self.fold(entry.name)
            let keywords = entry.keywords.map(Self.fold)
            return SearchFields(
                name: name, nameWords: Self.words(name), keywords: keywords,
                keywordWords: Array(Set(keywords.flatMap(Self.words))),
                categoryWords: Self.words(Self.fold(entry.category.title)))
        }
    }

    /// The catalog shipped with the app, loaded once.
    static let bundled: EmojiCatalog = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "EmojiCatalog", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let catalog = try? EmojiCatalog(data: data, isRenderable: EmojiGlyphSupport.isRenderable)
        else { return EmojiCatalog(entries: []) }
        return catalog
    }()

    /// The entry for a base glyph or any of its skin-tone variants.
    func entry(for glyph: String) -> EmojiEntry? {
        index[glyph].map { entries[$0] }
    }

    func entries(in category: EmojiCategory) -> [EmojiEntry] {
        entries.filter { $0.category == category }
    }

    /// Matches by name, Unicode keywords, custom keywords and category. Every query word
    /// must match something. Pinned matches come first, then by match quality with
    /// frecency breaking near-ties, then catalog order.
    func search(
        _ query: String, preferences: EmojiPreferences = EmojiPreferences(), category: EmojiCategory? = nil,
        now: Date = Date()
    ) -> [EmojiEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = entry(for: trimmed) { return [exact] }
        let folded = Self.fold(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
        let terms = folded.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let custom = preferences.customKeywords.mapValues { $0.map(Self.fold) }
        var scored: [(entry: EmojiEntry, pinned: Bool, score: Double, order: Int)] = []
        for (position, entry) in entries.enumerated() where category == nil || entry.category == category {
            guard let match = Self.score(fields[position], custom: custom[entry.id] ?? [], terms: terms, phrase: folded)
            else { continue }
            let usage = min(preferences.usage.score(for: entry.id, at: now), 10) * 15
            scored.append((entry, preferences.isPinned(entry.id), Double(match) + usage, position))
        }
        return scored.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.order < $1.order
        }.map(\.entry)
    }

    /// The grid's sections. Searching shows one ranked section; browsing shows Pinned,
    /// Frequently Used, then each category.
    func sections(
        query: String, preferences: EmojiPreferences = EmojiPreferences(), category: EmojiCategory? = nil,
        frequentLimit: Int = 16, now: Date = Date()
    ) -> [EmojiSection] {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let results = search(query, preferences: preferences, category: category, now: now)
            return results.isEmpty ? [] : [EmojiSection(id: "results", title: "Results", entries: results)]
        }
        var sections: [EmojiSection] = []
        let included: (EmojiEntry) -> Bool = { category == nil || $0.category == category }
        let pinned = preferences.pinned.compactMap { entry(for: $0) }.filter(included)
        if !pinned.isEmpty { sections.append(EmojiSection(id: "pinned", title: "Pinned", entries: pinned)) }
        let pinnedIDs = Set(pinned.map(\.id))
        let frequent = preferences.usage.ranked(at: now, limit: frequentLimit + pinnedIDs.count)
            .compactMap { entry(for: $0) }.filter { included($0) && !pinnedIDs.contains($0.id) }.prefix(frequentLimit)
        if !frequent.isEmpty {
            sections.append(EmojiSection(id: "frequent", title: "Frequently Used", entries: Array(frequent)))
        }
        for kind in EmojiCategory.allCases where category == nil || kind == category {
            let members = entries(in: kind)
            if !members.isEmpty { sections.append(EmojiSection(id: kind.rawValue, title: kind.title, entries: members)) }
        }
        return sections
    }

    /// Whole-phrase matches score first, so a saved keyword such as "ship it" finds its
    /// emoji; then each query word must match a word of the name, a keyword or a custom
    /// keyword, exactly or as a prefix.
    private static func score(_ fields: SearchFields, custom: [String], terms: [String], phrase: String) -> Int? {
        var total = fields.name == phrase ? 1_000 : 0
        if custom.contains(phrase) {
            total += 900
        } else if terms.count > 1, custom.contains(where: { $0.hasPrefix(phrase) }) {
            total += 600
        }
        if terms.count > 1, fields.keywords.contains(phrase) { total += 300 }
        let customWords = custom.flatMap(words)
        for term in terms {
            var best = 0
            if fields.name.hasPrefix(term) { best = max(best, 400) }
            if fields.nameWords.contains(term) {
                best = max(best, 350)
            } else if fields.nameWords.contains(where: { $0.hasPrefix(term) }) {
                best = max(best, 250)
            }
            if custom.contains(term) || customWords.contains(term) {
                best = max(best, 380)
            } else if custom.contains(where: { $0.hasPrefix(term) }) || customWords.contains(where: { $0.hasPrefix(term) }) {
                best = max(best, 300)
            }
            if fields.keywords.contains(term) || fields.keywordWords.contains(term) {
                best = max(best, 200)
            } else if fields.keywordWords.contains(where: { $0.hasPrefix(term) }) {
                best = max(best, 120)
            }
            if term.count >= 3 {
                if fields.name.contains(term) { best = max(best, 60) }
                if fields.categoryWords.contains(where: { $0.hasPrefix(term) }) { best = max(best, 40) }
            }
            guard best > 0 else { return nil }
            total += best
        }
        return total
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
    }

    private static func words(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "+") }.map(String.init)
    }
}

private final class BundleToken {}

/// Whether Apple Color Emoji can draw a glyph, so emoji newer than this macOS are hidden.
enum EmojiGlyphSupport {
    static func isRenderable(_ glyph: String) -> Bool {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 16, nil)
        // Without the emoji font there's nothing to check against; keep everything.
        guard CTFontCopyPostScriptName(font) as String == "AppleColorEmoji" else { return true }
        for scalar in glyph.unicodeScalars where needsGlyph(scalar) {
            let units = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) else { return false }
        }
        return true
    }

    /// Joiners, selectors, tags, modifiers and ASCII ride along with a base glyph.
    private static func needsGlyph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x7F, 0x200D, 0xFE0E, 0xFE0F, 0x20E3, 0x1F3FB...0x1F3FF, 0xE0020...0xE007F: false
        default: true
        }
    }
}
