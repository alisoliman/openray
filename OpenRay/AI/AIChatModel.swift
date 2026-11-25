import Foundation
import Observation

/// Text the next AI request will use. Nothing reaches the model unless it is
/// attached explicitly or arrives with a writing command from another app.
struct AIAttachment: Identifiable, Equatable, Sendable {
    /// Where the text came from. `.response` is a writing result carried into chat.
    enum Source: Equatable, Sendable {
        case clipboard, selection, response

        var symbol: String {
            switch self {
            case .clipboard: "list.clipboard"
            case .selection: "character.cursor.ibeam"
            case .response: "sparkles"
            }
        }
    }
    var id = UUID()
    var source: Source
    var text: String
    var appName: String?

    var title: String {
        switch source {
        case .clipboard: "Clipboard"
        case .selection: appName.map { "Selection from \($0)" } ?? "Selection"
        case .response: "Previous result"
        }
    }

    var summary: String { "\(title) · \(text.count.formatted()) chars" }
}

/// What a writing result shows: the marked-up changes, the result alone, or the original passage.
enum AIDiffMode: Hashable, Sendable { case changes, result, original }

@MainActor
@Observable
final class AIChatModel {
    static let inputLimit = 6_000
    var draft = ""
    /// An optional extra instruction for writing commands.
    var instruction = ""
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
    @ObservationIgnored private let engine: any AIEngine
    @ObservationIgnored private var generationTask: Task<Void, Never>?

    init(engine: any AIEngine = FoundationModelEngine()) {
        self.engine = engine
        availability = engine.availability
    }

    /// Characters that will be sent, including attachments.
    var pendingCharacterCount: Int {
        action == .chat
            ? draft.count + attachments.reduce(0) { $0 + $1.text.count }
            : (attachments.first?.text.count ?? draft.count) + instruction.count
    }

    var hasPendingInput: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || attachments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var canSend: Bool {
        availability.isAvailable && !isGenerating && hasPendingInput && pendingCharacterCount <= Self.inputLimit
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
    var canRetry: Bool { !isGenerating && messages.last?.role == .assistant }

    func refreshAvailability() { availability = engine.availability }

    func open(_ action: AIAction) {
        refreshAvailability()
        guard !isGenerating else { return }
        if self.action != action { newConversation(action: action) }
        engine.prepare(for: action)
    }

    func newConversation(action: AIAction? = nil) {
        guard !isGenerating else { return }
        engine.reset()
        messages = []
        errorMessage = nil
        draft = ""
        instruction = ""
        attachments = []
        lastSource = nil
        lastAttachment = nil
        lastDiff = nil
        diffMode = .changes
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
    /// chip per source, so a carried-over result and the clipboard can sit side by side.
    func attach(_ attachment: AIAttachment) {
        guard attachment.text.count <= Self.inputLimit else {
            errorMessage =
                "That text is longer than \(Self.inputLimit.formatted()) characters. Choose a shorter passage; nothing was attached."
            return
        }
        if action == .chat {
            attachments.removeAll { $0.source == attachment.source }
            attachments.append(attachment)
        } else {
            attachments = [attachment]
        }
        errorMessage = nil
    }

    func removeAttachment(_ id: AIAttachment.ID) {
        attachments.removeAll { $0.id == id }
        // The instruction field only shows with a passage, so don't keep a hidden one.
        if action != .chat, attachments.isEmpty { instruction = "" }
    }

    func send() {
        refreshAvailability()
        guard canSend else { return }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Writing operations need the exact passage, including surrounding layout.
        // canSend already rejects whitespace-only drafts without modifying them.
        let prompt: String
        let display: String?
        if action == .chat {
            // Attachments are marked as reference data, apart from the question, so the model
            // doesn't follow instructions that happen to be inside them.
            let blocks = attachments.filter { !$0.text.isEmpty }.map { attachment in
                let source = attachment.title.replacingOccurrences(of: "\"", with: "'")
                return "<attachment source=\"\(source)\">\n\(attachment.text)\n</attachment>"
            }
            let question = typed.isEmpty ? [] : ["<question>\n\(typed)\n</question>"]
            prompt = blocks.isEmpty ? typed : (blocks + question).joined(separator: "\n\n")
            display = attachments.isEmpty ? nil : typed
        } else {
            prompt = attachments.first?.text ?? draft
            display = nil
        }
        let labels = attachments.map(\.summary)
        let instruction = action == .chat ? "" : instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSource = action == .chat ? nil : prompt
        lastAttachment = action == .chat ? nil : attachments.first
        draft = ""
        if action == .chat { attachments = [] }
        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: prompt, displayText: display, attachmentLabels: labels))
        run(prompt, instruction: instruction)
    }

