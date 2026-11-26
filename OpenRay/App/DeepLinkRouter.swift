import AppKit
import SwiftUI

// openray:// links. A link names a command and, optionally, its arguments and the text to
// prefill. OpenRay always asks before running it, unless the person set that command, from its
// own ⌘K on this Mac, to run from links without asking. That setting never travels in archives.
//
//   openray://commands/<command-id>?arguments=<url-encoded JSON object>&fallbackText=<text>
//   openray://scripts/<script hash or id>
//   openray://window/<name>   = openray://commands/window.<name>
//   openray://system/<name>   = openray://commands/system.<name>
//   openray://focus/start?goal=<text>&duration=<minutes or 25m, 1h>
//
// The query parameters follow the public deeplink format at
// developers.raycast.com/information/lifecycle/deeplinks: `arguments`, `fallbackText` and
// `launchType` (`background` runs an allowed no-view command without showing the panel).

/// What a link asks for.
enum DeepLinkRoute: Equatable, Sendable {
    case command(id: String, arguments: [String: String], fallbackText: String?, background: Bool)
    /// Starts a focus session. Served once focus sessions exist (Slice 6).
    case focus(goal: String?, duration: Duration?)
}

enum DeepLink {
    static let scheme = "openray"

    struct Failure: LocalizedError, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func parse(_ url: URL) throws -> DeepLinkRoute {
        guard url.scheme?.lowercased() == scheme,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw Failure("That isn't an OpenRay link.") }
        let host = (components.host ?? "").lowercased()
        let path = components.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
        let fallbackText = query["fallbackText"].flatMap { $0.isEmpty ? nil : $0 }
        if fallbackText?.contains("\0") == true { throw Failure("The link's text contains a NUL character.") }
        let background = query["launchType"]?.lowercased() == "background"

        func command(_ id: String) throws -> DeepLinkRoute {
            guard !id.isEmpty, id.count <= 200, !id.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw Failure("The link doesn't name a command.")
            }
            return .command(
                id: id, arguments: try arguments(query["arguments"]), fallbackText: fallbackText, background: background)
        }

        switch host {
        case "commands", "command":
            return try command(path.joined(separator: "/"))
        case "scripts", "script":
            let name = path.joined(separator: "/")
            return try command(name.hasPrefix(ScriptCommand.idPrefix) ? name : ScriptCommand.idPrefix + name)
        case "window", "system":
            guard let name = path.first else { throw Failure("The link doesn't name a command.") }
            return try command("\(host).\(name)")
        case "focus":
            guard path.first?.lowercased() == "start" else { throw Failure("OpenRay doesn't know the link “\(url.absoluteString)”.") }
            return .focus(goal: query["goal"].flatMap { $0.isEmpty ? nil : $0 }, duration: try duration(query["duration"]))
        default:
            throw Failure("OpenRay doesn't know the link “\(url.absoluteString.truncatedForFeedback)”.")
        }
    }

    /// `arguments`: a JSON object of names to values. Numbers and booleans become text.
    static func arguments(_ json: String?) throws -> [String: String] {
        guard let json, !json.isEmpty else { return [:] }
        guard let data = json.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw Failure("The link's arguments aren't a JSON object.") }
        var values: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let text as String:
                // C strings end at NUL, so a script would receive less than the link shows.
                guard !text.contains("\0") else { throw Failure("The link's argument “\(key)” contains a NUL character.") }
                values[key] = text
            case let number as NSNumber: values[key] = number.stringValue
            case is NSNull: continue
            default: throw Failure("The link's argument “\(key)” isn't text.")
            }
        }
        return values
    }

    /// The longest duration a link may ask for.
    static let maximumDuration: Duration = .seconds(24 * 3_600)

    /// Minutes as a number (`25`), or a number and unit (`90s`, `25m`, `1h`), up to a day.
    static func duration(_ text: String?) throws -> Duration? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let invalid = Failure("The link's duration “\(text.truncatedForFeedback)” isn't between a minute and a day.")
        if let minutes = Int(text) {
            guard (1...1_440).contains(minutes) else { throw invalid }
            return .seconds(minutes * 60)
        }
        guard text.count <= 12, let parsed = ScriptMetadataParser.parseRefreshTime(text) else { throw invalid }
        guard parsed <= maximumDuration else { throw invalid }
        return parsed
    }

    /// The link that runs a command.
    static func url(forCommandID id: String, arguments: [String: String] = [:]) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        let hex = id.dropFirst(ScriptCommand.idPrefix.count)
        if id.hasPrefix(ScriptCommand.idPrefix), hex.count == 16, hex.allSatisfy(\.isHexDigit) {
            components.host = "scripts"
            components.path = "/" + hex
        } else {
            components.host = "commands"
            components.path = "/" + id
        }
        if !arguments.isEmpty, let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) {
            components.queryItems = [URLQueryItem(name: "arguments", value: String(decoding: data, as: UTF8.self))]
        }
        return components.url
    }

    /// Copy Deeplink's link for a root command row; nil for anything else.
    static func url(for item: LauncherItem) -> URL? {
        guard item.isBuiltInCommand, !item.id.hasPrefix("fallback."), !item.id.hasPrefix("argument.") else { return nil }
        if case .provided(let ref) = item.action, ref.provider == DeepLinkRouter.registration.id { return nil }
        return url(forCommandID: item.id)
    }
}

