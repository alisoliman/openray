import Foundation
import Observation

// Tools the model can call, independent of FoundationModels. Each tool is a spec (what the
// model reads), an executor over one of OpenRay's services (what runs), and a permission.
// `FoundationModelTools.swift` adapts specs to FoundationModels `Tool`s; everything here
// runs and is tested without a model.

/// One input a tool takes. Every value is text, which keeps the generated arguments small.
struct AIToolParameter: Hashable, Sendable {
    var name: String
    var description: String
    var isOptional = false
}

/// A tool the model can call.
struct AIToolSpec: Identifiable, Hashable, Sendable {
    enum Effect: String, Hashable, Sendable {
        /// Reads OpenRay's data or the Mac's, and changes nothing.
        case read
        /// Adds or changes something in OpenRay's library: a note, snippet or quicklink.
        case library
        /// Acts on the Mac outside OpenRay: an event, a window, a script. Runs only in a
        /// normal launch (`SideEffectGuard`).
        case system
    }

    /// The name the model calls it by, such as `searchNotes`. Also the permission key.
    var id: String
    /// The @-mention group it belongs to, such as `notes`.
    var extensionID: String
    var title: String
    var symbol: String
    /// What the model reads: when to call it and what it returns.
    var summary: String
    var parameters: [AIToolParameter] = []
    var effect: Effect = .read

    /// Tools that change something need an approval card unless the person chose Always.
    var isAction: Bool { effect != .read }
}

/// An @-mention group of tools: `@notes` offers searching and creating notes.
struct AIToolExtension: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var symbol: String
    /// Other words that mention it, such as `finder` for files.
    var aliases: [String] = []
    var tools: [AIToolSpec]

    var mention: String { "@" + id }
}

/// When a read-only tool may run without asking. Tools that change something always ask,
/// every call, whatever is stored: a stored `.always` for one of them counts as `.ask`.
enum AIToolPermission: String, CaseIterable, Identifiable, Sendable {
    /// Ask before every call, reads included.
    case ask
    /// Run reads; ask before anything that changes something. The default.
    case auto
    /// Run reads without asking. Never applies to tools that change something.
    case always

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: "Ask"
        case .auto: "Auto"
        case .always: "Always"
        }
    }

    func needsApproval(for spec: AIToolSpec) -> Bool {
        // Writes and actions need a fresh yes each time.
        if spec.isAction { return true }
        return self == .ask
    }

    /// The choices Settings offers for a tool: writes only ever ask.
    static func choices(for spec: AIToolSpec) -> [AIToolPermission] { spec.isAction ? [] : allCases }
}

/// The values the model filled in.
struct AIToolArguments: Hashable, Sendable {
    var values: [String: String]

    init(_ values: [String: String] = [:]) { self.values = values }

