import AppKit
import SwiftUI

// openray:// links. A link names a command and, optionally, its arguments and the text to
// prefill; OpenRay always asks before running it, unless the person chose to always allow
// that command from the app that sent the link.
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
            case let text as String: values[key] = text
            case let number as NSNumber: values[key] = number.stringValue
            case is NSNull: continue
            default: throw Failure("The link's argument “\(key)” isn't text.")
            }
        }
        return values
    }

    /// Minutes as a number (`25`), or a number and unit (`90s`, `25m`, `1h`).
    static func duration(_ text: String?) throws -> Duration? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let minutes = Int(text), minutes > 0 { return .seconds(minutes * 60) }
        if let parsed = ScriptMetadataParser.parseRefreshTime(text) { return parsed }
        throw Failure("The link's duration “\(text)” isn't a number of minutes.")
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

/// The app a link came from, when macOS says.
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
    var arguments: [String: String]
    var fallbackText: String?
    var source: DeepLinkSource
    var background: Bool
    var receivedAt: Date
}

/// What handling a link did.
enum DeepLinkOutcome: Equatable {
    case asked(DeepLinkRequest)
    case ran(commandID: String)
    case failed(String)
}

/// Receives links, asks about them in its own scope, and runs what the person approves.
@MainActor
final class DeepLinkRouter: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(id: "deeplink") { DeepLinkRouter() }
    /// `commandPreferences[commandID][trustKey]`: bundle ids, comma-separated, whose links run that command without asking.
    nonisolated static let trustKey = "allowLinksFrom"
    /// A Return pressed this soon after the question appears doesn't answer it, so a keystroke
    /// meant for another app can't approve a link that opened the panel under it.
    static let decisionDelay: TimeInterval = 0.5

    static let confirmScope = ProvidedScope(
        id: "deeplink.confirm", provider: "deeplink", title: "Open Link", symbol: "link", kind: .command,
        placeholder: "Run this command?", itemNoun: "choice", showsPreview: true, ranksItems: false)

    private(set) var pending: DeepLinkRequest?
    /// The clock decisions are measured with. Tests replace it.
    var now: () -> Date = { .now }

    var id: String { Self.registration.id }

    init() {}

    func commands(in model: LauncherModel) -> [CommandDescriptor] { [] }

    // MARK: Receiving

    /// The delegate's entry point. Links that arrive before the panel exists wait a moment.
    static func open(_ urls: [URL], source: DeepLinkSource, in model: LauncherModel, attempt: Int = 0) {
        guard let router = model.registry.provider(id: registration.id) as? DeepLinkRouter else { return }
        if model.panel == nil, !SideEffectGuard.isInert, attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated { open(urls, source: source, in: model, attempt: attempt + 1) }
            }
            return
        }
        for url in urls { router.handle(url, source: source, in: model) }
    }

    /// Parses a link and either asks about it, runs it (when always allowed), or explains why it can't.
    @discardableResult
    func handle(_ url: URL, source: DeepLinkSource, in model: LauncherModel) -> DeepLinkOutcome {
        let route: DeepLinkRoute
        do { route = try DeepLink.parse(url) } catch { return fail(error.localizedDescription, in: model) }
        switch route {
        case .focus:
            // Slice 6 serves focus sessions; until then the link explains itself.
            return fail("Focus sessions aren't available in this version of OpenRay yet.", in: model)
        case .command(let commandID, let arguments, let fallbackText, let background):
            guard let item = Self.commandItem(withID: commandID, in: model) else {
                return fail("The link's command “\(commandID.truncatedForFeedback)” isn't available.", in: model)
            }
            guard !model.store.database.disabledCommandIDs.contains(commandID) else {
                return fail("“\(item.title.truncatedForFeedback)” is turned off in Settings.", in: model)
            }
            let request = DeepLinkRequest(
                url: url, commandID: commandID, title: item.title, arguments: arguments, fallbackText: fallbackText,
                source: source, background: background, receivedAt: now())
            if isTrusted(source, for: commandID, in: model) {
                run(request, item: item, in: model)
                return .ran(commandID: commandID)
            }
            pending = request
            show(.provided(Self.confirmScope), in: model)
            return .asked(request)
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

    // MARK: Trust

    func trustedSources(for commandID: String, in model: LauncherModel) -> [String] {
        (model.store.database.commandPreferences[commandID]?[Self.trustKey] ?? "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    func isTrusted(_ source: DeepLinkSource, for commandID: String, in model: LauncherModel) -> Bool {
        guard let bundleID = source.bundleID else { return false }
        return trustedSources(for: commandID, in: model).contains(bundleID)
    }

    @discardableResult
    func setTrusted(_ trusted: Bool, bundleID: String, for commandID: String, in model: LauncherModel) -> Bool {
        var sources = trustedSources(for: commandID, in: model).filter { $0 != bundleID }
        if trusted { sources.append(bundleID) }
        return model.store.update { database in
            var preferences = database.commandPreferences[commandID] ?? [:]
            preferences[Self.trustKey] = sources.isEmpty ? nil : sources.joined(separator: ",")
            database.commandPreferences[commandID] = preferences.isEmpty ? nil : preferences
        }
    }

    // MARK: Answering

    enum Choice: String { case run, alwaysAllow, cancel }

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        guard scope.id == Self.confirmScope.id, let request = pending else { return [] }
        let title = request.title.truncatedForFeedback
        var rows = [
            LauncherItem(
                id: "deeplink.run", title: "Run “\(title)”", subtitle: "Asked by \(request.source.name)",
                symbol: "play", kind: .command, badge: "Run Once",
                action: .provided(ProvidedRef(provider: id, id: Choice.run.rawValue, primaryTitle: "Run Command", traits: [])))
        ]
        if request.source.bundleID != nil {
            rows.append(
                LauncherItem(
                    id: "deeplink.always", title: "Always Allow from \(request.source.name)",
                    subtitle: "Run now, and run “\(title)” from \(request.source.name) without asking",
                    symbol: "checkmark.shield", kind: .command, badge: "Allow",
                    action: .provided(
                        ProvidedRef(provider: id, id: Choice.alwaysAllow.rawValue, primaryTitle: "Run and Always Allow", traits: []))))
        }
        rows.append(
            LauncherItem(
                id: "deeplink.cancel", title: "Don't Run", subtitle: "Ignore this link", symbol: "xmark", kind: .command,
                badge: "Cancel",
                action: .provided(ProvidedRef(provider: id, id: Choice.cancel.rawValue, primaryTitle: "Don't Run", traits: []))))
        return rows
    }

    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview? {
        guard let request = pending else { return nil }
        var metadata: [(label: String, value: String)] = [
            ("Command", request.title), ("From", request.source.name),
        ]
        let specs = Self.commandItem(withID: request.commandID, in: model).flatMap { item -> [ArgumentSpec]? in
            guard case .provided(let ref) = item.action else { return nil }
            return model.registry.descriptor(for: ref, in: model)?.arguments
        } ?? []
        for name in request.arguments.keys.sorted() {
            let spec = specs.first { $0.name == name }
            let value = spec?.type == .password ? "••••••" : request.arguments[name] ?? ""
            metadata.append((spec?.placeholder.isEmpty == false ? spec!.placeholder : name, value))
        }
        if let text = request.fallbackText { metadata.append(("Text", text)) }
        metadata.append(("Link", request.url.absoluteString))
        let content = VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "link.circle.fill").font(.system(size: 34)).foregroundStyle(OR.Color.accent)
            Text("\(request.source.name) wants to run “\(request.title)”.").font(OR.Font.headline)
            Text("Links can run commands. Run only what you expected to open.")
                .font(OR.Font.callout).foregroundStyle(OR.Color.text2)
        }
        return ProvidedPreview(content: AnyView(content), metadata: metadata)
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? { ref.primaryTitle }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        guard let choice = Choice(rawValue: ref.id) else { return }
        answer(choice, in: model)
    }

    /// Runs, always allows and runs, or drops the pending link.
    func answer(_ choice: Choice, in model: LauncherModel) {
        guard let request = pending else {
            model.leaveScope()
            return
        }
        if choice != .cancel, now().timeIntervalSince(request.receivedAt) < Self.decisionDelay {
            model.feedback = .info("Press Return again to run “\(request.title.truncatedForFeedback)”.")
            return
        }
        pending = nil
        switch choice {
        case .cancel:
            model.leaveScope()
        case .run, .alwaysAllow:
            guard let item = Self.commandItem(withID: request.commandID, in: model) else {
                _ = fail("The link's command isn't available anymore.", in: model)
                return
            }
            if choice == .alwaysAllow, let bundleID = request.source.bundleID,
                !setTrusted(true, bundleID: bundleID, for: request.commandID, in: model)
            {
                model.feedback = .error(model.store.errorMessage ?? "Couldn't save the change.")
                return
            }
            model.navigate(to: .home)
            run(request, item: item, in: model)
        }
    }

    /// Runs a command with the link's arguments. The command's own confirmation, if any, still asks.
    private func run(_ request: DeepLinkRequest, item: LauncherItem, in model: LauncherModel) {
        var item = item
        if case .provided(var ref) = item.action {
            var arguments = request.arguments
            let specs = model.registry.descriptor(for: ref, in: model)?.arguments ?? []
            if let text = request.fallbackText, let first = specs.first, arguments[first.name] == nil {
                arguments[first.name] = text
            }
            ref.arguments = arguments
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
            model.confirmation = confirmation
        }
        if let text = request.fallbackText, model.section != .home, model.destination == .search, model.query.isEmpty {
            model.query = text
        }
    }
}

extension LauncherModel {
    /// ⌘K's Copy Deeplink, for root commands.
    func deepLinkActions(for item: LauncherItem) -> [ActionEntry] {
        guard let url = DeepLink.url(for: item) else { return [] }
        return [
            ActionEntry(id: "copyDeeplink", title: "Copy Deeplink", symbol: "link", group: .organize) { [weak self] in
                self?.copy(url.absoluteString, label: "Deeplink to \(item.title)")
            }
        ]
    }
}
