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

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: folder.appending(path: path).path) }

    deinit { try? FileManager.default.removeItem(at: folder) }
}

/// Builds archive containers by hand, to feed the reader what OpenRay itself never writes.
enum ArchiveCrafting {
    static func uint32(_ value: Int) -> Data {
        let big = UInt32(value).bigEndian
        return withUnsafeBytes(of: big) { Data($0) }
    }

    static func entry(_ path: String, _ data: Data) -> LibraryArchive.FileEntry {
        LibraryArchive.FileEntry(path: path, size: data.count, sha256: LibraryArchive.digest(data), category: nil)
    }

    /// A plain archive with exactly these files, in order, and these header bytes.
    static func archive(
        _ files: [(String, Data)], categories: [LibraryArchiveCategory] = LibraryArchiveCategory.allCases,
        flags: UInt8 = 0, header: Data = Data(#"{"format":1}"#.utf8)
    ) throws -> Data {
        let manifest = LibraryArchive.Manifest(
            createdAt: Date(timeIntervalSince1970: 0), appVersion: "test", schemaVersion: 5, categories: categories,
            files: files.map { entry($0.0, $0.1) })
        let manifestData = try JSONEncoder().encode(manifest)
        var data = LibraryArchive.magic
        data.append(1)
        data.append(flags)
        data.append(uint32(header.count))
        data.append(header)
        data.append(uint32(manifestData.count))
        data.append(manifestData)
        for (_, bytes) in files { data.append(bytes) }
        return data
    }

    static func library(_ database: LibraryDatabase = LibraryDatabase()) throws -> Data { try JSONEncoder().encode(database) }
}

@Suite("Library archives")
@MainActor
struct LibraryArchiveTests {
    /// The reader's minimum, to keep the tests quick.
    static let fastIterations = LibraryArchive.iterationRange.lowerBound

    /// A library with something in every category the parity build stores today, a clipboard
    /// image, and this Mac's own files beside library.json.
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
        try library.write(LocalApprovalStore.fileName, "{}")
        try library.write("library-pending-cleanup.json", "[]")
        try library.write(".DS_Store", "x")
        return library
    }

    func make(
        _ library: TemporaryLibrary, _ categories: Set<LibraryArchiveCategory> = Set(LibraryArchiveCategory.allCases),
        passphrase: String? = nil
    ) throws -> Data {
        try LibraryArchive.make(
            database: library.store.database, directory: library.folder, categories: categories, passphrase: passphrase,
            iterations: Self.fastIterations
        ).data
    }

    // MARK: Round trips

    @Test("An archive of everything round-trips: the library and its clipboard pictures, nothing of this Mac's")
    func roundTrip() throws {
        let source = try populated()
        let archive = try make(source)
        #expect(try !LibraryArchive.isEncrypted(archive))
        let contents = try LibraryArchive.read(archive)
        #expect(contents.categories == Set(LibraryArchiveCategory.allCases))
        let imageID = try #require(source.store.database.clipboard.compactMap(\.image).first?.id)
        // Only portable store files travel: not chats.json (no store owns it), never this Mac's own files.
        #expect(Set(contents.files.keys) == ["ClipboardImages/\(imageID).png"])

        let target = try TemporaryLibrary()
        let report = try target.store.importArchive(contents, categories: contents.categories, mode: .replace)
        #expect(report.filesWritten == 1)
        let before = source.store.database
        let after = target.store.database
        #expect(after.snippets == before.snippets)
        #expect(after.notes == before.notes)
        #expect(after.quicklinks == before.quicklinks)
        #expect(after.clipboard == before.clipboard)
        #expect(after.commandBindings == before.commandBindings)
        #expect(after.windowLayouts == before.windowLayouts)
        #expect(after.calculatorHistory == before.calculatorHistory)
        #expect(after.commandPreferences == before.commandPreferences)
        #expect(after.favoriteIDs == before.favoriteIDs)
        #expect(after.preferences == before.preferences)
        // Script folders arrive turned off.
        #expect(after.scriptDirectories.map(\.path) == ["/Users/x/Scripts"])
        #expect(after.scriptDirectories.allSatisfy { !$0.isEnabled })
        let entry = try #require(after.clipboard.first { $0.image != nil })
        #expect(target.store.imageData(for: try #require(entry.image)) != nil)
        for local in [LibraryBackupSettingsStore.fileName, LocalApprovalStore.fileName, "chats.json", ".DS_Store"] {
            #expect(!target.exists(local), "\(local)")
        }
        let reloaded = LibraryStore(fileURL: target.folder.appending(path: "library.json"))
        #expect(reloaded.database.snippets == before.snippets)
    }

