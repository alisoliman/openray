import Foundation
import SwiftUI
import Testing

@testable import OpenRay

@MainActor
struct LibrarySchemaV5Tests {
    private static let keysAddedInV5 = [
        "aiCommands", "agents", "disabledCommandIDs", "fallbackOrder", "scriptDirectories", "windowLayouts",
        "focusCategories", "emojiUsage", "calculatorHistory", "commandPreferences",
    ]

    private func temporaryLibraryURL() throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRaySchema-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appending(path: "library.json"))
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func versionFourLibrariesMigrateUpAndKeepTheirData() throws {
        let (directory, url) = try temporaryLibraryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        var legacy = LibraryDatabase()
        legacy.schemaVersion = 4
        legacy.notes = [QuickNote(title: "Keep", content: "A note from 2.0")]
        legacy.snippets = [Snippet(name: "Sign-off", keyword: ";bye", content: "Best, A.")]
        legacy.commandBindings = [CommandBinding(targetID: "ai.proofread", alias: "fix")]
        legacy.favoriteIDs = ["ai.summarize", "section.notes"]
        legacy.favoriteOrder = ["ai.summarize", "section.notes"]
        legacy.usage = [UsageRecord(id: "ai.summarize", count: 3)]
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        for key in Self.keysAddedInV5 { object.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let store = LibraryStore(fileURL: url)
        #expect(!store.isReadOnly)
        #expect(store.errorMessage == nil)
        let database = store.database
        #expect(database.schemaVersion == 5)
        #expect(database.notes == legacy.notes)
        #expect(database.snippets == legacy.snippets)
        #expect(database.aliasTarget(for: "fix") == "ai.proofread")
        #expect(database.orderedFavoriteIDs == ["ai.summarize", "section.notes"])
        #expect(database.usage.map(\.id) == ["ai.summarize"])
        #expect(database.aiCommands.isEmpty && database.agents.isEmpty)
        #expect(database.disabledCommandIDs.isEmpty && database.fallbackOrder.isEmpty)
        #expect(database.scriptDirectories.isEmpty && database.windowLayouts.isEmpty)
        #expect(database.focusCategories.isEmpty && database.emojiUsage.isEmpty)
        #expect(database.calculatorHistory.isEmpty && database.commandPreferences.isEmpty)
        // Loading alone doesn't rewrite the file; the first save does, as version 5.
        #expect(try jsonObject(at: url)["schemaVersion"] as? Int == 4)
        #expect(store.save(QuickNote(title: "After", content: "Saved by schema 5")))
        let saved = try jsonObject(at: url)
        #expect(saved["schemaVersion"] as? Int == 5)
        for key in Self.keysAddedInV5 { #expect(saved[key] != nil, "missing \(key)") }

        let reopened = LibraryStore(fileURL: url)
        #expect(!reopened.isReadOnly)
        #expect(reopened.database.notes.count == 2)
        #expect(reopened.database.binding(for: "ai.proofread")?.alias == "fix")
    }

    @Test func versionFiveCollectionsRoundTrip() throws {
        let (directory, url) = try temporaryLibraryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(fileURL: url)
        let ai = AICommandRecord()
        let agent = AgentRecord()
        let scripts = ScriptDirectoryRecord()
        let layout = WindowLayoutRecord()
        let history = CalculatorHistoryRecord()
        #expect(
            store.update { database in
                database.aiCommands = [ai]
                database.agents = [agent]
                database.disabledCommandIDs = ["window.center"]
                database.fallbackOrder = ["fallback.web", "fallback.ai"]
                database.scriptDirectories = [scripts]
                database.windowLayouts = [layout]
                database.focusCategories = [FocusCategoryRecord(id: "social")]
                database.emojiUsage = [EmojiUsageRecord(id: "🎉")]
                database.calculatorHistory = [history]
                database.commandPreferences = ["system.sleep": ["confirm": "false"]]
            })
        let reopened = LibraryStore(fileURL: url)
        #expect(!reopened.isReadOnly)
        #expect(reopened.database == store.database)
        #expect(reopened.database.aiCommands == [ai])
        #expect(reopened.database.emojiUsage.map(\.id) == ["🎉"])
        #expect(reopened.database.commandPreferences["system.sleep"]?["confirm"] == "false")
    }

    @Test func aPartialVersionFiveLibraryStillLoads() throws {
        let (directory, url) = try temporaryLibraryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryDatabase())) as? [String: Any])
        for key in Self.keysAddedInV5 where key != "fallbackOrder" { object.removeValue(forKey: key) }
        object["fallbackOrder"] = ["fallback.web"]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let store = LibraryStore(fileURL: url)
        #expect(!store.isReadOnly)
        #expect(store.database.fallbackOrder == ["fallback.web"])
    }

    @Test func duplicateIdentifiersInNewCollectionsAreRejected() {
        let store = LibraryStore(fileURL: nil)
        let record = WindowLayoutRecord()
        #expect(!store.update { $0.windowLayouts = [record, record] })
        #expect(store.database.windowLayouts.isEmpty)
        #expect(!store.update { $0.emojiUsage = [EmojiUsageRecord(id: "🙂"), EmojiUsageRecord(id: "🙂")] })
    }

    @Test func librariesFromANewerSchemaOpenReadOnlyAndStayUntouched() throws {
        let (directory, url) = try temporaryLibraryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryDatabase())) as? [String: Any])
        object["schemaVersion"] = LibraryDatabase.currentSchemaVersion + 1
        // A collection this build has never heard of.
        object["somethingFromTheFuture"] = [["id": "x", "shape": "unknown"]]
        let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try original.write(to: url)

        let store = LibraryStore(fileURL: url)
        #expect(store.isReadOnly)
        #expect(store.errorMessage?.contains("newer version") == true)
        #expect(!store.save(QuickNote(title: "Nope", content: "Must not be written")))
        #expect(!store.update { $0.fallbackOrder = ["fallback.ai"] })
        #expect(try Data(contentsOf: url) == original)
    }
}