    /// The trimmed value, or nil when it's missing or blank.
    subscript(name: String) -> String? {
        let value = values[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

enum AIToolError: LocalizedError, Equatable {
    case unknownTool(String)
    case missingArgument(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "There's no tool named \(name)."
        case .missingArgument(let name): "The \(name) value is missing."
        case .failed(let message): message
        }
    }
}

/// Runs one tool over an OpenRay service.
@MainActor
protocol AIToolExecutor {
    var spec: AIToolSpec { get }
    /// One line for the approval card: “Create a note titled ‘Groceries’”.
    func describe(_ arguments: AIToolArguments) -> String
    /// The text the model reads back.
    func run(_ arguments: AIToolArguments) async throws -> String
}

/// What a FoundationModels tool calls into. The broker is the live one.
protocol AIToolInvoking: Sendable {
    func invoke(toolID: String, arguments: AIToolArguments) async -> String
}

/// A conversation's tools: calls go through the broker with the conversation's current grants.
struct GrantedToolInvoker: AIToolInvoking {
    let broker: AIToolBroker
    let isGranted: @MainActor @Sendable (String) -> Bool

    func invoke(toolID: String, arguments: AIToolArguments) async -> String {
        await broker.invoke(toolID: toolID, arguments: arguments, isGranted: isGranted)
    }
}

/// Where tool permissions live: `commandPreferences["ai"]["tool.<id>"]` in the app.
@MainActor
protocol AIToolPermissionStoring: AnyObject {
    func permission(for toolID: String) -> AIToolPermission?
    func setPermission(_ permission: AIToolPermission?, for toolID: String)
}

/// Permissions kept in memory, for tests and previews.
@MainActor
final class InMemoryToolPermissions: AIToolPermissionStoring {
    var values: [String: AIToolPermission] = [:]
    init(_ values: [String: AIToolPermission] = [:]) { self.values = values }
    func permission(for toolID: String) -> AIToolPermission? { values[toolID] }
    func setPermission(_ permission: AIToolPermission?, for toolID: String) { values[toolID] = permission }
}

/// A call waiting for the person, drawn as a card in the conversation.
struct AIToolApproval: Identifiable, Equatable, Sendable {
    struct Field: Equatable, Sendable {
        var label: String
        var value: String
    }
    var id = UUID()
    var toolID: String
    var title: String
    var symbol: String
    /// What will happen, in one line.
    var detail: String
    var isAction: Bool
    /// Every value the call would use, so a write is approved knowing exactly what it writes.
    var fields: [Field] = []
    /// Always Allow is offered only for read-only tools.
    var offersAlways: Bool { !isAction }
}

enum AIToolDecision: Sendable {
    case allow, alwaysAllow, deny
}

/// One tool call, for the conversation's activity line.
struct AIToolActivity: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case ran, declined, blocked(String), failed(String) }
    var id = UUID()
    var toolID: String
    var title: String
    var detail: String
    var outcome: Outcome
}

/// Runs the tools the model calls: checks the permission, asks with an approval card when
/// needed, refuses system actions where side effects aren't allowed, and returns text the
/// model reads. A refusal is returned as text too, so the model can say what happened.
@MainActor
@Observable
final class AIToolBroker: AIToolInvoking {
    private(set) var pendingApprovals: [AIToolApproval] = []
    private(set) var activity: [AIToolActivity] = []
    @ObservationIgnored private(set) var executors: [String: any AIToolExecutor] = [:]
    @ObservationIgnored let permissions: any AIToolPermissionStoring
    @ObservationIgnored let sideEffects: SideEffectGuard
    @ObservationIgnored private var waiting: [UUID: CheckedContinuation<AIToolDecision, Never>] = [:]

    init(
        executors: [any AIToolExecutor] = [], permissions: (any AIToolPermissionStoring)? = nil,
        sideEffects: SideEffectGuard = .current
    ) {
        self.permissions = permissions ?? InMemoryToolPermissions()
        self.sideEffects = sideEffects
        register(executors)
    }

    func register(_ executors: [any AIToolExecutor]) {
        for executor in executors { self.executors[executor.spec.id] = executor }
    }

    var specs: [AIToolSpec] { executors.values.map(\.spec).sorted { $0.id < $1.id } }

    /// The stored permission, with a stored `.always` for a write read as `.ask`.
    func permission(for spec: AIToolSpec) -> AIToolPermission {
        let stored = permissions.permission(for: spec.id) ?? .auto
        return spec.isAction && stored == .always ? .ask : stored
    }

    /// The values a call would use, labeled by parameter, in full: what's approved is exactly
    /// what's written.
    static func fields(for spec: AIToolSpec, arguments: AIToolArguments) -> [AIToolApproval.Field] {
        spec.parameters.compactMap { parameter in
            guard let value = arguments[parameter.name] else { return nil }
            return AIToolApproval.Field(label: parameter.name.capitalized, value: value)
        }
    }

