import AppKit
import Foundation
import Testing

@testable import OpenRay

@MainActor
struct ClipboardStorageTests {
    @Test func versionOneLibraryMigratesWithoutLosingTextOrBroadeningCaptureConsent() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayMigration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let entry = ClipboardEntry(text: "Legacy clipboard", sourceName: "Legacy app")
        var legacy = LibraryDatabase()
        legacy.schemaVersion = 1
        legacy.preferences.clipboardEnabled = true
        legacy.clipboard = [entry]
        legacy.notes = [QuickNote(title: "Keep this", content: "Existing notes survive")]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        var preferences = try #require(object["preferences"] as? [String: Any])
        preferences.removeValue(forKey: "clipboardImagesEnabled")
        preferences.removeValue(forKey: "clipboardFilesEnabled")
        object["preferences"] = preferences
        var entries = try #require(object["clipboard"] as? [[String: Any]])
        entries[0].removeValue(forKey: "kind")
        object["clipboard"] = entries
        let original = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try original.write(to: url)
        let store = LibraryStore(fileURL: url)
        #expect(!store.isReadOnly)
        #expect(store.database.schemaVersion == LibraryDatabase.currentSchemaVersion)
        #expect(store.database.clipboard == [entry])
        #expect(store.database.preferences.clipboardEnabled)
        #expect(!store.database.preferences.capturesClipboardImages)
        #expect(!store.database.preferences.capturesClipboardFiles)
        #expect(try Data(contentsOf: url) == original)
        #expect(store.save(QuickNote(title: "Another", content: "New note")))
        let reopened = LibraryStore(fileURL: url)
        #expect(reopened.database.clipboard == [entry])
        #expect(reopened.database.notes.count == 2)
        #expect(reopened.database.schemaVersion == LibraryDatabase.currentSchemaVersion)
        #expect(!reopened.database.preferences.capturesClipboardImages)
    }

    @Test func imagesPersistOutsideJSONWithOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayMediaStorage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        store.update { $0.preferences.clipboardEnabled = true }
        let prepared = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        #expect(store.captureImage(prepared, sourceName: "Fixture"))
        let imageURL = directory.appending(path: "ClipboardImages/\(prepared.image.id).png")
        #expect(try Data(contentsOf: imageURL) == prepared.png)
        #expect(try FileManager.default.attributesOfItem(atPath: imageURL.path)[.posixPermissions] as? Int == 0o600)
        #expect(
            try FileManager.default.attributesOfItem(atPath: imageURL.deletingLastPathComponent().path)[
                .posixPermissions] as? Int == 0o700)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(!json.contains(prepared.png.base64EncodedString()))
        let reopened = LibraryStore(fileURL: url)
        #expect(reopened.imageData(for: prepared.image) == prepared.png)
        let attributes = try FileManager.default.attributesOfItem(atPath: imageURL.path)
        #expect(store.save(QuickNote(title: "Note", content: "No image rewrite")))
        let after = try FileManager.default.attributesOfItem(atPath: imageURL.path)
        #expect(attributes[.modificationDate] as? Date == after[.modificationDate] as? Date)
    }

    @Test func deletionAndExpiryRemoveOnlyManagedImages() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayMediaCleanup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(fileURL: directory.appending(path: "library.json"))
        store.update { $0.preferences.clipboardEnabled = true }
        let prepared = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        #expect(store.captureImage(prepared, sourceName: "Fixture"))
        let imageURL = directory.appending(path: "ClipboardImages/\(prepared.image.id).png")
        let unrelated = directory.appending(path: "ClipboardImages/keep-me.txt")
        try Data("unrelated file".utf8).write(to: unrelated)
        let entryID = try #require(store.database.clipboard.first?.id)
        store.toggleFavorite("clipboard.\(entryID)")
        store.pruneClipboard(now: Date.now.addingTimeInterval(8 * 86_400))
        #expect(store.database.clipboard.isEmpty)
        #expect(!store.database.favoriteIDs.contains("clipboard.\(entryID)"))
        #expect(!FileManager.default.fileExists(atPath: imageURL.path))
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "unrelated file")
    }

    @Test func pausedCaptureStillExpiresSavedTextAndImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayPausedRetention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(fileURL: directory.appending(path: "library.json"))
        #expect(store.update { $0.preferences.clipboardEnabled = true })
        let prepared = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        #expect(store.captureImage(prepared, sourceName: "Fixture"))
        let text = ClipboardEntry(text: "Saved before pausing", sourceName: "Fixture")
        #expect(store.capture(text))
        store.toggleFavorite("clipboard.\(text.id)")
        store.recordUse(of: "clipboard.\(text.id)")
        #expect(store.update { $0.preferences.clipboardEnabled = false })

        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let service = ClipboardService(
            store: store, pasteboard: board,
            captureContext: {
                Issue.record("Paused history maintenance must not read the source application or capture content.")
                return ClipboardCaptureContext(sourceName: "Unexpected", secureInput: false)
            })
        service.configure()
        defer { service.stop() }
        #expect(store.database.clipboard.count == 2)
        board.clearContents()
        board.setString("Copied while paused", forType: .string)
        let change = board.changeCount
        await service.poll(now: Date.now.addingTimeInterval(8 * 86_400))

        #expect(store.database.clipboard.isEmpty)
        #expect(!store.database.favoriteIDs.contains("clipboard.\(text.id)"))
        #expect(!store.database.usage.contains { $0.id == "clipboard.\(text.id)" })
        #expect(store.imageData(for: prepared.image) == nil)
        #expect(board.changeCount == change)
        #expect(board.string(forType: .string) == "Copied while paused")
    }

    @Test func reopeningValidLibraryRemovesImagesOrphanedByInterruptedCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayOrphanRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        #expect(store.update { $0.preferences.clipboardEnabled = true })
        let kept = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        #expect(store.captureImage(kept, sourceName: "Fixture"))
        let orphan = try ClipboardImageCodec.prepare(ClipboardFixtures.image(red: 0.9))
        try ClipboardImageStore(libraryURL: url).save(orphan)
        let original = try Data(contentsOf: url)

        let reopened = LibraryStore(fileURL: url)

        #expect(!reopened.isReadOnly)
        #expect(reopened.imageData(for: kept.image) == kept.png)
        #expect(reopened.imageData(for: orphan.image) == nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func unreadableLibraryNeverDeletesItsImagesDuringStartup() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayUnreadableImages-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let image = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        try ClipboardImageStore(libraryURL: url).save(image)
        try Data("damaged metadata".utf8).write(to: url)

        let store = LibraryStore(fileURL: url)

        #expect(store.isReadOnly)
        #expect(store.imageData(for: image.image) == image.png)
        #expect(try String(contentsOf: url, encoding: .utf8) == "damaged metadata")
    }

    @Test func historyEnforcesAnOverallByteBudget() {
        let store = LibraryStore(fileURL: nil)
        store.update {
            $0.preferences.clipboardEnabled = true
            $0.preferences.clipboardLimit = 100
        }
        for index in 1...10 {
            let image = ClipboardImage(
                id: String(format: "%064x", index), pixelWidth: 1, pixelHeight: 1,
                byteCount: ClipboardLimits.imageBytes)
            store.capture(ClipboardEntry(content: .image(image), sourceName: "Budget fixture"))
        }
        #expect(store.database.clipboard.count == 6)
        #expect(store.database.clipboard.reduce(0) { $0 + $1.byteCount } <= ClipboardLimits.historyBytes)
    }

    @Test func failedMetadataSaveDoesNotLeaveNewImageDataBehind() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayMediaRollback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        store.update { $0.preferences.clipboardEnabled = true }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let prepared = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        #expect(!store.captureImage(prepared, sourceName: "Fixture"))
        #expect(store.database.clipboard.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appending(path: "ClipboardImages/\(prepared.image.id).png").path))
        #expect(store.errorMessage != nil)
    }

    @Test func missingImageCopyDoesNotEraseTheCurrentPasteboard() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayMediaMissing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(fileURL: directory.appending(path: "library.json"))
        store.update { $0.preferences.clipboardEnabled = true }
        let prepared = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        #expect(store.captureImage(prepared, sourceName: "Fixture"))
        let entry = try #require(store.database.clipboard.first)
        try FileManager.default.removeItem(at: directory.appending(path: "ClipboardImages/\(prepared.image.id).png"))
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString("Keep current clipboard", forType: .string)
        let service = ClipboardService(store: store, pasteboard: board)
        #expect(!service.copy(entry))
        #expect(board.string(forType: .string) == "Keep current clipboard")
        #expect(service.contentMessage?.contains("missing or damaged") == true)
    }

    @Test func imageStoreNeverTraversesASymbolicLinkDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayMediaLinks-\(UUID())")
        let outside = FileManager.default.temporaryDirectory.appending(path: "OpenRayMediaOutside-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = LibraryStore(fileURL: directory.appending(path: "library.json"))
        store.update { $0.preferences.clipboardEnabled = true }
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: "ClipboardImages"), withDestinationURL: outside)
        let prepared = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        #expect(!store.captureImage(prepared, sourceName: "Fixture"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func clearingAnImageAlsoInvalidatesItsThumbnailCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayMediaThumb-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prepared = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        let url = directory.appending(path: "test.png")
        try prepared.png.write(to: url)
        let resource = ClipboardImageResource.file(prepared.image, url)
        let processor = ClipboardImageProcessor()
        #expect(await processor.thumbnail(resource, maxPixelSize: 32) != nil)
        try FileManager.default.removeItem(at: url)
        await processor.forget([prepared.image.id])
        #expect(await processor.thumbnail(resource, maxPixelSize: 32) == nil)
    }
}
