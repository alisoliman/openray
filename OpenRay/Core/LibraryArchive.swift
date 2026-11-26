import CommonCrypto
import CryptoKit
import Foundation
import Observation

// A single-file archive of the library: library.json, clipboard images, note assets and the
// other store files beside library.json, with selectable categories and optional passphrase
// encryption. Format (all integers big-endian):
//
//   "OPENRAYA" (8 bytes) · format version (1 byte, 1) · flags (1 byte; bit 0 = encrypted)
//   header length (UInt32) · header (JSON, `LibraryArchive.Header`)
//   payload
//
// The payload is a manifest length (UInt32), the manifest (JSON, `LibraryArchive.Manifest`) and
// each file's bytes in manifest order. Encrypted archives seal the payload with AES-256-GCM
// (CryptoKit). The key comes from the passphrase with PBKDF2-HMAC-SHA256 (CommonCrypto) over a
// random 16-byte salt; the salt and iteration count are in the header, which is authenticated as
// the cipher's associated data. A wrong passphrase and a damaged archive fail the same way.
//
// Only library.json and the files of registered portable stores (`LibraryArchive.portableStores`)
// travel. This Mac's own files (approvals, backup settings, caches) never do, and an archive that
// names one of them, under any spelling the file system treats as the same, is refused.

/// A part of the library an archive can carry.
enum LibraryArchiveCategory: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case settings, shortcuts, favorites, quicklinks, snippets, notes, clipboard, scripts, ai, windowLayouts, focus,
        history, otherData

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings: "Settings"
        case .shortcuts: "Aliases and Hotkeys"
        case .favorites: "Favorites and Ranking"
        case .quicklinks: "Quicklinks"
        case .snippets: "Snippets"
        case .notes: "Notes"
        case .clipboard: "Clipboard History"
        case .scripts: "Script Folders"
        case .ai: "AI Commands and Agents"
        case .windowLayouts: "Window Layouts"
        case .focus: "Focus Categories"
        case .history: "Calculator and Emoji History"
        case .otherData: "Other Data"
        }
    }

    var detail: String {
        switch self {
        case .settings: "Preferences, turned-off commands, fallback order and command settings"
        case .shortcuts: "Aliases and keyboard shortcuts for commands"
        case .favorites: "Favorites, their order, and how often you use things"
        case .quicklinks, .snippets: "Every \(title.lowercased().dropLast())"
        case .notes: "Notes and the files they use"
        case .clipboard: "Copied text, files and images, with the images themselves"
        case .scripts: "The folders OpenRay reads script commands from (not the scripts). They arrive turned off."
        case .ai: "Your AI commands and agents"
        case .windowLayouts: "Saved multi-app window layouts"
        case .focus: "App groups that focus sessions block"
        case .history: "Kept calculations and recently used emoji"
        case .otherData: "Other files OpenRay keeps beside the library, such as chats"
        }
    }

    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .shortcuts: "keyboard"
        case .favorites: "star"
        case .quicklinks: "link"
        case .snippets: "text.quote"
        case .notes: "note.text"
        case .clipboard: "clipboard"
        case .scripts: "terminal"
        case .ai: "sparkles"
        case .windowLayouts: "rectangle.3.group"
        case .focus: "moon"
        case .history: "clock.arrow.circlepath"
        case .otherData: "folder"
        }
    }
}

/// Whether an import adds to the library or replaces the chosen parts of it.
enum LibraryImportMode: String, CaseIterable, Identifiable, Sendable {
    /// Adds what's new; an item with the same identity is replaced by the archive's.
    case merge
    /// The chosen categories become exactly what the archive has.
    case replace

    var id: String { rawValue }
    var title: String { self == .merge ? "Merge" : "Replace" }
}

/// A folder beside library.json whose files travel in archives, and the file names it owns.
struct PortableStore: Sendable {
    var folder: String
    var category: LibraryArchiveCategory
    var owns: @Sendable (_ fileName: String) -> Bool
}

/// Thrown when OpenRay won't write somewhere while inert, or when an archive breaks a rule.
enum LibraryArchive {
    static let fileExtension = "openraybackup"
    static let magic = Data("OPENRAYA".utf8)
    static let formatVersion: UInt8 = 1
    static let cipher = "AES-256-GCM"
    static let keyDerivation = "PBKDF2-HMAC-SHA256"
    /// OWASP's 2023 guidance for PBKDF2-HMAC-SHA256.
    static let defaultIterations = 600_000
    /// What the reader accepts, and the writer uses.
    static let iterationRange = 100_000...10_000_000
    static let saltBytes = 16
    /// Files bigger than this aren't archived; the export says which were left out.
    static let maximumFileBytes = 512 * 1024 * 1024
    static let maximumEntries = 100_000
    static let libraryFileName = "library.json"
    /// This Mac's files beside the library. They never travel, and an archive naming one of
    /// them, however spelled, is refused.
    static let machineLocalFiles: [String] = [
        libraryFileName, "library-pending-cleanup.json", LibraryBackupSettingsStore.fileName,
        LocalApprovalStore.fileName, "currency-rates.json",
    ]

    /// The stores whose files archives carry. A slice that keeps portable files beside the
    /// library adds its folder here, with the file names it owns.
    static let portableStores: [PortableStore] = [
        PortableStore(folder: "ClipboardImages", category: .clipboard) { name in
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            return ClipboardImageStore.isDigest(stem) && ["png", "rich", "txt"].contains(ext)
        }
    ]

    struct Failure: LocalizedError, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct Encryption: Codable, Equatable, Sendable {
        var algorithm = LibraryArchive.cipher
        var keyDerivation = LibraryArchive.keyDerivation
        var iterations: Int
        var salt: Data
    }

    struct Header: Codable, Equatable, Sendable {
        var format = 1
        var encryption: Encryption?
    }

    struct FileEntry: Codable, Equatable, Sendable {
        var path: String
        var size: Int
        var sha256: String
        var category: LibraryArchiveCategory?
    }

    struct Manifest: Codable, Equatable, Sendable {
        var createdAt: Date
        var appVersion: String
        var schemaVersion: Int
        var categories: [LibraryArchiveCategory]
        var files: [FileEntry]
    }

    /// An opened archive.
    struct Contents: Sendable {
        var manifest: Manifest
        /// The archived library, with only its categories filled in.
        var database: LibraryDatabase
        /// Every file but library.json, by path relative to the library's folder.
        var files: [String: Data]
        var categories: Set<LibraryArchiveCategory> { Set(manifest.categories) }
    }

