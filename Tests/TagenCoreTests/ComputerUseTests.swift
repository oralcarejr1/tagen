import XCTest
@testable import TagenCore

/// Executor/session logic against SimulatedGUIDriver (an in-memory UI model).
/// These are NOT live GUI tests; live verification is tagen-gui-check on macOS.
final class ActionPolicyTests: XCTestCase {
    let policy = ActionPolicy()
    func obs(bundle: String = "dev.tagen.Fixture", title: String = "Tagen Fixture") -> GUIObservation {
        GUIObservation(app: AppInfo(name: "x", bundleID: bundle, pid: 1), window: WindowInfo(title: title, frame: .zero), root: Fixtures.fixtureTree(), layout: Fixtures.layout)
    }
    func el(_ id: String) -> AXElementSnapshot { Fixtures.fixtureTree().flattened().first { $0.identifier == id }! }
    func btn(_ title: String) -> AXElementSnapshot { AXElementSnapshot(id: "b", role: "AXButton", title: title) }

    func testClassification() {
        let q = ElementTarget.query(ElementQuery(identifier: "x"))
        XCTAssertEqual(policy.assess(.click(q), element: el("incrementButton"), observation: obs(), scopeBundleID: "dev.tagen.Fixture").risk, .low)
        XCTAssertEqual(policy.assess(.click(q), element: el("deleteButton"), observation: obs(), scopeBundleID: nil).risk, .high)
        for t in ["Buy now", "Place Order", "Send", "Empty Trash", "삭제", "결제하기", "보내기", "Sign Out"] {
            XCTAssertEqual(policy.assess(.click(q), element: btn(t), observation: obs(), scopeBundleID: nil).risk, .high, t)
        }
        XCTAssertEqual(policy.assess(.click(q), element: btn("Undo"), observation: obs(), scopeBundleID: nil).risk, .low, "word boundary: 'undo' ≠ 'do'")
        XCTAssertEqual(policy.assess(.typeText(q, text: "hello"), element: el("nameField"), observation: obs(), scopeBundleID: nil).risk, .medium)
        XCTAssertEqual(policy.assess(.typeText(q, text: "x"), element: el("passwordField"), observation: obs(), scopeBundleID: nil).risk, .high)
        XCTAssertEqual(policy.assess(.typeText(q, text: "sk-ant-api03-abcdefghijklmnopqrst"), element: el("nameField"), observation: obs(), scopeBundleID: nil).risk, .high)
        XCTAssertEqual(policy.assess(.typeText(nil, text: "ls"), element: nil, observation: obs(bundle: "com.apple.Terminal"), scopeBundleID: nil).risk, .high)
        XCTAssertEqual(policy.assess(.pressKeys(KeyCombo(key: "delete", modifiers: [.command])), element: nil, observation: obs(), scopeBundleID: nil).risk, .high)
        XCTAssertEqual(policy.assess(.pressKeys(KeyCombo(key: "c", modifiers: [.command])), element: nil, observation: obs(), scopeBundleID: nil).risk, .medium)
        XCTAssertEqual(policy.assess(.selectMenu(path: ["File", "Move to Trash"]), element: nil, observation: obs(), scopeBundleID: nil).risk, .high)
        XCTAssertEqual(policy.assess(.selectMenu(path: ["Fixture", "Reset Counter"]), element: nil, observation: obs(), scopeBundleID: nil).risk, .high, "reset is treated as destructive")
        XCTAssertEqual(policy.assess(.scroll(nil, direction: .down), element: nil, observation: obs(), scopeBundleID: nil).risk, .low)
        XCTAssertEqual(policy.assess(.click(q), element: btn("OK"), observation: obs(bundle: "com.apple.keychainaccess"), scopeBundleID: nil).risk, .prohibited)
        XCTAssertEqual(policy.assess(.click(q), element: btn("OK"), observation: obs(bundle: "com.apple.systempreferences", title: "Privacy & Security"), scopeBundleID: nil).risk, .prohibited)
        XCTAssertEqual(policy.assess(.click(q), element: btn("OK"), observation: obs(bundle: "com.other"), scopeBundleID: "dev.tagen.Fixture").risk, .high, "scope violation")
        XCTAssertFalse(policy.assess(.typeText(q, text: "hi"), element: el("nameField"), observation: obs(), scopeBundleID: nil).requiresApproval)
        XCTAssertTrue(ActionPolicy(autoApproveUpTo: .low).assess(.typeText(q, text: "hi"), element: el("nameField"), observation: obs(), scopeBundleID: nil).requiresApproval)
    }

