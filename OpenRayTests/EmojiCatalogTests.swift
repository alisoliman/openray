import Foundation
import Testing

@testable import OpenRay

struct EmojiCatalogTests {
    private let catalog = EmojiCatalog.bundled
    private let now = CalculatorClock.now

    @Test func bundledCatalogLoadsEveryCategory() throws {
        #expect(catalog.entries.count > 2_500)
        #expect(catalog.source.contains("Unicode License V3"))
        for category in EmojiCategory.allCases {
            #expect(!catalog.entries(in: category).isEmpty, "\(category)")
        }
        #expect(catalog.entries(in: .arrows).contains { $0.glyph == "→" })
        #expect(catalog.entries(in: .math).contains { $0.glyph == "≠" })
        #expect(catalog.entries(in: .currency).contains { $0.glyph == "€" })
        #expect(catalog.entries(in: .punctuation).contains { $0.glyph == "…" })
        #expect(catalog.entries(in: .keyboard).contains { $0.glyph == "⌘" })
    }

    @Test func entriesCarryNamesKeywordsAndTones() throws {
        let thumbs = try #require(catalog.entry(for: "👍"))
        #expect(thumbs.name == "thumbs up")
        #expect(thumbs.title == "Thumbs Up")
        #expect(thumbs.category == .peopleBody)
        #expect(thumbs.keywords.contains("+1"))
        #expect(thumbs.supportsSkinTones)
        #expect(thumbs.glyph(for: .medium) == "👍🏽")
        #expect(thumbs.glyph(for: .none) == "👍")
        #expect(thumbs.codepoints(for: .dark) == "U+1F44D U+1F3FF")
        // A toned glyph finds its base entry.
        #expect(catalog.entry(for: "👍🏾")?.id == "👍")
        let grin = try #require(catalog.entry(for: "😀"))
        #expect(!grin.supportsSkinTones)
        #expect(grin.glyph(for: .dark) == "😀")
    }

    @Test(arguments: [
        ("thumbs up", "👍"), ("thumbs", "👍"), ("+1", "👍"), ("grinning face", "😀"), (":joy:", "😂"),
        ("red heart", "❤️"), ("flag germany", "🇩🇪"), ("pizza", "🍕"), ("not equal", "≠"), ("command", "⌘"),
        ("euro", "€"), ("ellipsis", "…"), ("pinata", "🪅"), ("🍕", "🍕"),
    ])
    func searchFindsByNameAndKeyword(query: String, expected: String) {
        let results = catalog.search(query, now: now)
        #expect(results.prefix(5).contains { $0.glyph == expected }, "\(query): \(results.prefix(5).map(\.glyph))")
    }

