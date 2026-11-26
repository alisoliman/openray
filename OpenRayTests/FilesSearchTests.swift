import AppKit
import Foundation
import Testing

@testable import OpenRay

/// Records every file action instead of performing it.
@MainActor
final class FakeFileWorkspace: FileWorkspace {
    var openWith: [OpenWithApp] = [
        OpenWithApp(url: URL(fileURLWithPath: "/Applications/TextEdit.app"), name: "TextEdit", isDefault: true),
        OpenWithApp(url: URL(fileURLWithPath: "/Applications/Xcode.app"), name: "Xcode"),
    ]
    var targets = [
        ShareTarget(id: "com.apple.share.AirDrop.send", title: "AirDrop", symbol: "airplayaudio"),
        ShareTarget(id: "com.apple.share.Mail.compose", title: "Mail", symbol: "envelope"),
    ]
    var terminals: [OpenWithApp] = []
    private(set) var opened: [(file: URL, app: URL)] = []
    private(set) var terminalFolders: [(folder: URL, terminal: String)] = []
    private(set) var trashed: [URL] = []
    private(set) var shared: [(file: URL, target: String)] = []
    private(set) var shownFolders: [URL] = []
    var trashFailures: Set<String> = []

    func applications(toOpen url: URL) -> [OpenWithApp] { openWith }

    func open(_ url: URL, with application: URL) async throws { opened.append((url, application)) }

    func openInTerminal(_ folder: URL, terminalBundleID: String) async throws {
        terminalFolders.append((folder, terminalBundleID))
    }

    func trash(_ url: URL) throws {
        if trashFailures.contains(url.lastPathComponent) { throw FileWorkspaceError.refused("trash") }
        trashed.append(url)
    }

    func shareTargets(for url: URL) -> [ShareTarget] { targets }

    func share(_ url: URL, via target: ShareTarget) throws { shared.append((url, target.id)) }

    func showFolder(_ folder: URL) throws { shownFolders.append(folder) }

    func installedTerminals() -> [OpenWithApp] { terminals }
}

/// Lists a fixed folder and counts how often it was asked.
final class CountingFolderReader: FolderReading, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: [FileSearchResult]]
    private var _calls: [URL] = []

    init(_ entries: [String: [FileSearchResult]]) { self.entries = entries }

    var calls: [URL] { lock.withLock { _calls } }

    func contents(of directory: URL, includingHidden: Bool, limit: Int) throws -> [FileSearchResult] {
        try lock.withLock {
            _calls.append(directory)
            guard let found = entries[directory.path] else { throw CocoaError(.fileReadNoSuchFile) }
            return found.filter { includingHidden || !$0.name.hasPrefix(".") }
        }
    }
}

/// Ignore rules for fixture folders, keyed by path.
struct FixedIgnoreFiles: IgnoreFileReading {
    var rules: [String: String]
    func patterns(inFolder folder: URL) -> [IgnorePattern] { IgnorePattern.parse(rules[folder.path] ?? "") }
}

