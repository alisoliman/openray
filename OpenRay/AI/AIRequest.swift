import Foundation

// Request settings shared by chat, agents and AI Commands. They are plain values, so the
// engines, the stores and the tests all speak the same language; only
// `FoundationModelEngine` maps them onto FoundationModels types.

/// How freely the model words its answer. Maps to a sampling temperature.
enum AICreativity: String, CaseIterable, Identifiable, Sendable {
    case none, low, medium, high, maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .maximum: "Maximum"
        }
    }

    /// Nil for `.none`, which samples greedily instead.
    var temperature: Double? {
        switch self {
        case .none: nil
        case .low: 0.3
        case .medium: 0.6
        case .high: 0.9
        case .maximum: 1.2
        }
    }

    /// The nearest setting for a temperature, so an agent's number shows as a choice.
    static func nearest(to temperature: Double?) -> AICreativity {
        guard let temperature, temperature > 0.05 else { return .none }
        return allCases.filter { $0 != .none }
            .min { abs(($0.temperature ?? 0) - temperature) < abs(($1.temperature ?? 0) - temperature) } ?? .medium
    }
}

/// How hard the model thinks before answering. Offered only when the model has the
/// `.reasoning` capability; otherwise it's ignored.
enum AIReasoningLevel: String, CaseIterable, Identifiable, Sendable {
    case light, moderate, deep

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Which content guardrail the request uses. `.permissive` is Apple's setting for transforming
/// text the person supplied, which cuts false refusals on ordinary writing.
enum AIGuardrail: String, CaseIterable, Identifiable, Sendable {
    case standard, permissive

    var id: String { rawValue }
    var title: String { self == .standard ? "Standard" : "Permissive for my own text" }
}

/// Which Apple model answers. On this Mac is the default; Private Cloud Compute is an
/// opt-in larger model with a quota.
enum AIModelChoice: String, CaseIterable, Identifiable, Sendable {
    case onDevice, privateCloud

    var id: String { rawValue }
    var title: String { self == .onDevice ? "On this Mac" : "Larger model (Private Cloud Compute)" }
}

/// What the Private Cloud Compute model can do right now.
enum AIPrivateCloudStatus: Equatable, Sendable {
    case available(approachingLimit: Bool)
    case limitReached(resetDate: Date?)
    case unavailable(String)

    var isUsable: Bool { if case .available = self { true } else { false } }

    var summary: String {
        switch self {
        case .available(let approaching): approaching ? "Available · approaching your limit" : "Available"
        case .limitReached(let date):
            date.map { "Limit reached · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Limit reached"
        case .unavailable(let reason): reason
        }
    }
}

enum AIModelSelection {
    /// The model a request uses. Private Cloud Compute only when the person opted in and it
    /// can answer; otherwise the on-device model, so a quota or outage never blocks AI.
    static func resolve(preference: AIModelChoice, privateCloud: AIPrivateCloudStatus?) -> AIModelChoice {
        guard preference == .privateCloud, let privateCloud, privateCloud.isUsable else { return .onDevice }
        return .privateCloud
    }
}

/// What the active model supports, read at runtime.
struct AIModelCapabilities: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let vision = AIModelCapabilities(rawValue: 1 << 0)
    static let reasoning = AIModelCapabilities(rawValue: 1 << 1)
    static let toolCalling = AIModelCapabilities(rawValue: 1 << 2)
    static let guidedGeneration = AIModelCapabilities(rawValue: 1 << 3)
}

/// How a request uses its tools.
enum AIToolCallingMode: Equatable, Sendable {
    /// No tools.
    case none
    /// The model may call one of the tools.
    case allowed
    /// The model must call one: the person @-mentioned it.
    case required
}

/// How a session is configured: its instructions and sampling, and whether it keeps the
/// conversation. Two requests with equal profiles can share a session.
struct AIRequestProfile: Hashable, Sendable {
    /// Identifies the configuration: `chat`, `agent.<uuid>`, `aicommand.<id>`.
    var id: String
    var instructions: String
    var temperature: Double? = nil
    var greedy = false
    var reasoning: AIReasoningLevel? = nil
    var guardrail: AIGuardrail = .standard
    var maximumResponseTokens: Int? = 900
    /// Chat keeps earlier turns in the session; AI Commands start fresh every time.
    var keepsContext = true
    /// Asks for the transformed text alone (guided generation), for output that replaces a selection.
    var wantsPlainResult = false

