import AppKit
import Foundation

/// A quicklink's link with placeholders, e.g. `https://github.com/{argument name="repo"}`,
/// `spotify://search/{argument}`, `~/Projects/{argument name="project"}` or
/// `obsidian://open?vault=Notes`.
///
/// What is accepted:
/// - Any URL with an RFC 3986 scheme (`https:`, `mailto:`, `spotify://`,
///   `x-apple.systempreferences:` …). Web links need a host.
/// - Absolute paths (`/…`) and home paths (`~`, `~/…`). Values inserted into a
///   path are not percent-encoded, because the path is used as written.
/// - A bare host such as `example.com/docs`, which gets `https://`.
///
/// What is rejected, because opening it runs code in the browser or hides what
/// the link really is: `javascript:`, `vbscript:`, `data:` and `blob:` URLs, and
/// links that contain control characters or line breaks after rendering.
struct QuicklinkTemplate: Hashable, Sendable {
    static let rejectedSchemes: Set<String> = ["javascript", "vbscript", "data", "blob"]

    /// The link as written, without surrounding whitespace.
    let link: String
    let template: PlaceholderTemplate

    init(_ link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        self.link = trimmed
        template = PlaceholderTemplate(trimmed, context: .quicklink)
    }

    /// Paths open as files. Their placeholder values are inserted unencoded.
    var isPath: Bool { link.hasPrefix("/") || link == "~" || link.hasPrefix("~/") }

    /// The arguments to ask for, in order. Use `arguments(using:)` when the link
    /// references snippets that contain arguments.
    var arguments: [PlaceholderArgument] { template.arguments }

    /// The link with the legacy `{query}` and `{Name}` arguments rewritten as
    /// `{argument name="…"}`, for export to tools that only know the newer syntax.
    /// Only those tokens change; everything else, escapes included, stays as written.
    var modernizedLink: String {
        var result = link
        for placeholder in template.placeholders.reversed() where placeholder.isLegacyArgument {
            guard case .argument(let argument) = placeholder.token, let name = argument.name else { continue }
            let modifiers = placeholder.modifiers.map { " | \($0.rawValue)" }.joined()
            result.replaceSubrange(placeholder.range, with: "{argument name=\"\(name)\"\(modifiers)}")
        }
        return result
    }

    /// Plans the link with `source`'s snippets, renders it and checks the result.
    /// Blocking issues anywhere, including inside referenced snippets, and invalid
    /// placeholders, whose literal braces don't belong in a link, stop it.
    func resolve(using source: some PlaceholderDataSource) throws -> QuicklinkResolution {
        guard !link.isEmpty else { throw LibraryValidationError("Enter a URL, a deeplink or a file path.") }
        let plan = template.plan(snippets: source.snippetText(named:))
        if let issue = plan.issues.first(where: { $0.blocksExecution || Self.isInvalid($0) }) {
            throw LibraryValidationError(issue.message)
        }
        let rendering = plan.render(source, options: .init(appliesContextFormatting: !isPath))
        if let missing = rendering.missingArguments.first {
            throw LibraryValidationError(
                missing == "query" ? "Enter a search term for this quicklink." : "Enter a value for “\(missing)”.")
        }
        if let issue = rendering.blockingIssues.first { throw LibraryValidationError(issue.message) }
        let text = rendering.text
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LibraryValidationError("A quicklink can't contain line breaks or control characters.")
        }
        if isPath {
            let expanded = (text as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw LibraryValidationError("Use an absolute file path.") }
            return QuicklinkResolution(url: URL(fileURLWithPath: expanded), kind: .file, rendering: rendering)
        }
        let candidate: String
        if Self.scheme(of: text) != nil {
            candidate = text
        } else if Self.looksLikeHost(text) {
            candidate = "https://" + text
        } else {
            throw LibraryValidationError("Start the link with a scheme such as https:// or spotify://, or a path.")
        }
        guard let scheme = Self.scheme(of: candidate)?.lowercased(), let url = URL(string: candidate) else {
            throw LibraryValidationError("This isn't a valid link.")
        }
        guard !Self.rejectedSchemes.contains(scheme) else {
            throw LibraryValidationError("Quicklinks can't open \(scheme): links.")
        }
        switch scheme {
        case "http", "https":
            guard url.host?.isEmpty == false else { throw LibraryValidationError("Add a host to this web link.") }
            return QuicklinkResolution(url: url, kind: .web, rendering: rendering)
        case "file":
            guard url.isFileURL, url.path.hasPrefix("/") else {
                throw LibraryValidationError("Use an absolute file URL.")
            }
            return QuicklinkResolution(url: url, kind: .file, rendering: rendering)
        default:
            return QuicklinkResolution(url: url, kind: .deeplink(scheme: scheme), rendering: rendering)
        }
    }

    /// Checks the link for saving: every placeholder issue, including ones a run
    /// would tolerate such as `{cursor}`, then a trial render with sample values.
    func validate() throws {
        if let issue = template.validationIssues.first { throw LibraryValidationError(issue.message) }
        _ = try resolve(using: SampleQuicklinkValues())
    }

    private static func isInvalid(_ issue: PlaceholderIssue) -> Bool {
        if case .invalid = issue { true } else { false }
    }

    /// The scheme before the first `:`, if the text starts with one.
    static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
            scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) })
        else { return nil }
        // `example.com:8080/docs` is a host and port, not a scheme.
        let afterColon = text[text.index(after: colon)...]
        if scheme.contains("."), afterColon.first?.isNumber == true { return nil }
        return String(scheme)
    }

    private static func looksLikeHost(_ text: String) -> Bool {
        let host = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != ":" }
        return !text.contains(where: \.isWhitespace) && host.contains(".") && !host.hasPrefix(".")
            && !host.hasSuffix(".") && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }
}

