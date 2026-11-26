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
        case .scripts: "The folders OpenRay reads script commands from (not the scripts)"
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

enum LibraryArchive {
    static let fileExtension = "openraybackup"
    static let magic = Data("OPENRAYA".utf8)
    static let formatVersion: UInt8 = 1
    /// OWASP's 2023 guidance for PBKDF2-HMAC-SHA256.
    static let defaultIterations = 600_000
    static let iterationRange = 1_000...10_000_000
    /// Files bigger than this aren't archived.
    static let maximumFileBytes = 512 * 1024 * 1024
    /// Store files that describe this Mac, not the library, and stay out of archives.
    static let machineLocalFiles: Set<String> = [
        "library.json", "library-pending-cleanup.json", LibraryBackupSettingsStore.fileName,
    ]

    struct Failure: LocalizedError, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct Encryption: Codable, Equatable, Sendable {
        var algorithm = "AES-256-GCM"
        var keyDerivation = "PBKDF2-HMAC-SHA256"
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

    // MARK: Categories

    /// The file's category, by where it lives beside library.json.
    static func category(forFile path: String) -> LibraryArchiveCategory {
        let first = path.split(separator: "/").first.map(String.init) ?? path
        switch first {
        case "ClipboardImages": return .clipboard
        case "NoteAssets", "Notes", "NotesAssets": return .notes
        default: return .otherData
        }
    }

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
        return result
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

