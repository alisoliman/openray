import AppKit
import Foundation
import Testing

@testable import OpenRay

@MainActor
private final class RecordingOpener: QuicklinkOpening {
    var opened: [(URL, ResolvedApplication?)] = []
    func open(_ url: URL, with application: ResolvedApplication?) async throws { opened.append((url, application)) }
}

private struct FixedApplications: ApplicationResolving {
    var apps: [ResolvedApplication]
    func application(bundleIdentifier: String) -> ResolvedApplication? { apps.first { $0.bundleIdentifier == bundleIdentifier } }
    func application(named name: String) -> ResolvedApplication? { apps.first { $0.name == name } }
}

private struct FixedRecognizer: TextRecognizing {
    var text: String
    func recognizeText(in imageData: Data, options: TextRecognitionOptions) async throws -> TextRecognitionResult {
        TextRecognitionResult(lines: [RecognizedTextLine(text: text, confidence: 1, boundingBox: .zero)])
    }
    func recognizeText(inImageAt url: URL, options: TextRecognitionOptions) async throws -> TextRecognitionResult {
        try await recognizeText(in: Data(), options: options)
    }
    func barcodePayloads(in imageData: Data) async throws -> [String] { ["https://example.com/qr"] }
}

@MainActor
private final class FixedFiles: LibraryFileAccess {
    var importURL: URL?
    var exportURL: URL?
    func chooseImportFile(for kind: LibraryTransferKind) -> URL? { importURL }
    func chooseExportDestination(for kind: LibraryTransferKind) -> URL? { exportURL }
}

private let music = ResolvedApplication(
    bundleIdentifier: "com.apple.Music", name: "Music", url: URL(fileURLWithPath: "/System/Applications/Music.app"))

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "OpenRayClip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Models

