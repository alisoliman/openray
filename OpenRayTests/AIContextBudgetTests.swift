import Foundation
import Testing

@testable import OpenRay

@MainActor
struct AIContextBudgetTests {
    @Test func theBudgetFitsThenCondensesThenRefuses() {
        let budget = ContextBudget(contextSize: 1_000, responseReserve: 200)
        #expect(budget.available == 800)
        #expect(budget.threshold == 680)
        #expect(budget.decide(fixed: 100, turns: [100, 100, 100]) == .fits)
        // 100 + 5 × 150 = 850 > 680: keep what fits beside the fixed part and the summary reserve (125).
        #expect(budget.decide(fixed: 100, turns: [150, 150, 150, 150, 150]) == .condense(keepingLast: 3))
        // Even when the newest turn alone overflows, at least the oldest is folded.
        #expect(budget.decide(fixed: 500, turns: [400]) == .condense(keepingLast: 0))
        #expect(budget.decide(fixed: 790, turns: [10, 10]) == .tooLarge)
        #expect(budget.decide(fixed: 790, turns: []) == .fits)
    }

    @Test func theReplyReserveNeverTakesMoreThanAThirdOfTheWindow() {
        let budget = ContextBudget(contextSize: 600, responseReserve: 900)
        #expect(budget.responseReserve == 200)
        #expect(budget.available == 400)
    }

    @Test func chatCondensationFoldsOldTurnsIntoARollingSummary() async throws {
        let summarizer = FirstWordsSummarizer()
        let condenser = ChatCondenser(counter: WordCounter(window: 200), summarizer: summarizer)
        let profile = AIRequestProfile(id: "chat", instructions: "Be brief.", maximumResponseTokens: 40)
        let long = String(repeating: "word ", count: 30)
        let turns = (1...4).map { AIConversationContext.Turn(prompt: "Question \($0) " + long, response: "Answer \($0)") }
        let outcome = try await condenser.prepare(profile: profile, summary: "Earlier facts", turns: turns, prompt: "Next?", toolTokens: 0)
        let rebuilt = try #require(outcome.rebuilt)
        #expect(outcome.foldedTurns >= 2)
        #expect(rebuilt.turns == Array(turns.suffix(4 - outcome.foldedTurns)))
        #expect(outcome.summary == rebuilt.summary)
        // The earlier summary is carried into the new one, with the folded turns, oldest first.
        #expect(summarizer.calls.count == 1)
        #expect(summarizer.calls[0].hasPrefix("Summary so far:\nEarlier facts"))
        #expect(summarizer.calls[0].contains("Person: Question 1"))
        #expect(rebuilt.instructions.contains("<summary>"))
        #expect(rebuilt.instructions.hasPrefix("Be brief."))

        let small = try await condenser.prepare(
            profile: profile, summary: nil, turns: [.init(prompt: "Hi", response: "Hello")], prompt: "Again", toolTokens: 0)
        #expect(small.rebuilt == nil)
        #expect(summarizer.calls.count == 1)
    }

    @Test func aPromptTooLargeForTheWindowIsRefused() async {
        let condenser = ChatCondenser(counter: WordCounter(window: 60), summarizer: FirstWordsSummarizer())
        let profile = AIRequestProfile(id: "chat", instructions: "x", maximumResponseTokens: 10)
        await #expect(throws: AIServiceError.contextFull) {
            try await condenser.prepare(
                profile: profile, summary: nil, turns: [.init(prompt: "a", response: "b")],
                prompt: String(repeating: "w ", count: 80), toolTokens: 0)
        }
    }

    @Test func longAttachmentsAreMapReducedUntilTheyFit() async throws {
        let summarizer = FirstWordsSummarizer()
        summarizer.words = 4
        let condenser = AttachmentCondenser(counter: WordCounter(window: 1_000), summarizer: summarizer)
        let paragraphs = (1...12).map { "Paragraph \($0) " + String(repeating: "detail ", count: 20) }
        let text = paragraphs.joined(separator: "\n\n")
        let result = try await condenser.fit(text, within: 30, chunkBudget: 50, focus: "Keep facts")
        #expect(result.wasCondensed)
        #expect(result.text.split(whereSeparator: \.isWhitespace).count <= 30)
        // Map: each part fits the chunk budget. Reduce: more rounds only while it's still too long.
        #expect(summarizer.calls.allSatisfy { $0.split(whereSeparator: \.isWhitespace).count <= 50 })
        #expect(result.summaries == summarizer.calls.count)

        let short = try await condenser.fit("Short text.", within: 30, chunkBudget: 50, focus: "")
        #expect(short == .init(text: "Short text.", wasCondensed: false, summaries: 0))
    }

    @Test func aReduceThatDoesntShrinkStops() async {
        let summarizer = FirstWordsSummarizer()
        summarizer.words = 1_000
        let condenser = AttachmentCondenser(counter: WordCounter(window: 1_000), summarizer: summarizer)
        await #expect(throws: ContextBudgetError.attachmentTooLong) {
            try await condenser.fit(String(repeating: "word ", count: 100), within: 10, chunkBudget: 200, focus: "")
        }
    }

    @Test func aLongParagraphSplitsAtSentencesThenWords() async {
        let condenser = AttachmentCondenser(counter: WordCounter(window: 1_000), summarizer: FirstWordsSummarizer())
        let sentences = "One two three. Four five six. Seven eight nine."
        let chunks = await condenser.split(sentences, maximumTokens: 4)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.split(separator: " ").count <= 4 })
        let words = await condenser.split(String(repeating: "w ", count: 9), maximumTokens: 3)
        #expect(words.count == 3)
    }

    @Test func aChatCondensesOnTheEngineWhenItsWindowFills() async throws {
        let engine = RecordingAIEngine()
        engine.window = 600
        engine.replies = [String(repeating: "reply ", count: 100)]
        let chat = AIChatModel(engine: engine)
        for index in 1...3 {
            chat.draft = "Question \(index) " + String(repeating: "context ", count: 30)
            chat.send()
            await chat.waitForResponse()
        }
        #expect(!engine.summaries.isEmpty)
        let rebuilt = try #require(engine.rebuilds.last)
        #expect(rebuilt.summary == chat.summary)
        #expect(chat.summarizedMessageCount >= 2)
        #expect(chat.condensationNotice != nil)
        // Every turn still shows; only the model's context was condensed.
        #expect(chat.messages.count == 6)
        #expect(chat.errorMessage == nil)
    }

    @Test func aLongFileIsSummarizedInPartsBeforeItsTurn() async throws {
        let engine = RecordingAIEngine()
        engine.window = 300
        let chat = AIChatModel(engine: engine)
        let file = (1...20).map { "Section \($0) " + String(repeating: "finding ", count: 25) }.joined(separator: "\n\n")
        chat.attach(AIAttachment(source: .file, text: file, name: "report.txt"))
        #expect(chat.attachments.count == 1)
        #expect(chat.canSend)
        chat.draft = "What are the findings?"
        chat.send()
        await chat.waitForResponse()
        #expect(engine.summaries.count > 1)
        let sent = try #require(engine.requests.last?.prompt)
        #expect(sent.contains("<attachment source=\"report.txt\">"))
        #expect(sent.contains("<question>\nWhat are the findings?\n</question>"))
        #expect(sent.split(whereSeparator: \.isWhitespace).count < 300)
        // The turn keeps the shorter text, so Try Again doesn't summarize again.
        #expect(chat.messages.first?.text == sent)
        #expect(chat.condensationNotice?.contains("summarized in parts") == true)
    }
}