/// The app a link came from, when macOS says. Shown so the person knows who's asking; it never
/// authorizes anything, since a bundle identifier doesn't prove which code sent the link.
struct DeepLinkSource: Hashable, Sendable {
    var bundleID: String?
    var name: String

    static let unknown = DeepLinkSource(bundleID: nil, name: "another app")

    /// The sender of the Apple event being handled, which is how macOS delivers opened URLs.
    @MainActor
    static func currentAppleEventSender() -> DeepLinkSource {
        // keySenderPIDAttr, 'spid'.
        let senderPID = AEKeyword(0x7370_6964)
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
            let descriptor = event.attributeDescriptor(forKeyword: senderPID),
            let app = NSRunningApplication(processIdentifier: pid_t(descriptor.int32Value)),
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return .unknown }
        return DeepLinkSource(bundleID: app.bundleIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "another app")
    }
}

/// A command a link asked to run, waiting for an answer.
struct DeepLinkRequest: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var commandID: String
    var title: String
    /// The values the command will receive: the link's arguments, with its fallback text in the
    /// first argument when that one has none. Shown and run from this one place.
    var arguments: [String: String]
    /// The command's declared arguments, for labels and for masking passwords.
    var specs: [ArgumentSpec]
    var fallbackText: String?
    /// True when the fallback text became the first argument's value.
    var fallbackFillsArgument = false
    var source: DeepLinkSource
    var background: Bool

    /// The link without its query, which can hold argument values.
    var displayLink: String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? "\(DeepLink.scheme)://"
    }

    /// The arguments as the question shows them: declared ones first, in order, with passwords masked.
    var displayedArguments: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        for spec in specs {
            guard let value = arguments[spec.name] else { continue }
            rows.append((spec.placeholder.isEmpty ? spec.name : spec.placeholder, spec.type == .password ? "••••••" : value))
        }
        let declared = Set(specs.map(\.name))
        for name in arguments.keys.sorted() where !declared.contains(name) {
            rows.append((name, arguments[name] ?? ""))
        }
        if let fallbackText, !fallbackFillsArgument { rows.append(("Text", fallbackText)) }
        return rows
    }

    static func == (lhs: DeepLinkRequest, rhs: DeepLinkRequest) -> Bool { lhs.id == rhs.id }
}

/// What handling a link did.
enum DeepLinkOutcome: Equatable {
    case asked(DeepLinkRequest)
    case ran(commandID: String)
    case failed(String)
    /// The link names a script, and the script folders haven't been read yet. It's handled after.
    case waiting
}

