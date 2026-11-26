import Foundation
import Observation

struct FileSearchResult: Identifiable, Equatable, Sendable {
    var url: URL
    var modifiedAt: Date?
    /// A folder you can browse into. Packages such as apps and bundles count as files.
    var isDirectory = false
    /// Found by its contents rather than its name.
    var matchedContent = false
    var id: String { "file.\(url.path)" }
    var name: String { url.lastPathComponent }
}

/// Lists one folder for path browsing. The live reader uses FileManager; tests use fixtures.
protocol FolderReading: Sendable {
    func contents(of directory: URL, includingHidden: Bool, limit: Int) throws -> [FileSearchResult]
}

struct LiveFolderReader: FolderReading {
    /// While inert, only fixtures under the temporary folder are listed.
    var sideEffects = SideEffectGuard.current

    func contents(of directory: URL, includingHidden: Bool, limit: Int) throws -> [FileSearchResult] {
        try InertReadBoundary.check(directory, sideEffects: SideEffectGuard.atLeastCurrent(sideEffects))
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: includingHidden ? [] : [.skipsHiddenFiles])
        return urls.prefix(limit).map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FileSearchResult(
                url: url, modifiedAt: values?.contentModificationDate,
                isDirectory: values?.isDirectory == true && values?.isPackage != true)
        }
    }
}

/// Spotlight owns indexing; OpenRay only keeps the current bounded result set in memory.
/// A query that starts with `~/` or `/` lists that folder instead.
@MainActor
@Observable
final class FileSearchService: NSObject {
    private(set) var results: [FileSearchResult] = [] { didSet { orderedListing = nil } }
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    /// The folder the results list while the query is a path. Nil for Spotlight results.
    private(set) var browsedFolder: URL?
    /// Settings › Files, read at the start of each search.
    @ObservationIgnored var options: @MainActor () -> FileSearchOptions = { FileSearchOptions() }
    @ObservationIgnored let home: URL
    @ObservationIgnored private let folders: any FolderReading
    @ObservationIgnored private var metadataQuery: NSMetadataQuery?
    @ObservationIgnored private var pendingSearch: Task<Void, Never>?
    @ObservationIgnored private var filtering: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    /// What the current results list: a folder, and either recent files or a name search.
    @ObservationIgnored private var listing: Listing?
    @ObservationIgnored private var browsedAt: Date?
    /// The search the running Spotlight query answers, so results know why they matched.
    @ObservationIgnored private var activeQuery: (query: FileQuery, options: FileSearchOptions)?
    /// The browsed folder's rows for one filter and sort, kept until the results change.
    @ObservationIgnored private var orderedListing: (filter: String, sort: FileSortOrder, rows: [FileSearchResult])?

    /// Folders bigger than this list their first entries only.
    nonisolated static let folderLimit = 2_000

    private struct Listing: Equatable {
        var scope: FileSearchScope
        var recent: Bool
        var contentTerms: [String] = []
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, folders: any FolderReading = LiveFolderReader()) {
        self.home = home
        self.folders = folders
    }