struct QuicklinkResolution: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case web
        case file
        /// An app deeplink, routed by macOS to the app that registered the scheme.
        case deeplink(scheme: String)
    }

    var url: URL
    var kind: Kind
    var rendering: PlaceholderRendering
}

/// Fills every placeholder with harmless sample text, for validating a link.
private struct SampleQuicklinkValues: PlaceholderDataSource {
    func clipboardText(offset: Int) -> String? { "sample" }
    func selectedText() -> String? { "sample" }
    func snippetText(named name: String) -> String? { "sample" }
    func value(for argument: PlaceholderArgument) -> String? { argument.options.first ?? "sample" }
    func calculate(_ expression: String) -> String? { "1" }
}

// MARK: - Open With

/// The app a quicklink opens with. The name is kept for display when the app is
/// later removed.
struct QuicklinkApplication: Codable, Hashable, Sendable {
    var bundleIdentifier: String
    var name: String
}

/// An installed app, found by bundle identifier or name.
struct ResolvedApplication: Hashable, Sendable {
    var bundleIdentifier: String
    var name: String
    var url: URL

    var quicklinkApplication: QuicklinkApplication { .init(bundleIdentifier: bundleIdentifier, name: name) }
}

/// Finds installed apps. The live implementation reads Launch Services; tests use a fake.
protocol ApplicationResolving: Sendable {
    func application(bundleIdentifier: String) -> ResolvedApplication?
    func application(named name: String) -> ResolvedApplication?
}

/// Opens a resolved quicklink. Opening is a side effect, so it stays behind a protocol.
@MainActor
protocol QuicklinkOpening {
    func open(_ url: URL, with application: ResolvedApplication?) async throws
}

enum QuicklinkOpenWith {
    /// Resolves an imported or legacy `openWith` value: a bundle identifier
    /// (`com.apple.finder`), an app name (`Finder`, as Raycast exports write it) or
    /// a path to an `.app` bundle.
    static func resolve(_ value: String, using resolver: some ApplicationResolving) -> ResolvedApplication? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else { return nil }
        if trimmed.hasSuffix(".app") {
            let name = (trimmed as NSString).lastPathComponent.dropLast(4)
            return resolver.application(named: String(name))
        }
        if isBundleIdentifier(trimmed), let app = resolver.application(bundleIdentifier: trimmed) { return app }
        return resolver.application(named: trimmed)
    }

    static func isBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
    }
}

/// Resolves apps through Launch Services and the standard application folders.
/// It only reads bundle metadata.
struct WorkspaceApplicationResolver: ApplicationResolving {
    static let searchFolders = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        "/System/Library/CoreServices", "/System/Cryptexes/App/System/Applications",
        NSHomeDirectory() + "/Applications",
    ]

    func application(bundleIdentifier: String) -> ResolvedApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return Self.application(at: url)
    }

    func application(named name: String) -> ResolvedApplication? {
        guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
        for folder in Self.searchFolders {
            let url = URL(fileURLWithPath: folder).appending(path: name + ".app", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: url.path), let app = Self.application(at: url) { return app }
        }
        return nil
    }

    private static func application(at url: URL) -> ResolvedApplication? {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return nil }
        let name =
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return ResolvedApplication(bundleIdentifier: identifier, name: name, url: url)
    }
}

enum QuicklinkOpeners {
    /// The opener the app should use: an inert one in the test host and in
    /// verification runs, the workspace otherwise.
    @MainActor static func makeDefault(sideEffects: SideEffectGuard = .current) -> any QuicklinkOpening {
        sideEffects.isInert ? InertQuicklinkOpener(sideEffects: sideEffects) : WorkspaceQuicklinkOpener(sideEffects: sideEffects)
    }
}

/// Refuses to open anything.
struct InertQuicklinkOpener: QuicklinkOpening {
    var sideEffects = SideEffectGuard.current

    func open(_ url: URL, with application: ResolvedApplication?) async throws {
        throw SideEffectGuard.Blocked(what: "opening links and apps", mode: sideEffects.mode)
    }
}

/// Opens links with NSWorkspace, in the chosen app or the default handler.
struct WorkspaceQuicklinkOpener: QuicklinkOpening {
    var sideEffects = SideEffectGuard.current

    func open(_ url: URL, with application: ResolvedApplication?) async throws {
        try sideEffects.check("opening links and apps")
        let configuration = NSWorkspace.OpenConfiguration()
        if let application {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: application.url, configuration: configuration)
        } else {
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
        }
    }
}