/// Receives links, asks about them, and runs what the person approves.
@MainActor
final class DeepLinkRouter: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(id: "deeplink") { DeepLinkRouter() }
    /// An older build kept a per-app grant here. Imports strip it; nothing reads it.
    nonisolated static let legacyTrustKey = "allowLinksFrom"

    static let confirmScope = ProvidedScope(
        id: "deeplink.confirm", provider: "deeplink", title: "Open Link", symbol: "link", kind: .command,
        placeholder: "Run this command?", itemNoun: "choice", showsPreview: true, ranksItems: false)

    private(set) var pending: DeepLinkRequest?

    var id: String { Self.registration.id }

    init() {}

    func commands(in model: LauncherModel) -> [CommandDescriptor] { [] }

    // MARK: Focus (Slice 6 hook)

    /// Starts a focus session for `openray://focus/start?goal=…&duration=…`, once asked and
    /// approved. Slice 6 sets it at launch; while it's nil, Focus links say Focus isn't available.
    static var focusStarter: (@MainActor (_ goal: String?, _ duration: Duration?, _ model: LauncherModel) -> Void)?

    /// The id a Focus link's request carries in place of a command.
    static let focusCommandID = "focus.start"

    static func focusRequest(url: URL, goal: String?, duration: Duration?, source: DeepLinkSource) -> DeepLinkRequest {
        var arguments: [String: String] = [:]
        if let goal { arguments["Goal"] = goal }
        if let duration { arguments["Minutes"] = String(Int(duration.timeInterval / 60)) }
        return DeepLinkRequest(
            url: url, commandID: focusCommandID, title: "Start Focus", arguments: arguments, specs: [],
            fallbackText: nil, source: source, background: false)
    }

    // MARK: Receiving

    /// The delegate's entry point. Links that arrive before the panel exists wait a moment.
    /// Inert launches (tests, verification) never act on links macOS delivers.
    static func open(_ urls: [URL], source: DeepLinkSource, in model: LauncherModel, attempt: Int = 0) {
        guard let router = model.registry.provider(id: registration.id) as? DeepLinkRouter else { return }
        guard !SideEffectGuard.isInert else {
            model.feedback = .info("Links don't run in this isolated instance of OpenRay.")
            return
        }
        if model.panel == nil, attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated { open(urls, source: source, in: model, attempt: attempt + 1) }
            }
            return
        }
        for url in urls { router.handle(url, source: source, in: model) }
    }

    /// Parses a link and asks about it, runs it (when its command runs from links without
    /// asking), or explains why it can't.
    @discardableResult
    func handle(_ url: URL, source: DeepLinkSource, in model: LauncherModel) -> DeepLinkOutcome {
        let route: DeepLinkRoute
        do { route = try DeepLink.parse(url) } catch { return fail(error.localizedDescription, in: model) }
        switch route {
        case .focus(let goal, let duration):
            // Slice 6 hook: Focus sets `DeepLinkRouter.focusStarter`. Until it does, the link
            // explains itself. A Focus link asks first like any other; see `startFocus`.
            guard Self.focusStarter != nil else {
                return fail("Focus sessions aren't available in this version of OpenRay yet.", in: model)
            }
            return .asked(ask(Self.focusRequest(url: url, goal: goal, duration: duration, source: source), in: model))
        case .command(let commandID, let arguments, let fallbackText, let background):
            guard let item = Self.commandItem(withID: commandID, in: model) else {
                if let scripts = Self.scriptCatalogStillLoading(for: commandID, in: model) {
                    scripts.whenLoaded { [weak self, weak model] in
                        guard let self, let model else { return }
                        self.handle(url, source: source, in: model)
                    }
                    return .waiting
                }
                return fail("The link's command “\(commandID.truncatedForFeedback)” isn't available.", in: model)
            }
            guard !model.store.database.disabledCommandIDs.contains(commandID) else {
                return fail("“\(item.title.truncatedForFeedback)” is turned off in Settings.", in: model)
            }
            let specs = Self.argumentSpecs(of: item, in: model)
            var values = arguments
            var filled = false
            if let text = fallbackText, let first = specs.first, values[first.name] == nil {
                values[first.name] = text
                filled = true
            }
            let request = DeepLinkRequest(
                url: url, commandID: commandID, title: item.title, arguments: values, specs: specs,
                fallbackText: fallbackText, fallbackFillsArgument: filled, source: source, background: background)
            if LocalApprovalStore.for(model.store).linksRunWithoutAsking(commandID),
                Self.mayRunWithoutAsking(item, in: model)
            {
                run(request, item: item, in: model)
                return .ran(commandID: commandID)
            }
            return .asked(ask(request, in: model))
        }
    }

    /// Shows the question through the launcher's confirmation (Slice 1's `presentConfirmation`).
    /// Link questions are always `isDestructive`: a command asked for from outside is risky, so
    /// the launcher's visible-approval rule applies. Return answers only a prompt instance an
    /// action bar has drawn uncovered on the visible, key panel (never one hidden by onboarding,
    /// ⌘K or ⌘/), with a fresh press made after it had been shown long enough; the button answers
    /// only the instance it drew. A newer link replaces an older one still waiting, and the older
    /// one's answer can't run the newer command: each question is bound to its own request.
    private func ask(_ request: DeepLinkRequest, in model: LauncherModel) -> DeepLinkRequest {
        show(.provided(Self.confirmScope), in: model)
        pending = request
        model.selectedID = "deeplink.question"
        model.presentConfirmation(.provided(confirmation(for: request, in: model)))
        return request
    }

    private func confirmation(for request: DeepLinkRequest, in model: LauncherModel) -> ProvidedConfirmation {
        var detail = "Asked by \(request.source.name)."
        let shown = request.displayedArguments.map { "\($0.label): \($0.value)" }
        if !shown.isEmpty { detail += " " + shown.joined(separator: " · ") }
        return ProvidedConfirmation(
            id: "deeplink.\(request.id.uuidString)",
            CommandConfirmation(
                question: "Run “\(request.title.truncatedForFeedback)” from a link?", detail: detail, confirmTitle: "Run",
                symbol: "link", isDestructive: true)
        ) { [weak self, weak model] in
            guard let self, let model else { return }
            self.approve(request.id, in: model)
        }
    }

    private func fail(_ message: String, in model: LauncherModel) -> DeepLinkOutcome {
        show(.home, in: model)
        model.feedback = .error(message)
        return .failed(message)
    }

    private func show(_ section: LauncherSection, in model: LauncherModel) {
        if let panel = model.panel {
            panel.show(section: section)
        } else {
            model.navigate(to: section)
        }
    }

    /// A command row by id: shown commands, hidden ones, and rows providers rebuild.
    static func commandItem(withID id: String, in model: LauncherModel) -> LauncherItem? {
        let candidates = model.commandItems + model.registry.hiddenCommandItems(in: model)
        let item = candidates.first { $0.id == id } ?? model.registry.item(withID: id, in: model)
        guard let item, item.isBuiltInCommand, DeepLink.url(for: item) != nil else { return nil }
        return item
    }

    /// Whether a command may ever run from links without asking. Commands that ask before they
    /// run (destructive ones, scripts with `needsConfirmation`) and commands that take a password
    /// always ask, whatever was granted.
    static func mayRunWithoutAsking(_ item: LauncherItem, in model: LauncherModel) -> Bool {
        guard case .provided(let ref) = item.action else { return true }
        guard let descriptor = model.registry.descriptor(for: ref, in: model) else { return false }
        return descriptor.confirmation == nil && !descriptor.arguments.contains { $0.type == .password }
    }

    static func argumentSpecs(of item: LauncherItem, in model: LauncherModel) -> [ArgumentSpec] {
        guard case .provided(let ref) = item.action else { return [] }
        return model.registry.descriptor(for: ref, in: model)?.arguments ?? []
    }

    /// The script catalog, when the link names a script and the first scan of its folders
    /// hasn't finished (at launch, a link can arrive first).
    private static func scriptCatalogStillLoading(for commandID: String, in model: LauncherModel) -> ScriptCatalog? {
        guard commandID.hasPrefix(ScriptCommand.idPrefix),
            let scripts = model.registry.provider(id: ScriptCommandProvider.registration.id) as? ScriptCommandProvider,
            !scripts.catalog.hasLoaded
        else { return nil }
        scripts.synchronize(with: model)
        return scripts.catalog.hasLoaded ? nil : scripts.catalog
    }

    // MARK: Answering

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        guard scope.id == Self.confirmScope.id, let request = pending else { return [] }
        let title = request.title.truncatedForFeedback
        return [
            LauncherItem(
                id: "deeplink.question", title: "Run “\(title)”?", subtitle: "Asked by \(request.source.name)",
                symbol: "link", kind: .command, badge: "Link",
                action: .provided(ProvidedRef(provider: id, id: "ask", primaryTitle: "Review", traits: []))),
            LauncherItem(
                id: "deeplink.cancel", title: "Don't Run", subtitle: "Ignore this link", symbol: "xmark", kind: .command,
                badge: "Cancel",
                action: .provided(ProvidedRef(provider: id, id: "cancel", primaryTitle: "Don't Run", traits: []))),
        ]
    }

    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview? {
        guard let request = pending else { return nil }
        var metadata: [(label: String, value: String)] = [("Command", request.title), ("Asked by", request.source.name)]
        metadata += request.displayedArguments
        metadata.append(("Link", request.displayLink))
        let content = VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "link.circle.fill").font(.system(size: 34)).foregroundStyle(OR.Color.accent)
            Text("\(request.source.name) wants to run “\(request.title)”.").font(OR.Font.headline)
            Text("Links can run commands. Run only what you expected to open. To let this command run from links without asking, use its ⌘K menu.")
                .font(OR.Font.callout).foregroundStyle(OR.Color.text2)
        }
        return ProvidedPreview(content: AnyView(content), metadata: metadata)
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? { ref.primaryTitle }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        switch ref.id {
        case "cancel": cancel(in: model)
        default:
            // The question was dismissed with esc; ↩ on the row asks it again, and the answer
            // still needs a fresh key press.
            guard let request = pending else { return model.leaveScope() }
            _ = ask(request, in: model)
        }
    }

    /// Drops the pending link.
    func cancel(in model: LauncherModel) {
        pending = nil
        model.confirmation = nil
        model.leaveScope()
    }

    /// The question's answer, once the launcher's visible-approval rule has allowed it. It runs
    /// only the request it was asked for.
    func approve(_ requestID: UUID, in model: LauncherModel) {
        guard let request = pending, request.id == requestID else { return }
        pending = nil
        if request.commandID == Self.focusCommandID, let start = Self.focusStarter {
            model.navigate(to: .home)
            let minutes = request.arguments["Minutes"].flatMap(Int.init)
            start(request.arguments["Goal"], minutes.map { .seconds($0 * 60) }, model)
            return
        }
        guard let item = Self.commandItem(withID: request.commandID, in: model),
            !model.store.database.disabledCommandIDs.contains(request.commandID)
        else {
            _ = fail("The link's command isn't available anymore.", in: model)
            return
        }
        model.navigate(to: .home)
        run(request, item: item, in: model)
    }

    /// Runs a command with the request's arguments. The command's own confirmation, if any, still asks.
    private func run(_ request: DeepLinkRequest, item: LauncherItem, in model: LauncherModel) {
        var item = item
        if case .provided(var ref) = item.action {
            ref.arguments = request.arguments
            item.action = .provided(ref)
        }
        let quiet = request.background && model.runsWithoutPanel(item)
        if !quiet, let panel = model.panel, !panel.isVisible { panel.show() }
        model.selectedID = item.id
        model.perform(item)
        // A background run that has something to say, or a question to ask, brings the panel up.
        // Showing can reset to Home, so both are put back after.
        if quiet, model.feedback != nil || model.confirmation != nil, let panel = model.panel, !panel.isVisible {
            let feedback = model.feedback
            let confirmation = model.confirmation
            panel.show()
            model.feedback = feedback
            if let confirmation { model.presentConfirmation(confirmation) }
        }
        // Fallback text that became an argument (perhaps a password) is never typed into search.
        if let text = request.fallbackText, !request.fallbackFillsArgument, model.section != .home,
            model.destination == .search, model.query.isEmpty
        {
            model.query = text
        }
    }
}

