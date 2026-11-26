import AppKit

/// An app that can open a file, for Open With.
struct OpenWithApp: Equatable, Sendable {
    var url: URL
    var name: String
    var bundleID: String?
    var isDefault = false
}

/// A sharing service a file can go to.
struct ShareTarget: Equatable, Sendable {
    var id: String
    var title: String
    var symbol: String
}

/// The workspace calls behind the file actions, so tests run against a fake. The live one
/// checks `SideEffectGuard` before anything that changes the Mac or opens an app; reading
/// which apps can open a file is not an effect.
@MainActor
protocol FileWorkspace: AnyObject {
    func applications(toOpen url: URL) -> [OpenWithApp]
    func open(_ url: URL, with application: URL) async throws
    func openInTerminal(_ folder: URL, terminalBundleID: String) async throws
    func trash(_ url: URL) throws
    func shareTargets(for url: URL) -> [ShareTarget]
    func share(_ url: URL, via target: ShareTarget) throws
    /// Opens a folder, such as an app's Contents, in the Finder.
    func showFolder(_ folder: URL) throws
    /// Terminal apps installed on this Mac, Terminal first.
    func installedTerminals() -> [OpenWithApp]
}

enum FileWorkspaceError: LocalizedError, Equatable {
    case missingApp(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .missingApp(let name): "\(name) isn't installed."
        case .refused(let what): "Couldn't \(what)."
        }
    }
}

@MainActor
final class LiveFileWorkspace: FileWorkspace {
    private let sideEffects: SideEffectGuard
    /// Launch Services answers are cached briefly, since ⌘K's entries are rebuilt as the view updates.
    private var openWithCache: [String: (apps: [OpenWithApp], at: Date)] = [:]
    private var shareCache: [String: [ShareTarget]] = [:]

    /// Terminal apps OpenRay knows, by bundle id.
    static let terminalBundleIDs = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty", "co.zeit.hyper",
    ]

    init(sideEffects: SideEffectGuard = .current) {
        self.sideEffects = sideEffects
    }

    func applications(toOpen url: URL) -> [OpenWithApp] {
        if let cached = openWithCache[url.path], Date.now.timeIntervalSince(cached.at) < 30 { return cached.apps }
        let workspace = NSWorkspace.shared
        let preferred = workspace.urlForApplication(toOpen: url)?.standardizedFileURL
        var seen = Set<String>()
        let apps = workspace.urlsForApplications(toOpen: url).compactMap { app -> OpenWithApp? in
            let app = app.standardizedFileURL
            guard seen.insert(app.path).inserted else { return nil }
            return OpenWithApp(
                url: app, name: FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""),
                bundleID: Bundle(url: app)?.bundleIdentifier, isDefault: app == preferred)
        }
        .sorted { $0.isDefault != $1.isDefault ? $0.isDefault : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let limited = Array(apps.prefix(20))
        if openWithCache.count > 64 { openWithCache = [:] }
        openWithCache[url.path] = (limited, .now)
        return limited
    }

    func open(_ url: URL, with application: URL) async throws {
        try sideEffects.check("opening \(url.lastPathComponent)")
        _ = try await NSWorkspace.shared.open(
            [url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    func openInTerminal(_ folder: URL, terminalBundleID: String) async throws {
        try sideEffects.check("opening a terminal")
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID) else {
            throw FileWorkspaceError.missingApp("The chosen terminal")
        }
        _ = try await NSWorkspace.shared.open(
            [folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func trash(_ url: URL) throws {
        try sideEffects.check("moving \(url.lastPathComponent) to the Trash")
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func shareTargets(for url: URL) -> [ShareTarget] {
        if let cached = shareCache[url.path] { return cached }
        let candidates: [(NSSharingService.Name, String, String)] = [
            (.sendViaAirDrop, "AirDrop", "airplayaudio"),
            (.composeEmail, "Mail", "envelope"),
            (.composeMessage, "Messages", "message"),
        ]
        let targets = candidates.compactMap { name, title, symbol -> ShareTarget? in
            guard let service = NSSharingService(named: name), service.canPerform(withItems: [url]) else { return nil }
            return ShareTarget(id: name.rawValue, title: title, symbol: symbol)
        }
        if shareCache.count > 64 { shareCache = [:] }
        shareCache[url.path] = targets
        return targets
    }

    func share(_ url: URL, via target: ShareTarget) throws {
        try sideEffects.check("sharing \(url.lastPathComponent)")
        guard let service = NSSharingService(named: NSSharingService.Name(target.id)),
            service.canPerform(withItems: [url])
        else { throw FileWorkspaceError.refused("share with \(target.title)") }
        service.perform(withItems: [url])
    }

    func showFolder(_ folder: URL) throws {
        try sideEffects.check("opening \(folder.lastPathComponent) in the Finder")
        guard NSWorkspace.shared.open(folder) else { throw FileWorkspaceError.refused("open \(folder.lastPathComponent)") }
    }

    func installedTerminals() -> [OpenWithApp] {
        Self.terminalBundleIDs.compactMap { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { url in
                OpenWithApp(
                    url: url,
                    name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                    bundleID: bundleID)
            }
        }
    }
}

/// Files' actions and settings. Files' rows are the launcher's own `.file` rows, so this
/// provider offers no commands; it owns the workspace the file actions run through, and
/// `LauncherModel.fileActions(for:url:)` builds the entries.
@MainActor
final class FilesCommandProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(id: "files") { FilesCommandProvider() }

    var id: String { Self.registration.id }
    let workspace: any FileWorkspace

    init() {
        workspace = LiveFileWorkspace()
    }

    init(workspace: any FileWorkspace) {
        self.workspace = workspace
    }

    func commands(in model: LauncherModel) -> [CommandDescriptor] { [] }
}