    /// A built archive, and what it had to leave out.
    struct Built: Sendable {
        var data: Data
        var omissions: [String]
    }

    // MARK: Paths

    /// How the file system compares names: Unicode-normalized and case-folded, as on APFS and HFS+.
    static func canonical(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    /// The portable store that owns a relative path, `folder/name`, if one does.
    static func portableStore(for path: String) -> PortableStore? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return portableStores.first { $0.folder == parts[0] && $0.owns(parts[1]) }
    }

    /// The file's category, or nil when no portable store owns it.
    static func category(forFile path: String) -> LibraryArchiveCategory? { portableStore(for: path)?.category }

    /// A relative path an archive may carry and write: owned by a portable store, with no
    /// absolute, empty, `.`, `..` or hidden components, and not the library or one of this Mac's
    /// files under any spelling the file system treats as the same.
    static func validate(_ path: String) throws {
        let unsafe = Failure("The archive contains an unsafe file path.")
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.count <= 1_024, !path.hasPrefix("/"), !path.contains("\0"),
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") })
        else { throw unsafe }
        let name = canonical(path)
        let lastName = canonical(String(components.last ?? ""))
        let reserved = machineLocalFiles.map(canonical)
        guard !reserved.contains(name), !reserved.contains(lastName) else { throw unsafe }
        guard portableStore(for: path) != nil else {
            throw Failure("The archive contains a file OpenRay doesn't import: “\(path.truncatedForFeedback)”.")
        }
    }

    // MARK: Categories

    /// A copy of `database` holding only the chosen categories; everything else is emptied.
    static func filtered(_ database: LibraryDatabase, keeping categories: Set<LibraryArchiveCategory>) -> LibraryDatabase {
        var result = database
        let empty = LibraryDatabase()
        for category in LibraryArchiveCategory.allCases where !categories.contains(category) {
            switch category {
            case .settings:
                result.preferences = empty.preferences
                result.disabledCommandIDs = []
                result.fallbackOrder = []
                result.commandPreferences = [:]
            case .shortcuts: result.commandBindings = []
            case .favorites:
                result.favoriteIDs = []
                result.favoriteOrder = []
                result.usage = []
            case .quicklinks: result.quicklinks = []
            case .snippets: result.snippets = []
            case .notes: result.notes = []
            case .clipboard: result.clipboard = []
            case .scripts: result.scriptDirectories = []
            case .ai:
                result.aiCommands = []
                result.agents = []
            case .windowLayouts: result.windowLayouts = []
            case .focus: result.focusCategories = []
            case .history:
                result.calculatorHistory = []
                result.emojiUsage = []
            case .otherData: break
            }
        }
        for command in result.commandPreferences.keys {
            result.commandPreferences[command]?[DeepLinkRouter.legacyTrustKey] = nil
        }
        return result
    }

    /// The categories there's something to export for: every library category, and Other Data
    /// only when a portable store files under it.
    static var exportableCategories: [LibraryArchiveCategory] {
        LibraryArchiveCategory.allCases.filter { $0 != .otherData || portableStores.contains { $0.category == .otherData } }
    }

    /// How many items a category holds, for the import preview. Nil for settings, which aren't counted.
    static func count(of category: LibraryArchiveCategory, in database: LibraryDatabase) -> Int? {
        switch category {
        case .settings, .otherData: nil
        case .shortcuts: database.commandBindings.count
        case .favorites: database.favoriteIDs.count
        case .quicklinks: database.quicklinks.count
        case .snippets: database.snippets.count
        case .notes: database.notes.count
        case .clipboard: database.clipboard.count
        case .scripts: database.scriptDirectories.count
        case .ai: database.aiCommands.count + database.agents.count
        case .windowLayouts: database.windowLayouts.count
        case .focus: database.focusCategories.count
        case .history: database.calculatorHistory.count + database.emojiUsage.count
        }
    }

    // MARK: Writing

