import Foundation

/// Drives the push-to-talk state machine against real (or test) recognizer/synthesizer.
public actor VoiceController {
    public private(set) var state: VoiceState = .idle
    public var settings: VoiceSettings
    let recognizer: SpeechRecognizer
    let synthesizer: SpeechSynthesizer
    /// Called with the final transcript; returns the assistant's answer text.
    let submitHandler: @Sendable (String, LanguageCode) async throws -> String
    let onStateChange: @Sendable (VoiceState) -> Void
    private var recognitionTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?
    private var session = 0   // increments on every new listen; stale callbacks are dropped
    public private(set) var transitions: [(VoiceState, VoiceEvent, VoiceState)] = []

    public init(settings: VoiceSettings, recognizer: SpeechRecognizer, synthesizer: SpeechSynthesizer,
                submit: @escaping @Sendable (String, LanguageCode) async throws -> String,
                onStateChange: @escaping @Sendable (VoiceState) -> Void = { _ in }) {
        self.settings = settings; self.recognizer = recognizer; self.synthesizer = synthesizer
        self.submitHandler = submit; self.onStateChange = onStateChange
    }

    public func updateSettings(_ s: VoiceSettings) { settings = s }

    public func send(_ event: VoiceEvent) async {
        let (next, effects) = VoiceStateMachine.reduce(state, event, speakResponses: settings.speakResponses)
        transitions.append((state, event, next))
        state = next
        onStateChange(next)
        for e in effects { await run(e) }
    }

    /// Typed text fallback: skips recognition entirely.
    public func submitText(_ text: String) async {
        if state.isBusy { await send(.cancel) }
        state = .thinking(transcript: text)
        onStateChange(state)
        await run(.submit(text))
    }

    private func run(_ effect: VoiceEffect) async {
        switch effect {
        case .startRecognition:
            session += 1
            let mySession = session
            let lang = settings.recognitionLanguage
            let onDevice = settings.preferOnDevice
            recognitionTask?.cancel()
            recognitionTask = Task {
                do {
                    let stream = try await recognizer.start(language: lang, preferOnDevice: onDevice)
                    for try await u in stream {
                        guard self.isCurrent(mySession) else { return }
                        await self.send(u.isFinal ? .finalTranscript(u.text) : .partialTranscript(u.text))
                        if u.isFinal { return }
                    }
                    // Stream ended without a final result: treat last partial as final.
                    if self.isCurrent(mySession) { await self.send(.finalizeTimeout) }
                } catch is CancellationError {
                } catch {
                    if self.isCurrent(mySession) { await self.send(.recognitionFailed(String(describing: error))) }
                }
            }
        case .stopRecognition:
            await recognizer.finish()
        case .cancelRecognition:
            session += 1
            recognitionTask?.cancel(); recognitionTask = nil
            finalizeTask?.cancel(); finalizeTask = nil
            await recognizer.cancel()
        case .startFinalizeTimer:
            let mySession = session
            let t = settings.finalizeTimeout
            finalizeTask?.cancel()
            finalizeTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000))
                guard !Task.isCancelled, self.isCurrent(mySession) else { return }
                await self.send(.finalizeTimeout)
            }
        case .submit(let text):
            finalizeTask?.cancel(); finalizeTask = nil
            let lang = LanguageDetector.detect(text, fallback: settings.recognitionLanguage)
            requestTask?.cancel()
            let handler = submitHandler
            requestTask = Task {
                do {
                    let answer = try await handler(text, lang)
                    guard !Task.isCancelled else { return }
                    await self.send(.responseCompleted(answer))
                } catch {
                    guard !Task.isCancelled else { return }
                    await self.send(.responseFailed(String(describing: error)))
                }
            }
        case .cancelRequest:
            requestTask?.cancel(); requestTask = nil
        case .speak(let text):
            let spoken = Self.speakable(text, limit: settings.maxSpokenCharacters)
            let lang = LanguageDetector.detect(spoken, fallback: settings.recognitionLanguage)
            speakTask?.cancel()
            let synth = synthesizer
            speakTask = Task {
                await synth.speak(spoken, language: lang)
                guard !Task.isCancelled else { return }
                await self.send(.speechFinished)
            }
        case .stopSpeaking:
            speakTask?.cancel(); speakTask = nil
            await synthesizer.stop()
        case .showError:
            break   // UI observes state; nothing to do here
        }
    }

    private func isCurrent(_ s: Int) -> Bool { s == session }

    /// Strip markdown/code so TTS reads naturally, and cap length.
    public static func speakable(_ text: String, limit: Int) -> String {
        var t = text
        if let r = try? NSRegularExpression(pattern: "```[\\s\\S]*?```") {
            t = r.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " (code omitted) ")
        }
        t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "#", with: "")
        t = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-*•")) }.joined(separator: " ")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > limit {
            let cut = t.prefix(limit)
            if let end = cut.lastIndex(where: { ".!?。".contains($0) }) { t = String(cut[...end]) } else { t = String(cut) + "…" }
        }
        return t
    }
}
