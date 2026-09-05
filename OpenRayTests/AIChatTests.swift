import Foundation
import Testing

@testable import OpenRay

@MainActor
final class TestAIEngine: AIEngine {
    var availability: AIAvailability = .available
    var snapshots = ["A", "A helpful", "A helpful reply."]
    var failure: AIServiceError?
    var delay: Duration = .zero
    var prompts: [String] = []
    var resetCount = 0
    var preparedActions: [AIAction] = []

    func reset() { resetCount += 1 }
    func prepare(for action: AIAction) { preparedActions.append(action) }

    func stream(_ prompt: String, action: AIAction, onSnapshot: @escaping @MainActor (String) -> Void) async throws {
        prompts.append(prompt)
        for snapshot in snapshots {
            try Task.checkCancellation()
            onSnapshot(snapshot)
            if delay > .zero { try await Task.sleep(for: delay) }
        }
        if let failure { throw failure }
    }
}

@MainActor
struct AIChatTests {
    @Test func streamingReplacesSnapshotsAndBlocksConcurrentRequests() async {
        let engine = TestAIEngine()
        let chat = AIChatModel(engine: engine)
        chat.draft = "  Hello  "
        chat.send()
        chat.draft = "Second request"
        chat.send()
        #expect(chat.isGenerating)
        await chat.waitForResponse()
        #expect(engine.prompts == ["Hello"])
        #expect(chat.messages.count == 2)
        #expect(chat.messages.last?.text == "A helpful reply.")
        #expect(chat.messages.last?.isPartial == false)
        #expect(!chat.isGenerating)
        #expect(chat.draft == "Second request")
    }

    @Test func unavailableAIAndOversizedInputNeverGenerate() async {
        let engine = TestAIEngine()
        engine.availability = .notEnabled
        let chat = AIChatModel(engine: engine)
        chat.draft = "Hello"
        chat.send()
        #expect(!chat.canSend)
        #expect(chat.messages.isEmpty)
        engine.availability = .available
        chat.refreshAvailability()
        chat.draft = String(repeating: "a", count: AIChatModel.inputLimit + 1)
        chat.send()
        #expect(engine.prompts.isEmpty)
    }

    @Test func importedTextIsNotSilentlyTruncated() {
        let chat = AIChatModel(engine: TestAIEngine())
        chat.draft = "Keep my draft"
        chat.useText(String(repeating: "a", count: AIChatModel.inputLimit + 1))
        #expect(chat.draft == "Keep my draft")
        #expect(chat.errorMessage?.contains("No text has been truncated") == true)
    }

    @Test func contextOverflowKeepsVisibleHistoryAndResetsEngine() async {
        let engine = TestAIEngine()
        engine.snapshots = []
        engine.failure = .contextFull
        let chat = AIChatModel(engine: engine)
        chat.draft = "Summarize this"
        chat.send()
        await chat.waitForResponse()
        #expect(chat.messages.count == 1)
        #expect(chat.messages.first?.text == "Summarize this")
        #expect(chat.errorMessage?.contains("context limit") == true)
        #expect(engine.resetCount == 1)
        engine.failure = nil
        engine.snapshots = ["Recovered"]
        chat.draft = "Short request"
        chat.send()
        await chat.waitForResponse()
        #expect(chat.messages.last?.text == "Recovered")
    }

    @Test func cancelDoesNotPermitNewRequestUntilGenerationUnwinds() async {
        let engine = TestAIEngine()
        engine.delay = .seconds(10)
        let chat = AIChatModel(engine: engine)
        chat.draft = "Generate something"
        chat.send()
        await Task.yield()
        chat.cancel()
        #expect(chat.isGenerating)
        #expect(chat.isCancelling)
        chat.newConversation()
        #expect(!chat.messages.isEmpty)
        await chat.waitForResponse()
        #expect(!chat.isGenerating)
        #expect(chat.errorMessage?.contains("stopped") == true)
        #expect(engine.resetCount == 1)
    }

    @Test func changingWritingModeStartsCleanSession() async {
        let engine = TestAIEngine()
        let chat = AIChatModel(engine: engine)
        chat.draft = "First message"
        chat.send()
        await chat.waitForResponse()
        chat.open(.proofread)
        #expect(chat.messages.isEmpty)
        #expect(chat.action == .proofread)
        #expect(engine.resetCount == 1)
        #expect(engine.preparedActions == [.proofread])
    }

    @Test func allWritingInstructionsKeepUserContentOutOfSystemInstructions() {
        for action in AIAction.allCases {
            #expect(action.instructions.contains("no internet access"))
            #expect(action.instructions.contains("as data"))
            #expect(!action.instructions.contains("API key"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENRAY_TEST_AI"] == "1"), .timeLimit(.minutes(1)))
    func realOnDeviceModelStreamsAResponse() async throws {
        let engine = FoundationModelEngine()
        #expect(engine.availability == .available)
        var response = ""
        try await engine.stream("Rewrite this as a polite reminder: The team meeting starts at 2 pm.", action: .rewrite)
        { response = $0 }
        #expect(!response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
