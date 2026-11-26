import AppKit
import Foundation
import Testing

@testable import OpenRay

/// A library in a temporary folder, with its images and other store files, removed afterwards.
@MainActor
final class TemporaryLibrary {
    let folder: URL
    let store: LibraryStore

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "OpenRayArchiveTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = LibraryStore(fileURL: folder.appending(path: "library.json"))
    }

    func write(_ path: String, _ text: String) throws {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func contents(of path: String) -> String? {
        (try? Data(contentsOf: folder.appending(path: path))).map { String(decoding: $0, as: UTF8.self) }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }
}

@Suite("Library archives")
@MainActor
struct LibraryArchiveTests {
    static let fastIterations = 1_000

    /// A library with something in every category the parity build stores today, plus a
    /// clipboard image and another store file beside library.json.
    func populated() throws -> TemporaryLibrary {
        let library = try TemporaryLibrary()
        let store = library.store
        let image = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        #expect(
            store.update { database in
                database.preferences.clipboardEnabled = true
                database.preferences.clipboardImagesEnabled = true
                database.snippets = [Snippet(name: "Signature", keyword: "sig", content: "Best, Ada")]
                database.notes = [QuickNote(title: "Plan", content: "Plan\nShip the archive")]
                database.quicklinks.append(Quicklink(name: "Docs", template: "https://example.com/search?q={query}", keyword: "docs"))
                database.commandBindings = [CommandBinding(targetID: "section.files", alias: "ff")]
                database.scriptDirectories = [ScriptDirectoryRecord(path: "/Users/x/Scripts")]
                database.windowLayouts = [WindowLayoutRecord()]
                database.calculatorHistory = [CalculatorHistoryRecord()]
                database.commandPreferences = ["script.0123456789abcdef": ["fallback": "true"]]
                database.favoriteIDs.insert("section.quicklinks")
            })
        #expect(store.captureImage(image, sourceName: "Preview"))
        #expect(store.capture(ClipboardEntry(text: "copied text", sourceName: "Notes")))
        try library.write("chats.json", #"{"chats":[]}"#)
        try library.write(LibraryBackupSettingsStore.fileName, #"{"isEnabled":true}"#)
        try library.write("library-pending-cleanup.json", "[]")
        try library.write(".DS_Store", "x")
        return library
    }

    // MARK: Round trips

    @Test("An archive of everything round-trips: library, clipboard images and other store files")
    func roundTrip() throws {
        let source = try populated()
        let archive = try LibraryArchive.make(
            database: source.store.database, directory: source.folder,
            categories: Set(LibraryArchiveCategory.allCases), iterations: Self.fastIterations)
        #expect(try !LibraryArchive.isEncrypted(archive))
        let contents = try LibraryArchive.read(archive)
        #expect(contents.categories == Set(LibraryArchiveCategory.allCases))
        let imageID = try #require(source.store.database.clipboard.compactMap(\.image).first?.id)
        #expect(Set(contents.files.keys) == ["ClipboardImages/\(imageID).png", "chats.json"])

        let target = try TemporaryLibrary()
        let report = try target.store.importArchive(contents, categories: contents.categories, mode: .replace)
        #expect(report.filesWritten == 2)
        let before = source.store.database
        let after = target.store.database
        #expect(after.snippets == before.snippets)
        #expect(after.notes == before.notes)
        #expect(after.quicklinks == before.quicklinks)
        #expect(after.clipboard == before.clipboard)
        #expect(after.commandBindings == before.commandBindings)
        #expect(after.scriptDirectories == before.scriptDirectories)
        #expect(after.windowLayouts == before.windowLayouts)
        #expect(after.calculatorHistory == before.calculatorHistory)
        #expect(after.commandPreferences == before.commandPreferences)
        #expect(after.favoriteIDs == before.favoriteIDs)
        #expect(after.preferences == before.preferences)
        #expect(target.contents(of: "chats.json") == #"{"chats":[]}"#)
        // The imported picture is there for the entry that shows it.
        let entry = try #require(after.clipboard.first { $0.image != nil })
        #expect(target.store.imageData(for: try #require(entry.image)) != nil)
        // Machine-local and hidden files never travel.
        #expect(target.contents(of: LibraryBackupSettingsStore.fileName) == nil)
        #expect(target.contents(of: ".DS_Store") == nil)
        // The library on disk is the imported one.
        let reloaded = LibraryStore(fileURL: target.folder.appending(path: "library.json"))
        #expect(reloaded.database.snippets == before.snippets)
    }

    @Test("Encrypted archives need the passphrase and hide their contents")
    func encryption() throws {
        let source = try populated()
        let archive = try LibraryArchive.make(
            database: source.store.database, directory: source.folder,
            categories: Set(LibraryArchiveCategory.allCases), passphrase: "correct horse battery",
            iterations: Self.fastIterations)
        #expect(try LibraryArchive.isEncrypted(archive))
        #expect(archive.range(of: Data("Best, Ada".utf8)) == nil)
        #expect(archive.range(of: Data("library.json".utf8)) == nil)
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.read(archive) }
        #expect(throws: LibraryArchive.Failure("The passphrase is wrong, or the archive is damaged.")) {
            try LibraryArchive.read(archive, passphrase: "wrong horse")
        }
        let contents = try LibraryArchive.read(archive, passphrase: "correct horse battery")
        #expect(contents.database.snippets == source.store.database.snippets)
        #expect(contents.files.count == 2)
        // The passphrase is normalized, so a decomposed é opens what a composed one sealed.
        let accented = try LibraryArchive.make(
            database: source.store.database, directory: nil, categories: [.snippets], passphrase: "caf\u{E9} au lait",
            iterations: Self.fastIterations)
        #expect(try LibraryArchive.read(accented, passphrase: "cafe\u{301} au lait").database.snippets.count == 1)
    }

    @Test("Tampering with an encrypted archive's body or header is detected")
    func tampering() throws {
        let source = try populated()
        let archive = try LibraryArchive.make(
            database: source.store.database, directory: nil, categories: [.snippets], passphrase: "passphrase!",
            iterations: Self.fastIterations)
        var body = archive
        body[body.count - 20] ^= 0xFF
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.read(body, passphrase: "passphrase!") }
        // The header is authenticated: changing the iteration count breaks decryption.
        let range = try #require(archive.range(of: Data("\"iterations\":1000".utf8)))
        var changed = archive
        changed.replaceSubrange(range, with: Data("\"iterations\":1001".utf8))
        #expect(changed.count == archive.count)
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.read(changed, passphrase: "passphrase!") }
        #expect(try LibraryArchive.read(archive, passphrase: "passphrase!").database.snippets.count == 1)
    }

    @Test("Damaged, foreign and newer archives are refused")
    func refusals() throws {
        let source = try populated()
        #expect(throws: LibraryArchive.Failure("That file isn't an OpenRay archive.")) {
            try LibraryArchive.read(Data("{\"not\":\"an archive\"}".utf8))
        }
        var archive = try LibraryArchive.make(database: source.store.database, directory: nil, categories: [.notes])
        archive[archive.count - 3] ^= 0x01
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.read(archive) }
        var future = source.store.database
        future.schemaVersion = LibraryDatabase.currentSchemaVersion + 1
        let newer = try LibraryArchive.make(database: future, directory: nil, categories: [.notes])
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.read(newer) }
        #expect(throws: LibraryArchive.Failure.self) {
            try LibraryArchive.make(database: source.store.database, directory: nil, categories: [])
        }
    }

    // MARK: Selection

    @Test("An export carries only the chosen categories and their files")
    func selectiveExport() throws {
        let source = try populated()
        let archive = try LibraryArchive.make(
            database: source.store.database, directory: source.folder, categories: [.snippets, .otherData])
        let contents = try LibraryArchive.read(archive)
        #expect(contents.categories == [.snippets, .otherData])
        #expect(contents.database.snippets.count == 1)
        #expect(contents.database.notes.isEmpty)
        #expect(contents.database.clipboard.isEmpty)
        #expect(contents.database.commandBindings.isEmpty)
        #expect(Set(contents.files.keys) == ["chats.json"])
        let preview = LibraryArchive.preview(contents, current: source.store.database)
        #expect(preview.map(\.category) == [.snippets, .otherData])
        #expect(preview[0].archived == 1)
        #expect(preview[0].current == 1)
        #expect(preview[1].files == 1)
    }

    @Test("Merging updates matching items, adds new ones, and frees clashing keywords and aliases")
    func merge() throws {
        let target = try TemporaryLibrary()
        let shared = UUID()
        target.store.update { database in
            database.snippets = [
                Snippet(id: shared, name: "Address", keyword: "addr", content: "Old street"),
                Snippet(name: "Signature", keyword: "sig", content: "Mine"),
            ]
            database.notes = [QuickNote(title: "Mine", content: "Mine")]
            database.commandBindings = [CommandBinding(targetID: "section.files", alias: "ff")]
        }
        var incoming = LibraryDatabase()
        incoming.snippets = [
            Snippet(id: shared, name: "Address", keyword: "addr", content: "New street"),
            Snippet(name: "Their Signature", keyword: "sig", content: "Theirs"),
        ]
        incoming.notes = [QuickNote(title: "Theirs", content: "Theirs")]
        incoming.commandBindings = [CommandBinding(targetID: "section.notes", alias: "ff")]
        let archive = try LibraryArchive.make(
            database: incoming, directory: nil, categories: [.snippets, .notes, .shortcuts])
        let contents = try LibraryArchive.read(archive)

        let report = try target.store.importArchive(contents, categories: [.snippets, .shortcuts], mode: .merge)
        let snippets = target.store.database.snippets
        #expect(snippets.map(\.name) == ["Address", "Signature", "Their Signature"])
        #expect(snippets[0].content == "New street")
        #expect(snippets[1].keyword == "sig")
        #expect(snippets[2].keyword == "")
        #expect(target.store.database.commandBindings.map(\.targetID) == ["section.files"])
        #expect(report.notes.count == 2)
        // Notes weren't chosen, so they're untouched.
        #expect(target.store.database.notes.map(\.title) == ["Mine"])

        _ = try target.store.importArchive(contents, categories: [.notes], mode: .replace)
        #expect(target.store.database.notes.map(\.title) == ["Theirs"])
        #expect(target.store.database.snippets.count == 3)
    }

    @Test("Merging favorites and usage keeps both, with the larger count and the later date")
    func mergeFavorites() {
        var current = LibraryDatabase()
        current.favoriteIDs = ["a"]
        current.favoriteOrder = ["a"]
        current.usage = [UsageRecord(id: "x", count: 3, lastUsed: Date(timeIntervalSince1970: 10))]
        var incoming = LibraryDatabase()
        incoming.favoriteIDs = ["b", "a"]
        incoming.favoriteOrder = ["b", "a"]
        incoming.usage = [
            UsageRecord(id: "x", count: 1, lastUsed: Date(timeIntervalSince1970: 20)),
            UsageRecord(id: "y", count: 2, lastUsed: Date(timeIntervalSince1970: 5)),
        ]
        let merged = LibraryArchive.merged(current: current, incoming: incoming, categories: [.favorites], mode: .merge).database
        #expect(merged.favoriteOrder == ["a", "b"])
        #expect(merged.usage.first { $0.id == "x" } == UsageRecord(id: "x", count: 3, lastUsed: Date(timeIntervalSince1970: 20)))
        #expect(merged.usage.contains { $0.id == "y" })
    }

    @Test("Script folders already listed aren't added twice")
    func mergeScripts() {
        var current = LibraryDatabase()
        current.scriptDirectories = [ScriptDirectoryRecord(path: "/a")]
        var incoming = LibraryDatabase()
        incoming.scriptDirectories = [ScriptDirectoryRecord(path: "/a"), ScriptDirectoryRecord(path: "/b")]
        let merged = LibraryArchive.merged(current: current, incoming: incoming, categories: [.scripts], mode: .merge).database
        #expect(merged.scriptDirectories.map(\.path) == ["/a", "/b"])
    }

    @Test("A failed import changes nothing")
    func atomicImport() throws {
        let target = try TemporaryLibrary()
        target.store.update { $0.snippets = [Snippet(name: "Keep", keyword: "", content: "x")] }
        var incoming = LibraryDatabase()
        incoming.preferences.clipboardLimit = 9_999
        let contents = try LibraryArchive.read(
            try LibraryArchive.make(database: incoming, directory: nil, categories: [.settings]))
        #expect(throws: LibraryArchive.Failure.self) {
            try target.store.importArchive(contents, categories: [.settings], mode: .replace)
        }
        #expect(target.store.database.snippets.map(\.name) == ["Keep"])
        #expect(target.store.database.preferences.clipboardLimit != 9_999)
        #expect(!target.store.replaceLibrary(with: incoming))
    }

    // MARK: Paths

    @Test("Archive paths can't leave the library's folder")
    func paths() throws {
        for bad in ["../escape", "/etc/hosts", ".hidden/file", "a//b", "a/./b", "", "x/../../y"] {
            #expect(throws: LibraryArchive.Failure.self, "\(bad)") { try LibraryArchive.validate(bad) }
        }
        try LibraryArchive.validate("ClipboardImages/abc.png")
        try LibraryArchive.validate("chats.json")
        let target = try TemporaryLibrary()
        #expect(throws: LibraryArchive.Failure.self) {
            try LibraryArchive.install(["../outside.txt": Data("x".utf8)], categories: [.otherData], mode: .replace, into: target.folder)
        }
        #expect(!FileManager.default.fileExists(atPath: target.folder.deletingLastPathComponent().appending(path: "outside.txt").path))
    }

    @Test("Images whose bytes don't match their name aren't installed; merging keeps existing files")
    func install() throws {
        let target = try TemporaryLibrary()
        let png = Data("png bytes".utf8)
        let good = "ClipboardImages/\(ClipboardImageCodec.digest(png)).png"
        let bad = "ClipboardImages/\(String(repeating: "a", count: 64)).png"
        try target.write("chats.json", "mine")
        let written = try LibraryArchive.install(
            [good: png, bad: png, "chats.json": Data("theirs".utf8)], categories: [.clipboard, .otherData], mode: .merge,
            into: target.folder)
        #expect(written == 1)
        #expect(FileManager.default.fileExists(atPath: target.folder.appending(path: good).path))
        #expect(!FileManager.default.fileExists(atPath: target.folder.appending(path: bad).path))
        #expect(target.contents(of: "chats.json") == "mine")
        try LibraryArchive.install(["chats.json": Data("theirs".utf8)], categories: [.otherData], mode: .replace, into: target.folder)
        #expect(target.contents(of: "chats.json") == "theirs")
    }
}

