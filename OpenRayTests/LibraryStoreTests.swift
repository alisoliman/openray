import Foundation
import Testing

@testable import OpenRay

@MainActor
struct LibraryStoreTests {
    @Test func sensitiveFeaturesAreOffByDefault() {
        let store = LibraryStore(fileURL: nil)
        #expect(!store.database.preferences.clipboardEnabled)
        #expect(!store.database.preferences.snippetExpansionEnabled)
        #expect(store.database.clipboard.isEmpty)
    }

    @Test func roundTripsLibraryWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        let snippet = Snippet(name: "Address", keyword: ";addr", content: "123 Example Street")
        #expect(store.save(snippet))
        #expect(store.save(QuickNote(title: "A note", content: "Only local")))
        #expect(store.save(Quicklink(name: "Site", template: "https://example.com", keyword: "site")))
        store.toggleFavorite("snippet.\(snippet.id)")
        store.recordUse(of: "snippet.\(snippet.id)")
        let loaded = LibraryStore(fileURL: url)
        #expect(loaded.database == store.database)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func corruptedLibraryIsPreservedAndCannotBeOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let original = Data("not valid json".utf8)
        try original.write(to: url)
        let store = LibraryStore(fileURL: url)
        #expect(store.isReadOnly)
        #expect(store.errorMessage != nil)
        #expect(!store.save(QuickNote(title: "New", content: "Do not overwrite")))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func newerSchemaIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        var future = LibraryDatabase()
        future.schemaVersion = LibraryDatabase.currentSchemaVersion + 1
        try JSONEncoder().encode(future).write(to: url)
        let store = LibraryStore(fileURL: url)
        #expect(store.isReadOnly)
        #expect(!store.update { $0.notes = [] })
        #expect(
            try JSONDecoder().decode(LibraryDatabase.self, from: Data(contentsOf: url)).schemaVersion == LibraryDatabase
                .currentSchemaVersion + 1)
    }

    @Test func semanticallyInvalidJSONIsPreservedRatherThanCrashingSearch() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        var database = LibraryDatabase()
        database.usage = [UsageRecord(id: "duplicate"), UsageRecord(id: "duplicate")]
        let original = try JSONEncoder().encode(database)
        try original.write(to: url)
        let store = LibraryStore(fileURL: url)
        #expect(store.isReadOnly)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func invalidEditsLeaveExistingDataUntouched() {
        let store = LibraryStore(fileURL: nil)
        let valid = Snippet(name: "Greeting", keyword: ";hello", content: "Hello there")
        #expect(store.save(valid))
        #expect(!store.save(Snippet(name: "Duplicate", keyword: ";hello", content: "Other")))
        var edited = valid
        edited.content = ""
        #expect(!store.save(edited))
        #expect(store.database.snippets == [valid])
        edited.content = "Updated"
        #expect(store.save(edited))
        #expect(store.database.snippets.count == 1)
        #expect(store.database.snippets[0].content == "Updated")
    }

    @Test func failedSaveDoesNotPublishUnsavedChanges() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "OpenRayTests-\(UUID())")
        try Data("not a directory".utf8).write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = LibraryStore(fileURL: parent.appending(path: "library.json"))
        #expect(!store.save(QuickNote(title: "Lost", content: "Must not publish")))
        #expect(store.database.notes.isEmpty)
        #expect(store.errorMessage != nil)
    }

    @Test func clipboardDeduplicatesPreservesIdentityAndEnforcesRetention() {
        let store = LibraryStore(fileURL: nil)
        let now = Date(timeIntervalSince1970: 10_000_000)
        let first = ClipboardEntry(text: "First", copiedAt: now, sourceName: "Test")
        store.capture(first, now: now)
        #expect(store.database.clipboard.isEmpty)
        store.update {
            $0.preferences.clipboardEnabled = true
            $0.preferences.clipboardLimit = 2
        }
        store.capture(first, now: now)
        store.capture(ClipboardEntry(text: "Second", copiedAt: now, sourceName: "Test"), now: now)
        store.capture(ClipboardEntry(text: "First", copiedAt: now.addingTimeInterval(5), sourceName: "Other"), now: now)
        #expect(store.database.clipboard.count == 2)
        #expect(store.database.clipboard[0].id == first.id)
        #expect(store.database.clipboard[0].sourceName == "Other")
        store.capture(ClipboardEntry(text: "Third", copiedAt: now, sourceName: "Test"), now: now)
        #expect(store.database.clipboard.map(\.text) == ["Third", "First"])
        store.pruneClipboard(now: now.addingTimeInterval(8 * 86_400))
        #expect(store.database.clipboard.isEmpty)
    }

    @Test func clipboardRejectsEmptyAndOversizedValues() {
        let store = LibraryStore(fileURL: nil)
        store.update { $0.preferences.clipboardEnabled = true }
        store.capture(ClipboardEntry(text: " \n ", sourceName: "Test"))
        store.capture(ClipboardEntry(text: String(repeating: "x", count: 128_001), sourceName: "Test"))
        #expect(store.database.clipboard.isEmpty)
    }

    @Test func recencyAndFavoritesUseStableIDs() {
        let store = LibraryStore(fileURL: nil)
        store.recordUse(of: "app.test", at: Date(timeIntervalSince1970: 100))
        store.recordUse(of: "app.test", at: Date(timeIntervalSince1970: 200))
        #expect(store.database.usage.count == 1)
        #expect(store.database.usage[0].count == 2)
        store.toggleFavorite("app.test")
        #expect(store.database.favoriteIDs.contains("app.test"))
        store.toggleFavorite("app.test")
        #expect(!store.database.favoriteIDs.contains("app.test"))
    }
}
