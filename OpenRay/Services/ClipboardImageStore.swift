import Foundation

/// Full-resolution images live outside the JSON library so ordinary preference
/// and text updates never re-encode megabytes of image data.
@MainActor
final class ClipboardImageStore {
    let directory: URL?
    private var memory: [String: Data] = [:]
    private var memoryRichText: [UUID: ClipboardRichText] = [:]
    private var memoryRecognizedText: [String: String] = [:]

    init(libraryURL: URL?) {
        directory = libraryURL?.deletingLastPathComponent().appending(
            path: "ClipboardImages", directoryHint: .isDirectory)
    }

    func save(_ prepared: PreparedClipboardImage) throws {
        let image = prepared.image
        guard image.isValid, prepared.png.count == image.byteCount,
            ClipboardImageCodec.digest(prepared.png) == image.id
        else {
            throw LibraryValidationError("Invalid clipboard image data.")
        }
        guard let directory else {
            memory[image.id] = prepared.png
            return
        }
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw LibraryValidationError("The clipboard image directory must not be a symbolic link.")
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appending(path: image.id + ".png")
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw LibraryValidationError("The clipboard image path must not be a symbolic link.")
        }
        if data(for: image) == prepared.png { return }
        try prepared.png.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func data(for image: ClipboardImage) -> Data? {
        guard image.isValid else { return nil }
        guard let directory else { return memory[image.id] }
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        let url = directory.appending(path: image.id + ".png")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
            values.isRegularFile == true, values.isSymbolicLink != true,
            values.fileSize == image.byteCount, let data = try? Data(contentsOf: url),
            ClipboardImageCodec.digest(data) == image.id
        else { return nil }
        return data
    }

    func resource(for image: ClipboardImage) -> ClipboardImageResource? {
        guard image.isValid else { return nil }
        if let directory {
            guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                return .unavailable(image)
            }
            return .file(image, directory.appending(path: image.id + ".png"))
        }
        return memory[image.id].map { .memory(image, $0) } ?? .unavailable(image)
    }

    /// Only content-addressed PNGs owned by this store are eligible for cleanup.
    /// Call after a successful library save; never after an unreadable library load.
    func reconcile(keeping images: [ClipboardImage]) throws {
        let kept = Set(images.map(\.id))
        memory = memory.filter { kept.contains($0.key) }
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return }
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw LibraryValidationError("Clipboard image cleanup skipped a symbolic-link directory.")
        }
        for url in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        {
            let identifier = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "png", identifier.count == 64,
                identifier.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                !kept.contains(identifier)
            else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Side data

/// Formatting and recognized text, kept beside the images rather than in
/// `library.json`, so ordinary saves never rewrite them:
/// - `<entry UUID>.rich`: a binary property list with an entry's RTF and HTML.
/// - `<image digest>.txt`: UTF-8 text recognized in that image.
///
/// They're written when captured or recognized, read once when the library loads,
/// and removed by `reconcileSideData` when their entry or image is gone. A missing
/// or damaged file only costs that entry its formatting or searchable text.
extension ClipboardImageStore {
    func saveRichText(_ richText: ClipboardRichText, for entryID: UUID) throws {
        guard !richText.isEmpty, richText.byteCount <= ClipboardLimits.richTextBytes else {
            throw LibraryValidationError("Invalid clipboard formatting.")
        }
        guard let url = try sideFileURL(entryID.uuidString + ".rich") else {
            memoryRichText[entryID] = richText
            return
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try write(try encoder.encode(richText), to: url)
    }

    func removeRichText(for entryID: UUID) {
        memoryRichText[entryID] = nil
        guard let directory else { return }
        let url = directory.appending(path: entryID.uuidString + ".rich")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true, values.isSymbolicLink != true
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func richText(for entryID: UUID) -> ClipboardRichText? {
        guard let directory else { return memoryRichText[entryID] }
        guard let data = readSideFile(directory.appending(path: entryID.uuidString + ".rich"),
            limit: ClipboardLimits.richTextBytes + 4_096),
            let richText = try? PropertyListDecoder().decode(ClipboardRichText.self, from: data),
            !richText.isEmpty, richText.byteCount <= ClipboardLimits.richTextBytes
        else { return nil }
        return richText
    }

    func saveRecognizedText(_ text: String, forImage imageID: String) throws {
        guard ClipboardImageStore.isDigest(imageID), text.utf8.count <= ClipboardLimits.recognizedTextBytes else {
            throw LibraryValidationError("Invalid recognized text.")
        }
        guard let url = try sideFileURL(imageID + ".txt") else {
            memoryRecognizedText[imageID] = text
            return
        }
        try write(Data(text.utf8), to: url)
    }

    func recognizedText(forImage imageID: String) -> String? {
        guard ClipboardImageStore.isDigest(imageID) else { return nil }
        guard let directory else { return memoryRecognizedText[imageID] }
        guard let data = readSideFile(directory.appending(path: imageID + ".txt"), limit: ClipboardLimits.recognizedTextBytes)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes formatting of entries and text of images no longer in `entries`.
    func reconcileSideData(keeping entries: [ClipboardEntry]) throws {
        let entryIDs = Set(entries.map(\.id.uuidString))
        let imageIDs = Set(entries.compactMap(\.image?.id))
        memoryRichText = memoryRichText.filter { entryIDs.contains($0.key.uuidString) }
        memoryRecognizedText = memoryRecognizedText.filter { imageIDs.contains($0.key) }
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return }
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw LibraryValidationError("Clipboard cleanup skipped a symbolic-link directory.")
        }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.deletingPathExtension().lastPathComponent
            let orphaned: Bool
            switch url.pathExtension {
            case "rich": orphaned = UUID(uuidString: name) != nil && !entryIDs.contains(name)
            case "txt": orphaned = ClipboardImageStore.isDigest(name) && !imageIDs.contains(name)
            default: continue
            }
            guard orphaned else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    nonisolated static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The file's URL in the private directory, created if needed. Nil without a directory.
    private func sideFileURL(_ name: String) throws -> URL? {
        guard let directory else { return nil }
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw LibraryValidationError("The clipboard data directory must not be a symbolic link.")
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: name)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw LibraryValidationError("The clipboard data path must not be a symbolic link.")
        }
        return url
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func readSideFile(_ url: URL, limit: Int) -> Data? {
        guard let directory,
            (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
            values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? .max) <= limit
        else { return nil }
        return try? Data(contentsOf: url)
    }
}
