import Foundation
import Testing

@testable import OpenRay

struct FileSearchPolicyTests {
    private let home = URL(fileURLWithPath: "/Users/tester")

    @Test(arguments: [
        "/Users/tester/Library/Application Support/calculator.js",
        "/Users/tester/Library", "/Users/tester/Dev/app/node_modules/calculator.js",
        "/Users/tester/Dev/app/.git/config", "/Users/tester/.ssh/config",
        "/Users/tester/Apps/Something.app/Contents/config.json",
        "/Users/tester/Dev/DerivedData/file.swift", "/Users/tester-other/Documents/note.txt",
        "/System/Library/file.txt", "/Users/tester/../other/file.txt",
    ])
    func excludesPrivateAndNoisyPathsEvenWhenSpotlightReturnsThem(_ path: String) {
        #expect(!FileSearchPolicy.accepts(URL(fileURLWithPath: path), home: home))
    }

    @Test(arguments: [
        "/Users/tester/Documents/Meeting notes.txt", "/Users/tester/Desktop/Invoice.pdf",
        "/Users/tester/Dev/OpenRay/Calculator.swift", "/Users/tester/Documents/Library book.txt",
    ])
    func permitsOrdinaryHomeFiles(_ path: String) {
        #expect(FileSearchPolicy.accepts(URL(fileURLWithPath: path), home: home))
    }
}

@MainActor
struct FileSearchResumeTests {
    @Test(arguments: [false, true])
    func resumingTheSameNormalizedQueryKeepsResultsUntilSpotlightRefreshes(showRecent: Bool) async {
        let initial = StubFileMetadataQuery()
        let refresh = StubFileMetadataQuery()
        var queries = [initial, refresh]
        let service = FileSearchService(queryFactory: { queries.removeFirst() }, debounce: .zero)
        defer { service.stop() }
        service.search(showRecent ? "\n" : "  report\n", showRecent: showRecent)
        await service.waitForPendingSearch()
        initial.finish(with: ["report-one.txt", "report-two.txt"])
        let previous = service.results
        #expect(previous.count == 2)

        service.stop()
        service.search(showRecent ? "" : "report", showRecent: showRecent, preservingResults: true)
        #expect(service.results == previous)
        #expect(service.isSearching)
        await service.waitForPendingSearch()
        #expect(service.results == previous)

        refresh.finish(with: ["report-two.txt", "report-three.txt"])
        #expect(service.results.map(\.name) == ["report-two.txt", "report-three.txt"])
        #expect(!service.isSearching)
    }

    @Test(arguments: ["different", "REPORT", "r", ""])
    func changingTheQueryClearsPreservedResultsImmediately(query: String) async {
        let metadata = StubFileMetadataQuery()
        let service = FileSearchService(queryFactory: { metadata }, debounce: .zero)
        defer { service.stop() }
        service.search("report")
        await service.waitForPendingSearch()
        metadata.finish(with: ["report.txt"])
        #expect(!service.results.isEmpty)

        service.search(query, preservingResults: true)
        #expect(service.results.isEmpty)
    }

    @Test func changingRecentModeOrRequestingOrdinarySearchClearsResults() async {
        let metadata = StubFileMetadataQuery()
        let service = FileSearchService(queryFactory: { metadata }, debounce: .zero)
        defer { service.stop() }
        service.search("report", showRecent: true)
        await service.waitForPendingSearch()
        metadata.finish(with: ["report.txt"])
        service.search("report", showRecent: false, preservingResults: true)
        #expect(service.results.isEmpty)
        await service.waitForPendingSearch()
        metadata.finish(with: ["report.txt"])
        service.search("report")
        #expect(service.results.isEmpty)
    }

    @Test func replacedQueriesCannotOverwriteTheResumedResults() async {
        let initial = StubFileMetadataQuery()
        let refresh = StubFileMetadataQuery()
        var queries = [initial, refresh]
        let service = FileSearchService(queryFactory: { queries.removeFirst() }, debounce: .zero)
        defer { service.stop() }
        service.search("report")
        await service.waitForPendingSearch()
        initial.finish(with: ["report.txt"])
        service.search("report", preservingResults: true)
        await service.waitForPendingSearch()

        initial.finish(with: ["old-result.txt"])
        #expect(service.results.map(\.name) == ["report.txt"])
        refresh.finish(with: [])
        #expect(service.results.isEmpty)
        #expect(!service.isSearching)
    }

    @Test func failedRefreshClearsStaleResultsAndExplainsRecovery() async {
        let initial = StubFileMetadataQuery()
        let refresh = StubFileMetadataQuery()
        refresh.canStart = false
        var queries = [initial, refresh]
        let service = FileSearchService(queryFactory: { queries.removeFirst() }, debounce: .zero)
        defer { service.stop() }
        service.search("report")
        await service.waitForPendingSearch()
        initial.finish(with: ["report.txt"])
        service.search("report", preservingResults: true)
        #expect(!service.results.isEmpty)
        await service.waitForPendingSearch()

        #expect(service.results.isEmpty)
        #expect(!service.isSearching)
        #expect(service.errorMessage?.contains("Spotlight could not start") == true)
    }
}

private final class StubFileMetadataQuery: NSMetadataQuery {
    var items: [NSMetadataItem] = []
    var canStart = true
    override var resultCount: Int { items.count }
    override func result(at index: Int) -> Any { items[index] }
    override func start() -> Bool { canStart }
    override func stop() {}
    override func disableUpdates() {}
    override func enableUpdates() {}

    func finish(with names: [String]) {
        items = names.map {
            StubFileMetadataItem(fixtureURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0))
        }
        NotificationCenter.default.post(name: .NSMetadataQueryDidFinishGathering, object: self)
    }
}

private final class StubFileMetadataItem: NSMetadataItem {
    let url: URL
    init(fixtureURL: URL) {
        self.url = fixtureURL
        super.init()
    }
    override func value(forAttribute key: String) -> Any? {
        key == NSMetadataItemPathKey ? url.path : nil
    }
}
