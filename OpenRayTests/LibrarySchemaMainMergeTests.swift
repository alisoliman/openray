import Foundation
import Testing

@testable import OpenRay

/// The library after merging main: version 5 reads v3 (the released app), main's v4 (v3 plus
/// `pomodoro`) and the redesign's v4, and writes every key back.
@MainActor
struct LibrarySchemaMainMergeTests {
    private func temporaryLibraryURL() throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayMainMerge-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appending(path: "library.json"))
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Every key of `old`, recursively through objects and the objects inside arrays (matched by
    /// position), is still in `new`.
    private func missingKeys(_ old: [String: Any], in new: [String: Any], path: String = "") -> [String] {
        old.flatMap { key, value -> [String] in
            guard let replacement = new[key] else { return [path + key] }
            return missingKeys(value, in: replacement, path: path + key)
        }
    }

    private func missingKeys(_ old: Any, in new: Any, path: String) -> [String] {
        if let old = old as? [String: Any] {
            guard let new = new as? [String: Any] else { return [path] }
            return missingKeys(old, in: new, path: path + ".")
        }
        // Arrays of objects are compared item by item; plain values may be normalized on save.
        if let old = old as? [Any], old.contains(where: { $0 is [String: Any] }) {
            guard let new = new as? [Any], new.count >= old.count else { return [path + "[]"] }
            return old.indices.flatMap { missingKeys(old[$0], in: new[$0], path: path + "[\($0)]") }
        }
        return []
    }

    private static let sessionID = "6D3D7C8E-2B53-4E2B-9E57-8A0C1D2E3F40"
    private static let noteID = "1F6B1C9A-2D3E-4F50-8A6B-7C8D9E0F1A2B"

    /// main's preferences, which are version 3's.
    private static let mainPreferences = """
        {"appearance": "light", "hotKey": "controlSpace", "clipboardEnabled": false,
         "clipboardImagesEnabled": true, "clipboardFilesEnabled": false, "clipboardRetentionDays": 14,
         "clipboardLimit": 120, "snippetExpansionEnabled": false,
         "excludedClipboardBundleIDs": ["com.1password.1password", "com.example.secret"]}
        """

    private static let mainPomodoro = """
        {"configuration": {"focusMinutes": 50, "shortBreakMinutes": 10, "longBreakMinutes": 20,
                           "sessionsBeforeLongBreak": 3, "dailyGoal": 6, "automaticallyStartBreaks": true,
                           "playSound": false},
         "state": {"phase": "focus", "status": "paused", "completedInCycle": 2, "durationSeconds": 3000,
                   "remainingSeconds": 1200, "startedAt": 800000000},
         "sessions": [{"id": "\(sessionID)", "startedAt": 799990000, "completedAt": 799993000,
                       "durationSeconds": 3000}]}
        """

    private func library(version: Int, extra: String) -> String {
        """
        {"schemaVersion": \(version), "preferences": \(Self.mainPreferences),
         "quicklinks": [], "snippets": [],
         "notes": [{"id": "\(Self.noteID)", "title": "From main", "content": "Keep me",
                    "modifiedAt": 799000000}],
         "clipboard": [], "favoriteIDs": ["pomodoro.open", "section.notes"],
         "usage": [{"id": "caffeinate.start", "count": 4, "lastUsed": 799990000}],
         "commandBindings": [{"targetID": "pomodoro.start", "alias": "focus25"},
                             {"targetID": "caffeinate.toggle", "alias": "awake"}]\(extra)}
        """
    }

    @Test func mainsVersionFourKeepsPomodoroBindingsAndEveryKeyThroughVersionFive() throws {
        let (directory, url) = try temporaryLibraryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = library(version: 4, extra: ", \"pomodoro\": \(Self.mainPomodoro)")
        try Data(fixture.utf8).write(to: url)
        let original = try jsonObject(at: url)

        let store = LibraryStore(fileURL: url)
        #expect(!store.isReadOnly)
        #expect(store.errorMessage == nil)
        let database = store.database
        #expect(database.schemaVersion == 5)
        let pomodoro = database.pomodoro
        #expect(pomodoro.configuration.focusMinutes == 50)
        #expect(pomodoro.configuration.sessionsBeforeLongBreak == 3)
        #expect(pomodoro.configuration.automaticallyStartBreaks)
        #expect(!pomodoro.configuration.playSound)
        #expect(pomodoro.state.status == .paused)
        #expect(pomodoro.state.remainingSeconds == 1_200)
        #expect(pomodoro.state.completedInCycle == 2)
        #expect(pomodoro.sessions.map(\.id.uuidString) == [Self.sessionID])
        // Bindings and favorites main saved for its commands keep working.
        #expect(database.aliasTarget(for: "focus25") == "pomodoro.start")
        #expect(database.aliasTarget(for: "awake") == "caffeinate.toggle")
        #expect(database.favoriteIDs.contains("pomodoro.open"))
        #expect(database.usage.first?.id == "caffeinate.start")
        #expect(database.preferences.clipboardRetentionDays == 14)
        #expect(database.notes.first?.title == "From main")

        // Written as version 5 on the next save, with nothing main wrote left behind.
        #expect(store.update { $0.notes[0].content = "Edited after the merge" })
        let saved = try jsonObject(at: url)
        #expect(saved["schemaVersion"] as? Int == 5)
        #expect(missingKeys(original, in: saved).isEmpty, "lost \(missingKeys(original, in: saved))")
        let reopened = LibraryStore(fileURL: url)
        #expect(reopened.database.pomodoro == pomodoro)
        #expect(reopened.database.binding(for: "pomodoro.start")?.alias == "focus25")
        try reopened.database.validate()
    }

    @Test func mainsVersionFourWithAnInvalidTimerIsRefusedWithMainsValidation() throws {
        let (directory, url) = try temporaryLibraryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = Self.mainPomodoro.replacingOccurrences(of: "\"focusMinutes\": 50", with: "\"focusMinutes\": 500")
        try Data(library(version: 4, extra: ", \"pomodoro\": \(broken)").utf8).write(to: url)
        let store = LibraryStore(fileURL: url)
        #expect(store.errorMessage != nil)
        var database = LibraryDatabase()
        database.pomodoro.configuration.focusMinutes = 500
        #expect(throws: LibraryValidationError.self) { try database.validate() }
    }

    @Test func versionThreeLoadsWithADefaultTimerAndKeepsEveryKey() throws {
        let (directory, url) = try temporaryLibraryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(library(version: 3, extra: "").utf8).write(to: url)
        let original = try jsonObject(at: url)
        let store = LibraryStore(fileURL: url)
        #expect(!store.isReadOnly)
        #expect(store.database.pomodoro == PomodoroData())
        #expect(store.database.preferences.appearance == .light)
        #expect(store.update { $0.notes[0].content = "Edited" })
        let saved = try jsonObject(at: url)
        #expect(saved["schemaVersion"] as? Int == 5)
        #expect(saved["pomodoro"] != nil)
        #expect(missingKeys(original, in: saved).isEmpty, "lost \(missingKeys(original, in: saved))")
    }

    /// The redesign's version 4 (5b7e0bf), written out as that build saved it: its own preference
    /// keys, favorite order, and populated collections.
    private static let redesignLibrary = """
        {"schemaVersion": 4,
         "preferences": {"appearance": "system", "hotKey": "optionSpace", "clipboardEnabled": true,
                         "clipboardImagesEnabled": true, "clipboardFilesEnabled": false, "clipboardRetentionDays": 30,
                         "clipboardLimit": 250, "snippetExpansionEnabled": true,
                         "excludedClipboardBundleIDs": ["com.1password.1password", "com.example.vault"],
                         "firstRunCompleted": true, "rememberLastQuery": false, "barMode": true, "fileSearchScope": "home",
                         "clipboardPaused": false},
         "quicklinks": [{"id": "0B9E5E64-7C61-4B5A-9D0A-4C8C2F5F1A01", "name": "Docs",
                         "template": "https://example.com/search?q={query}", "keyword": "docs"}],
         "snippets": [{"id": "0B9E5E64-7C61-4B5A-9D0A-4C8C2F5F1A02", "name": "Sign-off", "keyword": ";bye",
                       "content": "Best, A. {date}", "expandsKeyword": false}],
         "notes": [{"id": "0B9E5E64-7C61-4B5A-9D0A-4C8C2F5F1A03", "title": "From 2.0", "content": "Ordered favorites",
                    "modifiedAt": 799000000}],
         "clipboard": [],
         "favoriteIDs": ["section.notes", "ai.chat", "quicklink.0B9E5E64-7C61-4B5A-9D0A-4C8C2F5F1A01"],
         "favoriteOrder": ["section.notes", "quicklink.0B9E5E64-7C61-4B5A-9D0A-4C8C2F5F1A01", "ai.chat"],
         "usage": [{"id": "section.notes", "count": 7, "lastUsed": 799990000}],
         "commandBindings": [{"targetID": "ai.proofread", "alias": "fix"}]}
        """

    @Test func theRedesignsVersionFourKeepsItsKeysAndValuesAndGainsAPomodoroTimer() throws {
        let (directory, url) = try temporaryLibraryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(Self.redesignLibrary.utf8).write(to: url)
        let original = try jsonObject(at: url)

        let store = LibraryStore(fileURL: url)
        #expect(!store.isReadOnly)
        #expect(store.errorMessage == nil)
        let database = store.database
        #expect(database.orderedFavoriteIDs.first == "section.notes")
        #expect(database.orderedFavoriteIDs.contains("quicklink.0B9E5E64-7C61-4B5A-9D0A-4C8C2F5F1A01"))
        #expect(database.preferences.clipboardLimit == 250)
        #expect(database.preferences.clipboardRetentionDays == 30)
        #expect(database.preferences.usesBarMode)
        #expect(!database.preferences.remembersLastQuery)
        #expect(database.quicklinks.first?.template == "https://example.com/search?q={query}")
        #expect(database.snippets.first?.content == "Best, A. {date}")
        #expect(database.snippets.first?.expandsKeyword == false)
        #expect(database.notes.first?.title == "From 2.0")
        #expect(database.usage.first?.count == 7)
        #expect(database.aliasTarget(for: "fix") == "ai.proofread")
        #expect(database.pomodoro == PomodoroData())

        #expect(store.update { $0.pomodoro.configuration.dailyGoal = 10 })
        let saved = try jsonObject(at: url)
        #expect(saved["schemaVersion"] as? Int == 5)
        #expect(missingKeys(original, in: saved).isEmpty, "lost \(missingKeys(original, in: saved))")
        let reopened = LibraryStore(fileURL: url).database
        #expect(reopened.pomodoro.configuration.dailyGoal == 10)
        #expect(reopened.snippets == database.snippets)
        #expect(reopened.quicklinks == database.quicklinks)
        #expect(LibraryDatabase.currentSchemaVersion == 5)
    }

    private func populatedPomodoro() -> PomodoroData {
        var pomodoro = PomodoroData()
        pomodoro.configuration.focusMinutes = 45
        pomodoro.state = .ready(phase: .focus, configuration: pomodoro.configuration, completedInCycle: 0)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        pomodoro.sessions = [PomodoroSession(startedAt: start, completedAt: start + 2_700, durationSeconds: 2_700)]
        return pomodoro
    }

    @Test func pomodoroHasItsOwnArchiveCategory() throws {
        var database = LibraryDatabase()
        database.pomodoro = populatedPomodoro()
        database.calculatorHistory = [CalculatorHistoryRecord()]
        try database.validate()
        #expect(LibraryArchive.filtered(database, keeping: [.history]).pomodoro == PomodoroData())
        #expect(LibraryArchive.filtered(database, keeping: [.pomodoro]).pomodoro == database.pomodoro)
        #expect(LibraryArchive.filtered(database, keeping: [.pomodoro]).calculatorHistory.isEmpty)
        #expect(LibraryArchive.count(of: .pomodoro, in: database) == 1)
        #expect(LibraryArchive.count(of: .history, in: database) == 1)
    }

    /// An archive made before Pomodoro existed has a library without `pomodoro` and a manifest
    /// that can't list it. Replacing everything it holds must leave the timer and its sessions.
    @Test func restoringAnArchiveFromBeforePomodoroNeverReplacesTheTimer() throws {
        let library = try TemporaryLibrary()
        let current = populatedPomodoro()
        #expect(library.store.update { $0.pomodoro = current })

        var archived = LibraryDatabase()
        archived.calculatorHistory = [CalculatorHistoryRecord()]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(archived)) as? [String: Any])
        object.removeValue(forKey: "pomodoro")
        let libraryJSON = try JSONSerialization.data(withJSONObject: object)
        let premerge = LibraryArchiveCategory.allCases.filter { $0 != .pomodoro }
        let data = try ArchiveCrafting.archive([(LibraryArchive.libraryFileName, libraryJSON)], categories: premerge)
        let contents = try LibraryArchive.read(data)
        #expect(!contents.categories.contains(.pomodoro))
        #expect(contents.database.pomodoro == PomodoroData())

        // The restore sheet offers what the archive has; asking for everything changes nothing more.
        let report = try library.store.importArchive(
            contents, categories: Set(LibraryArchiveCategory.allCases), mode: .replace)
        #expect(!report.categories.contains(.pomodoro))
        #expect(library.store.database.pomodoro == current)
        #expect(library.store.database.calculatorHistory.count == 1)
        #expect(LibraryStore(fileURL: library.folder.appending(path: "library.json")).database.pomodoro == current)
    }

    @Test func anArchiveThatListsPomodoroReplacesOrMergesIt() throws {
        let library = try TemporaryLibrary()
        let current = populatedPomodoro()
        #expect(library.store.update { $0.pomodoro = current })
        var archived = LibraryDatabase()
        archived.pomodoro.configuration.dailyGoal = 3
        let start = Date(timeIntervalSinceReferenceDate: 801_000_000)
        archived.pomodoro.sessions = [PomodoroSession(startedAt: start, completedAt: start + 1_500, durationSeconds: 1_500)]
        let data = try ArchiveCrafting.archive(
            [(LibraryArchive.libraryFileName, try JSONEncoder().encode(archived))], categories: [.pomodoro])
        let contents = try LibraryArchive.read(data)

        _ = try library.store.importArchive(contents, categories: [.pomodoro], mode: .merge)
        #expect(library.store.database.pomodoro.configuration == current.configuration)
        #expect(library.store.database.pomodoro.sessions.count == 2)
        _ = try library.store.importArchive(contents, categories: [.pomodoro], mode: .replace)
        #expect(library.store.database.pomodoro == archived.pomodoro)
    }

    @Test func anArchiveThatListsPomodoroWithoutItsDataIsRefused() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryDatabase())) as? [String: Any])
        object.removeValue(forKey: "pomodoro")
        let missing = try JSONSerialization.data(withJSONObject: object)
        let archive = try ArchiveCrafting.archive([(LibraryArchive.libraryFileName, missing)], categories: [.pomodoro])
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.read(archive) }
        object["pomodoro"] = NSNull()
        let null = try JSONSerialization.data(withJSONObject: object)
        let nullArchive = try ArchiveCrafting.archive([(LibraryArchive.libraryFileName, null)], categories: [.pomodoro])
        #expect(throws: (any Error).self) { try LibraryArchive.read(nullArchive) }
        // The same library is fine when the archive doesn't claim Pomodoro.
        object.removeValue(forKey: "pomodoro")
        let history = try ArchiveCrafting.archive(
            [(LibraryArchive.libraryFileName, try JSONSerialization.data(withJSONObject: object))], categories: [.history])
        #expect(try LibraryArchive.read(history).categories == [.history])
    }
}
