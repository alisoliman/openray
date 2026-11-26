import AppKit
import Observation

struct InstalledApplication: Identifiable, Equatable, Sendable {
    var name: String
    var url: URL
    var bundleIdentifier: String?
    var id: String { "app.\(bundleIdentifier ?? url.path)" }
}

/// Settings › Applications, kept in `commandPreferences[ApplicationSettings.key]`.
struct ApplicationSettings: Equatable, Sendable {
    static let key = "settings.applications"
    /// Auto Quit's choices, in minutes.
    static let autoQuitChoices = [1, 3, 5, 10, 15]

    /// Folders searched for apps beyond the standard ones.
    var extraFolders: [String] = []
    /// Look up to three levels inside the extra folders, for apps kept in nested subfolders.
    var deepSearch = false
    /// Item ids (`app.<bundle id>`) kept out of search.
    var hiddenAppIDs: [String] = []
    /// Apps Auto Quit quits once idle, by bundle id. Nil minutes follow the default.
    var autoQuit: [String: Int?] = [:]
    var autoQuitDefaultMinutes = 3
    /// Bundle ids Hide All and Quit All never touch.
    var keepRunningBundleIDs: [String] = []

    init() {}

    init(_ values: [String: String]?) {
        let values = values ?? [:]
        extraFolders = PreferenceValues.list(values["folders"])
        deepSearch = PreferenceValues.flag(values["deepSearch"], default: false)
        hiddenAppIDs = PreferenceValues.list(values["hidden"])
        keepRunningBundleIDs = PreferenceValues.list(values["keepRunning"])
        if let minutes = values["autoQuitMinutes"].flatMap(Int.init), Self.autoQuitChoices.contains(minutes) {
            autoQuitDefaultMinutes = minutes
        }
        for line in PreferenceValues.list(values["autoQuit"]) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard let bundleID = parts.first, !bundleID.isEmpty else { continue }
            let minutes = parts.count == 2 ? Int(parts[1]).flatMap { Self.autoQuitChoices.contains($0) ? $0 : nil } : nil
            autoQuit[bundleID] = .some(minutes)
        }
    }

    var values: [String: String] {
        var values: [String: String] = [:]
        values["folders"] = PreferenceValues.string(extraFolders)
        if deepSearch { values["deepSearch"] = "true" }
        values["hidden"] = PreferenceValues.string(hiddenAppIDs)
        values["keepRunning"] = PreferenceValues.string(keepRunningBundleIDs)
        if autoQuitDefaultMinutes != 3 { values["autoQuitMinutes"] = String(autoQuitDefaultMinutes) }
        values["autoQuit"] = PreferenceValues.string(
            autoQuit.keys.sorted().map { bundleID in
                (autoQuit[bundleID] ?? nil).map { "\(bundleID)=\($0)" } ?? bundleID
            })
        return values
    }

    /// The idle minutes before Auto Quit quits an app, or nil when it's off for that app.
    func autoQuitMinutes(for bundleID: String) -> Int? {
        guard let entry = autoQuit[bundleID] else { return nil }
        return entry ?? autoQuitDefaultMinutes
    }

    var scanConfiguration: ApplicationScanConfiguration {
        ApplicationScanConfiguration(
            extraFolders: extraFolders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) },
            deepSearch: deepSearch)
    }
}

/// Where the catalog looks for apps.
struct ApplicationScanConfiguration: Equatable, Sendable {
    var extraFolders: [URL] = []
    var deepSearch = false

    /// How far inside an extra folder apps are found: directly inside, or three levels with Deep Search.
    var extraFolderDepth: Int { deepSearch ? 3 : 1 }

    static var standardRoots: [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications"),
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
        ]
    }
}