    @Test("Encrypted archives need the passphrase and hide their contents")
    func encryption() throws {
        let source = try populated()
        let archive = try make(source, passphrase: "correct horse battery")
        #expect(try LibraryArchive.isEncrypted(archive))
        #expect(archive.range(of: Data("Best, Ada".utf8)) == nil)
        #expect(archive.range(of: Data("library.json".utf8)) == nil)
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.read(archive) }
        #expect(throws: LibraryArchive.Failure("The passphrase is wrong, or the archive is damaged.")) {
            try LibraryArchive.read(archive, passphrase: "wrong horse")
        }
        let contents = try LibraryArchive.read(archive, passphrase: "correct horse battery")
        #expect(contents.database.snippets == source.store.database.snippets)
        #expect(contents.files.count == 1)
        // The passphrase is normalized, so a decomposed é opens what a composed one sealed.
        let accented = try LibraryArchive.make(
            database: source.store.database, directory: nil, categories: [.snippets], passphrase: "caf\u{E9} au lait",
            iterations: Self.fastIterations
        ).data
        #expect(try LibraryArchive.read(accented, passphrase: "cafe\u{301} au lait").database.snippets.count == 1)
    }

    @Test("Tampering with an encrypted archive's body or header is detected")
    func tampering() throws {
        let source = try populated()
        let archive = try make(source, [.snippets], passphrase: "passphrase!")
        var body = archive
        body[body.count - 20] ^= 0xFF
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.read(body, passphrase: "passphrase!") }
        // The header is authenticated: changing the iteration count breaks decryption.
        let original = Data("\"iterations\":\(Self.fastIterations)".utf8)
        let range = try #require(archive.range(of: original))
        var changed = archive
        changed.replaceSubrange(range, with: Data("\"iterations\":\(Self.fastIterations + 1)".utf8))
        #expect(changed.count == archive.count)
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.read(changed, passphrase: "passphrase!") }
        #expect(try LibraryArchive.read(archive, passphrase: "passphrase!").database.snippets.count == 1)
    }

    @Test("Only the v1 suite is read: unknown flags, labels, salt sizes and iteration counts are refused")
    func strictHeader() throws {
        let library = try ArchiveCrafting.library()
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.read(try ArchiveCrafting.archive([("library.json", library)], flags: 2)) }
        let salt = Data(repeating: 7, count: 16).base64EncodedString()
        for header in [
            #"{"format":1,"encryption":{"algorithm":"AES-128-CBC","keyDerivation":"PBKDF2-HMAC-SHA256","iterations":600000,"salt":"\#(salt)"}}"#,
            #"{"format":1,"encryption":{"algorithm":"AES-256-GCM","keyDerivation":"scrypt","iterations":600000,"salt":"\#(salt)"}}"#,
            #"{"format":1,"encryption":{"algorithm":"AES-256-GCM","keyDerivation":"PBKDF2-HMAC-SHA256","iterations":10,"salt":"\#(salt)"}}"#,
            #"{"format":1,"encryption":{"algorithm":"AES-256-GCM","keyDerivation":"PBKDF2-HMAC-SHA256","iterations":600000,"salt":"AAAA"}}"#,
        ] {
            let crafted = try ArchiveCrafting.archive([("library.json", library)], flags: 1, header: Data(header.utf8))
            #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.isEncrypted(crafted) }
        }
        #expect(throws: LibraryArchive.Failure.self) {
            try LibraryArchive.make(database: LibraryDatabase(), directory: nil, categories: [.notes], passphrase: "x", iterations: 1_000)
        }
    }

    @Test("Damaged, foreign and newer archives are refused")
    func refusals() throws {
        let source = try populated()
        #expect(throws: LibraryArchive.Failure("That file isn't an OpenRay archive.")) {
            try LibraryArchive.read(Data("{\"not\":\"an archive\"}".utf8))
        }
        var archive = try make(source, [.notes])
        archive[archive.count - 3] ^= 0x01
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.read(archive) }
        var future = source.store.database
        future.schemaVersion = LibraryDatabase.currentSchemaVersion + 1
        let newer = try LibraryArchive.make(database: future, directory: nil, categories: [.notes]).data
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.read(newer) }
        #expect(throws: LibraryArchive.Failure.self) {
            try LibraryArchive.make(database: source.store.database, directory: nil, categories: [])
        }
    }

    // MARK: Names the reader refuses (blocker 1)

    @Test("An archive naming the library or this Mac's files, under any spelling, is refused")
    func reservedNames() throws {
        let library = try ArchiveCrafting.library()
        for name in [
            "LIBRARY.json", "Library.JSON", "library-pending-cleanup.json", "local-approvals.json", "LOCAL-APPROVALS.JSON",
            "backup-settings.json", "currency-rates.json", "ClipboardImages/library.json",
        ] {
            let crafted = try ArchiveCrafting.archive([("library.json", library), (name, Data("{}".utf8))])
            #expect(throws: LibraryArchive.Failure.self, "\(name)") { try LibraryArchive.read(crafted) }
        }
    }

    @Test("Files no portable store owns, duplicates and aliases are refused")
    func unportableAndDuplicateNames() throws {
        let library = try ArchiveCrafting.library()
        let png = Data("png".utf8)
        let digest = LibraryArchive.digest(png)
        let name = "ClipboardImages/\(digest).png"
        for files in [
            [("library.json", library), ("chats.json", Data("{}".utf8))],
            [("library.json", library), ("ClipboardImages/notes.txt", Data("x".utf8))],
            [("library.json", library), ("ClipboardImages/sub/\(digest).png", png)],
            [("library.json", library), (name, png), (name, png)],
            [("library.json", library), (name, png), ("ClipboardImages/\(digest.uppercased()).png", png)],
            [("library.json", library), ("library.json", library)],
        ] {
            let crafted = try ArchiveCrafting.archive(files)
            #expect(throws: LibraryArchive.Failure.self, "\(files.map(\.0))") { try LibraryArchive.read(crafted) }
        }
        #expect(try LibraryArchive.read(try ArchiveCrafting.archive([("library.json", library), (name, png)])).files.count == 1)
    }

    @Test("Archive paths can't be unsafe")
    func paths() throws {
        let digest = String(repeating: "a", count: 64)
        for bad in [
            "../escape", "/etc/hosts", ".hidden/file", "a//b", "a/./b", "", "x/../../y", "chats.json",
            "ClipboardImages/../library.json", "ClipboardImages/abc.png",
        ] {
            #expect(throws: LibraryArchive.Failure.self, "\(bad)") { try LibraryArchive.validate(bad) }
        }
        try LibraryArchive.validate("ClipboardImages/\(digest).png")
        try LibraryArchive.validate("ClipboardImages/\(digest).rich")
        try LibraryArchive.validate("ClipboardImages/\(digest).txt")
    }

    // MARK: Selection

    @Test("An export carries only the chosen categories and their files")
    func selectiveExport() throws {
        let source = try populated()
        let contents = try LibraryArchive.read(try make(source, [.snippets]))
        #expect(contents.categories == [.snippets])
        #expect(contents.database.snippets.count == 1)
        #expect(contents.database.notes.isEmpty)
        #expect(contents.database.clipboard.isEmpty)
        #expect(contents.database.commandBindings.isEmpty)
        #expect(contents.files.isEmpty)
        let preview = LibraryArchive.preview(contents, current: source.store.database)
        #expect(preview.map(\.category) == [.snippets])
        #expect(preview[0].archived == 1)
        #expect(preview[0].current == 1)
        #expect(!LibraryArchive.exportableCategories.contains(.otherData))
    }

    @Test("An export leaves out entries whose pictures are missing, and says so")
    func exportChecksPictures() throws {
        let source = try populated()
        let image = try #require(source.store.database.clipboard.compactMap(\.image).first)
        try FileManager.default.removeItem(at: source.folder.appending(path: "ClipboardImages/\(image.id).png"))
        let built = try LibraryArchive.make(
            database: source.store.database, directory: source.folder, categories: [.clipboard])
        #expect(built.omissions.count == 1)
        let contents = try LibraryArchive.read(built.data)
        #expect(contents.database.clipboard.allSatisfy { $0.image == nil })
        #expect(contents.database.clipboard.count == 1)
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
        let contents = try LibraryArchive.read(
            try LibraryArchive.make(database: incoming, directory: nil, categories: [.snippets, .notes, .shortcuts]).data)

        let report = try target.store.importArchive(contents, categories: [.snippets, .shortcuts], mode: .merge)
        let snippets = target.store.database.snippets
        #expect(snippets.map(\.name) == ["Address", "Signature", "Their Signature"])
        #expect(snippets[0].content == "New street")
        #expect(snippets[1].keyword == "sig")
        #expect(snippets[2].keyword == "")
        #expect(target.store.database.commandBindings.map(\.targetID) == ["section.files"])
        #expect(report.notes.count == 2)
        #expect(target.store.database.notes.map(\.title) == ["Mine"])

        _ = try target.store.importArchive(contents, categories: [.notes], mode: .replace)
        #expect(target.store.database.notes.map(\.title) == ["Theirs"])
        #expect(target.store.database.snippets.count == 3)
    }

    @Test("Importing without Shortcuts never touches an alias here; the imported keyword gives way")
    func unselectedShortcutsUntouched() throws {
        let target = try TemporaryLibrary()
        target.store.update { $0.commandBindings = [CommandBinding(targetID: "section.notes", alias: "docs")] }
        var incoming = LibraryDatabase()
        incoming.quicklinks = [Quicklink(name: "Docs", template: "https://example.com", keyword: "docs")]
        incoming.snippets = [Snippet(name: "Docs snippet", keyword: "docs", content: "x")]
        incoming.commandBindings = [CommandBinding(targetID: "section.notes", alias: "notes")]
        let contents = try LibraryArchive.read(
            try LibraryArchive.make(database: incoming, directory: nil, categories: [.quicklinks, .snippets, .shortcuts]).data)
        let report = try target.store.importArchive(contents, categories: [.quicklinks, .snippets], mode: .merge)
        #expect(target.store.database.commandBindings == [CommandBinding(targetID: "section.notes", alias: "docs")])
        #expect(target.store.database.quicklinks.first { $0.name == "Docs" }?.keyword == "")
        #expect(target.store.database.snippets.first?.keyword == "")
        #expect(report.notes.contains { $0.contains("keyword") })
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

    // MARK: Scripts and permissions (blocker 2, deeplink trust)

    @Test("Imported script folders arrive off; folders already here keep their own state")
    func scriptsArriveOff() {
        let local = ScriptDirectoryRecord(path: "/Users/me/Scripts", isEnabled: true)
        var current = LibraryDatabase()
        current.scriptDirectories = [local]
        var incoming = LibraryDatabase()
        incoming.scriptDirectories = [
            ScriptDirectoryRecord(id: local.id, path: "/Users/evil/Payload", isEnabled: true),
            ScriptDirectoryRecord(path: "/users/me/scripts", isEnabled: false),
            ScriptDirectoryRecord(path: "/Volumes/Shared/Tools", isEnabled: true),
        ]
        for mode in LibraryImportMode.allCases {
            let (merged, notes) = LibraryArchive.merged(current: current, incoming: incoming, categories: [.scripts], mode: mode)
            #expect(merged.scriptDirectories.first { $0.id == local.id } == local, "\(mode)")
            let added = merged.scriptDirectories.filter { $0.id != local.id }
            #expect(Set(added.map(\.path)) == ["/Users/evil/Payload", "/Volumes/Shared/Tools"], "\(mode)")
            #expect(added.allSatisfy { !$0.isEnabled }, "\(mode)")
            #expect(Set(merged.scriptDirectories.map(\.id)).count == merged.scriptDirectories.count)
            #expect(notes.contains { $0.contains("turned off") })
        }
    }

    @Test("An imported folder runs nothing until it's allowed on this Mac")
    func importedFolderInert() throws {
        let target = try TemporaryLibrary()
        let scripts = try ScriptFolder()
        try scripts.script("boom.sh", title: "Boom", mode: "inline", extra: ["refreshTime 10s"], body: "echo boom")
        var incoming = LibraryDatabase()
        incoming.scriptDirectories = [ScriptDirectoryRecord(path: scripts.url.path, isEnabled: true)]
        let contents = try LibraryArchive.read(
            try LibraryArchive.make(database: incoming, directory: nil, categories: [.scripts]).data)
        _ = try target.store.importArchive(contents, categories: [.scripts], mode: .merge)
        let provider = ScriptCommandProvider(
            catalog: ScriptCatalog(), runner: ScriptRunner(launcher: CannedScriptLauncher(
                execution: ScriptExecution(termination: .exited(0), output: "boom", duration: .zero))),
            presenter: RecordingScriptPresenter(), refreshesAutomatically: false)
        let model = LauncherModel(
            store: target.store, ai: AIChatModel(engine: TestAIEngine()), pasteboard: NSPasteboard.withUniqueName(),
            registry: CommandRegistry(providers: [provider]))
        provider.synchronize(with: model, synchronously: true)
        #expect(provider.catalog.commands.isEmpty)
        provider.refreshDueInlineScripts(in: model)
        #expect(provider.runner.jobs.isEmpty)
    }

    @Test("Restoring settings never brings link permissions")
    func noLinkTrustTravels() throws {
        let source = try populated()
        source.store.update { $0.commandPreferences["linktest.plain"] = [DeepLinkRouter.legacyTrustKey: "com.example.browser", "x": "1"] }
        LocalApprovalStore.for(source.store).setLinksRunWithoutAsking(true, for: "linktest.plain")
        let contents = try LibraryArchive.read(try make(source, [.settings]))
        #expect(contents.database.commandPreferences["linktest.plain"] == ["x": "1"])
        let target = try TemporaryLibrary()
        LocalApprovalStore.for(target.store).setLinksRunWithoutAsking(true, for: "kept.here")
        for mode in LibraryImportMode.allCases {
            _ = try target.store.importArchive(contents, categories: [.settings], mode: mode)
            #expect(target.store.database.commandPreferences["linktest.plain"]?[DeepLinkRouter.legacyTrustKey] == nil)
            #expect(!LocalApprovalStore.for(target.store).linksRunWithoutAsking("linktest.plain"))
            #expect(LocalApprovalStore.for(target.store).linksRunWithoutAsking("kept.here"))
        }
        // A hand-made archive carrying the legacy grant is stripped on import too.
        var crafted = LibraryDatabase()
        crafted.commandPreferences = ["a.b": [DeepLinkRouter.legacyTrustKey: "com.example.browser"]]
        let raw = try LibraryArchive.read(try ArchiveCrafting.archive([("library.json", try ArchiveCrafting.library(crafted))]))
        _ = try target.store.importArchive(raw, categories: [.settings], mode: .merge)
        #expect(target.store.database.commandPreferences["a.b"] == nil)
    }

    // MARK: Restoring files (majors: containment, transactions)

    @Test("A failed import changes nothing, files included")
    func atomicImport() throws {
        let target = try TemporaryLibrary()
        target.store.update { $0.snippets = [Snippet(name: "Keep", keyword: "", content: "x")] }
        var incoming = LibraryDatabase()
        incoming.preferences.clipboardLimit = 9_999
        let contents = try LibraryArchive.read(
            try LibraryArchive.make(database: incoming, directory: nil, categories: [.settings]).data)
        #expect(throws: LibraryArchive.Failure.self) {
            try target.store.importArchive(contents, categories: [.settings], mode: .replace)
        }
        #expect(target.store.database.snippets.map(\.name) == ["Keep"])
        #expect(target.store.database.preferences.clipboardLimit != 9_999)
        #expect(!target.store.replaceLibrary(with: incoming))
    }

    @Test("When the save fails after files are placed, they're taken back and replaced ones return")
    func rollback() throws {
        let target = try TemporaryLibrary()
        let new = Data("new".utf8)
        let rich = "ClipboardImages/\(String(repeating: "b", count: 64)).rich"
        let png = "ClipboardImages/\(LibraryArchive.digest(new)).png"
        try target.write(rich, "old")
        #expect(throws: LibraryArchive.Failure("disk full")) {
            try LibraryArchive.restore([rich: new, png: new], mode: .replace, into: target.folder) { "disk full" }
        }
        #expect(target.contents(of: rich) == "old")
        #expect(!target.exists(png))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: target.folder.path).filter { $0.hasPrefix(".openray-import") }
        #expect(leftovers.isEmpty)
        // The same restore that commits keeps the new files.
        let written = try LibraryArchive.restore([rich: new, png: new], mode: .replace, into: target.folder) { nil }
        #expect(written == 2)
        #expect(target.contents(of: rich) == "new")
        #expect(target.exists(png))
    }

    @Test("Imports never write through links, into a folder that's a link, or over one")
    func containment() throws {
        let target = try TemporaryLibrary()
        let outside = FileManager.default.temporaryDirectory.appending(path: "OpenRayOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let png = Data("png".utf8)
        let path = "ClipboardImages/\(LibraryArchive.digest(png)).png"
        // The store's folder is a link out of the library.
        try FileManager.default.createSymbolicLink(
            at: target.folder.appending(path: "ClipboardImages"), withDestinationURL: outside)
        #expect(throws: LibraryArchive.Failure.self) {
            try LibraryArchive.restore([path: png], mode: .replace, into: target.folder) { nil }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        // The destination itself is a link.
        try FileManager.default.removeItem(at: target.folder.appending(path: "ClipboardImages"))
        try FileManager.default.createDirectory(at: target.folder.appending(path: "ClipboardImages"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: target.folder.appending(path: path), withDestinationURL: outside.appending(path: "victim"))
        #expect(throws: LibraryArchive.Failure.self) {
            try LibraryArchive.restore([path: png], mode: .replace, into: target.folder) { nil }
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "victim").path))
        // Unsafe and unowned paths are refused before anything is written.
        #expect(throws: LibraryArchive.Failure.self) {
            try LibraryArchive.restore(["../outside.txt": png], mode: .replace, into: target.folder) { nil }
        }
        #expect(throws: LibraryArchive.Failure.self) {
            try LibraryArchive.restore(["Library.JSON": png], mode: .replace, into: target.folder) { nil }
        }
    }

    @Test("Pictures whose bytes don't match their name are skipped; merging keeps existing files")
    func installRules() throws {
        let target = try TemporaryLibrary()
        let png = Data("png bytes".utf8)
        let good = "ClipboardImages/\(LibraryArchive.digest(png)).png"
        let bad = "ClipboardImages/\(String(repeating: "a", count: 64)).png"
        let text = "ClipboardImages/\(String(repeating: "c", count: 64)).txt"
        try target.write(text, "mine")
        let written = try LibraryArchive.restore([good: png, bad: png, text: Data("theirs".utf8)], mode: .merge, into: target.folder) { nil }
        #expect(written == 1)
        #expect(target.exists(good))
        #expect(!target.exists(bad))
        #expect(target.contents(of: text) == "mine")
    }

    @Test("Imported clipboard entries without their pictures are left out, and the import says so")
    func importChecksPictures() throws {
        let source = try populated()
        var contents = try LibraryArchive.read(try make(source, [.clipboard]))
        contents.files = [:]
        let target = try TemporaryLibrary()
        let report = try target.store.importArchive(contents, categories: [.clipboard], mode: .merge)
        #expect(target.store.database.clipboard.allSatisfy { $0.image == nil })
        #expect(target.store.database.clipboard.count == 1)
        #expect(report.notes.contains { $0.contains("pictures") })
    }

    @Test("Store files are read only from portable stores, never through links")
    func storeFilesRules() throws {
        let library = try TemporaryLibrary()
        let png = Data("png".utf8)
        try library.write("ClipboardImages/\(LibraryArchive.digest(png)).png", "png")
        try library.write("ClipboardImages/readme.txt", "no")
        try library.write("Backups/OpenRay Backup 2026-01-01 0000 00.\(LibraryArchive.fileExtension)", "old archive")
        let outside = FileManager.default.temporaryDirectory.appending(path: "OpenRaySecret-\(UUID().uuidString)")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: library.folder.appending(path: "ClipboardImages/\(String(repeating: "d", count: 64)).png"),
            withDestinationURL: outside)
        let found = try LibraryArchive.storeFiles(in: library.folder)
        #expect(Set(found.files.keys) == ["ClipboardImages/\(LibraryArchive.digest(png)).png"])
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

    @Test("Rotation keeps this set's newest backups and touches nothing else in the folder")
    func rotation() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let set = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // Someone else's files with OpenRay's naming: another set's backup and a folder.
        let foreign = folder.appending(path: LibraryBackup.fileName(for: start.addingTimeInterval(-86_400)))
        try Data("not mine".utf8).write(to: foreign)
        let decoy = folder.appending(path: LibraryBackup.fileName(for: start.addingTimeInterval(-2 * 86_400)))
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: decoy.appending(path: "keep.txt"))
        try Data("mine".utf8).write(to: folder.appending(path: "notes.txt"))
        var written: [URL] = []
        for day in 0..<5 {
            written.append(
                try LibraryBackup.write(Data("archive \(day)".utf8), to: folder, setID: set, keep: 3, now: start.addingTimeInterval(Double(day) * 86_400)))
        }
        let kept = LibraryBackup.backups(in: folder, setID: set)
        #expect(kept.map(\.lastPathComponent) == written.suffix(3).reversed().map(\.lastPathComponent))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(FileManager.default.fileExists(atPath: decoy.appending(path: "keep.txt").path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "notes.txt").path))
        // Another Mac's set in the same folder is a separate index.
        #expect(LibraryBackup.backups(in: folder, setID: UUID()).isEmpty)
    }

    @Test("Two backups in the same second keep their order, so retention keeps the newer")
    func sameSecond() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let set = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try LibraryBackup.write(Data("first".utf8), to: folder, setID: set, keep: 5, now: now)
        let second = try LibraryBackup.write(Data("second".utf8), to: folder, setID: set, keep: 1, now: now)
        #expect(first.lastPathComponent != second.lastPathComponent)
        #expect(LibraryBackup.backups(in: folder, setID: set).map(\.lastPathComponent) == [second.lastPathComponent])
        #expect(try Data(contentsOf: second) == Data("second".utf8))
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
        let set = try #require(settings.settings.setID)
        let contents = try LibraryArchive.read(try Data(contentsOf: url))
        #expect(contents.database.snippets.map(\.name) == ["Saved"])
        #expect(await scheduler.backUpIfDue(now: now.addingTimeInterval(60)) == nil)
        #expect(await scheduler.backUpIfDue(now: now.addingTimeInterval(86_400)) != nil)
        _ = try await scheduler.backUpNow(now: now.addingTimeInterval(2 * 86_400))
        #expect(LibraryBackup.backups(in: folder, setID: set).count == 2)
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
        // An injected live rule doesn't change that in the test host.
        let live = LibraryBackupScheduler(store: library.store, settings: settings, sideEffects: SideEffectGuard(mode: .live))
        live.start()
        #expect(!live.isRunning)
        await #expect(throws: SideEffectGuard.Blocked.self) { try await live.backUpNow() }
        #expect(throws: SideEffectGuard.Blocked.self) {
            try LibraryBackup.write(Data(), to: outside, setID: UUID(), keep: 1)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
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

