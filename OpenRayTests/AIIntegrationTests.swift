import AppKit
import Foundation
import Testing

@testable import OpenRay

/// Slice 7 on top of Slices 5, 6 and 8: calendar and command tools, chats in library archives,
/// and the re-review fixes (retention through the hub, grants enforced at each tool call).
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct AIIntegrationTests {
    private func state(_ pairs: [(String, String)]) -> AIConversationState {
        var messages: [ChatMessage] = []
        for (question, answer) in pairs {
            messages.append(ChatMessage(role: .user, text: question))
            messages.append(ChatMessage(role: .assistant, text: answer))
        }
        return AIConversationState(messages: messages, summary: nil, summarizedMessageCount: 0, agentID: nil, transcript: nil)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: Calendar tool

    private func calendar(_ events: [CalendarEvent], access: CalendarAccess = .fullAccess, now: Date) -> CalendarService {
        let source = FakeCalendarSource(access: access)
        source.stored = events
        return CalendarService(source: source, opener: FakeURLOpener(), now: { now })
    }

    @Test func theCalendarToolListsUpcomingEventsFromShownCalendars() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = calendar(
            [
                CalendarEvent(title: "Standup", start: now.addingTimeInterval(3_600), end: now.addingTimeInterval(5_400), calendarID: "work", calendarTitle: "Work"),
                CalendarEvent(title: "Dentist", start: now.addingTimeInterval(7_200), end: now.addingTimeInterval(9_000), calendarID: "home"),
                CalendarEvent(title: "Offsite", start: now.addingTimeInterval(5 * 86_400), end: now.addingTimeInterval(5 * 86_400 + 3_600), calendarID: "work"),
            ], now: now)
        let store = LibraryStore(fileURL: nil)
        var preferences = CalendarPreferences()
        preferences.hiddenCalendarIDs = ["home"]
        #expect(preferences.save(to: store))
        let tool = CalendarReadTool(reader: CalendarServiceReader(service: service, store: store))
        #expect(tool.spec.effect == .read)
        let today = try await tool.run(AIToolArguments())
        #expect(today.contains("Standup"))
        #expect(today.contains("Work"))
        #expect(!today.contains("Dentist"))  // a hidden calendar
        #expect(!today.contains("Offsite"))  // beyond one day
        #expect(try await tool.run(AIToolArguments(["days": "7"])).contains("Offsite"))
        #expect(try await tool.run(AIToolArguments(["days": "7", "query": "off"])) .split(separator: "\n").count == 1)
        #expect(try await tool.run(AIToolArguments(["query": "nothing"])).hasPrefix("No events"))
    }

    @Test func theCalendarToolNeverAsksForAccess() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = FakeCalendarSource(access: .notDetermined)
        let service = CalendarService(source: source, opener: FakeURLOpener(), now: { now })
        let tool = CalendarReadTool(reader: CalendarServiceReader(service: service, store: LibraryStore(fileURL: nil)))
        #expect(try await tool.run(AIToolArguments()).contains("Open My Schedule"))
        #expect(source.requestCount == 0)
    }

    // MARK: Command tools

    @MainActor
    private final class FakeRunner: AICommandRunning {
        var catalog: [String: [AIRunnableCommand]] = [
            "system": [AIRunnableCommand(id: "system.lockScreen", title: "Lock Screen"), AIRunnableCommand(id: "system.emptyTrash", title: "Empty Trash")],
            "windows": [AIRunnableCommand(id: "window.leftHalf", title: "Left Half")],
        ]
        var results: [String: AICommandRunResult] = [:]
        var ran: [String] = []
        func commands(fromProvider provider: String) -> [AIRunnableCommand] { catalog[provider] ?? [] }
        func run(commandID: String) -> AICommandRunResult {
            ran.append(commandID)
            return results[commandID] ?? .ran
        }
    }

    @Test func commandToolsRunByNameAndReportTheLaunchersAnswer() async throws {
        let runner = FakeRunner()
        runner.results["system.emptyTrash"] = .askedToConfirm("Empty the Trash?")
        let system = RunCommandTool.system(runner: runner)
        #expect(system.spec.effect == .system)
        #expect(system.spec.summary.contains("Lock Screen, Empty Trash"))
        #expect(try await system.run(AIToolArguments(["command": "lock screen"])) == "Ran Lock Screen.")
        let trash = try await system.run(AIToolArguments(["command": "Empty Trash"]))
        #expect(trash.contains("asked the person to confirm “Empty the Trash?”"))
        #expect(try await system.run(AIToolArguments(["command": "Format Disk"])).contains("no command named"))
        #expect(runner.ran == ["system.lockScreen", "system.emptyTrash"])
        let windows = RunCommandTool.windows(runner: runner)
        #expect(windows.spec.extensionID == "windows")
        #expect(try await windows.run(AIToolArguments(["command": "Left Half"])) == "Ran Left Half.")
        #expect(windows.describe(AIToolArguments(["command": "Left Half"])) == "Run “Left Half” on this Mac")
    }

    @Test func aDestructiveSystemCommandStillAsksItsOwnQuestion() throws {
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: RecordingAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(), registry: CommandRegistry(providers: [SystemCommandProvider()]))
        defer { model.stop() }
        let runner = LauncherCommandRunner(model: model)
        let commands = runner.commands(fromProvider: "system")
        let trash = try #require(commands.first { $0.title == "Empty Trash" })
        // Slice 5's question comes first; nothing has run.
        guard case .askedToConfirm(let question) = runner.run(commandID: trash.id) else {
            Issue.record("Empty Trash should ask first")
            return
        }
        #expect(question.lowercased().contains("trash"))
        guard case .provided(let confirmation)? = model.confirmation else {
            Issue.record("Expected Slice 5's confirmation")
            return
        }
        #expect(confirmation.isDestructive)
        #expect(runner.run(commandID: "system.nope") == .failed("That command isn't available."))
    }

    @Test func calendarSystemAndWindowToolsJoinTheCatalogAndActionsAreRefusedHere() async throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let hub = model.aiHub
        hub.calendarReader = CalendarServiceReader(
            service: calendar([], now: .now), store: model.store)
        hub.commandRunner = FakeRunner()
        let broker = try #require(hub.makeBroker())
        let extensions = AIToolCatalog.extensions(for: broker.specs).map(\.id)
        #expect(extensions.suffix(3) == ["calendar", "system", "windows"])
        // System actions never run in the test host: refused before any card.
        let output = await broker.invoke(toolID: "runSystemCommand", arguments: AIToolArguments(["command": "Lock Screen"]))
        #expect(output.contains("while tests run"))
        #expect(broker.pendingApprovals.isEmpty)
        #expect(AIMentionParser.mentions(in: "@schedule today", extensions: AIToolCatalog.extensions(for: broker.specs)).map(\.extensionID) == ["calendar"])
    }

    // MARK: Grants at each call

    @MainActor
    private final class Grant {
        var isOn = true
    }

    @Test func aGrantRevokedDuringApprovalStopsTheCall() async throws {
        let read = FakeToolExecutor("searchClipboard", extensionID: "clipboard")
        let broker = AIToolBroker(executors: [read], permissions: InMemoryToolPermissions(["searchClipboard": .ask]))
        let grant = Grant()
        let call = Task {
            await broker.invoke(toolID: "searchClipboard", arguments: AIToolArguments(), isGranted: { _ in grant.isOn })
        }
        await waitFor { !broker.pendingApprovals.isEmpty }
        let card = try #require(broker.pendingApprovals.first)
        grant.isOn = false
        broker.resolve(card.id, .allow)
        #expect(await call.value.contains("no longer allowed"))
        #expect(read.runs.isEmpty)
        // Not granted at all: refused before anyone is asked.
        #expect(await broker.invoke(toolID: "searchClipboard", arguments: AIToolArguments(), isGranted: { _ in false }).contains("no longer allowed"))
        #expect(broker.pendingApprovals.isEmpty)
    }

    @Test func revokingAnAgentsToolStopsItsReplyBeforeTheToolRuns() async throws {
        let engine = RecordingAIEngine()
        engine.toolCalls = [("searchClipboard", [:])]
        let model = Slice7Fixtures.launcher(engine: engine)
        defer { model.stop() }
        let hub = model.aiHub
        LibraryToolPermissions(store: model.store).setPermission(.ask, for: "searchClipboard")
        var reader = Agent(name: "Reader", instructions: "Read things.", toolIDs: ["searchClipboard"])
        #expect(hub.save(reader))
        let chat = model.ai
        chat.selectAgent(reader)
        chat.draft = "What did I copy?"
        chat.send()
        let broker = try #require(chat.environment.toolBroker)
        await waitFor { !broker.pendingApprovals.isEmpty }
        try #require(!broker.pendingApprovals.isEmpty)
        reader.toolIDs = []
        #expect(hub.save(reader))
        await chat.waitForResponse()
        #expect(chat.errorMessage?.contains("tools changed") == true)
        #expect(engine.toolOutputs.allSatisfy { !$0.contains("From") })
        #expect(broker.activity.allSatisfy { $0.outcome != .ran })
    }

    @Test func deletingTheAgentMidReplyStopsTheReply() async throws {
        let engine = RecordingAIEngine()
        engine.toolCalls = [("searchNotes", [:])]
        let model = Slice7Fixtures.launcher(engine: engine)
        defer { model.stop() }
        let hub = model.aiHub
        LibraryToolPermissions(store: model.store).setPermission(.ask, for: "searchNotes")
        let agent = Agent(name: "Notes", instructions: "Use notes.", toolIDs: ["searchNotes"])
        #expect(hub.save(agent))
        model.ai.selectAgent(agent)
        model.ai.draft = "Find my plan"
        model.ai.send()
        let broker = try #require(model.ai.environment.toolBroker)
        await waitFor { !broker.pendingApprovals.isEmpty }
        try #require(!broker.pendingApprovals.isEmpty)
        #expect(hub.deleteAgent(agent.id))
        await model.ai.waitForResponse()
        #expect(model.ai.errorMessage?.contains("agent was deleted") == true)
        #expect(broker.activity.allSatisfy { $0.outcome != .ran })
    }

    // MARK: Retention and deleted chats

    @Test func retentionThatDeletesTheOpenChatMakesItReadOnlyAndUnbranchable() throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let hub = model.aiHub
        let old = try #require(hub.chatStore.save(state([("Old", "Chat")]), id: nil, now: .now.addingTimeInterval(-40 * 86_400)))
        #expect(hub.show(old.id))
        #expect(!hub.windowChat.isReadOnly)
        #expect(hub.setChatRetention(.days30))
        #expect(hub.chatStore.chat(id: old.id)?.isDeleted == true)
        #expect(hub.windowChat.isReadOnly)
        #expect(!hub.windowChat.canSend)
        #expect(hub.chatStore.branch(old.id, through: old.messages[1].id) == nil)
        #expect(!hub.branch(from: old.messages[1].id))
        #expect(hub.chatStore.chats.count == 1)
    }

    @Test func aChatDeletedBehindTheWindowsBackSaysSo() throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let hub = model.aiHub
        let saved = try #require(hub.chatStore.save(state([("One", "A")]), id: nil))
        #expect(hub.show(saved.id))
        hub.windowChat.draft = "More"
        hub.chatStore.delete(saved.id)  // not through the hub
        #expect(hub.saveWindowChat())
        #expect(hub.windowChat.isReadOnly)
        #expect(hub.saveError?.contains("Recently Deleted") == true)
    }

    @Test func aDelayedDetachNeverClearsTheNextConversation() async {
        let chat = AIChatModel(engine: RecordingAIEngine())
        chat.draft = "Old"
        let old = chat.conversationToken
        chat.newConversation()
        chat.draft = "New conversation"
        await chat.detach(ifStill: old)
        #expect(chat.draft == "New conversation")
        #expect(!chat.isReadOnly)
    }

    @Test func continueInChatWaitsForTheWindowsReply() async throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let hub = model.aiHub
        model.openAI(.chat, prompt: "Panel question")
        await model.ai.waitForResponse()
        let window = hub.windowChat
        window.draft = "Window question"
        window.send()
        #expect(window.isGenerating)
        #expect(!hub.continueInChat())
        #expect(model.ai.messages.count == 2)
        #expect(model.feedback?.text.contains("still writing") == true)
        await window.waitForResponse()
    }

    // MARK: The chats file

    @Test func aFileReplacedOnDiskIsReadAgainNotOverwritten() throws {
        let folder = Slice7Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = ChatStore.url(nextTo: folder.appending(path: "library.json"))
        let store = ChatStore(fileURL: url)
        let mine = try #require(store.save(state([("Mine", "A")]), id: nil))
        // An import writes another file in its place.
        let other = ChatStore(fileURL: folder.appending(path: "other.json"))
        let theirs = try #require(other.save(state([("Theirs", "B")]), id: nil))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: folder.appending(path: "other.json"), to: url)
        #expect(!store.pin(mine.id))
        #expect(store.errorMessage?.contains("replaced on disk") == true)
        #expect(store.chats.map(\.id) == [theirs.id])
        #expect(ChatStore(fileURL: url).chats.map(\.id) == [theirs.id])
    }

    @Test func chatsMoveIntoTheirFolderOnce() throws {
        let folder = Slice7Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = folder.appending(path: "library.json")
        let legacy = folder.appending(path: ChatStore.fileName)
        let old = ChatStore(fileURL: legacy)
        let chat = try #require(old.save(state([("Kept", "Yes")]), id: nil))
        ChatStore.migrateLegacyFile(nextTo: library)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(ChatStore(fileURL: ChatStore.url(nextTo: library)).chat(id: chat.id) != nil)
    }

    @Test func archivesMergeOrReplaceChatsByTheStoresReadRule() throws {
        let existing = ChatStore(fileURL: nil)
        let here = try #require(existing.save(state([("Here", "A")]), id: nil))
        let shared = try #require(existing.save(state([("Shared", "Old")]), id: nil))
        let folder = Slice7Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archiveURL = folder.appending(path: "archive.json")
        let archived = ChatStore(fileURL: archiveURL)
        let incoming = try #require(archived.save(state([("There", "B")]), id: nil))
        let hereURL = folder.appending(path: "here.json")
        let hereFile = ChatStore(fileURL: hereURL)
        _ = hereFile.save(state([("Here", "A")]), id: nil)
        let incomingData = try Data(contentsOf: archiveURL)
        let existingData = try Data(contentsOf: hereURL)
        #expect(ChatStore.isReadable(incomingData))
        #expect(!ChatStore.isReadable(Data("not chats".utf8)))
        #expect(!ChatStore.isReadable(Data(#"{"version": 2, "chats": []}"#.utf8)))

        let replaced = try #require(ChatStore.combined(existing: existingData, incoming: incomingData, merging: false))
        let merged = try #require(ChatStore.combined(existing: existingData, incoming: incomingData, merging: true))
        try replaced.write(to: folder.appending(path: "replaced.json"))
        try merged.write(to: folder.appending(path: "merged.json"))
        #expect(ChatStore(fileURL: folder.appending(path: "replaced.json")).chats.map(\.id) == [incoming.id])
        #expect(Set(ChatStore(fileURL: folder.appending(path: "merged.json")).chats.map(\.title)) == ["Here", "There"])
        #expect(ChatStore.combined(existing: existingData, incoming: Data("x".utf8), merging: true) == nil)
        _ = (here, shared)
    }

    @Test func archivesCarryChatsAndMergeThemIntoALibraryThatHasSome() throws {
        let source = try TemporaryLibrary()
        let sourceChats = ChatStore(fileURL: ChatStore.url(nextTo: source.folder.appending(path: "library.json")))
        let travelling = try #require(sourceChats.save(state([("Travel", "Plans")]), id: nil))
        let built = try LibraryArchive.make(
            database: source.store.database, directory: source.folder, categories: [.otherData], passphrase: nil,
            iterations: LibraryArchive.iterationRange.lowerBound)
        let contents = try LibraryArchive.read(built.data)
        #expect(contents.files.keys.contains(ChatStore.archivePath))

        let target = try TemporaryLibrary()
        let targetChats = ChatStore(fileURL: ChatStore.url(nextTo: target.folder.appending(path: "library.json")))
        let staying = try #require(targetChats.save(state([("Stay", "Here")]), id: nil))
        _ = try target.store.importArchive(contents, categories: [.otherData], mode: .merge)
        let after = ChatStore(fileURL: ChatStore.url(nextTo: target.folder.appending(path: "library.json")))
        #expect(Set(after.chats.map(\.id)) == [travelling.id, staying.id])
        // The open store notices the import instead of writing over it.
        #expect(!targetChats.pin(staying.id))
        #expect(Set(targetChats.chats.map(\.id)) == [travelling.id, staying.id])

        // An unreadable chats file is left out of an export, and the export says so.
        try source.write(ChatStore.archivePath, "not chats")
        let unreadable = try LibraryArchive.make(
            database: source.store.database, directory: source.folder, categories: [.otherData], passphrase: nil,
            iterations: LibraryArchive.iterationRange.lowerBound)
        #expect(try LibraryArchive.read(unreadable.data).files.isEmpty)
        #expect(unreadable.omissions.contains { $0.contains("chats") })
    }

    @Test func dictationsSignatureEntitlementIsDeclared() throws {
        // The app's own signature carries Audio Input, which the hardened runtime needs for the
        // microphone; package-release.sh checks the shipped signature for it.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "OpenRay.entitlements")
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: source), format: nil) as? [String: Any])
        #expect(plist["com.apple.security.device.audio-input"] as? Bool == true)
    }
}
