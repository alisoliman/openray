import Foundation
import FoundationModels

@Generable
struct AIWritingResult {
    @Guide(
        description: "The complete transformed passage only, without a preface, explanation, or conversational reply.")
    var text: String
}

@Generable
struct AIProofreadingResult {
    // Text only. A separate "needs corrections" flag generated before the text was
    // unreliable on the on-device model: it was false for most passages with real
    // mistakes, which hid every correction. Whether anything changed is decided by
    // comparing the corrected text with the original instead.
    @Guide(
        description:
            "The full passage with only its spelling, grammar, and punctuation mistakes corrected. Identical to the original when it has no mistakes."
    )
    var text: String

    static func preservingUnchangedPassage(_ text: String, original: String) -> String {
        // Guided generation can normalize whitespace even when every word and
        // punctuation mark is unchanged. Keep the user's exact layout in that case.
        text.split(whereSeparator: \.isWhitespace) == original.split(whereSeparator: \.isWhitespace)
            ? original : text
    }
}

@Generable
struct AIActionItems {
    // The element is nested so the generation schema calls it “Item”. Evaluated on the
    // on-device model, a longer, prefixed element name made it drop items it otherwise kept.
    @Generable
    struct Item: Equatable, Sendable {
        @Guide(
            description:
                "One concrete action, starting with a verb, with no bullet marker. Leave out the owner and the deadline; they have their own fields."
        )
        var task: String
        @Guide(
            description:
                "The person or team the passage explicitly names as responsible, exactly as written. Nil when the passage doesn't name one."
        )
        var owner: String?
        @Guide(
            description:
                "The deadline exactly as the passage states it, such as 'tomorrow' or 'by Friday'. Nil when no deadline is stated."
        )
        var due: String?
    }

    @Guide(
        description:
            "Whether the passage contains any pending work, request, or commitment. False for descriptions, background facts, and completed activities."
    )
    var hasActionItems: Bool
    @Guide(description: "One item per task or commitment. Empty when no tasks or commitments are present.")
    var items: [Item]

    /// Readable Markdown for Copy, Paste and Save as Note, such as “- Lee: Book the room (due tomorrow)”.
    /// The checklist renders from the fields, so this text is never parsed back.
    static func formatted(_ items: [AIActionItem]) -> String {
        let items = cleaned(items)
        guard !items.isEmpty else { return "No action items found." }
        return items.map { item in
            let owner = item.owner.map { "\($0): " } ?? ""
            let task = item.due != nil && item.task.hasSuffix(".") ? String(item.task.dropLast()) : item.task
            let due = item.due.map { " (due \($0))" } ?? ""
            return "- \(owner)\(task)\(due)"
        }
        .joined(separator: "\n")
    }

    /// Collapses whitespace, drops items without a task, and treats blank or placeholder
    /// owners and dates as unstated.
    static func cleaned(_ items: [AIActionItem]) -> [AIActionItem] {
        func clean(_ text: String?) -> String? {
            guard let text else { return nil }
            let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return collapsed.isEmpty ? nil : collapsed
        }
        func stated(_ text: String?) -> String? {
            clean(text).flatMap { ["none", "null", "nil", "n/a", "unknown", "unassigned", "tbd"].contains($0.lowercased()) ? nil : $0 }
        }
        return items.compactMap { item in
            clean(item.task).map { AIActionItem(task: $0, owner: stated(item.owner), due: stated(item.due)) }
        }
    }
}

typealias AIActionItem = AIActionItems.Item

@MainActor
final class FoundationModelEngine: AIEngine {
    private var session: LanguageModelSession?
    private var sessionAction: AIAction?

