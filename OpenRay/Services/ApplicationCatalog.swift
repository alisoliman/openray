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
        let roots = standardRoots.map { ($0, Int.max) } + configuration.extraFolders.map { ($0, configuration.extraFolderDepth) }
        for (root, depth) in roots {
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

/// What Uninstall would move to the Trash: the app, and the files it keeps in `~/Library`,
/// matched by bundle id or exact app name. Shown for review before anything moves.
struct UninstallPlan: Equatable, Sendable {
    var app: InstalledApplication
    var supportFiles: [URL]

    /// Why an app can't be uninstalled from OpenRay, or nil when it can.
    static func refusal(for app: InstalledApplication, ownBundleID: String? = Bundle.main.bundleIdentifier) -> String? {
        let path = app.url.standardizedFileURL.path
        if path.hasPrefix("/System/") || app.bundleIdentifier?.hasPrefix("com.apple.") == true {
            return "\(app.name) is part of macOS and can't be uninstalled."
        }
        if let ownBundleID, app.bundleIdentifier == ownBundleID { return "OpenRay can't uninstall itself." }
        return nil
    }

    /// The support files that exist for an app under `library` (normally `~/Library`).
    static func supportFiles(
        bundleID: String?, appName: String, library: URL, fileManager: FileManager = .default
    ) -> [URL] {
        var candidates: [URL] = []
        func add(_ folder: String, _ name: String) {
            candidates.append(library.appending(path: folder).appending(path: name))
        }
        let name = appName.trimmingCharacters(in: .whitespaces)
        // A short or generic name could match another app's folder, so only real names count.
        let usesName = name.count >= 3 && !["Apple", "Google", "Microsoft", "Adobe"].contains(name)
        if let bundleID, !bundleID.isEmpty {
            for folder in ["Application Support", "Caches", "Containers", "Logs", "HTTPStorages", "WebKit",
                "Application Scripts"]
            {
                add(folder, bundleID)
            }
            add("Preferences", "\(bundleID).plist")
            add("Saved Application State", "\(bundleID).savedState")
            add("HTTPStorages", "\(bundleID).binarycookies")
            add("Cookies", "\(bundleID).binarycookies")
            add("LaunchAgents", "\(bundleID).plist")
            // Group containers are named with a team or "group." prefix before the bundle id.
            let groups = library.appending(path: "Group Containers")
            for entry in (try? fileManager.contentsOfDirectory(atPath: groups.path)) ?? []
            where entry == "group.\(bundleID)" || entry.hasSuffix(".\(bundleID)") {
                candidates.append(groups.appending(path: entry))
            }
            let byHost = library.appending(path: "Preferences/ByHost")
            for entry in (try? fileManager.contentsOfDirectory(atPath: byHost.path)) ?? []
            where entry.hasPrefix("\(bundleID).") && entry.hasSuffix(".plist") {
                candidates.append(byHost.appending(path: entry))
            }
        }
        if usesName {
            add("Application Support", name)
            add("Caches", name)
            add("Logs", name)
        }
        var seen = Set<String>()
        return candidates.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted && fileManager.fileExists(atPath: url.path)
        }
    }
}