struct SnippetQuicklinkModelTests {
    @Test func snippetsAcceptImportedKeywordsButNotEmojiOrBoundaries() throws {
        for keyword in ["@@", "!email", ";;addr", "€x", "x+y"] {
            try Snippet(name: "S", keyword: keyword, content: "Text").validate(against: [])
        }
        for keyword in ["x", "emoji😀", "has space", "(x", "q'uote"] {
            #expect(throws: LibraryValidationError.self) {
                try Snippet(name: "S", keyword: keyword, content: "Text").validate(against: [])
            }
        }
        try Snippet(name: "Long", keyword: "", content: String(repeating: "x", count: 65_000)).validate(against: [])
        #expect(throws: LibraryValidationError.self) {
            try Snippet(name: "Long", keyword: "", content: String(repeating: "x", count: 65_001)).validate(against: [])
        }
        #expect(throws: LibraryValidationError.self) {
            try Snippet(name: "Args", keyword: "", content: "{argument name=\"a\"}{argument name=\"b\"}{argument name=\"c\"}{argument name=\"d\"}")
                .validate(against: [])
        }
        // Code with braces is fine.
        try Snippet(name: "Code", keyword: "", content: "if x { date = 1 }").validate(against: [])
    }

    @Test func tagsAreOptionalAndRoundTrip() throws {
        var snippet = Snippet(name: "S", keyword: "", content: "x")
        snippet.tags = LibraryTags.normalized(" work, Email ,work,, ")
        #expect(snippet.tags == ["work", "Email"])
        let decoded = try JSONDecoder().decode(Snippet.self, from: JSONEncoder().encode(snippet))
        #expect(decoded == snippet)
        let old = try JSONDecoder().decode(Snippet.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"A","keyword":"","content":"B"}"#.utf8))
        #expect(old.tags == nil && old.tagList.isEmpty)
        #expect(throws: LibraryValidationError.self) { try LibraryTags.validate(Array(repeating: "t", count: 17)) }
    }

    @Test func snippetsRenderThroughTheEngine() {
        let date = Date(timeIntervalSince1970: 1_655_300_679)
        let snippet = Snippet(name: "S", keyword: "", content: "{date format=\"yyyy-MM-dd\"} {argument default=\"x\"} {unknown}")
        #expect(snippet.expanded(at: date, locale: Locale(identifier: "en_US"), timeZone: .gmt) == "2022-06-15 x {unknown}")
    }

    @Test func quicklinkArgumentsBecomeCollisionFreeSpecs() {
        let legacy = Quicklink(name: "Search", template: "https://example.com/?q={query}", keyword: "s")
        #expect(legacy.argumentSpecs == [.query])
        let link = Quicklink(
            name: "Repo",
            template: ##"https://github.com/{argument name="org" default="apple"}/{argument}/{argument name="#1" options="a, b"}"##,
            keyword: "")
        let specs = link.argumentSpecs
        #expect(specs.map(\.name) == ["org", "#1", "#=#1"])
        #expect(specs[0] == ArgumentSpec(name: "org", placeholder: "org", isOptional: true, defaultValue: "apple"))
        #expect(specs[1] == ArgumentSpec(name: "#1", placeholder: "Argument 1"))
        #expect(specs[2].type == .dropdown([.init(title: "a", value: "a"), .init(title: "b", value: "b")]))
        #expect(Set(specs.map(\.name)).count == specs.count)
        #expect(PlaceholderArgument.ID.snippetUnnamed(snippet: "Sig", index: 2).specName == "#2@Sig")
        // The three kinds never collide, even with names chosen to look alike.
        #expect(PlaceholderArgument.ID.named("#foo#1").specName != PlaceholderArgument.ID.snippetUnnamed(snippet: "#foo", index: 1).specName)
        #expect(PlaceholderArgument.ID.named("#1").specName != PlaceholderArgument.ID.unnamed(1).specName)
        #expect(PlaceholderArgument.ID.named("query").specName == "query")

        // ArgumentSpec.resolve output feeds the link directly.
        let typed = ["#1": "swift", "#=#1": "b"]
        let values = (try? ArgumentSpec.resolve(specs, typed: typed)) ?? [:]
        #expect(values == ["org": "apple", "#1": "swift", "#=#1": "b"])
        let url = try? link.resolution(arguments: values, values: PlaceholderValues()).url
        #expect(url?.absoluteString == "https://github.com/apple/swift/b")
    }

    @Test func dropdownDefaultsOutsideTheOptionsStayValid() throws {
        let link = Quicklink(name: "T", template: #"x://{argument name="tone" default="calm" options="happy, sad"}"#, keyword: "")
        let spec = try #require(link.argumentSpecs.first)
        try spec.validate(spec.value(from: nil))
    }

    @Test func singleTermPathFillsTheFirstArgument() throws {
        let link = Quicklink(name: "T", template: #"https://x.com/{argument name="q"}?lang={argument name="l" default="en"}"#, keyword: "t")
        #expect(try link.resolvedURL(query: "a b").absoluteString == "https://x.com/a%20b?lang=en")
        #expect(link.needsQuery)
        // Values go through ArgumentSpec rules: blank isn't a value, dropdowns need an option.
        #expect(throws: LibraryValidationError("Enter a search term for this quicklink.")) {
            try Quicklink(name: "S", template: "https://x.com/?q={query}", keyword: "").resolvedURL(query: "   ")
        }
        let choice = Quicklink(name: "C", template: #"x://{argument name="tone" options="happy, sad"}"#, keyword: "")
        #expect(throws: LibraryValidationError.self) { try choice.resolvedURL(query: "angry") }
        #expect(try choice.resolvedURL(query: "sad").absoluteString == "x://sad")
    }

    @Test func openWithAndTagsPersistAndOlderLinksDecode() throws {
        var link = Quicklink(name: "Hits", template: "https://music.apple.com", keyword: "")
        link.openWith = music.quicklinkApplication
        link.tags = ["music"]
        try link.validate()
        #expect(try JSONDecoder().decode(Quicklink.self, from: JSONEncoder().encode(link)) == link)
        let old = try JSONDecoder().decode(
            Quicklink.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"A","template":"https://a.com","keyword":""}"#.utf8))
        #expect(old.openWith == nil && old.tags == nil)
    }
}

// MARK: - Storage

@MainActor
struct ClipboardSideStorageTests {
    private let rtf = Data(#"{\rtf1 Bold}"#.utf8)

    @Test func formattingIsSavedBesideTheLibraryAndReloaded() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        store.update { $0.preferences.clipboardEnabled = true }
        var entry = ClipboardEntry(text: "Bold", sourceName: "F")
        entry.richText = ClipboardRichText(rtf: rtf)
        #expect(store.capture(entry))
        // Named by its digest, which is all library.json stores.
        let digest = try #require(store.database.clipboard.first?.richTextDigest)
        let side = directory.appending(path: "ClipboardImages/\(digest).rich")
        #expect(FileManager.default.fileExists(atPath: side.path))
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(json.contains(digest) && !json.contains("\"rich\""))

        let reloaded = LibraryStore(fileURL: url)
        #expect(reloaded.database.clipboard.first?.richText == ClipboardRichText(rtf: rtf))

        // Copying the same text again without formatting doesn't bring the old formatting back.
        #expect(reloaded.capture(ClipboardEntry(text: "Bold", sourceName: "F")))
        #expect(!FileManager.default.fileExists(atPath: side.path))
        #expect(LibraryStore(fileURL: url).database.clipboard.first?.richText == nil)

        // Deleting the entry removes its side file.
        var again = ClipboardEntry(text: "Bold", sourceName: "F")
        again.richText = ClipboardRichText(html: Data("<b>Bold</b>".utf8))
        #expect(reloaded.capture(again))
        let againDigest = try #require(reloaded.database.clipboard.first?.richTextDigest)
        let againSide = directory.appending(path: "ClipboardImages/\(againDigest).rich")
        #expect(FileManager.default.fileExists(atPath: againSide.path))
        #expect(reloaded.update { $0.clipboard = [] })
        #expect(!FileManager.default.fileExists(atPath: againSide.path))
    }

    @Test func recognizedTextIsSavedBesideTheImageAndSearchable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: url)
        store.update { $0.preferences.clipboardEnabled = true }
        let prepared = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        #expect(store.captureImage(prepared, sourceName: "Preview"))
        #expect(store.setRecognizedText("Invoice 42", forImage: prepared.image.id))
        #expect(!store.setRecognizedText("x", forImage: String(repeating: "0", count: 64)))
        #expect(store.database.clipboard.first?.searchableText.contains("Invoice 42") == true)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "ClipboardImages/\(prepared.image.id).txt").path))
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("Invoice 42"))

        let reloaded = LibraryStore(fileURL: url)
        #expect(reloaded.database.clipboard.first?.recognizedText == "Invoice 42")
        #expect(reloaded.update { $0.clipboard = [] })
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "ClipboardImages/\(prepared.image.id).txt").path))
    }

    @Test func capturedImagesAreRecognizedInTheBackground() async throws {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = LibraryStore(fileURL: nil)
        store.update { $0.preferences.clipboardEnabled = true }
        let service = ClipboardService(
            store: store, pasteboard: board,
            captureContext: { .init(sourceName: "Fixture", sourceBundleID: "test.fixture", secureInput: false) },
            textRecognizer: FixedRecognizer(text: "Receipt total"))
        ClipboardFixtures.writeImage(try ClipboardFixtures.image(), to: board)
        await service.poll()
        await service.pendingRecognition?.value
        let entry = try #require(store.database.clipboard.first)
        #expect(entry.recognizedText == "Receipt total")
        #expect(await service.barcodePayloads(of: entry) == ["https://example.com/qr"])
    }

    @Test func retentionPreferenceDrivesPruning() {
        let now = Date(timeIntervalSince1970: 50_000_000)
        let old = ClipboardEntry(text: "Old", copiedAt: now.addingTimeInterval(-40 * 86_400), sourceName: "F")
        let recent = ClipboardEntry(text: "Recent", copiedAt: now.addingTimeInterval(-10 * 86_400), sourceName: "F")
        func prune(_ change: (inout AppPreferences) -> Void) -> [String] {
            let store = LibraryStore(fileURL: nil)
            store.update {
                $0.preferences.clipboardEnabled = true
                change(&$0.preferences)
                $0.clipboard = [recent, old]
            }
            store.pruneClipboard(now: now)
            return store.database.clipboard.map(\.text)
        }
        #expect(prune { _ in } == [])  // the default stays 7 days
        #expect(prune { $0.clipboardRetentionDays = 14 } == ["Recent"])
        #expect(prune { $0.clipboardRetention = .thirtyDays } == ["Recent"])
        #expect(prune { $0.clipboardRetention = .unlimited } == ["Recent", "Old"])
        #expect(AppPreferences().clipboardRetention == nil && AppPreferences().clipboardRetentionDays == 7)
    }
}

