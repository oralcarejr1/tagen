import XCTest
@testable import TagenAgents
@testable import TagenCore

/// CodexCLIModelClient against a fake `codex` (never the real CLI).
final class CodexCLIModelClientTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(AgentFixtures.hasPython, "python3 required for fake CLI fixtures")
    }

    func client(_ scenario: String, record: String? = nil, extra: [String: String] = [:]) -> CodexCLIModelClient {
        var e = extra
        if let r = record { e["FAKE_RECORD_FILE"] = r }
        return CodexCLIModelClient(executable: AgentFixtures.path("fake_codex_model.py"), environment: AgentFixtures.env(scenario, extra: e),
                                   workingDirectory: AgentFixtures.tempDir() + "/cwd")
    }
    func request(_ messages: [ChatMessage], system: String = "SYS", timeout: Double = 20, effort: Effort? = .low) -> ChatRequest {
        ChatRequest(system: system, messages: messages, purpose: .screenQuestion, effort: effort, timeout: timeout)
    }
    func record(_ path: String) throws -> JSONValue { try JSONValue.parse(String(contentsOfFile: path, encoding: .utf8)) }
    func error(of stream: AsyncThrowingStream<ModelStreamEvent, Error>) async -> ModelError? {
        do { for try await _ in stream {}; return nil } catch let e as ModelError { return e } catch { return .decoding("\(error)") }
    }
    func value(_ a: [String], after flag: String, matching prefix: String) -> String? {
        a.indices.filter { a[$0] == flag && $0 + 1 < a.count }.map { a[$0 + 1] }.first { $0.hasPrefix(prefix) }
    }

    func testArgumentsLockDownTheAgent() {
        let a = CodexCLIModelClient.arguments(request([.user("hi")], effort: .medium), model: "gpt-x", workingDirectory: "/w", imagePaths: ["/i/1.png"])
        XCTAssertEqual(Array(a.prefix(2)), ["exec", "--json"])
        for f in ["--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules"] { XCTAssertTrue(a.contains(f), f) }
        XCTAssertEqual(a[a.firstIndex(of: "--sandbox")! + 1], "read-only")
        XCTAssertEqual(a[a.firstIndex(of: "--cd")! + 1], "/w")
        let disabled = a.indices.filter { a[$0] == "--disable" }.map { a[$0 + 1] }
        for f in ["shell_tool", "code_mode_host", "apps", "plugins", "hooks", "browser_use", "computer_use"] { XCTAssertTrue(disabled.contains(f), f) }
        XCTAssertEqual(value(a, after: "-c", matching: "web_search"), "web_search=\"disabled\"")
        XCTAssertEqual(value(a, after: "-c", matching: "project_doc"), "project_doc_max_bytes=0")
        XCTAssertEqual(value(a, after: "-c", matching: "model_reasoning_effort"), "model_reasoning_effort=\"medium\"")
        XCTAssertEqual(a[a.firstIndex(of: "--model")! + 1], "gpt-x")
        XCTAssertEqual(a[a.firstIndex(of: "--image")! + 1], "/i/1.png")
        XCTAssertEqual(a.last, "-")
        XCTAssertFalse(a.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertFalse(a.contains("danger-full-access")); XCTAssertFalse(a.contains("workspace-write"))
        XCTAssertNil(CodexCLIModelClient.arguments(request([.user("hi")]), model: "", workingDirectory: "/w", imagePaths: []).firstIndex(of: "--model"),
                     "empty model uses the CLI default")
    }

    func testSystemPromptIsEscapedAsTOML() {
        XCTAssertEqual(CodexCLIModelClient.toml("a \"b\" \\ c\nd\te"), "\"a \\\"b\\\" \\\\ c\\nd\\te\"")
        XCTAssertEqual(CodexCLIModelClient.toml("한국어 / ok"), "\"한국어 / ok\"")
        XCTAssertEqual(CodexCLIModelClient.toml("\u{1}"), "\"\\u0001\"")
        let a = CodexCLIModelClient.arguments(request([.user("q")], system: "Say \"hi\"\nnow"), model: "", workingDirectory: "/w", imagePaths: [])
        XCTAssertEqual(value(a, after: "-c", matching: "developer_instructions"), "developer_instructions=\"Say \\\"hi\\\"\\nnow\"")
    }

    func testReturnsLastAgentMessageAttachesImagesAndCleansUp() async throws {
        let rec = AgentFixtures.tempDir() + "/rec.json"
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let c = client("success", record: rec, extra: ["OPENAI_API_KEY": "sk-no", "CODEX_API_KEY": "sk-no"])
        let r = try await c.complete(request([ChatMessage(role: .user, parts: [.image(data: png, mediaType: "image/png"), .text("what is this?")])]), model: "")
        XCTAssertEqual(r.text, "images=1 last=what is this?", "narration is dropped, last message kept")
        XCTAssertEqual(r.usage, TokenUsage(inputTokens: 120, outputTokens: 9, cacheReadTokens: 80))
        let j = try record(rec)
        XCTAssertNil(j.at("env", "OPENAI_API_KEY")); XCTAssertNil(j.at("env", "CODEX_API_KEY"))
        let img = j["images"]?[0]
        XCTAssertEqual(img?[1]?.intValue, png.count, "image written before launch")
        let path = try XCTUnwrap(img?[0]?.stringValue)
        XCTAssertTrue(path.hasSuffix(".png"))
        XCTAssertFalse(path.hasPrefix(j["cwd"]?.stringValue ?? "/nonexistent"), "images stay outside the agent's working folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "image files deleted before the answer is returned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent), "image folder deleted too")
        XCTAssertTrue(j["stdin"]?.stringValue?.contains("[image 1 attached]") ?? false)
    }

    func testMultiTurnIsFlattened() async throws {
        let rec = AgentFixtures.tempDir() + "/rec.json"
        let r = try await client("success", record: rec).complete(request([.user("first"), .assistant("answer"), .user("follow-up")]), model: "")
        XCTAssertEqual(r.text, "images=0 last=follow-up")
        let stdin = try record(rec)["stdin"]?.stringValue ?? ""
        XCTAssertTrue(stdin.contains("User: first")); XCTAssertTrue(stdin.contains("Assistant: answer"))
    }

    func testTurnWithoutAnswerIsAnError() async {
        let e = await error(of: client("no_answer").stream(request([.user("q")]), model: ""))
        guard case .decoding? = e else { return XCTFail("got \(String(describing: e))") }
    }

    func testNotSignedInMapsToAuthentication() async {
        let e = await error(of: client("auth").stream(request([.user("q")]), model: ""))
        guard case .cliSignedOut(let tool, let detail)? = e else { return XCTFail("got \(String(describing: e))") }
        XCTAssertEqual(tool, "Codex"); XCTAssertTrue(detail.contains("401"), detail)
        XCTAssertTrue(e!.userMessage(.korean).contains("Codex"))
    }

    func testUsageLimitMapsToRateLimited() async {
        let e = await error(of: client("limit").stream(request([.user("q")]), model: ""))
        XCTAssertEqual(e, .rateLimited(retryAfter: nil))
    }

    func testCrashReportsExitCode() async {
        let e = await error(of: client("crash").stream(request([.user("q")]), model: ""))
        guard case .server(_, let m)? = e else { return XCTFail("got \(String(describing: e))") }
        XCTAssertTrue(m.contains("code 101"), m); XCTAssertTrue(m.contains("panicked"), m)
    }

    func testHangTimesOutAndCancelStops() async throws {
        let timeoutError = await error(of: client("hang").stream(request([.user("q")], timeout: 1), model: ""))
        XCTAssertEqual(timeoutError, .timeout)
        let rec = AgentFixtures.tempDir() + "/rec.json"
        let stream = client("hang", record: rec).stream(request([.user("q")], timeout: 30), model: "")
        let task = Task { for try await _ in stream {} }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: rec) { try await Task.sleep(nanoseconds: 50_000_000) }
        task.cancel()
        let t0 = Date(); _ = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }

    func testMissingExecutableAndRouting() async throws {
        let e = await error(of: CodexCLIModelClient(executable: nil, environment: [:]).stream(request([.user("q")]), model: ""))
        XCTAssertEqual(e, .cliUnavailable(tool: "Codex"))
        XCTAssertTrue(e!.userMessage(.english).contains("Codex CLI"))
        var s = ModelSettings.default; s.routes = ModelSettings.chatGPTSubscriptionRoutes
        let router = ModelRouter(settings: s, clients: [.codexCLI: client("success")])
        var text = ""
        for try await ev in router.stream(request([.user("routed")])) { if case .completed(let r) = ev { text = r.text } }
        XCTAssertEqual(text, "images=0 last=routed")
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ModelSettings.self, from: data), s)
    }
}