    /// Builds an archive of the chosen categories: the library's own data, and the portable files
    /// in `directory` (the library's folder) that belong to them. A passphrase encrypts it.
    /// Clipboard entries are checked against their pictures, so the archive never refers to a
    /// file it doesn't hold; anything left out is listed in `omissions`.
    static func make(
        database: LibraryDatabase, directory: URL?, categories: Set<LibraryArchiveCategory>, passphrase: String? = nil,
        iterations: Int = defaultIterations, appVersion: String = Self.appVersion, now: Date = .now
    ) throws -> Built {
        guard !categories.isEmpty else { throw Failure("Choose at least one kind of data to export.") }
        var library = filtered(database, keeping: categories)
        var omissions: [String] = []
        var files: [(FileEntry, Data)] = []
        if let directory {
            let available = try storeFiles(in: directory, categories: categories)
            omissions += available.omissions
            var byPath = available.files
            if categories.contains(.clipboard) {
                // Keep only the side files entries refer to, and only entries whose picture is here.
                var wanted = Set<String>()
                var dropped = 0
                library.clipboard = library.clipboard.compactMap { entry in
                    var entry = entry
                    if let image = entry.image {
                        let path = "ClipboardImages/\(image.id).png"
                        guard let data = byPath[path], digest(data) == image.id else {
                            dropped += 1
                            return nil
                        }
                        wanted.insert(path)
                        if byPath["ClipboardImages/\(image.id).txt"] != nil { wanted.insert("ClipboardImages/\(image.id).txt") }
                    }
                    if let rich = entry.richTextDigest {
                        if byPath["ClipboardImages/\(rich).rich"] != nil {
                            wanted.insert("ClipboardImages/\(rich).rich")
                        } else {
                            entry.richTextDigest = nil
                        }
                    }
                    return entry
                }
                byPath = byPath.filter { category(forFile: $0.key) != .clipboard || wanted.contains($0.key) }
                if dropped > 0 {
                    omissions.append("\(dropped) clipboard image\(dropped == 1 ? " was" : "s were") missing and left out.")
                }
            }
            for (path, data) in byPath.sorted(by: { $0.key < $1.key }) {
                files.append((FileEntry(path: path, size: data.count, sha256: digest(data), category: category(forFile: path)), data))
            }
        } else if categories.contains(.clipboard) {
            let pictures = library.clipboard.filter { $0.image != nil }.count
            library.clipboard.removeAll { $0.image != nil }
            if pictures > 0 { omissions.append("\(pictures) clipboard image\(pictures == 1 ? " was" : "s were") left out.") }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let libraryData = try encoder.encode(library)
        files.insert(
            (FileEntry(path: libraryFileName, size: libraryData.count, sha256: digest(libraryData), category: nil), libraryData),
            at: 0)
        let manifest = Manifest(
            createdAt: now, appVersion: appVersion, schemaVersion: database.schemaVersion,
            categories: LibraryArchiveCategory.allCases.filter(categories.contains), files: files.map(\.0))
        let manifestData = try encoder.encode(manifest)
        var payload = Data()
        payload.appendBigEndian(UInt32(manifestData.count))
        payload.append(manifestData)
        for (_, data) in files { payload.append(data) }

        var header = Header()
        var flags: UInt8 = 0
        if let passphrase, !passphrase.isEmpty {
            guard iterationRange.contains(iterations) else { throw Failure("The key derivation setting is out of range.") }
            header.encryption = Encryption(iterations: iterations, salt: randomBytes(saltBytes))
            flags |= 1
        }
        let headerData = try JSONEncoder().encode(header)
        var archive = magic
        archive.append(formatVersion)
        archive.append(flags)
        archive.appendBigEndian(UInt32(headerData.count))
        archive.append(headerData)
        if let encryption = header.encryption, let passphrase {
            let key = try deriveKey(passphrase: passphrase, salt: encryption.salt, iterations: encryption.iterations)
            let sealed = try AES.GCM.seal(payload, using: key, authenticating: archive)
            guard let combined = sealed.combined else { throw Failure("The archive couldn't be encrypted.") }
            archive.append(combined)
        } else {
            archive.append(payload)
        }
        return Built(data: archive, omissions: omissions)
    }

    /// The portable files of the chosen categories in the library's folder: regular files only,
    /// never through a symbolic link, each under the size limit.
    static func storeFiles(in directory: URL, categories: Set<LibraryArchiveCategory> = Set(LibraryArchiveCategory.allCases))
        throws -> (files: [String: Data], omissions: [String])
    {
        var files: [String: Data] = [:]
        var omissions: [String] = []
        guard let root = realDirectory(directory) else { return ([:], []) }
        for store in portableStores where categories.contains(store.category) {
            let folder = root + "/" + store.folder
            guard fileKind(folder) == S_IFDIR else { continue }
            for name in try FileManager.default.contentsOfDirectory(atPath: folder).sorted() where store.owns(name) {
                let path = folder + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
                guard Int(info.st_size) <= maximumFileBytes else {
                    omissions.append("\(store.folder)/\(name) is too large to archive.")
                    continue
                }
                files[store.folder + "/" + name] = try Data(contentsOf: URL(fileURLWithPath: path))
            }
        }
        return (files, omissions)
    }

    // MARK: Reading

    /// Whether the archive needs a passphrase. Throws for anything that isn't a supported archive.
    static func isEncrypted(_ data: Data) throws -> Bool {
        try parseHeader(data).header.encryption != nil
    }

    /// Opens an archive. Every file is checked against its digest and against the path rules;
    /// a single bad entry refuses the whole archive.
    static func read(_ data: Data, passphrase: String? = nil) throws -> Contents {
        let (header, headerEnd) = try parseHeader(data)
        var payload = Data(data[(data.startIndex + headerEnd)...])
        if let encryption = header.encryption {
            guard let passphrase, !passphrase.isEmpty else { throw Failure("This archive is encrypted. Enter its passphrase.") }
            let key = try deriveKey(passphrase: passphrase, salt: encryption.salt, iterations: encryption.iterations)
            do {
                let box = try AES.GCM.SealedBox(combined: payload)
                payload = try AES.GCM.open(box, using: key, authenticating: data.prefix(headerEnd))
            } catch {
                throw Failure("The passphrase is wrong, or the archive is damaged.")
            }
        }
        var cursor = payload.startIndex
        guard let manifestLength = payload.readBigEndianUInt32(at: &cursor),
            Int(manifestLength) <= payload.endIndex - cursor
        else { throw Failure("The archive is damaged.") }
        let manifestData = payload[cursor..<(cursor + Int(manifestLength))]
        cursor += Int(manifestLength)
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: manifestData) } catch {
            throw Failure("The archive is damaged.")
        }
        guard manifest.files.count <= maximumEntries else { throw Failure("The archive has too many files.") }
        var files: [String: Data] = [:]
        var names = Set<String>()
        var library: Data?
        for entry in manifest.files {
            guard entry.size >= 0, entry.size <= payload.endIndex - cursor else { throw Failure("The archive is damaged.") }
            let bytes = Data(payload[cursor..<(cursor + entry.size)])
            cursor += entry.size
            guard digest(bytes) == entry.sha256 else {
                throw Failure("“\(entry.path.truncatedForFeedback)” in the archive is damaged.")
            }
            guard names.insert(canonical(entry.path)).inserted else {
                throw Failure("The archive names the same file twice.")
            }
            if entry.path == libraryFileName {
                library = bytes
            } else {
                try validate(entry.path)
                files[entry.path] = bytes
            }
        }
        guard cursor == payload.endIndex else { throw Failure("The archive is damaged.") }
        guard let library else { throw Failure("The archive has no library.") }
        let database: LibraryDatabase
        do {
            database = try JSONDecoder().decode(LibraryDatabase.self, from: library)
        } catch {
            throw Failure("The archive's library couldn't be read. \(error.localizedDescription)")
        }
        guard database.schemaVersion <= LibraryDatabase.currentSchemaVersion else {
            throw Failure("This archive comes from a newer version of OpenRay. Update OpenRay to import it.")
        }
        return Contents(manifest: manifest, database: database, files: files)
    }

    /// Reads and checks the plaintext header: the magic, version 1, only the encryption flag, and
    /// for encrypted archives exactly the supported cipher, key derivation, salt size and iterations.
    private static func parseHeader(_ data: Data) throws -> (header: Header, end: Int) {
        var cursor = data.startIndex
        guard data.count >= magic.count + 6, data.prefix(magic.count) == magic else {
            throw Failure("That file isn't an OpenRay archive.")
        }
        cursor += magic.count
        let version = data[cursor]
        let flags = data[cursor + 1]
        guard version == formatVersion else {
            throw Failure("This archive comes from a newer version of OpenRay. Update OpenRay to import it.")
        }
        guard flags & ~UInt8(1) == 0 else { throw Failure("This archive uses features OpenRay doesn't support.") }
        cursor += 2
        guard let length = data.readBigEndianUInt32(at: &cursor), length <= 64 * 1024, Int(length) <= data.endIndex - cursor,
            let header = try? JSONDecoder().decode(Header.self, from: data[cursor..<(cursor + Int(length))]),
            header.format == 1
        else { throw Failure("The archive is damaged.") }
        guard (flags & 1 == 1) == (header.encryption != nil) else { throw Failure("The archive is damaged.") }
        if let encryption = header.encryption {
            guard encryption.algorithm == cipher, encryption.keyDerivation == keyDerivation,
                encryption.salt.count == saltBytes, iterationRange.contains(encryption.iterations)
            else { throw Failure("This archive's encryption settings aren't supported.") }
        }
        return (header, cursor + Int(length) - data.startIndex)
    }

    // MARK: Importing

    /// What an import will change, category by category.
    struct CategoryPreview: Identifiable, Equatable, Sendable {
        var category: LibraryArchiveCategory
        var archived: Int?
        var current: Int?
        var files: Int
        var id: LibraryArchiveCategory { category }
    }

    static func preview(_ contents: Contents, current: LibraryDatabase) -> [CategoryPreview] {
        LibraryArchiveCategory.allCases.filter(contents.categories.contains).map { category in
            CategoryPreview(
                category: category, archived: count(of: category, in: contents.database),
                current: count(of: category, in: current),
                files: contents.files.keys.filter { Self.category(forFile: $0) == category }.count)
        }
    }

    /// The library after importing `categories` from `incoming`. Only the chosen categories
    /// change. Merging replaces items with the same identity and adds the rest; Replace makes
    /// each chosen category the archive's. Either way:
    /// - script folders arrive turned off, and folders already listed here keep their own state;
    /// - link permissions from an older build are dropped;
    /// - an imported keyword or alias that clashes with one already here is cleared on the
    ///   imported item, and each such change is described in `notes`.
    static func merged(
        current: LibraryDatabase, incoming: LibraryDatabase, categories: Set<LibraryArchiveCategory>,
        mode: LibraryImportMode
    ) -> (database: LibraryDatabase, notes: [String]) {
        var result = current
        var notes: [String] = []
        let replacing = mode == .replace
        for category in LibraryArchiveCategory.allCases where categories.contains(category) {
            switch category {
            case .settings:
                result.preferences = incoming.preferences
                var preferences = incoming.commandPreferences
                for command in preferences.keys { preferences[command]?[DeepLinkRouter.legacyTrustKey] = nil }
                preferences = preferences.filter { !$0.value.isEmpty }
                if replacing {
                    result.disabledCommandIDs = incoming.disabledCommandIDs
                    result.fallbackOrder = incoming.fallbackOrder
                    result.commandPreferences = preferences
                } else {
                    result.disabledCommandIDs.formUnion(incoming.disabledCommandIDs)
                    result.fallbackOrder += incoming.fallbackOrder.filter { !result.fallbackOrder.contains($0) }
                    for (command, values) in preferences {
                        result.commandPreferences[command, default: [:]].merge(values) { _, new in new }
                    }
                }
            case .shortcuts:
                result.commandBindings = replacing
                    ? incoming.commandBindings : mergeByKey(result.commandBindings, incoming.commandBindings, key: \.targetID)
            case .favorites:
                if replacing {
                    result.favoriteIDs = incoming.favoriteIDs
                    result.favoriteOrder = incoming.favoriteOrder
                    result.usage = incoming.usage
                } else {
                    let order = result.orderedFavoriteIDs
                    result.favoriteIDs.formUnion(incoming.favoriteIDs)
                    result.favoriteOrder = order + incoming.orderedFavoriteIDs.filter { !order.contains($0) }
                    var usage = Dictionary(result.usage.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    for record in incoming.usage {
                        if var existing = usage[record.id] {
                            existing.count = min(10_000, max(existing.count, record.count))
                            existing.lastUsed = max(existing.lastUsed, record.lastUsed)
                            usage[record.id] = existing
                        } else {
                            usage[record.id] = record
                        }
                    }
                    result.usage = Array(usage.values.sorted { $0.lastUsed > $1.lastUsed }.prefix(100))
                }
            case .quicklinks:
                result.quicklinks = replacing ? incoming.quicklinks : mergeByKey(result.quicklinks, incoming.quicklinks, key: \.id)
            case .snippets:
                result.snippets = replacing ? incoming.snippets : mergeByKey(result.snippets, incoming.snippets, key: \.id)
            case .notes:
                result.notes = replacing ? incoming.notes : mergeByKey(result.notes, incoming.notes, key: \.id)
            case .clipboard:
                result.clipboard =
                    (replacing ? incoming.clipboard : mergeByKey(result.clipboard, incoming.clipboard, key: \.id))
                    .sorted { $0.copiedAt > $1.copiedAt }
            case .scripts:
                let local = Dictionary(
                    current.scriptDirectories.map { (canonical($0.path), $0) }, uniquingKeysWith: { first, _ in first })
                var added = 0
                var restored: [ScriptDirectoryRecord] = []
                var seen = Set<String>()
                for record in incoming.scriptDirectories where !record.path.isEmpty {
                    let key = canonical(record.path)
                    guard seen.insert(key).inserted else { continue }
                    if let existing = local[key] {
                        restored.append(existing)
                    } else {
                        var record = record
                        record.isEnabled = false
                        if current.scriptDirectories.contains(where: { $0.id == record.id }) { record.id = UUID() }
                        restored.append(record)
                        added += 1
                    }
                }
                if replacing {
                    result.scriptDirectories = restored
                } else {
                    let here = Set(current.scriptDirectories.map(\.id))
                    result.scriptDirectories = current.scriptDirectories + restored.filter { !here.contains($0.id) }
                }
                if added > 0 {
                    notes.append(
                        "\(added) script folder\(added == 1 ? " was" : "s were") added turned off. Turn them on in Settings › Scripts to allow their scripts on this Mac.")
                }
            case .ai:
                result.aiCommands = replacing ? incoming.aiCommands : mergeByKey(result.aiCommands, incoming.aiCommands, key: \.id)
                result.agents = replacing ? incoming.agents : mergeByKey(result.agents, incoming.agents, key: \.id)
            case .windowLayouts:
                result.windowLayouts =
                    replacing ? incoming.windowLayouts : mergeByKey(result.windowLayouts, incoming.windowLayouts, key: \.id)
            case .focus:
                result.focusCategories =
                    replacing ? incoming.focusCategories : mergeByKey(result.focusCategories, incoming.focusCategories, key: \.id)
            case .history:
                result.calculatorHistory =
                    replacing
                    ? incoming.calculatorHistory : mergeByKey(result.calculatorHistory, incoming.calculatorHistory, key: \.id)
                result.emojiUsage = replacing ? incoming.emojiUsage : mergeByKey(result.emojiUsage, incoming.emojiUsage, key: \.id)
            case .otherData:
                break
            }
        }
        notes += resolveConflicts(in: &result, imported: incoming, categories: categories)
        result.schemaVersion = LibraryDatabase.currentSchemaVersion
        return (result, notes)
    }

    /// Clears what the import brought that clashes with what's already here, on the imported
    /// item only, and only for categories being imported:
    /// - an imported snippet keyword another snippet here already uses;
    /// - an imported snippet or quicklink keyword that an alias here already uses;
    /// - an imported alias that another alias or any keyword already uses.
    private static func resolveConflicts(
        in database: inout LibraryDatabase, imported: LibraryDatabase, categories: Set<LibraryArchiveCategory>
    ) -> [String] {
        var notes: [String] = []
        let importedSnippets = categories.contains(.snippets) ? Set(imported.snippets.map(\.id)) : []
        let importedQuicklinks = categories.contains(.quicklinks) ? Set(imported.quicklinks.map(\.id)) : []
        let importedTargets = categories.contains(.shortcuts) ? Set(imported.commandBindings.map(\.targetID)) : []
        let localAliases = Set(
            database.commandBindings.filter { !importedTargets.contains($0.targetID) }
                .compactMap { CommandBinding.normalizedAlias($0.alias) })

        var keywords: [String: UUID] = [:]
        for snippet in database.snippets where !importedSnippets.contains(snippet.id) && !snippet.keyword.isEmpty {
            keywords[snippet.keyword.lowercased()] = snippet.id
        }
        var cleared = 0
        for index in database.snippets.indices where importedSnippets.contains(database.snippets[index].id) {
            let keyword = database.snippets[index].keyword.lowercased()
            guard !keyword.isEmpty else { continue }
            let clashesWithAlias = CommandBinding.normalizedAlias(keyword).map(localAliases.contains) ?? false
            let takenBySnippet = keywords[keyword].map { $0 != database.snippets[index].id } ?? false
            if takenBySnippet || clashesWithAlias {
                database.snippets[index].keyword = ""
                cleared += 1
            } else {
                keywords[keyword] = database.snippets[index].id
            }
        }
        for index in database.quicklinks.indices where importedQuicklinks.contains(database.quicklinks[index].id) {
            guard let keyword = CommandBinding.normalizedAlias(database.quicklinks[index].keyword),
                localAliases.contains(keyword)
            else { continue }
            database.quicklinks[index].keyword = ""
            cleared += 1
        }
        if cleared > 0 {
            notes.append("\(cleared) imported keyword\(cleared == 1 ? " was" : "s were") already in use and left empty.")
        }

        if !importedTargets.isEmpty {
            let contentKeywords = Set(
                (database.quicklinks.map(\.keyword) + database.snippets.map(\.keyword)).compactMap(CommandBinding.normalizedAlias))
            var aliases = localAliases
            var dropped = 0
            for index in database.commandBindings.indices
            where importedTargets.contains(database.commandBindings[index].targetID) {
                guard let alias = CommandBinding.normalizedAlias(database.commandBindings[index].alias) else { continue }
                if aliases.contains(alias) || contentKeywords.contains(alias) {
                    database.commandBindings[index].alias = nil
                    dropped += 1
                } else {
                    aliases.insert(alias)
                }
            }
            database.commandBindings.removeAll { importedTargets.contains($0.targetID) && $0.isEmpty }
            if dropped > 0 {
                notes.append("\(dropped) imported alias\(dropped == 1 ? " was" : "es were") already in use and left out.")
            }
        }
        return notes
    }

    private static func mergeByKey<Item, Key: Hashable>(_ current: [Item], _ incoming: [Item], key: KeyPath<Item, Key>)
        -> [Item]
    {
        var result = current
        var index = Dictionary(result.enumerated().map { ($0.element[keyPath: key], $0.offset) }, uniquingKeysWith: { first, _ in first })
        for item in incoming {
            if let position = index[item[keyPath: key]] {
                result[position] = item
            } else {
                index[item[keyPath: key]] = result.count
                result.append(item)
            }
        }
        return result
    }

    // MARK: Read rules

    /// Whether a clipboard side file would be read back by the store: the same checks
    /// `ClipboardImageStore` applies when it reads. Pictures also need their entry's
    /// `ClipboardImage` (size and validity), which `pictureIsReadable` checks.
    static func sideFileIsReadable(_ name: String, _ data: Data) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        switch (name as NSString).pathExtension {
        case "rich":
            guard ClipboardImageStore.isDigest(stem), data.count <= ClipboardLimits.richTextBytes + 4_096,
                digest(data) == stem,
                let richText = try? PropertyListDecoder().decode(ClipboardRichText.self, from: data)
            else { return false }
            return !richText.isEmpty && richText.byteCount <= ClipboardLimits.richTextBytes
        case "txt":
            return ClipboardImageStore.isDigest(stem) && data.count <= ClipboardLimits.recognizedTextBytes
                && String(data: data, encoding: .utf8) != nil
        default:
            return false
        }
    }

    /// Whether these bytes are the picture `image` refers to, as the store checks on read.
    static func pictureIsReadable(_ data: Data, for image: ClipboardImage) -> Bool {
        image.isValid && data.count == image.byteCount && digest(data) == image.id
    }

    /// The bytes of a regular file in the library's folder, never through a link. Nil otherwise.
    static func existingFile(_ path: String, in directory: URL) -> Data? {
        guard let root = realDirectory(directory) else { return nil }
        let full = root + "/" + path
        guard fileKind(full) == S_IFREG else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: full))
    }

    // MARK: Restoring files

    /// Writes an archive's files into the library's folder and saves the library, as one step
    /// that can be undone:
    /// 1. Every destination is checked first: owned by a portable store, its folder a real folder
    ///    and the file, if there, a regular file. Nothing is followed through a symbolic link.
    /// 2. The files are written to a hidden staging folder inside the library's folder.
    /// 3. Each is moved into place; a file it replaces is moved aside, not deleted.
    /// 4. `commit` saves the library. If it fails, or anything above does, the moved files go
    ///    back and the replaced ones return. On success the replaced files are deleted, and the
    ///    library's own cleanup removes pictures nothing refers to anymore.
    /// Merging keeps files already there. Clipboard pictures are written only when their bytes
    /// match their name. Returns how many files were written.
    @MainActor
    static func restore(
        _ files: [String: Data], mode: LibraryImportMode, into directory: URL, overwriting: Set<String> = [],
        commit: () -> String?
    ) throws -> Int {
        let unsafe = Failure("The archive contains an unsafe file path.")
        if fileKind(directory.path) == nil {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard let root = realDirectory(directory) else { throw unsafe }

        struct Placement {
            var folder: String
            var destination: String
            var data: Data
        }
        var plan: [Placement] = []
        var seen = Set<String>()
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            try validate(path)
            guard seen.insert(canonical(path)).inserted else { throw Failure("The archive names the same file twice.") }
            let parts = path.split(separator: "/").map(String.init)
            if parts[1].hasSuffix(".png"), category(forFile: path) == .clipboard,
                digest(data) + ".png" != parts[1]
            {
                continue
            }
            let folder = root + "/" + parts[0]
            if let kind = fileKind(folder), kind != S_IFDIR { throw unsafe }
            let destination = folder + "/" + parts[1]
            if let kind = fileKind(destination) {
                guard kind == S_IFREG else { throw unsafe }
                if mode == .merge, !overwriting.contains(path) { continue }
            }
            plan.append(Placement(folder: folder, destination: destination, data: data))
        }

        let staging = root + "/.openray-import-" + UUID().uuidString
        guard mkdir(staging, 0o700) == 0 else { throw Failure("The import couldn't prepare its files.") }
        // Removed afterwards unless a replaced file couldn't be put back: then it holds the originals.
        var keepStaging = false
        defer { if !keepStaging { try? FileManager.default.removeItem(atPath: staging) } }
        for (index, placement) in plan.enumerated() {
            guard FileManager.default.createFile(
                atPath: staging + "/new-\(index)", contents: placement.data, attributes: [.posixPermissions: 0o600])
            else { throw Failure("The import couldn't write its files. Is the disk full?") }
        }

        var placed: [(destination: String, replaced: String?)] = []
        /// Takes placed files back and returns replaced ones. A failure keeps the staging folder,
        /// which then holds the originals, and says where.
        func rollBack(after error: Failure) -> Failure {
            var lost: [String] = []
            for item in placed.reversed() {
                unlink(item.destination)
                if let replaced = item.replaced, rename(replaced, item.destination) != 0 {
                    lost.append((item.destination as NSString).lastPathComponent)
                }
            }
            guard !lost.isEmpty else { return error }
            keepStaging = true
            return Failure(
                "\(error.message) Some replaced files couldn't be put back; their originals are in \(staging).")
        }
        do {
            for (index, placement) in plan.enumerated() {
                if fileKind(placement.folder) == nil, mkdir(placement.folder, 0o700) != 0 {
                    throw Failure("The import couldn't create \((placement.folder as NSString).lastPathComponent).")
                }
                guard fileKind(placement.folder) == S_IFDIR else { throw unsafe }
                var replaced: String?
                if let kind = fileKind(placement.destination) {
                    guard kind == S_IFREG else { throw unsafe }
                    let aside = staging + "/old-\(index)"
                    guard rename(placement.destination, aside) == 0 else {
                        throw Failure("The import couldn't replace \((placement.destination as NSString).lastPathComponent).")
                    }
                    replaced = aside
                }
                guard rename(staging + "/new-\(index)", placement.destination) == 0 else {
                    if let replaced { rename(replaced, placement.destination) }
                    throw Failure("The import couldn't place \((placement.destination as NSString).lastPathComponent).")
                }
                placed.append((placement.destination, replaced))
            }
        } catch let error as Failure {
            throw rollBack(after: error)
        } catch {
            throw rollBack(after: Failure(error.localizedDescription))
        }
        // The commit point: the library's save. Before it, everything above can be undone.
        if let message = commit() { throw rollBack(after: Failure(message)) }
        return plan.count
    }

    /// The folder's real path, when it's a folder.
    static func realDirectory(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        let path = String(cString: resolved)
        return fileKind(path) == S_IFDIR ? path : nil
    }

    /// What's at a path, without following a symbolic link there. Nil when nothing is.
    static func fileKind(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    // MARK: Helpers

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func randomBytes(_ count: Int) -> Data {
        Data(SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Array($0) })
    }

    /// PBKDF2-HMAC-SHA256 to a 256-bit key. The passphrase is normalized (NFC) first, so the same
    /// words typed on another keyboard derive the same key.
    static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordBytes.withMemoryRebound(to: CChar.self) { passwordChars in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2), passwordChars.baseAddress, passwordChars.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &key, key.count)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure("The passphrase couldn't be used.") }
        return SymmetricKey(data: key)
    }
}