    @Test func everyQueryWordMustMatch() {
        let results = catalog.search("cat face", now: now)
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.name.contains("cat") || $0.keywords.contains { $0.hasPrefix("cat") } })
        #expect(catalog.search("zzqx", now: now).isEmpty)
        #expect(catalog.search("   ", now: now).isEmpty)
    }

    @Test func exactNamesRankFirst() {
        #expect(catalog.search("dog", now: now).first?.glyph == "🐕")
        #expect(catalog.search("fire", now: now).first?.glyph == "🔥")
    }

    @Test func categoryFilterNarrowsSearch() {
        let arrows = catalog.search("right arrow", category: .arrows, now: now)
        #expect(arrows.first?.glyph == "→")
        #expect(arrows.allSatisfy { $0.category == .arrows })
    }

    @Test func customKeywordsAreSearchable() {
        var preferences = EmojiPreferences()
        preferences.setKeywords([" LGTM ", "ship it", "lgtm", ""], for: "👍")
        #expect(preferences.customKeywords["👍"] == ["lgtm", "ship it"])
        #expect(catalog.search("lgtm", preferences: preferences, now: now).first?.glyph == "👍")
        #expect(catalog.search("lgtm", now: now).first?.glyph != "👍")
        preferences.setKeywords([], for: "👍")
        #expect(preferences.customKeywords["👍"] == nil)
    }

    @Test func pinsComeFirstThenFrecency() {
        var preferences = EmojiPreferences()
        let plain = catalog.search("heart", now: now)
        let blue = plain.firstIndex { $0.glyph == "💙" }
        for minutes in 0..<6 { preferences.recordUse("💙", at: now.addingTimeInterval(Double(-minutes * 60))) }
        let used = catalog.search("heart", preferences: preferences, now: now)
        let raised = used.firstIndex { $0.glyph == "💙" }
        #expect(raised != nil && blue != nil && raised! < blue!)
        preferences.togglePin("💔")
        #expect(catalog.search("heart", preferences: preferences, now: now).first?.glyph == "💔")
        preferences.togglePin("💔")
        #expect(preferences.pinned.isEmpty)
    }

    @Test func browsingShowsPinnedFrequentThenCategories() {
        var preferences = EmojiPreferences()
        preferences.togglePin("🔥")
        preferences.recordUse("🔥", at: now)
        preferences.recordUse("🍕", at: now)
        let sections = catalog.sections(query: "", preferences: preferences, now: now)
        #expect(sections.map(\.id).prefix(3) == ["pinned", "frequent", "smileys-emotion"])
        #expect(sections[0].entries.map(\.glyph) == ["🔥"])
        // Pinned emoji don't repeat under Frequently Used.
        #expect(sections[1].entries.map(\.glyph) == ["🍕"])
        #expect(sections.last?.id == "shapes")

        let searching = catalog.sections(query: "pizza", preferences: preferences, now: now)
        #expect(searching.map(\.title) == ["Results"])
        let symbols = catalog.sections(query: "", category: .math, now: now)
        #expect(symbols.map(\.id) == ["math"])
    }

    @Test func usageDecaysWithAHalfLife() {
        var usage = EmojiUsage()
        usage.record("🍕", at: now)
        #expect(usage.score(for: "🍕", at: now) == 1)
        let later = now.addingTimeInterval(EmojiUsage.halfLife)
        #expect(abs(usage.score(for: "🍕", at: later) - 0.5) < 1e-9)
        usage.record("🍕", at: later)
        #expect(abs(usage.score(for: "🍕", at: later) - 1.5) < 1e-9)
        #expect(usage.records["🍕"]?.count == 2)
        usage.record("🔥", at: later)
        usage.record("🌮", at: now.addingTimeInterval(-EmojiUsage.halfLife * 4))
        #expect(usage.ranked(at: later, limit: 2) == ["🍕", "🔥"])
        usage.forget("🍕")
        #expect(usage.ranked(at: later, limit: 5) == ["🔥", "🌮"])
    }

    @Test func usageKeepsABoundedNumberOfRecords() {
        var usage = EmojiUsage()
        for index in 0..<(EmojiUsage.maximumRecords + 20) {
            usage.record("e\(index)", at: now.addingTimeInterval(Double(index)))
        }
        #expect(usage.records.count <= EmojiUsage.maximumRecords)
        #expect(usage.records["e\(EmojiUsage.maximumRecords + 19)"] != nil)
    }

    @Test func preferencesRoundTripAndTolerateMissingFields() throws {
        var preferences = EmojiPreferences()
        preferences.togglePin("🔥")
        preferences.setKeywords(["lit"], for: "🔥")
        preferences.recordUse("🔥", at: now)
        preferences.defaultSkinTone = .mediumDark
        preferences.columns = 9
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(EmojiPreferences.self, from: data) == preferences)

        let sparse = try JSONDecoder().decode(EmojiPreferences.self, from: Data(#"{"columns":42}"#.utf8))
        #expect(sparse.pinned.isEmpty)
        #expect(sparse.defaultSkinTone == .none)
        #expect(sparse.columns == 10)
    }

    @Test func skinTonesMapToModifiers() {
        #expect(SkinTone.none.modifier == nil)
        #expect(SkinTone.light.sample == "✋🏻")
        #expect(SkinTone.dark.sample == "✋🏿")
        #expect(SkinTone.allCases.count == 6)
    }

    @Test func unrenderableEmojiAreDropped() throws {
        let json = Data(
            #"""
            {"source":"test","categories":[
              {"id":"smileys-emotion","items":[{"e":"😀","n":"grinning face"},{"e":"🫪","n":"distorted face"}]},
              {"id":"arrows","items":[{"e":"→","n":"right-pointing arrow","k":["right"]}]},
              {"id":"unknown","items":[{"e":"x","n":"x"}]}]}
            """#.utf8)
        let catalog = try EmojiCatalog(data: json) { $0 != "🫪" }
        #expect(catalog.entries.map(\.glyph) == ["😀", "→"])
        // Text symbols are never filtered by the emoji font.
        let symbolsOnly = try EmojiCatalog(data: json) { _ in false }
        #expect(symbolsOnly.entries.map(\.glyph) == ["→"])
    }

    @Test func systemEmojiFontDrawsCommonEmoji() {
        #expect(EmojiGlyphSupport.isRenderable("😀"))
        #expect(EmojiGlyphSupport.isRenderable("👍🏽"))
        #expect(EmojiGlyphSupport.isRenderable("🇩🇪"))
        #expect(EmojiGlyphSupport.isRenderable("\u{E000}") == false)
    }
}
