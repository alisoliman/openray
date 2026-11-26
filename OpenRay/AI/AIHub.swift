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
    /// Why the window's conversation couldn't be saved. It stays open until it can be.
    private(set) var saveError: String?
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
            agents: { [weak self] in self?.agents ?? [Agent.assistant] },
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

    /// Points both conversations' engines at the chosen model. A build without Private Cloud
    /// Compute stays on this Mac whatever is stored.
    func applySettings() {
        let choice = AIModelSelection.isBuildEnabled ? settings.model : .onDevice
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

    /// Saves an agent and, when given, whether it starts new chats, in one save: both or neither.
    @discardableResult
    func save(_ agent: Agent, isDefault: Bool? = nil) -> Bool {
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
            if let isDefault {
                var settings = AISettings(database: database)
                if isDefault {
                    settings.defaultAgentID = agent.id
                } else if settings.defaultAgentID == agent.id {
                    settings.defaultAgentID = nil
                }
                settings.write(into: &database)
            }
        }
    }

    /// Deletes an agent. Open chats drop it at once, even mid-reply.
    @discardableResult
    func deleteAgent(_ id: UUID) -> Bool {
        guard let launcher else { return false }
        let saved = launcher.store.update { database in
            database.agents.removeAll { $0.id == id }
            var settings = AISettings(database: database)
            if settings.defaultAgentID == id { settings.defaultAgentID = nil }
            settings.write(into: &database)
        }
        if saved {
            for chat in [panelChat, windowChatStorage].compactMap({ $0 }) { chat.forgetAgent(id) }
        }
        return saved
    }

    /// Adds commands from a JSON export, all or none. Returns what was added and skipped.
    func importCommands(from data: Data) throws -> AICommandTransfer.ImportResult {
        guard let launcher else { return AICommandTransfer.ImportResult(records: [], skipped: 0) }
        let result = try AICommandTransfer.importCommands(from: data)
        guard launcher.store.update({ $0.aiCommands += result.records }) else {
            throw LibraryValidationError(launcher.store.errorMessage ?? "The commands couldn't be saved.")
        }
        launcher.commandCatalogDidChange()
        return result
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
        engine.setModelChoice(AIModelSelection.isBuildEnabled ? settings.model : .onDevice)
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

    /// ⌘J: copies the panel's conversation into a new saved chat, and only once that's saved
    /// clears the panel and shows the chat in the window. A failed save changes nothing.
    @discardableResult
    func continueInChat() -> Bool {
        guard let panelChat, let state = panelChat.transferState() else { return false }
        guard saveWindowChat() else {
            launcher?.feedback = .error(saveError ?? "The chat window's conversation couldn't be saved.")
            return false
        }
        guard let saved = chatStore.save(state, id: nil) else {
            launcher?.feedback = .error(chatStore.errorMessage ?? "The chat couldn't be saved.")
            return false
        }
        panelChat.newConversation(action: .chat)
        show(saved.id)
        openChatWindow()
        return true
    }

    /// Saves the window's conversation once a turn was submitted, whether or not the model
    /// answered. A chat in Recently Deleted, or deleted for good, is never written or revived.
    /// False, with `saveError`, when it couldn't be saved; the conversation stays as it is.
    @discardableResult
    func saveWindowChat() -> Bool {
        guard let chat = windowChatStorage, !chat.isGenerating, !chat.isReadOnly,
            chat.messages.contains(where: { $0.role == .user }), chatStore.refusal(forSaving: chat.chatID) == nil
        else {
            saveError = nil
            return true
        }
        guard let saved = chatStore.save(chat.conversationState(), id: chat.chatID) else {
            saveError = chatStore.errorMessage ?? "This chat couldn't be saved."
            return false
        }
        chat.chatID = saved.id
        saveError = nil
        return true
    }

    /// Opens a saved chat in the window, after saving the one that was open. A chat in
    /// Recently Deleted opens read-only.
    @discardableResult
    func show(_ chatID: UUID) -> Bool {
        guard let saved = chatStore.chat(id: chatID), !windowChat.isGenerating, saveWindowChat() else { return false }
        windowChat.load(saved.state, agent: agent(id: saved.agentID))
        windowChat.chatID = saved.id
        windowChat.isReadOnly = saved.isDeleted
        return true
    }

    /// Starts a new conversation in the window, after saving the one that was open.
    @discardableResult
    func newWindowChat() -> Bool {
        guard !windowChat.isGenerating, saveWindowChat() else { return false }
        windowChat.newConversation(action: .chat)
        return true
    }

    /// Continues from a message in a new chat, leaving the original as it was.
    @discardableResult
    func branch(from messageID: UUID) -> Bool {
        guard saveWindowChat(), let chatID = windowChat.chatID, let branch = chatStore.branch(chatID, through: messageID)
        else { return false }
        return show(branch.id)
    }

    /// Moves a chat to Recently Deleted. If the window shows it, its reply stops and the
    /// window starts fresh; nothing saves into the deleted chat.
    func deleteChat(_ id: UUID) {
        guard chatStore.delete(id) else { return }
        detachWindowChat(if: [id])
    }

    func deletePermanently(_ id: UUID) {
        guard chatStore.deletePermanently(id) else { return }
        detachWindowChat(if: [id])
    }

    func emptyRecentlyDeleted() {
        let ids = Set(chatStore.recentlyDeleted.map(\.id))
        guard chatStore.emptyRecentlyDeleted() else { return }
        detachWindowChat(if: ids)
    }

    func restoreChat(_ id: UUID) {
        guard chatStore.restore(id) else { return }
        if let chat = windowChatStorage, chat.chatID == id { chat.isReadOnly = false }
    }

    func archiveChat(_ id: UUID) {
        guard saveWindowChat() else { return }
        chatStore.archive(id)
    }

    func deleteAllChats() {
        guard chatStore.deleteAll() else { return }
        detachWindowChat(if: nil)
    }

    /// Detaches the window's conversation when its chat is among `ids` (nil: any chat).
    private func detachWindowChat(if ids: Set<UUID>?) {
        guard let chat = windowChatStorage else { return }
        if let ids {
            guard let id = chat.chatID, ids.contains(id) else { return }
        }
        // Read-only first, so a reply finishing now can't save into the deleted chat.
        chat.isReadOnly = true
        Task { await chat.detach() }
    }

    // MARK: Attachments

    /// Attaches files to a conversation: text, code, PDFs and images. Problems show in the
    /// conversation. Files that finish reading after it became another conversation are dropped.
    func attachFiles(_ urls: [URL], to chat: AIChatModel) async {
        let token = chat.conversationToken
        for url in urls {
            do {
                let attachment = try await AIAttachmentLoader.load(url, capabilities: chat.capabilities, recognizer: recognizer)
                guard chat.conversationToken == token else { return }
                chat.attach(attachment)
            } catch {
                guard chat.conversationToken == token else { return }
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
        let token = chat.conversationToken
        do {
            let capture = try await screenCapture.capture(target)
            guard chat.conversationToken == token else { return }
            let attachment = try await AIAttachmentLoader.image(
                capture.png, name: capture.title, source: .screen, capabilities: chat.capabilities, recognizer: recognizer)
            // A capture that finishes after the conversation changed doesn't belong to the new one.
            guard chat.conversationToken == token else { return }
            chat.attach(attachment)
        } catch {
            guard chat.conversationToken == token else { return }
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
