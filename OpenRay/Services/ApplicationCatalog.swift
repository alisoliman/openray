import AppKit
import Observation

struct InstalledApplication: Identifiable, Equatable, Sendable {
    var name: String
    var url: URL
    var bundleIdentifier: String?
    var id: String { "app.\(bundleIdentifier ?? url.path)" }
}

@MainActor
@Observable
final class ApplicationCatalog {
    private(set) var applications: [InstalledApplication] = []
    private(set) var isLoading = false

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        applications = await Task.detached(priority: .userInitiated) { Self.scan() }.value
    }

    private nonisolated static func scan() -> [InstalledApplication] {
        let manager = FileManager.default
        let roots = [
            manager.homeDirectoryForCurrentUser.appending(path: "Applications"),
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
        ]
        var apps: [String: InstalledApplication] = [:]
        for root in roots {
            guard
                let enumerator = manager.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
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
        if manager.fileExists(atPath: finderURL.path) {
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
