import AppKit
import Foundation
import Testing

@testable import OpenRay

@MainActor
struct EmojiProviderTests {
    private let pasteboard = NSPasteboard.withUniqueName()

    private func setUp(store: LibraryStore = LibraryStore(fileURL: nil)) -> (EmojiProvider, LauncherModel) {
        let provider = EmojiProvider(catalog: .bundled, now: { CalculatorClock.now })
        let model = LauncherModel(
            store: store, ai: AIChatModel(engine: TestAIEngine()), pasteboard: pasteboard,
            registry: CommandRegistry(providers: [provider]))
        model.navigate(to: .provided(EmojiProvider.scope))
        model.files.stop()
        return (provider, model)
    }

    private func search(_ model: LauncherModel, _ query: String) {
        model.query = query
        model.files.stop()
        model.synchronizeSelection()
    }

    private func browse(_ model: LauncherModel, _ title: String) throws {
        let tile = try #require(model.orderedResults.first { $0.title == title }, "\(title)")
        model.perform(tile)
        model.files.stop()
        model.synchronizeSelection()
    }

    // MARK: Browsing through the shared pipeline

    @Test func theFirstScreenShowsPinsFrequentAndCategories() throws {
        let (provider, model) = setUp()
        defer { model.stop() }
        #expect(model.groups.map(\.id) == ["emoji.categories"])
        #expect(model.results.count == EmojiCategory.allCases.count)
        #expect(model.groups.first?.columns == GridColumns.defaultCount)
        provider.update(in: model) {
            $0.togglePin("🔥")
            $0.recordUse("🔥", at: CalculatorClock.now)
            $0.recordUse("🍕", at: CalculatorClock.now)
        }
        #expect(model.groups.map(\.id) == ["emoji.pinned", "emoji.frequent", "emoji.categories"])
        #expect(model.groups[1].items.map(\.title) == ["🍕"])
        let ids = model.orderedResults.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func largeCategoriesPageUnderTheScopeCap() throws {
        let (_, model) = setUp()
        defer { model.stop() }
        try browse(model, "People & Body")
        let total = EmojiCatalog.bundled.entries(in: .peopleBody).count
        #expect(total > 100)
        var seen: [String] = []
        for page in 0..<((total + EmojiProvider.pageSize - 1) / EmojiProvider.pageSize) {
            #expect(model.results.count <= 100)
            let tiles = model.orderedResults.filter { $0.id.hasPrefix("emoji-tile.") }
            seen += tiles.map(\.title)
            let titled = try #require(model.groups.first { $0.id == "emoji.people-body" }?.title)
            #expect(titled.hasPrefix("People & Body · \(page * EmojiProvider.pageSize + 1)–"))
            if seen.count < total { try browse(model, "More") }
        }
        #expect(seen.count == total)
        #expect(model.orderedResults.contains { $0.title == "More" } == false)
        try browse(model, "Previous")
        try browse(model, "All Categories")
        #expect(model.groups.map(\.id) == ["emoji.categories"])
    }

    @Test func searchRanksResultsInOneGroup() throws {
        let (_, model) = setUp()
        defer { model.stop() }
        search(model, "thumbs up")
        #expect(model.groups.map(\.id) == ["emoji.results"])
        #expect(model.selectedItem?.title == "👍")
        #expect(model.results.count <= EmojiProvider.pageSize)
        search(model, "zzqx")
        #expect(model.groups.isEmpty)
        #expect(model.providedEmptyState(for: EmojiProvider.scope).title.contains("zzqx"))
    }

    @Test func oversizedPastesAreNotSearched() {
        let (_, model) = setUp()
        defer { model.stop() }
        search(model, String(repeating: "smile ", count: 20))
        #expect(model.results.isEmpty)
        #expect(model.providedEmptyState(for: EmojiProvider.scope).title == "That's too long to search")
        search(model, String(repeating: "x", count: 600))
        #expect(model.results.isEmpty)
    }

    @Test func aGlobalAliasStillWins() throws {
        let (_, model) = setUp()
        defer { model.stop() }
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: EmojiProvider.searchID, alias: "zz")))
        search(model, "zz")
        #expect(model.results.map(\.id) == [EmojiProvider.searchID])
        #expect(model.selectedItem?.id == EmojiProvider.searchID)
    }

    @Test func gridArrowsMoveByTheGroupsColumns() throws {
        let (_, model) = setUp()
        defer { model.stop() }
        let first = try #require(model.groups.first)
        model.moveSelection(1)
        #expect(model.selectedID == first.items[GridColumns.defaultCount].id)
        model.moveSelectionHorizontally(1)
        #expect(model.selectedID == first.items[GridColumns.defaultCount + 1].id)
    }

    // MARK: ↩, ⌘↩ and ⌘K

    @Test func returnCopiesAndRecordsUse() throws {
        let (_, model) = setUp()
        defer { model.stop() }
        search(model, "thumbs up")
        model.performSelected()
        #expect(pasteboard.string(forType: .string) == "👍")
        let record = try #require(model.store.database.emojiUsage.first { $0.id == "👍" })
        #expect(record.count == 1)
        #expect(record.lastUsed == CalculatorClock.now)
        let item = try #require(model.selectedItem)
        #expect(model.secondaryTitle(for: item) != nil)
        model.pasteSelected()
        #expect(model.store.database.emojiUsage.first { $0.id == "👍" }?.count == 2)
    }

    @Test func defaultSkinToneShapesTilesAndCopies() throws {
        let (provider, model) = setUp()
        defer { model.stop() }
        provider.update(in: model) { $0.defaultSkinTone = .medium }
        search(model, "thumbs up")
        #expect(model.selectedItem?.title == "👍🏽")
        model.performSelected()
        #expect(pasteboard.string(forType: .string) == "👍🏽")
        #expect(model.store.database.emojiUsage.map(\.id) == ["👍"])
        #expect(model.store.database.commandPreferences["emoji.search"]?["skinTone"] == "3")
    }

    @Test func skinToneActionsOpenAChooserBeforeCopyingOrPasting() throws {
        let (_, model) = setUp()
        defer { model.stop() }
        search(model, "thumbs up")
        let thumbs = try #require(model.selectedItem)
        let actions = model.actions(for: thumbs)
        let paste = try #require(actions.first { $0.id == "emoji.pasteTone" })
        #expect(paste.children.count == SkinTone.allCases.count)
        // The real entry point (keyboard, action panel, context menu) runs the parent.
        paste.perform()
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(model.section.providedScope?.id == EmojiProvider.tonesID)
        model.files.stop()
        #expect(model.results.map(\.title) == ["👍", "👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"])
        #expect(model.groups.first?.columns == SkinTone.allCases.count)
        #expect(pasteboard.string(forType: .string) == nil)

        model.navigate(to: .provided(EmojiProvider.scope))
        search(model, "thumbs up")
        let again = try #require(model.selectedItem)
        try #require(model.actions(for: again).first { $0.id == "emoji.copyTone" }).perform()
        model.files.stop()
        let dark = try #require(model.results.last)
        model.selectedID = dark.id
        model.performSelected()
        #expect(pasteboard.string(forType: .string) == "👍🏿")
        #expect(model.section.providedScope?.id == EmojiProvider.searchID)
        #expect(model.store.database.emojiUsage.first { $0.id == "👍" }?.count == 1)
    }

    @Test func pinZoomAndUnicode() throws {
        let (_, model) = setUp()
        defer { model.stop() }
        search(model, "thumbs up")
        let thumbs = try #require(model.selectedItem)
        let actions = model.actions(for: thumbs)
        try #require(actions.first { $0.id == "emoji.copyUnicode" }).perform()
        #expect(pasteboard.string(forType: .string) == "U+1F44D")
        try #require(actions.first { $0.id == "emoji.pin" }).perform()
        #expect(model.store.database.emojiUsage.first { $0.id == "👍" }?.pinOrder == 0)
        try #require(actions.first { $0.id == "emoji.larger" }).perform()
        #expect(model.store.database.commandPreferences["emoji.search"]?["columns"] == "7")
        search(model, "")
        #expect(model.groups.first?.id == "emoji.pinned")
        #expect(model.groups.first?.columns == 7)
    }

    @Test func customKeywordsAreEditedInTheSearchField() throws {
        let (provider, model) = setUp()
        defer { model.stop() }
        search(model, "fire")
        let item = try #require(model.selectedItem)
        guard case .provided(let ref) = item.action else {
            Issue.record("Emoji tiles are provider rows")
            return
        }
        #expect(item.canEdit)
        provider.edit(item, ref: ref, in: model)
        #expect(model.section.providedScope?.id == EmojiProvider.keywordsID)
        search(model, "lit,  hot , ")
        #expect(model.results.first?.title.contains("lit, hot") == true)
        model.performSelected()
        #expect(model.section.providedScope?.id == EmojiProvider.searchID)
        #expect(model.store.database.emojiUsage.first { $0.id == "🔥" }?.keywords == ["lit", "hot"])
        search(model, "lit")
        #expect(model.selectedItem?.title == "🔥")
    }

    @Test func aFailedSaveKeepsTheEditorOpenAndSaysWhy() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "openray-emoji-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "library.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryDatabase())) as? [String: Any])
        object["schemaVersion"] = LibraryDatabase.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let (provider, model) = setUp(store: LibraryStore(fileURL: url))
        defer { model.stop() }
        #expect(model.store.isReadOnly)
        search(model, "fire")
        let item = try #require(model.selectedItem)
        guard case .provided(let ref) = item.action else { return }
        provider.edit(item, ref: ref, in: model)
        search(model, "lit")
        model.performSelected()
        #expect(model.section.providedScope?.id == EmojiProvider.keywordsID)
        #expect(model.feedback?.style == .error)
        #expect(!provider.update(in: model) { $0.togglePin("🔥") })
    }

    @Test func savedCountsAtTheLimitNeverOverflow() throws {
        let store = LibraryStore(fileURL: nil)
        #expect(store.update {
            $0.emojiUsage = [
                EmojiUsageRecord(id: "👍", score: 1, count: .max, lastUsed: CalculatorClock.now),
                EmojiUsageRecord(id: "🔥"),
            ]
        })
        let (_, model) = setUp(store: store)
        defer { model.stop() }
        search(model, "thumbs up")
        model.performSelected()
        #expect(model.store.database.emojiUsage.first { $0.id == "👍" }?.count == EmojiUsage.maximumCount)
        var usage = EmojiUsage(records: ["x": .init(score: .greatestFiniteMagnitude, count: .max, lastUsed: CalculatorClock.now)])
        usage.record("x", at: CalculatorClock.now)
        #expect(usage.records["x"]?.count == EmojiUsage.maximumCount)
        #expect(usage.records["x"]?.score == EmojiUsage.maximumScore)
    }

    @Test func preferencesRoundTripThroughRecords() {
        var preferences = EmojiPreferences()
        preferences.togglePin("🔥")
        preferences.togglePin("🍕")
        preferences.setKeywords(["lit"], for: "🔥")
        preferences.recordUse("🌮", at: CalculatorClock.now)
        let restored = EmojiPreferences(records: preferences.records)
        #expect(restored.pinned == ["🔥", "🍕"])
        #expect(restored.customKeywords == ["🔥": ["lit"]])
        #expect(restored.usage == preferences.usage)
        #expect(EmojiPreferences(records: [EmojiUsageRecord(id: "🙂")]).records.isEmpty)
    }
}
