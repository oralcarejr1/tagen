import XCTest
@testable import TagenAgents
@testable import TagenCore

final class ClaudeCodeAdapterTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(AgentFixtures.hasPython, "python3 required for fake CLI fixtures")
    }
    func adapter(_ scenario: String, mcp: String? = nil, extra: [String: String] = [:]) -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(executable: AgentFixtures.path("fake_claude.py"), environment: AgentFixtures.env(scenario, extra: extra),
                          approvalMCPPath: mcp, runtimeDirectory: AgentFixtures.tempDir())
    }
    func spec(_ prompt: String = "fix the bug", resume: String? = nil, profile: AgentPermissionProfile = .askEveryTime) -> AgentTaskSpec {
        AgentTaskSpec(provider: .claudeCode, prompt: prompt, workingDirectory: AgentFixtures.tempDir(), model: "claude-opus-5-5",
                      permissionProfile: profile, resumeSessionID: resume, maxTurns: 5, timeout: 30)
    }
    func broker(_ d: ApprovalDecision = .denied(reason: "no")) -> (ApprovalBroker, Presenter) {
        let p = Presenter(d); return (ApprovalBroker(presenter: p, timeout: 10, stop: EmergencyStop()), p)
    }

    func testArgumentsMapToSupportedHeadlessFlags() {
        let a = adapter("success").arguments(for: spec(resume: "abc", profile: .readOnly), mcpConfigPath: "/tmp/cfg.json")
        XCTAssertEqual(Array(a.prefix(4)), ["-p", "--output-format", "stream-json", "--verbose"])
        XCTAssertTrue(a.contains("--include-partial-messages"))
        XCTAssertEqual(a[a.firstIndex(of: "--permission-mode")! + 1], "plan")
        XCTAssertEqual(a[a.firstIndex(of: "--resume")! + 1], "abc")
        XCTAssertEqual(a[a.firstIndex(of: "--permission-prompt-tool")! + 1], "mcp__tagen__approve")
        XCTAssertFalse(a.contains("bypassPermissions")); XCTAssertFalse(a.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(ClaudeCodeAdapter.permissionMode(.autoEditsInProject), "acceptEdits")
    }

    func testSuccessStreamsProgressToolsAndResult() async {
        let argsFile = AgentFixtures.tempDir() + "/args.json"
        let run = await adapter("success", extra: ["FAKE_ARGS_FILE": argsFile]).start(spec("add tests"), approvals: broker().0)
        let ev = await collect(run)
        XCTAssertTrue(ev.contains(.session("sess-123")))
        XCTAssertTrue(ev.contains(.messageDelta("Work")))
        XCTAssertTrue(ev.contains(.toolStarted(id: "toolu_read", name: "Read", detail: "README.md")))
        XCTAssertTrue(ev.contains(.toolFinished(id: "toolu_read", name: "Read", success: true, detail: "file contents")))
        let r = ev.result
        XCTAssertEqual(r?.finalText, "echo: add tests", "prompt delivered on stdin")
        XCTAssertEqual(r?.sessionID, "sess-123"); XCTAssertEqual(r?.costUSD, 0.0123); XCTAssertEqual(r?.turns, 3)
        let args = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: argsFile)))) as? [String]
        XCTAssertEqual(args?.contains("--model"), true)
    }

    func testApprovalRelayAllowEndToEnd() async throws {
        let mcp = try XCTUnwrap(AgentFixtures.approvalMCP, "build tagen-approval-mcp first (swift build --build-tests)")
        let (b, p) = broker(.approved)
        let ev = await collect(await adapter("approval", mcp: mcp).start(spec(), approvals: b))
        XCTAssertEqual(ev.result?.finalText, "allowed", "\(ev)")
        XCTAssertEqual(p.seen.current.first?.risk, .high, "rm -rf is high risk")
        XCTAssertTrue(p.seen.current.first?.detail.contains("rm -rf build") == true)
        XCTAssertTrue(ev.contains(.approvalResolved(id: "toolu_bash", approved: true)))
    }

    func testApprovalRelayDenyEndToEnd() async throws {
        let mcp = try XCTUnwrap(AgentFixtures.approvalMCP)
        let ev = await collect(await adapter("approval", mcp: mcp).start(spec(), approvals: broker(.denied(reason: "nope")).0))
        XCTAssertTrue(ev.result?.finalText.hasPrefix("denied: The user denied this in Tagen") == true, "\(String(describing: ev.result))")
        XCTAssertTrue(ev.contains(.toolFinished(id: "toolu_bash", name: "Bash", success: false, detail: "The user denied this in Tagen: nope")))
    }

    func testReadOnlyProfileDeniesWithoutAsking() async throws {
        let mcp = try XCTUnwrap(AgentFixtures.approvalMCP)
        let (b, p) = broker(.approved)
        let ev = await collect(await adapter("approval", mcp: mcp).start(spec(profile: .readOnly), approvals: b))
        XCTAssertTrue(ev.result?.finalText.contains("read-only") == true)
        XCTAssertTrue(p.seen.current.isEmpty)
    }

    func testAuthFailureClassified() async {
        let ev = await collect(await adapter("auth").start(spec(), approvals: broker().0))
        XCTAssertEqual(ev.failure?.kind, .authentication, "\(ev)")
        XCTAssertNotNil(ev.failure?.remedy)
    }

    func testCrashIsRecoverableWithSession() async {
        let ev = await collect(await adapter("crash").start(spec(), approvals: broker().0))
        let f = ev.failure
        XCTAssertEqual(f?.kind, .processCrashed); XCTAssertEqual(f?.exitCode, 3)
        XCTAssertTrue(f?.message.contains("panic") == true); XCTAssertEqual(f?.sessionID, "sess-123"); XCTAssertTrue(f?.isRecoverable == true)
    }

    func testCancelStopsHungProcessQuickly() async {
        let run = await adapter("hang").start(spec(), approvals: broker().0)
        let t0 = Date()
        Task { try? await Task.sleep(nanoseconds: 500_000_000); await run.cancel() }
        let ev = await collect(run, timeout: 10)
        XCTAssertEqual(ev.failure?.kind, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 6)
    }

    func testResumeAndMaxTurns() async {
        let ev = await collect(await adapter("success").start(spec("continue", resume: "sess-old"), approvals: broker().0))
        XCTAssertEqual(ev.result?.sessionID, "sess-old")
        XCTAssertTrue(ev.result?.finalText.hasPrefix("resumed sess-old") == true)
        let mt = await collect(await adapter("max_turns").start(spec(), approvals: broker().0))
        XCTAssertTrue(mt.result?.finalText.contains("maximum number of turns") == true)
    }

    func testMissingExecutable() async {
        let a = ClaudeCodeAdapter(executable: nil, environment: [:], approvalMCPPath: nil)
        let ev = await collect(await a.start(spec(), approvals: broker().0))
        XCTAssertEqual(ev.failure?.kind, .notInstalled)
    }

    func testParserHandlesErrorResultsAndDenials() {
        let p = ClaudeStreamParser(workingDirectory: "/p")
        let ev = p.handle(["type": "result", "subtype": "error_during_execution", "is_error": true, "session_id": "s", "errors": ["tool crashed"]])
        XCTAssertEqual(ev.last, .failed(AgentFailure(kind: .agentError, message: "tool crashed", sessionID: "s")))
        let ok = ClaudeStreamParser(workingDirectory: "/p").handle(["type": "result", "subtype": "success", "result": "done", "session_id": "s",
                                                                    "permission_denials": [["tool_name": "Bash", "tool_input": ["command": "rm x"]]]])
        XCTAssertEqual(ok.result?.permissionDenials, ["Bash: rm x"])
    }
}

