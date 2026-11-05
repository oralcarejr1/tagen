import Foundation

public enum VoiceState: Sendable, Equatable {
    case idle
    case listening(partial: String)
    case transcribing(partial: String)   // key released, waiting for the final result
    case thinking(transcript: String)
    case speaking(text: String)
    case error(String)

    public var isBusy: Bool { if case .idle = self { return false }; if case .error = self { return false }; return true }
}

public enum VoiceEvent: Sendable, Equatable {
    case talkPressed
    case talkReleased
    case partialTranscript(String)
    case finalTranscript(String)
    case recognitionFailed(String)
    case responseCompleted(String)
    case responseFailed(String)
    case speechFinished
    case cancel                 // Esc / cancel button / emergency stop
    case finalizeTimeout        // final transcript did not arrive in time
}

public enum VoiceEffect: Sendable, Equatable {
    case startRecognition
    case stopRecognition        // stop audio, wait for final result
    case cancelRecognition      // discard
    case submit(String)
    case cancelRequest
    case speak(String)
    case stopSpeaking
    case showError(String)
    case startFinalizeTimer
}

/// Pure push-to-talk state machine. Effects are executed by `VoiceController`.
///
/// Interruption: pressing the talk key while thinking or speaking cancels the in-flight
/// request / stops speech and starts listening again.
public enum VoiceStateMachine {
    public static func reduce(_ state: VoiceState, _ event: VoiceEvent, speakResponses: Bool = true) -> (VoiceState, [VoiceEffect]) {
        switch (state, event) {
        // Start listening
        case (.idle, .talkPressed), (.error, .talkPressed):
            return (.listening(partial: ""), [.startRecognition])
        case (.thinking, .talkPressed):
            return (.listening(partial: ""), [.cancelRequest, .startRecognition])
        case (.speaking, .talkPressed):
            return (.listening(partial: ""), [.stopSpeaking, .startRecognition])
        case (.transcribing, .talkPressed):
            return (.listening(partial: ""), [.cancelRecognition, .startRecognition])

        // Partial results
        case (.listening, .partialTranscript(let t)):
            return (.listening(partial: t), [])
        case (.transcribing, .partialTranscript(let t)):
            return (.transcribing(partial: t), [])

        // Release
        case (.listening(let p), .talkReleased):
            return (.transcribing(partial: p), [.stopRecognition, .startFinalizeTimer])

        // Final transcript (may arrive before or after release)
        case (.transcribing, .finalTranscript(let t)), (.listening, .finalTranscript(let t)):
            let text = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return (.idle, state == .listening(partial: "") ? [] : [.cancelRecognition]) }
            var effects: [VoiceEffect] = []
            if case .listening = state { effects.append(.stopRecognition) }
            effects.append(.submit(text))
            return (.thinking(transcript: text), effects)
        case (.transcribing(let p), .finalizeTimeout):
            let text = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return (.idle, [.cancelRecognition]) }
            return (.thinking(transcript: text), [.cancelRecognition, .submit(text)])

        // Recognition errors
        case (.listening, .recognitionFailed(let m)), (.transcribing, .recognitionFailed(let m)):
            return (.error(m), [.cancelRecognition, .showError(m)])

        // Responses
        case (.thinking, .responseCompleted(let text)):
            if speakResponses && !text.isEmpty { return (.speaking(text: text), [.speak(text)]) }
            return (.idle, [])
        case (.thinking, .responseFailed(let m)):
            return (.error(m), [.showError(m)])
        case (.speaking, .speechFinished):
            return (.idle, [])

        // Cancel from anywhere
        case (.listening, .cancel), (.transcribing, .cancel):
            return (.idle, [.cancelRecognition])
        case (.thinking, .cancel):
            return (.idle, [.cancelRequest])
        case (.speaking, .cancel):
            return (.idle, [.stopSpeaking])
        case (.error, .cancel):
            return (.idle, [])

        default:
            // Stale events (e.g. late partials after cancel) are ignored.
            return (state, [])
        }
    }
}

public struct TranscriptionUpdate: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
    public init(text: String, isFinal: Bool) { self.text = text; self.isFinal = isFinal }
}

public enum SpeechRecognitionError: Error, Sendable, Equatable, CustomStringConvertible {
    case notAuthorized
    case microphoneUnavailable
    case languageUnavailable(String)
    case recognizerUnavailable
    case failed(String)
    public var description: String {
        switch self {
        case .notAuthorized: return "Speech recognition or microphone permission is not granted."
        case .microphoneUnavailable: return "No microphone is available."
        case .languageUnavailable(let l): return "Speech recognition is not available for \(l)."
        case .recognizerUnavailable: return "Speech recognizer is currently unavailable."
        case .failed(let m): return "Speech recognition failed: \(m)"
        }
    }
}

/// OS boundary: speech-to-text. `start` begins capturing audio; updates stream until
/// `finish()` (key released → final result) or `cancel()`.
public protocol SpeechRecognizer: Sendable {
    func start(language: LanguageCode, preferOnDevice: Bool) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error>
    func finish() async
    func cancel() async
    func supportsOnDevice(language: LanguageCode) async -> Bool
}

/// OS boundary: text-to-speech. `speak` returns when speech finishes or is stopped.
public protocol SpeechSynthesizer: Sendable {
    func speak(_ text: String, language: LanguageCode) async
    func stop() async
}

public struct VoiceSettings: Sendable, Codable, Equatable {
    public var recognitionLanguage: LanguageCode = .korean
    public var preferOnDevice: Bool = true
    public var speakResponses: Bool = true
    public var finalizeTimeout: Double = 2.5
    public var maxSpokenCharacters: Int = 600
    public init() {}
}
