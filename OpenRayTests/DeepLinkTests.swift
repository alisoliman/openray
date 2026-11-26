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
            CommandDescriptor(
                id: "linktest.secret", title: "Use Token", subtitle: "", kind: .command, symbol: "key",
                arguments: [ArgumentSpec(name: "token", placeholder: "Token", type: .password)], mode: .noView),
        ]
    }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        runs.append(ref.arguments)
    }
}


@Suite("Deeplinks")
@MainActor
struct DeepLinkTests {
    let browser = DeepLinkSource(bundleID: "com.example.browser", name: "Browser")

    static let start = Date(timeIntervalSinceReferenceDate: 1_000)

    /// A launcher whose prompt clock and panel surface the test drives (Slice 1's hooks).
    func harness(extra: [any CommandProvider] = []) -> (LauncherModel, DeepLinkRouter, LinkTargetProvider, NSPasteboard, Date) {
        let target = LinkTargetProvider()
        let router = DeepLinkRouter()
        let pasteboard = NSPasteboard.withUniqueName()
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: pasteboard, registry: CommandRegistry(providers: [target, router] + extra))
        let start = Self.start
        model.promptClock = { start }
        model.confirmationSurfaceVisibleSince = { start }
        return (model, router, target, pasteboard, start)
    }

    func isAsked(_ outcome: DeepLinkOutcome) -> Bool {
        if case .asked = outcome { return true }
        return false
    }

    func failure(_ outcome: DeepLinkOutcome) -> String? {
        if case .failed(let message) = outcome { return message }
        return nil
    }

    /// Answers the question as a person would: an action bar draws it, it stays up for the
    /// minimum exposure, and a fresh Return arrives (`LauncherPanel`'s path).
    func pressReturn(_ model: LauncherModel) {
        guard let instance = model.confirmationInstanceID else { return }
        let shown = model.promptClock()
        model.confirmationDidAppear(instance)
        let later = shown.addingTimeInterval(LauncherModel.minimumPromptExposure)
        model.promptClock = { later }
        _ = model.confirmFromReturn(isRepeat: false, pressedAt: later)
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

    @Test("Bad links are refused with a reason, and huge durations never crash")
    func parseFailures() {
        for text in [
            "https://commands/x", "openray://commands/", "openray://unknown/thing",
            "openray://commands/x?arguments=not-json", "openray://commands/x?arguments=%7B%22a%22%3A%5B1%5D%7D",
            "openray://commands/x?arguments=%7B%22a%22%3A%22b%5Cu0000c%22%7D", "openray://commands/x?fallbackText=a%00b",
            "openray://focus/stop", "openray://focus/start?duration=soon",
            "openray://focus/start?duration=9223372036854775807", "openray://focus/start?duration=1441",
            "openray://focus/start?duration=0", "openray://focus/start?duration=48h",
            "openray://focus/start?duration=99999999999999999999d",
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
        let (model, _, _, pasteboard, _) = harness()
        for id in ["section.files", "ai.chat", "settings", "window.leftHalf", "linktest.plain", "linktest.greet"] {
            let item = try #require(model.commandItems.first { $0.id == id }, "\(id)")
            let entries = model.actions(for: item).map(\.id)
            // Greet takes a password, so links always ask for it and it has no such switch.
            #expect(entries.contains("deeplinkTrust") == (id != "linktest.greet"), "\(id)")
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

    // MARK: The question

    @Test("A link always asks first, as a question bound to it, with passwords and the query hidden")
    func asks() throws {
        let (model, router, target, _, _) = harness()
        let url = DeepLink.url(forCommandID: "linktest.greet", arguments: ["name": "Ada", "token": "s3cret"])!
        #expect(isAsked(router.handle(url, source: browser, in: model)))
        let request = try #require(router.pending)
        #expect(request.title == "Greet Someone")
        #expect(target.runs.isEmpty)
        #expect(model.section.providedScope?.id == DeepLinkRouter.confirmScope.id)
        #expect(model.results.map(\.id) == ["deeplink.question", "deeplink.cancel"])
        guard case .provided(let question)? = model.confirmation else {
            Issue.record("Expected the link's question")
            return
        }
        #expect(question.id == "deeplink.\(request.id.uuidString)")
        #expect(question.isDestructive, "Link questions need visible approval")
        #expect(question.question.contains("Greet Someone"))
        #expect(!question.detail.contains("s3cret"))
        #expect(question.detail.contains("Browser"))
        let preview = try #require(router.preview(for: model.results[0], ref: ProvidedRef(provider: "deeplink", id: "ask"), in: model))
        let metadata = Dictionary(uniqueKeysWithValues: preview.metadata.map { ($0.label, $0.value) })
        #expect(metadata["Command"] == "Greet Someone")
        #expect(metadata["Asked by"] == "Browser")
        #expect(metadata["Name"] == "Ada")
        #expect(metadata["Token"] == "••••••")
        #expect(metadata["Link"] == "openray://commands/linktest.greet")
        #expect(!preview.metadata.contains { $0.value.contains("s3cret") })
    }

    @Test("Fallback text filling a password argument is masked too, and runs as that argument")
    func fallbackPassword() throws {
        let (model, router, target, _, _) = harness()
        router.handle(URL(string: "openray://commands/linktest.secret?fallbackText=hunter2")!, source: browser, in: model)
        let request = try #require(router.pending)
        #expect(request.arguments == ["token": "hunter2"])
        #expect(request.fallbackFillsArgument)
        #expect(request.displayedArguments.map(\.label) == ["Token"])
        #expect(request.displayedArguments.map(\.value) == ["••••••"])
        guard case .provided(let question)? = model.confirmation else {
            Issue.record("Expected the link's question")
            return
        }
        #expect(!question.detail.contains("hunter2"))
        let preview = try #require(router.preview(for: model.results[0], ref: ProvidedRef(provider: "deeplink", id: "ask"), in: model))
        #expect(!preview.metadata.contains { $0.value.contains("hunter2") })
        pressReturn(model)
        #expect(target.runs == [["token": "hunter2"]])
    }

    @Test("Only a fresh Return, after the question was drawn and shown long enough, uncovered, answers it")
    func visibleApproval() throws {
        let (model, router, target, _, start) = harness()
        router.handle(DeepLink.url(forCommandID: "linktest.plain")!, source: browser, in: model)
        let instance = try #require(model.confirmationInstanceID)
        // No action bar has drawn it (as when onboarding covers the panel): Return can't answer it.
        #expect(model.confirmFromReturn(isRepeat: false, pressedAt: start.addingTimeInterval(5)))
        #expect(target.runs.isEmpty)
        model.confirmationDidAppear(instance)
        // Too soon after it was drawn.
        #expect(model.confirmFromReturn(isRepeat: false, pressedAt: start.addingTimeInterval(0.1)))
        let later = start.addingTimeInterval(1)
        model.promptClock = { later }
        // A held Return never answers.
        #expect(model.confirmFromReturn(isRepeat: true, pressedAt: later))
        // Nor while the panel isn't on screen.
        model.confirmationSurfaceVisibleSince = { nil }
        #expect(model.confirmFromReturn(isRepeat: false, pressedAt: later))
        #expect(target.runs.isEmpty)
        #expect(router.pending != nil)
        model.confirmationSurfaceVisibleSince = { start }
        #expect(model.confirmFromReturn(isRepeat: false, pressedAt: later))
        #expect(target.runs.count == 1)
        #expect(router.pending == nil)
        #expect(model.section == .home)
    }

    @Test("The Run button answers only the question it drew; a newer link's question isn't it")
    func buttonBoundToInstance() throws {
        let (model, router, target, _, start) = harness()
        router.handle(DeepLink.url(forCommandID: "linktest.plain")!, source: browser, in: model)
        let first = try #require(model.confirmationInstanceID)
        model.confirmationDidAppear(first)
        let later = start.addingTimeInterval(1)
        model.promptClock = { later }
        router.handle(DeepLink.url(forCommandID: "linktest.greet", arguments: ["name": "Eve"])!, source: browser, in: model)
        model.approveConfirmation(id: first)
        #expect(target.runs.isEmpty)
        #expect(router.pending?.commandID == "linktest.greet")
        let second = try #require(model.confirmationInstanceID)
        #expect(second != first)
    }

    @Test("A newer link replaces the question; an answer bound to the old one can't run either command")
    func superseded() throws {
        let (model, router, target, _, _) = harness()
        router.handle(DeepLink.url(forCommandID: "linktest.plain")!, source: browser, in: model)
        let first = try #require(model.confirmation)
        router.handle(DeepLink.url(forCommandID: "linktest.greet", arguments: ["name": "Eve"])!, source: browser, in: model)
        // An answer bound to the first question arrives late.
        model.confirm(first)
        #expect(target.runs.isEmpty)
        #expect(router.pending?.commandID == "linktest.greet")
    }

    @Test("Esc dismisses the question; ↩ on its row asks again rather than running")
    func dismissedQuestion() {
        let (model, router, target, _, _) = harness()
        router.handle(DeepLink.url(forCommandID: "linktest.plain")!, source: browser, in: model)
        model.goBack()
        #expect(model.confirmation == nil)
        model.perform(model.results[0])
        #expect(target.runs.isEmpty)
        #expect(model.confirmation != nil)
        pressReturn(model)
        #expect(target.runs.count == 1)
    }

    @Test("Approving runs the command with the link's arguments; fallback text fills the first one")
    func runsWithArguments() {
        let (model, router, target, _, _) = harness()
        router.handle(DeepLink.url(forCommandID: "linktest.greet", arguments: ["name": "Ada"])!, source: browser, in: model)
        pressReturn(model)
        #expect(target.runs == [["name": "Ada"]])
        router.handle(URL(string: "openray://commands/linktest.greet?fallbackText=Grace")!, source: browser, in: model)
        pressReturn(model)
        #expect(target.runs.last == ["name": "Grace"])
    }

    @Test("Don't Run drops the link and nothing runs")
    func cancel() {
        let (model, router, target, _, _) = harness()
        router.handle(DeepLink.url(forCommandID: "linktest.plain")!, source: browser, in: model)
        model.goBack()
        model.perform(model.results[1])
        #expect(target.runs.isEmpty)
        #expect(router.pending == nil)
        #expect(model.section == .home)
    }

    // MARK: Trust

    @Test("Only the command's own ⌘K lets links run it without asking, on this Mac, from any app")
    func trustFromCommand() throws {
        let (model, router, target, _, _) = harness()
        let url = DeepLink.url(forCommandID: "linktest.plain")!
        #expect(isAsked(router.handle(url, source: browser, in: model)))
        router.cancel(in: model)
        let item = try #require(model.commandItems.first { $0.id == "linktest.plain" })
        let allow = try #require(model.actions(for: item).first { $0.id == "deeplinkTrust" })
        #expect(allow.title == "Run from Links Without Asking")
        allow.perform()
        #expect(LocalApprovalStore.for(model.store).linksRunWithoutAsking("linktest.plain"))
        // Kept beside the library on this Mac, never in the library itself.
        #expect(model.store.database.commandPreferences["linktest.plain"] == nil)
        #expect(router.handle(url, source: .unknown, in: model) == .ran(commandID: "linktest.plain"))
        #expect(target.runs.count == 1)
        // Other commands still ask.
        #expect(isAsked(router.handle(DeepLink.url(forCommandID: "linktest.greet")!, source: browser, in: model)))
        router.cancel(in: model)
        let revoke = try #require(model.actions(for: item).first { $0.id == "deeplinkTrust" })
        #expect(revoke.title == "Ask Before Running from Links")
        revoke.perform()
        #expect(isAsked(router.handle(url, source: browser, in: model)))
    }

    @Test("A grant an older build stored in the library is ignored")
    func legacyGrantIgnored() {
        let (model, router, _, _, _) = harness()
        model.store.update { $0.commandPreferences["linktest.plain"] = [DeepLinkRouter.legacyTrustKey: "com.example.browser"] }
        #expect(isAsked(router.handle(DeepLink.url(forCommandID: "linktest.plain")!, source: browser, in: model)))
    }

    @Test("A command's own confirmation still asks after the link is approved")
    func commandConfirmationStillAsks() throws {
        let (model, router, target, _, _) = harness()
        target.asksFirst = true
        router.handle(DeepLink.url(forCommandID: "linktest.greet", arguments: ["name": "Ada"])!, source: browser, in: model)
        pressReturn(model)
        #expect(target.runs.isEmpty)
        let confirmation = try #require(model.confirmation)
        #expect(confirmation.question == "Greet?")
        model.confirm(confirmation)
        #expect(target.runs == [["name": "Ada"]])
    }

    @Test("Unknown, disabled and focus links explain why they can't run")
    func failures() {
        let (model, router, target, _, _) = harness()
        let unknown = failure(router.handle(URL(string: "openray://commands/nope.nothing")!, source: browser, in: model))
        #expect(unknown?.contains("isn't available") == true)
        #expect(model.feedback?.style == .error)
        model.store.update { $0.disabledCommandIDs.insert("linktest.plain") }
        let disabled = failure(router.handle(DeepLink.url(forCommandID: "linktest.plain")!, source: browser, in: model))
        #expect(disabled?.contains("turned off") == true)
        #expect(failure(router.handle(URL(string: "openray://focus/start?goal=x")!, source: browser, in: model)) != nil)
        #expect(failure(router.handle(URL(string: "openray://nope")!, source: browser, in: model)) != nil)
        #expect(target.runs.isEmpty)
    }

    @Test("A command turned off while its question is up doesn't run")
    func disabledWhileAsking() {
        let (model, router, target, _, _) = harness()
        router.handle(DeepLink.url(forCommandID: "linktest.plain")!, source: browser, in: model)
        model.store.update { $0.disabledCommandIDs.insert("linktest.plain") }
        pressReturn(model)
        #expect(target.runs.isEmpty)
        #expect(model.feedback?.style == .error)
    }

    @Test("Built-in commands open from links, and fallback text fills the scope's search")
    func builtIns() {
        let (model, router, _, _, _) = harness()
        router.handle(URL(string: "openray://commands/section.snippets?fallbackText=sig")!, source: browser, in: model)
        pressReturn(model)
        #expect(model.section == .snippets)
        #expect(model.query == "sig")
    }

    @Test("Links macOS delivers are ignored while OpenRay is inert")
    func inertEntry() {
        let (model, router, target, _, _) = harness()
        DeepLinkRouter.open([DeepLink.url(forCommandID: "linktest.plain")!], source: browser, in: model)
        #expect(router.pending == nil)
        #expect(target.runs.isEmpty)
        #expect(model.feedback?.text.contains("isolated") == true)
    }

    @Test("A script link that arrives before the folders are read waits for them")
    func scriptLinkWaits() async throws {
        let folder = try ScriptFolder()
        let file = try folder.script("hello.sh", title: "Hello Script", body: "echo hi")
        let scripts = ScriptCommandProvider(
            catalog: ScriptCatalog(), runner: ScriptRunner(launcher: CannedScriptLauncher(
                execution: ScriptExecution(termination: .exited(0), output: "", duration: .zero))),
            presenter: RecordingScriptPresenter(), refreshesAutomatically: false)
        let (model, router, _, _, _) = harness(extra: [scripts])
        let record = folder.record
        model.store.update { $0.scriptDirectories = [record] }
        #expect(LocalApprovalStore.for(model.store).approve(record))
        let url = try #require(DeepLink.url(forCommandID: ScriptCommand.id(for: file)))
        #expect(router.handle(url, source: browser, in: model) == .waiting)
        for _ in 0..<50 where router.pending == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(router.pending?.title == "Hello Script")
    }
}

extension DeepLinkTests {
    @Test("Commands that ask first or take a password never run from links without asking")
    func trustScope() throws {
        let (model, router, target, _, _) = harness()
        target.asksFirst = true
        let approvals = LocalApprovalStore.for(model.store)
        for id in ["linktest.greet", "linktest.secret"] {
            let item = try #require(model.commandItems.first { $0.id == id })
            #expect(!DeepLinkRouter.mayRunWithoutAsking(item, in: model), "\(id)")
            #expect(!model.actions(for: item).contains { $0.id == "deeplinkTrust" }, "\(id)")
            // A grant made some other way is never honored.
            approvals.setLinksRunWithoutAsking(true, for: id)
            #expect(isAsked(router.handle(DeepLink.url(forCommandID: id, arguments: ["name": "x", "token": "y"])!, source: browser, in: model)), "\(id)")
            router.cancel(in: model)
            // …but it can still be revoked from ⌘K.
            let revoke = try #require(model.actions(for: item).first { $0.id == "deeplinkTrust" })
            #expect(revoke.title == "Ask Before Running from Links")
            revoke.perform()
            #expect(!approvals.linksRunWithoutAsking(id))
        }
        #expect(target.runs.isEmpty)
    }

    @Test("Fallback text used as a password never lands in the search field of the scope the command opens")
    func noPasswordPrefill() async throws {
        let folder = try ScriptFolder()
        let file = try folder.script(
            "secret.sh", title: "Show Secret", mode: "fullOutput",
            extra: [#"argument1 { "type": "password", "placeholder": "Token" }"#], body: "echo done")
        let scripts = ScriptCommandProvider(
            catalog: ScriptCatalog(), runner: ScriptRunner(launcher: CannedScriptLauncher(
                execution: ScriptExecution(termination: .exited(0), output: "done", duration: .zero))),
            presenter: RecordingScriptPresenter(), refreshesAutomatically: false)
        let (model, router, _, _, _) = harness(extra: [scripts])
        let record = folder.record
        model.store.update { $0.scriptDirectories = [record] }
        LocalApprovalStore.for(model.store).approve(record)
        scripts.synchronize(with: model, synchronously: true)
        let url = try #require(URL(string: "openray://scripts/\(ScriptCommand.id(for: file).dropFirst(7))?fallbackText=hunter2"))
        router.handle(url, source: browser, in: model)
        pressReturn(model)
        #expect(model.section.providedScope?.id == ScriptCommandProvider.outputScope.id)
        #expect(model.query.isEmpty)
        let job = try #require(scripts.runner.jobs.first)
        #expect(job.values == ["argument1": "hunter2"])
        await job.task?.value
    }
}

extension DeepLinkTests {
    @Test("With Slice 6's hook set, a Focus link asks first, then starts the session it describes")
    func focusHook() throws {
        let (model, router, _, _, _) = harness()
        var started: [(goal: String?, duration: Duration?)] = []
        DeepLinkRouter.focusStarter = { goal, duration, _ in started.append((goal, duration)) }
        defer { DeepLinkRouter.focusStarter = nil }
        let url = try #require(URL(string: "openray://focus/start?goal=Write&duration=25"))
        #expect(isAsked(router.handle(url, source: browser, in: model)))
        #expect(started.isEmpty)
        let request = try #require(router.pending)
        #expect(request.displayedArguments.map(\.label) == ["Goal", "Minutes"])
        pressReturn(model)
        #expect(started.count == 1)
        #expect(started.first?.goal == "Write")
        #expect(started.first?.duration == .seconds(1_500))
    }
}

extension DeepLinkTests {
    @Test("A Focus link starts a session through Slice 6's Focus provider, after asking")
    func focusThroughProvider() throws {
        let apps = FakeFocusApps()
        let notices = FakeFocusNotices()
        let controller = FocusController(apps: apps, notices: notices, runsTicker: false)
        let focus = FocusCommandProvider(controller: controller)
        let (model, router, _, _, _) = harness(extra: [focus])
        let url = try #require(URL(string: "openray://focus/start?goal=Write%20the%20report&duration=40"))
        #expect(isAsked(router.handle(url, source: browser, in: model)))
        #expect(controller.session == nil, "Nothing starts before the question is answered")
        pressReturn(model)
        let session = try #require(controller.session)
        #expect(session.configuration.goal == "Write the report")
        #expect(session.configuration.duration == 40 * 60)
        #expect(notices.started.count == 1)
        try controller.complete()

        // Without a duration, no time limit; with Start Focus Session turned off, refused.
        router.handle(try #require(URL(string: "openray://focus/start?goal=Read")), source: browser, in: model)
        pressReturn(model)
        #expect(controller.session?.configuration.duration == nil)
        try controller.complete()
        model.store.update { $0.disabledCommandIDs.insert(FocusCommandProvider.startID) }
        #expect(failure(router.handle(url, source: browser, in: model))?.contains("turned off") == true)
    }
}
