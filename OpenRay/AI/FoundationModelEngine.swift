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
    @Guide(
        description:
            "Whether the original passage contains a spelling, grammar, or punctuation error. False for already-correct text, including questions and requests."
    )
    var needsCorrections: Bool
    @Guide(
        description:
            "The corrected passage only. Preserve names, meaning, and paragraph breaks. Use an empty string when no corrections are needed."
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
struct AIActionItemsResult {
    @Guide(
        description:
            "Whether the passage contains any pending work, request, or commitment. False for descriptions, background facts, and completed activities."
    )
    var hasActionItems: Bool
    @Guide(
        description:
            "One concrete task per item, with no bullet marker. Include only explicitly stated owners and deadlines. Empty when no tasks or commitments are present."
    )
    var items: [String]

    static func formatted(_ items: [String]) -> String {
        let items = items.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return items.isEmpty ? "No action items found." : items.map { "- " + $0 }.joined(separator: "\n")
    }
}

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

    func stream(_ prompt: String, action: AIAction, onSnapshot: @escaping @MainActor (String) -> Void) async throws {
        guard availability.isAvailable else { throw AIServiceError.unavailable(availability) }
        if session == nil || sessionAction != action {
            session = LanguageModelSession(instructions: action.instructions)
            sessionAction = action
        }
        guard let session else { throw AIServiceError.unavailable(.unavailable) }
        do {
            let request = Prompt(action.prompt(for: prompt))
            switch action {
            case .chat:
                let stream = session.streamResponse(
                    to: request, options: GenerationOptions(temperature: 0.4, maximumResponseTokens: 900))
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    onSnapshot(snapshot.content)
                }
            case .proofread:
                let stream = session.streamResponse(
                    to: request, generating: AIProofreadingResult.self,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 1_500))
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    if snapshot.content.needsCorrections == false {
                        onSnapshot(prompt)
                    } else if let text = snapshot.content.text {
                        onSnapshot(AIProofreadingResult.preservingUnchangedPassage(text, original: prompt))
                    }
                }
            case .actionItems:
                let stream = session.streamResponse(
                    to: request, generating: AIActionItemsResult.self,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 900))
                var finalItems: [String] = []
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    if snapshot.content.hasActionItems == true, let items = snapshot.content.items {
                        finalItems = items
                        if !items.isEmpty { onSnapshot(AIActionItemsResult.formatted(items)) }
                    }
                }
                onSnapshot(AIActionItemsResult.formatted(finalItems))
            default:
                let stream = session.streamResponse(
                    to: request, generating: AIWritingResult.self,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 1_500))
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    if let text = snapshot.content.text { onSnapshot(text) }
                }
            }
            try Task.checkCancellation()
            // Writing commands transform each passage independently. Only chat
            // carries conversational context into the next request.
            if action != .chat { reset() }
        } catch is CancellationError {
            reset()
            throw CancellationError()
        } catch let error as LanguageModelSession.GenerationError {
            reset()
            switch error {
            case .exceededContextWindowSize: throw AIServiceError.contextFull
            case .guardrailViolation, .refusal: throw AIServiceError.guardrail
            case .unsupportedLanguageOrLocale: throw AIServiceError.unsupportedLanguage
            case .concurrentRequests, .rateLimited: throw AIServiceError.busy
            default: throw AIServiceError.failed(error.localizedDescription)
            }
        } catch {
            reset()
            throw AIServiceError.failed(error.localizedDescription)
        }
    }
}