// MARK: - Backups

/// Scheduled backups: how often, where and how many to keep.
struct LibraryBackupSettings: Codable, Equatable, Sendable {
    enum Frequency: String, Codable, CaseIterable, Identifiable, Sendable {
        case daily, weekly
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var interval: TimeInterval { self == .daily ? 86_400 : 7 * 86_400 }
    }

    var isEnabled = false
    /// The folder backups go to; it can be in iCloud Drive.
    var folderPath: String?
    var frequency: Frequency = .daily
    /// How many backups to keep; older ones are deleted after each new one.
    var keep = 7
    var lastBackupAt: Date?
    var lastError: String?
    /// What the last backup left out, if anything.
    var lastNote: String?
    /// This Mac's backup set. Rotation deletes only the files this set's index lists.
    var setID: UUID?

    static let keepRange = 1...100

    var folder: URL? { folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// Whether a scheduled backup is due: on, with a folder, and never made or older than one interval.
    func isDue(at now: Date) -> Bool {
        guard isEnabled, folder != nil else { return false }
        guard let lastBackupAt else { return true }
        return now.timeIntervalSince(lastBackupAt) >= frequency.interval
    }
}

/// Backup settings, in their own file beside library.json. They describe this Mac, so archives leave them out.
@MainActor
@Observable
final class LibraryBackupSettingsStore {
    nonisolated static let fileName = "backup-settings.json"

