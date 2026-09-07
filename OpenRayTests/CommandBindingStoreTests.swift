import Foundation
import Testing

@testable import OpenRay

@MainActor
struct CommandBindingStoreTests {
    @Test(arguments: [1, 2]) func migratesLegacyLibrariesWithoutChangingLauncherHotkey(version: Int) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        var legacy = LibraryDatabase()
        legacy.schemaVersion = version
        legacy.preferences.hotKey = .controlOptionSpace
        legacy.notes = [QuickNote(title: "Keep", content: "My local note")]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "commandBindings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let store = LibraryStore(fileURL: url)
        #expect(!store.isReadOnly)
        #expect(store.database.schemaVersion == LibraryDatabase.currentSchemaVersion)
        #expect(store.database.commandBindings.isEmpty)
        #expect(store.database.preferences.hotKey == .controlOptionSpace)
        #expect(store.database.notes == legacy.notes)
        #expect(store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "clip")))

        let reopened = LibraryStore(fileURL: url)
        #expect(!reopened.isReadOnly)
        #expect(reopened.database.preferences.hotKey == .controlOptionSpace)
        #expect(reopened.database.notes == legacy.notes)
        #expect(reopened.database.aliasTarget(for: "clip") == "section.clipboard")
    }

    @Test func bindingsRoundTripWithStableTargetsAndExactNormalizedAliases() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        let shortcut = CommandShortcut(keyCode: 8, modifiers: [.control, .option])
        #expect(
            store.saveCommandBinding(
                CommandBinding(targetID: "section.clipboard", alias: "  Clip\n", shortcut: shortcut)))
        #expect(
            store.saveCommandBinding(
                CommandBinding(
                    targetID: "settings", shortcut: CommandShortcut(keyCode: 1, modifiers: [.control, .option]))))
        let reopened = LibraryStore(fileURL: url)

        #expect(!reopened.isReadOnly)
        #expect(reopened.database == store.database)
        #expect(reopened.database.binding(for: "section.clipboard")?.alias == "Clip")
        #expect(reopened.database.binding(for: "section.clipboard")?.shortcut == shortcut)
        #expect(reopened.database.aliasTarget(for: "\n cLiP  ") == "section.clipboard")
        #expect(reopened.database.aliasTarget(for: "clip argument") == nil)
        #expect(reopened.database.aliasTarget(for: "cli") == nil)
        #expect(reopened.database.aliasTarget(for: "  ") == nil)
        #expect(reopened.database.binding(for: "missing") == nil)
    }

    @Test func aliasesCannotCollideWithCommandsQuicklinksOrSnippets() {
        let store = LibraryStore(fileURL: nil)
        #expect(store.save(Snippet(name: "Address", keyword: ";addr", content: "123 Main Street")))
        #expect(store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "CLIP")))
        let before = store.database

        #expect(!store.saveCommandBinding(CommandBinding(targetID: "section.notes", alias: " clip ")))
        #expect(!store.saveCommandBinding(CommandBinding(targetID: "section.notes", alias: " WEB ")))
        #expect(!store.saveCommandBinding(CommandBinding(targetID: "section.notes", alias: ";ADDR")))
        #expect(store.database == before)
        #expect(store.errorMessage != nil)
        #expect(store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "clip")))
        #expect(store.database.commandBindings.count == 1)
    }

    @Test func keywordCreationAndEditsCannotClaimCommandAliases() {
        let store = LibraryStore(fileURL: nil)
        var snippet = Snippet(name: "Address", keyword: ";addr", content: "123 Main Street")
        var quicklink = Quicklink(name: "Example", template: "https://example.com", keyword: "example")
        #expect(store.save(snippet))
        #expect(store.save(quicklink))
        #expect(store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "clip")))
        let before = store.database

        #expect(!store.save(Quicklink(name: "Conflict", template: "https://example.com", keyword: "CLIP")))
        #expect(!store.save(Snippet(name: "Conflict", keyword: "CLIP", content: "Some text")))
        snippet.keyword = "Clip"
        quicklink.keyword = "Clip"
        #expect(!store.save(snippet))
        #expect(!store.save(quicklink))
        #expect(store.database == before)
    }

    @Test func existingKeywordOverlapDoesNotPreventUnrelatedBindings() {
        let store = LibraryStore(fileURL: nil)
        #expect(store.save(Quicklink(name: "Other web", template: "https://example.com", keyword: "web")))
        #expect(store.save(Snippet(name: "Web text", keyword: "web", content: "My web address")))
        #expect(store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "clip")))
        #expect(store.database.aliasTarget(for: "clip") == "section.clipboard")
    }

    @Test func aliasNamespaceUsesUnicodeCaseInsensitiveComparison() {
        let store = LibraryStore(fileURL: nil)
        #expect(store.save(Quicklink(name: "Street", template: "https://example.com", keyword: "straße")))
        #expect(!store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "STRASSE")))
        #expect(store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "Grüße")))
        #expect(store.database.aliasTarget(for: "GRÜSSE") == "section.clipboard")
        #expect(!store.saveCommandBinding(CommandBinding(targetID: "settings", alias: "GRÜSSE")))
    }

    @Test func aliasLengthBoundaryAndNonReservedShortcutConflictsAreAllowed() {
        let store = LibraryStore(fileURL: nil)
        let shortcut = CommandShortcut(keyCode: 8, modifiers: [.control, .option])
        let alias = String(repeating: "a", count: 32)
        #expect(
            store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: alias, shortcut: shortcut)))
        #expect(store.saveCommandBinding(CommandBinding(targetID: "settings", alias: "s", shortcut: shortcut)))
        #expect(store.database.aliasTarget(for: alias.uppercased()) == "section.clipboard")
        #expect(store.database.commandBindings.count == 2)
        #expect(store.database.commandBindings.allSatisfy { $0.shortcut == shortcut })
    }

    @Test func editingAnAliasPreservesShortcutConflictPriority() {
        let store = LibraryStore(fileURL: nil)
        let shortcut = CommandShortcut(keyCode: 8, modifiers: [.control, .option])
        #expect(
            store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "clip", shortcut: shortcut)))
        #expect(store.saveCommandBinding(CommandBinding(targetID: "settings", alias: "prefs", shortcut: shortcut)))
        #expect(
            store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "cl", shortcut: shortcut)))
        #expect(store.database.commandBindings.map(\.targetID) == ["section.clipboard", "settings"])
        #expect(store.database.aliasTarget(for: "cl") == "section.clipboard")
    }

    @Test func invalidAliasesShortcutsAndUnsafeTargetsAreRejectedAtomically() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        #expect(store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "clip")))
        let before = store.database
        let original = try Data(contentsOf: url)

        for alias in ["two words", "two\twords", String(repeating: "x", count: 33)] {
            #expect(!store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: alias)))
        }
        #expect(
            !store.saveCommandBinding(
                CommandBinding(targetID: "section.clipboard", shortcut: CommandShortcut(keyCode: 8, modifiers: []))))
        #expect(
            !store.saveCommandBinding(
                CommandBinding(
                    targetID: "section.clipboard", shortcut: CommandShortcut(keyCode: 49, modifiers: [.command]))))
        for target in ["system.lock", "system.sleep", "system.emptyTrash", "app.unknown", "section.home"] {
            #expect(!store.saveCommandBinding(CommandBinding(targetID: target, alias: "unsafe")))
            #expect(!store.saveCommandBinding(CommandBinding(targetID: target)))
        }
        #expect(store.database == before)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func clearingAndRemovingBindingsPersistsAndReleasesAlias() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        #expect(store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "clip")))
        #expect(store.saveCommandBinding(CommandBinding(targetID: "settings", alias: "prefs")))
        #expect(store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: " \n ")))
        #expect(store.database.binding(for: "section.clipboard") == nil)
        #expect(store.save(Quicklink(name: "Clip", template: "https://example.com", keyword: "clip")))
        #expect(store.removeCommandBinding(for: "settings"))
        #expect(LibraryStore(fileURL: url).database.commandBindings.isEmpty)
    }

    @Test func removedCommandsAreDiscardedWithoutLosingOtherLibraryData() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        var database = LibraryDatabase()
        database.preferences.hotKey = .controlSpace
        database.notes = [QuickNote(title: "Keep", content: "Safe")]
        database.commandBindings = [
            CommandBinding(targetID: "removed.command", alias: "clip"),
            CommandBinding(targetID: "section.clipboard", alias: "clip"),
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(database).write(to: url)

        let store = LibraryStore(fileURL: url)
        #expect(!store.isReadOnly)
        #expect(store.database.commandBindings == [CommandBinding(targetID: "section.clipboard", alias: "clip")])
        #expect(store.database.preferences.hotKey == .controlSpace)
        #expect(store.database.notes == database.notes)
        #expect(store.update { $0.commandBindings.append(CommandBinding(targetID: "another.removed", alias: "clip")) })
        #expect(store.database.commandBindings.count == 1)
        #expect(LibraryStore(fileURL: url).database == store.database)
    }

    @Test func malformedPayloadForRemovedCommandDoesNotMakeLibraryReadOnly() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        var database = LibraryDatabase()
        database.preferences.hotKey = .controlSpace
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(database)) as? [String: Any])
        let obsolete: [String: Any] = ["targetID": "removed.command", "alias": [1, 2], "shortcut": "obsolete format"]
        json["commandBindings"] = [obsolete]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let store = LibraryStore(fileURL: url)
        #expect(!store.isReadOnly)
        #expect(store.database.commandBindings.isEmpty)
        #expect(store.database.preferences.hotKey == .controlSpace)
        #expect(store.saveCommandBinding(CommandBinding(targetID: "settings", alias: "prefs")))
    }

    @Test func failedPersistenceDoesNotPublishOrNotifyBindings() throws {
        let parent = temporaryDirectory()
        try Data("not a directory".utf8).write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = LibraryStore(fileURL: parent.appending(path: "library.json"))
        var notifications = 0
        store.commandBindingsDidChange = { notifications += 1 }

        #expect(!store.saveCommandBinding(CommandBinding(targetID: "section.clipboard", alias: "clip")))
        #expect(store.database.commandBindings.isEmpty)
        #expect(notifications == 0)
        #expect(store.errorMessage != nil)
    }

    @Test func successfulBindingChangesNotifyAfterPublishOnly() {
        let store = LibraryStore(fileURL: nil)
        var published: [[CommandBinding]] = []
        store.commandBindingsDidChange = { published.append(store.database.commandBindings) }
        let binding = CommandBinding(targetID: "section.clipboard", alias: "clip")
        #expect(store.saveCommandBinding(binding))
        #expect(store.saveCommandBinding(binding))
        #expect(store.save(QuickNote(title: "No notification", content: "Separate data")))
        #expect(!store.saveCommandBinding(CommandBinding(targetID: "settings", alias: "clip")))
        #expect(store.removeCommandBinding(for: binding.targetID))
        #expect(published == [[binding], []])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "CommandBindingTests-\(UUID())")
    }
}
