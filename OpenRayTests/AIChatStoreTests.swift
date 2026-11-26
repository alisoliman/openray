import Foundation
import Testing

@testable import OpenRay

@MainActor
struct AIChatStoreTests {
    private func state(_ pairs: [(String, String)], agentID: UUID? = nil, transcript: Data? = nil) -> AIConversationState {
        var messages: [ChatMessage] = []
        for (question, answer) in pairs {
            messages.append(ChatMessage(role: .user, text: question))
            messages.append(ChatMessage(role: .assistant, text: answer))
        }
        return AIConversationState(
            messages: messages, summary: nil, summarizedMessageCount: 0, agentID: agentID, transcript: transcript)
    }

    @Test func chatsRoundTripThroughTheirOwnFileBesideTheLibrary() throws {
        let folder = Slice7Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = folder.appending(path: "library.json")
        let url = ChatStore.url(nextTo: library)
        #expect(url.lastPathComponent == "chats.json")
        #expect(url.deletingLastPathComponent() == folder)
        let agent = UUID()
        let transcript = Data("{\"entries\":[]}".utf8)
        let store = ChatStore(fileURL: url)
        let saved = try #require(store.save(state([("Plan the trip", "Here's a plan.")], agentID: agent, transcript: transcript), id: nil))
        store.pin(saved.id)

        let reopened = ChatStore(fileURL: url)
        let chat = try #require(reopened.chat(id: saved.id))
        #expect(chat.title == "Plan the trip")
        #expect(chat.messages.map(\.text) == ["Plan the trip", "Here's a plan."])
        #expect(chat.messages.map(\.role) == ["user", "assistant"])
        #expect(chat.agentID == agent)
        #expect(chat.transcript == transcript)
        #expect(chat.isPinned)
        #expect(reopened.pinned(at: 1)?.id == saved.id)
        #expect(reopened.pinned(at: 2) == nil)
        // The library file is never written by the chat store.
        #expect(!FileManager.default.fileExists(atPath: library.path))
    }

    @Test func anUnreadableFileIsNeverOverwritten() throws {
        let folder = Slice7Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "chats.json")
        try Data("not json".utf8).write(to: url)
        let store = ChatStore(fileURL: url)
        #expect(store.isReadOnly)
        #expect(store.save(state([("Hi", "Hello")]), id: nil) == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    }

    @Test func savingAgainUpdatesTheSameChat() throws {
        let store = ChatStore(fileURL: nil)
        let first = try #require(store.save(state([("One", "A")]), id: nil))
        let second = try #require(store.save(state([("One", "A"), ("Two", "B")]), id: first.id))
        #expect(first.id == second.id)
        #expect(store.chats.count == 1)
        #expect(store.chat(id: first.id)?.messages.count == 4)
        #expect(store.save(AIConversationState(messages: [], summary: nil, summarizedMessageCount: 0, agentID: nil, transcript: nil), id: nil) == nil)
    }

    @Test func branchingCopiesThePrefixAndLeavesTheOriginal() throws {
        let store = ChatStore(fileURL: nil)
        var conversation = state([("One", "A"), ("Two", "B"), ("Three", "C")], transcript: Data("t".utf8))
        conversation.summary = "Earlier: one"
        conversation.summarizedMessageCount = 2
        let original = try #require(store.save(conversation, id: nil))
        let branchPoint = original.messages[3].id  // the reply "B"
        let branch = try #require(store.branch(original.id, through: branchPoint))
        #expect(branch.id != original.id)
        #expect(branch.branchedFrom == original.id)
        #expect(branch.messages.map(\.text) == ["One", "A", "Two", "B"])
        #expect(branch.transcript == nil)
        #expect(branch.summary == "Earlier: one")
        #expect(store.chat(id: original.id)?.messages.count == 6)

        // A branch point inside the summarized part can't keep the summary.
        let early = try #require(store.branch(original.id, through: original.messages[0].id))
        #expect(early.messages.map(\.text) == ["One"])
        #expect(early.summary == nil)
        #expect(early.summarizedMessageCount == 0)
        #expect(store.branch(original.id, through: UUID()) == nil)
    }

