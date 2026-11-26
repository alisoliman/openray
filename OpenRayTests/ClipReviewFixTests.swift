import AppKit
import Foundation
import Testing

@testable import OpenRay

@MainActor
private final class Opener: QuicklinkOpening {
    var opened: [(URL, ResolvedApplication?)] = []
    func open(_ url: URL, with application: ResolvedApplication?) async throws { opened.append((url, application)) }
}

private struct NoApplications: ApplicationResolving {
    func application(bundleIdentifier: String) -> ResolvedApplication? { nil }
    func application(named name: String) -> ResolvedApplication? { nil }
}

@MainActor
private final class Files: LibraryFileAccess {
    var importURL: URL?
    var exportURL: URL?
    func chooseImportFile(for kind: LibraryTransferKind) -> URL? { importURL }
    func chooseExportDestination(for kind: LibraryTransferKind) -> URL? { exportURL }
}

private final class Reads: PlaceholderDataSource, @unchecked Sendable {
    var log: [String] = []
    func clipboardText(offset: Int) -> String? {
        log.append("clipboard")
        return "secret"
    }
    func selectedText() -> String? {
        log.append("selection")
        return "secret"
    }
    func makeUUID() -> UUID {
        log.append("uuid")
        return UUID()
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "OpenRayClipFix-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
private func makeModel(store: LibraryStore = LibraryStore(fileURL: nil), files: Files = Files()) -> (LauncherModel, Opener) {
    let model = LauncherModel(
        store: store, ai: AIChatModel(engine: TestAIEngine()), pasteboard: NSPasteboard.withUniqueName(),
        registry: CommandRegistry(providers: [LibraryCommandProvider(files: files)]))
    let opener = Opener()
    model.quicklinkOpener = opener
    model.applicationResolver = NoApplications()
    return (model, opener)
}

// MARK: - Data loss

@MainActor
struct ClipDataLossTests {
    /// B3: neither export can replace the library, by any path that leads to it.
    @Test func exportsNeverReplaceTheLibrary() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: library)
        #expect(store.update { $0.snippets = [Snippet(name: "Sig", keyword: ";sig", content: "Ann")] })
        let original = try Data(contentsOf: library)
        let files = Files()
        let (model, _) = makeModel(store: store, files: files)

        let symlink = directory.appending(path: "alias.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: library)
        let hardLink = directory.appending(path: "hard.json")
        try FileManager.default.linkItem(at: library, to: hardLink)
        let destinations = [
            library, symlink, hardLink, directory.appending(path: "LIBRARY.JSON"),
            directory.appending(path: "sub/../library.json"), directory.appending(path: "ClipboardImages/export.json"),
        ]
        for kind in LibraryTransferKind.allCases {
            for destination in destinations {
                files.exportURL = destination
                model.runExport(kind, files: files)
                #expect(model.feedback?.style == .error, "\(kind) → \(destination.path)")
                #expect(try Data(contentsOf: library) == original)
            }
        }
        #expect(LibraryStore(fileURL: library).database.snippets.map(\.name) == ["Sig"])

        files.exportURL = directory.appending(path: "export.json")
        model.runExport(.snippets, files: files)
        #expect(model.feedback?.style == .success)
        #expect(try Data(contentsOf: library) == original)
    }

    /// M7: a library written before dynamic placeholders loads, saves as v5, and keeps its text.
    @Test func librariesFromBeforeDynamicPlaceholdersLoadAndKeepTheirText() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appending(path: "library.json")
        let content = #"{argument}{argument}{argument}{argument} {clipboard} \{snippet name="x"} {date} {uuid | uppercase}"#
        var old = LibraryDatabase()
        old.snippets = [Snippet(name: "Example", keyword: ";ex", content: content)]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["schemaVersion"] = 4
        json["snippets"] = (json["snippets"] as? [[String: Any]])?.map { snippet in
            var snippet = snippet
            snippet.removeValue(forKey: "placeholderVersion")
            return snippet
        }
        try JSONSerialization.data(withJSONObject: json).write(to: library)

        let store = LibraryStore(fileURL: library)
        #expect(!store.isReadOnly)
        let snippet = try #require(store.database.snippets.first)
        let date = Date(timeIntervalSince1970: 0)
        let expected = content.replacingOccurrences(of: "{date}", with: {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.timeZone = .gmt
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        }())
        #expect(snippet.expanded(at: date, locale: Locale(identifier: "en_US"), timeZone: .gmt) == expected)

        // Nothing private is substituted when it's copied from the launcher.
        let (model, _) = makeModel(store: store)
        #expect(model.clipboard.copy("private"))
        model.copyContent(
            LauncherItem(id: "snippet.\(snippet.id)", title: "Example", subtitle: "", symbol: "curlybraces", kind: .snippet,
                badge: "Snippet", action: .snippet(snippet)))
        #expect(model.clipboard.readText()?.contains("private") == false)
        #expect(model.clipboard.readText()?.contains("{clipboard}") == true)

        // It saves as v5 with the migrated text, which doesn't migrate twice.
        #expect(store.update { $0.preferences.rememberLastQuery = false })
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: library)) as? [String: Any])
        #expect(saved["schemaVersion"] as? Int == LibraryDatabase.currentSchemaVersion)
        let reloaded = LibraryStore(fileURL: library)
        #expect(reloaded.database.snippets.first?.content == snippet.content)
        #expect(reloaded.database.snippets.first?.expanded(at: date, locale: Locale(identifier: "en_US"), timeZone: .gmt) == expected)
    }

    /// M6: inline formatting moves to a side file on load and survives unrelated saves.
    @Test func inlineFormattingMigratesWithoutLoss() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appending(path: "library.json")
        var database = LibraryDatabase()
        database.preferences.clipboardEnabled = true
        var entry = ClipboardEntry(text: "Bold", sourceName: "F")
        entry.richText = ClipboardRichText(rtf: Data("{\\rtf1 Bold}".utf8))
        database.clipboard = [entry]
        try JSONEncoder().encode(database).write(to: library)

        let store = LibraryStore(fileURL: library)
        let digest = try #require(store.database.clipboard.first?.richTextDigest)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "ClipboardImages/\(digest).rich").path))
        #expect(store.update { $0.preferences.rememberLastQuery = false })
        #expect(LibraryStore(fileURL: library).database.clipboard.first?.richText == entry.richText)
    }

    /// M6: when the side file can't be written, the formatting stays inline instead.
    @Test func formattingStaysInlineWhenItsFileCantBeWritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appending(path: "library.json")
        // A file where the folder should be makes every side write fail.
        try Data("x".utf8).write(to: directory.appending(path: "ClipboardImages"))
        let store = LibraryStore(fileURL: library)
        store.update { $0.preferences.clipboardEnabled = true }
        var entry = ClipboardEntry(text: "Bold", sourceName: "F")
        entry.richText = ClipboardRichText(html: Data("<b>Bold</b>".utf8))
        #expect(store.capture(entry))
        #expect(store.database.clipboard.first?.richTextDigest == nil)
        #expect(store.update { $0.preferences.rememberLastQuery = false })
        #expect(LibraryStore(fileURL: library).database.clipboard.first?.richText == entry.richText)
    }

    /// M6: formatting from an earlier copy never comes back after a plain recopy or an edit.
    @Test func replacedFormattingNeverReturns() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appending(path: "library.json")
        let store = LibraryStore(fileURL: library)
        store.update { $0.preferences.clipboardEnabled = true }
        var rich = ClipboardEntry(text: "Bold", sourceName: "F")
        rich.richText = ClipboardRichText(rtf: Data("{\\rtf1 Bold}".utf8))
        #expect(store.capture(rich))
        #expect(store.capture(ClipboardEntry(text: "Bold", sourceName: "F")))
        #expect(LibraryStore(fileURL: library).database.clipboard.first?.richText == nil)

        #expect(store.capture(rich))
        #expect(LibraryStore(fileURL: library).database.clipboard.first?.richText == rich.richText)
        #expect(store.update { database in database.clipboard[0].replaceText("Edited") })
        let reloaded = LibraryStore(fileURL: library)
        #expect(reloaded.database.clipboard.first?.plainText == "Edited")
        #expect(reloaded.database.clipboard.first?.richText == nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "ClipboardImages").path)
        #expect(!leftovers.contains { $0.hasSuffix(".rich") })
    }

    /// M11: cleanup never follows a symbolic-link data folder.
    @Test func cleanupNeverFollowsALinkedDataFolder() throws {
        let directory = try temporaryDirectory()
        let elsewhere = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let victim = elsewhere.appending(path: String(repeating: "a", count: 64) + ".rich")
        try Data("keep".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "ClipboardImages"), withDestinationURL: elsewhere)
        let store = LibraryStore(fileURL: directory.appending(path: "library.json"))
        store.update { $0.preferences.clipboardEnabled = true }
        var rich = ClipboardEntry(text: "Bold", sourceName: "F")
        rich.richText = ClipboardRichText(rtf: Data("{\\rtf1 Bold}".utf8))
        #expect(store.capture(rich))
        #expect(store.capture(ClipboardEntry(text: "Bold", sourceName: "F")))
        #expect(store.update { $0.clipboard = [] })
        #expect(FileManager.default.fileExists(atPath: victim.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path) == [victim.lastPathComponent])
    }

    /// Copied text and Text Replacements are literal: placeholder-like text never runs.
    @Test func literalSourcesNeverBecomePlaceholders() throws {
        let (model, _) = makeModel()
        model.saveAsSnippet("Use {clipboard} and \\{date}", title: "Tip")
        guard case .snippet(let snippet)? = model.editor else {
            Issue.record("Expected the snippet editor")
            return
        }
        #expect(snippet.expanded() == "Use {clipboard} and \\{date}")

        let plist = try PropertyListSerialization.data(
            fromPropertyList: [["phrase": "Paste {clipboard | uppercase} here", "shortcut": "pc"]], format: .xml, options: 0)
        let imported = try #require(try LibraryImport.snippets(from: plist).items.first)
        #expect(Snippet(name: "R", keyword: "", content: imported.text).expanded() == "Paste {clipboard | uppercase} here")
    }

    /// m2: a row the save would reject is planned as invalid, so the rest still import.
    @Test func importPlansWhatTheSaveAccepts() throws {
        let (model, _) = makeModel()
        let json = Data(
            #"""
            [{"name":"Good","text":"fine"},
             {"name":"Args","text":"{argument name=\"a\"}{argument name=\"b\"}{argument name=\"c\"}{argument name=\"d\"}"},
             {"name":"Also good","text":"ok"}]
            """#.utf8)
        #expect(model.importLibrary(json, fileName: "s.json", kind: .snippets))
        #expect(model.store.database.snippets.map(\.name) == ["Good", "Also good"])
        #expect(model.feedback?.text == "Imported snippets: 2 added, 1 skipped")
    }

    /// m4: OpenRay's own round trip keeps the exact app, even one that isn't installed now.
    @Test func openWithSurvivesARoundTrip() throws {
        let (source, _) = makeModel()
        var link = Quicklink(name: "Radio", template: "https://example.com", keyword: "")
        link.openWith = QuicklinkApplication(bundleIdentifier: "com.example.gone", name: "Gone Player")
        source.store.update { $0.quicklinks = [link] }
        let data = try source.exportLibrary(.quicklinks)
        let (target, _) = makeModel()
        #expect(target.importLibrary(data, fileName: "q.json", kind: .quicklinks))
        #expect(target.store.database.quicklinks.first { $0.name == "Radio" }?.openWith == link.openWith)
    }

    @Test func bigImportsPlanInLinearTime() throws {
        let rows = (0..<10_000).map { #"{"name":"S\#($0)","text":"t\#($0)","keyword":";k\#($0 % 50)"}"# }
        let data = Data(("[" + rows.joined(separator: ",") + "]").utf8)
        let file = try LibraryImport.snippets(from: data)
        let clock = ContinuousClock()
        let start = clock.now
        let plan = LibraryImport.plan(snippets: file.items, existing: [])
        #expect(plan.additions.count == 10_000)
        #expect(clock.now - start < .seconds(3))
    }
}

// MARK: - Guard

@MainActor
struct ClipGuardTests {
    /// B2: an injected live policy never selects or writes the general pasteboard here.
    @Test func injectedLivePolicyCantReachTheRealClipboard() {
        #expect(SideEffectGuard.isInert)
        let service = ClipboardService(store: LibraryStore(fileURL: nil), pasteboard: .general, sideEffects: SideEffectGuard(mode: .live))
        #expect(!service.usesGeneralPasteboard)
        #expect(service.copy("private board only"))
        #expect(SideEffectGuard(mode: .verification).restrictedByProcess.mode == .verification)
    }

    /// B1: the editor's Test opens the sample link in its app through the guarded opener.
    @Test func editorTestUsesTheGuardedOpenerWithSamplesAndApp() async throws {
        let (model, opener) = makeModel()
        let draft = EditorDraft(editor: .quicklink(Quicklink(name: "", template: "", keyword: "")), store: model.store)
        draft.name = "Repo"
        draft.content = #"https://github.com/{argument name="org"}/{argument name="kind" options="issues, pulls"}"#
        draft.openWith = QuicklinkApplication(bundleIdentifier: "com.apple.Safari", name: "Safari")
        let sample = draft.quicklinkSample
        #expect(draft.quicklinkPreview.url == "https://github.com/swift%20concurrency/issues")
        await model.testQuicklink(sample.link, arguments: sample.arguments)?.value
        #expect(opener.opened.map(\.0.absoluteString) == ["https://github.com/swift%20concurrency/issues"])
        #expect(model.store.database.usage.isEmpty)

        // The default opener is inert here.
        let inert = LauncherModel(store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: .withUniqueName())
        await inert.testQuicklink(sample.link, arguments: sample.arguments)?.value
        #expect(inert.feedback?.style == .error)
    }
}

// MARK: - Engine

struct ClipEngineReviewTests {
    /// M2: thousands of references to a large snippet stop at planning, before reading anything.
    @Test func repeatedReferencesAreBounded() {
        let body = String(repeating: "{uuid}", count: 3_000)
        let template = String(repeating: "{snippet name=\"Body\"}", count: 3_000)
        var lookups = 0
        let clock = ContinuousClock()
        let start = clock.now
        let plan = PlaceholderTemplate(template, context: .snippet).plan { name in
            lookups += 1
            return name == "Body" ? body : nil
        }
        #expect(plan.issues == [.tooComplex])
        #expect(plan.blockingIssues == [.tooComplex])
        #expect(lookups == 1)
        let reads = Reads()
        let rendering = plan.render(reads)
        #expect(rendering.text.isEmpty && reads.log.isEmpty)
        #expect(clock.now - start < .seconds(3))

        // Within the budget, a repeated reference is planned once and rendered each time.
        let small = PlaceholderTemplate("{snippet name=\"S\"}-{snippet name=\"S\"}", context: .text).plan { _ in "x" }
        #expect(small.issues.isEmpty)
        #expect(small.render(PlaceholderValues()).text == "x-x")
    }

    /// M3: an escaped quote inside a malformed token keeps the whole token literal.
    @Test func escapedQuotesNeverExposeQuotedPlaceholders() {
        let reads = Reads()
        for text in [
            #"{argument typo "say \"quoted {clipboard}\""}"#, #"{date x="a\\" y="{selection}"}"#,
            #"{argument typo="\"{uuid}\""}"#,
        ] {
            let rendering = Placeholders.render(text, context: .text, source: reads)
            #expect(rendering.text == text, "\(text)")
        }
        #expect(reads.log.isEmpty)
    }

    /// M4: a quicklink's fields include those of snippets it references.
    @Test @MainActor func nestedSnippetArgumentsGetFields() async throws {
        let (model, opener) = makeModel()
        let link = Quicklink(name: "Search", template: #"https://example.com/?q={snippet name="Search"}"#, keyword: "")
        model.store.update {
            $0.snippets = [Snippet(name: "Search", keyword: "", content: #"{argument name="q"}"#)]
            $0.quicklinks = [link]
        }
        #expect(model.quicklinkPlan(link).argumentSpecs.map(\.name) == ["q"])
        await model.openQuicklink(link, arguments: ["q": "swift"])?.value
        #expect(opener.opened.map(\.0.absoluteString) == ["https://example.com/?q=swift"])
    }

    /// M4: a blank term takes the default; an optional field before a required one asks for both.
    @Test @MainActor func singleTermRulesFollowTheFields() async throws {
        let (model, opener) = makeModel()
        let station = Quicklink(name: "Radio", template: #"https://x.com/{argument name="s" default="hits"}"#, keyword: "r")
        let pair = Quicklink(
            name: "Pair", template: #"https://x.com/{argument name="a" default="1"}/{argument name="b"}"#, keyword: "p")
        model.store.update { $0.quicklinks = [station, pair] }

        model.beginArgument(station)
        let row = LauncherItem(
            id: "argument.\(station.id)", title: "Radio", subtitle: "", symbol: "globe", kind: .quicklink, badge: "Quicklink",
            action: .quicklink(station, ""))
        #expect(!model.returnIsInert(for: row))
        model.perform(row)
        for _ in 0..<50 where opener.opened.isEmpty { await Task.yield() }
        #expect(opener.opened.map(\.0.absoluteString) == ["https://x.com/hits"])

        model.perform(
            LauncherItem(id: "quicklink.\(pair.id)", title: "Pair", subtitle: "", symbol: "link", kind: .quicklink,
                badge: "Quicklink", action: .quicklink(pair, "")))
        #expect(model.feedback?.style == .warning && model.feedback?.text == "Enter b.")
        #expect(model.quicklinkCommand(for: pair) != nil)
    }

    /// M4: fields stay right when a referenced snippet changes.
    @Test @MainActor func runCommandsFollowReferencedSnippets() {
        let (model, _) = makeModel()
        let link = Quicklink(name: "L", template: #"x://{argument name="a"}/{snippet name="S"}"#, keyword: "")
        model.store.update {
            $0.snippets = [Snippet(name: "S", keyword: "", content: #"{argument name="b"}"#)]
            $0.quicklinks = [link]
        }
        #expect(model.quicklinkCommand(for: link) != nil)
        model.store.update { $0.snippets[0].content = "plain" }
        #expect(model.quicklinkCommand(for: link) == nil)
    }

    /// M10: run commands can't hold aliases or hotkeys.
    @Test @MainActor func runCommandsAreNeverBindable() throws {
        let (model, _) = makeModel()
        let link = Quicklink(name: "Pair", template: #"x://{argument name="a"}/{argument name="b"}"#, keyword: "")
        let snippet = Snippet(name: "Ask", keyword: "", content: #"Dear {argument name="who"}"#)
        model.store.update {
            $0.quicklinks = [link]
            $0.snippets = [snippet]
        }
        let ids = [
            LibraryCommandProvider.commandID(for: link), LibraryCommandProvider.commandID(for: snippet, action: .copy),
            LibraryCommandProvider.commandID(for: snippet, action: .paste),
        ]
        #expect(ids.allSatisfy { model.registry.item(withID: $0, in: model) != nil })
        #expect(ids.allSatisfy { !CuratedCommand.supports($0) })
        #expect(!model.registry.bindableCommandItems(in: model).contains { $0.id.hasPrefix(LibraryCommandProvider.runPrefix) })
        #expect(CuratedCommand.supports("library.importSnippets"))
    }
}

// MARK: - Clipboard and keys

@MainActor
struct ClipKeysAndPrivacyTests {
    private func clipboardItem(_ text: String) -> LauncherItem {
        let entry = ClipboardEntry(text: text, sourceName: "F")
        return LauncherItem(
            id: "clipboard.\(entry.id)", title: text, subtitle: "", symbol: "doc", kind: .clipboard, badge: "Text",
            action: .clipboard(entry))
    }

    /// M12: ↩ and ⌘↩ always do different things, in both modes.
    @Test(arguments: [ContentPrimaryAction.copy, .paste])
    func returnAndCommandReturnNeverBothCopy(_ mode: ContentPrimaryAction) {
        let (model, _) = makeModel()
        model.primaryActionOverride = mode
        let item = clipboardItem("Hello")
        model.perform(item)
        let primary = model.feedback?.style
        model.paste(item)
        let secondary = model.feedback?.style
        // In this isolated test, copying toasts success and pasting explains the isolated board.
        #expect(primary == (mode == .copy ? .success : .info))
        #expect(secondary == (mode == .copy ? .info : .success))
        #expect(model.primaryTitle(for: item).hasPrefix(mode == .copy ? "Copy" : "Paste"))
        #expect(model.secondaryTitle(for: item)?.hasPrefix(mode == .copy ? "Paste" : "Copy") == true)
    }

    /// M8: copies from an excluded app never reach `{clipboard}`.
    @Test func excludedCopiesAreNeverInserted() async {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = LibraryStore(fileURL: nil)
        store.update { $0.preferences.clipboardEnabled = true }
        final class Source { var context = ClipboardCaptureContext(sourceName: "1Password", sourceBundleID: "com.1password.1password", secureInput: false) }
        let source = Source()
        let service = ClipboardService(store: store, pasteboard: board, captureContext: { source.context })
        board.clearContents()
        board.setString("hunter2", forType: .string)
        await service.poll()
        #expect(service.placeholderText() == nil)
        source.context = ClipboardCaptureContext(sourceName: "Notes", sourceBundleID: "com.apple.Notes", secureInput: false)
        board.clearContents()
        board.setString("note", forType: .string)
        await service.poll()
        #expect(service.placeholderText() == "note")
        #expect(ClipboardPolicy.placeholderText(from: board, secureInput: true) == nil)
    }

    /// M8: with capture off, a template asking only for history reads nothing.
    @Test func historyOnlyTemplatesDontReadTheClipboardWhileCaptureIsOff() {
        var database = LibraryDatabase()
        database.preferences.clipboardEnabled = false
        var reads = 0
        _ = PlaceholderValues.snapshot(library: database, requirements: .init(clipboardOffsets: [1])) {
            reads += 1
            return "x"
        }
        #expect(reads == 0)
        database.preferences.clipboardEnabled = true
        _ = PlaceholderValues.snapshot(library: database, requirements: .init(clipboardOffsets: [1])) {
            reads += 1
            return "x"
        }
        #expect(reads == 1)
    }

    /// M9: one retention setter, so turning history back on after Unlimited keeps the new choice.
    @Test func reOptingInAfterUnlimitedKeepsTheNewChoice() {
        let (model, _) = makeModel()
        model.store.update { $0.preferences.setClipboardRetention(.unlimited) }
        #expect(model.store.database.preferences.clipboardRetentionDaysOrUnlimited == nil)
        model.clipboardOptIn.days = 1
        model.enableClipboardHistory()
        let preferences = model.store.database.preferences
        #expect(preferences.effectiveClipboardRetention == .oneDay)
        #expect(preferences.clipboardRetentionDaysOrUnlimited == 1)
        #expect(AppPreferences().clipboardRetentionDaysOrUnlimited == 7)
    }
}
