import Foundation

enum FileSearchPolicy {
    /// Spotlight doesn't reliably honor kMDItemPath predicates. Always enforce
    /// scope on returned URLs as well, including hidden ancestors and app bundles.
    static func accepts(_ url: URL, home: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        let root = home.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return false }
        let relative = String(path.dropFirst(root.count + 1))
        let components = relative.split(separator: "/")
        guard components.first != "Library" else { return false }
        return !components.contains { component in
            component.hasPrefix(".") || component == "node_modules" || component == "DerivedData"
                || component.hasSuffix(".app")
        }
    }
}