    func invoke(toolID: String, arguments: AIToolArguments) async -> String {
        await invoke(toolID: toolID, arguments: arguments, isGranted: nil)
    }

    /// Runs a call. `isGranted`, when given, is the conversation's current grant for the tool,
    /// asked before anything happens and again after an approval: a tool the person took away
    /// from the agent mid-turn never runs.
    func invoke(toolID: String, arguments: AIToolArguments, isGranted: (@MainActor (String) -> Bool)?) async -> String {
        guard let executor = executors[toolID] else { return AIToolError.unknownTool(toolID).localizedDescription }
        let revoked = "This tool is no longer allowed in this conversation, so nothing was done."
        if let isGranted, !isGranted(toolID) {
            log(executor.spec, executor.describe(arguments), .declined)
            return revoked
        }
        let spec = executor.spec
        let detail = executor.describe(arguments)
        // An action this launch may not perform is refused before anyone is asked about it.
        if spec.effect == .system {
            do { try sideEffects.check(spec.title.lowercased()) } catch {
                log(spec, detail, .blocked(error.localizedDescription))
                return error.localizedDescription
            }
        }
        if permission(for: spec).needsApproval(for: spec) {
            let decision = await requestApproval(
                AIToolApproval(
                    toolID: spec.id, title: spec.title, symbol: spec.symbol, detail: detail, isAction: spec.isAction,
                    fields: Self.fields(for: spec, arguments: arguments)))
            switch decision {
            case .deny:
                log(spec, detail, .declined)
                return "The person declined this request, so nothing was done. Tell them it wasn't done."
            case .alwaysAllow:
                // Standing permission is for reads only; a write was approved this once.
                if !spec.isAction { permissions.setPermission(.always, for: spec.id) }
            case .allow:
                break
            }
        }
        // Stop, or a closed conversation, between the yes and the run cancels the call.
        if Task.isCancelled {
            log(spec, detail, .declined)
            return "The request was stopped, so nothing was done."
        }
        if let isGranted, !isGranted(toolID) {
            log(spec, detail, .declined)
            return revoked
        }
        do {
            let output = try await executor.run(arguments)
            log(spec, detail, .ran)
            return output
        } catch {
            log(spec, detail, .failed(error.localizedDescription))
            return "The tool failed: \(error.localizedDescription)"
        }
    }

    /// Answers a card. Unknown or already answered ids do nothing.
    func resolve(_ id: UUID, _ decision: AIToolDecision) {
        pendingApprovals.removeAll { $0.id == id }
        waiting.removeValue(forKey: id)?.resume(returning: decision)
    }

    /// Declines every open card, as Stop does.
    func declineAll() {
        for approval in pendingApprovals { resolve(approval.id, .deny) }
    }

    func clearActivity() { activity = [] }

    private func requestApproval(_ approval: AIToolApproval) async -> AIToolDecision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .deny)
                    return
                }
                waiting[approval.id] = continuation
                pendingApprovals.append(approval)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(approval.id, .deny) }
        }
    }

    private func log(_ spec: AIToolSpec, _ detail: String, _ outcome: AIToolActivity.Outcome) {
        activity.append(AIToolActivity(toolID: spec.id, title: spec.title, detail: detail, outcome: outcome))
    }
}

/// `@calendar`-style mentions in what the person typed.
enum AIMentionParser {
    struct Mention: Equatable, Sendable {
        var extensionID: String
        /// The typed token's range in the text, `@` included.
        var range: Range<String.Index>
    }

