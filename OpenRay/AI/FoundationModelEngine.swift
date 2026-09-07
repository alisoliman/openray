import Foundation
import FoundationModels

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
            // Proofreading and extraction should preserve source facts without creative variation.
            let options =
                switch action {
                case .proofread, .actionItems: GenerationOptions(sampling: .greedy, maximumResponseTokens: 900)
                default: GenerationOptions(temperature: 0.4, maximumResponseTokens: 900)
                }
            let stream = session.streamResponse(
                to: Prompt(prompt), options: options)
            for try await snapshot in stream {
                try Task.checkCancellation()
                onSnapshot(snapshot.content)
            }
            try Task.checkCancellation()
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
