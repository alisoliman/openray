import AppKit
import Foundation
import Observation

/// Everything AI that lives beside the panel's chat: saved chats and the chat window's
/// conversation, tools and their approvals, agents, AI Commands, attachments and settings.
/// The panel's `AIChatModel` owns one; `LauncherModel.aiHub` binds it to the launcher on
/// first use, so nothing here touches the library before the launcher exists.
@MainActor
@Observable
final class AIHub {
    /// The conversation inside the launcher panel.
    @ObservationIgnored weak var panelChat: AIChatModel?
    @ObservationIgnored private(set) weak var launcher: LauncherModel?
    private(set) var chatStore = ChatStore(fileURL: nil)
    @ObservationIgnored private(set) var broker: AIToolBroker?
    private var windowChatStorage: AIChatModel?
    /// Shows the chat window, at a saved chat when one is given. The app delegate sets it;
    /// tests leave it nil and read `windowRequests`.
    @ObservationIgnored var presentWindow: (() -> Void)?
    /// Opens the AI Command or agent editor. The app delegate sets it; tests read `editorRequests`.
    @ObservationIgnored var presentEditor: ((AIEditorRequest) -> Void)?
    private(set) var windowRequests = 0
    private(set) var editorRequests: [AIEditorRequest] = []
    /// Makes the chat window's engine. Nil asks the panel's engine for a sibling.
    @ObservationIgnored var windowEngineFactory: (@MainActor () -> any AIEngine)?
    @ObservationIgnored var screenCapture: any AIScreenCapturing =
        SideEffectGuard.isInert ? InertScreenCapture() as any AIScreenCapturing : LiveScreenCapture()
    @ObservationIgnored var recognizer: any TextRecognizing = VisionTextRecognizer()
    @ObservationIgnored var fileSearcher: (any AIFileSearching)?
    @ObservationIgnored var translator: (any AITextTranslating)?
    @ObservationIgnored var dictation: any AIDictating =
        SideEffectGuard.isInert ? InertDictation() as any AIDictating : SpeechDictation()

    init() {}

    var isBound: Bool { launcher != nil }

    /// Connects to the launcher once: chat storage beside the library, tools over the
    /// library, settings. Later calls return at once.
    @discardableResult
    func bind(to model: LauncherModel) -> AIHub {
        guard launcher == nil else { return self }
        launcher = model
        chatStore = ChatStore(fileURL: model.store.fileURL.map(ChatStore.url(nextTo:)))
        broker = makeBroker()
        if translator == nil { translator = TranslationServiceTranslator() }
        if let panelChat { configure(panelChat) }
        applySettings()
        chatStore.purge(retention: settings.chatRetention)
        return self
    }

    /// Tools over the launcher's library. Each conversation has its own broker, so its
    /// approval cards show where it is: the panel or the window.
    func makeBroker() -> AIToolBroker? {
        guard let launcher else { return nil }
        return AIToolBroker(
            executors: AIToolCatalog.standard(store: launcher.store, files: fileSearcher ?? SpotlightFileSearcher()),
            permissions: LibraryToolPermissions(store: launcher.store))
    }

    /// Gives a conversation the agents, tools and translator.
    func configure(_ chat: AIChatModel) {
        chat.environment = AIChatEnvironment(
            agents: { [weak self] in self?.agents ?? [] },
            defaultAgent: { [weak self] in self?.defaultAgent },
            toolExtensions: { [weak self] in self?.toolExtensions ?? [] },
            toolBroker: chat.environment.toolBroker ?? makeBroker(), translator: translator)
        if chat.messages.isEmpty, !chat.isGenerating, chat.agent == nil, let agent = defaultAgent, !agent.isAssistant {
            chat.selectAgent(agent)
        }
    }

    // MARK: Settings

    var settings: AISettings { launcher.map { AISettings(database: $0.store.database) } ?? AISettings() }

    @discardableResult
    func updateSettings(_ change: (inout AISettings) -> Void) -> Bool {
        guard let launcher else { return false }
        let saved = launcher.store.update { database in
            var settings = AISettings(database: database)
            change(&settings)
            settings.write(into: &database)
        }
        if saved { applySettings() }
        return saved
    }

    /// Points both conversations' engines at the chosen model.
    func applySettings() {
        let choice = settings.model
        panelChat?.engine.setModelChoice(choice)
        windowChatStorage?.engine.setModelChoice(choice)
    }

    /// Private Cloud Compute's status, when the SDK has it.
    var privateCloudStatus: AIPrivateCloudStatus? { panelChat?.engine.privateCloudStatus }

    /// The model requests use now: the larger one only when opted in and usable.
    var effectiveModel: AIModelChoice {
        AIModelSelection.resolve(preference: settings.model, privateCloud: settings.model == .privateCloud ? privateCloudStatus : nil)
    }

    // MARK: Agents and commands

    var agents: [Agent] { [Agent.assistant] + (launcher?.store.database.agents.map(Agent.init(record:)) ?? []) }

