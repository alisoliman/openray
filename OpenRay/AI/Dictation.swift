import AVFoundation
import Foundation
import Speech

/// Dictation into the chat composer (⌃M), transcribed on this Mac. Opt-in.
@MainActor
protocol AIDictating: AnyObject {
    /// Nil when dictation can start; otherwise why it can't.
    var unavailableReason: String? { get }
    var isListening: Bool { get }
    /// Starts listening. `onText` receives the whole transcript so far, each time it changes.
    func start(onText: @escaping @MainActor (String) -> Void) async throws
    func stop()
}

/// Never listens, for tests and verification.
@MainActor
final class InertDictation: AIDictating {
    var unavailableReason: String? { "Dictation is off here." }
    var isListening: Bool { false }
    func start(onText: @escaping @MainActor (String) -> Void) async throws {
        throw AIServiceError.failed("Dictation is off here.")
    }
    func stop() {}
}

/// The Speech framework's on-device recognizer over the microphone. macOS needs the app's
/// microphone and speech usage descriptions before it may ask; without them in Info.plist
/// it says so, and never prompts or crashes.
@MainActor
final class SpeechDictation: AIDictating {
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var isListening = false
    private let sideEffects: SideEffectGuard

    init(sideEffects: SideEffectGuard = .current) {
        self.sideEffects = sideEffects
    }

    var unavailableReason: String? {
        if sideEffects.isInert { return "Dictation is off here." }
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["NSMicrophoneUsageDescription"] != nil, info["NSSpeechRecognitionUsageDescription"] != nil else {
            return "This build of OpenRay can't use the microphone yet."
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition else {
            return "On-device dictation isn't available for your language."
        }
        return nil
    }

    func start(onText: @escaping @MainActor (String) -> Void) async throws {
        try sideEffects.check("listening to the microphone")
        if let reason = unavailableReason { throw AIServiceError.failed(reason) }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized, let recognizer = SFSpeechRecognizer() else {
            throw AIServiceError.failed("Allow Speech Recognition for OpenRay in System Settings › Privacy & Security.")
        }
        stop()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        let input = audio.inputNode
        // The throwing replacement for the tap API deprecated in macOS 27; `error: ()` marks
        // where the Objective-C error pointer was.
        try input.__installTap(
            onBus: 0, bufferSize: 1_024, format: input.outputFormat(forBus: 0), error: (),
            block: Self.tap(feeding: request))
        audio.prepare()
        try audio.start()
        isListening = true
        task = recognizer.recognitionTask(with: request, resultHandler: Self.handler(onText: onText, owner: self))
    }

    /// Built outside the main actor: the audio thread calls it.
    nonisolated private static func tap(feeding request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in request.append(buffer) }
    }

    /// Built outside the main actor: Speech calls it on its own queue, and it hops back.
    nonisolated private static func handler(
        onText: @escaping @MainActor (String) -> Void, owner: SpeechDictation
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let finished = error != nil || result?.isFinal == true
            Task { @MainActor in
                if let text { onText(text) }
                if finished { owner?.stop() }
            }
        }
    }

    func stop() {
        guard isListening || task != nil else { return }
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
    }
}
