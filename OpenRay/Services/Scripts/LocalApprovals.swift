import Darwin
import Foundation
import Observation

// Approvals that belong to this Mac and never travel: which script folders may run, and which
// commands links may run without asking. They live in their own file beside library.json,
// which archives leave out, so restoring a library can't grant either one.

/// A folder as the file system knows it: its resolved path and the device and inode it has
/// there. Replacing the folder, or pointing its path somewhere else, changes the identity.
struct FolderIdentity: Codable, Hashable, Sendable {
    var resolvedPath: String
    var device: Int64
    var inode: UInt64

    /// The identity of the folder at `url` now, following links once to the folder itself.
    /// Nil when there's no folder there.
    static func current(of url: URL) -> FolderIdentity? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        let path = String(cString: resolved)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return FolderIdentity(resolvedPath: path, device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

struct LocalApprovals: Codable, Equatable, Sendable {
    /// Script folders the person allowed on this Mac, by record id, with the folder they saw.
    var scriptFolders: [UUID: FolderIdentity] = [:]
    /// Commands links may run without asking, allowed from the command's own ⌘K on this Mac.
    var linkCommands: Set<String> = []
}

/// This Mac's approvals, in `local-approvals.json` beside the library, or in memory for an
/// in-memory library. One instance per library store.
@MainActor
@Observable
final class LocalApprovalStore {
    nonisolated static let fileName = "local-approvals.json"

    private(set) var approvals = LocalApprovals()
    private(set) var errorMessage: String?
    let fileURL: URL?

    private static let instances = NSMapTable<LibraryStore, LocalApprovalStore>.weakToStrongObjects()

    /// The approvals of the library `store` keeps.
    static func `for`(_ store: LibraryStore) -> LocalApprovalStore {
        if let existing = instances.object(forKey: store) { return existing }
        let made = LocalApprovalStore(libraryURL: store.fileURL)
        instances.setObject(made, forKey: store)
        return made
    }

    init(libraryURL: URL?) {
        fileURL = libraryURL?.deletingLastPathComponent().appending(path: Self.fileName)
        if let fileURL, let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(LocalApprovals.self, from: data)
        {
            approvals = decoded
        }
    }

    @discardableResult
    func update(_ change: (inout LocalApprovals) -> Void) -> Bool {
        var next = approvals
        change(&next)
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
        approvals = next
        return true
    }

    // MARK: Script folders

    /// Whether the folder is still the one the person allowed. A moved, replaced or redirected
    /// folder needs allowing again.
    func isApproved(_ record: ScriptDirectoryRecord) -> Bool {
        guard let approved = approvals.scriptFolders[record.id], let url = record.url,
            let current = FolderIdentity.current(of: url)
        else { return false }
        return approved == current
    }

    /// Allows the folder as it is now. False when there's no folder at its path.
    @discardableResult
    func approve(_ record: ScriptDirectoryRecord) -> Bool {
        guard let url = record.url, let identity = FolderIdentity.current(of: url) else { return false }
        return update { $0.scriptFolders[record.id] = identity }
    }

    func revoke(_ recordID: UUID) {
        guard approvals.scriptFolders[recordID] != nil else { return }
        update { $0.scriptFolders[recordID] = nil }
    }

    // MARK: Links

    func linksRunWithoutAsking(_ commandID: String) -> Bool { approvals.linkCommands.contains(commandID) }

    @discardableResult
    func setLinksRunWithoutAsking(_ allowed: Bool, for commandID: String) -> Bool {
        update { approvals in
            if allowed { approvals.linkCommands.insert(commandID) } else { approvals.linkCommands.remove(commandID) }
        }
    }
}

/// While OpenRay is inert (tests, verification), files may be written only inside the
/// temporary folder. A normal launch writes wherever the person chose.
enum InertWrites {
    static func check(_ folder: URL, sideEffects: SideEffectGuard = .current, what: String) throws {
        // `effective`: an injected live rule can't make an inert process act.
        guard sideEffects.effective.isInert else { return }
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let target = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let root = temporary.hasSuffix("/") ? temporary : temporary + "/"
        if target != temporary, !target.hasPrefix(root) { try sideEffects.check(what) }
    }
}