// MARK: - Re-review fixes

extension LibraryArchiveTests {
    @Test("Imported files must pass the store's own read rules; merging replaces a damaged file with a good one")
    func readRules() throws {
        let source = try populated()
        let image = try #require(source.store.database.clipboard.compactMap(\.image).first)
        var contents = try LibraryArchive.read(try make(source, [.clipboard]))
        let path = "ClipboardImages/\(image.id).png"
        let good = try #require(contents.files[path])

        // A damaged file already sits under the picture's name; Merge replaces it.
        let target = try TemporaryLibrary()
        try target.write(path, "damaged")
        _ = try target.store.importArchive(contents, categories: [.clipboard], mode: .merge)
        #expect(try Data(contentsOf: target.folder.appending(path: path)) == good)
        #expect(target.store.imageData(for: image) == good)

        // A picture whose digest matches its name but not its entry's size isn't accepted.
        var entry = try #require(contents.database.clipboard.first { $0.image != nil })
        let other = try TemporaryLibrary()
        let truncated = Data(good.prefix(good.count - 1))
        contents.files = ["ClipboardImages/\(LibraryArchive.digest(truncated)).png": truncated]
        entry.content = .image(ClipboardImage(id: LibraryArchive.digest(truncated), pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight, byteCount: good.count))
        contents.database.clipboard = [entry]
        let report = try other.store.importArchive(contents, categories: [.clipboard], mode: .merge)
        #expect(other.store.database.clipboard.isEmpty)
        #expect(report.notes.contains { $0.contains("damaged") })

        // Formatting whose bytes don't decode is dropped; the text entry stays, without it.
        let bogus = Data("not a property list".utf8)
        let digest = LibraryArchive.digest(bogus)
        #expect(!LibraryArchive.sideFileIsReadable("\(digest).rich", bogus))
        var text = ClipboardEntry(text: "formatted", sourceName: "Notes")
        text.richTextDigest = digest
        var richContents = contents
        richContents.database.clipboard = [text]
        richContents.files = ["ClipboardImages/\(digest).rich": bogus]
        let third = try TemporaryLibrary()
        _ = try third.store.importArchive(richContents, categories: [.clipboard], mode: .replace)
        #expect(third.store.database.clipboard.first?.richTextDigest == nil)
        #expect(!third.exists("ClipboardImages/\(digest).rich"))
    }

