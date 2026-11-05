import XCTest
@testable import TagenCore

final class VoiceStateMachineTests: XCTestCase {
    func run(_ events: [VoiceEvent], speak: Bool = true) -> (VoiceState, [[VoiceEffect]]) {
        var s = VoiceState.idle
        var effects: [[VoiceEffect]] = []
        for e in events { let (n, ef) = VoiceStateMachine.reduce(s, e, speakResponses: speak); s = n; effects.append(ef) }
        return (s, effects)
    }

    func testHappyPathWithPartials() {
        let (s, ef) = run([.talkPressed, .partialTranscript("안녕"), .partialTranscript("안녕하세요"), .talkReleased,
                           .finalTranscript("안녕하세요 오늘 날씨"), .responseCompleted("맑습니다."), .speechFinished])
        XCTAssertEqual(s, .idle)
        XCTAssertEqual(ef[0], [.startRecognition])
        XCTAssertEqual(ef[3], [.stopRecognition, .startFinalizeTimer])
        XCTAssertEqual(ef[4], [.submit("안녕하세요 오늘 날씨")])
        XCTAssertEqual(ef[5], [.speak("맑습니다.")])
    }

    func testInterruptWhileSpeakingAndThinking() {
        var (s, ef) = run([.talkPressed, .talkReleased, .finalTranscript("hello"), .responseCompleted("long answer"), .talkPressed])
        XCTAssertEqual(s, .listening(partial: "")); XCTAssertEqual(ef.last, [.stopSpeaking, .startRecognition])
        (s, ef) = run([.talkPressed, .talkReleased, .finalTranscript("hello"), .talkPressed])
        XCTAssertEqual(ef.last, [.cancelRequest, .startRecognition])
    }

    func testCancelFromEveryState() {
        XCTAssertEqual(VoiceStateMachine.reduce(.listening(partial: "x"), .cancel).1, [.cancelRecognition])
        XCTAssertEqual(VoiceStateMachine.reduce(.transcribing(partial: "x"), .cancel).1, [.cancelRecognition])
        XCTAssertEqual(VoiceStateMachine.reduce(.thinking(transcript: "x"), .cancel).1, [.cancelRequest])
        XCTAssertEqual(VoiceStateMachine.reduce(.speaking(text: "x"), .cancel).1, [.stopSpeaking])
        XCTAssertEqual(VoiceStateMachine.reduce(.idle, .cancel).0, .idle)
    }

    func testErrorsTimeoutsAndStaleEvents() {
        XCTAssertEqual(VoiceStateMachine.reduce(.listening(partial: ""), .recognitionFailed("no mic")).0, .error("no mic"))
        XCTAssertEqual(VoiceStateMachine.reduce(.transcribing(partial: "partial words"), .finalizeTimeout).1, [.cancelRecognition, .submit("partial words")])
        XCTAssertEqual(VoiceStateMachine.reduce(.transcribing(partial: ""), .finalizeTimeout).0, .idle)
        XCTAssertEqual(VoiceStateMachine.reduce(.transcribing(partial: ""), .finalTranscript("  ")).0, .idle)
        XCTAssertEqual(VoiceStateMachine.reduce(.idle, .partialTranscript("late")).0, .idle, "late partial ignored")
        XCTAssertEqual(VoiceStateMachine.reduce(.error("x"), .talkPressed).0, .listening(partial: ""))
        XCTAssertEqual(VoiceStateMachine.reduce(.thinking(transcript: "q"), .responseCompleted("a"), speakResponses: false).0, .idle)
        XCTAssertEqual(VoiceStateMachine.reduce(.thinking(transcript: "q"), .responseFailed("net")).0, .error("net"))
    }
}

