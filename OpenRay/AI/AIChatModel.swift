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
    @ObservationIgnored private let engine: any AIEngine
    @ObservationIgnored private var generationTask: Task<Void, Never>?

    init(engine: any AIEngine = FoundationModelEngine()) {
        self.engine = engine
        availability = engine.availability
    }

    var canSend: Bool {
        availability.isAvailable && !isGenerating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.count <= Self.inputLimit
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

    func send() {
        refreshAvailability()
        guard canSend else { return }
        // Writing operations need the exact passage, including surrounding layout.
        // canSend already rejects whitespace-only drafts without modifying them.
        let prompt = action == .chat ? draft.trimmingCharacters(in: .whitespacesAndNewlines) : draft
        draft = ""
        errorMessage = nil
        isGenerating = true
        isCancelling = false
        messages.append(ChatMessage(role: .user, text: prompt))
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
                try await self.engine.stream(prompt, action: action) { [weak self] content in
                    guard let self, let index = self.messages.firstIndex(where: { $0.id == response.id }) else {
                        return
                    }
                    self.messages[index].text = content
                }
                if let index = self.messages.firstIndex(where: { $0.id == response.id }) {
                    self.messages[index].isPartial = false
                    if self.messages[index].text.isEmpty {
                        self.messages.remove(at: index)
                        self.errorMessage = "The model returned an empty response. Try a more specific request."
                    }
                }
            } catch {
                self.engine.reset()
                if self.isCancelling || error is CancellationError {
                    self.errorMessage = "Response stopped. The next message starts a fresh session."
                } else {
                    self.errorMessage = error.localizedDescription
                }
                self.messages.removeAll { $0.id == response.id && $0.text.isEmpty }
                // Incomplete responses keep their explicit “Stopped” label.
                self.refreshAvailability()
            }
        }
    }

    func cancel() {
        guard isGenerating else { return }
        isCancelling = true
        generationTask?.cancel()
    }

    func waitForResponse() async { await generationTask?.value }
}