    func testKeyComboParsing() {
        XCTAssertEqual(KeyCombo.parse("cmd+shift+s"), KeyCombo(key: "s", modifiers: [.command, .shift]))
        XCTAssertEqual(KeyCombo.parse("⌘⇧S"), KeyCombo(key: "s", modifiers: [.command, .shift]))
        XCTAssertEqual(KeyCombo.parse("return"), KeyCombo(key: "return"))
        XCTAssertNil(KeyCombo.parse("hyper+x"))
        XCTAssertEqual(KeyCombo(key: "s", modifiers: [.command]).description, "⌘S")
    }
}

final class ActionExecutorTests: XCTestCase {
    func make(_ decision: ApprovalDecision = .denied(reason: "no"), autoApprove: RiskLevel = .medium, stop: EmergencyStop = EmergencyStop()) -> (SimulatedGUIDriver, ActionExecutor, RecordingPresenter) {
        let d = SimulatedGUIDriver()
        let p = RecordingPresenter(decision)
        var cfg = ExecutorConfig(); cfg.settleDelay = 0.01; cfg.pollInterval = 0.01; cfg.verifyTimeout = 0.2
        let e = ActionExecutor(driver: d, policy: ActionPolicy(autoApproveUpTo: autoApprove), approvals: ApprovalBroker(presenter: p, stop: stop),
                               config: cfg, clock: SystemClock(), stop: stop)
        return (d, e, p)
    }
    let scope = "dev.tagen.Fixture"
    func q(_ id: String) -> ElementTarget { .query(ElementQuery(identifier: id)) }

    func testClickVerifiesStateChangeAndUsesAXPress() async {
        let (d, e, p) = make()
        let r = await e.run(.click(q("incrementButton")), scopeBundleID: scope)
        XCTAssertTrue(r.succeeded, "\(r.outcome)")
        XCTAssertEqual(d.state.current.count, 1)
        if case .axPress = d.performed.current.first {} else { XCTFail("expected AXPress, got \(d.performed.current)") }
        XCTAssertTrue(p.seen.current.isEmpty)
        XCTAssertEqual(r.trace.map { $0.split(separator: ":")[0] }, ["observe", "identify", "validate", "authorize", "execute", "reobserve", "verify"])
    }

    func testTypeTextVerifiesValue() async {
        let (d, e, _) = make()
        let r = await e.run(.typeText(q("nameField"), text: "김철수"), scopeBundleID: scope)
        XCTAssertTrue(r.succeeded); XCTAssertEqual(d.state.current.name, "김철수")
        if case .succeeded(let v) = r.outcome { XCTAssertTrue(v.contains("김철수")) }
    }

    func testCheckboxToggleVerified() async {
        let (d, e, _) = make()
        let r = await e.run(.click(q("featureCheckbox")), scopeBundleID: scope)
        XCTAssertTrue(r.succeeded); XCTAssertTrue(d.state.current.checkbox)
    }

    func testHighRiskDeniedIsNeverExecuted() async {
        let (d, e, p) = make(.denied(reason: "user said no"))
        let r = await e.run(.click(q("deleteButton")), scopeBundleID: scope)
        XCTAssertEqual(r.outcome, .denied(reason: "user said no"))
        XCTAssertFalse(d.state.current.deleted); XCTAssertTrue(d.performed.current.isEmpty)
        XCTAssertEqual(p.seen.current.first?.risk, .high)
    }

    func testHighRiskApprovedExecutesOnce() async {
        let (d, e, p) = make(.approved)
        let r = await e.run(.click(q("deleteButton")), scopeBundleID: scope)
        XCTAssertTrue(r.succeeded); XCTAssertTrue(d.state.current.deleted); XCTAssertEqual(p.seen.current.count, 1)
    }

