import Foundation

/// Full-resolution images live outside the JSON library so ordinary preference
/// and text updates never re-encode megabytes of image data.
@MainActor
final class ClipboardImageStore {
    let directory: URL?
    private var memory: [String: Data] = [:]
    private var memoryRichText: [String: ClipboardRichText] = [:]
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
/// - `<digest>.rich`: a binary property list with RTF and HTML, named by its own
///   SHA-256 digest, which the entry stores. A file is only ever read for the digest
///   it has, so it can't be overwritten for another row or come back stale.
/// - `<image digest>.txt`: UTF-8 text recognized in that image.
///
/// They're written before the row that refers to them is saved, read when the
/// library loads, and removed by `reconcileSideData` once nothing refers to them.
/// A missing or damaged file only costs that entry its formatting or searchable text.
extension ClipboardImageStore {
    /// Writes formatting to a file named by its digest, and returns the digest for the
    /// entry to store. Never touches another digest's file.
    func saveRichText(_ richText: ClipboardRichText) throws -> String {
        guard !richText.isEmpty, richText.byteCount <= ClipboardLimits.richTextBytes else {
            throw LibraryValidationError("Invalid clipboard formatting.")
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(richText)
        let digest = ClipboardImageCodec.digest(data)
        guard let url = try sideFileURL(digest + ".rich") else {
            memoryRichText[digest] = richText
            return digest
        }
        if readSideFile(url, limit: ClipboardLimits.richTextBytes + 4_096) != data { try write(data, to: url) }
        return digest
    }

    /// The formatting with `digest`, only if its file still has that digest.
    func richText(digest: String) -> ClipboardRichText? {
        guard ClipboardImageStore.isDigest(digest) else { return nil }
        guard let directory else { return memoryRichText[digest] }
        guard let data = readSideFile(directory.appending(path: digest + ".rich"),
            limit: ClipboardLimits.richTextBytes + 4_096),
            ClipboardImageCodec.digest(data) == digest,
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

    /// Removes formatting no entry refers to (gone, or replaced by a copy without
    /// formatting) and text of images no longer in `entries`.
    func reconcileSideData(keeping entries: [ClipboardEntry]) throws {
        let richDigests = Set(entries.compactMap(\.richTextDigest))
        let imageIDs = Set(entries.compactMap(\.image?.id))
        memoryRichText = memoryRichText.filter { richDigests.contains($0.key) }
        memoryRecognizedText = memoryRecognizedText.filter { imageIDs.contains($0.key) }
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return }
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw LibraryValidationError("Clipboard cleanup skipped a symbolic-link directory.")
        }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.deletingPathExtension().lastPathComponent
            let orphaned: Bool
            switch url.pathExtension {
            case "rich": orphaned = ClipboardImageStore.isDigest(name) && !richDigests.contains(name)
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