    @Test("A save that fails before reaching the disk rolls the files back")
    func failedSaveRollsBack() throws {
        let target = try TemporaryLibrary()
        var incoming = LibraryDatabase()
        incoming.preferences.clipboardLimit = 9_999
        #expect(target.store.replaceLibraryForImport(with: incoming) != .saved)
        if case .savedWithWarning = target.store.replaceLibraryForImport(with: incoming) {
            Issue.record("An invalid library never reaches the disk")
        }
    }

    @Test("A replaced original that can't be put back keeps the staging folder and says where")
    func rollbackFailureKeepsOriginals() throws {
        let target = try TemporaryLibrary()
        let rich = "ClipboardImages/\(String(repeating: "e", count: 64)).rich"
        try target.write(rich, "original")
        do {
            _ = try LibraryArchive.restore([rich: Data("new".utf8)], mode: .replace, into: target.folder) {
                // The save fails, and the folder the original goes back into has become read-only.
                chmod(target.folder.appending(path: "ClipboardImages").path, 0o500)
                return "disk full"
            }
            Issue.record("Expected the restore to fail")
        } catch let error as LibraryArchive.Failure {
            #expect(error.message.contains("originals are in"))
        }
        chmod(target.folder.appending(path: "ClipboardImages").path, 0o700)
        let staging = try FileManager.default.contentsOfDirectory(atPath: target.folder.path).filter { $0.hasPrefix(".openray-import") }
        #expect(staging.count == 1)
    }
}