    var defaultAgent: Agent? {
        guard let id = settings.defaultAgentID else { return nil }
        return agents.first { $0.id == id }
    }

    func agent(id: UUID?) -> Agent? { id.flatMap { id in agents.first { $0.id == id } } }

    /// The added built-ins, then the person's own commands.
    var aiCommands: [AICommand] {
        AICommand.addedBuiltIns + (launcher?.store.database.aiCommands.map(AICommand.init(record:)) ?? [])
    }

    /// Every command Quick Fix can run: the original writing commands, then `aiCommands`.
    var quickFixChoices: [(id: String, title: String)] {
        AIWritingCommandProvider.writingActions.map { ("ai.\($0.id)", $0.title) } + aiCommands.map { ($0.id, $0.name) }
    }

    var toolExtensions: [AIToolExtension] { AIToolCatalog.extensions(for: broker?.specs ?? []) }

    @discardableResult
    func save(_ command: AICommand) -> Bool {
        guard let launcher else { return false }
        if let message = command.validationMessage {
            launcher.feedback = .warning(message)
            return false
        }
        let record = command.record(
            createdAt: launcher.store.database.aiCommands.first { $0.id == command.recordID }?.createdAt ?? .now)
        let saved = launcher.store.update { database in
            if let index = database.aiCommands.firstIndex(where: { $0.id == record.id }) {
                database.aiCommands[index] = record
            } else {
                database.aiCommands.append(record)
            }
        }
        if saved { launcher.commandCatalogDidChange() }
        return saved
    }

    @discardableResult
    func duplicate(_ command: AICommand) -> AICommand? {
        guard let launcher else { return nil }
        let record = command.duplicate()
        guard launcher.store.update({ $0.aiCommands.append(record) }) else { return nil }
        launcher.commandCatalogDidChange()
        return AICommand(record: record)
    }

    @discardableResult
    func save(_ agent: Agent) -> Bool {
        guard let launcher, !agent.isAssistant else { return false }
        if let message = agent.validationMessage {
            launcher.feedback = .warning(message)
            return false
        }
        let record = agent.record(createdAt: launcher.store.database.agents.first { $0.id == agent.id }?.createdAt ?? .now)
        return launcher.store.update { database in
            if let index = database.agents.firstIndex(where: { $0.id == record.id }) {
                database.agents[index] = record
            } else {
                database.agents.append(record)
            }
        }
    }

    @discardableResult
    func deleteAgent(_ id: UUID) -> Bool {
        guard let launcher else { return false }
        let saved = launcher.store.update { database in
            database.agents.removeAll { $0.id == id }
            var settings = AISettings(database: database)
            if settings.defaultAgentID == id { settings.defaultAgentID = nil }
            settings.write(into: &database)
        }
        for chat in [panelChat, windowChatStorage].compactMap({ $0 }) where chat.agent?.id == id { chat.selectAgent(nil) }
        return saved
    }

    /// Adds commands from a JSON export. Returns how many were added.
    func importCommands(from data: Data) throws -> Int {
        guard let launcher else { return 0 }
        let records = try AICommandTransfer.importCommands(from: data)
        guard launcher.store.update({ $0.aiCommands += records }) else {
            throw LibraryValidationError(launcher.store.errorMessage ?? "The commands couldn't be saved.")
        }
        launcher.commandCatalogDidChange()
        return records.count
    }

    func exportCommands() throws -> Data {
        try AICommandTransfer.export(aiCommands.filter { !$0.isBuiltIn })
    }

    func requestEditor(_ request: AIEditorRequest) {
        editorRequests.append(request)
        launcher?.panel?.dismiss(restoreFocus: false)
        presentEditor?(request)
    }

    // MARK: The chat window

    /// The chat window's conversation, made on first use.
    var windowChat: AIChatModel {
        if let windowChatStorage { return windowChatStorage }
        let engine = windowEngineFactory?() ?? panelChat?.engine.makeSibling() ?? InertAIEngine()
        engine.setModelChoice(settings.model)
        let chat = AIChatModel(engine: engine, hub: self)
        configure(chat)
        chat.onConversationChange = { [weak self] in self?.saveWindowChat() }
        windowChatStorage = chat
        return chat
    }

    /// Shows the chat window.
    func openChatWindow() {
        // Made before the window draws, so its view never creates state mid-update.
        _ = windowChat
        windowRequests += 1
        launcher?.panel?.dismiss(restoreFocus: false)
        presentWindow?()
    }

    /// ⌘J: moves the panel's conversation into a new saved chat and shows it in the window.
    @discardableResult
    func continueInChat() -> Bool {
        guard let panelChat, let state = panelChat.takeConversation() else { return false }
        saveWindowChat()
        guard let saved = chatStore.save(state, id: nil) else {
            launcher?.feedback = .error(chatStore.errorMessage ?? "The chat couldn't be saved.")
            return false
        }
        show(saved.id)
        openChatWindow()
        return true
    }

