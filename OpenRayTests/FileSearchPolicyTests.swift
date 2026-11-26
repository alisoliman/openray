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

/// main #12's resume tests on the 2.0 service. It keeps the last rows while Spotlight gathers for
/// the same listing (scope, recent mode, content terms), and the launcher rescores them, so a
/// resumed search never empties and refills. Results are filtered off the main thread.
@MainActor
struct FileSearchResumeTests {
    private func service(_ queries: [StubFileMetadataQuery]) -> (FileSearchService, URL) {
        var queries = queries
        let home = FileManager.default.temporaryDirectory.appending(path: "OpenRayResume-\(UUID())")
        let service = FileSearchService(home: home, queryFactory: { queries.removeFirst() }, debounce: .zero)
        return (service, home)
    }

    @Test(arguments: [false, true])
    func resumingTheSameQueryKeepsResultsUntilSpotlightRefreshes(showRecent: Bool) async {
        let initial = StubFileMetadataQuery()
        let refresh = StubFileMetadataQuery()
        let (service, home) = service([initial, refresh])
        defer { service.stop() }
        service.search(showRecent ? "\n" : "  report\n", showRecent: showRecent)
        await service.waitForPendingSearch()
        initial.finish(with: ["report-one.txt", "report-two.txt"], in: home)
        await service.waitForResults()
        let previous = service.results
        #expect(previous.count == 2)

        // Hiding stops Spotlight; showing searches again without emptying the list.
        service.stop()
        service.search(showRecent ? "" : "report", showRecent: showRecent)
        #expect(service.results == previous)
        #expect(service.isSearching)
        await service.waitForPendingSearch()
        #expect(service.results == previous)

        refresh.finish(with: ["report-two.txt", "report-three.txt"], in: home)
        await service.waitForResults()
        #expect(service.results.map(\.name) == ["report-two.txt", "report-three.txt"])
        #expect(!service.isSearching)
    }

    @Test func changingRecentModeOrClearingTheQueryDropsTheRows() async {
        let metadata = StubFileMetadataQuery()
        let (service, home) = service([metadata, metadata, metadata])
        defer { service.stop() }
        // An empty query in Files lists recent files.
        service.search("", showRecent: true)
        await service.waitForPendingSearch()
        metadata.finish(with: ["report.txt"], in: home)
        await service.waitForResults()
        #expect(!service.results.isEmpty)
        // Name search rows would mislead under the recent listing's heading, and the reverse.
        service.search("report", showRecent: false)
        #expect(service.results.isEmpty)
        await service.waitForPendingSearch()
        metadata.finish(with: ["report.txt"], in: home)
        await service.waitForResults()
        #expect(!service.results.isEmpty)
        // Too short to search: nothing is shown.
        service.search("r")
        #expect(service.results.isEmpty)
    }

    @Test func replacedQueriesCannotOverwriteTheResumedResults() async {
        let initial = StubFileMetadataQuery()
        let refresh = StubFileMetadataQuery()
        let (service, home) = service([initial, refresh])
        defer { service.stop() }
        service.search("report")
        await service.waitForPendingSearch()
        initial.finish(with: ["report.txt"], in: home)
        await service.waitForResults()
        service.search("report")
        await service.waitForPendingSearch()

        initial.finish(with: ["old-result.txt"], in: home)
        await service.waitForResults()
        #expect(service.results.map(\.name) == ["report.txt"])
        refresh.finish(with: [], in: home)
        await service.waitForResults()
        #expect(service.results.isEmpty)
        #expect(!service.isSearching)
    }

    @Test func failedRefreshClearsStaleResultsAndExplainsRecovery() async {
        let initial = StubFileMetadataQuery()
        let refresh = StubFileMetadataQuery()
        refresh.canStart = false
        let (service, home) = service([initial, refresh])
        defer { service.stop() }
        service.search("report")
        await service.waitForPendingSearch()
        initial.finish(with: ["report.txt"], in: home)
        await service.waitForResults()
        service.search("report")
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

    func finish(with names: [String], in home: URL) {
        items = names.map { StubFileMetadataItem(fixtureURL: home.appendingPathComponent($0)) }
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