extension LibraryBackupTests {
    @Test("Rotation never deletes a different file that took an indexed backup's name")
    func rotationChecksIdentity() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let set = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try LibraryBackup.write(Data("one".utf8), to: folder, setID: set, keep: 5, now: start)
        // Someone deletes the backup and puts another file under its name.
        try FileManager.default.removeItem(at: first)
        try Data("someone else's".utf8).write(to: first)
        for day in 1...3 {
            try LibraryBackup.write(Data("day \(day)".utf8), to: folder, setID: set, keep: 2, now: start.addingTimeInterval(Double(day) * 86_400))
        }
        #expect(try Data(contentsOf: first) == Data("someone else's".utf8))
        #expect(LibraryBackup.backups(in: folder, setID: set).count == 2)
        #expect(!LibraryBackup.index(in: folder, setID: set).entries.contains { $0.name == first.lastPathComponent })
    }

    @Test("A damaged index is cleaned: repeated names and foreign names are dropped")
    func indexValidation() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let set = UUID()
        let name = LibraryBackup.fileName(for: Date(timeIntervalSince1970: 1_700_000_000))
        let index = LibraryBackup.Index(
            setID: set,
            entries: [
                .init(name: name, sequence: 1, createdAt: .now), .init(name: name, sequence: 2, createdAt: .now),
                .init(name: "../escape.openraybackup", sequence: 3, createdAt: .now),
                .init(name: "notes.txt", sequence: 4, createdAt: .now),
            ])
        try JSONEncoder().encode(index).write(to: LibraryBackup.indexURL(in: folder, setID: set))
        #expect(LibraryBackup.index(in: folder, setID: set).entries.map(\.name) == [name])
    }
}