    /// Saves the window's conversation, if it has anything to keep.
    func saveWindowChat() {
        guard let chat = windowChatStorage, !chat.isGenerating, chat.messages.contains(where: { $0.role == .assistant }) else {
            return
        }
        if let saved = chatStore.save(chat.conversationState(), id: chat.chatID) { chat.chatID = saved.id }
    }

    /// Opens a saved chat in the window.
    func show(_ chatID: UUID) {
        guard let saved = chatStore.chat(id: chatID), !windowChat.isGenerating else { return }
        saveWindowChat()
        windowChat.load(saved.state, agent: agent(id: saved.agentID))
        windowChat.chatID = saved.id
    }

    /// Starts a new conversation in the window.
    func newWindowChat() {
        guard !windowChat.isGenerating else { return }
        saveWindowChat()
        windowChat.newConversation(action: .chat)
    }

    /// Continues from a message in a new chat, leaving the original as it was.
    func branch(from messageID: UUID) {
        saveWindowChat()
        guard let chatID = windowChat.chatID, let branch = chatStore.branch(chatID, through: messageID) else { return }
        show(branch.id)
    }

    /// Moves a chat to Recently Deleted; the window starts fresh if it was showing it.
    func deleteChat(_ id: UUID) {
        chatStore.delete(id)
        if windowChatStorage?.chatID == id { windowChatStorage?.newConversation(action: .chat) }
    }

    func archiveChat(_ id: UUID) {
        saveWindowChat()
        chatStore.archive(id)
    }

    func deleteAllChats() {
        chatStore.deleteAll()
        windowChatStorage?.newConversation(action: .chat)
    }

    // MARK: Attachments

    /// Attaches files to a conversation: text, code, PDFs and images. Problems show in the conversation.
    func attachFiles(_ urls: [URL], to chat: AIChatModel) async {
        for url in urls {
            do {
                chat.attach(try await AIAttachmentLoader.load(url, capabilities: chat.capabilities, recognizer: recognizer))
            } catch {
                chat.report(error.localizedDescription)
            }
        }
    }

    func attachNote(_ note: QuickNote, to chat: AIChatModel) { chat.attach(AIAttachmentLoader.note(note)) }

    func attachClipboardEntry(_ entry: ClipboardEntry, to chat: AIChatModel) {
        if let attachment = AIAttachmentLoader.clipboardEntry(entry) {
            chat.attach(attachment)
        } else {
            chat.report("That clipboard entry has no text to attach.")
        }
    }

    /// Captures the focused window or the screen into a conversation. Asks for Screen
    /// Recording permission here, in context, the first time.
    func attachScreen(_ target: AIScreenTarget, to chat: AIChatModel) async {
        guard settings.screenContextEnabled else {
            chat.report("Turn on screen context in Settings › Apple Intelligence to attach the screen.")
            return
        }
        if !screenCapture.hasPermission, !screenCapture.requestPermission() {
            chat.report(AIScreenCaptureError.noPermission.localizedDescription)
            return
        }
        do {
            let capture = try await screenCapture.capture(target)
            chat.attach(
                try await AIAttachmentLoader.image(
                    capture.png, name: capture.title, source: .screen, capabilities: chat.capabilities, recognizer: recognizer))
        } catch {
            chat.report(error.localizedDescription)
        }
    }
}

/// Which editor to open.
enum AIEditorRequest: Equatable, Sendable {
    case newCommand
    case command(String)
    case newAgent
    case agent(UUID)
}

/// Slice 3's Translation service for the Translate command.
@MainActor
final class TranslationServiceTranslator: AITextTranslating {
    let service: TranslationService

    init(service: TranslationService = TranslationService(engine: AppleTranslationEngine.standard())) {
        self.service = service
    }

    func translate(_ text: String, toLanguageID languageID: String) async throws -> String {
        guard let target = TranslationLanguages.all.first(where: { $0.id == languageID }) else {
            throw AIServiceError.failed("That language isn't available for translation.")
        }
        do {
            let outcome = try await service.translate(TranslationRequest(text: text, source: nil, target: target), fixedTarget: true)
            return outcome.translatedText
        } catch let failure as TranslationFailure {
            switch failure {
            case .needsDownload:
                throw AIServiceError.failed(
                    "\(failure.message) Open Translate in OpenRay to download it, then run the command again.")
            default: throw AIServiceError.failed(failure.message)
            }
        }
    }
}

extension LauncherModel {
    /// The AI hub, connected to this launcher.
    var aiHub: AIHub { ai.hub.bind(to: self) }

    /// Slice 4's “Send to AI”: opens chat with these files attached. Text files, code, PDFs
    /// and images are read on this Mac; long ones are summarized in parts when sent.
    func sendFilesToAI(_ urls: [URL]) async {
        openAI(.chat)
        await aiHub.attachFiles(urls, to: ai)
        focusRequest += 1
    }
}