/// Controlled transcript fixture standing in for live audio (no microphone in CI).
final class FixtureRecognizer: SpeechRecognizer, @unchecked Sendable {
    let script: [TranscriptionUpdate]
    let failWith: Error?
    let gapNanos: UInt64
    let waitForFinish: Bool
    let finished = Locked(false)
    let cancelled = Locked(0)
    let languages = Locked<[LanguageCode]>([])
    init(_ script: [TranscriptionUpdate], failWith: Error? = nil, gapNanos: UInt64 = 5_000_000, waitForFinish: Bool = true) {
        self.script = script; self.failWith = failWith; self.gapNanos = gapNanos; self.waitForFinish = waitForFinish
    }
    func start(language: LanguageCode, preferOnDevice: Bool) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        languages.withLock { $0.append(language) }
        if let e = failWith { throw e }
        let s = script, gap = gapNanos, wait = waitForFinish, fin = finished
        return AsyncThrowingStream { c in
            let t = Task {
                for u in s where !u.isFinal { try? await Task.sleep(nanoseconds: gap); c.yield(u) }
                if wait { while !fin.current { try? await Task.sleep(nanoseconds: 2_000_000); if Task.isCancelled { c.finish(); return } } }
                if let f = s.last(where: \.isFinal) { c.yield(f) }
                c.finish()
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
    func finish() async { finished.set(true) }
    func cancel() async { cancelled.withLock { $0 += 1 } }
    func supportsOnDevice(language: LanguageCode) async -> Bool { true }
}

final class FixtureSynth: SpeechSynthesizer, @unchecked Sendable {
    let spoken = Locked<[(String, LanguageCode)]>([])
    let stops = Locked(0)
    let durationNanos: UInt64
    init(durationNanos: UInt64 = 20_000_000) { self.durationNanos = durationNanos }
    func speak(_ text: String, language: LanguageCode) async {
        spoken.withLock { $0.append((text, language)) }
        try? await Task.sleep(nanoseconds: durationNanos)
    }
    func stop() async { stops.withLock { $0 += 1 } }
}

final class VoiceControllerTests: XCTestCase {
    func waitUntil(_ c: VoiceController, timeout: Double = 3, _ pred: @escaping (VoiceState) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if pred(await c.state) { return true }; try? await Task.sleep(nanoseconds: 5_000_000) }
        return false
    }

    func testPushToTalkEndToEndKorean() async {
        let rec = FixtureRecognizer([.init(text: "오늘", isFinal: false), .init(text: "오늘 일정", isFinal: false), .init(text: "오늘 일정 알려줘", isFinal: true)])
        let synth = FixtureSynth()
        let asked = Locked<[(String, LanguageCode)]>([])
        let c = VoiceController(settings: VoiceSettings(), recognizer: rec, synthesizer: synth) { t, l in asked.withLock { $0.append((t, l)) }; return "**오후 3시** 회의가 있습니다." }
        await c.send(.talkPressed)
        let sawPartial = await waitUntil(c) { if case .listening(let p) = $0 { return p == "오늘 일정" }; return false }
        XCTAssertTrue(sawPartial)
        await c.send(.talkReleased)
        let v1 = await waitUntil(c) { $0 == .idle }
        XCTAssertTrue(v1)
        XCTAssertEqual(asked.current.first?.0, "오늘 일정 알려줘"); XCTAssertEqual(asked.current.first?.1, .korean)
        XCTAssertEqual(synth.spoken.current.first?.0, "오후 3시 회의가 있습니다.", "markdown stripped for TTS")
        XCTAssertEqual(synth.spoken.current.first?.1, .korean)
    }

    func testInterruptSpeechByPressingTalk() async {
        let rec = FixtureRecognizer([.init(text: "hi", isFinal: true)], waitForFinish: true)
        let synth = FixtureSynth(durationNanos: 2_000_000_000)
        let c = VoiceController(settings: VoiceSettings(), recognizer: rec, synthesizer: synth) { _, _ in "a long spoken answer" }
        await c.send(.talkPressed); await c.send(.talkReleased)
        let v2 = await waitUntil(c) { if case .speaking = $0 { return true }; return false }
        XCTAssertTrue(v2)
        await c.send(.talkPressed)
        let v3 = await c.state
        XCTAssertEqual(v3, .listening(partial: ""))
        XCTAssertGreaterThanOrEqual(synth.stops.current, 1)
        await c.send(.cancel)
        let v4 = await c.state
        XCTAssertEqual(v4, .idle)
    }

    func testRecognitionFailureAndTextFallback() async {
        let rec = FixtureRecognizer([], failWith: SpeechRecognitionError.notAuthorized)
        let c = VoiceController(settings: VoiceSettings(), recognizer: rec, synthesizer: FixtureSynth()) { t, _ in "echo \(t)" }
        await c.send(.talkPressed)
        let v5 = await waitUntil(c) { if case .error = $0 { return true }; return false }
        XCTAssertTrue(v5)
        await c.submitText("typed question")
        let v6 = await waitUntil(c) { $0 == .idle }
        XCTAssertTrue(v6)
    }

    func testFinalizeTimeoutSubmitsPartial() async {
        let rec = FixtureRecognizer([.init(text: "what time", isFinal: false)], waitForFinish: false)
        var s = VoiceSettings(); s.finalizeTimeout = 0.1; s.speakResponses = false
        let asked = Locked<[String]>([])
        let c = VoiceController(settings: s, recognizer: rec, synthesizer: FixtureSynth()) { t, _ in asked.withLock { $0.append(t) }; return "noon" }
        await c.send(.talkPressed)
        try? await Task.sleep(nanoseconds: 50_000_000)
        await c.send(.talkReleased)
        let v7 = await waitUntil(c) { $0 == .idle }
        XCTAssertTrue(v7)
        XCTAssertEqual(asked.current, ["what time"])
    }

    func testRequestFailureShowsError() async {
        let rec = FixtureRecognizer([.init(text: "q", isFinal: true)])
        let c = VoiceController(settings: VoiceSettings(), recognizer: rec, synthesizer: FixtureSynth()) { _, _ in throw ModelError.timeout }
        await c.send(.talkPressed); await c.send(.talkReleased)
        let v8 = await waitUntil(c) { if case .error = $0 { return true }; return false }
        XCTAssertTrue(v8)
    }

    func testSpeakableTrimming() {
        let s = VoiceController.speakable("# Title\n- item **one**\n```swift\nlet x = 1\n```\nDone.", limit: 600)
        XCTAssertFalse(s.contains("let x")); XCTAssertFalse(s.contains("**")); XCTAssertTrue(s.contains("item one"))
        XCTAssertLessThanOrEqual(VoiceController.speakable(String(repeating: "Sentence. ", count: 200), limit: 100).count, 101)
    }
}