    /// Builds an archive of the chosen categories: the library's own data, and the files in
    /// `directory` (the library's folder) that belong to them. A passphrase encrypts it.
    static func make(
        database: LibraryDatabase, directory: URL?, categories: Set<LibraryArchiveCategory>, passphrase: String? = nil,
        iterations: Int = defaultIterations, appVersion: String = Self.appVersion, now: Date = .now
    ) throws -> Data {
        guard !categories.isEmpty else { throw Failure("Choose at least one kind of data to export.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let library = try encoder.encode(filtered(database, keeping: categories))
        var files: [(FileEntry, Data)] = [
            (FileEntry(path: "library.json", size: library.count, sha256: digest(library), category: nil), library)
        ]
        if let directory {
            for (path, url) in try storeFiles(in: directory) {
                let category = category(forFile: path)
                guard categories.contains(category) else { continue }
                let data = try Data(contentsOf: url)
                files.append((FileEntry(path: path, size: data.count, sha256: digest(data), category: category), data))
            }
        }
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
            header.encryption = Encryption(iterations: iterations, salt: randomBytes(16))
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
        return archive
    }

    /// Files beside library.json, by relative path: regular, non-hidden files, without symbolic
    /// links, machine-local files or anything too large.
    static func storeFiles(in directory: URL) throws -> [(String, URL)] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var files: [(String, URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                (values.fileSize ?? 0) <= maximumFileBytes
            else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(root.path + "/") else { continue }
            let path = String(full.dropFirst(root.path.count + 1))
            // A backup folder inside the library's folder mustn't fold old backups into new ones.
            guard !machineLocalFiles.contains(path), !path.hasSuffix(".tmp"),
                url.pathExtension != fileExtension, (try? validate(path)) != nil
            else { continue }
            files.append((path, url))
        }
        return files.sorted { $0.0 < $1.0 }
    }

    // MARK: Reading

    /// Whether the archive needs a passphrase. Throws for anything that isn't an archive.
    static func isEncrypted(_ data: Data) throws -> Bool {
        try parseHeader(data).header.encryption != nil
    }

    /// Opens an archive, checking every file against its digest.
    static func read(_ data: Data, passphrase: String? = nil) throws -> Contents {
        let (header, headerEnd) = try parseHeader(data)
        var payload = Data(data[(data.startIndex + headerEnd)...])
        if let encryption = header.encryption {
            guard let passphrase, !passphrase.isEmpty else { throw Failure("This archive is encrypted. Enter its passphrase.") }
            guard iterationRange.contains(encryption.iterations), encryption.salt.count >= 8 else {
                throw Failure("This archive's encryption settings aren't supported.")
            }
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
        var files: [String: Data] = [:]
        var library: Data?
        for entry in manifest.files {
            guard entry.size >= 0, entry.size <= payload.endIndex - cursor else { throw Failure("The archive is damaged.") }
            let bytes = Data(payload[cursor..<(cursor + entry.size)])
            cursor += entry.size
            guard digest(bytes) == entry.sha256 else {
                throw Failure("“\(entry.path)” in the archive is damaged.")
            }
            if entry.path == "library.json" {
                library = bytes
            } else {
                try validate(entry.path)
                files[entry.path] = bytes
            }
        }
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

    private static func parseHeader(_ data: Data) throws -> (header: Header, end: Int) {
        var cursor = data.startIndex
        guard data.count >= magic.count + 6, data.prefix(magic.count) == magic else {
            throw Failure("That file isn't an OpenRay archive.")
        }
        cursor += magic.count
        guard data[cursor] <= formatVersion else {
            throw Failure("This archive comes from a newer version of OpenRay. Update OpenRay to import it.")
        }
        cursor += 2
        guard let length = data.readBigEndianUInt32(at: &cursor), Int(length) <= data.endIndex - cursor,
            let header = try? JSONDecoder().decode(Header.self, from: data[cursor..<(cursor + Int(length))])
        else { throw Failure("The archive is damaged.") }
        let encrypted = data[data.startIndex + magic.count + 1] & 1 == 1
        guard encrypted == (header.encryption != nil) else { throw Failure("The archive is damaged.") }
        return (header, cursor + Int(length) - data.startIndex)
    }

    /// A relative path an archive may write into the library's folder: no absolute paths, no
    /// `..`, no hidden components.
    static func validate(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.count <= 1_024, !path.hasPrefix("/"), !path.contains("\0"),
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") })
        else { throw Failure("The archive contains an unsafe file path.") }
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

    /// The library after importing `categories` from `incoming`. Merging replaces items with the
    /// same identity and adds the rest; snippet keywords and aliases that would clash with ones
    /// already here are dropped from the imported items, and each such change is described.
    static func merged(
        current: LibraryDatabase, incoming: LibraryDatabase, categories: Set<LibraryArchiveCategory>,
        mode: LibraryImportMode
    ) -> (database: LibraryDatabase, notes: [String]) {
        var result = current
        var notes: [String] = []
        if mode == .replace, categories.isSuperset(of: LibraryArchiveCategory.allCases) {
            result = incoming
            result.schemaVersion = LibraryDatabase.currentSchemaVersion
            return (result, notes)
        }
        let replacing = mode == .replace
        for category in LibraryArchiveCategory.allCases where categories.contains(category) {
            switch category {
            case .settings:
                result.preferences = incoming.preferences
                if replacing {
                    result.disabledCommandIDs = incoming.disabledCommandIDs
                    result.fallbackOrder = incoming.fallbackOrder
                    result.commandPreferences = incoming.commandPreferences
                } else {
                    result.disabledCommandIDs.formUnion(incoming.disabledCommandIDs)
                    result.fallbackOrder += incoming.fallbackOrder.filter { !result.fallbackOrder.contains($0) }
                    for (command, values) in incoming.commandPreferences {
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
                if replacing {
                    result.scriptDirectories = incoming.scriptDirectories
                } else {
                    let paths = Set(result.scriptDirectories.map(\.path))
                    result.scriptDirectories = mergeByKey(
                        result.scriptDirectories, incoming.scriptDirectories.filter { !paths.contains($0.path) }, key: \.id)
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
        notes += resolveConflicts(in: &result, imported: incoming)
        result.schemaVersion = LibraryDatabase.currentSchemaVersion
        return (result, notes)
    }

    /// Clears imported snippet keywords that another snippet already uses, and imported aliases
    /// that another command or a keyword already uses. Items already in the library keep theirs.
    private static func resolveConflicts(in database: inout LibraryDatabase, imported: LibraryDatabase) -> [String] {
        var notes: [String] = []
        let importedSnippets = Set(imported.snippets.map(\.id))
        var keywords: [String: UUID] = [:]
        for snippet in database.snippets where !importedSnippets.contains(snippet.id) && !snippet.keyword.isEmpty {
            keywords[snippet.keyword.lowercased()] = snippet.id
        }
        var cleared = 0
        for index in database.snippets.indices where importedSnippets.contains(database.snippets[index].id) {
            let keyword = database.snippets[index].keyword.lowercased()
            guard !keyword.isEmpty else { continue }
            if let owner = keywords[keyword], owner != database.snippets[index].id {
                database.snippets[index].keyword = ""
                cleared += 1
            } else {
                keywords[keyword] = database.snippets[index].id
            }
        }
        if cleared > 0 {
            notes.append("\(cleared) imported snippet keyword\(cleared == 1 ? " was" : "s were") already in use and left empty.")
        }

        let importedTargets = Set(imported.commandBindings.map(\.targetID))
        let contentKeywords = Set(
            (database.quicklinks.map(\.keyword) + database.snippets.map(\.keyword)).compactMap(CommandBinding.normalizedAlias))
        var aliases = Set(
            database.commandBindings.filter { !importedTargets.contains($0.targetID) }
                .compactMap { CommandBinding.normalizedAlias($0.alias) })
        var dropped = 0
        for index in database.commandBindings.indices where importedTargets.contains(database.commandBindings[index].targetID) {
            guard let alias = CommandBinding.normalizedAlias(database.commandBindings[index].alias) else { continue }
            if aliases.contains(alias) || contentKeywords.contains(alias) {
                database.commandBindings[index].alias = nil
                dropped += 1
            } else {
                aliases.insert(alias)
            }
        }
        database.commandBindings.removeAll(where: \.isEmpty)
        if dropped > 0 {
            notes.append("\(dropped) imported alias\(dropped == 1 ? " was" : "es were") already in use and left out.")
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

    /// Writes an archive's files for the chosen categories into the library's folder. Merging
    /// keeps files that are already there; replacing overwrites them. Clipboard images are
    /// written only when their bytes match their content-addressed name.
    @discardableResult
    static func install(
        _ files: [String: Data], categories: Set<LibraryArchiveCategory>, mode: LibraryImportMode, into directory: URL
    ) throws -> Int {
        let root = directory.standardizedFileURL
        var written = 0
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            try validate(path)
            let category = category(forFile: path)
            guard categories.contains(category) else { continue }
            if category == .clipboard, path.hasSuffix(".png") {
                let name = (path as NSString).lastPathComponent
                guard ClipboardImageCodec.digest(data) + ".png" == name else { continue }
            }
            let destination = root.appending(path: path)
            let folder = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Never write through a link that leads out of the library's folder.
            guard folder.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path),
                (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
            else { throw Failure("The archive contains an unsafe file path.") }
            if mode == .merge, FileManager.default.fileExists(atPath: destination.path) { continue }
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            written += 1
        }
        return written
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

enum LibraryBackup {
    static let namePrefix = "OpenRay Backup "

    /// `OpenRay Backup 2026-11-26 0930 15.openraybackup`: sortable by name, in local time.
    static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d-%02d-%02d %02d%02d %02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0, parts.second ?? 0)
        return namePrefix + stamp + "." + LibraryArchive.fileExtension
    }

    /// The backups in a folder, newest first. Only files OpenRay named are listed.
    static func backups(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix(namePrefix) && $0.pathExtension == LibraryArchive.fileExtension }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Writes one backup, then deletes all but the newest `keep`. Returns the new file.
    @discardableResult
    static func write(_ archive: Data, to folder: URL, keep: Int, now: Date = .now) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appending(path: fileName(for: now))
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: (fileName(for: now) as NSString).deletingPathExtension + " \(suffix)." + LibraryArchive.fileExtension)
            suffix += 1
        }
        try archive.write(to: url, options: .atomic)
        try rotate(in: folder, keep: keep)
        return url
    }

    /// Deletes every OpenRay backup in the folder but the newest `keep`. Other files stay.
    @discardableResult
    static func rotate(in folder: URL, keep: Int) throws -> [URL] {
        let old = Array(try backups(in: folder).dropFirst(max(1, keep)))
        for url in old { try FileManager.default.removeItem(at: url) }
        return old
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

    /// Imports the chosen categories from an opened archive: one validated save of the library,
    /// then the files those categories carry. Nothing changes when the save fails.
    func importArchive(
        _ contents: LibraryArchive.Contents, categories: Set<LibraryArchiveCategory>, mode: LibraryImportMode
    ) throws -> ArchiveImportReport {
        let chosen = categories.intersection(contents.categories)
        guard !chosen.isEmpty else { throw LibraryArchive.Failure("Choose at least one kind of data to import.") }
        let (merged, notes) = LibraryArchive.merged(
            current: database, incoming: contents.database, categories: chosen, mode: mode)
        guard replaceLibrary(with: merged) else {
            throw LibraryArchive.Failure(errorMessage ?? "The library couldn't be saved.")
        }
        var written = 0
        if let directory = fileURL?.deletingLastPathComponent() {
            written = try LibraryArchive.install(contents.files, categories: chosen, mode: mode, into: directory)
        }
        return ArchiveImportReport(categories: chosen, notes: notes, filesWritten: written)
    }

    /// An archive of the whole library, or of the chosen categories, built off the main actor.
    func makeArchive(
        categories: Set<LibraryArchiveCategory>, passphrase: String? = nil,
        iterations: Int = LibraryArchive.defaultIterations, now: Date = .now
    ) async throws -> Data {
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
        guard !sideEffects.isInert, task == nil else { return }
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
        try checkAllowed(folder)
        guard !isBackingUp else { throw LibraryArchive.Failure("A backup is already being made.") }
        isBackingUp = true
        defer { isBackingUp = false }
        do {
            let archive = try await store.makeArchive(categories: Set(LibraryArchiveCategory.allCases), now: now)
            let keep = settings.settings.keep
            let url = try await Task.detached(priority: .utility) {
                try LibraryBackup.write(archive, to: folder, keep: keep, now: now)
            }.value
            settings.update {
                $0.lastBackupAt = now
                $0.lastError = nil
            }
            return url
        } catch {
            settings.update { $0.lastError = error.localizedDescription }
            throw error
        }
    }

    /// While inert, backups may go only into the temporary folder.
    private func checkAllowed(_ folder: URL) throws {
        guard sideEffects.isInert else { return }
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let target = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if !target.hasPrefix(temporary.hasSuffix("/") ? temporary : temporary + "/") {
            try sideEffects.check("writing backups")
        }
    }
}