// MARK: - Note images (Slice 6's NoteAssets)

extension LibraryArchiveTests {
    /// A small real PNG, as a note image.
    func notePNG() throws -> Data { try ClipboardFixtures.image(width: 8, height: 8) }

    @Test("A note's images travel with it and come back where the note refers to them")
    func noteImagesRoundTrip() throws {
        let source = try TemporaryLibrary()
        let assets = NoteAssetStore(libraryURL: source.store.fileURL)
        let png = try notePNG()
        let reference = try assets.save(png, fileExtension: "png")
        let orphan = try assets.save(try ClipboardFixtures.image(width: 4, height: 4), fileExtension: "png")
        let name = try #require(NoteAssetStore.fileName(in: reference))
        #expect(source.store.update {
            $0.notes = [QuickNote(title: "Trip", content: "Trip\n![photo](\(reference))\nThe view.")]
        })
        let contents = try LibraryArchive.read(try make(source, [.notes]))
        // Only images a note refers to travel; an image no note uses stays behind.
        #expect(Set(contents.files.keys) == [reference])
        #expect(!contents.files.keys.contains(orphan))

        let target = try TemporaryLibrary()
        let report = try target.store.importArchive(contents, categories: [.notes], mode: .merge)
        #expect(report.filesWritten == 1)
        #expect(target.store.database.notes.first?.content.contains(reference) == true)
        let restored = NoteAssetStore(libraryURL: target.store.fileURL)
        #expect(try Data(contentsOf: try #require(restored.url(for: reference))) == png)
        #expect(LibraryArchive.isNoteAssetName(name))
    }

    @Test("Note image names must be exactly what the note store writes")
    func noteAssetNames() throws {
        let uuid = UUID().uuidString
        #expect(LibraryArchive.isNoteAssetName("\(uuid).png"))
        #expect(LibraryArchive.isNoteAssetName("\(uuid).jpeg"))
        for bad in [
            "\(uuid.lowercased()).png", "\(uuid).PNG", "\(uuid).pdf", "\(uuid)", "photo.png", ".pending-removal",
            "\(uuid).png.txt", "../\(uuid).png",
        ] {
            #expect(!LibraryArchive.isNoteAssetName(bad), "\(bad)")
        }
        try LibraryArchive.validate("NoteAssets/\(uuid).png")
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.validate("NoteAssets/photo.png") }
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.validate("NoteAssets/.pending-removal") }
        #expect(throws: LibraryArchive.Failure.self) { try LibraryArchive.validate("NoteAssets/sub/\(uuid).png") }
        // The store's housekeeping file never travels.
        let library = try TemporaryLibrary()
        try library.write("NoteAssets/.pending-removal", "x")
        try library.write("NoteAssets/notes.txt", "x")
        #expect(try LibraryArchive.storeFiles(in: library.folder).files.isEmpty)
    }

    @Test("Missing or unreadable note images are left out and reported; the note keeps its text")
    func noteImagesMissing() throws {
        let source = try TemporaryLibrary()
        let assets = NoteAssetStore(libraryURL: source.store.fileURL)
        let good = try assets.save(try notePNG(), fileExtension: "png")
        let broken = try assets.save(Data("not an image".utf8), fileExtension: "png")
        let gone = "NoteAssets/\(UUID().uuidString).png"
        source.store.update {
            $0.notes = [QuickNote(title: "Mixed", content: "Mixed\n![a](\(good)) ![b](\(broken)) ![c](\(gone))")]
        }
        let built = try LibraryArchive.make(database: source.store.database, directory: source.folder, categories: [.notes])
        #expect(built.omissions.contains { $0.contains("2 images in notes") })
        let contents = try LibraryArchive.read(built.data)
        #expect(Set(contents.files.keys) == [good])

        let target = try TemporaryLibrary()
        let report = try target.store.importArchive(contents, categories: [.notes], mode: .replace)
        #expect(target.store.database.notes.first?.content.contains(gone) == true)
        #expect(report.notes.contains { $0.contains("2 images in notes") })
        #expect(target.exists(good))
        #expect(!target.exists(broken))
    }
}
