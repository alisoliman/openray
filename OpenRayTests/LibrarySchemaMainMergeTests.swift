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

    /// Every key of `old`, recursively through objects, is still in `new`.
    private func missingKeys(_ old: [String: Any], in new: [String: Any], path: String = "") -> [String] {
        old.flatMap { key, value -> [String] in
            guard let replacement = new[key] else { return [path + key] }
            if let value = value as? [String: Any], let replacement = replacement as? [String: Any] {
                return missingKeys(value, in: replacement, path: path + key + ".")
            }
            return []
        }
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

    @Test func theRedesignsVersionFourKeepsItsKeysAndGainsAPomodoroTimer() throws {
        let (directory, url) = try temporaryLibraryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The redesign's version 4: favorite order and its preferences, without the v5 collections.
        var redesign = LibraryDatabase()
        redesign.schemaVersion = 4
        redesign.notes = [QuickNote(title: "From 2.0", content: "Ordered favorites")]
        redesign.favoriteIDs = ["section.notes", "ai.chat"]
        redesign.favoriteOrder = ["section.notes", "ai.chat"]
        redesign.preferences.clipboardLimit = 250
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(redesign)) as? [String: Any])
        for key in [
            "aiCommands", "agents", "disabledCommandIDs", "fallbackOrder", "scriptDirectories", "windowLayouts",
            "focusCategories", "emojiUsage", "calculatorHistory", "commandPreferences", "pomodoro",
        ] {
            object.removeValue(forKey: key)
        }
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let original = try jsonObject(at: url)

        let store = LibraryStore(fileURL: url)
        #expect(!store.isReadOnly)
        #expect(store.database.orderedFavoriteIDs == ["section.notes", "ai.chat"])
        #expect(store.database.preferences.clipboardLimit == 250)
        #expect(store.database.pomodoro == PomodoroData())
        #expect(store.update { $0.pomodoro.configuration.dailyGoal = 10 })
        let saved = try jsonObject(at: url)
        #expect(saved["schemaVersion"] as? Int == 5)
        #expect(missingKeys(original, in: saved).isEmpty, "lost \(missingKeys(original, in: saved))")
        #expect(LibraryStore(fileURL: url).database.pomodoro.configuration.dailyGoal == 10)
        #expect(LibraryDatabase.currentSchemaVersion == 5)
    }

    @Test func archivesCarryPomodoroWithHistoryOnly() throws {
        var database = LibraryDatabase()
        database.pomodoro.configuration.focusMinutes = 45
        database.pomodoro.state = .ready(phase: .focus, configuration: database.pomodoro.configuration, completedInCycle: 0)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        database.pomodoro.sessions = [PomodoroSession(startedAt: start, completedAt: start + 2_700, durationSeconds: 2_700)]
        try database.validate()

        let withoutHistory = LibraryArchive.filtered(database, keeping: [.notes])
        #expect(withoutHistory.pomodoro == PomodoroData())
        let withHistory = LibraryArchive.filtered(database, keeping: [.history])
        #expect(withHistory.pomodoro == database.pomodoro)
        #expect(LibraryArchive.count(of: .history, in: database) == 1)
    }
}