final class ApprovalRelayTests: XCTestCase {
    func testRoundTripAndTokenCheck() throws {
        let sock = AgentFixtures.tempDir() + "/r.sock"
        let server = ApprovalRelayServer(socketPath: sock) { req in
            req.toolName == "Bash" ? .deny(message: "no shell") : .allow(updatedInput: req.input)
        }
        try server.start()
        defer { server.stop() }
        let a = ApprovalRelayClient.ask(socketPath: sock, token: server.token, toolName: "Edit", input: ["file_path": "/p/x"], toolUseID: "t1")
        XCTAssertEqual(a["behavior"]?.stringValue, "allow"); XCTAssertEqual(a.at("updatedInput", "file_path")?.stringValue, "/p/x")
        let d = ApprovalRelayClient.ask(socketPath: sock, token: server.token, toolName: "Bash", input: [:], toolUseID: nil)
        XCTAssertEqual(d["message"]?.stringValue, "no shell")
        let bad = ApprovalRelayClient.ask(socketPath: sock, token: "wrong", toolName: "Edit", input: [:], toolUseID: nil)
        XCTAssertEqual(bad["behavior"]?.stringValue, "deny")
        let none = ApprovalRelayClient.ask(socketPath: sock + ".missing", token: server.token, toolName: "Edit", input: [:], toolUseID: nil)
        XCTAssertEqual(none["behavior"]?.stringValue, "deny", "unreachable app → deny")
    }

    func testMCPServerProtocol() {
        let s = ApprovalMCPServer(socketPath: "/nonexistent.sock", token: "t")
        let i = s.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        XCTAssertEqual(i?.at("result", "protocolVersion")?.stringValue, "2025-06-18")
        XCTAssertNil(s.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertEqual(s.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?.at("result", "tools")?[0]?["name"]?.stringValue, "approve")
        let call = s.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "approve", "arguments": ["tool_name": "Bash", "input": ["command": "ls"]]]])
        let text = call?.at("result", "content")?[0]?["text"]?.stringValue ?? ""
        XCTAssertEqual((try? JSONValue.parse(text))?["behavior"]?.stringValue, "deny")
        XCTAssertNotNil(s.handle(["jsonrpc": "2.0", "id": 4, "method": "bogus"])?["error"])
    }
}
