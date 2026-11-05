import XCTest
@testable import TagenAgents
@testable import TagenCore

final class CodexAppServerAdapterTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipUnless(AgentFixtures.hasPython, "python3 required") }

    func adapter(_ scenario: String, log: String? = nil) -> CodexAppServerAdapter {
        CodexAppServerAdapter(executable: AgentFixtures.path("fake_codex.py"), environment: AgentFixtures.env(scenario, extra: log.map { ["FAKE_LOG": $0] } ?? [:]), requestTimeout: 10)
    }
    func spec(_ profile: AgentPermissionProfile = .askEveryTime, resume: String? = nil) -> AgentTaskSpec {
        AgentTaskSpec(provider: .codex, prompt: "list files", workingDirectory: AgentFixtures.tempDir(), model: "gpt-5-codex", permissionProfile: profile, resumeSessionID: resume, timeout: 30)
    }
    func broker(_ d: ApprovalDecision) -> (ApprovalBroker, Presenter) { let p = Presenter(d); return (ApprovalBroker(presenter: p, timeout: 10, stop: EmergencyStop()), p) }

    func testHandshakeThreadTurnAndStreaming() async throws {
        let log = AgentFixtures.tempDir() + "/log.txt"
        let ev = await collect(await adapter("success", log: log).start(spec(), approvals: broker(.approved).0))
        XCTAssertTrue(ev.contains(.session("thr_new")))
        XCTAssertTrue(ev.contains(.toolStarted(id: "cmd1", name: "command", detail: "ls")))
        XCTAssertTrue(ev.contains(.toolOutput(id: "cmd1", text: "README.md\n")))
        XCTAssertTrue(ev.contains(.messageDelta("Hel")))
        XCTAssertEqual(ev.result?.finalText, "Hello"); XCTAssertEqual(ev.result?.sessionID, "thr_new")
        let l = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertTrue(l.contains("recv initialize")); XCTAssertTrue(l.contains("recv initialized")); XCTAssertTrue(l.contains("recv account/read"))
        XCTAssertTrue(l.contains("\"approvalPolicy\": \"untrusted\"")); XCTAssertTrue(l.contains("\"sandbox\": \"workspace-write\""))
        XCTAssertTrue(l.contains("\"model\": \"gpt-5-codex\""))
    }

    func testCommandApprovalAcceptAndDecline() async {
        let (b, p) = broker(.approved)
        let ev = await collect(await adapter("approval").start(spec(), approvals: b))
        XCTAssertEqual(ev.result?.finalText, "decision=accept")
        XCTAssertEqual(p.seen.current.first?.risk, .high)
        XCTAssertTrue(p.seen.current.first?.reasons.contains("agent says: clean build") == true)
        let ev2 = await collect(await adapter("approval").start(spec(), approvals: broker(.denied(reason: "x")).0))
        XCTAssertEqual(ev2.result?.finalText, "decision=decline")
    }

    func testFileApprovalAutoAcceptedInAutoEditsProfile() async {
        let (b, p) = broker(.denied(reason: "should not be asked"))
        let ev = await collect(await adapter("fileapproval").start(spec(.autoEditsInProject), approvals: b))
        XCTAssertEqual(ev.result?.finalText, "decision=accept"); XCTAssertTrue(p.seen.current.isEmpty)
        let ro = await collect(await adapter("fileapproval").start(spec(.readOnly), approvals: broker(.approved).0))
        XCTAssertEqual(ro.result?.finalText, "decision=decline")
    }

    func testLegacyApprovalVocabulary() async {
        let ev = await collect(await adapter("legacy").start(spec(), approvals: broker(.approved).0))
        XCTAssertEqual(ev.result?.finalText, "decision=approved")
    }

    func testAuthRequired() async {
        let ev = await collect(await adapter("auth").start(spec(), approvals: broker(.approved).0))
        XCTAssertEqual(ev.failure?.kind, .authentication)
    }

    func testTurnFailureWith401IsAuth() async {
        let ev = await collect(await adapter("turnfail").start(spec(), approvals: broker(.approved).0))
        XCTAssertEqual(ev.failure?.kind, .authentication)
    }

    func testCancelSendsTurnInterrupt() async throws {
        let log = AgentFixtures.tempDir() + "/log.txt"
        let run = await adapter("hang", log: log).start(spec(), approvals: broker(.approved).0)
        Task { try? await Task.sleep(nanoseconds: 800_000_000); await run.cancel() }
        let ev = await collect(run, timeout: 10)
        XCTAssertEqual(ev.failure?.kind, .cancelled)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue((try String(contentsOfFile: log, encoding: .utf8)).contains("interrupt"))
    }

    func testCrashThenAutomaticResumeViaTaskManager() async throws {
        let store = try AppStore.inMemory()
        let mgr = AgentTaskManager(adapters: [.codex: adapter("crash")], approvals: broker(.approved).0, store: store, stop: EmergencyStop(), maxAutoRecoveries: 1)
        let (id, stream) = await mgr.start(spec())
        let ev = await collect(stream, timeout: 30)
        XCTAssertEqual(ev.result?.finalText, "recovered", "\(ev)")
        XCTAssertTrue(ev.contains { if case .log(let l) = $0 { return l.contains("resuming session thr_new") }; return false })
        let snap = await mgr.tasks[id]
        XCTAssertEqual(snap?.recoveries, 1); XCTAssertEqual(snap?.status, .completed)
        let rec = try XCTUnwrap(store.agentSession(id: id))
        XCTAssertEqual(rec.status, "completed"); XCTAssertEqual(rec.externalSessionID, "thr_new")
        XCTAssertFalse(try store.agentEvents(sessionID: id).isEmpty)
    }
}