    func testValidationRejectsDisabledAndNonTextTargets() async {
        let (d, e, _) = make()
        let r1 = await e.run(.click(q("disabledButton")), scopeBundleID: scope)
        XCTAssertEqual(r1.outcome, .failed(phase: .validate, reason: "target [w0.7] is disabled"))
        let r2 = await e.run(.typeText(q("incrementButton"), text: "x"), scopeBundleID: scope)
        if case .failed(.validate, _) = r2.outcome {} else { XCTFail("\(r2.outcome)") }
        XCTAssertTrue(d.performed.current.isEmpty)
    }

    func testAmbiguousAndMissingTargetsRefused() async {
        let (d, e, _) = make()
        let r = await e.run(.click(.query(ElementQuery(role: "AXButton"))), scopeBundleID: scope)
        if case .failed(.identify, let why) = r.outcome { XCTAssertTrue(why.contains("elements match")) } else { XCTFail("\(r.outcome)") }
        let r2 = await e.run(.click(q("nope")), scopeBundleID: scope)
        if case .failed(.identify, _) = r2.outcome {} else { XCTFail() }
        XCTAssertTrue(d.performed.current.isEmpty)
    }

    func testStaleCoordinatesRefusedAfterUIChange() async throws {
        let (d, e, _) = make()
        let old = try await d.observe(scopeBundleID: scope)
        d.state.withLock { $0.windowOffset = 50; $0.name = "changed" }   // window moved, UI changed
        let center = old.root!.children[0].frame!.center
        let r = await e.run(.click(.point(center, observationID: old.id)), scopeBundleID: scope, previous: old)
        if case .failed(.identify, let why) = r.outcome { XCTAssertTrue(why.contains("older observation")) } else { XCTFail("\(r.outcome)") }
        XCTAssertEqual(d.state.current.count, 0)
        XCTAssertTrue(d.performed.current.isEmpty, "must never click guessed coordinates")
    }

    func testFreshCoordinatesClickViaCGEventPath() async throws {
        let (d, e, _) = make()
        let o = try await d.observe(scopeBundleID: scope)
        // Point targets on an element prefer the element under the point (AX press).
        let r = await e.run(.click(.point(o.root!.children[0].frame!.center, observationID: o.id)), scopeBundleID: scope, previous: o)
        XCTAssertTrue(r.succeeded, "\(r.outcome)"); XCTAssertEqual(d.state.current.count, 1)
    }

    func testStaleElementIdReResolvedByIdentity() async throws {
        let (d, e, _) = make()
        let old = try await d.observe(scopeBundleID: scope)
        d.state.withLock { $0.windowOffset = 30 }
        let r = await e.run(.click(.element(id: "w0.0", observationID: old.id)), scopeBundleID: scope, previous: old)
        XCTAssertTrue(r.succeeded, "\(r.outcome)"); XCTAssertEqual(d.state.current.count, 1)
    }

    func testBoundedRetryForIdempotentTyping() async {
        let (d, e, _) = make()
        d.failNextPerforms.set(1)
        let r = await e.run(.typeText(q("nameField"), text: "Bob"), scopeBundleID: scope)
        XCTAssertTrue(r.succeeded); XCTAssertEqual(r.attempts, 2); XCTAssertEqual(d.state.current.name, "Bob")
        d.failNextPerforms.set(5)
        let r2 = await e.run(.typeText(q("nameField"), text: "Zed"), scopeBundleID: scope)
        XCTAssertFalse(r2.succeeded); XCTAssertEqual(r2.attempts, 2, "bounded")
    }

    func testUserInputConflictPauses() async {
        let (d, e, _) = make()
        d.userIdle.set(0.1)
        let r = await e.run(.click(q("incrementButton")), scopeBundleID: scope)
        if case .failed(.execute, let why) = r.outcome { XCTAssertTrue(why.contains("user")) } else { XCTFail("\(r.outcome)") }
        XCTAssertEqual(d.state.current.count, 0)
    }

    func testEmergencyStopBeforeExecution() async {
        let stop = EmergencyStop()
        let (d, e, _) = make(.approved, stop: stop)
        // Approval presenter triggers the stop while the user is being asked.
        let p2 = StopOnPresent(stop: stop)
        let e2 = ActionExecutor(driver: d, policy: ActionPolicy(), approvals: ApprovalBroker(presenter: p2, stop: stop), config: e.config, stop: stop)
        let r = await e2.run(.click(q("deleteButton")), scopeBundleID: scope)
        XCTAssertNotEqual(r.outcome, .succeeded(verification: "UI changed after click"))
        XCTAssertFalse(d.state.current.deleted)
    }