extension LauncherModel {
    /// ⌘K's Copy Deeplink for root commands, and the switch that lets links run the command
    /// without asking. That switch is this Mac's alone and never travels in archives.
    func deepLinkActions(for item: LauncherItem) -> [ActionEntry] {
        guard let url = DeepLink.url(for: item) else { return [] }
        let approvals = LocalApprovalStore.for(store)
        let trusted = approvals.linksRunWithoutAsking(item.id)
        var entries = [
            ActionEntry(id: "copyDeeplink", title: "Copy Deeplink", symbol: "link", group: .organize) { [weak self] in
                self?.copy(url.absoluteString, label: "Deeplink to \(item.title)")
            }
        ]
        // Commands that always ask from links don't offer the switch; one granted earlier can still be revoked.
        guard trusted || DeepLinkRouter.mayRunWithoutAsking(item, in: self) else { return entries }
        entries.append(
            ActionEntry(
                id: "deeplinkTrust", title: trusted ? "Ask Before Running from Links" : "Run from Links Without Asking",
                symbol: trusted ? "lock" : "lock.open", group: .organize
            ) { [weak self] in
                guard let self else { return }
                if approvals.setLinksRunWithoutAsking(!trusted, for: item.id) {
                    self.toast(trusted ? "Links to “\(item.title.truncatedForFeedback)” will ask first"
                        : "Links can run “\(item.title.truncatedForFeedback)” without asking")
                } else {
                    self.feedback = .error(approvals.errorMessage ?? "Couldn't save the change.")
                }
            })
        return entries
    }
}
