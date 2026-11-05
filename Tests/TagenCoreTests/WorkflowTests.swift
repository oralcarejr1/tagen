import XCTest
@testable import TagenCore

/// Representative end-to-end workflows over TagenCore with test doubles (simulated UI, scripted
/// model, transcript fixtures). Live-device equivalents are listed in docs/test-results.md.
final class WorkflowTests: XCTestCase {
    func fixtureContext(selection: SelectedText? = nil) -> ScreenContext {
        ScreenContext(app: AppInfo(name: "TagenFixture", bundleID: "dev.tagen.Fixture", pid: 7),
                      window: WindowInfo(title: "Tagen Fixture", frame: Rect(x: 100, y: 100, width: 560, height: 620)),
                      axRoot: Fixtures.fixtureTree(), selection: selection, layout: Fixtures.layout)
    }

    /// W3: locate a UI element and highlight it; the rendered overlay lands on the AX frame
    /// (anchoring error 0 pt, target ≤ 12 pt) and follows the element when the window moves.
    func testW3LocateAndHighlightFollowsWindowMove() async throws {
        let provider = FakeContextProvider(fixtureContext())
        let o = AssistantOrchestrator(contextProvider: provider, models: ScriptedModel([#"{"answer":"Here","annotations":[{"type":"highlight","element_id":"w0.3","label":"Greet"}]}"#]), store: nil, stop: EmergencyStop())
        var reply: GuideReply?
        for try await e in await o.ask("where is greet?", mode: .guide) { if case .guidance(let g) = e { reply = g } }
        var lc = AnnotationLifecycle()
        lc.set(try XCTUnwrap(reply).annotations)
        let r0 = lc.render(layout: Fixtures.layout)[0]
        XCTAssertEqual(Fixtures.layout.globalRect(fromLocal: r0.targetRect, in: Fixtures.primary), Rect(x: 344, y: 180, width: 70, height: 24))
        // Window moves 40 pt right: the provider now reports the new AX frame.
        var moved = fixtureContext(); moved.axRoot!.children[3].frame = Rect(x: 384, y: 180, width: 70, height: 24)
        provider.ctx.set(moved)
        guard case .element(let ident, _) = lc.annotations[0].target else { return XCTFail() }
        let f = await provider.currentFrame(ofElementWithIdentity: ident)
        lc.update(AnchorObservation(elementFrames: [lc.annotations[0].id: f], windowFrame: nil, layout: Fixtures.layout, now: Date()))
        let r1 = lc.render(layout: Fixtures.layout)[0]
        let err = abs(Fixtures.layout.globalRect(fromLocal: r1.targetRect, in: Fixtures.primary).midX - 419)
        XCTAssertLessThanOrEqual(err, 12)
    }

    /// W4: speak a question and receive a spoken answer (transcript fixture → orchestrator → TTS).
    func testW4SpokenQuestionSpokenAnswer() async throws {
        let o = AssistantOrchestrator(contextProvider: FakeContextProvider(fixtureContext()), models: ScriptedModel(["The count is zero."]), store: nil, stop: EmergencyStop())
        let synth = FixtureSynth()
        let vc = VoiceController(settings: VoiceSettings(), recognizer: FixtureRecognizer([.init(text: "what is the count", isFinal: false), .init(text: "What is the count?", isFinal: true)]),
                                 synthesizer: synth) { text, _ in
            var answer = ""
            for try await e in await o.ask(text, mode: .ask) { if case .completed(let a) = e { answer = a } }
            return answer
        }
        await vc.send(.talkPressed); await vc.send(.talkReleased)
        let end = Date().addingTimeInterval(3)
        while await vc.state != .idle && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(synth.spoken.current.first?.0, "The count is zero.")
    }

    /// W10: Accessibility revoked in the middle of an Act task → the step fails with a clear
    /// permission error, nothing is retried blindly, and the session stops.
    func testW10RevokedPermissionMidTask() async {
        let driver = RevokingDriver()
        var cfg = ExecutorConfig(); cfg.settleDelay = 0.01; cfg.pollInterval = 0.01; cfg.verifyTimeout = 0.1
        let stop = EmergencyStop()
        let ex = ActionExecutor(driver: driver, policy: ActionPolicy(), approvals: ApprovalBroker(presenter: nil, stop: stop), config: cfg, stop: stop)
        let s = ComputerUseSession(goal: "click twice", scopeBundleID: nil,
                                   planner: ScriptedPlanner([.click(.query(ElementQuery(identifier: "incrementButton"))), .click(.query(ElementQuery(identifier: "incrementButton")))]),
                                   executor: ex)
        var last: ComputerUseEvent?
        for await e in s.run() { last = e }
        guard case .failed(let m)? = last else { return XCTFail("\(String(describing: last))") }
        XCTAssertTrue(m.contains("Permission denied") || m.contains("cannot observe"), m)
        XCTAssertEqual(driver.inner.state.current.count, 1, "first click succeeded, nothing after revocation")
        // UI-level gating reports the missing permission.
        XCTAssertFalse(PermissionGate.evaluate(.computerUse, states: [.accessibility: .denied]).available)
    }

    /// Stability: 100 mixed sessions (ask, guide, selection, act, cancel) without crashes or leaks of state.
    func testHundredMixedSessionsStable() async throws {
        var completed = 0, stopped = 0
        for i in 0..<100 {
            let sel = SelectedText(text: "sample \(i)", source: .accessibility, isEditable: true)
            switch i % 5 {
            case 0:
                let o = AssistantOrchestrator(contextProvider: FakeContextProvider(fixtureContext()), models: ScriptedModel(["a\(i)"]), store: nil, stop: EmergencyStop())
                for try await e in await o.ask("q\(i)", mode: .ask) { if case .completed = e { completed += 1 } }
            case 1:
                let o = AssistantOrchestrator(contextProvider: FakeContextProvider(fixtureContext()), models: ScriptedModel([#"{"answer":"x","annotations":[{"type":"arrow","element_id":"w0.0"}]}"#]), store: nil, stop: EmergencyStop())
                for try await e in await o.ask("where", mode: .guide) { if case .completed = e { completed += 1 } }
            case 2:
                let o = AssistantOrchestrator(contextProvider: FakeContextProvider(fixtureContext(selection: sel)), models: ScriptedModel(["t\(i)"]), store: nil, stop: EmergencyStop())
                for try await e in await o.runSelectionAction(.translate(to: nil)) { if case .completed = e { completed += 1 } }
            case 3:
                var cfg = ExecutorConfig(); cfg.settleDelay = 0; cfg.pollInterval = 0.001; cfg.verifyTimeout = 0.05
                let stop = EmergencyStop()
                let ex = ActionExecutor(driver: SimulatedGUIDriver(), policy: ActionPolicy(), approvals: ApprovalBroker(presenter: nil, stop: stop), config: cfg, stop: stop)
                for await e in ComputerUseSession(goal: "g", scopeBundleID: nil, planner: ScriptedPlanner([.click(.query(ElementQuery(identifier: "incrementButton")))]), executor: ex).run() {
                    if case .finished = e { completed += 1 }
                }
            default:
                let o = AssistantOrchestrator(contextProvider: FakeContextProvider(fixtureContext()), models: ScriptedModel(["slow"], delayNanos: 500_000_000), store: nil, stop: EmergencyStop())
                let stream = await o.ask("q", mode: .ask)
                await o.cancel()
                do { for try await _ in stream {} } catch { if error as? AssistantError == .stopped { stopped += 1 } }
            }
        }
        XCTAssertEqual(completed, 80); XCTAssertEqual(stopped, 20)
    }
}

/// Wraps the simulated UI and revokes Accessibility after the first performed action.
final class RevokingDriver: GUIDriver, @unchecked Sendable {
    let inner = SimulatedGUIDriver()
    let revoked = Locked(false)
    func observe(scopeBundleID: String?) async throws -> GUIObservation {
        if revoked.current { throw DriverError.permissionDenied("Accessibility") }
        return try await inner.observe(scopeBundleID: scopeBundleID)
    }
    func perform(_ p: GUIPrimitive) async throws {
        if revoked.current { throw DriverError.permissionDenied("Accessibility") }
        try await inner.perform(p)
        revoked.set(true)
    }
    func secondsSinceUserInput() async -> Double? { nil }
}
