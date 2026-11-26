import Foundation
import Testing

@testable import OpenRay

private struct FakeApplications: ApplicationResolving {
    var byIdentifier: [String: ResolvedApplication] = [:]
    var byName: [String: ResolvedApplication] = [:]

    func application(bundleIdentifier: String) -> ResolvedApplication? { byIdentifier[bundleIdentifier] }
    func application(named name: String) -> ResolvedApplication? { byName[name] }
}

private func arguments(_ pairs: [String: String]) -> PlaceholderValues {
    PlaceholderValues(arguments: Dictionary(uniqueKeysWithValues: pairs.map { (.named($0.key), $0.value) }))
}

struct QuicklinkTemplateTests {
    @Test func webLinksEncodeArguments() throws {
        let template = QuicklinkTemplate(#"  https://github.com/{argument name="org"}/{argument name="repo"}?q={argument name="q"}  "#)
        #expect(template.arguments.map(\.title) == ["org", "repo", "q"])
        let resolved = try template.resolve(using: arguments(["org": "apple", "repo": "swift", "q": "a b&c"]))
        #expect(resolved.url.absoluteString == "https://github.com/apple/swift?q=a%20b%26c")
        #expect(resolved.kind == .web)
    }

    @Test(arguments: [
        ("spotify://search/{argument}", "spotify://search/Daft%20Punk", "spotify"),
        ("obsidian://open?vault=Notes&file={argument}", "obsidian://open?vault=Notes&file=Daft%20Punk", "obsidian"),
        ("x-apple.systempreferences:com.apple.preference.security", "x-apple.systempreferences:com.apple.preference.security", "x-apple.systempreferences"),
        ("shortcuts://run-shortcut?Name={Test}", "shortcuts://run-shortcut?Name=Daft%20Punk", "shortcuts"),
        ("mailto:{argument}", "mailto:Daft%20Punk", "mailto"),
        ("tel:+15550100", "tel:+15550100", "tel"),
    ])
    func anyUrlSchemeOpensAsADeeplink(_ link: String, _ expected: String, _ scheme: String) throws {
        let values = PlaceholderValues(arguments: [.unnamed(1): "Daft Punk", .named("Test"): "Daft Punk"])
        let resolved = try QuicklinkTemplate(link).resolve(using: values)
        #expect(resolved.url.absoluteString == expected)
        #expect(resolved.kind == .deeplink(scheme: scheme))
    }

    @Test func pathsInsertValuesUnencoded() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let template = QuicklinkTemplate(#"~/Projects/{argument name="project"}"#)
        #expect(template.isPath)
        let resolved = try template.resolve(using: arguments(["project": "my app"]))
        #expect(resolved.kind == .file)
        #expect(resolved.url.path == home + "/Projects/my app")
        #expect(try QuicklinkTemplate("/tmp").resolve(using: PlaceholderValues()).url == URL(fileURLWithPath: "/tmp"))
        #expect(try QuicklinkTemplate("~").resolve(using: PlaceholderValues()).url.path == home)
        let fileURL = try QuicklinkTemplate("file:///tmp/a%20b").resolve(using: PlaceholderValues())
        #expect(fileURL.kind == .file && fileURL.url.path == "/tmp/a b")
    }

    @Test func bareHostsGetHTTPS() throws {
        #expect(try QuicklinkTemplate("example.com/docs").resolve(using: PlaceholderValues()).url.absoluteString == "https://example.com/docs")
        let withPort = try QuicklinkTemplate("example.com:8080/x").resolve(using: PlaceholderValues())
        #expect(withPort.url.absoluteString == "https://example.com:8080/x")
        #expect(withPort.url.port == 8080)
    }

    @Test(arguments: [
        "javascript:alert(1)", "JavaScript:alert(1)", "  javascript:alert(1)", "vbscript:msgbox", "data:text/html,<b>x</b>",
        "blob:https://example.com/id", "https://", "http:///path", "not a link", "", "relative/path",
        "https://x.com/{cursor}", "{browser-tab}", "https://x.com/{argument name=\"a\"}{argument name=\"b\"}{argument name=\"c\"}{argument name=\"d\"}",
        "https://x.com/{date locale=\"xx-YY\"}",
    ])
    func unsafeOrBrokenLinksAreRejected(_ link: String) {
        #expect(throws: LibraryValidationError.self) { try QuicklinkTemplate(link).validate() }
    }

    @Test func renderedValuesCannotSmuggleAnUnsafeScheme() {
        let template = QuicklinkTemplate("{argument | raw}:alert(1)")
        #expect(throws: LibraryValidationError.self) {
            try template.resolve(using: PlaceholderValues(arguments: [.unnamed(1): "javascript"]))
        }
        let newline = QuicklinkTemplate("https://x.com/{argument | raw}")
        #expect(throws: LibraryValidationError.self) {
            try newline.resolve(using: PlaceholderValues(arguments: [.unnamed(1): "a\nb"]))
        }
        // Encoded, the same newline is harmless.
        #expect(
            (try? QuicklinkTemplate("https://x.com/{argument}").resolve(using: PlaceholderValues(arguments: [.unnamed(1): "a\nb"])))?
                .url.absoluteString == "https://x.com/a%0Ab")
    }

    @Test func missingArgumentsExplainWhatToEnter() {
        #expect(throws: LibraryValidationError("Enter a search term for this quicklink.")) {
            try QuicklinkTemplate("https://d.com/?q={query}").resolve(using: PlaceholderValues())
        }
        #expect(throws: LibraryValidationError("Enter a value for “repo”.")) {
            try QuicklinkTemplate(#"https://github.com/{argument name="repo"}"#).resolve(using: PlaceholderValues())
        }
        let withDefault = try? QuicklinkTemplate(#"https://d.com/?q={argument name="q" default="swift"}"#)
            .resolve(using: PlaceholderValues())
        #expect(withDefault?.url.absoluteString == "https://d.com/?q=swift")
    }

    @Test(arguments: [
        "https://duckduckgo.com/?q={query}", "https://x.com/{argument options=\"a, b\"}", "~/Downloads",
        "obsidian://open?vault={clipboard}", "https://x.com/{date format=\"yyyy\"}/{uuid}/{selection}",
        "https://x.com/{snippet name=\"x\"}?n={calculator expression=\"1 + 1\"}", "spotify:", "example.com",
    ])
    func validLinksPassValidation(_ link: String) throws {
        try QuicklinkTemplate(link).validate()
    }

    @Test func legacyQueryLinksResolveExactlyAsBefore() throws {
        for query in ["swift", "a b", "café & co/100%", "?#[]@!$'()*+,;="] {
            let link = Quicklink(name: "Search", template: "https://duckduckgo.com/?q={query}", keyword: "d")
            let legacy = try link.resolvedURL(query: query)
            let engine = try QuicklinkTemplate(link.template).resolve(using: arguments(["query": query])).url
            #expect(engine == legacy)
        }
    }

    @Test func modernizedLinksUseNamedArguments() {
        #expect(QuicklinkTemplate("https://d.com/?q={query}").modernizedLink == #"https://d.com/?q={argument name="query"}"#)
        #expect(QuicklinkTemplate("x://{Test | raw}").modernizedLink == #"x://{argument name="Test" | raw}"#)
        let modern = #"https://x.com/{argument name="a" default="b"}/{clipboard}"#
        #expect(QuicklinkTemplate(modern).modernizedLink == modern)
    }

    @Test func schemeDetection() {
        #expect(QuicklinkTemplate.scheme(of: "https://x") == "https")
        #expect(QuicklinkTemplate.scheme(of: "x-apple.systempreferences:abc") == "x-apple.systempreferences")
        #expect(QuicklinkTemplate.scheme(of: "example.com:8080") == nil)
        #expect(QuicklinkTemplate.scheme(of: "1abc:x") == nil)
        #expect(QuicklinkTemplate.scheme(of: "no colon") == nil)
        #expect(QuicklinkTemplate.scheme(of: "a b:c") == nil)
    }

    @Test func openWithResolvesBundleIdentifiersNamesAndPaths() {
        let finder = ResolvedApplication(
            bundleIdentifier: "com.apple.finder", name: "Finder",
            url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        let safari = ResolvedApplication(
            bundleIdentifier: "com.apple.Safari", name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let resolver = FakeApplications(
            byIdentifier: ["com.apple.finder": finder], byName: ["Finder": finder, "Safari": safari])
        #expect(QuicklinkOpenWith.resolve("com.apple.finder", using: resolver) == finder)
        #expect(QuicklinkOpenWith.resolve(" Finder ", using: resolver) == finder)
        #expect(QuicklinkOpenWith.resolve("/Applications/Safari.app", using: resolver) == safari)
        #expect(QuicklinkOpenWith.resolve("com.example.missing", using: resolver) == nil)
        #expect(QuicklinkOpenWith.resolve("", using: resolver) == nil)
        #expect(finder.quicklinkApplication == QuicklinkApplication(bundleIdentifier: "com.apple.finder", name: "Finder"))
        #expect(QuicklinkOpenWith.isBundleIdentifier("com.apple.Safari"))
        #expect(!QuicklinkOpenWith.isBundleIdentifier("Visual Studio Code"))
        #expect(!QuicklinkOpenWith.isBundleIdentifier("com..x"))
    }

    @Test func openWithApplicationsRoundTripThroughJSON() throws {
        let app = QuicklinkApplication(bundleIdentifier: "com.apple.Music", name: "Music")
        let data = try JSONEncoder().encode(app)
        #expect(try JSONDecoder().decode(QuicklinkApplication.self, from: data) == app)
    }
}

struct QuicklinkReviewFixTests {
    @Test func modernizingKeepsEscapesAndModernSyntaxExactly() throws {
        let escaped = #"https://example.com/?q=\{clipboard}&r={query}"#
        #expect(QuicklinkTemplate(escaped).modernizedLink == #"https://example.com/?q=\{clipboard}&r={argument name="query"}"#)
        let spaced = #"https://x.com/{ argument name="x" default="d" options="a, b"}"#
        #expect(QuicklinkTemplate(spaced).modernizedLink == spaced)

        // Export, import and resolve: the escaped token stays literal text, never a clipboard read.
        let exported = try LibraryImport.exportQuicklinks([ImportedQuicklink(name: "Escaped", link: QuicklinkTemplate(escaped).modernizedLink)])
        let imported = try #require(try LibraryImport.quicklinks(from: exported).items.first)
        #expect(imported.link == #"https://example.com/?q=\{clipboard}&r={argument name="query"}"#)
        let template = QuicklinkTemplate(imported.link)
        #expect(!template.template.placeholders.contains { $0.kind == .clipboard })
        #expect(template.arguments.map(\.id) == [.named("query")])
    }

    @Test func legacyPlaceholdersAreMarked() {
        let template = QuicklinkTemplate("x://{query}/{Name}/{argument name=\"query\"}")
        #expect(template.template.placeholders.map(\.isLegacyArgument) == [true, true, false])
    }

    @MainActor @Test(arguments: [SideEffectGuard.Mode.testHost, .verification])
    func inertModesGetAnInertOpener(_ mode: SideEffectGuard.Mode) async {
        let opener = QuicklinkOpeners.makeDefault(sideEffects: SideEffectGuard(mode: mode))
        #expect(opener is InertQuicklinkOpener)
        await #expect(throws: SideEffectGuard.Blocked(what: "opening links and apps", mode: mode)) {
            try await opener.open(URL(string: "https://example.com")!, with: nil)
        }
        // An injected live policy can't lift this process's: still inert, and the
        // workspace opener refuses too, before any system call.
        #expect(QuicklinkOpeners.makeDefault(sideEffects: SideEffectGuard(mode: .live)) is InertQuicklinkOpener)
        #expect(QuicklinkOpeners.makeDefault() is InertQuicklinkOpener)
        await #expect(throws: SideEffectGuard.Blocked.self) {
            try await WorkspaceQuicklinkOpener(sideEffects: SideEffectGuard(mode: .live))
                .open(URL(string: "https://example.com")!, with: nil)
        }
    }
}