@MainActor
struct Step0SeamTests {
    // MARK: ArgumentSpec

    @Test func argumentSpecsUseAFlatPortableJSONForm() throws {
        let json = Data(
            #"""
            [
              {"name": "query", "placeholder": "Search term"},
              {"name": "token", "placeholder": "Token", "type": "password", "optional": true},
              {"name": "lang", "placeholder": "Language", "type": "dropdown", "default": "en",
               "options": [{"title": "English", "value": "en"}, {"title": "German", "value": "de"}]}
            ]
            """#.utf8)
        let specs = try JSONDecoder().decode([ArgumentSpec].self, from: json)
        #expect(specs[0] == .query)
        #expect(specs[1].type == .password && specs[1].isOptional)
        #expect(specs[2].type == .dropdown([.init(title: "English", value: "en"), .init(title: "German", value: "de")]))
        #expect(specs[2].defaultValue == "en")
        let again = try JSONDecoder().decode([ArgumentSpec].self, from: JSONEncoder().encode(specs))
        #expect(again == specs)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ArgumentSpec.self, from: Data(#"{"name": "x", "type": "slider"}"#.utf8))
        }
    }

    @Test func argumentsResolveDefaultsAndValidateChoices() throws {
        let specs = [
            ArgumentSpec.query,
            ArgumentSpec(name: "token", placeholder: "Token", type: .password, isOptional: true),
            ArgumentSpec(
                name: "lang", placeholder: "Language", type: .dropdown([.init(title: "German", value: "de")]),
                defaultValue: "de"),
        ]
        #expect(try ArgumentSpec.resolve(specs, typed: ["query": "  swift  "]) == ["query": "swift", "lang": "de"])
        #expect(try ArgumentSpec.resolve(specs, typed: ["query": "a", "token": " s3 "])["token"] == " s3 ")
        #expect(throws: LibraryValidationError.self) { try ArgumentSpec.resolve(specs, typed: ["query": "   "]) }
        #expect(throws: LibraryValidationError.self) {
            try ArgumentSpec.resolve(specs, typed: ["query": "a", "lang": "fr"])
        }
    }

    @Test func quicklinksDescribeTheirSingleArgument() throws {
        let search = Quicklink(name: "Search", template: "https://example.com/?q={query}", keyword: "ex")
        let plain = Quicklink(name: "Home", template: "https://example.com", keyword: "")
        #expect(search.argumentSpecs == [.query])
        #expect(plain.argumentSpecs.isEmpty)
        // The single-argument path is unchanged.
        #expect(try search.resolvedURL(query: "a b").absoluteString == "https://example.com/?q=a%20b")
    }

    // MARK: Action panel model

    @Test func actionEntriesDefaultToNoSectionAndNoChildren() {
        let entry = ActionEntry(id: "x", title: "X", symbol: "xmark", group: .item) {}
        #expect(entry.section == nil)
        #expect(entry.children.isEmpty)
    }

    // MARK: Settings panes

    @Test func settingsPanesKeepTheirIdentifiersAndOrder() {
        #expect(
            SettingsPane.allCases.map(\.rawValue) == [
                "general", "shortcuts", "clipboard", "snippets", "files", "ai", "permissions", "library", "about",
            ])
        #expect(SettingsPane.primary == [.general, .shortcuts, .clipboard, .snippets, .files, .ai])
        #expect(SettingsPane.secondary == [.permissions, .library, .about])
        #expect(SettingsPane(rawValue: "clipboard") == .clipboard)
        #expect(SettingsPane(rawValue: "nope") == nil)
        #expect(RuntimeMode.settingsPane(arguments: ["--open-settings", "library"]) == .library)
        #expect(RuntimeMode.settingsPane(arguments: ["--open-settings"]) == .general)
        #expect(Set(SettingsPane.allCases.map(\.id)).count == SettingsPane.allCases.count)
        #expect(SettingsPane.ai.title == "Apple Intelligence")
        #expect(SettingsPane.permissions.kind == .permission)
    }

    @Test func everySettingsPaneBuildsItsView() {
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName())
        defer { model.stop() }
        let navigation = SettingsNavigation()
        for pane in SettingsPane.allCases {
            _ = pane.content(model: model, navigation: navigation)
        }
    }

    // MARK: Scopes

    @Test func builtInScopesKeepTheirIdentity() {
        #expect(LauncherSection.allCases.map(\.rawValue) == [
            "home", "applications", "files", "clipboard", "snippets", "quicklinks", "notes", "calculator", "windows",
        ])
        let scope = ProvidedScope(
            id: "test.scope", provider: "test", title: "Scope", symbol: "star", kind: .command, placeholder: "Search")
        var renamed = scope
        renamed.title = "Renamed"
        #expect(LauncherSection.provided(scope) == .provided(renamed))
        #expect(LauncherSection.provided(scope).id == "test.scope")
        #expect(LauncherSection.provided(scope) != .home)
        #expect(!LauncherSection.provided(scope).createsItems)
        #expect(LauncherSection.provided(scope).shortTitle == "Scope")
    }
}
