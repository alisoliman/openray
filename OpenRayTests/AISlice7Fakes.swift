import AppKit
import Foundation
import Testing

@testable import OpenRay

/// An engine for Slice 7 tests: a configurable window and capabilities, one token per word,
/// and a record of every request, summary, rebuild and transcript. It never calls a model.
@MainActor
final class RecordingAIEngine: AIEngine {
    var availability: AIAvailability = .available
    var capabilities: AIModelCapabilities = []
    var window = 4_096
    var replies = ["A helpful reply."]
    var failure: AIServiceError?
    var requests: [AIRequest] = []
    var actionPrompts: [String] = []
    var summaries: [String] = []
    var rebuilds: [AIConversationContext] = []
    var resetCount = 0
    var transcript: Data?
    var restored: [Data] = []
    var modelChoice: AIModelChoice = .onDevice
    var cloudStatus: AIPrivateCloudStatus?
    /// Tools the engine calls, as a model would, before it answers: (tool id, arguments).
    var toolCalls: [(String, [String: String])] = []
    var toolOutputs: [String] = []

    func prepare(for action: AIAction) { prepared.append(action) }
    func reset() { resetCount += 1 }

    func stream(_ prompt: String, action: AIAction, onSnapshot: @escaping @MainActor (String) -> Void) async throws {
        actionPrompts.append(prompt)
        for reply in replies { onSnapshot(reply) }
        if let failure { throw failure }
    }

    func contextSize() async -> Int { window }
    func tokenCount(_ text: String) async -> Int { text.split(whereSeparator: \.isWhitespace).count }
    func toolTokenCount(_ tools: [AIToolSpec]) async -> Int { tools.count * 10 }

    func stream(_ request: AIRequest, onSnapshot: @escaping @MainActor (AIResponseSnapshot) -> Void) async throws {
        requests.append(request)
        if let invoker = request.toolInvoker {
            for (id, arguments) in toolCalls where request.tools.contains(where: { $0.id == id }) {
                toolOutputs.append(await invoker.invoke(toolID: id, arguments: AIToolArguments(arguments)))
            }
        }
        try Task.checkCancellation()
        for reply in replies { onSnapshot(AIResponseSnapshot(text: reply)) }
        if let failure { throw failure }
    }

    func summarize(_ text: String, focus: String) async throws -> String {
        summaries.append(text)
        return "summary \(summaries.count)"
    }

    func rebuild(_ context: AIConversationContext) { rebuilds.append(context) }
    func exportTranscript() -> Data? { transcript }
    var restoredContexts: [AIConversationContext] = []
    var prepared: [AIAction] = []
    func restoreTranscript(_ data: Data, context: AIConversationContext) -> Bool {
        restored.append(data)
        restoredContexts.append(context)
        return true
    }
    func setModelChoice(_ choice: AIModelChoice) { modelChoice = choice }
    var privateCloudStatus: AIPrivateCloudStatus? { cloudStatus }
    func makeSibling() -> any AIEngine {
        let engine = RecordingAIEngine()
        engine.capabilities = capabilities
        engine.window = window
        return engine
    }
}

/// One token per word, with a fixed window.
@MainActor
struct WordCounter: AITokenCounting {
    var window: Int
    func tokenCount(_ text: String) async -> Int { text.split(whereSeparator: \.isWhitespace).count }
    func contextSize() async -> Int { window }
}

/// Keeps the first few words of whatever it summarizes, and counts its calls.
@MainActor
final class FirstWordsSummarizer: AISummarizing {
    var words = 3
    var calls: [String] = []
    func summarize(_ text: String, focus: String) async throws -> String {
        calls.append(text)
        return text.split(whereSeparator: \.isWhitespace).prefix(words).joined(separator: " ")
    }
}

/// A tool that records its calls.
@MainActor
final class FakeToolExecutor: AIToolExecutor {
    let spec: AIToolSpec
    var runs: [AIToolArguments] = []
    var output = "done"

    init(_ id: String, extensionID: String, effect: AIToolSpec.Effect = .read) {
        spec = AIToolSpec(
            id: id, extensionID: extensionID, title: id, symbol: "wrench", summary: "Test tool \(id).",
            parameters: [AIToolParameter(name: "query", description: "Words.", isOptional: true)], effect: effect)
    }

    func describe(_ arguments: AIToolArguments) -> String { "Run \(spec.id)" }
    func run(_ arguments: AIToolArguments) async throws -> String {
        runs.append(arguments)
        return output
    }
}

/// Translates by tagging the text, for the Translate command.
@MainActor
final class FakeTranslator: AITextTranslating {
    var calls: [(String, String)] = []
    func translate(_ text: String, toLanguageID languageID: String) async throws -> String {
        calls.append((text, languageID))
        return "[\(languageID)] \(text)"
    }
}

@MainActor
enum Slice7Fixtures {
    /// A launcher with the AI Command provider and a recording engine. The selection reads from `selection`.
    static func launcher(
        engine: RecordingAIEngine = RecordingAIEngine(), selection: String? = "Their are two thing.",
        store: LibraryStore = LibraryStore(fileURL: nil)
    ) -> LauncherModel {
        let model = LauncherModel(
            store: store, ai: AIChatModel(engine: engine), pasteboard: NSPasteboard.withUniqueName(),
            registry: CommandRegistry(providers: [AIWritingCommandProvider(), AICommandProvider()]))
        model.selectionReader = {
            guard let selection else { throw AIServiceError.failed("No selection") }
            return selection
        }
        model.aiHub.windowEngineFactory = { engine.makeSibling() }
        return model
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OpenRaySlice7-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
