import Foundation

/// Full-resolution images live outside the JSON library so ordinary preference
/// and text updates never re-encode megabytes of image data.
@MainActor
final class ClipboardImageStore {
    let directory: URL?
    private var memory: [String: Data] = [:]

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