    var availability: AIAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale() ? .available : .unsupportedLocale
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .deviceNotEligible: return .notEligible
            case .modelNotReady: return .preparing
            @unknown default: return .unavailable
            }
        }
    }

    func prepare(for action: AIAction) {
        guard availability.isAvailable else { return }
        if session == nil || sessionAction != action {
            session = LanguageModelSession(instructions: action.instructions)
            sessionAction = action
            session?.prewarm()
        }
    }

    func reset() {
        session = nil
        sessionAction = nil
    }

    /// Rebuilds the chat session from its transcript up to, not including, the latest prompt.
    /// The instructions entry is kept.
    func discardLastExchange() {
        guard let session, sessionAction == .chat else {
            reset()
            return
        }
        let entries = Array(session.transcript)
        guard let index = entries.lastIndex(where: { if case .prompt = $0 { true } else { false } }) else { return }
        self.session = LanguageModelSession(transcript: Transcript(entries: entries[..<index]))
    }

    func stream(_ prompt: String, action: AIAction, onSnapshot: @escaping @MainActor (String) -> Void) async throws {
        try await stream(prompt, action: action, instruction: "") { onSnapshot($0.text) }
    }

    func stream(
        _ prompt: String, action: AIAction, instruction: String,
        onSnapshot: @escaping @MainActor (AIResponseSnapshot) -> Void
    ) async throws {
        guard availability.isAvailable else { throw AIServiceError.unavailable(availability) }
        if session == nil || sessionAction != action {
            session = LanguageModelSession(instructions: action.instructions)
            sessionAction = action
        }
        guard let session else { throw AIServiceError.unavailable(.unavailable) }
        do {
            let request = Prompt(action.prompt(for: prompt, instruction: instruction))
            switch action {
            case .chat:
                let stream = session.streamResponse(
                    to: request, options: GenerationOptions(temperature: 0.4, maximumResponseTokens: 900))
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    onSnapshot(AIResponseSnapshot(text: snapshot.content))
                }
            case .proofread:
                let stream = session.streamResponse(
                    to: request, generating: AIProofreadingResult.self,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 1_500))
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    if let text = snapshot.content.text {
                        onSnapshot(
                            AIResponseSnapshot(text: AIProofreadingResult.preservingUnchangedPassage(text, original: prompt)))
                    }
                }
            case .actionItems:
                let stream = session.streamResponse(
                    to: request, generating: AIActionItems.self,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 900))
                var finalItems: [AIActionItem] = []
                func send(_ items: [AIActionItem]) {
                    onSnapshot(AIResponseSnapshot(text: AIActionItems.formatted(items), actionItems: items))
                }
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    if snapshot.content.hasActionItems == true, let items = snapshot.content.items {
                        // An item streams in before its task does; skip it until the task arrives.
                        finalItems = AIActionItems.cleaned(
                            items.compactMap { item in
                                item.task.map { AIActionItem(task: $0, owner: item.owner, due: item.due) }
                            })
                        if !finalItems.isEmpty { send(finalItems) }
                    }
                }
                send(finalItems)
            default:
                let stream = session.streamResponse(
                    to: request, generating: AIWritingResult.self,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 1_500))
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    if let text = snapshot.content.text { onSnapshot(AIResponseSnapshot(text: text)) }
                }
            }
            try Task.checkCancellation()
            // Writing commands transform each passage independently. Only chat
            // carries conversational context into the next request.
            if action != .chat { reset() }
        } catch is CancellationError {
            reset()
            throw CancellationError()
        } catch let error as LanguageModelError {
            // macOS 27 throws LanguageModelError; the older GenerationError is no longer raised.
            reset()
            switch error {
            case .contextSizeExceeded: throw AIServiceError.contextFull
            case .guardrailViolation, .refusal: throw AIServiceError.guardrail
            case .unsupportedLanguageOrLocale: throw AIServiceError.unsupportedLanguage
            case .rateLimited, .timeout: throw AIServiceError.busy
            default: throw AIServiceError.failed(error.localizedDescription)
            }
        } catch LanguageModelSession.Error.concurrentRequests {
            reset()
            throw AIServiceError.busy
        } catch let error as SystemLanguageModel.Error {
            reset()
            if case .assetsUnavailable = error { throw AIServiceError.unavailable(.preparing) }
            throw AIServiceError.failed(error.localizedDescription)
        } catch {
            reset()
            throw AIServiceError.failed(error.localizedDescription)
        }
    }
}
