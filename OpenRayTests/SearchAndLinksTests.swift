import Foundation
import Testing

@testable import OpenRay

struct SearchAndLinksTests {
    @Test func exactBeforePrefixBeforeFuzzy() throws {
        let exact = try #require(SearchMatcher.score("notes", in: "Notes"))
        let prefix = try #require(SearchMatcher.score("notes", in: "Notes Manager"))
        let fuzzy = try #require(SearchMatcher.score("nts", in: "Notes"))
        #expect(exact > prefix)
        #expect(prefix > fuzzy)
        #expect(SearchMatcher.score("unrelated", in: "Notes") == nil)
    }

    @Test func supportsCaseAccentsAndMultipleTerms() {
        #expect(SearchMatcher.score("cafe", in: "Café") == 1_000)
        #expect(SearchMatcher.score("WIN MAN", in: "Window Management") != nil)
        #expect(SearchMatcher.score("win zebra", in: "Window Management") == nil)
        #expect(SearchMatcher.score("", in: "Anything") == 0)
    }

    @Test func quicklinkEncodesQueryWithoutInjectingParameters() throws {
        let link = Quicklink(name: "Search", template: "https://example.com/?q={query}&lang=en", keyword: "q")
        let term = "a&admin=true #c++/日本語?"
        let url = try link.resolvedURL(query: term)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "q" })?.value == term)
        #expect(components.queryItems?.count == 2)
        #expect(components.fragment == nil)
    }

    @Test func quicklinkSupportsUnicodePathsAndFilePaths() throws {
        let link = Quicklink(name: "File", template: "/tmp/My folder/note.txt", keyword: "")
        #expect(try link.resolvedURL().path == "/tmp/My folder/note.txt")
        #expect(try link.resolvedURL().isFileURL == true)
        let web = Quicklink(name: "Website", template: "https://example.com/about", keyword: "")
        #expect(try web.resolvedURL().absoluteString == web.template)
    }

    @Test(arguments: [
        "javascript:alert(1)", "data:text/html,unsafe", "https://", "not a URL", "ftp://example.com",
        "https://example.com/{unknown}", "/tmp/{query}",
    ])
    func rejectsUnsupportedQuicklinks(_ template: String) {
        #expect(throws: LibraryValidationError.self) {
            try Quicklink(name: "Test", template: template, keyword: "").validate()
        }
    }

    @Test func queryRequiredOnlyForTemplates() {
        #expect(throws: LibraryValidationError.self) {
            try Quicklink(name: "Search", template: "https://example.com/?q={query}", keyword: "s").resolvedURL()
        }
    }

    @Test func quicklinkKeywordsAreCaseInsensitiveAndPreserveArguments() {
        let link = Quicklink(name: "Search", template: "https://example.com/?q={query}", keyword: "web")
        #expect(link.argument(in: "  WEB  Swift Concurrency  ") == "Swift Concurrency")
        #expect(link.argument(in: "web") == "")
        #expect(link.argument(in: "website example") == nil)
    }
}