    private(set) var settings = LibraryBackupSettings()
    private(set) var errorMessage: String?
    let fileURL: URL?

    /// `libraryURL` nil keeps the settings in memory.
    init(libraryURL: URL?) {
        fileURL = libraryURL?.deletingLastPathComponent().appending(path: Self.fileName)
        if let fileURL, let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(LibraryBackupSettings.self, from: data)
        {
            settings = decoded
        }
    }

    @discardableResult
    func update(_ change: (inout LibraryBackupSettings) -> Void) -> Bool {
        var next = settings
        change(&next)
        next.keep = min(max(next.keep, LibraryBackupSettings.keepRange.lowerBound), LibraryBackupSettings.keepRange.upperBound)
        if let fileURL {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        errorMessage = nil
        settings = next
        return true
    }
}

/// Backups in a chosen folder. Each Mac's backups form a set with its own index file in the
/// folder; rotation deletes only regular files that index lists and OpenRay named, so other
/// files, folders and other sets' backups are never touched.
enum LibraryBackup {
    static let namePrefix = "OpenRay Backup "

    struct Index: Codable, Equatable, Sendable {
        struct Entry: Codable, Equatable, Sendable {
            var name: String
            var sequence: Int
            var createdAt: Date
            /// The file's device and inode when it was written. Rotation deletes only a file that
            /// still has them, so a different file that later took the name is never touched.
            var device: Int64?
            var inode: UInt64?
        }
        var setID: UUID
        var entries: [Entry] = []
    }