    /// The default assistant in chat.
    static let chat = AIRequestProfile(id: "chat", instructions: AIAction.chat.instructions, temperature: 0.4)
}

/// An image a request shows the model. Only sent when the model has `.vision`.
struct AIImageInput: Hashable, Sendable {
    var data: Data
    var label: String
}

/// One configured generation: a chat turn with an agent, tools or images, or an AI Command.
struct AIRequest: Sendable {
    var prompt: String
    var images: [AIImageInput] = []
    var profile: AIRequestProfile
    var tools: [AIToolSpec] = []
    var toolMode: AIToolCallingMode = .none
    /// Runs the tools the model calls. Nil means no tools.
    var toolInvoker: (any AIToolInvoking)? = nil
    /// What an engine that predates requests streams instead.
    var fallbackAction: AIAction = .chat
}

/// A conversation's context, rebuilt after condensation or when a saved chat resumes.
struct AIConversationContext: Equatable, Sendable {
    struct Turn: Equatable, Sendable {
        var prompt: String
        var response: String
    }
    var profile: AIRequestProfile
    /// The rolling summary of turns that no longer fit.
    var summary: String?
    /// The most recent turns, oldest first.
    var turns: [Turn]

    /// The instructions with the summary folded in, so the summary costs no extra turn.
    var instructions: String {
        guard let summary, !summary.isEmpty else { return profile.instructions }
        return profile.instructions
            + "\n\nSummary of the earlier conversation, for context. Don't repeat it unless asked:\n<summary>\n\(summary)\n</summary>"
    }
}

/// Character-based estimates for engines that can't count tokens. About four characters a
/// token for English; tests replace it with their own counter.
enum AITokenEstimate {
    static let defaultContextSize = 4_096

    static func tokens(in text: String) -> Int {
        text.isEmpty ? 0 : max(1, (text.utf8.count + 3) / 4)
    }

    static func tokens(for tools: [AIToolSpec]) -> Int {
        var total = 0
        for tool in tools {
            total += 12 + tokens(in: tool.id + tool.summary)
            for parameter in tool.parameters {
                total += 6 + tokens(in: parameter.name + parameter.description)
            }
        }
        return total
    }
}

extension AIEngine {
    var capabilities: AIModelCapabilities { [] }
    func contextSize() async -> Int { AITokenEstimate.defaultContextSize }
    func tokenCount(_ text: String) async -> Int { AITokenEstimate.tokens(in: text) }
    func toolTokenCount(_ tools: [AIToolSpec]) async -> Int { AITokenEstimate.tokens(for: tools) }

    func stream(_ request: AIRequest, onSnapshot: @escaping @MainActor (AIResponseSnapshot) -> Void) async throws {
        try await stream(request.prompt, action: request.fallbackAction, instruction: "", onSnapshot: onSnapshot)
    }

    func summarize(_ text: String, focus: String) async throws -> String {
        var latest = ""
        try await stream(text, action: .summarize, instruction: focus) { latest = $0.text }
        return latest
    }

    func rebuild(_ context: AIConversationContext) { reset() }
    func exportTranscript() -> Data? { nil }
    func restoreTranscript(_ data: Data, profile: AIRequestProfile) -> Bool { false }
    func setModelChoice(_ choice: AIModelChoice) {}
    var privateCloudStatus: AIPrivateCloudStatus? { nil }
    func makeSibling() -> any AIEngine { InertAIEngine() }
}

/// Never generates. Stands in where no engine was provided, so nothing reaches a real model by accident.
@MainActor
final class InertAIEngine: AIEngine {
    var availability: AIAvailability { .unavailable }
    func prepare(for action: AIAction) {}
    func reset() {}
    func stream(_ prompt: String, action: AIAction, onSnapshot: @escaping @MainActor (String) -> Void) async throws {
        throw AIServiceError.unavailable(.unavailable)
    }
}

/// Counts tokens and reads the window size through an engine.
@MainActor
struct EngineTokenCounter: AITokenCounting {
    let engine: any AIEngine
    func tokenCount(_ text: String) async -> Int { await engine.tokenCount(text) }
    func contextSize() async -> Int { await engine.contextSize() }
}

/// Summarizes through an engine, on a session apart from the conversation's.
@MainActor
struct EngineSummarizer: AISummarizing {
    let engine: any AIEngine
    func summarize(_ text: String, focus: String) async throws -> String { try await engine.summarize(text, focus: focus) }
}