    @Test func deletingMovesToRecentlyDeletedThenPurgesAfterThirtyDays() throws {
        let store = ChatStore(fileURL: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let chat = try #require(store.save(state([("Hi", "Hello")]), id: nil, now: now))
        store.pin(chat.id)
        store.delete(chat.id, now: now)
        #expect(store.recent.isEmpty)
        #expect(store.pinned.isEmpty)
        #expect(store.recentlyDeleted.map(\.id) == [chat.id])
        store.restore(chat.id)
        #expect(store.recent.map(\.id) == [chat.id])
        #expect(!store.chat(id: chat.id)!.isPinned)

        store.delete(chat.id, now: now)
        store.purge(retention: .forever, now: now.addingTimeInterval(10 * 86_400))
        #expect(store.recentlyDeleted.count == 1)
        store.purge(retention: .forever, now: now.addingTimeInterval(31 * 86_400))
        #expect(store.chats.isEmpty)
    }

    @Test func retentionMovesOldUnpinnedChatsToRecentlyDeleted() throws {
        let store = ChatStore(fileURL: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try #require(store.save(state([("Old", "A")]), id: nil, now: now.addingTimeInterval(-40 * 86_400)))
        let pinned = try #require(store.save(state([("Pinned", "B")]), id: nil, now: now.addingTimeInterval(-40 * 86_400)))
        let fresh = try #require(store.save(state([("Fresh", "C")]), id: nil, now: now))
        store.pin(pinned.id)
        store.purge(retention: .days30, now: now)
        #expect(store.chat(id: old.id)?.isDeleted == true)
        #expect(store.chat(id: pinned.id)?.isDeleted == false)
        #expect(store.chat(id: fresh.id)?.isDeleted == false)
    }

    @Test func archiveSearchPinsAndDeleteAll() throws {
        let store = ChatStore(fileURL: nil)
        let trip = try #require(store.save(state([("Plan the Lisbon trip", "Day one…")]), id: nil))
        let budget = try #require(store.save(state([("Budget review", "Totals…")]), id: nil))
        #expect(store.search("lisbon").map(\.id) == [trip.id])
        #expect(store.search("totals").map(\.id) == [budget.id])
        store.archive(trip.id)
        #expect(store.search("lisbon").isEmpty)
        #expect(store.search("lisbon", in: .archived).map(\.id) == [trip.id])
        store.unarchive(trip.id)
        store.pin(trip.id)
        store.pin(budget.id)
        #expect(store.pinned.map(\.id) == [trip.id, budget.id])
        store.movePin(budget.id, by: -1)
        #expect(store.pinned.map(\.id) == [budget.id, trip.id])
        store.unpin(budget.id)
        #expect(store.pinned(at: 1)?.id == trip.id)
        store.deleteAll()
        #expect(store.chats.isEmpty)
    }

    @Test func atMostNinePins() throws {
        let store = ChatStore(fileURL: nil)
        for index in 0..<10 {
            let chat = try #require(store.save(state([("Q\(index)", "A")]), id: nil))
            store.pin(chat.id)
        }
        #expect(store.pinned.count == 9)
        #expect(store.errorMessage?.contains("nine") == true)
    }

    @Test func continueInChatMovesThePanelConversationIntoTheWindow() async throws {
        let engine = RecordingAIEngine()
        engine.transcript = Data("transcript".utf8)
        let model = Slice7Fixtures.launcher(engine: engine)
        defer { model.stop() }
        model.openAI(.chat)
        model.ai.draft = "Draft the agenda"
        model.ai.send()
        await model.ai.waitForResponse()
        let entry = try #require(model.actions(for: nil).first { $0.id == "chatWindow" })
        #expect(entry.title == "Continue in Chat Window")
        #expect(entry.key == "j")
        entry.perform()
        let hub = model.aiHub
        #expect(hub.windowRequests == 1)
        #expect(model.ai.messages.isEmpty)
        let window = hub.windowChat
        #expect(window.messages.map(\.text) == ["Draft the agenda", "A helpful reply."])
        let saved = try #require(window.chatID.flatMap(hub.chatStore.chat(id:)))
        #expect(saved.transcript == Data("transcript".utf8))
        #expect((window.engine as? RecordingAIEngine)?.restored == [Data("transcript".utf8)])

        // The window keeps the conversation going and saves each reply.
        window.draft = "Add a break"
        window.send()
        await window.waitForResponse()
        #expect(hub.chatStore.chat(id: saved.id)?.messages.count == 4)

        // Branch from the first reply, then start over.
        hub.branch(from: window.messages[1].id)
        #expect(window.chatID != saved.id)
        #expect(window.messages.count == 2)
        hub.newWindowChat()
        #expect(window.messages.isEmpty)
        #expect(hub.chatStore.recent.count == 2)
    }

    @Test func openingAChatWithoutATranscriptRebuildsFromItsMessages() throws {
        let engine = RecordingAIEngine()
        let model = Slice7Fixtures.launcher(engine: engine)
        defer { model.stop() }
        let hub = model.aiHub
        let saved = try #require(hub.chatStore.save(state([("One", "A"), ("Two", "B")]), id: nil))
        hub.show(saved.id)
        let windowEngine = try #require(hub.windowChat.engine as? RecordingAIEngine)
        #expect(windowEngine.restored.isEmpty)
        #expect(windowEngine.rebuilds.last?.turns == [.init(prompt: "One", response: "A"), .init(prompt: "Two", response: "B")])
        #expect(hub.windowChat.chatID == saved.id)
    }
}
