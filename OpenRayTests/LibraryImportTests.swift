import Foundation
import Testing

@testable import OpenRay

private func json(_ text: String) -> Data { Data(text.utf8) }

struct LibraryImportTests {
    // MARK: Snippet files

    @Test func readsSnippetJSONArraysAndSingleObjects() throws {
        let file = try LibraryImport.snippets(
            from: json(
                #"""
                [
                  {"name": " Personal Email ", "text": "sherlock@gmail.com", "keyword": "@@"},
                  {"name": "No keyword", "text": "Line 1\nLine 2", "keyword": ""},
                  {"name": "Missing text"},
                  {"name": 3, "text": "wrong type"},
                  "not an object",
                  {"name": "Extra", "text": "ok", "id": 7, "tags": ["a"]}
                ]
                """#))
        #expect(
            file.items == [
                ImportedSnippet(name: "Personal Email", text: "sherlock@gmail.com", keyword: "@@"),
                ImportedSnippet(name: "No keyword", text: "Line 1\nLine 2"),
                ImportedSnippet(name: "Extra", text: "ok"),
            ])
        #expect(file.invalidCount == 3)

        let single = try LibraryImport.snippets(
            from: json(#"{"name": "Personal Email", "text": "sherlock@gmail.com", "keyword": "@@"}"#))
        #expect(single.items.count == 1 && single.invalidCount == 0)
    }

    @Test func rejectsUnreadableAndEmptyFiles() {
        #expect(throws: LibraryImportError.unreadable) { try LibraryImport.snippets(from: json("not json")) }
        #expect(throws: LibraryImportError.unreadable) { try LibraryImport.snippets(from: json("42")) }
        #expect(throws: LibraryImportError.noEntries) { try LibraryImport.snippets(from: json("[]")) }
        #expect(throws: LibraryImportError.fileTooLarge) {
            try LibraryImport.snippets(from: Data(repeating: 0x20, count: LibraryImport.maximumBytes + 1))
        }
        #expect(throws: LibraryImportError.unreadable) { try LibraryImport.quicklinks(from: json("{")) }
    }

    @Test func neverParsesEncryptedArchives() {
        let valid = json(#"[{"name": "A", "text": "B"}]"#)
        #expect(throws: LibraryImportError.encryptedArchive) { try LibraryImport.checkFileName("Backup.rayconfig") }
        #expect(throws: LibraryImportError.encryptedArchive) {
            try LibraryImport.snippets(from: valid, fileName: "/Users/x/Raycast.RAYCONFIG")
        }
        #expect(throws: LibraryImportError.encryptedArchive) {
            try LibraryImport.quicklinks(from: valid, fileName: "x.rayconfig")
        }
        #expect(throws: Never.self) { try LibraryImport.checkFileName("snippets.json") }
        #expect(LibraryImportError.encryptedArchive.errorDescription?.contains("JSON") == true)
    }

    @Test(arguments: [PropertyListSerialization.PropertyListFormat.xml, .binary])
    func readsTextReplacementsPropertyLists(_ format: PropertyListSerialization.PropertyListFormat) throws {
        let entries: [[String: String]] = [
            ["phrase": "On my way!", "shortcut": "omw"],
            ["phrase": "\n  Kind regards,\nAnn", "shortcut": " "],
            ["phrase": String(repeating: "Long ", count: 30), "shortcut": "lng"],
            ["shortcut": "nophrase"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: format, options: 0)
        let file = try LibraryImport.snippets(from: data, fileName: "property list.plist")
        #expect(file.items.map(\.keyword) == ["omw", nil, "lng"])
        #expect(file.items.map(\.name).prefix(2) == ["On my way!", "Kind regards,"])
        #expect(file.items[2].name.count == 60 && file.items[2].name.hasSuffix("…"))
        #expect(file.items[1].text == "\n  Kind regards,\nAnn")
        #expect(file.invalidCount == 1)
    }

    @Test func snippetExportRoundTrips() throws {
        let snippets = [
            ImportedSnippet(name: "Email", text: "a@b.com / {clipboard}", keyword: "@@"),
            ImportedSnippet(name: "Plain", text: "No keyword"),
        ]
        let data = try LibraryImport.exportSnippets(snippets)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""keyword" : "@@""#))
        #expect(text.contains("a@b.com / {clipboard}"))
        #expect(!text.contains("null"))
        #expect(try LibraryImport.snippets(from: data).items == snippets)
        let library = Snippet(name: "Lib", keyword: ";l", content: "Text")
        #expect(ImportedSnippet(library) == ImportedSnippet(name: "Lib", text: "Text", keyword: ";l"))
        #expect(ImportedSnippet(Snippet(name: "N", keyword: "", content: "T")).keyword == nil)
    }

    // MARK: Quicklink files

    @Test func readsTheDocumentedQuicklinkExample() throws {
        let file = try LibraryImport.quicklinks(
            from: json(
                #"""
                [
                  {"link": "https://duckduckgo.com/?q={argument}", "name": "Search DuckDuckGo"},
                  {"openWith": "Finder", "iconName": "folder-16", "link": "~/Downloads", "name": "Downloads"},
                  {"openWith": "Music", "link": "https://music.apple.com/gb/station/apple-music-hits/ra.1498155548", "name": "Apple Music Hits Radio"},
                  {"link": "shortcuts://run-shortcut?Name={Test}", "name": "Run Apple Shortcut"},
                  {"name": "No link"}
                ]
                """#))
        #expect(file.items.count == 4)
        #expect(file.invalidCount == 1)
        #expect(file.items[1] == ImportedQuicklink(name: "Downloads", link: "~/Downloads", iconName: "folder-16", openWith: "Finder"))
        let plan = LibraryImport.plan(quicklinks: file.items, existing: [])
        #expect(plan.additions == file.items)
        #expect(plan.summary == "4 added")
    }

    @Test func quicklinkExportModernizesLegacyQueries() throws {
        let link = Quicklink(name: "Search", template: "https://duckduckgo.com/?q={query}", keyword: "d")
        let exported = ImportedQuicklink(link, openWith: "Safari")
        #expect(exported.link == #"https://duckduckgo.com/?q={argument name="query"}"#)
        let data = try LibraryImport.exportQuicklinks([exported])
        #expect(try LibraryImport.quicklinks(from: data).items == [exported])
        #expect(String(decoding: data, as: UTF8.self).contains("https://duckduckgo.com"))
    }

    // MARK: Conflicts

    @Test func snippetPlanSkipsDuplicatesAndDropsConflictingKeywords() {
        let existing = [
            Snippet(name: "Email", keyword: "@@", content: "a@b.com"),
            Snippet(name: "Sig", keyword: ";sig", content: "Ann"),
        ]
        let incoming = [
            ImportedSnippet(name: "Email", text: "a@b.com", keyword: "@@"),  // identical
            ImportedSnippet(name: "Other email", text: "c@d.com", keyword: "@@"),  // keyword taken
            ImportedSnippet(name: "New", text: "new", keyword: ";new"),
            ImportedSnippet(name: "New again", text: "again", keyword: ";new"),  // taken earlier in the file
            ImportedSnippet(name: "New", text: "new", keyword: ";new"),  // identical to an earlier entry
            ImportedSnippet(name: "Spaced", text: "x", keyword: "has space"),  // invalid keyword
            ImportedSnippet(name: "Too long", text: String(repeating: "x", count: 11)),
            ImportedSnippet(name: " ", text: "nameless"),
        ]
        let plan = LibraryImport.plan(snippets: incoming, existing: existing, maximumTextLength: 10)
        #expect(
            plan.additions == [
                ImportedSnippet(name: "Other email", text: "c@d.com"),
                ImportedSnippet(name: "New", text: "new", keyword: ";new"),
                ImportedSnippet(name: "New again", text: "again"),
                ImportedSnippet(name: "Spaced", text: "x"),
            ])
        #expect(plan.duplicates.map(\.name) == ["Email", "New"])
        #expect(plan.keywordConflicts.map(\.name) == ["Other email", "New again"])
        #expect(plan.keywordsDropped.map(\.name) == ["Other email", "New again", "Spaced"])
        #expect(plan.invalid.map(\.name) == ["Too long", " "])
        #expect(plan.replacements.isEmpty)
        #expect(plan.skippedCount == 4)
        #expect(plan.summary == "4 added, 4 skipped, 3 without keyword")
    }

    @Test func snippetPlanCanSkipConflicts() {
        let existing = [Snippet(name: "Email", keyword: "@@", content: "a@b.com")]
        let plan = LibraryImport.plan(
            snippets: [ImportedSnippet(name: "Other", text: "x", keyword: "@@")], existing: existing, policy: .skip)
        #expect(plan.additions.isEmpty)
        #expect(plan.skippedConflicts.map(\.name) == ["Other"])
        #expect(plan.summary == "0 added, 1 skipped")
    }

    @Test func snippetPlanCanMergeIntoTheKeywordHolder() {
        let holder = Snippet(name: "Email", keyword: "@@", content: "old@b.com")
        let plan = LibraryImport.plan(
            snippets: [
                ImportedSnippet(name: "Email", text: "new@b.com", keyword: "@@"),
                ImportedSnippet(name: "Email v2", text: "newer@b.com", keyword: "@@"),
                ImportedSnippet(name: "A", text: "1", keyword: ";a"),
                ImportedSnippet(name: "A2", text: "2", keyword: ";a"),
            ], existing: [holder], policy: .replaceExisting)
        #expect(plan.replacements == [.init(existingID: holder.id, snippet: ImportedSnippet(name: "Email v2", text: "newer@b.com", keyword: "@@"))])
        #expect(plan.additions == [ImportedSnippet(name: "A2", text: "2", keyword: ";a")])
        #expect(plan.summary == "1 added, 1 updated")
    }

    @Test func snippetPlanUsesTheGivenKeywordRule() {
        let plan = LibraryImport.plan(
            snippets: [ImportedSnippet(name: "A", text: "1", keyword: "@@")], existing: [],
            isValidKeyword: { $0.allSatisfy(\.isLetter) })
        #expect(plan.additions == [ImportedSnippet(name: "A", text: "1")])
        #expect(plan.keywordsDropped.count == 1)
    }

    @Test func quicklinkPlanSkipsDuplicatesAndUnsafeLinks() {
        let existing = [Quicklink(name: "Search", template: "https://d.com/?q={query}", keyword: "d")]
        let plan = LibraryImport.plan(
            quicklinks: [
                ImportedQuicklink(name: "Search", link: #"https://d.com/?q={argument name="query"}"#),
                ImportedQuicklink(name: "Search", link: "https://other.com/?q={argument}"),
                ImportedQuicklink(name: "Evil", link: "javascript:alert(1)"),
                ImportedQuicklink(name: "Broken", link: "{browser-tab}"),
                ImportedQuicklink(name: "Search", link: "https://other.com/?q={argument}"),
            ], existing: existing)
        #expect(plan.additions.map(\.link) == ["https://other.com/?q={argument}"])
        #expect(plan.duplicates.count == 2)
        #expect(plan.invalid.map(\.name) == ["Evil", "Broken"])
        #expect(plan.summary == "1 added, 2 duplicates skipped, 2 invalid skipped")
    }
}