    func testClickFocusesTextFieldAndUntargetedTypingVerified() async {
        let (d, e, _) = make()
        d.state.withLock { $0.name = "x" }
        let c = await e.run(.click(q("nameField")), scopeBundleID: scope)
        XCTAssertEqual(c.outcome, .succeeded(verification: "text field focused"))
        let t = await e.run(.typeText(nil, text: "typed", replaceExisting: false), scopeBundleID: scope)
        XCTAssertTrue(t.succeeded, "\(t.outcome)")
        XCTAssertEqual(d.state.current.name, "xtyped")
        if case .succeeded(let v) = t.outcome { XCTAssertTrue(v.contains("xtyped")) }
    }

    func testUntargetedTypingWithoutFocusFailsVerification() async {
        let (d, e, _) = make()
        let t = await e.run(.typeText(nil, text: "lost", replaceExisting: false), scopeBundleID: scope)
        if case .failed(.verify, let why) = t.outcome { XCTAssertEqual(why, "no observable change after typing") } else { XCTFail("\(t.outcome)") }
        XCTAssertEqual(d.state.current.name, "")
    }

    func testMenuShortcutScrollWait() async {
        let (d, e, _) = make()
        d.state.withLock { $0.count = 5 }
        let v1 = await e.run(.selectMenu(path: ["Fixture", "Set Counter to Zero"]), scopeBundleID: scope).succeeded
        XCTAssertTrue(v1)
        XCTAssertEqual(d.state.current.count, 0)
        d.state.withLock { $0.count = 3 }
        let v2 = await e.run(.pressKeys(KeyCombo(key: "r", modifiers: [.command])), scopeBundleID: scope).succeeded
        XCTAssertTrue(v2)
        XCTAssertEqual(d.state.current.count, 0)
        let v3 = await e.run(.scroll(q("nameField"), direction: .down, amount: 3), scopeBundleID: scope).succeeded
        XCTAssertTrue(v3)
        let v4 = await e.run(.wait(.elementExists(ElementQuery(identifier: "countLabel")), timeout: 1), scopeBundleID: scope).succeeded
        XCTAssertTrue(v4)
        let w = await e.run(.wait(.elementExists(ElementQuery(identifier: "ghost")), timeout: 0.1), scopeBundleID: scope)
        XCTAssertFalse(w.succeeded)
        let v5 = await e.run(.selectMenu(path: ["File"]), scopeBundleID: scope).succeeded
        XCTAssertFalse(v5)
    }
}

final class StopOnPresent: ApprovalPresenter, @unchecked Sendable {
    let stop: EmergencyStop
    init(stop: EmergencyStop) { self.stop = stop }
    func present(_ request: ApprovalRequest) async -> ApprovalDecision { stop.trigger(reason: "user hit stop"); return .approved }
}

final class ComputerUseSessionTests: XCTestCase {
    func session(_ planner: ActionPlanner, driver: SimulatedGUIDriver = SimulatedGUIDriver(), steps: Int = 10) -> (ComputerUseSession, SimulatedGUIDriver) {
        var cfg = ExecutorConfig(); cfg.settleDelay = 0.01; cfg.pollInterval = 0.01; cfg.verifyTimeout = 0.2
        let stop = EmergencyStop()
        let ex = ActionExecutor(driver: driver, policy: ActionPolicy(), approvals: ApprovalBroker(presenter: DenyAllPresenter(), stop: stop), config: cfg, stop: stop)
        var c = ComputerUseConfig(); c.maxSteps = steps
        return (ComputerUseSession(goal: "greet Alice", scopeBundleID: "dev.tagen.Fixture", planner: planner, executor: ex, config: c), driver)
    }
    func final(_ s: ComputerUseSession) async -> [ComputerUseEvent] { var out: [ComputerUseEvent] = []; for await e in s.run() { out.append(e) }; return out }

