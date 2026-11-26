import Foundation
import Observation

/// Text the next AI request will use. Nothing reaches the model unless it is
/// attached explicitly or arrives with a writing command from another app.
struct AIAttachment: Identifiable, Equatable, Sendable {
    /// Where the text came from. `.response` is a writing result carried into chat.
    enum Source: Equatable, Sendable {
        case clipboard, selection, response
        /// A file's text: plain text, code, or a PDF's text through PDFKit.
        case file
        /// A note from OpenRay's notes.
        case note
        /// An image or screenshot: sent as an image to models with vision, otherwise as its text.
        case image
        /// The focused window or the whole screen, captured on request.
        case screen

        var symbol: String {
            switch self {
            case .clipboard: "list.clipboard"
            case .selection: "character.cursor.ibeam"
            case .response: "sparkles"
            case .file: "doc.text"
            case .note: "note.text"
            case .image: "photo"
            case .screen: "macwindow"
            }
        }

        /// Chat keeps one chip for these; a new one replaces the old.
        var isSingular: Bool { [.clipboard, .selection, .response].contains(self) }

        /// Long text from these is summarized in parts to fit, instead of refused.
        var isCondensable: Bool { [.file, .note, .screen, .image].contains(self) }
    }
    var id = UUID()
    var source: Source
    var text: String
    var appName: String?
    /// A file name, note title or window title.
    var name: String? = nil
    /// The picture itself, for models with vision. `text` then holds its recognized text, if any.
    var image: AIImageInput? = nil

    var title: String {
        switch source {
        case .clipboard: "Clipboard"
        case .selection: appName.map { "Selection from \($0)" } ?? "Selection"
        case .response: "Previous result"
        case .file: name ?? "File"
        case .note: name.map { "Note: \($0)" } ?? "Note"
        case .image: name ?? "Image"
        case .screen: name ?? "Screen"
        }
    }

    var summary: String {
        if image != nil, text.isEmpty { return "\(title) · image" }
        return "\(title) · \(text.count.formatted()) chars"
    }

    /// Whether it gives the model anything: text, or an image.
    var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil }
}

/// A translator for the Translate command. The live one is Slice 3's `TranslationService`.
@MainActor
protocol AITextTranslating {
    func translate(_ text: String, toLanguageID languageID: String) async throws -> String
}

/// What the chat reads from the rest of OpenRay: agents, tools, a translator. The hub fills
/// it in; tests set what they need.
struct AIChatEnvironment {
    /// The current agents. When set, chat looks its agent up here before every request, so an
    /// edit or deletion takes effect in open conversations. Nil keeps the agent as chosen.
    var agents: (@MainActor () -> [Agent])? = nil
    var defaultAgent: @MainActor () -> Agent? = { nil }
    var toolExtensions: @MainActor () -> [AIToolExtension] = { [] }
    var toolBroker: AIToolBroker? = nil
    var translator: (any AITextTranslating)? = nil
}

/// A conversation as saved: what's on screen, the summary of folded turns and the engine's transcript.
struct AIConversationState: Equatable, Sendable {
    var messages: [ChatMessage]
    var summary: String?
    var summarizedMessageCount: Int
    var agentID: UUID?
    var transcript: Data?
}

/// What a writing result shows: the marked-up changes, the result alone, or the original passage.
enum AIDiffMode: Hashable, Sendable { case changes, result, original }

@MainActor
@Observable
final class AIChatModel {
    static let inputLimit = 6_000
    /// The most text a file, note or screen attachment may hold; longer text is summarized
    /// in parts to fit the model's window when it's sent.
    static let condensableLimit = 400_000
    var draft = ""
    /// An optional extra instruction for writing commands. Once a result is on screen it's the
    /// follow-up field (main #13): its text revises the result, and it empties after each run.
    var instruction = ""
    /// The instruction the latest writing run used, for Try Again.
    private(set) var lastInstruction = ""
    /// main #13: follow-ups already applied to the current writing result, oldest first.
    private(set) var acceptedRevisions: [String] = []
    /// A follow-up whose reply failed before writing anything. Try Again sends it again.
    private(set) var failedRevision: RevisionTurn?
    /// Revision turns by their user message, so Try Again repeats one with the context it had.
    @ObservationIgnored private var revisionTurns: [UUID: RevisionTurn] = [:]

    /// One follow-up and the result it revises.
    struct RevisionTurn: Equatable {
        var request: String
        var context: AIWritingContext
    }