    /// Generates the latest response again from the same input. If the new run produces
    /// nothing, the previous response comes back.
    func retry() {
        guard !isGenerating, let index = messages.lastIndex(where: { $0.role == .user }) else { return }
        let prompt = messages[index].text
        let previous = Array(messages[(index + 1)...])
        messages.removeSubrange((index + 1)...)
        errorMessage = nil
        if action == .chat { engine.discardLastExchange() } else { engine.reset() }
        run(
            prompt, instruction: action == .chat ? "" : instruction.trimmingCharacters(in: .whitespacesAndNewlines),
            restoring: previous)
    }

    private func run(_ prompt: String, instruction: String, restoring previous: [ChatMessage] = []) {
        isGenerating = true
        isCancelling = false
        diffMode = .changes
        lastDiff = nil
        let response = ChatMessage(role: .assistant, text: "", isPartial: true)
        messages.append(response)
        let action = self.action
        generationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isGenerating = false
                self.isCancelling = false
                self.generationTask = nil
            }
            do {
                try await self.engine.stream(prompt, action: action, instruction: instruction) { [weak self] snapshot in
                    guard let self, let index = self.messages.firstIndex(where: { $0.id == response.id }) else {
                        return
                    }
                    self.messages[index].text = snapshot.text
                    self.messages[index].actionItems = snapshot.actionItems
                }
                if let index = self.messages.firstIndex(where: { $0.id == response.id }) {
                    self.messages[index].isPartial = false
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
                        self.recoverFromEmptyRun(prompt: prompt, action: action, restoring: previous)
                    }
                }
            } catch {
                self.engine.reset()
                if self.isCancelling || error is CancellationError {
                    self.errorMessage = "Response stopped. The next message starts a fresh session."
                } else {
                    self.errorMessage = error.localizedDescription
                }
                // Incomplete responses keep their explicit “Stopped” label.
                if self.messages.contains(where: { $0.id == response.id && $0.text.isEmpty }) {
                    self.messages.removeAll { $0.id == response.id }
                    self.recoverFromEmptyRun(prompt: prompt, action: action, restoring: previous)
                }
                self.refreshAvailability()
            }
            self.updateDiff()
        }
    }

    /// A run that produced no text leaves things as they were: Try Again brings back the
    /// previous response, and a typed writing passage returns to the field instead of vanishing.
    private func recoverFromEmptyRun(prompt: String, action: AIAction, restoring previous: [ChatMessage]) {
        if !previous.isEmpty {
            messages.append(contentsOf: previous)
        } else if action != .chat, lastAttachment == nil, draft.isEmpty {
            draft = prompt
            if messages.last?.role == .user { messages.removeLast() }
        }
    }

    private func updateDiff() {
        guard action.showsDiff, let source = lastSource, let response = latestResponse else {
            lastDiff = nil
            return
        }
        lastDiff = WordDiff(from: source, to: response.text)
    }

    func cancel() {
        guard isGenerating else { return }
        isCancelling = true
        generationTask?.cancel()
    }

    func waitForResponse() async { await generationTask?.value }
}