    func testScriptedMultiStepTask() async {
        let (s, d) = session(ScriptedPlanner([.typeText(.query(ElementQuery(identifier: "nameField")), text: "Alice"),
                                               .click(.query(ElementQuery(identifier: "incrementButton"))),
                                               .click(.query(ElementQuery(identifier: "incrementButton")))], summary: "done"))
        let ev = await final(s)
        guard case .finished(let sum)? = ev.last else { return XCTFail("\(String(describing: ev.last))") }
        XCTAssertEqual(sum, "done"); XCTAssertEqual(d.state.current.count, 2); XCTAssertEqual(d.state.current.name, "Alice")
    }

    func testModelPlannerLoopWithJSON() async {
        let model = ScriptedModel([#"{"rationale":"type name","action":{"type":"type","element_id":"w0.2","text":"Alice"}}"#,
                                   #"{"rationale":"press","action":{"type":"click","element_id":"w0.3"}}"#,
                                   #"{"action":{"type":"done","summary":"Greeted Alice"}}"#])
        let (s, d) = session(ModelActionPlanner(models: model))
        let ev = await final(s)
        guard case .finished(let sum)? = ev.last else { return XCTFail("\(String(describing: ev.last))") }
        XCTAssertEqual(sum, "Greeted Alice"); XCTAssertEqual(d.state.current.name, "Alice")
        // Planner conversation is append-only and reports previous results.
        let reqs = model.requests.current
        XCTAssertEqual(reqs.count, 3); XCTAssertEqual(reqs[2].messages.count, 5)
        XCTAssertEqual(reqs[1].messages[0], reqs[0].messages[0])
        XCTAssertTrue(reqs[1].messages.last!.text.contains("OK"))
    }

    func testDestructivePlanIsDeniedAndStops() async {
        let model = ScriptedModel([#"{"action":{"type":"click","element_id":"w0.5"}}"#])
        let (s, d) = session(ModelActionPlanner(models: model))
        let ev = await final(s)
        guard case .failed(let m)? = ev.last else { return XCTFail() }
        XCTAssertTrue(m.contains("denied")); XCTAssertFalse(d.state.current.deleted)
    }

    func testConsecutiveFailuresAndStepLimit() async {
        let bad = ScriptedModel(Array(repeating: #"{"action":{"type":"click","element_id":"w0.7"}}"#, count: 5))
        let (s, _) = session(ModelActionPlanner(models: bad))
        guard case .failed(let m)? = await final(s).last else { return XCTFail() }
        XCTAssertTrue(m.contains("consecutive failures"))
        let loop = ScriptedPlanner(Array(repeating: .scroll(nil, direction: .down, amount: 1), count: 10))
        let (s2, _) = session(loop, steps: 3)
        guard case .failed(let m2)? = await final(s2).last else { return XCTFail() }
        XCTAssertTrue(m2.contains("step limit"))
    }

    func testActionParser() {
        let o = GUIObservation(app: nil, window: nil, root: nil, layout: Fixtures.layout)
        XCTAssertEqual(ActionParser.parse(#"{"action":{"type":"keys","combo":"cmd+s"}}"#, observation: o), .action(.pressKeys(KeyCombo(key: "s", modifiers: [.command])), rationale: ""))
        XCTAssertEqual(ActionParser.parse(#"{"action":{"type":"menu","path":["File","Save"]}}"#, observation: o), .action(.selectMenu(path: ["File", "Save"]), rationale: ""))
        XCTAssertEqual(ActionParser.parse(#"{"action":{"type":"ask_user","question":"Which file?"}}"#, observation: o), .askUser(question: "Which file?"))
        if case .action(.click(.point(let p, let id), _, _), _) = ActionParser.parse(#"{"action":{"type":"click","point":[10,20]}}"#, observation: o) {
            XCTAssertEqual(p, Point(x: 10, y: 20)); XCTAssertEqual(id, o.id)
        } else { XCTFail() }
        if case .fail = ActionParser.parse("I will click it", observation: o) {} else { XCTFail() }
        if case .fail = ActionParser.parse(#"{"action":{"type":"rm_rf"}}"#, observation: o) {} else { XCTFail() }
        if case .fail = ActionParser.parse(#"{"action":{"type":"keys","combo":"hyper+q"}}"#, observation: o) {} else { XCTFail() }
    }
}