    /// A writing command's work, put away while another command or chat is on screen, so opening
    /// the command again brings it back (main #12 kept one session per tool). Writing runs keep no
    /// model session (the engine resets after each), so the visible state is all there is.
    struct WritingSnapshot {
        var action: AIAction
        var conversationToken: UUID
        var draft: String
        var instruction: String
        var lastInstruction: String
        var attachments: [AIAttachment]
        var messages: [ChatMessage]
        var lastSource: String?
        var lastAttachment: AIAttachment?
        var acceptedRevisions: [String]
        var failedRevision: RevisionTurn?
        var revisionTurns: [UUID: RevisionTurn]
        var errorMessage: String?

        var hasWork: Bool {
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
                || !messages.isEmpty
        }
    }

    /// The writing command on screen, for putting away. Nil for chat, AI Commands and while a
    /// reply is being written.
    func writingSnapshot() -> WritingSnapshot? {
        guard action != .chat, command == nil, !isGenerating else { return nil }
        return WritingSnapshot(
            action: action, conversationToken: conversationToken, draft: draft, instruction: instruction,
            lastInstruction: lastInstruction, attachments: attachments, messages: messages, lastSource: lastSource,
            lastAttachment: lastAttachment, acceptedRevisions: acceptedRevisions, failedRevision: failedRevision,
            revisionTurns: revisionTurns, errorMessage: errorMessage)
    }

    /// Brings a put-away writing command back exactly as it was.
    func restoreWriting(_ snapshot: WritingSnapshot) {
        guard !isGenerating else { return }
        newConversation(action: snapshot.action)
        conversationToken = snapshot.conversationToken
        draft = snapshot.draft
        instruction = snapshot.instruction
        lastInstruction = snapshot.lastInstruction
        attachments = snapshot.attachments
        messages = snapshot.messages
        lastSource = snapshot.lastSource
        lastAttachment = snapshot.lastAttachment
        acceptedRevisions = snapshot.acceptedRevisions
        failedRevision = snapshot.failedRevision
        revisionTurns = snapshot.revisionTurns
        errorMessage = snapshot.errorMessage
        updateDiff()
        engine.prepare(for: snapshot.action)
    }