    /// `OpenRay Backup 2026-11-26 0930 15.openraybackup`, in local time.
    static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d-%02d-%02d %02d%02d %02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0, parts.second ?? 0)
        return namePrefix + stamp + "." + LibraryArchive.fileExtension
    }

    static func isBackupName(_ name: String) -> Bool {
        name.hasPrefix(namePrefix) && name.hasSuffix("." + LibraryArchive.fileExtension) && !name.contains("/")
    }

    static func indexURL(in folder: URL, setID: UUID) -> URL {
        folder.appending(path: ".openray-backups-\(setID.uuidString.lowercased()).json")
    }

    /// This set's index. Entries without OpenRay's backup names, and repeated names, are dropped.
    static func index(in folder: URL, setID: UUID) -> Index {
        guard let data = try? Data(contentsOf: indexURL(in: folder, setID: setID)),
            var index = try? JSONDecoder().decode(Index.self, from: data), index.setID == setID
        else { return Index(setID: setID) }
        var seen = Set<String>()
        index.entries = index.entries.sorted { $0.sequence > $1.sequence }
            .filter { isBackupName($0.name) && seen.insert($0.name).inserted }
            .reversed()
        return index
    }

    /// The device and inode of a regular file, not through a link.
    static func fileIdentity(_ url: URL) -> (device: Int64, inode: UInt64)? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return (Int64(info.st_dev), UInt64(info.st_ino))
    }

    /// This set's backups that are still there, newest first.
    static func backups(in folder: URL, setID: UUID) -> [URL] {
        index(in: folder, setID: setID).entries.sorted { $0.sequence > $1.sequence }
            .map { folder.appending(path: $0.name) }
            .filter { LibraryArchive.fileKind($0.path) == S_IFREG }
    }

    /// Writes one backup into the set, then deletes all but the set's newest `keep`. Returns the new file.
    @discardableResult
    static func write(_ archive: Data, to folder: URL, setID: UUID, keep: Int, now: Date = .now) throws -> URL {
        try InertWrites.check(folder, what: "writing backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var index = index(in: folder, setID: setID)
        let stem = (fileName(for: now) as NSString).deletingPathExtension
        var name = fileName(for: now)
        var suffix = 2
        while LibraryArchive.fileKind(folder.appending(path: name).path) != nil {
            name = "\(stem) \(suffix).\(LibraryArchive.fileExtension)"
            suffix += 1
        }
        let url = folder.appending(path: name)
        try archive.write(to: url, options: [.withoutOverwriting])
        let identity = fileIdentity(url)
        index.entries.append(
            Index.Entry(
                name: name, sequence: (index.entries.map(\.sequence).max() ?? 0) + 1, createdAt: now,
                device: identity?.device, inode: identity?.inode))
        try save(index, in: folder)
        try rotate(in: folder, setID: setID, keep: keep)
        return url
    }

    /// Deletes this set's backups beyond the newest `keep`: only regular files the index lists,
    /// with OpenRay's backup names, directly in the folder, that are still the very file written
    /// (same device and inode). Never a folder, a link or a file that took the name later. A
    /// deletion that fails stays in the index and is tried again next time.
    @discardableResult
    static func rotate(in folder: URL, setID: UUID, keep: Int) throws -> [URL] {
        var index = index(in: folder, setID: setID)
        let ordered = index.entries.sorted { $0.sequence > $1.sequence }
        let old = ordered.dropFirst(max(1, keep))
        var removed: [URL] = []
        var forgotten = Set<String>()
        for entry in old {
            let url = folder.appending(path: entry.name)
            guard let identity = fileIdentity(url), let device = entry.device, let inode = entry.inode,
                identity.device == device, identity.inode == inode
            else {
                // Gone, or no longer the file this set wrote: forget it, delete nothing.
                forgotten.insert(entry.name)
                continue
            }
            if unlink(url.path) == 0 {
                removed.append(url)
                forgotten.insert(entry.name)
            }
        }
        index.entries.removeAll { forgotten.contains($0.name) }
        try save(index, in: folder)
        return removed
    }

    private static func save(_ index: Index, in folder: URL) throws {
        try JSONEncoder().encode(index).write(to: indexURL(in: folder, setID: index.setID), options: .atomic)
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    func readBigEndianUInt32(at cursor: inout Index) -> UInt32? {
        guard endIndex - cursor >= 4 else { return nil }
        let value = self[cursor..<(cursor + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        cursor += 4
        return value
    }
}

// MARK: - Importing into the store

extension LibraryStore {
    struct ArchiveImportReport: Equatable, Sendable {
        var categories: Set<LibraryArchiveCategory>
        var notes: [String]
        var filesWritten: Int
    }

    /// Imports the chosen categories from an opened archive. The merged library is checked
    /// before anything changes; clipboard entries from the archive whose pictures aren't in it
    /// (or already here) are left out; then files and library are written as one step that
    /// rolls back if any part fails.
    func importArchive(
        _ contents: LibraryArchive.Contents, categories: Set<LibraryArchiveCategory>, mode: LibraryImportMode
    ) throws -> ArchiveImportReport {
        let chosen = categories.intersection(contents.categories)
        guard !chosen.isEmpty else { throw LibraryArchive.Failure("Choose at least one kind of data to import.") }
        guard !isReadOnly else { throw LibraryArchive.Failure(errorMessage ?? "The library can't be changed.") }
        var (merged, notes) = LibraryArchive.merged(
            current: database, incoming: contents.database, categories: chosen, mode: mode)
        let directory = fileURL?.deletingLastPathComponent()
        // Only files the committed rows will read, checked by the store's own read rules. Merging
        // keeps a file already here unless it fails those rules and the archive's passes.
        var files: [String: Data] = [:]
        var overwriting: Set<String> = []
        func existingPasses(_ path: String, _ check: (Data) -> Bool) -> Bool {
            guard let directory, let data = LibraryArchive.existingFile(path, in: directory) else { return false }
            return check(data)
        }
        func take(_ path: String, _ check: (Data) -> Bool) -> Bool {
            let here = existingPasses(path, check)
            guard let data = contents.files[path], check(data) else { return here }
            files[path] = data
            if !here { overwriting.insert(path) }
            return true
        }
        if chosen.contains(.clipboard) {
            let imported = Set(contents.database.clipboard.map(\.id))
            var missing = 0
            var lostFormatting = 0
            merged.clipboard = merged.clipboard.compactMap { entry in
                guard imported.contains(entry.id) else { return entry }
                var entry = entry
                if let image = entry.image {
                    // Without a folder (an in-memory library) nothing can be placed, so only a
                    // picture the store already has will do.
                    let readable =
                        directory == nil
                        ? imageData(for: image) != nil
                        : take("ClipboardImages/\(image.id).png") { LibraryArchive.pictureIsReadable($0, for: image) }
                    guard readable else {
                        missing += 1
                        return nil
                    }
                    let text = "ClipboardImages/\(image.id).txt"
                    _ = take(text) { LibraryArchive.sideFileIsReadable((text as NSString).lastPathComponent, $0) }
                }
                if let rich = entry.richTextDigest {
                    let path = "ClipboardImages/\(rich).rich"
                    if !take(path, { LibraryArchive.sideFileIsReadable((path as NSString).lastPathComponent, $0) }) {
                        entry.richTextDigest = nil
                        lostFormatting += 1
                    }
                }
                return entry
            }
            if missing > 0 {
                notes.append("\(missing) clipboard entr\(missing == 1 ? "y was" : "ies were") left out because their pictures weren't in the archive or were damaged.")
            }
            if lostFormatting > 0 {
                notes.append("\(lostFormatting) clipboard entr\(lostFormatting == 1 ? "y keeps" : "ies keep") its text but not its formatting.")
            }
        }
        do { try merged.validate() } catch { throw LibraryArchive.Failure(error.localizedDescription) }
        let written: Int
        if let directory {
            var warning: String?
            written = try LibraryArchive.restore(files, mode: mode, into: directory, overwriting: overwriting) {
                switch self.replaceLibraryForImport(with: merged) {
                case .saved: return nil
                case .savedWithWarning(let message):
                    // The library reached the disk, so the files stay with it.
                    warning = message
                    return nil
                case .failed(let message): return message
                }
            }
            if let warning { notes.append(warning) }
        } else {
            guard replaceLibrary(with: merged) else {
                throw LibraryArchive.Failure(errorMessage ?? "The library couldn't be saved.")
            }
            written = 0
        }
        return ArchiveImportReport(categories: chosen, notes: notes, filesWritten: written)
    }

    /// An archive of the chosen categories, built off the main actor.
    func makeArchive(
        categories: Set<LibraryArchiveCategory>, passphrase: String? = nil,
        iterations: Int = LibraryArchive.defaultIterations, now: Date = .now
    ) async throws -> LibraryArchive.Built {
        let database = database
        let directory = fileURL?.deletingLastPathComponent()
        return try await Task.detached(priority: .userInitiated) {
            try LibraryArchive.make(
                database: database, directory: directory, categories: categories, passphrase: passphrase,
                iterations: iterations, now: now)
        }.value
    }
}

// MARK: - Scheduled backups

/// Makes scheduled backups while OpenRay runs, and Back Up Now on request. Inert launches
/// (tests, verification) never schedule, and write only into the temporary folder.
@MainActor
@Observable
final class LibraryBackupScheduler {
    let store: LibraryStore
    let settings: LibraryBackupSettingsStore
    let sideEffects: SideEffectGuard
    private(set) var isBackingUp = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: LibraryStore, settings: LibraryBackupSettingsStore, sideEffects: SideEffectGuard = .current) {
        self.store = store
        self.settings = settings
        self.sideEffects = sideEffects
    }

    var isRunning: Bool { task != nil }

    /// Checks now and then every half hour. Does nothing while inert.
    func start() {
        guard !sideEffects.effective.isInert, task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.backUpIfDue()
                try? await Task.sleep(for: .seconds(1_800))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Makes a backup when one is due. Returns it, or nil when none was due or it failed.
    @discardableResult
    func backUpIfDue(now: Date = .now) async -> URL? {
        guard settings.settings.isDue(at: now) else { return nil }
        return try? await backUpNow(now: now)
    }

    /// Makes a backup of everything into the chosen folder and keeps the newest few.
    @discardableResult
    func backUpNow(now: Date = .now) async throws -> URL {
        guard let folder = settings.settings.folder else {
            throw LibraryArchive.Failure("Choose a folder for backups first.")
        }
        try InertWrites.check(folder, sideEffects: sideEffects, what: "writing backups")
        guard !isBackingUp else { throw LibraryArchive.Failure("A backup is already being made.") }
        isBackingUp = true
        defer { isBackingUp = false }
        let setID = settings.settings.setID ?? UUID()
        if settings.settings.setID == nil { settings.update { $0.setID = setID } }
        do {
            let built = try await store.makeArchive(categories: Set(LibraryArchiveCategory.allCases), now: now)
            let keep = settings.settings.keep
            let url = try await Task.detached(priority: .utility) {
                try LibraryBackup.write(built.data, to: folder, setID: setID, keep: keep, now: now)
            }.value
            settings.update {
                $0.lastBackupAt = now
                $0.lastError = nil
                $0.lastNote = built.omissions.isEmpty ? nil : built.omissions.joined(separator: " ")
            }
            return url
        } catch {
            settings.update { $0.lastError = error.localizedDescription }
            throw error
        }
    }
}
