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

    @Test(arguments: AIAction.allCases.filter { $0 != .chat })
    func writingActionsPreserveTheRawPassage(action: AIAction) async {
        let source = "\t  The bus arrives at noon.\n\n    Please meet me outside.\n\n"
        let engine = TestAIEngine()
        engine.snapshots = [source]
        let chat = AIChatModel(engine: engine)
        chat.open(action)
        chat.draft = source
        chat.send()
        await chat.waitForResponse()
        #expect(engine.prompts == [source])
        #expect(chat.messages.first?.text == source)
        #expect(chat.messages.last?.text == source)
    }

    @Test(arguments: AIAction.allCases)
    func whitespaceOnlyDraftsNeverGenerate(action: AIAction) async {
        let engine = TestAIEngine()
        let chat = AIChatModel(engine: engine)
        chat.open(action)
        chat.draft = " \t\n\n"
        #expect(!chat.canSend)
        chat.send()
        await chat.waitForResponse()
        #expect(engine.prompts.isEmpty)
        #expect(chat.messages.isEmpty)
        #expect(chat.draft == " \t\n\n")
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

    @Test func writingOperationsWrapPassagesAndKeepChatInstructionsSeparate() {
        let source = "Can you send the report?"
        #expect(AIAction.chat.prompt(for: source) == source)
        for action in AIAction.allCases where action != .chat {
            #expect(action.prompt(for: source).contains("<passage>\n\(source)\n</passage>"))
            #expect(!action.instructions.contains("Use earlier messages"))
            #expect(action.instructions.contains("not a chat message"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENRAY_TEST_AI"] == "1"), .timeLimit(.minutes(3)))
    func realOnDeviceWritingActionsRespectTransformationContracts() async throws {
        let engine = FoundationModelEngine()
        #expect(engine.availability == .available)
        let chat = AIChatModel(engine: engine)
        func generate(_ source: String, action: AIAction) async throws -> String {
            chat.open(action)
            chat.draft = source
            chat.send()
            await chat.waitForResponse()
            #expect(chat.errorMessage == nil)
            let message = try #require(chat.messages.last)
            #expect(message.role == .assistant)
            let response = message.text
            print("LIVE AI [\(action.rawValue)] INPUT: \(source)\nOUTPUT: \(response)")
            #expect(!response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            return response
        }

        // Different clean passages also exercise repeated requests in one writing mode.
        for source in [
            "Alex will send the report on Monday. Jamie will review it on Tuesday. The team meets Wednesday.",
            "The train arrives at six.\n\nPlease meet me outside the station.",
            "Can you send the report by Friday?",
            "\t  The bus arrives at noon.\n\n",
        ] {
            let response = try await generate(source, action: .proofread)
            #expect(response == source)
        }
        let corrected = try await generate("She go to the store yesterday and buyed three apple.", action: .proofread)
        #expect(corrected == "She went to the store yesterday and bought three apples.")

        let extracted = try await generate(
            "Alex will send the report on Monday. Jamie will review it on Tuesday. The office has blue walls.",
            action: .actionItems)
        let items = extracted.split(separator: "\n")
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.hasPrefix("- ") })
        #expect(items.contains { $0.contains("Alex") && $0.contains("Monday") && $0.lowercased().contains("send") })
        #expect(items.contains { $0.contains("Jamie") && $0.contains("Tuesday") && $0.lowercased().contains("review") })
        #expect(!extracted.contains("blue"))
        let noTasks = try await generate(
            "The building is made of red brick. The lobby has two windows.", action: .actionItems)
        #expect(noTasks == "No action items found.")

        let source = "The library opens at 9 am and closes at 6 pm. It is closed on Sunday."
        let summary = try await generate(source, action: .summarize)
        #expect(summary.contains("9") && summary.contains("6") && summary.contains("Sunday"))
        let rewrite = try await generate("I wanted to let you know that the meeting starts at 2 pm.", action: .rewrite)
        #expect(rewrite.contains("2") && rewrite.lowercased().contains("meeting"))
        let shortened = try await generate(
            "Due to the fact that the meeting has been canceled, there is no need for you to attend.", action: .shorten)
        #expect(shortened.lowercased().contains("cancel"))
        #expect(shortened.split(separator: " ").count < 19)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENRAY_TEST_AI"] == "1"), .timeLimit(.minutes(2)))
    func realWritingCommandQualityEvaluation() async throws {
        let correct = "Alex will send the report on Monday. Jamie will review it on Tuesday. The team meets Wednesday."
        let unchanged = try await evaluateWriting(correct, action: .proofread, named: "already-correct")

        let corrected = try await evaluateWriting(
            "She go to the store yesterday and buyed three apple.", action: .proofread, named: "grammar-errors")

        let actions = try await evaluateWriting(correct, action: .actionItems, named: "owners-and-dates")
        let lines = actions.split(whereSeparator: \.isNewline)
        let normalizedLines = lines.map { $0.lowercased() }

        let noActions = try await evaluateWriting(
            "The library has two floors. Its walls are blue.", action: .actionItems, named: "no-actions")

        // Model quality is evaluated and reported separately from deterministic service correctness.
        // These observations are not exact-output build gates across changing on-device model versions.
        let checks: [(String, Bool)] = [
            ("Already-correct proofreading returns the passage unchanged", unchanged == correct),
            (
                "Proofreading corrects the supplied grammar errors",
                corrected.contains("went") && corrected.contains("bought") && corrected.contains("three apples")
            ),
            (
                "Action extraction returns one bullet per line",
                !lines.isEmpty && lines.allSatisfy { $0.hasPrefix("- ") }
            ),
            (
                "Action extraction preserves Alex's task and date",
                normalizedLines.contains { $0.contains("alex") && $0.contains("monday") && $0.contains("report") }
            ),
            (
                "Action extraction preserves Jamie's task and date",
                normalizedLines.contains { $0.contains("jamie") && $0.contains("tuesday") && $0.contains("review") }
            ),
            (
                "Descriptions produce no action items",
                noActions.lowercased().contains("no action items") && !noActions.contains("- ")
            ),
        ]
        Attachment.record(
            checks.map { "\($0.1 ? "MEETS EXPECTATION" : "QUALITY DEVIATION"): \($0.0)" }.joined(separator: "\n"),
            named: "writing-evaluation-summary.txt")
        if checks.contains(where: { !$0.1 }) {
            Issue.record(
                "The on-device writing evaluation found quality deviations. Review writing-evaluation-summary.txt and the output attachments.",
                severity: .warning)
        }
    }

    private func evaluateWriting(_ prompt: String, action: AIAction, named name: String) async throws -> String {
        let engine = FoundationModelEngine()
        try #require(engine.availability == .available)
        var response = ""
        try await engine.stream(prompt, action: action) { response = $0 }
        Attachment.record(
            "Action: \(action.rawValue)\nInput:\n\(prompt)\n\nOutput:\n\(response)",
            named: "writing-command-\(name).txt")
        #expect(!response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