    /// Whether a reply answers a follow-up. Those are free-form text, even for Extract Action
    /// Items, so they're never read as a checklist.
    func repliesToRevision(_ message: ChatMessage) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == message.id }),
            let request = messages[..<index].last(where: { $0.role == .user })
        else { return false }
        return revisionTurns[request.id] != nil
    }

    /// Unsent text, a passage not yet run, or any result or failure on screen.
    var hasWritingWork: Bool { writingSnapshot()?.hasWork ?? false }
    private(set) var attachments: [AIAttachment] = []
    private(set) var messages: [ChatMessage] = []
    private(set) var action: AIAction = .chat
    private(set) var availability: AIAvailability
    private(set) var isGenerating = false
    private(set) var isCancelling = false
    private(set) var errorMessage: String?
    /// The passage and attachment behind the latest writing result, for diffs and Replace.
    private(set) var lastSource: String?
    private(set) var lastAttachment: AIAttachment?
    /// The finished writing result's word diff, computed once rather than on every redraw.
    private(set) var lastDiff: WordDiff?
    /// Which view of a writing result is showing. ⌘K can change it, so it lives here.
    var diffMode = AIDiffMode.changes
    /// The AI Command on screen: a custom command or an added built-in. Nil for chat and the
    /// original writing commands, which `action` describes.
    private(set) var command: AICommandRun?
    /// Who chat talks to. Nil is the plain assistant.
    private(set) var agent: Agent?
    /// The rolling summary of turns that no longer fit the model's window.
    private(set) var summary: String?
    /// How many messages, from the start, the summary stands for.
    private(set) var summarizedMessageCount = 0
    /// Says, once, that earlier turns or an attachment were summarized to fit.
    private(set) var condensationNotice: String?
    /// The saved chat this conversation is, in the chat window.
    var chatID: UUID?
    /// A chat in Recently Deleted: shown, but nothing can be sent until it's restored.
    var isReadOnly = false
    /// Why the current reply was stopped by OpenRay rather than by the person.
    @ObservationIgnored private var stoppedReason: String?
    /// Changes whenever this becomes a different conversation, so work that finishes later
    /// (a capture, a file read) can tell it no longer belongs here.
    private(set) var conversationToken = UUID()
    @ObservationIgnored var environment = AIChatEnvironment()
    /// Called after each response finishes or fails, so the chat window can save.
    @ObservationIgnored var onConversationChange: (() -> Void)?
    @ObservationIgnored let engine: any AIEngine
    @ObservationIgnored let hub: AIHub
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    /// The profile the engine's session was built with, so a switch of agent or tools carries
    /// the conversation over instead of dropping it.
    @ObservationIgnored private var activeProfile: AIRequestProfile?
    /// What each chat turn asked for beyond its text: tools, images, long attachments.
    @ObservationIgnored private var turnRequests: [UUID: TurnRequest] = [:]

    private struct TurnRequest {
        var plan: AIToolPlan
        var images: [AIImageInput]
        /// Long attachments, summarized to fit before the turn is sent.
        var condensable: [AIAttachment]
        var question: String
        var shortAttachments: [AIAttachment]
    }

    /// `engine` nil uses Apple's model, except in the test host, where nothing reaches a real
    /// model unless a test passes one in.
    init(engine: (any AIEngine)? = nil, hub: AIHub? = nil) {
        let engine = engine ?? (SideEffectGuard.isTestHost ? InertAIEngine() : FoundationModelEngine())
        self.engine = engine
        availability = engine.availability
        self.hub = hub ?? AIHub()
        if hub == nil { self.hub.panelChat = self }
    }

    /// What the active model supports.
    var capabilities: AIModelCapabilities { engine.capabilities }
    /// Engines that predate capabilities report none; tool calling is only withheld from
    /// engines that report capabilities without it.
    private var engineReportsCapabilities: Bool { !capabilities.isEmpty }

    /// What the header and result call this run.
    var title: String { command?.title ?? action.title }
    var symbol: String { command?.symbol ?? action.kindSymbol }
    var runTitle: String { command == nil ? action.runTitle : "Run" }
    var subtitle: String { command?.title ?? action.subtitle }
    /// Writing results with a word diff: the original transforms, and commands that replace a selection.
    var showsDiff: Bool {
        guard let command else { return action.showsDiff }
        return command.output == .replace && command.source != nil && command.performer == .model
    }

    /// Ready to run. Translation needs no Apple Intelligence.
    var isReady: Bool {
        if case .translation? = command?.performer { return true }
        return availability.isAvailable
    }

    /// Characters that will be sent, including attachments. Long files, notes and screens
    /// don't count: they're summarized to fit when sent.
    var pendingCharacterCount: Int {
        action == .chat
            ? draft.count + attachments.filter { !$0.source.isCondensable }.reduce(0) { $0 + $1.text.count }
            : (attachments.first?.text.count ?? draft.count) + instruction.count
    }

    var hasPendingInput: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments.contains(where: \.hasContent)
    }

    var canSend: Bool {
        guard availability.isAvailable, !isGenerating, !isReadOnly else { return false }
        if isRevising { return instruction.count <= Self.inputLimit }
        return hasPendingInput && pendingCharacterCount <= Self.inputLimit
    }

    /// The latest finished writing result, never a stopped one.
    var lastCompletedResult: String? {
        guard action != .chat else { return nil }
        return messages.last { $0.role == .assistant && !$0.isPartial && !$0.text.isEmpty }?.text
    }

    /// What a follow-up revises: the original passage, the latest finished result and the
    /// follow-ups so far. Nil in chat, for AI Commands, and before the first result.
    var writingContext: AIWritingContext? {
        guard action != .chat, command == nil, !isGenerating, let source = lastSource, let result = lastCompletedResult
        else { return nil }
        return AIWritingContext(originalPassage: source, currentResult: result, acceptedRevisions: acceptedRevisions)
    }

    /// Whether sending now revises the current result with the follow-up field's text.
    var isRevising: Bool {
        writingContext != nil && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The latest assistant reply. A stopped writing result never counts, so it can't be copied
    /// or replaced; a stopped chat reply keeps its “Stopped” label and stays usable.
    var latestResponse: ChatMessage? {
        guard let last = messages.last, last.role == .assistant, !last.text.isEmpty, action == .chat || !last.isPartial
        else { return nil }
        return last
    }

    /// Try Again needs a finished run to repeat. A stopped writing result counts here,
    /// though it can't be copied or replaced.
    var canRetry: Bool { !isGenerating && !isReadOnly && messages.last?.role == .assistant }

    func refreshAvailability() { availability = engine.availability }

    func open(_ action: AIAction) {
        refreshAvailability()
        guard !isGenerating else { return }
        if self.action != action || command != nil { newConversation(action: action) }
        engine.prepare(for: action)
    }

    func newConversation(action: AIAction? = nil) {
        guard !isGenerating else { return }
        engine.reset()
        messages = []
        errorMessage = nil
        draft = ""
        instruction = ""
        lastInstruction = ""
        acceptedRevisions = []
        failedRevision = nil
        revisionTurns = [:]
        attachments = []
        lastSource = nil
        lastAttachment = nil
        lastDiff = nil
        diffMode = .changes
        command = nil
        summary = nil
        summarizedMessageCount = 0
        condensationNotice = nil
        activeProfile = nil
        turnRequests = [:]
        chatID = nil
        isReadOnly = false
        conversationToken = UUID()
        agent = environment.defaultAgent()
        environment.toolBroker?.clearActivity()
        if let action { self.action = action }
    }

    func useText(_ text: String) {
        guard text.count <= Self.inputLimit else {
            errorMessage =
                "Choose a shorter passage. On-device requests support up to \(Self.inputLimit.formatted()) characters here. No text has been truncated."
            return
        }
        draft = text
        errorMessage = nil
    }

    /// Attaches text as a chip. Writing commands keep a single source passage. Chat keeps one
    /// chip per clipboard, selection and carried-over result, and any number of files, notes,
    /// images and screens.
    func attach(_ attachment: AIAttachment) {
        // A writing reply in flight keeps the passage it was asked about.
        guard action == .chat || !isGenerating else { return }
        let limit = action == .chat && attachment.source.isCondensable ? Self.condensableLimit : Self.inputLimit
        guard attachment.text.count <= limit else {
            errorMessage =
                "That text is longer than \(limit.formatted()) characters. Choose a shorter passage; nothing was attached."
            return
        }
        if action == .chat {
            if attachment.source.isSingular {
                attachments.removeAll { $0.source == attachment.source }
            } else {
                attachments.removeAll { $0.source == attachment.source && $0.name == attachment.name && $0.text == attachment.text }
            }
            attachments.append(attachment)
        } else {
            attachments = [attachment]
        }
        errorMessage = nil
    }

    func removeAttachment(_ id: AIAttachment.ID) {
        guard action == .chat || !isGenerating else { return }
        attachments.removeAll { $0.id == id }
        // The instruction field only shows with a passage, so don't keep a hidden one.
        if action != .chat, attachments.isEmpty { instruction = "" }
    }

    /// Shows a problem in the conversation, such as an attachment that couldn't be read.
    func report(_ message: String) { errorMessage = message }

    // MARK: Agents

    /// Chooses who chat talks to. The conversation carries over to the new agent.
    func selectAgent(_ agent: Agent?) {
        guard !isGenerating else { return }
        self.agent = agent?.isAssistant == true ? nil : agent
        errorMessage = nil
    }

    /// Drops a deleted agent, even mid-reply: a reply it was writing stops, and the next
    /// request goes to the assistant.
    func forgetAgent(_ id: UUID) {
        guard agent?.id == id else { return }
        agent = nil
        if isGenerating {
            cancel()
            stoppedReason = "The agent was deleted, so its reply stopped."
        }
    }

    /// The agent lost tools: a reply it's writing stops, so it can't read with them.
    func agentToolsRevoked(_ id: UUID) {
        guard agent?.id == id, isGenerating else { return }
        cancel()
        stoppedReason = "The agent's tools changed, so its reply stopped."
    }

    /// The agent as it's defined now: edits apply, and a deleted one falls back to the assistant.
    private func currentAgent() -> Agent? {
        guard let agent, let agents = environment.agents else { return agent }
        let current = agents().first { $0.id == agent.id }
        if current == nil || current?.isAssistant == true { self.agent = nil }
        return current?.isAssistant == true ? nil : current
    }

    // MARK: Sending

    func send() {
        refreshAvailability()
        guard !isReadOnly else { return }
        if action == .chat,
            let switched = AgentSwitch.parse(draft.trimmingCharacters(in: .whitespaces), agents: environment.agents?() ?? [])
        {
            // “/writer” switches agents; anything after it is sent to the new agent.
            selectAgent(switched.agent)
            draft = switched.remainder
            if switched.remainder.isEmpty, !attachments.contains(where: \.hasContent) { return }
        }
        guard canSend else { return }
        if isRevising, let context = writingContext {
            let request = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            revise(RevisionTurn(request: request, context: context))
            return
        }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Writing operations need the exact passage, including surrounding layout.
        // canSend already rejects whitespace-only drafts without modifying them.
        let prompt: String
        var display: String?
        var turn: TurnRequest?
        if action == .chat {
            let plan = AIToolRouter.plan(
                text: typed, extensions: environment.toolBroker == nil ? [] : environment.toolExtensions(),
                agentToolIDs: currentAgent()?.toolIDs ?? [])
            let question = plan.mode == .required ? plan.prompt : typed
            let short = attachments.filter { !$0.source.isCondensable && $0.hasContent }
            let long = attachments.filter { $0.source.isCondensable && !$0.text.isEmpty }
            let images = capabilities.contains(.vision) ? attachments.compactMap(\.image) : []
            prompt = Self.chatPrompt(question: question, attachments: short + long)
            display = attachments.isEmpty && question == typed ? nil : typed
            turn = TurnRequest(plan: plan, images: images, condensable: long, question: question, shortAttachments: short)
        } else {
            prompt = attachments.first?.text ?? draft
            display = nil
        }
        let labels = attachments.map(\.summary)
        let instruction = action == .chat ? "" : instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSource = action == .chat ? nil : prompt
        lastAttachment = action == .chat ? nil : attachments.first
        draft = ""
        if action == .chat {
            attachments = []
        } else {
            // A new run on the passage: earlier follow-ups no longer apply, and the field is free
            // for the next one.
            lastInstruction = instruction
            self.instruction = ""
            acceptedRevisions = []
            failedRevision = nil
        }
        errorMessage = nil
        let message = ChatMessage(role: .user, text: prompt, displayText: display, attachmentLabels: labels)
        if let turn { turnRequests[message.id] = turn }
        messages.append(message)
        run(prompt, instruction: instruction)
    }

    /// Sends a follow-up that revises the current writing result (main #13).
    private func revise(_ turn: RevisionTurn) {
        instruction = ""
        failedRevision = nil
        errorMessage = nil
        let message = ChatMessage(role: .user, text: turn.request)
        revisionTurns[message.id] = turn
        messages.append(message)
        run(turn.request, instruction: "", revision: turn)
    }

    /// Attachments are marked as reference data, apart from the question, so the model
    /// doesn't follow instructions that happen to be inside them.
    static func chatPrompt(question: String, attachments: [AIAttachment]) -> String {
        let blocks = attachments.filter { !$0.text.isEmpty }.map { attachment in
            let source = attachment.title.replacingOccurrences(of: "\"", with: "'")
            return "<attachment source=\"\(source)\">\n\(attachment.text)\n</attachment>"
        }
        let wrapped = question.isEmpty ? [] : ["<question>\n\(question)\n</question>"]
        return blocks.isEmpty ? question : (blocks + wrapped).joined(separator: "\n\n")
    }

    /// Runs an AI Command right away on the text it rendered, in the writing view.
    func start(_ run: AICommandRun) {
        refreshAvailability()
        guard !isGenerating else { return }
        newConversation(action: run.output == .replace ? .rewrite : .summarize)
        command = run
        guard isReady else { return }
        lastSource = run.source ?? run.prompt
        lastAttachment =
            run.output == .replace ? run.source.map { AIAttachment(source: .selection, text: $0, appName: run.sourceAppName) } : nil
        messages.append(ChatMessage(role: .user, text: run.prompt, displayText: run.title))
        self.run(run.prompt, instruction: "")
    }

    /// Generates the latest response again from the same input. If the new run produces
    /// nothing, the previous response comes back.
    func retry() {
        guard !isGenerating, !isReadOnly else { return }
        // A follow-up that failed before writing anything left the previous result on screen.
        if let failed = failedRevision, messages.last?.role == .assistant {
            if instruction.trimmingCharacters(in: .whitespacesAndNewlines) == failed.request { instruction = "" }
            engine.reset()
            revise(failed)
            return
        }
        guard let index = messages.lastIndex(where: { $0.role == .user }) else { return }
        let prompt = messages[index].text
        let revision = revisionTurns[messages[index].id]
        let previous = Array(messages[(index + 1)...])
        messages.removeSubrange((index + 1)...)
        errorMessage = nil
        if action == .chat { engine.discardLastExchange() } else { engine.reset() }
        run(prompt, instruction: action == .chat ? "" : lastInstruction, restoring: previous, revision: revision)
    }

    private func run(
        _ prompt: String, instruction: String, restoring previous: [ChatMessage] = [], revision: RevisionTurn? = nil
    ) {
        isGenerating = true
        isCancelling = false
        diffMode = .changes
        lastDiff = nil
        let userMessageID = messages.last(where: { $0.role == .user })?.id
        let response = ChatMessage(role: .assistant, text: "", isPartial: true)
        messages.append(response)
        let action = self.action
        let command = self.command
        generationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isGenerating = false
                self.isCancelling = false
                self.stoppedReason = nil
                self.generationTask = nil
                self.onConversationChange?()
            }
            let apply: @MainActor (AIResponseSnapshot) -> Void = { [weak self] snapshot in
                guard let self, let index = self.messages.firstIndex(where: { $0.id == response.id }) else { return }
                self.messages[index].text = snapshot.text
                self.messages[index].actionItems = snapshot.actionItems
            }
            do {
                if let revision {
                    try await self.engine.streamRevision(
                        revision.request, context: revision.context, action: action, onSnapshot: apply)
                } else if let command {
                    try await self.generate(command, prompt: prompt, onSnapshot: apply)
                } else if action == .chat {
                    try await self.generateChat(prompt, userMessageID: userMessageID, onSnapshot: apply)
                } else {
                    try await self.engine.stream(prompt, action: action, instruction: instruction, onSnapshot: apply)
                }
                if let index = self.messages.firstIndex(where: { $0.id == response.id }) {
                    self.messages[index].isPartial = false
                    if let revision, !self.messages[index].text.isEmpty {
                        self.acceptedRevisions = revision.context.acceptedRevisions + [revision.request]
                    }
                    if self.messages[index].text.isEmpty {
                        self.messages.remove(at: index)
                        if action == .chat, !previous.isEmpty {
                            // A chat Try Again already dropped the old reply from the session, so the
                            // reply that comes back is on screen only. Start clean rather than mislead.
                            self.engine.reset()
                            self.errorMessage =
                                "The model returned an empty response. The next message starts a fresh session."
                        } else {
                            self.errorMessage = "The model returned an empty response. Try a more specific request."
                        }
                        self.recoverFromEmptyRun(prompt: prompt, action: action, restoring: previous, revision: revision)
                    }
                }
            } catch {
                self.engine.reset()
                self.environment.toolBroker?.declineAll()
                if self.isCancelling || error is CancellationError {
                    self.errorMessage =
                        self.stoppedReason.map { "\($0) The next message starts a fresh session." }
                        ?? "Response stopped. The next message starts a fresh session."
                } else if revision != nil, error as? AIServiceError == .contextFull {
                    self.errorMessage =
                        "This revision reached the model’s context limit. Your passage and result are kept. Shorten your request, or use the result as a new passage."
                } else {
                    self.errorMessage = error.localizedDescription
                }
                // Incomplete responses keep their explicit “Stopped” label.
                if self.messages.contains(where: { $0.id == response.id && $0.text.isEmpty }) {
                    self.messages.removeAll { $0.id == response.id }
                    self.recoverFromEmptyRun(prompt: prompt, action: action, restoring: previous, revision: revision)
                }
                self.refreshAvailability()
            }
            self.updateDiff()
        }
    }

    /// A chat turn: long attachments summarized to fit, older turns condensed when the window
    /// would overflow, then the request with its agent, tools and images.
    private func generateChat(
        _ prompt: String, userMessageID: UUID?, onSnapshot: @escaping @MainActor (AIResponseSnapshot) -> Void
    ) async throws {
        var prompt = prompt
        let turn = userMessageID.flatMap { turnRequests[$0] }
        if let turn, !turn.condensable.isEmpty {
            prompt = try await condenseAttachments(turn, userMessageID: userMessageID)
        }
        var plan = turn?.plan ?? AIToolPlan(tools: [], mode: .none, prompt: prompt, mentionedExtensionIDs: [])
        let agent = currentAgent()
        if plan.mode == .allowed {
            // Tools the agent offered when this turn was planned, still granted now. A tool
            // the person removed from the agent since then isn't offered again.
            let granted = Set(agent?.toolIDs ?? [])
            plan.tools.removeAll { !granted.contains($0.id) }
            if plan.tools.isEmpty { plan.mode = .none }
        }
        if !capabilities.contains(.toolCalling), engineReportsCapabilities {
            plan = AIToolPlan(tools: [], mode: .none, prompt: plan.prompt, mentionedExtensionIDs: plan.mentionedExtensionIDs)
        }
        let profile = (agent ?? .assistant).profile(capabilities: capabilities, hasTools: !plan.tools.isEmpty)
        try await prepareContext(prompt: prompt, profile: profile, tools: plan.tools, before: userMessageID)
        try Task.checkCancellation()
        // Every call is checked against the grants at that moment: a tool the person mentioned
        // in this turn, or one the current agent still grants.
        let mentioned = plan.mode == .required ? Set(plan.tools.map(\.id)) : []
        let invoker = environment.toolBroker.map { broker in
            GrantedToolInvoker(broker: broker) { [weak self] toolID in
                mentioned.contains(toolID) || (self?.currentAgent()?.toolIDs.contains(toolID) ?? false)
            }
        }
        let request = AIRequest(
            prompt: prompt, images: turn?.images ?? [], profile: profile, tools: plan.tools, toolMode: plan.mode,
            toolInvoker: plan.tools.isEmpty ? nil : invoker, fallbackAction: .chat)
        try await engine.stream(request, onSnapshot: onSnapshot)
    }

    private func generate(
        _ command: AICommandRun, prompt: String, onSnapshot: @escaping @MainActor (AIResponseSnapshot) -> Void
    ) async throws {
        switch command.performer {
        case .model:
            let request = AIRequest(
                prompt: prompt, profile: command.profile,
                fallbackAction: command.output == .replace ? .rewrite : .summarize)
            try await engine.stream(request, onSnapshot: onSnapshot)
        case .translation:
            guard let translator = environment.translator, let target = command.targetLanguageID else {
                throw AIServiceError.failed("Translation isn't available here.")
            }
            let text = try await translator.translate(prompt, toLanguageID: target)
            try Task.checkCancellation()
            onSnapshot(AIResponseSnapshot(text: text))
        }
    }

    /// Summarizes long attachments in parts until the turn fits, and keeps the shorter prompt
    /// as the turn's text, so Try Again and later turns use it.
    private func condenseAttachments(_ turn: TurnRequest, userMessageID: UUID?) async throws -> String {
        let counter = EngineTokenCounter(engine: engine)
        let budget = ContextBudget(contextSize: await counter.contextSize(), responseReserve: 900)
        let condenser = AttachmentCondenser(counter: counter, summarizer: EngineSummarizer(engine: engine))
        let share = max(64, budget.attachmentBudget / max(1, turn.condensable.count))
        var fitted: [AIAttachment] = []
        var condensed = false
        for attachment in turn.condensable {
            let focus =
                turn.question.isEmpty
                ? "Summarize this part of \(attachment.title), keeping its key facts."
                : "Summarize this part of \(attachment.title), keeping what helps answer: \(turn.question)"
            let result = try await condenser.fit(attachment.text, within: share, chunkBudget: budget.chunkBudget, focus: focus)
            var copy = attachment
            copy.text = result.text
            condensed = condensed || result.wasCondensed
            fitted.append(copy)
        }
        let prompt = Self.chatPrompt(question: turn.question, attachments: turn.shortAttachments + fitted)
        if condensed {
            condensationNotice = "Long attachments were summarized in parts to fit the on-device model."
            if let userMessageID, let index = messages.firstIndex(where: { $0.id == userMessageID }) {
                messages[index].text = prompt
            }
        }
        if let userMessageID { turnRequests[userMessageID]?.condensable = [] }
        return prompt
    }

    /// Earlier exchanges after the summary, oldest first, with how many messages each covers.
    private func turns(before messageID: UUID?) -> [(turn: AIConversationContext.Turn, messages: Int)] {
        let end = messageID.flatMap { id in messages.firstIndex { $0.id == id } } ?? messages.count
        var result: [(turn: AIConversationContext.Turn, messages: Int)] = []
        var index = min(summarizedMessageCount, end)
        while index < end {
            let message = messages[index]
            if message.role == .user, index + 1 < end, messages[index + 1].role == .assistant {
                let turn = AIConversationContext.Turn(prompt: message.text, response: messages[index + 1].text)
                result.append((turn: turn, messages: 2))
                index += 2
            } else {
                let isUser = message.role == .user
                let turn = AIConversationContext.Turn(prompt: isUser ? message.text : "", response: isUser ? "" : message.text)
                result.append((turn: turn, messages: 1))
                index += 1
            }
        }
        return result
    }

    /// Measures the turn against the window and folds old turns into the summary when it
    /// would overflow. Also carries the conversation over when the agent or tools changed.
    private func prepareContext(prompt: String, profile: AIRequestProfile, tools: [AIToolSpec], before messageID: UUID?)
        async throws
    {
        let earlier = turns(before: messageID)
        let toolTokens = tools.isEmpty ? 0 : await engine.toolTokenCount(tools)
        let condenser = ChatCondenser(counter: EngineTokenCounter(engine: engine), summarizer: EngineSummarizer(engine: engine))
        let outcome = try await condenser.prepare(
            profile: profile, summary: summary, turns: earlier.map(\.turn), prompt: prompt, toolTokens: toolTokens)
        if let rebuilt = outcome.rebuilt {
            summary = outcome.summary
            summarizedMessageCount += earlier.prefix(outcome.foldedTurns).reduce(0) { $0 + $1.messages }
            engine.rebuild(rebuilt)
            condensationNotice = "Earlier messages were summarized to fit the on-device model's context."
        } else if let activeProfile, activeProfile != profile, !earlier.isEmpty {
            engine.rebuild(AIConversationContext(profile: profile, summary: summary, turns: earlier.map(\.turn)))
        }
        activeProfile = profile
    }

    /// A run that produced no text leaves things as they were: Try Again brings back the
    /// previous response, and a typed writing passage returns to the field instead of vanishing.
    private func recoverFromEmptyRun(
        prompt: String, action: AIAction, restoring previous: [ChatMessage], revision: RevisionTurn? = nil
    ) {
        if !previous.isEmpty {
            messages.append(contentsOf: previous)
        } else if let revision {
            // The previous result stays on screen, never replaced by default; the follow-up waits in
            // its field unless a newer one was typed meanwhile, and Try Again sends it again.
            if messages.last?.role == .user { messages.removeLast() }
            failedRevision = revision
            if instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { instruction = revision.request }
        } else if action != .chat, command == nil, lastAttachment == nil, draft.isEmpty {
            draft = prompt
            if messages.last?.role == .user { messages.removeLast() }
        }
        // A failed first run gives its instruction back, unless another was typed meanwhile.
        if revision == nil, action != .chat, command == nil, previous.isEmpty, instruction.isEmpty {
            instruction = lastInstruction
        }
    }

    private func updateDiff() {
        guard showsDiff, let source = lastSource, let response = latestResponse else {
            lastDiff = nil
            return
        }
        lastDiff = WordDiff(from: source, to: response.text)
    }

    func cancel() {
        guard isGenerating else { return }
        isCancelling = true
        environment.toolBroker?.declineAll()
        generationTask?.cancel()
    }

    func waitForResponse() async { await generationTask?.value }

    func dismissCondensationNotice() { condensationNotice = nil }

    // MARK: Saving and resuming

    /// The conversation as the chat store keeps it.
    func conversationState() -> AIConversationState {
        AIConversationState(
            messages: messages.filter { !($0.role == .assistant && $0.text.isEmpty) }, summary: summary,
            summarizedMessageCount: summarizedMessageCount, agentID: agent?.id, transcript: engine.exportTranscript())
    }

    /// Resumes a saved conversation: the engine's own transcript when it can read it, with its
    /// instructions replaced by the agent's current ones, otherwise a session rebuilt from the
    /// summary and the recent turns. What the model knows matches what's shown either way.
    func load(_ state: AIConversationState, agent: Agent?) {
        guard !isGenerating else { return }
        newConversation(action: .chat)
        messages = state.messages
        summary = state.summary
        summarizedMessageCount = min(state.summarizedMessageCount, state.messages.count)
        self.agent = agent?.isAssistant == true ? nil : agent
        refreshAvailability()
        guard !messages.isEmpty else { return }
        let profile = (self.agent ?? .assistant).profile(capabilities: capabilities, hasTools: false)
        let context = AIConversationContext(profile: profile, summary: summary, turns: turns(before: nil).map(\.turn))
        if let data = state.transcript, engine.restoreTranscript(data, context: context) {
            activeProfile = profile
        } else {
            engine.rebuild(context)
            activeProfile = profile
        }
    }

    /// This conversation as Continue in Chat moves it, without clearing it. The caller clears
    /// it with `newConversation` only once the copy is saved.
    func transferState() -> AIConversationState? {
        guard !isGenerating, messages.contains(where: { $0.role == .assistant && !$0.text.isEmpty }) else { return nil }
        var state = conversationState()
        if action != .chat {
            // A writing result continues as chat with the result as its first reply.
            state.transcript = nil
            state.summary = nil
            state.summarizedMessageCount = 0
        }
        return state.messages.isEmpty ? nil : state
    }

    /// Stops any reply and empties the conversation, even mid-reply: its chat was deleted.
    /// Nothing happens when it has meanwhile become another conversation.
    func detach(ifStill token: UUID? = nil) async {
        guard token == nil || token == conversationToken else { return }
        isReadOnly = true
        if isGenerating {
            cancel()
            await waitForResponse()
        }
        guard token == nil || token == conversationToken else { return }
        newConversation(action: .chat)
    }
}
