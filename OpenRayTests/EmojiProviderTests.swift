import AppKit
import Foundation
import Testing

@testable import OpenRay

@MainActor
struct EmojiProviderTests {
    private let pasteboard = NSPasteboard.withUniqueName()

    private func setUp() -> (EmojiProvider, LauncherModel) {
        let provider = EmojiProvider(catalog: .bundled, now: { CalculatorClock.now })
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: pasteboard,
            registry: CommandRegistry(providers: [provider]))
        model.navigate(to: .provided(EmojiProvider.scope))
        return (provider, model)
    }

    private func search(_ model: LauncherModel, _ query: String) {
        model.query = query
        model.files.stop()
        model.synchronizeSelection()
    }

    @Test func browsingShowsEveryCategoryAsAGrid() throws {
        let (_, model) = setUp()
        defer { model.stop() }
        let groups = model.groups
        #expect(groups.first?.id == "emoji.smileys-emotion")
        #expect(groups.last?.id == "emoji.shapes")
        #expect(groups.allSatisfy { $0.style == .grid && $0.columns == GridColumns.defaultCount && $0.tile != nil })
        // The whole catalog, past the launcher's 100-row scope cap.
        #expect(groups.flatMap(\.items).count == EmojiCatalog.bundled.entries.count)
        #expect(model.selectedItem?.title == "😀")
    }

    @Test func repeatedTilesHaveSectionScopedIDs() throws {
        let (provider, model) = setUp()
        defer { model.stop() }
        provider.update(in: model) {
            $0.togglePin("🔥")
            $0.recordUse("🔥", at: CalculatorClock.now)
            $0.recordUse("🍕", at: CalculatorClock.now)
        }
        let groups = model.groups
        #expect(groups.map(\.id).prefix(3) == ["emoji.pinned", "emoji.frequent", "emoji.smileys-emotion"])
        let ids = groups.flatMap(\.items).map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("emoji.pinned.🔥") && ids.contains("emoji.travel-places.🔥"))
    }

    @Test func searchRanksResultsInOneGroup() throws {
        let (_, model) = setUp()
        defer { model.stop() }
        search(model, "thumbs up")
        #expect(model.groups.map(\.id) == ["emoji.results"])
        #expect(model.selectedItem?.title == "👍")
        search(model, "zzqx")
        #expect(model.groups.isEmpty)
        #expect(model.providedEmptyState(for: EmojiProvider.scope).title.contains("zzqx"))
    }

    @Test func returnCopiesAndRecordsUse() throws {
        let (_, model) = setUp()
        defer { model.stop() }
        search(model, "thumbs up")
        model.performSelected()
        #expect(pasteboard.string(forType: .string) == "👍")
        let record = try #require(model.store.database.emojiUsage.first { $0.id == "👍" })
        #expect(record.count == 1)
        #expect(record.lastUsed == CalculatorClock.now)
        // ⌘↩ is the paste hook; the isolated pasteboard copies.
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
        // Usage stays on the base emoji.
        #expect(model.store.database.emojiUsage.map(\.id) == ["👍"])
        #expect(model.store.database.commandPreferences["emoji.search"]?["skinTone"] == "3")
    }

    @Test func actionsPinZoomAndCopyTones() throws {
        let (_, model) = setUp()
        defer { model.stop() }
        search(model, "thumbs up")
        let item = try #require(model.selectedItem)
        let actions = model.actions(for: item)
        let ids = actions.map(\.id)
        #expect(ids.contains("emoji.pasteTone") && ids.contains("emoji.copyTone") && ids.contains("emoji.copyUnicode"))
        #expect(actions.first { $0.id == "emoji.copyTone" }?.children.count == SkinTone.allCases.count)
        try #require(actions.first { $0.id == "emoji.copyTone" }?.children.last).perform()
        #expect(pasteboard.string(forType: .string) == "👍🏿")
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

    @Test func gridArrowsMoveByTheGroupsColumns() throws {
        let (_, model) = setUp()
        defer { model.stop() }
        let first = try #require(model.groups.first)
        model.moveSelection(1)
        #expect(model.selectedID == first.items[GridColumns.defaultCount].id)
        model.moveSelectionHorizontally(1)
        #expect(model.selectedID == first.items[GridColumns.defaultCount + 1].id)
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
