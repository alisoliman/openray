import Foundation
import Observation

/// Owns the local library. Mutations are published only after an atomic save succeeds.
@MainActor
@Observable
final class LibraryStore {
    private(set) var database: LibraryDatabase
    private(set) var errorMessage: String?
    private(set) var isReadOnly = false
    let fileURL: URL?
    @ObservationIgnored var commandBindingsDidChange: (() -> Void)?
    @ObservationIgnored private let images: ClipboardImageStore

    init(fileURL: URL? = LibraryStore.defaultURL) {
        self.fileURL = fileURL
        images = ClipboardImageStore(libraryURL: fileURL)
        database = LibraryDatabase()
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            var decoded = try JSONDecoder().decode(LibraryDatabase.self, from: Data(contentsOf: fileURL))
            decoded.discardUnavailableCommandBindings()
            try decoded.validate()
            decoded.schemaVersion = LibraryDatabase.currentSchemaVersion
            database = decoded
        } catch {
            // Do not overwrite an unreadable or newer library with empty defaults.
            isReadOnly = true
            errorMessage =
                "Your library could not be loaded. The original file is untouched. \(error.localizedDescription)"
        }
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "OpenRay", directoryHint: .isDirectory)
            .appending(path: "library.json")
    }

    @discardableResult
    func update(_ mutation: (inout LibraryDatabase) throws -> Void) -> Bool {
        guard !isReadOnly else { return false }
        do {
            var next = database
            try mutation(&next)
            next.discardUnavailableCommandBindings()
            next.schemaVersion = LibraryDatabase.currentSchemaVersion
            let removedClipboardIDs = Set(database.clipboard.map { "clipboard.\($0.id)" })
                .subtracting(next.clipboard.map { "clipboard.\($0.id)" })
            next.favoriteIDs.subtract(removedClipboardIDs)
            next.usage.removeAll { removedClipboardIDs.contains($0.id) }
            try next.validate()
            if let fileURL {
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(next).write(to: fileURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
            let removedImages = Set(database.clipboard.compactMap(\.image).map(\.id))
                .subtracting(next.clipboard.compactMap(\.image).map(\.id))
            let bindingsChanged = database.commandBindings != next.commandBindings
            database = next
            if bindingsChanged { commandBindingsDidChange?() }
            if !removedImages.isEmpty {
                Task { await ClipboardImageProcessor.shared.forget(removedImages) }
            }
            errorMessage = nil
            do { try images.reconcile(keeping: next.clipboard.compactMap(\.image)) } catch {
                errorMessage =
                    "The library was saved, but some unused clipboard images could not be removed: \(error.localizedDescription)"
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveCommandBinding(_ binding: CommandBinding) -> Bool {
        update { database in
            var binding = binding
            binding.alias = binding.alias?.trimmingCharacters(in: .whitespacesAndNewlines)
            if binding.alias?.isEmpty == true { binding.alias = nil }
            try binding.validate()
            if binding.isEmpty {
                database.commandBindings.removeAll { $0.targetID == binding.targetID }
            } else if let index = database.commandBindings.firstIndex(where: { $0.targetID == binding.targetID }) {
                database.commandBindings[index] = binding
            } else {
                database.commandBindings.append(binding)
            }
        }
    }

    @discardableResult
    func removeCommandBinding(for targetID: String) -> Bool {
        update { database in
            database.commandBindings.removeAll { $0.targetID == targetID }
        }
    }

    @discardableResult
    func save(_ quicklink: Quicklink) -> Bool {
        update { database in
            try quicklink.validate()
            if let index = database.quicklinks.firstIndex(where: { $0.id == quicklink.id }) {
                database.quicklinks[index] = quicklink
            } else {
                database.quicklinks.append(quicklink)
            }
        }
    }

    @discardableResult
    func save(_ snippet: Snippet) -> Bool {
        update { database in
            try snippet.validate(against: database.snippets)
            if let index = database.snippets.firstIndex(where: { $0.id == snippet.id }) {
                database.snippets[index] = snippet
            } else {
                database.snippets.append(snippet)
            }
        }
    }

    @discardableResult
    func save(_ note: QuickNote) -> Bool {
        update { database in
            guard !note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LibraryValidationError("Give this note a title.")
            }
            guard note.content.count <= 100_000 else {
                throw LibraryValidationError("Notes support up to 100,000 characters.")
            }
            var note = note
            note.modifiedAt = .now
            if let index = database.notes.firstIndex(where: { $0.id == note.id }) {
                database.notes[index] = note
            } else {
                database.notes.insert(note, at: 0)
            }
        }
    }

    func recordUse(of id: String, at date: Date = .now) {
        update { database in
            if let index = database.usage.firstIndex(where: { $0.id == id }) {
                database.usage[index].count = min(database.usage[index].count + 1, 10_000)
                database.usage[index].lastUsed = date
            } else {
                database.usage.append(UsageRecord(id: id, lastUsed: date))
            }
            database.usage = Array(database.usage.sorted { $0.lastUsed > $1.lastUsed }.prefix(100))
        }
    }

    func toggleFavorite(_ id: String) {
        update { database in
            if !database.favoriteIDs.insert(id).inserted { database.favoriteIDs.remove(id) }
        }
    }

    @discardableResult
    func capture(_ entry: ClipboardEntry, now: Date = .now) -> Bool {
        guard database.preferences.clipboardEnabled, entry.isValid else { return false }
        if case .image = entry.content, !database.preferences.capturesClipboardImages { return false }
        if case .files = entry.content, !database.preferences.capturesClipboardFiles { return false }
        return update { database in
            var entry = entry
            if let existing = database.clipboard.first(where: { $0.content == entry.content }) {
                entry.id = existing.id
            }
            database.clipboard.removeAll { $0.content == entry.content }
            database.clipboard.insert(entry, at: 0)
            Self.pruneClipboard(in: &database, now: now)
        }
    }

    @discardableResult
    func captureImage(
        _ prepared: PreparedClipboardImage, copiedAt: Date = .now,
        sourceName: String, sourceBundleID: String? = nil
    ) -> Bool {
        guard !isReadOnly, database.preferences.clipboardEnabled, database.preferences.capturesClipboardImages else {
            return false
        }
        do {
            try images.save(prepared)
            let saved = capture(
                ClipboardEntry(
                    content: .image(prepared.image), copiedAt: copiedAt,
                    sourceName: sourceName, sourceBundleID: sourceBundleID))
            if !saved { try images.reconcile(keeping: database.clipboard.compactMap(\.image)) }
            return saved
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func imageResource(for image: ClipboardImage) -> ClipboardImageResource? { images.resource(for: image) }
    func imageData(for image: ClipboardImage) -> Data? { images.data(for: image) }

    func pruneClipboard(now: Date = .now) {
        var next = database
        Self.pruneClipboard(in: &next, now: now)
        if next.clipboard != database.clipboard {
            update {
                $0.clipboard = next.clipboard
                $0.favoriteIDs = next.favoriteIDs
                $0.usage = next.usage
            }
        }
    }

    private static func pruneClipboard(in database: inout LibraryDatabase, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(max(1, database.preferences.clipboardRetentionDays)) * 86_400)
        let previousIDs = Set(database.clipboard.map { "clipboard.\($0.id)" })
        var bytes = 0
        database.clipboard = Array(
            database.clipboard.filter { $0.copiedAt > cutoff }
                .prefix(max(1, min(500, database.preferences.clipboardLimit)))
                .filter { entry in
                    let cost = max(0, entry.byteCount)
                    guard cost <= ClipboardLimits.historyBytes - bytes else { return false }
                    bytes += cost
                    return true
                })
        let expiredIDs = previousIDs.subtracting(database.clipboard.map { "clipboard.\($0.id)" })
        database.favoriteIDs.subtract(expiredIDs)
        database.usage.removeAll { expiredIDs.contains($0.id) }
    }
}