@Suite("Backups")
@MainActor
struct LibraryBackupTests {
    func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenRayBackupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Backup names sort by time and rotation keeps the newest, leaving other files alone")
    func rotation() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("mine".utf8).write(to: folder.appending(path: "notes.txt"))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var written: [URL] = []
        for day in 0..<5 {
            written.append(try LibraryBackup.write(Data("archive \(day)".utf8), to: folder, keep: 3, now: start.addingTimeInterval(Double(day) * 86_400)))
        }
        let kept = try LibraryBackup.backups(in: folder)
        #expect(kept.map(\.lastPathComponent) == written.suffix(3).reversed().map(\.lastPathComponent))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "notes.txt").path))
        #expect(LibraryBackup.fileName(for: start).hasPrefix(LibraryBackup.namePrefix))
        #expect(LibraryBackup.fileName(for: start).hasSuffix(".\(LibraryArchive.fileExtension)"))
        // Two backups in the same second don't overwrite each other.
        let again = try LibraryBackup.write(Data("again".utf8), to: folder, keep: 10, now: start.addingTimeInterval(4 * 86_400))
        #expect(again.lastPathComponent != written.last?.lastPathComponent)
        #expect(try LibraryBackup.rotate(in: folder, keep: 1).count == 3)
    }

    @Test("A backup is due once its interval passes, only when on and with a folder")
    func due() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var settings = LibraryBackupSettings()
        #expect(!settings.isDue(at: now))
        settings.isEnabled = true
        #expect(!settings.isDue(at: now))
        settings.folderPath = "/tmp/backups"
        #expect(settings.isDue(at: now))
        settings.lastBackupAt = now.addingTimeInterval(-86_000)
        #expect(!settings.isDue(at: now))
        settings.lastBackupAt = now.addingTimeInterval(-86_400)
        #expect(settings.isDue(at: now))
        settings.frequency = .weekly
        #expect(!settings.isDue(at: now))
        settings.lastBackupAt = now.addingTimeInterval(-7 * 86_400)
        #expect(settings.isDue(at: now))
    }

    @Test("Backup settings persist beside the library, with the count kept in range")
    func settingsPersist() throws {
        let library = try TemporaryLibrary()
        let settings = LibraryBackupSettingsStore(libraryURL: library.store.fileURL)
        #expect(settings.update {
            $0.isEnabled = true
            $0.folderPath = "/tmp/x"
            $0.keep = 500
        })
        #expect(settings.settings.keep == 100)
        let reloaded = LibraryBackupSettingsStore(libraryURL: library.store.fileURL)
        #expect(reloaded.settings == settings.settings)
        let memory = LibraryBackupSettingsStore(libraryURL: nil)
        memory.update { $0.keep = 0 }
        #expect(memory.settings.keep == 1)
    }

    @Test("Back Up Now writes an archive that imports, records the date and rotates")
    func backUpNow() async throws {
        let library = try TemporaryLibrary()
        library.store.update { $0.snippets = [Snippet(name: "Saved", keyword: "", content: "x")] }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = LibraryBackupSettingsStore(libraryURL: library.store.fileURL)
        settings.update {
            $0.folderPath = folder.path
            $0.keep = 2
            $0.isEnabled = true
        }
        let scheduler = LibraryBackupScheduler(store: library.store, settings: settings)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try await scheduler.backUpNow(now: now)
        #expect(settings.settings.lastBackupAt == now)
        let contents = try LibraryArchive.read(try Data(contentsOf: url))
        #expect(contents.database.snippets.map(\.name) == ["Saved"])
        #expect(await scheduler.backUpIfDue(now: now.addingTimeInterval(60)) == nil)
        #expect(await scheduler.backUpIfDue(now: now.addingTimeInterval(86_400)) != nil)
        _ = try await scheduler.backUpNow(now: now.addingTimeInterval(2 * 86_400))
        #expect(try LibraryBackup.backups(in: folder).count == 2)
    }

    @Test("While inert, backups never schedule and never write outside the temporary folder")
    func inert() async throws {
        let library = try TemporaryLibrary()
        let settings = LibraryBackupSettingsStore(libraryURL: nil)
        let outside = URL(fileURLWithPath: "/Users/Shared/OpenRay Backup Test \(UUID().uuidString)")
        settings.update {
            $0.isEnabled = true
            $0.folderPath = outside.path
        }
        let scheduler = LibraryBackupScheduler(store: library.store, settings: settings)
        scheduler.start()
        #expect(!scheduler.isRunning)
        await #expect(throws: SideEffectGuard.Blocked.self) { try await scheduler.backUpNow() }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(await scheduler.backUpIfDue() == nil)
    }

    @Test("The archive commands are bindable, and Back Up Now asks for a folder first")
    func commands() throws {
        let provider = LibraryArchiveProvider()
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(), registry: CommandRegistry(providers: [provider]))
        let ids = model.commandItems.map(\.id)
        #expect(ids.contains(LibraryArchiveProvider.backUpID))
        #expect(ids.contains(LibraryArchiveProvider.exportID))
        #expect(LibraryArchiveProvider.registration.acceptsBinding(LibraryArchiveProvider.backUpID))
        let backUp = try #require(model.commandItems.first { $0.id == LibraryArchiveProvider.backUpID })
        #expect(backUp.subtitle.contains("Choose a backup folder"))
        model.perform(backUp)
        #expect(model.feedback == nil)
        #expect(!provider.scheduler(for: model).isBackingUp)
    }
}
