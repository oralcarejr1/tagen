#if os(macOS)
import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech
import TagenCore

/// SFSpeechRecognizer + AVAudioEngine push-to-talk recognizer. Audio is streamed to the
/// recognizer only while the talk key is held and is never written to disk.
public final class MacSpeechRecognizer: SpeechRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    public init() {}

    public func supportsOnDevice(language: LanguageCode) async -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: language.localeIdentifier))?.supportsOnDeviceRecognition ?? false
    }

    public func start(language: LanguageCode, preferOnDevice: Bool) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw SpeechRecognitionError.notAuthorized }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: language.localeIdentifier)) else {
            throw SpeechRecognitionError.languageUnavailable(language.localeIdentifier)
        }
        guard rec.isAvailable else { throw SpeechRecognitionError.recognizerUnavailable }
        await cancel()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if preferOnDevice && rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.taskHint = .dictation
        if #available(macOS 13, *) { req.addsPunctuation = true }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw SpeechRecognitionError.microphoneUnavailable }

        let (stream, continuation) = AsyncThrowingStream<TranscriptionUpdate, Error>.makeStream()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in req?.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw SpeechRecognitionError.failed("audio engine: \(error.localizedDescription)")
        }
        let t = rec.recognitionTask(with: req) { result, error in
            if let r = result {
                continuation.yield(TranscriptionUpdate(text: r.bestTranscription.formattedString, isFinal: r.isFinal))
                if r.isFinal { continuation.finish() }
            } else if let e = error as NSError? {
                // 1110 = "no speech detected": finish quietly with an empty final result.
                if e.code == 1110 || e.code == 301 { continuation.yield(TranscriptionUpdate(text: "", isFinal: true)); continuation.finish() }
                else { continuation.finish(throwing: SpeechRecognitionError.failed(e.localizedDescription)) }
            }
        }
        lock.withLock { self.engine = engine; self.request = req; self.task = t; self.recognizer = rec }
        continuation.onTermination = { [weak self] _ in self?.stopAudio() }
        return stream
    }

    private func stopAudio() {
        let e: AVAudioEngine? = lock.withLock { let e = engine; engine = nil; return e }
        if let e { e.inputNode.removeTap(onBus: 0); e.stop() }
    }

    public func finish() async {
        stopAudio()
        let r = lock.withLock { request }
        r?.endAudio()
    }

    public func cancel() async {
        stopAudio()
        let t: SFSpeechRecognitionTask? = lock.withLock { let t = task; task = nil; request = nil; return t }
        t?.cancel()
    }
}

/// AVSpeechSynthesizer-based TTS with Korean/English voices; interruptible.
public final class MacSpeechSynthesizer: NSObject, SpeechSynthesizer, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    public override init() {
        super.init()
        synth.delegate = self
    }

    public func speak(_ text: String, language: LanguageCode) async {
        await stop()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.withLock { continuation = c }
                let u = AVSpeechUtterance(string: text)
                u.voice = AVSpeechSynthesisVoice(language: language.localeIdentifier)
                u.rate = rate
                synth.speak(u)
            }
        } onCancel: { [weak self] in
            self?.synth.stopSpeaking(at: .immediate)
            self?.resume()
        }
    }

    public func stop() async {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        resume()
    }

    private func resume() {
        let c: CheckedContinuation<Void, Never>? = lock.withLock { let c = continuation; continuation = nil; return c }
        c?.resume()
    }

    public func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { resume() }
    public func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { resume() }
}
#endif
