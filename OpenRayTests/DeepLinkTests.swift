import AppKit
import Foundation
import Testing

@testable import OpenRay

/// A command a link can target: it records each run and its arguments.
@MainActor
final class LinkTargetProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(id: "linktest", bindablePrefixes: ["linktest."]) {
        LinkTargetProvider()
    }
    var runs: [[String: String]] = []
    var asksFirst = false

    var id: String { "linktest" }
    init() {}

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: "linktest.greet", title: "Greet Someone", subtitle: "Says hello", kind: .command, symbol: "hand.wave",
                arguments: [ArgumentSpec(name: "name", placeholder: "Name"), ArgumentSpec(name: "token", placeholder: "Token", type: .password, isOptional: true)],
                mode: .noView,
                confirmation: asksFirst ? CommandConfirmation(question: "Greet?", detail: "", confirmTitle: "Greet") : nil),
            CommandDescriptor(
                id: "linktest.plain", title: "Plain Command", subtitle: "", kind: .command, symbol: "circle", mode: .noView),
        ]
    }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        runs.append(ref.arguments)
    }
}

@Suite("Deeplinks")
@MainActor
struct DeepLinkTests {
    let safari = DeepLinkSource(bundleID: "com.example.browser", name: "Browser")

    func harness() -> (LauncherModel, DeepLinkRouter, LinkTargetProvider, NSPasteboard) {
        let target = LinkTargetProvider()
        let router = DeepLinkRouter()
        router.now = { Date(timeIntervalSince1970: 1_000) }
        let pasteboard = NSPasteboard.withUniqueName()
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: pasteboard, registry: CommandRegistry(providers: [target, router]))
        return (model, router, target, pasteboard)
    }

    func isAsked(_ outcome: DeepLinkOutcome) -> Bool {
        if case .asked = outcome { return true }
        return false
    }

    func failure(_ outcome: DeepLinkOutcome) -> String? {
        if case .failed(let message) = outcome { return message }
        return nil
    }

    /// Moves the router's clock past the decision delay.
    func later(_ router: DeepLinkRouter, by seconds: TimeInterval = 1) {
        let base = router.pending?.receivedAt ?? .now
        router.now = { base.addingTimeInterval(seconds) }
    }

    // MARK: Parsing

    @Test("Command links carry their arguments and fallback text")
    func parseCommand() throws {
        let url = try #require(
            URL(string: #"openray://commands/linktest.greet?arguments=%7B%22name%22%3A%22Ada%22%2C%22n%22%3A3%7D&fallbackText=hi%20there&launchType=background"#))
        #expect(
            try DeepLink.parse(url)
                == .command(id: "linktest.greet", arguments: ["name": "Ada", "n": "3"], fallbackText: "hi there", background: true))
    }

    @Test("Scripts, window and system links name their commands")
    func parseShortForms() throws {
        #expect(
            try DeepLink.parse(URL(string: "openray://scripts/0123456789abcdef")!)
                == .command(id: "script.0123456789abcdef", arguments: [:], fallbackText: nil, background: false))
        #expect(
            try DeepLink.parse(URL(string: "openray://scripts/script.0123456789abcdef")!)
                == .command(id: "script.0123456789abcdef", arguments: [:], fallbackText: nil, background: false))
        #expect(
            try DeepLink.parse(URL(string: "openray://window/leftHalf")!)
                == .command(id: "window.leftHalf", arguments: [:], fallbackText: nil, background: false))
        #expect(
            try DeepLink.parse(URL(string: "openray://system/lock")!)
                == .command(id: "system.lock", arguments: [:], fallbackText: nil, background: false))
        #expect(
            try DeepLink.parse(URL(string: "openray://focus/start?goal=Write&duration=25")!)
                == .focus(goal: "Write", duration: .seconds(1_500)))
        #expect(try DeepLink.parse(URL(string: "openray://focus/start?duration=1h")!) == .focus(goal: nil, duration: .seconds(3_600)))
    }

    @Test("Bad links are refused with a reason")
    func parseFailures() {
        for text in [
            "https://commands/x", "openray://commands/", "openray://unknown/thing",
            "openray://commands/x?arguments=not-json", "openray://commands/x?arguments=%7B%22a%22%3A%5B1%5D%7D",
            "openray://focus/stop", "openray://focus/start?duration=soon",
        ] {
            #expect(throws: DeepLink.Failure.self, "\(text)") { try DeepLink.parse(URL(string: text)!) }
        }
    }

    @Test("Command links round-trip, and scripts use the short form")
    func links() throws {
        let url = try #require(DeepLink.url(forCommandID: "linktest.greet", arguments: ["name": "Ada Lovelace"]))
        #expect(try DeepLink.parse(url) == .command(id: "linktest.greet", arguments: ["name": "Ada Lovelace"], fallbackText: nil, background: false))
        #expect(DeepLink.url(forCommandID: "script.0123456789abcdef")?.absoluteString == "openray://scripts/0123456789abcdef")
        #expect(DeepLink.url(forCommandID: "script.browse")?.absoluteString == "openray://commands/script.browse")
        #expect(DeepLink.url(forCommandID: "section.files")?.absoluteString == "openray://commands/section.files")
    }

    // MARK: Copy Deeplink

    @Test("Every root command has Copy Deeplink; content rows don't")
    func copyDeeplink() throws {
        let (model, _, _, pasteboard) = harness()
        for id in ["section.files", "ai.chat", "settings", "window.leftHalf", "linktest.greet"] {
            let item = try #require(model.commandItems.first { $0.id == id }, "\(id)")
            let entry = try #require(model.actions(for: item).first { $0.id == "copyDeeplink" }, "\(id)")
            entry.perform()
            #expect(model.feedback?.style == .success)
            let copied = try #require(pasteboard.string(forType: .string))
            #expect(try DeepLink.parse(URL(string: copied)!) == .command(id: id, arguments: [:], fallbackText: nil, background: false))
        }
        let quicklink = try #require(model.quicklinkItems.first)
        #expect(!model.actions(for: quicklink).contains { $0.id == "copyDeeplink" })
        let fallback = LauncherItem(
            id: "fallback.linktest.greet", title: "Greet", subtitle: "", symbol: "circle", badge: "",
            action: .provided(ProvidedRef(provider: "linktest", id: "linktest.greet", traits: [.command])))
        #expect(DeepLink.url(for: fallback) == nil)
    }

    // MARK: Confirmation

    @Test("A link always asks first, showing the command, its source and arguments")
    func asks() throws {
        let (model, router, target, _) = harness()
        let url = DeepLink.url(forCommandID: "linktest.greet", arguments: ["name": "Ada", "token": "s3cret"])!
        let outcome = router.handle(url, source: safari, in: model)
        #expect(isAsked(outcome))
        let request = try #require(router.pending)
        #expect(request.title == "Greet Someone")
        #expect(target.runs.isEmpty)
        #expect(model.section.providedScope?.id == DeepLinkRouter.confirmScope.id)
        #expect(model.results.map(\.id) == ["deeplink.run", "deeplink.always", "deeplink.cancel"])
        let preview = try #require(router.preview(for: model.results[0], ref: ProvidedRef(provider: "deeplink", id: "run"), in: model))
        let metadata = Dictionary(uniqueKeysWithValues: preview.metadata.map { ($0.label, $0.value) })
        #expect(metadata["Command"] == "Greet Someone")
        #expect(metadata["From"] == "Browser")
        #expect(metadata["Name"] == "Ada")
        #expect(metadata["Token"] == "••••••")
    }

    @Test("Return right after the question appears doesn't answer it")
    func decisionDelay() {
        let (model, router, target, _) = harness()
        router.handle(DeepLink.url(forCommandID: "linktest.plain")!, source: safari, in: model)
        router.answer(.run, in: model)
        #expect(target.runs.isEmpty)
        #expect(router.pending != nil)
        later(router)
        router.answer(.run, in: model)
        #expect(target.runs.count == 1)
        #expect(router.pending == nil)
        #expect(model.section == .home)
    }

    @Test("Approving runs the command with the link's arguments; fallback text fills the first one")
    func runsWithArguments() {
        let (model, router, target, _) = harness()
        router.handle(DeepLink.url(forCommandID: "linktest.greet", arguments: ["name": "Ada"])!, source: safari, in: model)
        later(router)
        model.perform(model.results[0])
        #expect(target.runs == [["name": "Ada"]])
        let url = URL(string: "openray://commands/linktest.greet?fallbackText=Grace")!
        router.handle(url, source: safari, in: model)
        later(router)
        router.answer(.run, in: model)
        #expect(target.runs.last == ["name": "Grace"])
    }

    @Test("Don't Run drops the link and nothing runs")
    func cancel() {
        let (model, router, target, _) = harness()
        router.handle(DeepLink.url(forCommandID: "linktest.plain")!, source: safari, in: model)
        later(router)
        router.answer(.cancel, in: model)
        #expect(target.runs.isEmpty)
        #expect(router.pending == nil)
        #expect(model.section == .home)
    }

    @Test("Always Allow trusts that command from that app only")
    func alwaysAllow() {
        let (model, router, target, _) = harness()
        let url = DeepLink.url(forCommandID: "linktest.plain")!
        router.handle(url, source: safari, in: model)
        later(router)
        router.answer(.alwaysAllow, in: model)
        #expect(target.runs.count == 1)
        #expect(router.trustedSources(for: "linktest.plain", in: model) == ["com.example.browser"])
        // The same app's next link runs without asking.
        #expect(router.handle(url, source: safari, in: model) == .ran(commandID: "linktest.plain"))
        #expect(target.runs.count == 2)
        // Another app, or the same app for another command, still asks.
        let other = DeepLinkSource(bundleID: "com.example.other", name: "Other")
        #expect(isAsked(router.handle(url, source: other, in: model)))
        #expect(isAsked(router.handle(DeepLink.url(forCommandID: "linktest.greet")!, source: safari, in: model)))
        #expect(target.runs.count == 2)
        router.setTrusted(false, bundleID: "com.example.browser", for: "linktest.plain", in: model)
        #expect(model.store.database.commandPreferences["linktest.plain"] == nil)
    }

    @Test("A link from an unknown app can't be always allowed")
    func unknownSource() {
        let (model, router, _, _) = harness()
        router.handle(DeepLink.url(forCommandID: "linktest.plain")!, source: .unknown, in: model)
        #expect(model.results.map(\.id) == ["deeplink.run", "deeplink.cancel"])
        #expect(!router.isTrusted(.unknown, for: "linktest.plain", in: model))
    }

    @Test("A command's own confirmation still asks after the link is approved")
    func commandConfirmationStillAsks() throws {
        let (model, router, target, _) = harness()
        target.asksFirst = true
        router.handle(DeepLink.url(forCommandID: "linktest.greet", arguments: ["name": "Ada"])!, source: safari, in: model)
        later(router)
        router.answer(.run, in: model)
        #expect(target.runs.isEmpty)
        let confirmation = try #require(model.confirmation)
        model.confirm(confirmation)
        #expect(target.runs == [["name": "Ada"]])
    }

    @Test("Unknown, disabled and focus links explain why they can't run")
    func failures() {
        let (model, router, target, _) = harness()
        let unknown = failure(router.handle(URL(string: "openray://commands/nope.nothing")!, source: safari, in: model))
        #expect(unknown?.contains("isn't available") == true)
        #expect(model.feedback?.style == .error)
        model.store.update { $0.disabledCommandIDs.insert("linktest.plain") }
        let disabled = failure(router.handle(DeepLink.url(forCommandID: "linktest.plain")!, source: safari, in: model))
        #expect(disabled?.contains("turned off") == true)
        #expect(failure(router.handle(URL(string: "openray://focus/start?goal=x")!, source: safari, in: model)) != nil)
        #expect(failure(router.handle(URL(string: "openray://nope")!, source: safari, in: model)) != nil)
        #expect(target.runs.isEmpty)
    }

    @Test("Built-in commands open from links, and fallback text fills the scope's search")
    func builtIns() {
        let (model, router, _, _) = harness()
        router.handle(URL(string: "openray://commands/section.snippets?fallbackText=sig")!, source: safari, in: model)
        later(router)
        router.answer(.run, in: model)
        #expect(model.section == .snippets)
        #expect(model.query == "sig")
    }

    @Test("Links reach the router through the delegate's entry point")
    func staticEntry() {
        let (model, router, _, _) = harness()
        DeepLinkRouter.open([DeepLink.url(forCommandID: "linktest.plain")!], source: safari, in: model)
        #expect(router.pending?.commandID == "linktest.plain")
    }
}
