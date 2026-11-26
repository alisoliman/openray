import AppKit
import Foundation
import Testing

@testable import OpenRay

/// The fixes from the Slice 7 review: deleted chats stay deleted, nothing is lost on transfer
/// or navigation, agent edits apply in open chats, the model's context matches what's shown,
/// and AI Commands with required arguments run through the argument fields.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct AIReviewFixTests {
    private func state(_ pairs: [(String, String)]) -> AIConversationState {
        var messages: [ChatMessage] = []
        for (question, answer) in pairs {
            messages.append(ChatMessage(role: .user, text: question))
            messages.append(ChatMessage(role: .assistant, text: answer))
        }
        return AIConversationState(messages: messages, summary: nil, summarizedMessageCount: 0, agentID: nil, transcript: nil)
    }

    // MARK: Deleted chats

    @Test func savingNeverRevivesADeletedChat() throws {
        let store = ChatStore(fileURL: nil)
        let chat = try #require(store.save(state([("Hi", "Hello")]), id: nil))
        store.delete(chat.id)
        #expect(store.refusal(forSaving: chat.id) == .inRecentlyDeleted)
        #expect(store.save(state([("Hi", "Hello"), ("More", "Sure")]), id: chat.id) == nil)
        #expect(store.chat(id: chat.id)?.isDeleted == true)
        #expect(store.chat(id: chat.id)?.messages.count == 2)
        store.deletePermanently(chat.id)
        #expect(store.refusal(forSaving: chat.id) == .removed)
        #expect(store.save(state([("Hi", "Hello")]), id: chat.id) == nil)
        #expect(store.chats.isEmpty)
    }

    @Test func aChatInRecentlyDeletedOpensReadOnlyAndClosingItSavesNothing() throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let hub = model.aiHub
        let saved = try #require(hub.chatStore.save(state([("Plan", "Steps")]), id: nil))
        hub.deleteChat(saved.id)
        #expect(hub.show(saved.id))
        let window = hub.windowChat
        #expect(window.isReadOnly)
        #expect(!window.canRetry)
        window.draft = "Continue"
        #expect(!window.canSend)
        window.send()
        #expect(window.messages.count == 2)
        // Closing, switching or starting over saves nothing into it.
        #expect(hub.saveWindowChat())
        #expect(hub.newWindowChat())
        #expect(hub.chatStore.chat(id: saved.id)?.isDeleted == true)
        // Restore makes it writable again.
        #expect(hub.show(saved.id))
        hub.restoreChat(saved.id)
        #expect(!window.isReadOnly)
    }

    @Test func deletingTheOpenChatMidReplyStopsItAndNeverWritesItBack() async throws {
        let engine = RecordingAIEngine()
        let model = Slice7Fixtures.launcher(engine: engine)
        defer { model.stop() }
        let hub = model.aiHub
        let saved = try #require(hub.chatStore.save(state([("One", "A")]), id: nil))
        #expect(hub.show(saved.id))
        let window = hub.windowChat
        let windowEngine = try #require(window.engine as? RecordingAIEngine)
        windowEngine.toolCalls = []
        window.draft = "Two"
        window.send()
        #expect(window.isGenerating)
        hub.deleteAllChats()
        #expect(window.isReadOnly)
        await window.waitForResponse()
        for _ in 0..<50 where window.chatID != nil || window.isReadOnly { await Task.yield() }
        #expect(hub.chatStore.chats.isEmpty)
        #expect(window.chatID == nil)
        #expect(window.messages.isEmpty)
        #expect(!window.isReadOnly)
    }

    @Test func emptyingRecentlyDeletedDetachesTheOpenChat() async throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let hub = model.aiHub
        let saved = try #require(hub.chatStore.save(state([("One", "A")]), id: nil))
        hub.chatStore.delete(saved.id)
        #expect(hub.show(saved.id))
        hub.emptyRecentlyDeleted()
        for _ in 0..<50 where hub.windowChat.chatID != nil { await Task.yield() }
        #expect(hub.windowChat.chatID == nil)
        #expect(hub.windowChat.messages.isEmpty)
        #expect(hub.saveWindowChat())
        #expect(hub.chatStore.chats.isEmpty)
    }

    // MARK: No data loss

    @Test func aFailedWriteChangesNothing() throws {
        let store = ChatStore(fileURL: nil)
        let chat = try #require(store.save(state([("Hi", "Hello")]), id: nil))
        store.writeFailureForTesting = "The disk is full."
        #expect(!store.pin(chat.id))
        #expect(!store.delete(chat.id))
        #expect(!store.deleteAll())
        #expect(store.save(state([("New", "Chat")]), id: nil) == nil)
        #expect(store.chats.map(\.id) == [chat.id])
        #expect(store.chat(id: chat.id)?.isPinned == false)
        #expect(store.chat(id: chat.id)?.isDeleted == false)
        #expect(store.errorMessage?.contains("disk is full") == true)
    }

    @Test func continueInChatKeepsThePanelConversationUntilItsCopyIsSaved() async throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        model.openAI(.chat)
        model.ai.draft = "Keep me"
        model.ai.send()
        await model.ai.waitForResponse()
        let hub = model.aiHub
        hub.chatStore.writeFailureForTesting = "No space."
        #expect(!hub.continueInChat())
        #expect(model.ai.messages.map(\.text) == ["Keep me", "A helpful reply."])
        #expect(hub.windowRequests == 0)
        #expect(model.feedback?.text.contains("No space") == true)
        #expect(hub.chatStore.chats.isEmpty)
        hub.chatStore.writeFailureForTesting = nil
        #expect(hub.continueInChat())
        #expect(model.ai.messages.isEmpty)
        #expect(hub.windowChat.messages.count == 2)
    }

    @Test func aWindowChatThatCantBeSavedStaysOpen() async throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let hub = model.aiHub
        let other = try #require(hub.chatStore.save(state([("Other", "Chat")]), id: nil))
        let window = hub.windowChat
        window.draft = "Unsaved question"
        hub.chatStore.writeFailureForTesting = "Read-only volume."
        window.send()
        await window.waitForResponse()
        #expect(hub.saveError?.contains("Read-only volume") == true)
        #expect(!hub.show(other.id))
        #expect(!hub.newWindowChat())
        #expect(window.messages.first?.text == "Unsaved question")
        hub.chatStore.writeFailureForTesting = nil
        #expect(hub.show(other.id))
        #expect(hub.saveError == nil)
        #expect(hub.chatStore.chats.count == 2)
    }

    @Test func aTurnIsSavedEvenWhenTheModelFails() async throws {
        let engine = RecordingAIEngine()
        let model = Slice7Fixtures.launcher(engine: engine)
        defer { model.stop() }
        let hub = model.aiHub
        let window = hub.windowChat
        (window.engine as? RecordingAIEngine)?.failure = .busy
        (window.engine as? RecordingAIEngine)?.replies = []
        window.draft = "Does this survive?"
        window.send()
        await window.waitForResponse()
        #expect(hub.chatStore.chats.first?.messages.map(\.text) == ["Does this survive?"])
    }

    // MARK: Agents in open chats

    @Test func removingAnAgentsToolStopsItInOpenChats() async throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let hub = model.aiHub
        var researcher = Agent(name: "Researcher", instructions: "Look things up.", toolIDs: ["searchClipboard"])
        #expect(hub.save(researcher))
        let chat = model.ai
        chat.selectAgent(researcher)
        chat.draft = "What did I copy?"
        chat.send()
        await chat.waitForResponse()
        let engine = try #require(chat.engine as? RecordingAIEngine)
        #expect(engine.requests.last?.tools.map(\.id) == ["searchClipboard"])

        researcher.toolIDs = []
        researcher.instructions = "Answer from memory."
        #expect(hub.save(researcher))
        chat.draft = "And now?"
        chat.send()
        await chat.waitForResponse()
        let request = try #require(engine.requests.last)
        #expect(request.tools.isEmpty)
        #expect(request.toolMode == .none)
        #expect(request.profile.instructions.hasPrefix("Answer from memory."))
        // The session was rebuilt for the new definition, with the conversation kept.
        #expect(engine.rebuilds.last?.profile.instructions.hasPrefix("Answer from memory.") == true)
        #expect(engine.rebuilds.last?.turns.first?.prompt == "What did I copy?")
    }

    @Test func deletingTheActiveAgentMidReplyFallsBackToTheAssistant() async throws {
        let engine = RecordingAIEngine()
        let model = Slice7Fixtures.launcher(engine: engine)
        defer { model.stop() }
        let hub = model.aiHub
        let coach = Agent(name: "Coach", instructions: "Coach me.", toolIDs: ["searchNotes"])
        #expect(hub.save(coach))
        model.ai.selectAgent(coach)
        model.ai.draft = "First"
        model.ai.send()
        #expect(hub.deleteAgent(coach.id))
        #expect(model.ai.agent == nil)
        await model.ai.waitForResponse()
        model.ai.draft = "Second"
        model.ai.send()
        await model.ai.waitForResponse()
        #expect(engine.requests.last?.profile == .chat)
        #expect(engine.requests.last?.tools.isEmpty == true)
    }

    @Test func aRestoredTranscriptGetsTheAgentsCurrentInstructions() throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let hub = model.aiHub
        let writer = Agent(name: "Writer", instructions: "New rules.")
        #expect(hub.save(writer))
        var saved = state([("Q", "A")])
        saved.agentID = writer.id
        saved.transcript = Data("old".utf8)
        saved.summary = "Earlier"
        let chat = try #require(hub.chatStore.save(saved, id: nil))
        #expect(hub.show(chat.id))
        let engine = try #require(hub.windowChat.engine as? RecordingAIEngine)
        let context = try #require(engine.restoredContexts.last)
        #expect(context.instructions.hasPrefix("New rules."))
        #expect(context.instructions.contains("<summary>\nEarlier\n</summary>"))
    }

    // MARK: Model context

    @Test func reopeningAChatKeepsItsSessionAndRetryRegistersToolsAgain() {
        let chat = AIRequestProfile.chat
        var ledger = AISessionLedger(exists: true, profile: chat, toolIDs: ["searchNotes"])
        // Esc, then Tab back into the same chat: the conversation stays.
        #expect(ledger.keepsSession(preparing: .chat))
        #expect(!ledger.keepsSession(preparing: .proofread))
        #expect(ledger.plan(for: chat, toolIDs: ["searchNotes"]) == .reuse)
        #expect(ledger.plan(for: chat, toolIDs: []) == .retool)
        // Try Again rebuilds the transcript without tools, so the same tools register again.
        ledger = ledger.afterRebuildingWithoutTools()
        #expect(ledger.plan(for: chat, toolIDs: ["searchNotes"]) == .retool)
        // Another configuration, or a session built for an action, starts fresh.
        #expect(ledger.plan(for: AIRequestProfile(id: "x", instructions: "y"), toolIDs: []) == .fresh)
        #expect(AISessionLedger(exists: true, action: .chat).plan(for: chat, toolIDs: []) == .fresh)
        #expect(!AISessionLedger().keepsSession(preparing: .chat))
        var command = AIRequestProfile.chat
        command.keepsContext = false
        #expect(AISessionLedger(exists: true, profile: command).plan(for: command, toolIDs: ["a"]) == .fresh)
    }

    @Test func reopeningTheSameChatNeitherResetsNorRebuildsIt() async {
        let engine = RecordingAIEngine()
        let model = Slice7Fixtures.launcher(engine: engine)
        defer { model.stop() }
        model.openAI(.chat, prompt: "Hello")
        await model.ai.waitForResponse()
        let resets = engine.resetCount
        model.leaveAI()
        model.openAI(.chat, prompt: "Hello")
        model.ai.draft = "Follow-up"
        model.ai.send()
        await model.ai.waitForResponse()
        #expect(engine.resetCount == resets)
        #expect(engine.rebuilds.isEmpty)
        #expect(engine.requests.map(\.prompt) == ["Hello", "Follow-up"])
    }

    // MARK: AI Commands with arguments

    private func addPersonaCommand(to model: LauncherModel) throws -> AICommand {
        let record = AICommandRecord(name: "Persona Reply", prompt: "Reply to {selection} as {argument name=\"persona\" | raw}.")
        #expect(model.store.update { $0.aiCommands.append(record) })
        model.commandCatalogDidChange()
        return AICommand(record: record)
    }

    @Test func searchAICommandsRowsAskForRequiredArguments() async throws {
        let engine = RecordingAIEngine()
        let model = Slice7Fixtures.launcher(engine: engine, selection: "Where are you?")
        defer { model.stop() }
        let command = try addPersonaCommand(to: model)
        model.navigate(to: .provided(AICommandProvider.scope))
        let row = try #require(model.results.first { $0.title == "Persona Reply" })
        #expect(row.id == command.id)
        model.perform(row)
        let session = try #require(model.argumentSession)
        #expect(session.specs.map(\.name) == ["persona"])
        model.setArgumentValue("a pirate", at: 0)
        model.submitArguments()
        await model.ai.waitForResponse()
        #expect(model.destination == .ai)
        #expect(engine.requests.last?.prompt.contains("as a pirate.") == true)
        #expect(engine.requests.last?.prompt.contains("Where are you?") == true)
        #expect(model.store.database.usage.contains { $0.id == command.id })
    }

    @Test func quickFixOpensTheArgumentFieldsOfItsCommand() throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let command = try addPersonaCommand(to: model)
        #expect(model.aiHub.updateSettings { $0.quickFixCommandID = command.id })
        let quickFix = try #require(model.bindableCommands.first { $0.id == AICommandProvider.quickFixID })
        model.perform(quickFix)
        #expect(model.argumentSession?.item.id == command.id)
        #expect(model.argumentSession?.specs.first?.name == "persona")
    }

    @Test func argumentsInsideReferencedSnippetsGetFields() throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        #expect(model.store.update {
            $0.snippets = [Snippet(name: "Sig", keyword: "", content: "Regards, {argument name=\"sender\"}")]
        })
        let record = AICommandRecord(name: "Sign It", prompt: "{selection}\n\n{snippet name=\"Sig\"}")
        #expect(model.store.update { $0.aiCommands.append(record) })
        let descriptor = try #require(
            model.registry.descriptor(for: ProvidedRef(provider: "aicommand", id: AICommand.id(for: record.id)), in: model))
        #expect(descriptor.arguments.map(\.name).contains("sender"))
    }

    @Test func deletingACommandRemovesItsAliasAndHotkey() throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let command = try addPersonaCommand(to: model)
        #expect(model.store.update { $0.commandBindings.append(CommandBinding(targetID: command.id, alias: "pr")) })
        model.navigate(to: .provided(AICommandProvider.scope))
        let row = try #require(model.results.first { $0.id == command.id })
        guard case .provided(let ref) = row.action,
            case .store(let remove)? = model.registry.provider(id: "aicommand")?.deletion(for: row, ref: ref, in: model)
        else {
            Issue.record("Expected a store deletion")
            return
        }
        #expect(remove())
        #expect(!model.store.database.commandBindings.contains { $0.targetID == command.id })
    }

    @Test func aCopyOfTranslateTranslatesWithTheModel() throws {
        let copy = AICommand(record: AICommand.translate.duplicate())
        #expect(copy.performer == .model)
        #expect(copy.prompt.hasPrefix("Translate the following text into {argument name=\"language\""))
        #expect(copy.prompt.hasSuffix("{selection}"))
        #expect(copy.validationMessage == nil)
        let plan = copy.template.plan(snippets: { _ in nil })
        #expect(plan.argumentSpecs.first?.defaultValue == "English")
    }

    @Test func importsSkipBadRowsWithoutCuttingAnythingShort() throws {
        let long = String(repeating: "x", count: AICommandTransfer.maximumPromptCharacters + 1)
        let json = "[{\"name\": \"Good\", \"prompt\": \"Do {selection}\"}, {\"name\": \"Long\", \"prompt\": \"\(long)\"}, {\"prompt\": \"x\"}]"
        let result = try AICommandTransfer.importCommands(from: Data(json.utf8))
        #expect(result.records.map(\.name) == ["Good"])
        #expect(result.skipped == 2)
        #expect(result.summary.contains("skipped 2"))
        #expect(result.records[0].prompt == "Do {selection}")
    }

    // MARK: Attachments and defaults

    @Test func aCaptureThatFinishesAfterTheChatChangedIsDropped() async throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let hub = model.aiHub
        let capture = GatedCapture()
        hub.screenCapture = capture
        hub.updateSettings { $0.screenContextEnabled = true }
        let chat = model.ai
        let task = Task { await hub.attachScreen(.focusedWindow(processID: 42), to: chat) }
        for _ in 0..<100 where !capture.isWaiting { await Task.yield() }
        chat.newConversation()
        capture.finish()
        await task.value
        #expect(chat.attachments.isEmpty)
        #expect(chat.errorMessage == nil)
    }

    @Test func theTestHostsDefaultEngineNeverReachesAModel() {
        let chat = AIChatModel()
        #expect(chat.engine is InertAIEngine)
        #expect(!chat.availability.isAvailable)
        #expect(LiveScreenCapture(sideEffects: SideEffectGuard(mode: .live)).hasPermission == false)
        #expect(SpeechDictation(sideEffects: SideEffectGuard(mode: .live)).unavailableReason == "Dictation is off here.")
    }

    @Test func dictationHasItsUsageStrings() {
        // The app's Info.plist carries them, so macOS can ask; the test host bundle is the app.
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["NSMicrophoneUsageDescription"] != nil)
        #expect(info["NSSpeechRecognitionUsageDescription"] != nil)
    }
}

/// A screen capture that waits until the test lets it finish.
@MainActor
private final class GatedCapture: AIScreenCapturing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false
    var isWaiting: Bool { continuation != nil }
    var hasPermission: Bool { true }
    func requestPermission() -> Bool { true }
    func capture(_ target: AIScreenTarget) async throws -> (png: Data, title: String) {
        // Finishing first lets a late capture return at once, so the test can never hang.
        if !isFinished { await withCheckedContinuation { continuation = $0 } }
        return (Data([1, 2, 3]), "Window")
    }
    func finish() {
        isFinished = true
        continuation?.resume()
        continuation = nil
    }
}