// MARK: - Launcher

@MainActor
struct LauncherLibraryWiringTests {
    private func makeModel(files: FixedFiles = FixedFiles()) -> (LauncherModel, RecordingOpener) {
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(),
            registry: CommandRegistry(providers: [LibraryCommandProvider(files: files)]))
        let opener = RecordingOpener()
        model.quicklinkOpener = opener
        model.applicationResolver = FixedApplications(apps: [music])
        return (model, opener)
    }

    @Test func theProviderIsRegisteredAndItsCommandsAreBindable() {
        #expect(CommandProviders.all.contains { $0.id == LibraryCommandProvider.registration.id })
        #expect(CuratedCommand.supports("library.importSnippets"))
        #expect(!CuratedCommand.supports(LibraryCommandProvider.runPrefix + "quicklink." + UUID().uuidString))
        let (model, _) = makeModel()
        let ids = model.registry.commandItems(in: model).map(\.id)
        #expect(LibraryCommandProvider.Command.allCases.map(\.rawValue).allSatisfy(ids.contains))
    }

    @Test func snippetsCopyTheirRenderedTextWithTheCurrentClipboard() {
        let (model, _) = makeModel()
        model.store.update {
            $0.snippets = [
                Snippet(name: "Reply", keyword: "", content: "Re: {clipboard | uppercase} — {snippet name=\"Sig\"}"),
                Snippet(name: "Sig", keyword: "", content: "Ann"),
            ]
        }
        #expect(model.clipboard.copy("hello"))
        let item = LauncherItem(
            id: "snippet.x", title: "Reply", subtitle: "", symbol: "curlybraces", kind: .snippet, badge: "Snippet",
            action: .snippet(model.store.database.snippets[0]))
        model.perform(item)
        #expect(model.clipboard.readText() == "Re: HELLO — Ann")
    }

    @Test func snippetsWithAMissingRequiredArgumentAreNotCopied() throws {
        let (model, _) = makeModel()
        let snippet = Snippet(name: "Ask", keyword: "", content: "Dear {argument name=\"who\"}")
        model.store.update { $0.snippets = [snippet] }
        #expect(model.clipboard.copy("unchanged"))
        model.perform(
            LauncherItem(id: "snippet.\(snippet.id)", title: "Ask", subtitle: "", symbol: "curlybraces", kind: .snippet,
                badge: "Snippet", action: .snippet(snippet)))
        #expect(model.clipboard.readText() == "unchanged")
        // It runs as its command, whose argument fields ask for the value.
        let session = try #require(model.argumentSession)
        #expect(session.specs.map(\.name) == ["who"])
        model.setArgumentValue("Ann", at: 0)
        model.submitArguments()
        #expect(model.argumentSession == nil)
        #expect(model.clipboard.readText() == "Dear Ann")
        #expect(model.clipboard.copy("unchanged"))
        let command = model.registry.item(withID: LibraryCommandProvider.commandID(for: snippet, action: .copy), in: model)
        guard case .provided(var ref)? = command?.action, let command else {
            Issue.record("Expected the snippet's copy command")
            return
        }
        ref.arguments = ["who": "Ann"]
        model.registry.perform(command, ref: ref, in: model)
        #expect(model.clipboard.readText() == "Dear Ann")
    }

    @Test func quicklinksOpenWithTheirAppAndFreshValues() async throws {
        let (model, opener) = makeModel()
        var link = Quicklink(name: "Search", template: "https://x.com/?q={query}&c={clipboard}", keyword: "x")
        link.openWith = music.quicklinkApplication
        model.store.update { $0.quicklinks = [link] }
        #expect(model.clipboard.copy("copied text"))
        await model.openQuicklink(link, query: "a b")?.value
        #expect(opener.opened.map(\.0.absoluteString) == ["https://x.com/?q=a%20b&c=copied%20text"])
        #expect(opener.opened.first?.1 == music)
        #expect(model.store.database.usage.contains { $0.id == "quicklink.\(link.id)" })
        #expect(model.openerName(for: link) == "Music")
    }

    @Test func multiValueQuicklinksRunAsTheirCommand() async throws {
        let (model, opener) = makeModel()
        let link = Quicklink(name: "Repo", template: #"https://github.com/{argument name="org"}/{argument name="repo"}"#, keyword: "gh")
        model.store.update { $0.quicklinks = [link] }
        let command = try #require(model.quicklinkCommand(for: link))
        guard case .provided(var ref) = command.action else {
            Issue.record("Expected a provided row")
            return
        }
        #expect(model.registry.descriptor(for: ref, in: model)?.arguments.map(\.name) == ["org", "repo"])
        #expect(!model.registry.commandItems(in: model).contains { $0.id == command.id })

        // The built-in row's ↩ runs the command, whose argument fields ask for the values.
        model.perform(
            LauncherItem(id: "quicklink.\(link.id)", title: "Repo", subtitle: "", symbol: "link", kind: .quicklink,
                badge: "Quicklink", action: .quicklink(link, "")))
        #expect(model.argumentSession?.specs.map(\.name) == ["org", "repo"])
        #expect(opener.opened.isEmpty)
        model.cancelArguments()

        // Slice 1's fields fill ref.arguments and perform it.
        ref.arguments = ["org": "apple", "repo": "swift"]
        model.registry.perform(command, ref: ref, in: model)
        for _ in 0..<50 where opener.opened.isEmpty { await Task.yield() }
        #expect(opener.opened.map(\.0.absoluteString) == ["https://github.com/apple/swift"])
    }

    @Test func theDefaultOpenerIsInertInTests() async {
        let model = LauncherModel(store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: .withUniqueName())
        #expect(model.quicklinkOpener is InertQuicklinkOpener)
        await model.openQuicklink(Quicklink(name: "A", template: "https://example.com", keyword: ""), query: "")?.value
        #expect(model.feedback?.style == .error)
    }

    @Test func clipboardEntriesOfferPasteAsSaveAsSnippetAndImageText() throws {
        let (model, _) = makeModel()
        var rich = ClipboardEntry(text: "Bold", sourceName: "F")
        rich.richText = ClipboardRichText(rtf: Data("{\\rtf1 Bold}".utf8))
        let item = LauncherItem(id: "clipboard.\(rich.id)", title: "Bold", subtitle: "", symbol: "doc", kind: .clipboard, badge: "Text", action: .clipboard(rich))
        let actions = model.actions(for: item)
        let pasteAs = try #require(actions.first { $0.id == "pasteAs" })
        #expect(pasteAs.section == "Paste As")
        #expect(pasteAs.title == "Paste as Plain Text")
        #expect(pasteAs.children.map(\.id) == ["pasteAs.original", "pasteAs.plainText", "pasteAs.rtf"])
        pasteAs.perform()
        #expect(model.clipboard.readText() == "Bold")

        let save = try #require(actions.first { $0.id == "saveAsSnippet" })
        save.perform()
        guard case .snippet(let snippet)? = model.editor else {
            Issue.record("Save as Snippet should open the snippet editor")
            return
        }
        #expect(snippet.content == "Bold" && snippet.name == "Bold")

        let image = try ClipboardImageCodec.prepare(ClipboardFixtures.image()).image
        var picture = ClipboardEntry(content: .image(image), sourceName: "Preview")
        picture.recognizedText = "Total 12"
        let pictureItem = LauncherItem(
            id: "clipboard.\(picture.id)", title: "Image", subtitle: "", symbol: "photo", kind: .clipboard, badge: "Image",
            action: .clipboard(picture))
        let ids = model.actions(for: pictureItem).map(\.id)
        #expect(ids.contains("copyImageText") && ids.contains("copyQRCode") && !ids.contains("saveAsSnippet"))
        _ = model.copyRecognizedText(of: picture)
    }

    @Test func clipboardInRootSearchIsAPreference() {
        let (model, _) = makeModel()
        model.store.update {
            $0.preferences.clipboardEnabled = true
            $0.clipboard = [ClipboardEntry(text: "zebra crossing notes", sourceName: "F")]
        }
        model.query = "zebra crossing"
        #expect(!model.results.contains { $0.id.hasPrefix("clipboard.") })
        model.store.update { $0.preferences.clipboardInRootSearch = true }
        model.query = "zebra crossing "
        #expect(model.results.contains { $0.id.hasPrefix("clipboard.") })
    }

    @Test func tagsAreSearchable() {
        let (model, _) = makeModel()
        var snippet = Snippet(name: "Signature", keyword: "", content: "Ann")
        snippet.tags = ["quarterly"]
        var link = Quicklink(name: "Dashboard", template: "https://example.com", keyword: "")
        link.tags = ["quarterly"]
        model.store.update {
            $0.snippets = [snippet]
            $0.quicklinks = [link]
        }
        model.query = "quarterly"
        let ids = model.results.map(\.id)
        #expect(ids.contains("snippet.\(snippet.id)") && ids.contains("quicklink.\(link.id)"))
    }

    @Test func returnCopiesAndCommandReturnPastesByDefault() {
        let (model, _) = makeModel()
        #expect(model.contentPrimaryAction == .copy)
        let item = LauncherItem(
            id: "snippet.x", title: "S", subtitle: "", symbol: "curlybraces", kind: .snippet, badge: "Snippet",
            action: .snippet(Snippet(name: "S", keyword: "", content: "x")))
        #expect(model.primaryTitle(for: item) == "Copy")
        #expect(model.secondaryTitle(for: item)?.hasPrefix("Paste") == true)
    }

    @Test func importsPlanAgainstAliasesAndReportUnreadableEntries() throws {
        let (model, _) = makeModel()
        model.store.update {
            $0.quicklinks = [Quicklink(name: "Web", template: "https://a.com/?q={query}", keyword: "web")]
        }
        let json = Data(#"[{"name":"A","text":"one","keyword":";a"},{"name":"B","text":"two","keyword":"web"},{"name":"C"}]"#.utf8)
        let preview = try model.planImport(json, fileName: "s.json", kind: .snippets, policy: .dropKeyword)
        #expect(preview.summary == "2 added, 1 without keyword, 1 unreadable")
        #expect(model.importLibrary(json, fileName: "s.json", kind: .snippets))
        #expect(model.store.database.snippets.map(\.keyword) == [";a", ""])
        #expect(model.feedback?.text == "Imported snippets: 2 added, 1 without keyword, 1 unreadable")
        // Importing the same file again adds nothing.
        #expect(model.importLibrary(json, fileName: "s.json", kind: .snippets))
        #expect(model.store.database.snippets.count == 2)

        let links = Data(#"[{"name":"Hits","link":"https://music.apple.com","openWith":"Music"},{"name":"Bad","link":"javascript:alert(1)"}]"#.utf8)
        #expect(model.importLibrary(links, fileName: "q.json", kind: .quicklinks))
        let imported = try #require(model.store.database.quicklinks.first { $0.name == "Hits" })
        #expect(imported.openWith == music.quicklinkApplication)
        #expect(!model.store.database.quicklinks.contains { $0.name == "Bad" })
    }

    @Test func exportsRoundTripAndArchivesAreRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = FixedFiles()
        let (model, _) = makeModel(files: files)
        model.store.update { $0.snippets = [Snippet(name: "Sig", keyword: ";sig", content: "Ann")] }
        files.exportURL = directory.appending(path: "snippets.json")
        model.runExport(.snippets, files: files)
        let exported = try LibraryImport.snippets(from: Data(contentsOf: try #require(files.exportURL)))
        #expect(exported.items == [ImportedSnippet(name: "Sig", text: "Ann", keyword: ";sig")])

        files.importURL = directory.appending(path: "Backup.rayconfig")
        model.runImport(.snippets, files: files)
        #expect(model.feedback?.style == .error && model.feedback?.text == LibraryImportError.encryptedArchive.errorDescription)

        // The provider's commands use the same file access.
        let provider = LibraryCommandProvider(files: files)
        files.exportURL = directory.appending(path: "links.json")
        let command = try #require(model.registry.item(withID: "library.exportQuicklinks", in: model))
        if case .provided(let ref) = command.action { provider.perform(command, ref: ref, in: model) }
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "links.json").path))
    }

    @Test func expansionSettingsComeFromPreferences() {
        let store = LibraryStore(fileURL: nil)
        store.update {
            $0.preferences.snippetExpansionEnabled = true
            $0.preferences.snippetExpansion = SnippetExpansionSettings(mode: .afterDelimiterDiscarding)
            $0.snippets = [Snippet(name: "Hi", keyword: ";hi", content: "Hello")]
        }
        let expander = SnippetExpander(store: store, isSecureInputEnabled: { false })
        #expect(expander.handle(SnippetKeyInput(characters: ";hi", processID: 1, bundleIdentifier: "com.apple.TextEdit")) == nil)
        let outcome = expander.handle(SnippetKeyInput(characters: ".", processID: 1, bundleIdentifier: "com.apple.TextEdit"))
        guard case .failed(let plan, _)? = outcome else {
            Issue.record("Expected the inert inserter to refuse")
            return
        }
        #expect(plan.deleteCount == 4 && plan.text == "Hello")
    }

    @Test func theEditorSavesTagsAndOpenWith() {
        let (model, _) = makeModel()
        let draft = EditorDraft(editor: .quicklink(Quicklink(name: "", template: "", keyword: "")), store: model.store)
        draft.name = "Hits"
        draft.content = "https://music.apple.com/{argument name=\"station\" default=\"hits\"}"
        draft.tags = "music, radio"
        draft.openWith = music.quicklinkApplication
        #expect(draft.quicklinkPreview.valid)
        #expect(draft.save())
        let saved = model.store.database.quicklinks.first { $0.name == "Hits" }
        #expect(saved?.tags == ["music", "radio"] && saved?.openWith == music.quicklinkApplication)

        let snippet = EditorDraft(editor: .snippet(Snippet(name: "", keyword: "", content: "")), store: model.store)
        snippet.name = "Email"
        snippet.keyword = "@@"
        snippet.content = "a@b.com"
        #expect(snippet.keywordError == nil)
        #expect(snippet.save())
        snippet.tags = (0..<20).map { "t\($0)" }.joined(separator: ", ")
        #expect(snippet.tagsError != nil)
    }
}
