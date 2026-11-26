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
    /// Rows deleted from another store whose favorite and usage records a failed save left
    /// behind. Every later save removes them first, until one succeeds.
    @ObservationIgnored private(set) var pendingForgottenIDs: Set<String> = []
    /// Deletions from other stores, recorded before they happen (item id → provider id) in
    /// `pendingCleanupURL`, so a failed save or a quit at any point can't lose the cleanup. Entries
    /// loaded at launch wait for `reconcileJournaledCleanup`, which checks the row is really gone.
    @ObservationIgnored private(set) var journaledCleanup: [String: String] = [:]

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
            journaledCleanup = Self.readJournal(at: pendingCleanupURL)
        } catch {
            // Do not overwrite an unreadable or newer library with empty defaults.
            isReadOnly = true
            errorMessage =
                "Your library could not be loaded. The original file is untouched. \(error.localizedDescription)"
            return
        }
        // Formatting and recognized text are kept beside the images. Values still inline
        // (their side file was never written) move there now, and stay inline until they do.
        for index in database.clipboard.indices {
            let entry = database.clipboard[index]
            if let digest = entry.richTextDigest {
                // A file that can't be read now keeps its reference, so it's never cleaned
                // up, and a later read (the next launch, or a copy) can still use it.
                database.clipboard[index].richText = images.richText(digest: digest)
            } else if let richText = entry.richText {
                database.clipboard[index].richTextDigest = try? images.saveRichText(richText)
            }
            if let image = entry.image {
                if let text = entry.recognizedText {
                    database.clipboard[index].recognizedTextIsStored =
                        (try? images.saveRecognizedText(text, forImage: image.id)) != nil
                } else if let text = images.recognizedText(forImage: image.id) {
                    database.clipboard[index].recognizedText = text
                    database.clipboard[index].recognizedTextIsStored = true
                }
            }
        }
        // An interrupted image capture can leave a PNG that no saved entry owns.
        // Only a successfully decoded library can authorize removing those files.
        do {
            try images.reconcile(keeping: database.clipboard.compactMap(\.image))
            try images.reconcileSideData(keeping: database.clipboard)
        } catch {
            errorMessage =
                "Your library was loaded, but some unused clipboard images could not be removed: \(error.localizedDescription)"
        }
    }

    /// Where cleanup that couldn't be saved waits for the next launch, beside the library.
    var pendingCleanupURL: URL? {
        fileURL?.deletingLastPathComponent().appending(path: "library-pending-cleanup.json")
    }

    private static func readJournal(at url: URL?) -> [String: String] {
        guard let url, let data = try? Data(contentsOf: url),
            let entries = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return entries
    }

    /// Writes the journal, or removes it when empty. Throws when it can't be written.
    private func writeJournal(_ entries: [String: String]) throws {
        guard let url = pendingCleanupURL else { return }
        if entries.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(entries).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Records, before a provider deletes a row from its own store, that the row's favorite and
    /// usage must go. Throws when it can't be recorded, and then the deletion mustn't happen.
    func journalCleanup(of itemID: String, provider: String) throws {
        guard !isReadOnly else { throw LibraryValidationError("The library is read-only.") }
        var entries = journaledCleanup
        entries[itemID] = provider
        try writeJournal(entries)
        journaledCleanup = entries
    }

    /// Withdraws a recorded cleanup whose deletion didn't happen.
    func unjournalCleanup(of itemID: String) {
        guard journaledCleanup[itemID] != nil else { return }
        var entries = journaledCleanup
        entries.removeValue(forKey: itemID)
        if (try? writeJournal(entries)) != nil { journaledCleanup = entries }
    }

    /// Settles recorded cleanup whose outcome isn't known yet: from an earlier session, or from a
    /// deletion that failed after it was recorded. `isGone` says whether the row was really
    /// deleted: true cleans its records, false drops the entry (the deletion never happened), and
    /// nil keeps it for later (its provider can't tell yet). Rows whose deletion this session
    /// confirmed are already being cleaned and aren't asked about.
    func reconcileJournaledCleanup(isGone: (_ itemID: String, _ provider: String) -> Bool?) {
        guard !journaledCleanup.isEmpty, !isReadOnly else { return }
        var entries = journaledCleanup
        for (id, provider) in journaledCleanup where !pendingForgottenIDs.contains(id) {
            switch isGone(id, provider) {
            case true?: pendingForgottenIDs.insert(id)
            case false?: entries.removeValue(forKey: id)
            case nil: break
            }
        }
        if entries != journaledCleanup, (try? writeJournal(entries)) != nil { journaledCleanup = entries }
        if !pendingForgottenIDs.isEmpty { update { _ in } }
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
            // Stale records of rows deleted elsewhere go first, so a row restored under the same
            // id in this mutation keeps the favorite or usage the mutation gives it.
            if !pendingForgottenIDs.isEmpty {
                next.favoriteIDs.subtract(pendingForgottenIDs)
                next.usage.removeAll { pendingForgottenIDs.contains($0.id) }
            }
            try mutation(&next)
            // Libraries from before Paused was stored infer it from saved history. Removing
            // that history, by pruning, Delete All or deleting entries, keeps capture Paused.
            if database.clipboardIsPaused, next.preferences.clipboardPaused == nil,
                !next.preferences.clipboardEnabled, !next.clipboardIsPaused
            {
                next.preferences.clipboardPaused = true
            }
            next.discardUnavailableCommandBindings()
            next.schemaVersion = LibraryDatabase.currentSchemaVersion
            let removedClipboardIDs = Set(database.clipboard.map { "clipboard.\($0.id)" })
                .subtracting(next.clipboard.map { "clipboard.\($0.id)" })
            next.favoriteIDs.subtract(removedClipboardIDs)
            next.favoriteOrder = next.orderedFavoriteIDs
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
            if !pendingForgottenIDs.isEmpty {
                // Saved: the journal no longer needs these.
                let settled = journaledCleanup.filter { !pendingForgottenIDs.contains($0.key) }
                if settled != journaledCleanup, (try? writeJournal(settled)) != nil { journaledCleanup = settled }
                pendingForgottenIDs = []
            }
            if bindingsChanged { commandBindingsDidChange?() }
            if !removedImages.isEmpty {
                Task { await ClipboardImageProcessor.shared.forget(removedImages) }
            }
            errorMessage = nil
            do {
                try images.reconcile(keeping: next.clipboard.compactMap(\.image))
                try images.reconcileSideData(keeping: next.clipboard)
            } catch {
                errorMessage =
                    "The library was saved, but some unused clipboard images could not be removed: \(error.localizedDescription)"
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Removes the favorite and usage records of rows deleted from another store. When the save
    /// fails, later saves keep trying, so the records can't outlive the rows for good.
    @discardableResult
    func forget(itemIDs: Set<String>) -> Bool {
        let referenced = itemIDs.filter { id in
            database.favoriteIDs.contains(id) || database.usage.contains { $0.id == id }
        }
        guard !referenced.isEmpty else {
            for id in itemIDs { unjournalCleanup(of: id) }
            return true
        }
        pendingForgottenIDs.formUnion(referenced)
        return update { _ in }
    }

    /// Replaces the whole library in one validated save, as an archive import does. The current
    /// library stays when the new one is invalid or can't be saved.
    @discardableResult
    func replaceLibrary(with replacement: LibraryDatabase) -> Bool {
        update { $0 = replacement }
    }

    /// What saving an imported library did.
    enum ImportSaveOutcome: Equatable {
        case saved
        /// The new library reached the disk, but a later step (setting its permissions) failed.
        /// It's the library now: the store has adopted it.
        case savedWithWarning(String)
        case failed(String)
    }

    /// Replaces the library for an import and says whether the new one reached the disk, the
    /// import's commit point. A save that wrote the file and then failed to set its permissions
    /// has still happened: the store adopts the file it wrote, so files imported with it stay.
    func replaceLibraryForImport(with replacement: LibraryDatabase) -> ImportSaveOutcome {
        let before = fileURL.flatMap(Self.fileIdentity)
        if replaceLibrary(with: replacement) { return .saved }
        let message = errorMessage ?? "The library couldn't be saved."
        guard let fileURL, let after = Self.fileIdentity(fileURL), after != before,
            let data = try? Data(contentsOf: fileURL),
            let written = try? JSONDecoder().decode(LibraryDatabase.self, from: data), (try? written.validate()) != nil
        else { return .failed(message) }
        let bindingsChanged = database.commandBindings != written.commandBindings
        database = written
        if bindingsChanged { commandBindingsDidChange?() }
        let warning = "The library was saved, but its file permissions couldn't be set. \(message)"
        errorMessage = warning
        return .savedWithWarning(warning)
    }

    private static func fileIdentity(_ url: URL) -> [Int]? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
            let device = values[.systemNumber] as? Int, let inode = values[.systemFileNumber] as? Int
        else { return nil }
        return [device, inode]
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
            var note = note
            if note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The first line becomes the title, so a note never needs a separate name.
                note.title = QuickNote.derivedTitle(from: note.content)
            }
            guard !note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LibraryValidationError("Write something before saving this note.")
            }
            guard note.content.count <= 100_000 else {
                throw LibraryValidationError("Notes support up to 100,000 characters.")
            }
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

    @discardableResult
    func toggleFavorite(_ id: String) -> Bool {
        update { database in
            if database.favoriteIDs.insert(id).inserted {
                database.favoriteOrder = database.orderedFavoriteIDs.filter { $0 != id } + [id]
            } else {
                database.favoriteIDs.remove(id)
                database.favoriteOrder.removeAll { $0 == id }
            }
        }
    }

    @discardableResult
    func setPinned(_ pinned: Bool, clipboardEntry id: UUID) -> Bool {
        update { database in
            guard let index = database.clipboard.firstIndex(where: { $0.id == id }) else { return }
            database.clipboard[index].isPinned = pinned
        }
    }

    /// Duplicates a snippet under a fresh name. Keywords must stay unique, so the copy has none.
    @discardableResult
    func duplicate(_ snippet: Snippet) -> Snippet? {
        var copy = snippet
        copy.id = UUID()
        copy.name = snippet.name + " Copy"
        copy.keyword = ""
        return save(copy) ? copy : nil
    }

    /// Why the last capture wasn't kept although the library could be saved. The
    /// clipboard scope shows it, so a copy never disappears without explanation.
    private(set) var captureRejection: String?

    @discardableResult
    func capture(_ entry: ClipboardEntry, now: Date = .now) -> Bool {
        captureRejection = nil
        guard database.preferences.clipboardEnabled, entry.isValid else { return false }
        if case .image = entry.content, !database.preferences.capturesClipboardImages { return false }
        if case .files = entry.content, !database.preferences.capturesClipboardFiles { return false }
        var entry = entry
        entry.richTextDigest = nil
        let insert = { (database: inout LibraryDatabase) in
            var entry = entry
            if let existing = database.clipboard.first(where: { $0.content == entry.content }) {
                entry.id = existing.id
                entry.isPinned = existing.isPinned
            }
            database.clipboard.removeAll { $0.content == entry.content }
            database.clipboard.insert(entry, at: 0)
            Self.pruneClipboard(in: &database, now: now)
        }
        // Pinned entries claim the byte budget first, so a new capture can be the one
        // pruned. Then nothing is saved and the reason is kept.
        var preview = database
        insert(&preview)
        guard preview.clipboard.contains(where: { $0.content == entry.content }) else {
            let budget = ByteCountFormatter.string(fromByteCount: Int64(ClipboardLimits.historyBytes), countStyle: .file)
            captureRejection =
                "The last copy wasn't saved: pinned entries fill the \(budget) clipboard budget. Unpin some to keep new copies."
            return false
        }
        // Formatting goes to its own content-named file before the row that refers to
        // it. If that fails the row carries it inline; an unsaved row's file is cleaned up.
        if case .text = entry.content, let richText = entry.richText {
            entry.richTextDigest = try? images.saveRichText(richText)
        }
        return update(insert)
    }

    /// Saves text recognized in a captured image beside it, and makes the entries
    /// showing that image searchable by it. False when no entry shows the image.
    @discardableResult
    func setRecognizedText(_ text: String, forImage imageID: String) -> Bool {
        guard !isReadOnly, database.clipboard.contains(where: { $0.image?.id == imageID }) else { return false }
        // Saved inline if the side file can't be written, so the text is never lost.
        let stored = (try? images.saveRecognizedText(text, forImage: imageID)) != nil
        return update { database in
            for index in database.clipboard.indices where database.clipboard[index].image?.id == imageID {
                database.clipboard[index].recognizedText = text
                database.clipboard[index].recognizedTextIsStored = stored
            }
        }
    }

    @discardableResult
    func captureImage(
        _ prepared: PreparedClipboardImage, copiedAt: Date = .now,
        sourceName: String, sourceBundleID: String? = nil
    ) -> Bool {
        captureRejection = nil
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

    /// Formatting for an entry whose side file couldn't be read when the library loaded.
    func richText(digest: String) -> ClipboardRichText? { images.richText(digest: digest) }

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
        let previousIDs = Set(database.clipboard.map { "clipboard.\($0.id)" })
        // Pinned entries are exempt from retention and the entry count, but not the byte budget,
        // which they claim first. Within each pass the newest entries win.
        database.clipboard = ClipboardRetentionPolicy(preferences: database.preferences).prune(database.clipboard, now: now)
        let expiredIDs = previousIDs.subtracting(database.clipboard.map { "clipboard.\($0.id)" })
        database.favoriteIDs.subtract(expiredIDs)
        database.usage.removeAll { expiredIDs.contains($0.id) }
    }
}