final class CodexExecAdapterTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipUnless(AgentFixtures.hasPython, "python3 required") }
    func testExecJSONLAndResumeArgs() async throws {
        let argsFile = AgentFixtures.tempDir() + "/a.json"
        let a = CodexExecAdapter(executable: AgentFixtures.path("fake_codex_exec.py"), environment: AgentFixtures.env("success", extra: ["FAKE_ARGS_FILE": argsFile]))
        let spec = AgentTaskSpec(provider: .codex, prompt: "do it", workingDirectory: AgentFixtures.tempDir(), permissionProfile: .readOnly, resumeSessionID: "thr_9")
        let ev = await collect(await a.start(spec, approvals: ApprovalBroker(presenter: nil, stop: EmergencyStop())))
        XCTAssertEqual(ev.result?.sessionID, "thr_9"); XCTAssertEqual(ev.result?.finalText, "Done: do it"); XCTAssertEqual(ev.result?.changedFiles, ["src/x.py"])
        let args = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: argsFile))) as? [String])
        XCTAssertEqual(args[args.firstIndex(of: "--sandbox")! + 1], "read-only")
        XCTAssertEqual(args[args.firstIndex(of: "resume")! + 1], "thr_9")
        XCTAssertFalse(args.contains { $0.contains("dangerously") })
        let fail = await collect(await CodexExecAdapter(executable: AgentFixtures.path("fake_codex_exec.py"), environment: AgentFixtures.env("fail")).start(spec, approvals: ApprovalBroker(presenter: nil, stop: EmergencyStop())))
        XCTAssertEqual(fail.failure?.kind, .authentication)
    }
}

final class AgentInfrastructureTests: XCTestCase {
    func testLocatorPrefersOverridesThenPath() {
        let existing: Set<String> = ["/custom/claude", "/opt/homebrew/bin/codex", "/login/bin/codex"]
        let l = ExecutableLocator(overrides: ["claude": "/custom/claude"], fileExists: { existing.contains($0) })
        XCTAssertEqual(l.locate("claude", loginShellPATH: nil), "/custom/claude")
        XCTAssertEqual(l.locate("codex", loginShellPATH: "/login/bin"), "/login/bin/codex")
        XCTAssertEqual(l.locate("codex", loginShellPATH: nil), "/opt/homebrew/bin/codex")
        XCTAssertNil(l.locate("nothing", loginShellPATH: nil))
        let env = l.environment(loginShellPATH: "/login/bin", extra: ["X": "1"])
        XCTAssertTrue(env["PATH"]!.hasPrefix("/login/bin")); XCTAssertEqual(env["X"], "1")
    }

