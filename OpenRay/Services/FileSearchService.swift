import Foundation
import Observation

struct FileSearchResult: Identifiable, Equatable, Sendable {
    var url: URL
    var modifiedAt: Date?
    var id: String { "file.\(url.path)" }
    var name: String { url.lastPathComponent }
}

/// Spotlight owns indexing; OpenRay only keeps the current bounded result set in memory.
@MainActor
@Observable
final class FileSearchService: NSObject {
    private struct Request: Equatable {
        let text: String
        let showRecent: Bool
    }

    private(set) var results: [FileSearchResult] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var metadataQuery: NSMetadataQuery?
    @ObservationIgnored private var pendingSearch: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lastRequest: Request?
    @ObservationIgnored private let queryFactory: @MainActor () -> NSMetadataQuery
    @ObservationIgnored private let debounce: Duration

    init(
        queryFactory: @escaping @MainActor () -> NSMetadataQuery = { NSMetadataQuery() },
        debounce: Duration = .milliseconds(180)
    ) {
        self.queryFactory = queryFactory
        self.debounce = debounce
        super.init()
    }

    func search(_ text: String, showRecent: Bool = false, preservingResults: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestKey = Request(text: text, showRecent: showRecent)
        let keepsResults = preservingResults && lastRequest == requestKey
        stop()
        // A resumed query can retain its selection while Spotlight refreshes.
        // Different queries and modes must never expose the previous matches.
        if !keepsResults { results = [] }
        lastRequest = requestKey
        errorMessage = nil
        guard text.count <= 512 else { return }
        guard text.count >= 2 || showRecent && text.isEmpty else { return }
        isSearching = true
        let request = UUID()
        generation = request
        let delay = debounce
        pendingSearch = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, self.generation == request else { return }
            self.startQuery(text)
        }
    }

    func waitForPendingSearch() async { await pendingSearch?.value }

    func stop() {
        pendingSearch?.cancel()
        pendingSearch = nil
        generation = UUID()
        if let metadataQuery {
            NotificationCenter.default.removeObserver(self, name: nil, object: metadataQuery)
            metadataQuery.stop()
        }
        metadataQuery = nil
        isSearching = false
    }

    private func startQuery(_ text: String) {
        let query = queryFactory()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        query.searchScopes = [home]
        var predicates = [
            NSPredicate(format: "NOT (%K BEGINSWITH %@)", NSMetadataItemPathKey, home + "/Library/"),
            NSPredicate(format: "NOT (%K BEGINSWITH %@)", NSMetadataItemFSNameKey, "."),
            NSPredicate(format: "%K != %@", NSMetadataItemContentTypeKey, "com.apple.application-bundle"),
        ]
        if !text.isEmpty {
            for term in text.split(whereSeparator: \.isWhitespace) {
                predicates.append(NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, String(term)))
            }
        }
        query.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        query.notificationBatchingInterval = 0.2
        metadataQuery = query
        NotificationCenter.default.addObserver(
            self, selector: #selector(didUpdate(_:)),
            name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didUpdate(_:)),
            name: .NSMetadataQueryDidUpdate, object: query)
        if !query.start() {
            results = []
            isSearching = false
            errorMessage = "Spotlight could not start. Check that indexing is enabled for your home folder."
        }
    }

    @objc private func didUpdate(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery, query === metadataQuery else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        var found: [FileSearchResult] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        for index in 0..<min(query.resultCount, 4_000) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            let url = URL(fileURLWithPath: path)
            guard FileSearchPolicy.accepts(url, home: home) else { continue }
            found.append(
                FileSearchResult(
                    url: url,
                    modifiedAt: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date))
            if found.count == 80 { break }
        }
        results = found
        isSearching = false
    }
}
