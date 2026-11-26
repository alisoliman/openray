import AppKit
import Foundation
import Testing

@testable import OpenRay

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct AIAgentTests {
    private let writer = Agent(name: "Writer", symbol: "pencil", instructions: "You edit prose. Be terse.", temperature: 0.9)
    private let coder = Agent(name: "Code Review", instructions: "You review code.", reasoning: .deep)
    private let coach = Agent(name: "Coach", instructions: "You coach.")

    @Test func slashPicksAnAgentByNameOrUniquePrefix() {
        let agents = [Agent.assistant, writer, coder, coach]
        #expect(AgentSwitch.parse("/writer tighten this", agents: agents)?.agent.id == writer.id)
        #expect(AgentSwitch.parse("/writer tighten this", agents: agents)?.remainder == "tighten this")
        #expect(AgentSwitch.parse("/Code Review is this safe?", agents: agents)?.agent.id == coder.id)
        #expect(AgentSwitch.parse("/code review is this safe?", agents: agents)?.remainder == "is this safe?")
        #expect(AgentSwitch.parse("/wri", agents: agents)?.agent.id == writer.id)
        #expect(AgentSwitch.parse("/co hello", agents: agents) == nil)  // Code Review or Coach
        #expect(AgentSwitch.parse("/nobody hi", agents: agents) == nil)
        #expect(AgentSwitch.parse("writer", agents: agents) == nil)
        #expect(AgentSwitch.suggestions(for: "/c", agents: agents).map(\.name) == ["Code Review", "Coach"])
        #expect(AgentSwitch.suggestions(for: "/writer now", agents: agents).isEmpty)
    }

    @Test func chattingWithAnAgentUsesItsInstructionsAndSampling() async throws {
        let engine = RecordingAIEngine()
        let chat = AIChatModel(engine: engine)
        chat.environment.agents = { [.assistant, writer] }
        chat.draft = "/writer"
        chat.send()
        // A bare switch sends nothing.
        #expect(chat.agent?.id == writer.id)
        #expect(chat.messages.isEmpty)
        chat.draft = "Tighten: we are going to be going soon."
        chat.send()
        await chat.waitForResponse()
        let request = try #require(engine.requests.last)
        #expect(request.profile.id == "agent.\(writer.id.uuidString)")
        #expect(request.profile.instructions.hasPrefix("You edit prose. Be terse."))
        #expect(request.profile.instructions.contains("cannot operate apps"))
        #expect(request.profile.temperature == 0.9)
        #expect(request.profile.keepsContext)
        #expect(request.prompt == "Tighten: we are going to be going soon.")
    }

    @Test func thePlainAssistantIsTheChatOpenRayAlwaysHad() async throws {
        let engine = RecordingAIEngine()
        let chat = AIChatModel(engine: engine)
        chat.draft = "Hello"
        chat.send()
        await chat.waitForResponse()
        #expect(engine.requests.last?.profile == .chat)
        #expect(engine.requests.last?.profile.instructions == AIAction.chat.instructions)
        #expect(engine.requests.last?.fallbackAction == .chat)
    }

    @Test func switchingAgentsMidChatCarriesTheConversationOver() async throws {
        let engine = RecordingAIEngine()
        let chat = AIChatModel(engine: engine)
        chat.draft = "First question"
        chat.send()
        await chat.waitForResponse()
        #expect(engine.rebuilds.isEmpty)
        chat.selectAgent(coach)
        chat.draft = "Second question"
        chat.send()
        await chat.waitForResponse()
        let rebuilt = try #require(engine.rebuilds.last)
        #expect(rebuilt.profile.id == "agent.\(coach.id.uuidString)")
        #expect(rebuilt.turns == [.init(prompt: "First question", response: "A helpful reply.")])
        // Choosing the assistant again goes back to the plain chat.
        chat.selectAgent(.assistant)
        #expect(chat.agent == nil)
    }

    @Test func reasoningIsAskedForOnlyWhenTheModelOffersIt() {
        #expect(coder.profile(capabilities: [], hasTools: false).reasoning == nil)
        #expect(coder.profile(capabilities: .reasoning, hasTools: false).reasoning == .deep)
        #expect(Agent.assistant.profile(capabilities: .reasoning, hasTools: true).instructions.contains("tools"))
    }

    @Test func theDefaultAgentStartsNewChats() throws {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let hub = model.aiHub
        #expect(hub.save(writer))
        #expect(hub.agents.map(\.name) == ["Assistant", "Writer"])
        #expect(hub.updateSettings { $0.defaultAgentID = writer.id })
        model.ai.newConversation()
        #expect(model.ai.agent?.id == writer.id)
        #expect(hub.windowChat.agent?.id == writer.id)
        #expect(hub.deleteAgent(writer.id))
        #expect(hub.settings.defaultAgentID == nil)
        #expect(model.ai.agent == nil)
        #expect(model.store.database.agents.isEmpty)
    }

    @Test func agentsValidateAndRoundTrip() throws {
        var agent = Agent(name: "  ", instructions: "")
        #expect(agent.validationMessage?.contains("name") == true)
        agent.name = "Long"
        agent.instructions = String(repeating: "x", count: Agent.maximumInstructionCharacters + 1)
        #expect(agent.validationMessage?.contains("every message") == true)
        let record = writer.record(createdAt: Date(timeIntervalSince1970: 5))
        var database = LibraryDatabase()
        database.agents = [record]
        let decoded = try JSONDecoder().decode(LibraryDatabase.self, from: JSONEncoder().encode(database))
        #expect(decoded.agents == [record])
        #expect(Agent(record: record) == writer)
        #expect(Agent(record: AgentRecord(temperature: 9)).temperature == 2)
        #expect(!Slice7Fixtures.launcher().aiHub.save(.assistant))
    }

    @Test func agentToolsAreOfferedWithoutAMention() async throws {
        let engine = RecordingAIEngine()
        let chat = AIChatModel(engine: engine)
        let notes = FakeToolExecutor("searchNotes", extensionID: "notes")
        let broker = AIToolBroker(executors: [notes])
        chat.environment.toolBroker = broker
        chat.environment.toolExtensions = { AIToolCatalog.extensions(for: broker.specs) }
        var researcher = coach
        researcher.toolIDs = ["searchNotes"]
        chat.selectAgent(researcher)
        chat.draft = "What did I write about Lisbon?"
        chat.send()
        await chat.waitForResponse()
        let request = try #require(engine.requests.last)
        #expect(request.tools.map(\.id) == ["searchNotes"])
        #expect(request.toolMode == .allowed)
        #expect(request.toolInvoker != nil)
        #expect(request.profile.instructions.contains("Use the provided tools"))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct AIToolTests {
    private let extensions = [
        AIToolExtension(id: "notes", title: "Notes", symbol: "note", aliases: ["note"], tools: [
            AIToolSpec(id: "searchNotes", extensionID: "notes", title: "Search Notes", symbol: "n", summary: "s"),
            AIToolSpec(id: "createNote", extensionID: "notes", title: "Create Note", symbol: "n", summary: "c", effect: .library),
        ]),
        AIToolExtension(id: "files", title: "Files", symbol: "doc", aliases: ["finder", "file-search"], tools: [
            AIToolSpec(id: "searchFiles", extensionID: "files", title: "Search Files", symbol: "f", summary: "f")
        ]),
        AIToolExtension(id: "calculator", title: "Calculator", symbol: "f", aliases: ["math"], tools: [
            AIToolSpec(id: "calculate", extensionID: "calculator", title: "Calculate", symbol: "f", summary: "m")
        ]),
        AIToolExtension(id: "clipboard", title: "Clipboard", symbol: "c", tools: [
            AIToolSpec(id: "searchClipboard", extensionID: "clipboard", title: "Clipboard", symbol: "c", summary: "c")
        ]),
    ]

    @Test func mentionsAreFoundOnlyAtWordStarts() {
        let text = "@notes what did kim@example.com say? Ask @finder and @unknown, then @MATH."
        let found = AIMentionParser.mentions(in: text, extensions: extensions).map(\.extensionID)
        #expect(found == ["notes", "files", "calculator"])
        #expect(AIMentionParser.strippingMentions("@notes  find   groceries", extensions: extensions) == "find groceries")
        #expect(AIMentionParser.mentions(in: "email@notes", extensions: extensions).isEmpty)
        #expect(AIMentionParser.mentions(in: "(@note) and @file-search", extensions: extensions).map(\.extensionID) == ["notes", "files"])
        #expect(AIMentionParser.mentions(in: "@", extensions: extensions).isEmpty)
    }

    @Test func mentionsCompleteWhileTyped() {
        #expect(AIMentionParser.completions(for: "find it @no", extensions: extensions).map(\.id) == ["notes"])
        #expect(AIMentionParser.completions(for: "@fin", extensions: extensions).map(\.id) == ["files"])
        #expect(AIMentionParser.completions(for: "@", extensions: extensions).count == extensions.count)
        #expect(AIMentionParser.completions(for: "me@ex", extensions: extensions).isEmpty)
        #expect(AIMentionParser.completions(for: "@notes now", extensions: extensions).isEmpty)
    }

    @Test func mentionsForceTheirToolsAndAgentsOfferTheirs() {
        let mentioned = AIToolRouter.plan(text: "@notes save groceries", extensions: extensions, agentToolIDs: ["calculate"])
        #expect(mentioned.tools.map(\.id) == ["searchNotes", "createNote"])
        #expect(mentioned.mode == .required)
        #expect(mentioned.prompt == "save groceries")
        #expect(mentioned.mentionedExtensionIDs == ["notes"])

        let many = AIToolRouter.plan(text: "@notes @files @math @clipboard go", extensions: extensions, agentToolIDs: [])
        #expect(many.tools.count == AIToolRouter.maximumTools)
        #expect(many.tools.map(\.id) == ["searchNotes", "createNote", "searchFiles", "calculate"])

        let agent = AIToolRouter.plan(text: "what's 2+2", extensions: extensions, agentToolIDs: ["calculate", "missing"])
        #expect(agent.tools.map(\.id) == ["calculate"])
        #expect(agent.mode == .allowed)
        #expect(agent.prompt == "what's 2+2")

        let none = AIToolRouter.plan(text: "hello", extensions: extensions, agentToolIDs: [])
        #expect(none.tools.isEmpty && none.mode == .none)
        // A message that is only a mention keeps its text.
        #expect(AIToolRouter.plan(text: "@notes", extensions: extensions, agentToolIDs: []).prompt == "@notes")
    }

    @Test func readsRunButEveryWriteNeedsItsOwnApproval() async throws {
        let read = FakeToolExecutor("searchNotes", extensionID: "notes")
        let write = FakeToolExecutor("createNote", extensionID: "notes", effect: .library)
        // A standing "Always" stored for a write, say by an older build, counts as Ask.
        let permissions = InMemoryToolPermissions(["createNote": .always])
        let broker = AIToolBroker(executors: [read, write], permissions: permissions)
        #expect(broker.permission(for: write.spec) == .ask)
        #expect(AIToolPermission.choices(for: write.spec).isEmpty)
        #expect(AIToolPermission.choices(for: read.spec) == AIToolPermission.allCases)
        #expect(await broker.invoke(toolID: "searchNotes", arguments: AIToolArguments(["query": "x"])) == "done")
        #expect(read.runs.count == 1)
        #expect(broker.pendingApprovals.isEmpty)

        for decision in [AIToolDecision.allow, .alwaysAllow, .allow] {
            let call = Task {
                await broker.invoke(toolID: "createNote", arguments: AIToolArguments(["query": "Milk, eggs", "ignored": "x"]))
            }
            await waitFor { !broker.pendingApprovals.isEmpty }
            let card = try #require(broker.pendingApprovals.first)
            #expect(card.isAction)
            #expect(!card.offersAlways)
            #expect(card.detail == "Run createNote")
            // The card shows the values it would write.
            #expect(card.fields == [AIToolApproval.Field(label: "Query", value: "Milk, eggs")])
            broker.resolve(card.id, decision)
            #expect(await call.value == "done")
        }
        // Always Allow on a write approved that call only.
        #expect(write.runs.count == 3)
        #expect(permissions.values["createNote"] == .always)  // left as stored, still read as Ask

        let denied = Task { await broker.invoke(toolID: "createNote", arguments: AIToolArguments()) }
        await waitFor { !broker.pendingApprovals.isEmpty }
        broker.resolve(try #require(broker.pendingApprovals.first).id, .deny)
        #expect(await denied.value.contains("declined"))
        #expect(write.runs.count == 3)
        #expect(broker.activity.last?.outcome == .declined)

        // A read may be allowed for good.
        permissions.values["searchNotes"] = .ask
        let ask = Task { await broker.invoke(toolID: "searchNotes", arguments: AIToolArguments()) }
        await waitFor { !broker.pendingApprovals.isEmpty }
        let readCard = try #require(broker.pendingApprovals.first)
        #expect(readCard.offersAlways)
        broker.resolve(readCard.id, .alwaysAllow)
        _ = await ask.value
        #expect(permissions.values["searchNotes"] == .always)
        #expect(await broker.invoke(toolID: "searchNotes", arguments: AIToolArguments()) == "done")
        #expect(read.runs.count == 3)
        #expect(await broker.invoke(toolID: "nope", arguments: AIToolArguments()).contains("no tool"))
    }

    @Test func snippetCardsShowTheExpansionKeyword() {
        let spec = CreateSnippetTool(store: LibraryStore(fileURL: nil)).spec
        let fields = AIToolBroker.fields(
            for: spec, arguments: AIToolArguments(["name": "Sign-off", "text": "Best, Kim", "keyword": ";bk"]))
        #expect(fields.map(\.label) == ["Name", "Text", "Keyword"])
        #expect(fields.map(\.value) == ["Sign-off", "Best, Kim", ";bk"])
    }

    @Test func askAsksEvenForReadsAndStopDeclines() async throws {
        let read = FakeToolExecutor("searchClipboard", extensionID: "clipboard")
        let broker = AIToolBroker(executors: [read], permissions: InMemoryToolPermissions(["searchClipboard": .ask]))
        let call = Task { await broker.invoke(toolID: "searchClipboard", arguments: AIToolArguments()) }
        await waitFor { !broker.pendingApprovals.isEmpty }
        try #require(!broker.pendingApprovals.isEmpty)
        broker.declineAll()
        #expect(await call.value.contains("declined"))
        #expect(read.runs.isEmpty)

        let cancelled = Task { await broker.invoke(toolID: "searchClipboard", arguments: AIToolArguments()) }
        await waitFor { !broker.pendingApprovals.isEmpty }
        try #require(!broker.pendingApprovals.isEmpty)
        cancelled.cancel()
        #expect(await cancelled.value.contains("declined"))
        await waitFor { broker.pendingApprovals.isEmpty }
        #expect(read.runs.isEmpty)
    }

    @Test func systemActionsNeverRunWhereSideEffectsAreOff() async {
        let system = FakeToolExecutor("createEvent", extensionID: "calendar", effect: .system)
        let broker = AIToolBroker(
            executors: [system], permissions: InMemoryToolPermissions(["createEvent": .always]),
            sideEffects: SideEffectGuard(mode: .testHost))
        // Refused before any card: stored Always counts as Ask for an action, but no one is
        // asked about something this launch can't do.
        let output = await broker.invoke(toolID: "createEvent", arguments: AIToolArguments())
        #expect(output.contains("while tests run"))
        #expect(system.runs.isEmpty)
        #expect(broker.pendingApprovals.isEmpty)
        guard case .blocked? = broker.activity.last?.outcome else {
            Issue.record("Expected a blocked call")
            return
        }
    }

    @Test func anAtMentionInChatForcesTheToolAndAsksBeforeWriting() async throws {
        let engine = RecordingAIEngine()
        engine.toolCalls = [("createNote", ["title": "Groceries", "content": "Milk, eggs"])]
        let model = Slice7Fixtures.launcher(engine: engine)
        defer { model.stop() }
        model.openAI(.chat)
        model.ai.draft = "@notes save my groceries: milk, eggs"
        model.ai.send()
        let broker = try #require(model.ai.environment.toolBroker)
        await waitFor { !broker.pendingApprovals.isEmpty }
        try #require(!broker.pendingApprovals.isEmpty)
        let request = try #require(engine.requests.last)
        #expect(request.tools.map(\.id) == ["searchNotes", "createNote"])
        #expect(request.toolMode == .required)
        #expect(request.prompt == "save my groceries: milk, eggs")
        #expect(model.ai.messages.first?.displayText == "@notes save my groceries: milk, eggs")
        #expect(model.store.database.notes.isEmpty)
        // A write is approved on its card, which shows every value; ⌘K doesn't offer it.
        #expect(!model.actions(for: nil).contains { $0.id == "tool.allow" })
        broker.resolve(broker.pendingApprovals[0].id, .allow)
        await model.ai.waitForResponse()
        #expect(model.store.database.notes.map(\.title) == ["Groceries"])
        #expect(engine.toolOutputs == ["Saved the note “Groceries”."])
    }

    @Test func toolPermissionsPersistInTheLibrary() {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let permissions = LibraryToolPermissions(store: model.store)
        #expect(permissions.permission(for: "createNote") == nil)
        permissions.setPermission(.ask, for: "createNote")
        #expect(model.store.database.commandPreferences["ai"]?["tool.createNote"] == "ask")
        #expect(model.aiHub.settings.toolPermissions["createNote"] == .ask)
        permissions.setPermission(.auto, for: "createNote")
        #expect(model.store.database.commandPreferences["ai"] == nil)
    }

    @Test func theBuiltInToolsWorkOverTheLibrary() async throws {
        let store = LibraryStore(fileURL: nil)
        store.update {
            $0.notes = [QuickNote(title: "Lisbon trip", content: "Pastéis in Belém")]
            $0.snippets = [Snippet(name: "Address", keyword: ";addr", content: "1 Main St")]
        }
        #expect(try await NotesSearchTool(store: store).run(AIToolArguments(["query": "lisbon"])).contains("Pastéis"))
        #expect(try await NotesSearchTool(store: store).run(AIToolArguments(["query": "paris"])) == "No notes matched.")
        #expect(try await SnippetsSearchTool(store: store).run(AIToolArguments(["query": "addr"])).contains("1 Main St"))
        _ = try await CreateSnippetTool(store: store).run(AIToolArguments(["name": "Sign-off", "text": "Best, Ali"]))
        #expect(store.database.snippets.contains { $0.name == "Sign-off" })
        await #expect(throws: AIToolError.missingArgument("content")) {
            try await CreateNoteTool(store: store).run(AIToolArguments(["title": "Empty"]))
        }
        let calculator = CalculatorTool(evaluate: { $0 == "2+2" ? "4" : nil })
        #expect(try await calculator.run(AIToolArguments(["expression": "2+2"])) == "2+2 = 4")
        #expect(try await calculator.run(AIToolArguments(["expression": "??"])).contains("couldn't"))
        let catalog = AIToolCatalog.extensions(for: AIToolCatalog.standard(store: store, files: StubFiles()).map(\.spec))
        // Without the calendar and command services, the library's own tools.
        #expect(catalog.map(\.id) == Array(AIToolCatalog.extensionOrder.prefix(6)))
        #expect(catalog.first { $0.id == "notes" }?.tools.map(\.id) == ["searchNotes", "createNote"])
        #expect(try await FileSearchTool(searcher: StubFiles()).run(AIToolArguments(["query": "report"])).contains("report.pdf"))
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
private struct StubFiles: AIFileSearching {
    func search(_ query: String, limit: Int) async -> [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/\(query).pdf")]
    }
}

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct AIModelChoiceTests {
    @Test func thisBuildIsOnDeviceOnly() {
        // Private Cloud Compute needs a managed entitlement Developer ID builds can't carry.
        #expect(!AIModelSelection.isBuildEnabled)
        #expect(AISettings().model == .onDevice)
        #expect(AIModelSelection.resolve(preference: .privateCloud, privateCloud: .available(approachingLimit: false)) == .onDevice)
        #expect(FoundationModelEngine().privateCloudStatus == nil)
        #expect(AIModelSelection.buildUnavailableReason.contains("App Store"))
    }

    @Test func inABuildThatMayUseItTheLargerModelIsOptInAndOnlyUsedWhileItCanAnswer() {
        func resolve(_ preference: AIModelChoice, _ status: AIPrivateCloudStatus?) -> AIModelChoice {
            AIModelSelection.resolve(preference: preference, privateCloud: status, buildAllows: true)
        }
        #expect(resolve(.onDevice, .available(approachingLimit: false)) == .onDevice)
        #expect(resolve(.privateCloud, .available(approachingLimit: true)) == .privateCloud)
        #expect(resolve(.privateCloud, .limitReached(resetDate: nil)) == .onDevice)
        #expect(resolve(.privateCloud, .unavailable("Not ready")) == .onDevice)
        #expect(resolve(.privateCloud, nil) == .onDevice)
    }

    @Test func aStoredOptInStaysOnDeviceInThisBuild() {
        let engine = RecordingAIEngine()
        engine.cloudStatus = .available(approachingLimit: false)
        let model = Slice7Fixtures.launcher(engine: engine)
        defer { model.stop() }
        let hub = model.aiHub
        let window = hub.windowChat.engine as? RecordingAIEngine
        #expect(model.store.database.commandPreferences["ai"] == nil)
        #expect(hub.updateSettings { $0.model = .privateCloud })
        #expect(model.store.database.commandPreferences["ai"]?["model"] == "privateCloud")
        #expect(engine.modelChoice == .onDevice)
        #expect(window?.modelChoice == .onDevice)
        #expect(hub.effectiveModel == .onDevice)
    }

    @Test func settingsRoundTripAndIgnoreUnknownValues() {
        var settings = AISettings()
        settings.defaultAgentID = UUID()
        settings.quickFixCommandID = "aicommand.changeTone"
        settings.toolPermissions = ["createNote": .ask, "searchNotes": .auto]
        settings.chatRetention = .days90
        settings.dictationEnabled = true
        settings.screenContextEnabled = true
        settings.chatWindowOnTop = true
        var database = LibraryDatabase()
        settings.write(into: &database)
        #expect(database.commandPreferences["ai"]?["tool.searchNotes"] == nil)
        var expected = settings
        expected.toolPermissions = ["createNote": .ask]
        #expect(AISettings(database: database) == expected)
        database.commandPreferences["ai"] = ["model": "quantum", "retention": "forever-ish", "tool.x": "sometimes"]
        #expect(AISettings(database: database) == AISettings())
    }
}

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct AIAttachmentTests {
    private struct FakeRecognizer: TextRecognizing {
        var text: String
        func recognizeText(in imageData: Data, options: TextRecognitionOptions) async throws -> TextRecognitionResult {
            TextRecognitionResult(lines: [RecognizedTextLine(text: text, confidence: 1, boundingBox: .zero)])
        }
        func recognizeText(inImageAt url: URL, options: TextRecognitionOptions) async throws -> TextRecognitionResult {
            TextRecognitionResult(lines: [RecognizedTextLine(text: text, confidence: 1, boundingBox: .zero)])
        }
        func barcodePayloads(in imageData: Data) async throws -> [String] { [] }
    }

    @Test func textFilesAttachAndBinaryFilesDont() async throws {
        let folder = Slice7Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appending(path: "notes.md")
        try Data("# Plan\nShip it.".utf8).write(to: text)
        let attachment = try await AIAttachmentLoader.load(text, capabilities: [], recognizer: FakeRecognizer(text: ""))
        #expect(attachment.source == .file)
        #expect(attachment.title == "notes.md")
        #expect(attachment.text == "# Plan\nShip it.")
        let binary = folder.appending(path: "blob.bin")
        try Data([0, 1, 2, 0, 255]).write(to: binary)
        await #expect(throws: AIAttachmentError.unsupported("blob.bin")) {
            try await AIAttachmentLoader.load(binary, capabilities: [], recognizer: FakeRecognizer(text: ""))
        }
        #expect(AIAttachmentLoader.decodedText(Data("café".utf8), isText: true) == "café")
    }

    @Test func pdfTextComesFromPDFKit() async throws {
        let folder = Slice7Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "memo.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Quarterly memo", attributes: [.font: NSFont.systemFont(ofSize: 18)]))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        let attachment = try await AIAttachmentLoader.load(url, capabilities: [], recognizer: FakeRecognizer(text: ""))
        #expect(attachment.text.contains("Quarterly memo"))
        #expect(attachment.source == .file)
    }

    @Test func imagesAreSentAsImagesOnlyToModelsWithVision() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let read = try await AIAttachmentLoader.image(
            png, name: "Shot", source: .image, capabilities: [], recognizer: FakeRecognizer(text: "Invoice 42"))
        #expect(read.text == "Invoice 42")
        #expect(read.image == nil)
        let seen = try await AIAttachmentLoader.image(
            png, name: "Shot", source: .screen, capabilities: .vision, recognizer: FakeRecognizer(text: "unused"))
        #expect(seen.image?.data == png)
        #expect(seen.text.isEmpty)
        #expect(seen.summary == "Shot · image")
        await #expect(throws: AIAttachmentError.noText("Blank")) {
            try await AIAttachmentLoader.image(png, name: "Blank", source: .image, capabilities: [], recognizer: FakeRecognizer(text: " "))
        }
    }

    @Test func imageAttachmentsReachTheRequestWithVision() async throws {
        let engine = RecordingAIEngine()
        engine.capabilities = .vision
        let chat = AIChatModel(engine: engine)
        let image = AIImageInput(data: Data([1, 2, 3]), label: "Window")
        chat.attach(AIAttachment(source: .screen, text: "", name: "Window", image: image))
        #expect(chat.canSend)
        chat.send()
        await chat.waitForResponse()
        #expect(engine.requests.last?.images == [image])
        #expect(chat.messages.first?.attachmentLabels == ["Window · image"])
    }

    @Test func screenContextIsOptInAndNeverCapturesInTests() async {
        let model = Slice7Fixtures.launcher()
        defer { model.stop() }
        let hub = model.aiHub
        #expect(hub.screenCapture is InertScreenCapture)
        await hub.attachScreen(.entireScreen, to: model.ai)
        #expect(model.ai.errorMessage?.contains("Turn on screen context") == true)
        hub.updateSettings { $0.screenContextEnabled = true }
        await hub.attachScreen(.focusedWindow(processID: nil), to: model.ai)
        #expect(model.ai.errorMessage?.contains("Screen Recording") == true)
        #expect(model.ai.attachments.isEmpty)
        #expect(hub.dictation is InertDictation)
    }

    @Test func notesAndClipboardEntriesAttachAsText() {
        let chat = AIChatModel(engine: RecordingAIEngine())
        let note = QuickNote(title: "Agenda", content: "1. Budget")
        chat.attach(AIAttachmentLoader.note(note))
        chat.attach(AIAttachment(source: .file, text: "a", name: "a.txt"))
        chat.attach(AIAttachment(source: .file, text: "b", name: "b.txt"))
        #expect(chat.attachments.map(\.title) == ["Note: Agenda", "a.txt", "b.txt"])
        let entry = ClipboardEntry(text: "Copied words", sourceName: "Safari")
        #expect(AIAttachmentLoader.clipboardEntry(entry)?.text == "Copied words")
        #expect(AIAttachmentLoader.clipboardEntry(entry)?.appName == "Safari")
    }
}