@MainActor
func waitFor(_ condition: () -> Bool, timeout: Int = 600) async throws {
    for _ in 0..<timeout {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for a condition")
}

@MainActor
struct FilesSearchTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    private func model(
        _ providers: [any CommandProvider] = [FilesCommandProvider(workspace: FakeFileWorkspace())],
        pasteboard: NSPasteboard = .withUniqueName()
    ) -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: pasteboard,
            registry: CommandRegistry(providers: providers))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayFiles-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.standardizedFileURL
    }

    // MARK: Path browsing

    @Test func pathQueriesParseHomeAndAbsolutePaths() {
        let documents = FilePathQuery.parse("~/Documents/rep", home: home)
        #expect(documents?.directory.path == "/Users/tester/Documents")
        #expect(documents?.filter == "rep")
        #expect(FilePathQuery.parse("~/", home: home)?.directory.path == "/Users/tester")
        #expect(FilePathQuery.parse("~/", home: home)?.filter == "")
        #expect(FilePathQuery.parse("/", home: home)?.directory.path == "/")
        #expect(FilePathQuery.parse("/Volumes/Data/", home: home)?.directory.path == "/Volumes/Data")
        #expect(FilePathQuery.parse("/Volumes/Data/My Fi", home: home)?.filter == "My Fi")
        #expect(FilePathQuery.parse("~/Documents/../Desktop/", home: home)?.directory.path == "/Users/tester/Desktop")
        for text in ["report", "~", "~tester/", " ~/Documents", "a/b"] {
            #expect(FilePathQuery.parse(text, home: home) == nil)
        }
    }

    @Test func pathNavigationEntersFoldersAndGoesUp() throws {
        let documents = URL(fileURLWithPath: "/Users/tester/Documents", isDirectory: true)
        #expect(FilePathQuery.text(for: home, home: home) == "~/")
        #expect(FilePathQuery.text(for: documents, home: home) == "~/Documents/")
        #expect(FilePathQuery.text(for: URL(fileURLWithPath: "/Volumes"), home: home) == "/Volumes/")
        #expect(FilePathQuery.text(for: URL(fileURLWithPath: "/"), home: home) == "/")
        // Tab: a folder opens its listing, a file completes its name.
        #expect(FilePathQuery.completion(for: documents.appending(path: "Taxes"), isFolder: true, home: home) == "~/Documents/Taxes/")
        #expect(FilePathQuery.completion(for: documents.appending(path: "a.txt"), isFolder: false, home: home) == "~/Documents/a.txt")
        // ⇧Tab: up one folder, through Home and on to the root.
        let query = try #require(FilePathQuery.parse("~/Documents/Taxes/", home: home))
        #expect(query.parentText(home: home) == "~/Documents/")
        #expect(FilePathQuery.parse("~/", home: home)?.parentText(home: home) == "/Users/")
        #expect(FilePathQuery.parse("/Users/", home: home)?.parentText(home: home) == "/")
        #expect(FilePathQuery.parse("/", home: home)?.parentText(home: home) == nil)
        #expect(FilePathQuery.parse("~/Documents/Ta", home: home)?.folderText(home: home) == "~/Documents/")
    }

    @Test func listingsPutFoldersFirstAndFollowTheSortOrder() {
        let folder = URL(fileURLWithPath: "/tmp/listing")
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let entries = [
            FileSearchResult(url: folder.appending(path: "zeta.txt"), modifiedAt: new),
            FileSearchResult(url: folder.appending(path: "Reports"), modifiedAt: old, isDirectory: true),
            FileSearchResult(url: folder.appending(path: "alpha.txt"), modifiedAt: old),
            FileSearchResult(url: folder.appending(path: "report.pdf"), modifiedAt: new),
        ]
        #expect(FilePathQuery.ordered(entries, filter: "", sort: .relevance).map(\.name) == ["Reports", "alpha.txt", "report.pdf", "zeta.txt"])
        #expect(FilePathQuery.ordered(entries, filter: "", sort: .name).map(\.name) == ["alpha.txt", "report.pdf", "Reports", "zeta.txt"])
        #expect(FilePathQuery.ordered(entries, filter: "", sort: .dateModified).map(\.name).prefix(2) == ["report.pdf", "zeta.txt"])
        #expect(FilePathQuery.ordered(entries, filter: "rep", sort: .relevance).map(\.name) == ["Reports", "report.pdf"])
    }

    @Test func browsingListsAFolderOnceAndFiltersTheSameListing() async throws {
        let documents = home.appending(path: "Documents")
        let projects = home.appending(path: "Projects")
        let reader = CountingFolderReader([
            documents.path: [
                FileSearchResult(url: documents.appending(path: "report.pdf")),
                FileSearchResult(url: documents.appending(path: ".hidden")),
            ],
            projects.path: [FileSearchResult(url: projects.appending(path: "OpenRay"), isDirectory: true)],
        ])
        let service = FileSearchService(home: home, folders: reader)
        service.search("~/Documents/")
        try await waitFor { !service.isSearching }
        #expect(service.browsedFolder?.path == documents.path)
        #expect(service.results.map(\.name) == ["report.pdf"])
        // Typing a filter after the slash narrows the same listing; the disk isn't read again.
        service.search("~/Documents/rep")
        service.search("~/Documents/repo")
        #expect(reader.calls.count == 1)
        service.search("~/Projects/")
        try await waitFor { !service.isSearching }
        #expect(service.results.map(\.name) == ["OpenRay"])
        #expect(reader.calls.count == 2)
        // Showing hidden files lists the folder again.
        service.options = { FileSearchOptions(includesHiddenFiles: true) }
        service.invalidateListing()
        service.search("~/Documents/")
        try await waitFor { !service.isSearching && service.browsedFolder?.path == documents.path }
        #expect(Set(service.results.map(\.name)) == ["report.pdf", ".hidden"])
        // A folder that can't be read says so.
        service.search("~/Missing/")
        try await waitFor { !service.isSearching }
        #expect(service.results.isEmpty)
        #expect(service.errorMessage?.contains("/Users/tester/Missing") == true)
        // A name search leaves browsing.
        service.search("report")
        #expect(service.browsedFolder == nil)
        service.stop()
    }

    @Test func typingAPathBrowsesFoldersWithTabAndShiftTab() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let taxes = root.appending(path: "Taxes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: taxes, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appending(path: "report.txt"))
        try Data("b".utf8).write(to: taxes.appending(path: "2026.pdf"))
        let model = model()
        let rootText = root.path + "/"

        model.query = rootText
        try await waitFor { model.files.browsedFolder?.path == root.path && !model.files.isSearching }
        let rows = model.orderedResults
        // The folder itself comes first (↩ opens it in the Finder), then its contents, folders first.
        #expect(rows.map(\.title) == [root.lastPathComponent, "Taxes", "report.txt"])
        #expect(model.groups.first?.title == rootText)
        #expect(model.groups.first?.id == "files.path")

        // Tab enters the selected folder.
        model.selectedID = rows[1].id
        model.handleTab()
        #expect(model.query == taxes.path + "/")
        try await waitFor { model.files.browsedFolder?.path == taxes.path && !model.files.isSearching }
        #expect(model.orderedResults.map(\.title) == ["Taxes", "2026.pdf"])

        // ⇧Tab goes back up, and the folder action panel offers it.
        #expect(model.actions(for: model.selectedItem).contains { $0.id == "files.parent" && $0.modifiers == .shift })
        #expect(model.browseEnclosingFolder())
        #expect(model.query == rootText)
        try await waitFor { model.files.browsedFolder?.path == root.path && !model.files.isSearching }

        // A partial name filters the listing; Tab on a file completes its name.
        model.query = rootText + "rep"
        #expect(model.orderedResults.map(\.title) == ["report.txt"])
        model.handleTab()
        #expect(model.query == rootText + "report.txt")
        // With a partial name, ⇧Tab clears it first.
        #expect(model.browseEnclosingFolder())
        #expect(model.query == rootText)
        model.files.stop()
    }

    @Test func pathBrowsingWorksInTheFilesScopeToo() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Inbox"), withIntermediateDirectories: true)
        let model = model()
        model.navigate(to: .files)
        model.query = root.path + "/"
        try await waitFor { model.files.browsedFolder?.path == root.path && !model.files.isSearching }
        #expect(model.orderedResults.map(\.title) == [root.lastPathComponent, "Inbox"])
        model.files.stop()
    }

    // MARK: Ignore patterns

    @Test func globsMatchNamesLikeAShell() {
        #expect(Glob.matches("*.log", "server.log"))
        #expect(!Glob.matches("*.log", "server.log.txt"))
        #expect(Glob.matches("build", "build"))
        #expect(!Glob.matches("build", "builder"))
        #expect(Glob.matches("file?.txt", "file1.txt"))
        #expect(!Glob.matches("file?.txt", "file10.txt"))
        #expect(Glob.matches("[abc]*", "beta"))
        #expect(!Glob.matches("[abc]*", "delta"))
        #expect(Glob.matches("[!a]*", "beta"))
        #expect(!Glob.matches("[!a]*", "alpha"))
        #expect(Glob.matches("v[0-9]", "v7"))
        #expect(Glob.matches("\\*literal", "*literal"))
        #expect(!Glob.matches("\\*literal", "xliteral"))
        #expect(Glob.matches("*", ""))
        #expect(Glob.matches("[", "["))
    }

    @Test func ignoreLinesFollowGitignoreSyntax() throws {
        #expect(IgnorePattern(line: "") == nil)
        #expect(IgnorePattern(line: "# comment") == nil)
        let negated = try #require(IgnorePattern(line: "!keep.log"))
        #expect(negated.negated && !negated.anchored)
        let folder = try #require(IgnorePattern(line: "cache/"))
        #expect(folder.directoryOnly && !folder.anchored)
        #expect(folder.matches(["src", "cache"], isDirectory: true))
        #expect(!folder.matches(["src", "cache"], isDirectory: false))
        let anchored = try #require(IgnorePattern(line: "/dist"))
        #expect(anchored.anchored)
        #expect(anchored.matches(["dist"], isDirectory: true))
        #expect(!anchored.matches(["app", "dist"], isDirectory: true))
        let middle = try #require(IgnorePattern(line: "docs/*.md"))
        #expect(middle.anchored)
        #expect(middle.matches(["docs", "a.md"], isDirectory: false))
        #expect(!middle.matches(["src", "docs", "a.md"], isDirectory: false))
        let deep = try #require(IgnorePattern(line: "a/**/b"))
        #expect(deep.matches(["a", "b"], isDirectory: false))
        #expect(deep.matches(["a", "x", "y", "b"], isDirectory: false))
        #expect(!deep.matches(["c", "b"], isDirectory: false))
        let anyDepth = try #require(IgnorePattern(line: "**/logs"))
        #expect(anyDepth.matches(["x", "y", "logs"], isDirectory: true))
        #expect(IgnorePattern(line: "#hash") == nil)
        #expect(IgnorePattern(line: "\\#hash")?.components == ["#hash"])
        #expect(IgnorePattern(line: "trailing   ")?.components == ["trailing"])
    }

    @Test func globalPatternsMatchAtAnyDepthUnlessAnchored() throws {
        let build = try #require(IgnorePattern(line: "build/**", global: true))
        #expect(build.matches(["Dev", "app", "build"], isDirectory: true))
        #expect(build.matches(["build", "out.o"], isDirectory: false))
        let rooted = try #require(IgnorePattern(line: "/scratch", global: true))
        #expect(rooted.matches(["scratch"], isDirectory: true))
        #expect(!rooted.matches(["Dev", "scratch"], isDirectory: true))
        #expect(FilesSettings.patterns("*.log, build/**\n tmp ,,") == ["*.log", "build/**", "tmp"])
    }

    @Test func lastMatchingRuleWinsAndIgnoredFoldersStayIgnored() {
        let rules = [IgnoreRuleSet(base: [], patterns: IgnorePattern.parse("*.log\n!keep.log\nvendor/\n!vendor/lib.swift"))]
        #expect(IgnoreRuleSet.isIgnored(["server.log"], isDirectory: false, by: rules))
        #expect(!IgnoreRuleSet.isIgnored(["keep.log"], isDirectory: false, by: rules))
        // Nothing inside an ignored folder comes back, as in git.
        #expect(IgnoreRuleSet.isIgnored(["vendor", "lib.swift"], isDirectory: false, by: rules))
        #expect(!IgnoreRuleSet.isIgnored(["src", "main.swift"], isDirectory: false, by: rules))
        // A nested file's rules apply below its folder only.
        let nested = [IgnoreRuleSet(base: ["app"], patterns: IgnorePattern.parse("/generated"))]
        #expect(IgnoreRuleSet.isIgnored(["app", "generated", "a.swift"], isDirectory: false, by: nested))
        #expect(!IgnoreRuleSet.isIgnored(["generated", "a.swift"], isDirectory: false, by: nested))
    }

    @Test func policyAppliesHiddenFilesExclusionsScopesAndIgnoreFiles() {
        func accepts(_ path: String, _ options: FileSearchOptions = FileSearchOptions(), ignore: IgnoreFileReading? = nil) -> Bool {
            FileSearchPolicy.accepts(URL(fileURLWithPath: path), home: home, options: options, ignoreFiles: ignore)
        }
        #expect(!accepts("/Users/tester/.config/app.toml"))
        #expect(accepts("/Users/tester/.config/app.toml", FileSearchOptions(includesHiddenFiles: true)))
        // .git and the Trash stay out even with hidden files on.
        #expect(!accepts("/Users/tester/Dev/app/.git/config", FileSearchOptions(includesHiddenFiles: true)))
        #expect(!accepts("/Users/tester/.Trash/old.txt", FileSearchOptions(includesHiddenFiles: true)))
        // Excluded paths, and everything inside them.
        let excluded = FileSearchOptions(excludedPaths: ["/Users/tester/Archive"])
        #expect(!accepts("/Users/tester/Archive", excluded))
        #expect(!accepts("/Users/tester/Archive/2019/a.pdf", excluded))
        #expect(accepts("/Users/tester/Archive-new/a.pdf", excluded))
        // A scope inside Library (iCloud Drive) and one outside Home are searched.
        let icloud = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs")
        let drive = URL(fileURLWithPath: "/Volumes/Work")
        let scoped = FileSearchOptions(extraScopes: [icloud, drive])
        #expect(!accepts("/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/a.pages"))
        #expect(accepts("/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/a.pages", scoped))
        #expect(!accepts("/Users/tester/Library/Caches/a.txt", scoped))
        #expect(accepts("/Volumes/Work/plan.key", scoped))
        #expect(!accepts("/Volumes/Other/plan.key", scoped))
        #expect(
            FileSearchPolicy.searchRoots(home: home, options: scoped).map(\.path)
                == ["/Users/tester", "/Volumes/Work"])
        // Global patterns.
        let patterns = FileSearchOptions(ignorePatterns: ["*.log", "build/**"])
        #expect(!accepts("/Users/tester/Dev/server.log", patterns))
        #expect(!accepts("/Users/tester/Dev/app/build/out.o", patterns))
        #expect(accepts("/Users/tester/Dev/app/src/main.swift", patterns))
        // Ignore files, read per folder, and the switch that turns them off.
        let ignore = FixedIgnoreFiles(rules: ["/Users/tester/Dev/app": "dist/\n*.tmp\n!important.tmp"])
        #expect(!accepts("/Users/tester/Dev/app/dist/bundle.js", ignore: ignore))
        #expect(!accepts("/Users/tester/Dev/app/src/x.tmp", ignore: ignore))
        #expect(accepts("/Users/tester/Dev/app/src/important.tmp", ignore: ignore))
        #expect(accepts("/Users/tester/Dev/other/dist/bundle.js", ignore: ignore))
        #expect(accepts("/Users/tester/Dev/app/dist/bundle.js", FileSearchOptions(usesIgnoreFiles: false), ignore: ignore))
    }

    @Test func ignoreFilesAreReadFromDisk() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("secrets/\n".utf8).write(to: project.appending(path: ".gitignore"))
        try Data("*.bak\n".utf8).write(to: project.appending(path: ".openrayignore"))
        let reader = IgnoreFileReader()
        let options = FileSearchOptions()
        #expect(!FileSearchPolicy.accepts(project.appending(path: "secrets/key.pem"), home: root, options: options, ignoreFiles: reader))
        #expect(!FileSearchPolicy.accepts(project.appending(path: "notes.bak"), home: root, options: options, ignoreFiles: reader))
        #expect(FileSearchPolicy.accepts(project.appending(path: "notes.txt"), home: root, options: options, ignoreFiles: reader))
    }

    // MARK: Content search

    @Test func contentFiltersParseFromTheQuery() {
        #expect(FileQuery.parse("report content:revenue") == FileQuery(nameTerms: ["report"], contentTerms: ["revenue"]))
        #expect(FileQuery.parse("content:\"net revenue\" q1") == FileQuery(nameTerms: ["q1"], contentTerms: ["net revenue"]))
        #expect(FileQuery.parse("Content:Total").contentTerms == ["Total"])
        #expect(FileQuery.parse("content:").isEmpty)
        #expect(FileQuery.parse("http://example.com notes:x").nameTerms == ["http://example.com", "notes:x"])
        #expect(FileQuery.parse("content:x").hasFilters)
        #expect(!FileQuery.parse("plain words").hasFilters)
        #expect(FileSearchService.escapedForSpotlight("a*b\"c\\d?") == "a\\*b\\\"c\\\\d\\?")
        #expect(FileSearchService.contentPredicate("revenue") != nil)
        #expect(FileSearchService.contentPredicate("") == nil)
    }

    @Test func contentMatchesRankBelowNameMatchesAndSortsApply() {
        let folder = URL(fileURLWithPath: "/Users/tester/Documents")
        let results = [
            FileSearchResult(url: folder.appending(path: "budget.xlsx"), modifiedAt: Date(timeIntervalSince1970: 3), matchedContent: true),
            FileSearchResult(url: folder.appending(path: "Revenue 2026.numbers"), modifiedAt: Date(timeIntervalSince1970: 1)),
            FileSearchResult(url: folder.appending(path: "archive.txt"), modifiedAt: Date(timeIntervalSince1970: 2)),
        ]
        let query = FileQuery.parse("revenue")
        #expect(LauncherModel.rankedFileResults(results, query: query, sort: .relevance).map(\.name) == ["Revenue 2026.numbers", "budget.xlsx"])
        #expect(LauncherModel.rankedFileResults(results, query: query, sort: .dateModified).map(\.name) == ["budget.xlsx", "Revenue 2026.numbers"])
        #expect(LauncherModel.rankedFileResults(results, query: FileQuery(), sort: .name).map(\.name) == ["archive.txt", "budget.xlsx", "Revenue 2026.numbers"])
    }

    @Test func spotlightCandidatesAreFilteredAndMarked() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidates: [(path: String, modifiedAt: Date?)] = [
            (root.appending(path: "Notes/revenue.txt").path, nil),
            (root.appending(path: "Notes/budget.txt").path, nil),
            (root.appending(path: ".cache/revenue.txt").path, nil),
            (root.appending(path: "Library/revenue.txt").path, nil),
            (root.appending(path: "Notes/more.txt").path, nil),
        ]
        let found = FileSearchService.accepted(
            candidates, query: FileQuery.parse("revenue"), options: FileSearchOptions(matchesContent: true), home: root,
            limit: 2, ignoreFiles: FixedIgnoreFiles(rules: [:]))
        #expect(found.map(\.name) == ["revenue.txt", "budget.txt"])
        #expect(found.map(\.matchedContent) == [false, true])
        let contentOnly = FileSearchService.accepted(
            candidates, query: FileQuery.parse("content:revenue"), options: FileSearchOptions(), home: root, limit: 10,
            ignoreFiles: FixedIgnoreFiles(rules: [:]))
        #expect(contentOnly.allSatisfy { $0.matchedContent })
    }

    @Test func aContentSearchInEverythingShowsOnlyFiles() {
        let model = model()
        model.query = "content:quarterly"
        #expect(model.fileSearchRows != nil)
        #expect(model.results.allSatisfy { if case .file = $0.action { true } else { false } })
        model.query = "quarterly"
        #expect(model.fileSearchRows == nil)
        model.files.stop()
    }

    // MARK: Actions

    @Test func fileRowsOfferOpenWithShareTerminalTrashAndMore() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "plan.txt")
        try Data("x".utf8).write(to: file)
        let workspace = FakeFileWorkspace()
        let model = model([FilesCommandProvider(workspace: workspace)])
        let item = model.fileRow(FileSearchResult(url: file))
        let entries = model.actions(for: item)
        let ids = entries.map(\.id)
        for id in ["openWith", "share", "sendToAI", "saveQuicklink", "excludeFile", "trash", "quickLook", "reveal", "copyPath"] {
            #expect(ids.contains(id))
        }
        // Folders only.
        #expect(!ids.contains("terminal"))
        let openWith = try #require(entries.first { $0.id == "openWith" })
        #expect(openWith.children.map(\.title) == ["TextEdit (Default)", "Xcode"])
        openWith.children[1].perform()
        try await waitFor { !workspace.opened.isEmpty }
        #expect(workspace.opened.first?.app.lastPathComponent == "Xcode.app")
        let share = try #require(entries.first { $0.id == "share" })
        share.children[1].perform()
        #expect(workspace.shared.map(\.target) == ["com.apple.share.Mail.compose"])
        let trash = try #require(entries.first { $0.id == "trash" })
        #expect(trash.modifiers == .command && trash.isDestructive)

        // Move to Trash asks first, and only ↩ moves it.
        trash.perform()
        #expect(workspace.trashed.isEmpty)
        guard case .provided(let question)? = model.confirmation else {
            Issue.record("Move to Trash didn't ask")
            return
        }
        #expect(question.confirmTitle == "Move to Trash")
        model.performSelected()
        #expect(workspace.trashed == [file])
        #expect(model.feedback?.style == .success)

        // A folder can open in the terminal chosen in Settings.
        let folder = root.appending(path: "Code", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.updateFilesSettings { $0.terminalBundleID = "com.googlecode.iterm2" }
        let folderEntries = model.actions(for: model.fileRow(FileSearchResult(url: folder, isDirectory: true)))
        try #require(folderEntries.first { $0.id == "terminal" }).perform()
        try await waitFor { !workspace.terminalFolders.isEmpty }
        #expect(workspace.terminalFolders.first?.terminal == "com.googlecode.iterm2")
    }

    @Test func aFailedTrashSaysWhy() throws {
        let workspace = FakeFileWorkspace()
        workspace.trashFailures = ["locked.txt"]
        let model = model([FilesCommandProvider(workspace: workspace)])
        model.askToTrash(URL(fileURLWithPath: "/tmp/locked.txt"), workspace: workspace)
        model.performSelected()
        #expect(model.feedback?.style == .error)
        #expect(workspace.trashed.isEmpty)
    }

    @Test func excludeSortHiddenQuicklinkAndAIActionsWork() throws {
        let model = model()
        let file = URL(fileURLWithPath: "/Users/tester/Archive/old.pdf")
        model.excludeFromFileSearch(file)
        #expect(model.filesSettings.excludedPaths == ["/Users/tester/Archive/old.pdf"])

        model.navigate(to: .files)
        let sort = try #require(model.actions(for: nil).first { $0.id == "files.sort" })
        #expect(sort.title == "Sort by Date Modified")
        sort.perform()
        #expect(model.filesSettings.sort == .dateModified)
        try #require(model.actions(for: nil).first { $0.id == "files.hidden" }).perform()
        #expect(model.filesSettings.includesHiddenFiles)

        model.saveFileAsQuicklink(file)
        guard case .quicklink(let link)? = model.editor else {
            Issue.record("Save as Quicklink didn't open the editor")
            return
        }
        #expect(link.name == "old")
        #expect(link.template == file.path)
        model.closeEditor(force: true)

        model.sendFileToAI(file)
        #expect(model.destination == .ai)
        #expect(model.ai.draft.contains("old.pdf"))
        model.files.stop()
    }

    @Test func filesSettingsRoundTripThroughCommandPreferences() {
        var settings = FilesSettings()
        #expect(settings.values.isEmpty)
        settings.includesHiddenFiles = true
        settings.usesIgnoreFiles = false
        settings.ignorePatterns = ["*.log", "build/**"]
        settings.excludedPaths = ["/a", "/b"]
        settings.extraScopes = ["~/Drive"]
        settings.matchesContent = true
        settings.sort = .name
        settings.terminalBundleID = "com.mitchellh.ghostty"
        #expect(FilesSettings(settings.values) == settings)
        #expect(settings.options.extraScopes.first?.path.hasSuffix("/Drive") == true)
        #expect(FileSortOrder.name.next == .relevance)

        let model = model()
        model.updateFilesSettings { $0.sort = .name }
        #expect(model.store.database.commandPreferences[FilesSettings.key]?["sort"] == "name")
        #expect(model.files.options().sort == .name)
    }
}