    /// Mentions of known extensions, in order. `@` must start the text or follow a space or
    /// punctuation, so an address like `kim@example.com` never counts. Unknown names stay text.
    static func mentions(in text: String, extensions: [AIToolExtension]) -> [Mention] {
        var names: [String: String] = [:]
        for item in extensions {
            names[item.id.lowercased()] = item.id
            for alias in item.aliases { names[alias.lowercased()] = item.id }
        }
        var found: [Mention] = []
        var index = text.startIndex
        while let at = text[index...].firstIndex(of: "@") {
            let start = text.index(after: at)
            let precededByWord = at > text.startIndex && isNameCharacter(text[text.index(before: at)])
            let end = text[start...].firstIndex { !isNameCharacter($0) } ?? text.endIndex
            let name = String(text[start..<end]).lowercased()
            if !precededByWord, !name.isEmpty, let id = names[name] {
                found.append(Mention(extensionID: id, range: at..<end))
            }
            index = end > at ? end : text.index(after: at)
            if index >= text.endIndex { break }
        }
        return found
    }

    /// The text without its mention tokens, with spacing tidied.
    static func strippingMentions(_ text: String, extensions: [AIToolExtension]) -> String {
        var result = text
        for mention in mentions(in: text, extensions: extensions).reversed() { result.removeSubrange(mention.range) }
        return result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Completions for a mention being typed at the end of the text: `@cal` offers `@calendar`.
    static func completions(for text: String, extensions: [AIToolExtension]) -> [AIToolExtension] {
        guard let at = text.lastIndex(of: "@") else { return [] }
        if at > text.startIndex, isNameCharacter(text[text.index(before: at)]) { return [] }
        let partial = text[text.index(after: at)...].lowercased()
        guard partial.allSatisfy(isNameCharacter) else { return [] }
        return extensions.filter { item in
            item.id.hasPrefix(partial) || item.aliases.contains { $0.hasPrefix(partial) }
        }
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }
}

/// Which tools one request offers. The set stays small: the on-device window is short and
/// every tool definition spends it.
struct AIToolPlan: Equatable, Sendable {
    var tools: [AIToolSpec]
    var mode: AIToolCallingMode
    /// The prompt with mention tokens removed.
    var prompt: String
    var mentionedExtensionIDs: [String]
}

enum AIToolRouter {
    /// The most tools one request carries.
    static let maximumTools = 4

    /// Mentions win: their tools, and the model must call one. Otherwise the agent's tools,
    /// which the model may call. Otherwise none.
    static func plan(text: String, extensions: [AIToolExtension], agentToolIDs: [String]) -> AIToolPlan {
        let mentions = AIMentionParser.mentions(in: text, extensions: extensions)
        var mentioned: [String] = []
        for mention in mentions where !mentioned.contains(mention.extensionID) { mentioned.append(mention.extensionID) }
        if !mentioned.isEmpty {
            let tools = mentioned.compactMap { id in extensions.first { $0.id == id } }.flatMap(\.tools)
            let stripped = AIMentionParser.strippingMentions(text, extensions: extensions)
            return AIToolPlan(
                tools: Array(unique(tools).prefix(maximumTools)), mode: .required,
                prompt: stripped.isEmpty ? text : stripped, mentionedExtensionIDs: mentioned)
        }
        let all = extensions.flatMap(\.tools)
        let chosen = agentToolIDs.compactMap { id in all.first { $0.id == id } }
        guard !chosen.isEmpty else { return AIToolPlan(tools: [], mode: .none, prompt: text, mentionedExtensionIDs: []) }
        return AIToolPlan(
            tools: Array(unique(chosen).prefix(maximumTools)), mode: .allowed, prompt: text, mentionedExtensionIDs: [])
    }

    private static func unique(_ tools: [AIToolSpec]) -> [AIToolSpec] {
        var seen = Set<String>()
        return tools.filter { seen.insert($0.id).inserted }
    }
}

/// A source of extra tools from outside OpenRay, such as an MCP server. Out of scope for
/// this pass: nothing conforms yet. A client would list a few hand-picked tools per agent as
/// `AIToolExecutor`s and register them with the broker, never a whole server's catalog.
@MainActor
protocol AIExternalToolSource {
    var id: String { get }
    var title: String { get }
    func executors() async throws -> [any AIToolExecutor]
}