@MainActor
@Observable
final class ApplicationCatalog {
    private(set) var applications: [InstalledApplication] = []
    private(set) var isLoading = false
    /// Settings › Applications' folders, read at the start of each scan.
    @ObservationIgnored var configuration: @MainActor () -> ApplicationScanConfiguration = { .init() }
    /// The folders always searched, all the way down. Tests replace them with fixtures.
    @ObservationIgnored var standardRoots = ApplicationScanConfiguration.standardRoots
    @ObservationIgnored var includesFinder = true
    /// A refresh asked for while one runs, such as after adding a folder, scans again when it ends.
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Scans the app folders. A call while a scan runs waits for a fresh scan, not the stale one.
    func refresh() async {
        if let refreshTask {
            refreshAgain = true
            await refreshTask.value
            return
        }
        let task = Task {
            isLoading = true
            repeat {
                refreshAgain = false
                let configuration = configuration()
                let roots = standardRoots
                let finder = includesFinder
                applications = await Task.detached(priority: .userInitiated) {
                    Self.scan(configuration, standardRoots: roots, includesFinder: finder)
                }.value
            } while refreshAgain
            isLoading = false
            // Cleared in the same turn as the last check, so a later call starts a new scan.
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    nonisolated static func scan(
        _ configuration: ApplicationScanConfiguration, standardRoots: [URL], includesFinder: Bool = true
    ) -> [InstalledApplication] {
        let manager = FileManager.default
        var apps: [String: InstalledApplication] = [:]
        // Standard folders are searched all the way down; extra folders as deep as configured.
        // Extra folders can hold anything, so only real app bundles count there.
        let roots =
            standardRoots.map { ($0, Int.max, false) }
            + configuration.extraFolders.map { ($0, configuration.extraFolderDepth, true) }
        for (root, depth, requiresBundle) in roots {
            guard
                let enumerator = manager.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else {
                    if enumerator.level >= depth { enumerator.skipDescendants() }
                    continue
                }
                if requiresBundle, !ApplicationBundle.isValid(url) { continue }
                let bundle = Bundle(url: url)
                guard bundle?.bundleIdentifier != Bundle.main.bundleIdentifier else { continue }
                let name =
                    (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let app = InstalledApplication(name: name, url: url, bundleIdentifier: bundle?.bundleIdentifier)
                if apps[app.id] == nil { apps[app.id] = app }
            }
        }
        // Finder lives outside the standard Applications directories.
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        if includesFinder, manager.fileExists(atPath: finderURL.path) {
            let finder = InstalledApplication(name: "Finder", url: finderURL, bundleIdentifier: "com.apple.finder")
            apps[finder.id] = finder
        }
        return apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class FileIconCache {
    static let shared = FileIconCache()
    private let cache = NSCache<NSURL, NSImage>()

    init() { cache.countLimit = 200 }

    func icon(for url: URL) -> NSImage {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// Whether a folder is a real application bundle: an `APPL` Info.plist with a bundle id and an
/// executable that exists. A plain folder named `Archive.app` isn't one.
enum ApplicationBundle {
    nonisolated static func isValid(_ url: URL) -> Bool {
        guard let bundle = Bundle(url: url), let info = bundle.infoDictionary, !info.isEmpty,
            let identifier = bundle.bundleIdentifier, !identifier.isEmpty
        else { return false }
        if let type = info["CFBundlePackageType"] as? String, type != "APPL" { return false }
        guard let executable = bundle.executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executable.path)
    }
}

/// What Uninstall would move to the Trash: the app, and the files it keeps in `~/Library` that
/// provably belong to it alone. Each is reviewed and ticked by hand before anything moves.
struct UninstallPlan: Equatable, Sendable {
    var app: InstalledApplication
    var supportFiles: [URL]
    /// Why support files aren't offered, such as another installed copy that shares them.
    var supportFilesNote: String?

    /// Why an app can't be uninstalled from OpenRay, or nil when it can.
    static func refusal(for app: InstalledApplication, ownBundleID: String? = Bundle.main.bundleIdentifier) -> String? {
        let path = app.url.standardizedFileURL.path
        if path.hasPrefix("/System/") || app.bundleIdentifier?.hasPrefix("com.apple.") == true {
            return "\(app.name) is part of macOS and can't be uninstalled."
        }
        if let ownBundleID, app.bundleIdentifier == ownBundleID { return "OpenRay can't uninstall itself." }
        guard ApplicationBundle.isValid(app.url) else {
            return "“\(app.url.lastPathComponent)” isn't an app bundle OpenRay can uninstall."
        }
        return nil
    }

    /// A bundle id safe to use as a file name: reverse-DNS letters, digits, dots and hyphens.
    static func isPlainBundleID(_ id: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return id.count <= 255 && id.contains(".") && !id.hasPrefix(".") && !id.hasSuffix(".") && !id.contains("..")
            && id.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
    }

    /// The support files that exist for an app under `library` (normally `~/Library`), named by
    /// its bundle id. Folders named only by the app's name, and group containers that other apps
    /// can share, are never offered: their owner can't be proven. Every candidate must sit
    /// directly in its Library folder once symlinks are resolved.
    static func supportFiles(bundleID: String?, library: URL, fileManager: FileManager = .default) -> [URL] {
        guard let bundleID, isPlainBundleID(bundleID) else { return [] }
        let names: [(folder: String, name: String)] = [
            ("Application Support", bundleID), ("Caches", bundleID), ("Containers", bundleID),
            ("Logs", bundleID), ("HTTPStorages", bundleID), ("HTTPStorages", "\(bundleID).binarycookies"),
            ("WebKit", bundleID), ("Application Scripts", bundleID), ("Preferences", "\(bundleID).plist"),
            ("Saved Application State", "\(bundleID).savedState"), ("Cookies", "\(bundleID).binarycookies"),
            ("LaunchAgents", "\(bundleID).plist"),
        ]
        var candidates = names.map { library.appending(path: $0.folder).appending(path: $0.name) }
        let byHost = library.appending(path: "Preferences/ByHost")
        for entry in (try? fileManager.contentsOfDirectory(atPath: byHost.path)) ?? []
        where entry.hasPrefix("\(bundleID).") && entry.hasSuffix(".plist")
            && !entry.dropFirst(bundleID.count + 1).dropLast(6).contains(".")
        {
            candidates.append(byHost.appending(path: entry))
        }
        let root = library.standardizedFileURL.resolvingSymlinksInPath().path
        var seen = Set<String>()
        return candidates.filter { url in
            guard seen.insert(url.standardizedFileURL.path).inserted, FileIdentity.of(url) != nil else { return false }
            // The folder it sits in must really be inside Library, whatever symlinks say.
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            return parent.hasPrefix(root + "/")
        }
    }

    /// The plan for an app. When another copy with the same bundle id is installed, the
    /// support files are shared with it, so none are offered.
    static func make(for app: InstalledApplication, library: URL, otherCopies: [URL]) -> UninstallPlan {
        let path = app.url.standardizedFileURL.resolvingSymlinksInPath().path
        let others = otherCopies.filter { $0.standardizedFileURL.resolvingSymlinksInPath().path != path }
        if !others.isEmpty {
            return UninstallPlan(
                app: app, supportFiles: [],
                supportFilesNote: "Another copy of \(app.name) is installed, so its support files stay.")
        }
        return UninstallPlan(app: app, supportFiles: supportFiles(bundleID: app.bundleIdentifier, library: library))
    }
}
