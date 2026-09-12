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
    var requests: [AIRequest] = []
    var resetCount = 0
    var preparedActions: [AIAction] = []

    func reset() { resetCount += 1 }
    func prepare(for action: AIAction) { preparedActions.append(action) }

    func stream(_ request: AIRequest, action: AIAction, onSnapshot: @escaping @MainActor (String) -> Void) async throws
    {
        requests.append(request)
        try await stream(request.prompt, action: action, onSnapshot: onSnapshot)
    }

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

    @Test(arguments: AIAction.workspaceActions.filter { $0 != .chat })
    func followUpsReviseTheLatestResultAndRetainOriginalFactsAndAcceptedInstructions(action: AIAction) async throws {
        let engine = TestAIEngine()
        engine.snapshots = ["The meeting starts at 2 pm on Friday."]
        let chat = AIChatModel(engine: engine)
        chat.open(action)
        chat.draft = "  I wanted to let you know the meeting starts at 2 pm on Friday.\n"
        chat.send()
        await chat.waitForResponse()
        let source = try #require(chat.sourcePassage)
        #expect(chat.hasWritingContext)
        #expect(engine.requests.first?.isRevision == false)
        chat.draft = "Make it warmer"
        engine.snapshots = ["Looking forward to seeing you at 2 pm on Friday!"]
        chat.send()
        await chat.waitForResponse()
        let second = try #require(engine.requests.last)
        #expect(second.prompt == "Make it warmer")
        #expect(second.writingContext?.originalPassage == source)
        #expect(second.writingContext?.currentResult == "The meeting starts at 2 pm on Friday.")
        #expect(second.writingContext?.acceptedRevisions == [])
        chat.draft = "Keep it to one sentence"
        chat.send()
        await chat.waitForResponse()
        let third = try #require(engine.requests.last)
        #expect(third.writingContext?.originalPassage == source)
        #expect(third.writingContext?.currentResult == "Looking forward to seeing you at 2 pm on Friday!")
        #expect(third.writingContext?.acceptedRevisions == ["Make it warmer"])
        #expect(
            chat.messages.filter { $0.role == .user }.map(\.text) == [
                source, "Make it warmer", "Keep it to one sentence",
            ])
    }

    @Test func retryAfterFailedRevisionRetainsContextAndDoesNotDuplicateMessages() async throws {
        let engine = TestAIEngine()
        engine.snapshots = ["The report is due Friday."]
        let chat = AIChatModel(engine: engine)
        chat.open(.rewrite)
        chat.draft = "I need your report by Friday."
        chat.send()
        await chat.waitForResponse()
        chat.draft = "Make it friendlier"
        engine.snapshots = ["Could you"]
        engine.failure = .busy
        chat.send()
        await chat.waitForResponse()
        let failed = try #require(engine.requests.last)
        #expect(chat.draft == "Make it friendlier")
        #expect(chat.latestCompletedResponse == "The report is due Friday.")
        #expect(chat.messages.last?.isPartial == true)
        #expect(chat.canRetry)
        engine.failure = nil
        engine.snapshots = ["Could you please send your report by Friday?"]
        chat.retry()
        await chat.waitForResponse()
        #expect(engine.requests.last == failed)
        #expect(chat.messages.count == 4)
        #expect(chat.latestCompletedResponse == "Could you please send your report by Friday?")
        #expect(chat.draft.isEmpty)
        #expect(chat.errorMessage == nil)
        #expect(!chat.canRetry)
        chat.draft = "Make it shorter"
        chat.send()
        await chat.waitForResponse()
        #expect(engine.requests.last?.writingContext?.acceptedRevisions == ["Make it friendlier"])
    }

    @Test func stoppedInitialWritingRequestCanBeRetriedWithoutTreatingSourceAsARevision() async {
        let engine = TestAIEngine()
        engine.delay = .seconds(10)
        let chat = AIChatModel(engine: engine)
        chat.open(.rewrite)
        chat.draft = "Please send your feedback by Friday."
        chat.send()
        await Task.yield()
        chat.cancel()
        await chat.waitForResponse()
        #expect(chat.sourcePassage == "Please send your feedback by Friday.")
        #expect(chat.draft == chat.sourcePassage)
        #expect(chat.latestCompletedResponse == nil)
        #expect(chat.canRetry)
        engine.delay = .zero
        engine.snapshots = ["Please share your feedback by Friday."]
        // Enter on the restored draft follows the same safe retry path as Retry.
        chat.send()
        await chat.waitForResponse()
        #expect(engine.requests.last?.isRevision == false)
        #expect(engine.requests.last?.prompt == chat.sourcePassage)
        #expect(chat.messages.count == 2)
        #expect(chat.latestCompletedResponse == "Please share your feedback by Friday.")
    }

    @Test func failedRevisionNeverUsesPartialOutputOrOverwritesANewerDraft() async {
        let engine = TestAIEngine()
        engine.snapshots = ["A complete first version."]
        let chat = AIChatModel(engine: engine)
        chat.open(.rewrite)
        chat.draft = "The original passage."
        chat.send()
        await chat.waitForResponse()
        engine.failure = .contextFull
        engine.snapshots = ["An incomplete"]
        chat.draft = "Failed instruction"
        chat.send()
        chat.draft = "Use a more formal tone instead"
        await chat.waitForResponse()
        #expect(chat.draft == "Use a more formal tone instead")
        #expect(!chat.canRetry)
        #expect(chat.errorMessage?.contains("Your passage and revisions are saved") == true)
        engine.failure = nil
        chat.send()
        await chat.waitForResponse()
        #expect(engine.requests.last?.writingContext?.currentResult == "A complete first version.")
        #expect(engine.requests.last?.writingContext?.acceptedRevisions == [])
    }

    @Test func followUpTypedDuringFailedInitialResponseRevisesOriginalPassage() async {
        let engine = TestAIEngine()
        engine.failure = .busy
        engine.snapshots = ["Incomplete first"]
        let chat = AIChatModel(engine: engine)
        chat.open(.rewrite)
        chat.draft = "Please send the report by Friday."
        chat.send()
        chat.draft = "Make it warmer"
        await chat.waitForResponse()
        #expect(chat.draft == "Make it warmer")
        #expect(chat.hasWritingContext)
        #expect(chat.latestCompletedResponse == nil)
        engine.failure = nil
        engine.snapshots = ["Could you please send the report by Friday?"]
        chat.send()
        await chat.waitForResponse()
        #expect(chat.sourcePassage == "Please send the report by Friday.")
        #expect(engine.requests.last?.prompt == "Make it warmer")
        #expect(engine.requests.last?.writingContext?.originalPassage == "Please send the report by Friday.")
        #expect(engine.requests.last?.writingContext?.currentResult == "Please send the report by Friday.")
        #expect(engine.requests.last?.writingContext?.acceptedRevisions == [])
        #expect(chat.latestCompletedResponse == "Could you please send the report by Friday?")
    }

    @Test func followUpTypedBeforeStoppingInitialResponseKeepsContextThroughAnotherFailure() async {
        let engine = TestAIEngine()
        engine.delay = .seconds(10)
        let chat = AIChatModel(engine: engine)
        chat.open(.rewrite)
        chat.draft = "The design review is on Friday."
        chat.send()
        chat.draft = "Make it warmer"
        chat.cancel()
        await chat.waitForResponse()
        engine.delay = .zero
        engine.snapshots = []
        engine.failure = .busy
        chat.send()
        await chat.waitForResponse()
        // The restored failed follow-up remains a revision even when edited;
        // neither attempt produced a completed assistant response.
        chat.draft = "Make it friendly and brief"
        engine.failure = nil
        engine.snapshots = ["Join us for the design review on Friday!"]
        chat.send()
        await chat.waitForResponse()
        #expect(chat.sourcePassage == "The design review is on Friday.")
        #expect(engine.requests.last?.writingContext?.currentResult == "The design review is on Friday.")
        #expect(engine.requests.last?.prompt == "Make it friendly and brief")
    }

    @Test func editingRestoredInitialFailureStillEditsTheOriginalPassage() async {
        let engine = TestAIEngine()
        engine.failure = .busy
        engine.snapshots = []
        let chat = AIChatModel(engine: engine)
        chat.open(.rewrite)
        chat.draft = "The review is on Friday."
        chat.send()
        await chat.waitForResponse()
        #expect(chat.draft == "The review is on Friday.")
        #expect(!chat.hasWritingContext)
        chat.draft = "The review is on Thursday."
        engine.failure = nil
        engine.snapshots = ["The review is on Thursday."]
        chat.send()
        await chat.waitForResponse()
        #expect(chat.sourcePassage == "The review is on Thursday.")
        #expect(engine.requests.last?.isRevision == false)
    }

    @Test func emptyResponsesRestoreTheRequestAndCanBeRetried() async {
        let engine = TestAIEngine()
        engine.snapshots = [" \n"]
        let chat = AIChatModel(engine: engine)
        chat.open(.rewrite)
        chat.draft = "Keep the source."
        chat.send()
        await chat.waitForResponse()
        #expect(chat.messages.count == 1)
        #expect(chat.draft == "Keep the source.")
        #expect(chat.sourcePassage == "Keep the source.")
        #expect(chat.latestCompletedResponse == nil)
        #expect(chat.canRetry)
        #expect(engine.resetCount == 2)  // Opening a different action, then empty-response recovery.
    }

    @Test func explicitNewPassageResetsRevisionContextButInvalidImportPreservesWork() async {
        let engine = TestAIEngine()
        let chat = AIChatModel(engine: engine)
        chat.open(.rewrite)
        let originalConversationID = chat.conversationID
        chat.draft = "First source"
        chat.send()
        await chat.waitForResponse()
        #expect(!chat.startWriting(String(repeating: "a", count: AIChatModel.inputLimit + 1)))
        #expect(chat.conversationID == originalConversationID)
        #expect(chat.sourcePassage == "First source")
        #expect(chat.hasWritingContext)
        #expect(chat.startWriting("A different passage"))
        #expect(chat.conversationID != originalConversationID)
        #expect(chat.sourcePassage == nil)
        #expect(!chat.hasWritingContext)
        #expect(chat.messages.isEmpty)
        #expect(chat.draft == "A different passage")
        chat.send()
        await chat.waitForResponse()
        #expect(engine.requests.last?.isRevision == false)
        #expect(chat.sourcePassage == "A different passage")
    }

    @Test func revisionPromptsIdentifyInstructionAndReferenceDataSeparately() {
        let request = AIRequest(
            prompt: "Make it friendlier",
            writingContext: AIWritingContext(
                originalPassage: "The original source", currentResult: "The current version",
                acceptedRevisions: ["Keep it short"]))
        let prompt = request.modelPrompt(for: .rewrite)
        #expect(prompt.contains("<original_passage>\nThe original source\n</original_passage>"))
        #expect(prompt.contains("<current_result>\nThe current version\n</current_result>"))
        #expect(prompt.contains("1. Keep it short"))
        #expect(prompt.contains("<revision_request>\nMake it friendlier\n</revision_request>"))
        #expect(!prompt.contains("<passage>\nMake it friendlier"))
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
            chat.newConversation(action: action)
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

        // Explicitly start a new passage; subsequent sends are now revisions.
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
    func realWritingFollowUpsReviseThePassageAcrossModelResets() async throws {
        let engine = FoundationModelEngine()
        try #require(engine.availability == .available)
        let chat = AIChatModel(engine: engine)
        chat.open(.rewrite)
        let source = "Maya, I wanted to let you know that the design review starts at 2 pm on Friday."
        chat.draft = source
        chat.send()
        await chat.waitForResponse()
        try #require(chat.errorMessage == nil)
        let first = try #require(chat.latestCompletedResponse)
        chat.draft = "Make it warmer and friendlier. Keep Maya, the design review, and the original day and time."
        chat.send()
        await chat.waitForResponse()
        try #require(chat.errorMessage == nil)
        let warmer = try #require(chat.latestCompletedResponse)
        chat.draft = "Use one sentence and keep the friendly tone."
        chat.send()
        await chat.waitForResponse()
        try #require(chat.errorMessage == nil)
        let final = try #require(chat.latestCompletedResponse)
        Attachment.record(
            "Source:\n\(source)\n\nInitial rewrite:\n\(first)\n\nWarmer revision:\n\(warmer)\n\nFinal revision:\n\(final)",
            named: "writing-follow-up-evaluation.txt")
        for result in [warmer, final] {
            #expect(result.contains("Maya"))
            #expect(result.contains("Friday"))
            #expect(result.contains("2"))
            #expect(result.lowercased().contains("design review"))
            #expect(!result.lowercased().contains("make it warmer"))
            #expect(!result.lowercased().contains("use one sentence"))
        }
        #expect(chat.messages.count == 6)
        #expect(
            final.split(whereSeparator: { ".!?".contains($0) }).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count == 1)
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
