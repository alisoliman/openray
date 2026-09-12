import Foundation
import Observation

@MainActor
@Observable
final class AIChatModel {
    static let inputLimit = 6_000
    var draft = ""
    private(set) var messages: [ChatMessage] = []
    private(set) var action: AIAction = .chat
    private(set) var availability: AIAvailability
    private(set) var isGenerating = false
    private(set) var isCancelling = false
    private(set) var errorMessage: String?
    private(set) var conversationID = UUID()
    private(set) var sourcePassage: String?
    private var acceptedRevisions: [String] = []
    private var failedAttempt: Attempt?
    private var draftRevisesOriginalPassage = false
    @ObservationIgnored private let engine: any AIEngine
    @ObservationIgnored private var generationTask: Task<Void, Never>?

    private struct Attempt {
        let request: AIRequest
        let responseID: UUID
    }

    init(engine: any AIEngine = FoundationModelEngine()) {
        self.engine = engine
        availability = engine.availability
    }

    var canSend: Bool {
        availability.isAvailable && !isGenerating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.count <= Self.inputLimit
    }

    var latestCompletedResponse: String? {
        messages.last { $0.role == .assistant && !$0.isPartial }?.text
    }

    var hasWritingContext: Bool {
        action != .chat && sourcePassage != nil && (latestCompletedResponse != nil || draftRevisesOriginalPassage)
    }

    var canRetry: Bool {
        availability.isAvailable && !isGenerating && failedAttempt != nil
            && (draft.isEmpty || draft == failedAttempt?.request.prompt)
    }

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
        sourcePassage = nil
        acceptedRevisions = []
        failedAttempt = nil
        draftRevisesOriginalPassage = false
        conversationID = UUID()
        if let action { self.action = action }
    }

    /// Imports an explicit new passage without turning it into a follow-up or
    /// discarding the current conversation if the passage cannot be accepted.
    @discardableResult
    func startWriting(_ text: String) -> Bool {
        guard !isGenerating else { return false }
        guard text.count <= Self.inputLimit else {
            useText(text)
            return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        newConversation()
        useText(text)
        return true
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

    func send() {
        refreshAvailability()
        guard canSend else { return }
        // Writing operations need the exact passage, including surrounding layout.
        // canSend already rejects whitespace-only drafts without modifying them.
        let prompt = action == .chat ? draft.trimmingCharacters(in: .whitespacesAndNewlines) : draft
        if let attempt = failedAttempt, attempt.request.prompt == prompt {
            generate(attempt.request, reusing: attempt.responseID)
            return
        }
        var request = AIRequest(prompt: prompt)
        if action != .chat {
            if let sourcePassage,
                let result = latestCompletedResponse ?? (draftRevisesOriginalPassage ? sourcePassage : nil)
            {
                request.writingContext = AIWritingContext(
                    originalPassage: sourcePassage, currentResult: result, acceptedRevisions: acceptedRevisions)
            } else {
                sourcePassage = prompt
                acceptedRevisions = []
            }
        }
        generate(request)
    }

    func retry() {
        refreshAvailability()
        guard canRetry, let attempt = failedAttempt else { return }
        generate(attempt.request, reusing: attempt.responseID)
    }

    private func generate(_ request: AIRequest, reusing responseID: UUID? = nil) {
        draft = ""
        errorMessage = nil
        failedAttempt = nil
        draftRevisesOriginalPassage = false
        isGenerating = true
        isCancelling = false
        if let responseID {
            messages.removeAll { $0.id == responseID }
        } else {
            messages.append(ChatMessage(role: .user, text: request.prompt))
        }
        let response = ChatMessage(id: responseID ?? UUID(), role: .assistant, text: "", isPartial: true)
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
                try await self.engine.stream(request, action: action) { [weak self] content in
                    guard let self, let index = self.messages.firstIndex(where: { $0.id == response.id }) else {
                        return
                    }
                    self.messages[index].text = content
                }
                try Task.checkCancellation()
                if let index = self.messages.firstIndex(where: { $0.id == response.id }) {
                    if self.messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.messages.remove(at: index)
                        self.engine.reset()
                        self.recover(request, responseID: response.id)
                        self.errorMessage = "The model returned an empty response. Retry or edit your request."
                    } else {
                        self.messages[index].isPartial = false
                        if request.isRevision { self.acceptedRevisions.append(request.prompt) }
                    }
                }
            } catch {
                self.engine.reset()
                self.recover(request, responseID: response.id)
                if self.isCancelling || error is CancellationError {
                    self.errorMessage =
                        action == .chat
                        ? "Response stopped. Your request is saved. Retry or edit it to continue in a fresh model session."
                        : "Response stopped. Your passage and earlier revisions are saved. Retry or edit your request."
                } else {
                    self.errorMessage =
                        action != .chat && error as? AIServiceError == .contextFull
                        ? "This revision reached the model’s context limit. Your passage and revisions are saved. Shorten your request, or start a new passage from the latest result."
                        : error.localizedDescription
                }
                self.messages.removeAll { $0.id == response.id && $0.text.isEmpty }
                // Incomplete responses keep their explicit “Stopped” label.
                self.refreshAvailability()
            }
        }
    }

    private func recover(_ request: AIRequest, responseID: UUID) {
        failedAttempt = Attempt(request: request, responseID: responseID)
        // A draft typed during the first response is already a follow-up. If
        // that response fails, revise the original passage instead of mistaking
        // the follow-up instruction for a new source. Editing a restored initial
        // request still edits the source, while editing a failed revision keeps
        // its original context even if no response has completed yet.
        draftRevisesOriginalPassage = action != .chat && (request.isRevision || !draft.isEmpty)
        // Users may already be drafting the next request while generation runs.
        if draft.isEmpty { draft = request.prompt }
    }

    func cancel() {
        guard isGenerating else { return }
        isCancelling = true
        generationTask?.cancel()
    }

    func waitForResponse() async { await generationTask?.value }
}