    func search(_ text: String, showRecent: Bool = false, scope: FileSearchScope = .home) {
        if text.count <= 512, let path = FilePathQuery.parse(text, home: home) {
            browse(path.directory)
            return
        }
        stop()
        errorMessage = nil
        browsedFolder = nil
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 512, text.count >= 2 || showRecent && text.isEmpty else {
            if !results.isEmpty { results = [] }
            return
        }
        // Keep the last rows while Spotlight gathers. LauncherModel re-scores them
        // against the new query, so the list doesn't empty and refill on each
        // keystroke. Rows from another folder, or from a name search shown as the
        // recent listing, would mislead, so those clear.
        // Rows found by other contents would sit under the new search's heading, so they clear too.
        let listing = Listing(scope: scope, recent: text.isEmpty, contentTerms: FileQuery.parse(text).contentTerms)
        if listing != self.listing, !results.isEmpty { results = [] }
        self.listing = listing
        isSearching = true
        let request = UUID()
        generation = request
        pendingSearch = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, !Task.isCancelled, self.generation == request else { return }
            // Files asks with `showRecent`; root search matches names only, so its Top Hit stays a name match.
            self.startQuery(text, scope: scope, matchingContent: showRecent)
        }
    }

    func stop() {
        pendingSearch?.cancel()
        pendingSearch = nil
        filtering?.cancel()
        filtering = nil
        generation = UUID()
        if let metadataQuery {
            NotificationCenter.default.removeObserver(self, name: nil, object: metadataQuery)
            metadataQuery.stop()
        }
        metadataQuery = nil
        activeQuery = nil
        isSearching = false
    }

    // MARK: Path browsing

    /// The browsed folder's entries for a filter and sort. The view asks several times per
    /// keystroke, so the answer is kept until the listing or the filter changes.
    func orderedListing(filter: String, sort: FileSortOrder) -> [FileSearchResult] {
        if let cached = orderedListing, cached.filter == filter, cached.sort == sort { return cached.rows }
        let rows = FilePathQuery.ordered(results, filter: filter, sort: sort)
        orderedListing = (filter, sort, rows)
        return rows
    }

    /// Makes the next search list the browsed folder again, after a setting it depends on changed.
    func invalidateListing() {
        browsedAt = nil
        if browsedFolder != nil { generation = UUID() }
        if browsedFolder != nil { isSearching = false }
    }

    /// Lists a folder, once per folder: typing a filter after the slash narrows the same
    /// listing in the model, so only a new folder (or a stale listing) reads the disk again.
    private func browse(_ directory: URL) {
        let fresh = browsedAt.map { Date.now.timeIntervalSince($0) < 3 } ?? false
        if browsedFolder == directory, isSearching || fresh { return }
        stop()
        errorMessage = nil
        if browsedFolder != directory, !results.isEmpty { results = [] }
        browsedFolder = directory
        listing = nil
        isSearching = true
        let request = UUID()
        generation = request
        let includingHidden = options().includesHiddenFiles
        let folders = self.folders
        let limit = Self.folderLimit
        pendingSearch = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try folders.contents(of: directory, includingHidden: includingHidden, limit: limit) }
            }.value
            guard let self, !Task.isCancelled, self.generation == request else { return }
            switch outcome {
            case .success(let entries):
                self.results = entries
                self.errorMessage = nil
            case .failure(let error):
                self.results = []
                self.errorMessage =
                    (error as? SideEffectGuard.Blocked)?.errorDescription
                    ?? (FileManager.default.fileExists(atPath: directory.path)
                    ? "OpenRay can't read “\(directory.lastPathComponent)”. Check Full Disk Access in Settings."
                    : "There's no folder at \(directory.path).")
            }
            self.browsedAt = .now
            self.isSearching = false
        }
    }

    // MARK: Spotlight

    private func startQuery(_ text: String, scope: FileSearchScope, matchingContent: Bool) {
        var options = self.options()
        options.matchesContent = options.matchesContent && matchingContent
        let parsed = FileQuery.parse(text)
        let query = NSMetadataQuery()
        query.searchScopes =
            scope == .home ? FileSearchPolicy.searchRoots(home: home, options: options).map(\.path) : [scope.url.path]
        let library = home.path + "/Library/"
        var predicates: [NSPredicate] = [
            NSPredicate(format: "%K != %@", NSMetadataItemContentTypeKey, "com.apple.application-bundle")
        ]
        // A scope chosen inside Library, such as iCloud Drive, keeps its results.
        if !options.extraScopes.contains(where: { $0.path.hasPrefix(library) }) {
            predicates.append(NSPredicate(format: "NOT (%K BEGINSWITH %@)", NSMetadataItemPathKey, library))
        }
        if !options.includesHiddenFiles {
            predicates.append(NSPredicate(format: "NOT (%K BEGINSWITH %@)", NSMetadataItemFSNameKey, "."))
        }
        for term in parsed.nameTerms {
            let name = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, term)
            if options.matchesContent, let content = Self.contentPredicate(term) {
                predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: [name, content]))
            } else {
                predicates.append(name)
            }
        }
        predicates += parsed.contentTerms.compactMap(Self.contentPredicate)
        query.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        query.notificationBatchingInterval = 0.2
        metadataQuery = query
        activeQuery = (parsed, options)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didUpdate(_:)),
            name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didUpdate(_:)),
            name: .NSMetadataQueryDidUpdate, object: query)
        if !query.start() {
            isSearching = false
            results = []
            errorMessage = "Spotlight could not start. Check that indexing is enabled for your home folder."
        }
    }

    /// Spotlight's text-content match, written in its own query syntax so wildcards stay literal.
    nonisolated static func contentPredicate(_ term: String) -> NSPredicate? {
        let escaped = Self.escapedForSpotlight(term)
        guard !escaped.isEmpty else { return nil }
        return NSPredicate(fromMetadataQueryString: "kMDItemTextContent == \"*\(escaped)*\"cd")
    }

    nonisolated static func escapedForSpotlight(_ term: String) -> String {
        var escaped = ""
        for character in term {
            if "\\\"*?".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    @objc private func didUpdate(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery, query === metadataQuery, let activeQuery
        else { return }
        let (parsed, options) = activeQuery
        query.disableUpdates()
        var candidates: [(path: String, modifiedAt: Date?)] = []
        for index in 0..<min(query.resultCount, 4_000) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            candidates.append((path, item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date))
        }
        query.enableUpdates()
        // Checking each path's folders and ignore files touches the disk, so it runs off the main thread.
        let request = generation
        let home = self.home
        let snapshot = candidates
        filtering?.cancel()
        filtering = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                Self.accepted(snapshot, query: parsed, options: options, home: home, limit: 80)
            }.value
            guard let self, !Task.isCancelled, self.generation == request else { return }
            self.results = found
            self.isSearching = false
        }
    }

    /// The candidates Settings › Files allows, up to `limit`, marked when only their contents matched.
    nonisolated static func accepted(
        _ candidates: [(path: String, modifiedAt: Date?)], query: FileQuery, options: FileSearchOptions, home: URL,
        limit: Int, ignoreFiles: IgnoreFileReading? = nil
    ) -> [FileSearchResult] {
        let reader = ignoreFiles ?? IgnoreFileReader()
        var found: [FileSearchResult] = []
        for candidate in candidates {
            if Task.isCancelled { break }
            let url = URL(fileURLWithPath: candidate.path)
            guard FileSearchPolicy.accepts(url, home: home, options: options, ignoreFiles: reader) else { continue }
            let name = url.lastPathComponent
            let nameMatches = query.nameTerms.allSatisfy {
                name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            var isFolder = false
            if url.hasDirectoryPath {
                isFolder = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
            }
            found.append(
                FileSearchResult(
                    url: url, modifiedAt: candidate.modifiedAt, isDirectory: isFolder,
                    matchedContent: query.hasFilters || !nameMatches))
            if found.count == limit { break }
        }
        return found
    }
}