    func testAuthInterpretationAndCredentialEnv() throws {
        XCTAssertEqual(AgentAuthManager.interpret(provider: .claudeCode, exitCode: 0, output: #"{"loggedIn":true,"authMethod":"claude.ai"}"#), .signedIn(method: "claude.ai"))
        if case .signedOut = AgentAuthManager.interpret(provider: .claudeCode, exitCode: 1, output: #"{"authMethod":"none"}"#) {} else { XCTFail() }
        if case .signedIn = AgentAuthManager.interpret(provider: .codex, exitCode: 0, output: "Logged in using an API key") {} else { XCTFail() }
        if case .signedOut = AgentAuthManager.interpret(provider: .codex, exitCode: 1, output: "Not logged in") {} else { XCTFail() }
        let secrets = InMemorySecretStore([SecretKey.claudeCodeOAuthToken: "tok"])
        let m = AgentAuthManager(locator: ExecutableLocator(), secrets: secrets, loginShellPATH: nil)
        XCTAssertEqual(m.credentialEnvironment(.claudeCode), ["CLAUDE_CODE_OAUTH_TOKEN": "tok"])
        XCTAssertTrue(m.credentialEnvironment(.codex).isEmpty)
        XCTAssertTrue(AgentAuthManager.loginCommand(.codex, executable: "/a b/codex").contains("'/a b/codex' login"))
    }

    func testAuthErrorDetector() {
        XCTAssertTrue(AuthErrorDetector.isAuthError("Invalid API key · Please run /login"))
        XCTAssertTrue(AuthErrorDetector.isAuthError("unexpected status 401 Unauthorized"))
        XCTAssertFalse(AuthErrorDetector.isAuthError("tests failed: 3 errors"))
    }

    func testManagerNotInstalledEmergencyStopAndPersistence() async throws {
        let store = try AppStore.inMemory()
        let stop = EmergencyStop()
        let mgr = AgentTaskManager(adapters: [.claudeCode: ClaudeCodeAdapter(executable: nil, environment: [:], approvalMCPPath: nil)],
                                   approvals: ApprovalBroker(presenter: nil, stop: stop), store: store, stop: stop)
        let (id, s) = await mgr.start(AgentTaskSpec(provider: .claudeCode, prompt: "x", workingDirectory: "/tmp"))
        let ev = await collect(s)
        XCTAssertEqual(ev.failure?.kind, .notInstalled)
        XCTAssertEqual(try store.agentSession(id: id)?.status, "failed")
        let (_, s2) = await mgr.start(AgentTaskSpec(provider: .codex, prompt: "x", workingDirectory: "/tmp"))
        let ev2 = await collect(s2)
        XCTAssertEqual(ev2.failure?.kind, .notInstalled, "no adapter registered")
    }

    func testEmergencyStopCancelsRunningAgents() async throws {
        try XCTSkipUnless(AgentFixtures.hasPython)
        let stop = EmergencyStop()
        let mgr = AgentTaskManager(adapters: [.claudeCode: ClaudeCodeAdapter(executable: AgentFixtures.path("fake_claude.py"), environment: AgentFixtures.env("hang"), approvalMCPPath: nil)],
                                   approvals: ApprovalBroker(presenter: nil, stop: stop), store: nil, stop: stop)
        await mgr.installEmergencyStop()
        let (_, s) = await mgr.start(AgentTaskSpec(provider: .claudeCode, prompt: "x", workingDirectory: AgentFixtures.tempDir()))
        Task { try? await Task.sleep(nanoseconds: 600_000_000); stop.trigger(reason: "test") }
        let ev = await collect(s, timeout: 10)
        XCTAssertEqual(ev.failure?.kind, .cancelled)
    }
}
