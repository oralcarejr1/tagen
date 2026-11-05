import XCTest
@testable import TagenAgents
@testable import TagenCore

/// ClaudeCLIModelClient against a fake `claude` (never the real CLI).
final class ClaudeCLIModelClientTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(AgentFixtures.hasPython, "python3 required for fake CLI fixtures")
    }

    func client(_ scenario: String, record: String? = nil, extra: [String: String] = [:]) -> ClaudeCLIModelClient {
        var e = extra
        if let r = record { e["FAKE_RECORD_FILE"] = r }
        return ClaudeCLIModelClient(executable: AgentFixtures.path("fake_claude_model.py"), environment: AgentFixtures.env(scenario, extra: e),
                                    workingDirectory: AgentFixtures.tempDir() + "/cwd")
    }
    func request(_ messages: [ChatMessage], timeout: Double = 20, effort: Effort? = .low) -> ChatRequest {
        ChatRequest(system: "SYS", messages: messages, purpose: .screenQuestion, effort: effort, timeout: timeout)
    }
    func record(_ path: String) throws -> JSONValue {
        try JSONValue.parse(String(contentsOfFile: path, encoding: .utf8))
    }
    func error(of stream: AsyncThrowingStream<ModelStreamEvent, Error>) async -> ModelError? {
        do { for try await _ in stream {}; return nil } catch let e as ModelError { return e } catch { return .decoding("\(error)") }
    }

    func testArgumentsDisableToolsSettingsAndSessions() {
        let a = ClaudeCLIModelClient.arguments(request([.user("hi")], effort: .medium), model: "opus")
        XCTAssertEqual(a.first, "-p")
        XCTAssertEqual(a[a.firstIndex(of: "--input-format")! + 1], "stream-json")
        XCTAssertEqual(a[a.firstIndex(of: "--output-format")! + 1], "stream-json")
        XCTAssertEqual(a[a.firstIndex(of: "--tools")! + 1], "", "all built-in tools off")
        XCTAssertEqual(a[a.firstIndex(of: "--setting-sources")! + 1], "", "no CLAUDE.md / hooks / user settings")
        XCTAssertTrue(a.contains("--strict-mcp-config")); XCTAssertTrue(a.contains("--no-session-persistence"))
        XCTAssertTrue(a.contains("--disable-slash-commands"))
        XCTAssertEqual(a[a.firstIndex(of: "--max-turns")! + 1], "1")
        XCTAssertEqual(a[a.firstIndex(of: "--system-prompt")! + 1], "SYS")
        XCTAssertEqual(a[a.firstIndex(of: "--model")! + 1], "opus")
        XCTAssertEqual(a[a.firstIndex(of: "--effort")! + 1], "medium")
        XCTAssertFalse(a.contains("--bare"), "--bare ignores the subscription sign-in")
        XCTAssertFalse(a.contains("--dangerously-skip-permissions"))
    }

    func testStreamsTextWithImageAndStripsAPIKeys() async throws {
        let rec = AgentFixtures.tempDir() + "/rec.json"
        let c = client("success", record: rec, extra: ["ANTHROPIC_API_KEY": "sk-should-not-pass", "ANTHROPIC_AUTH_TOKEN": "x"])
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let deltas = Locked<[String]>([])
        let r = try await c.complete(request([ChatMessage(role: .user, parts: [.image(data: png, mediaType: "image/png"), .text("what is this?")])]),
                                     model: "sonnet") { d in deltas.withLock { $0.append(d) } }
        XCTAssertEqual(r.text, "images=1 last=what is this?")
        XCTAssertEqual(deltas.current.joined(), r.text)
        XCTAssertGreaterThan(deltas.current.count, 1, "streamed in pieces")
        XCTAssertEqual(r.model, "claude-sonnet-5-5")
        XCTAssertEqual(r.usage, TokenUsage(inputTokens: 11, outputTokens: 7, cacheReadTokens: 2, cacheWriteTokens: 954))
        let j = try record(rec)
        XCTAssertNil(j.at("env", "ANTHROPIC_API_KEY"), "API key must not reach the CLI")
        XCTAssertNil(j.at("env", "ANTHROPIC_AUTH_TOKEN"))
        let block = j.at("stdin")?[0]?.at("message", "content")?[0]
        XCTAssertEqual(block?["type"]?.stringValue, "image")
        XCTAssertEqual(block?.at("source", "data")?.stringValue, png.base64EncodedString())
        XCTAssertEqual(block?.at("source", "media_type")?.stringValue, "image/png")
        XCTAssertTrue(j["cwd"]?.stringValue?.hasSuffix("/cwd") ?? false, "runs in Tagen's own empty folder")
    }

    func testKeepsSubscriptionTokenStoredInTagen() async throws {
        let rec = AgentFixtures.tempDir() + "/rec.json"
        _ = try await client("success", record: rec, extra: ["CLAUDE_CODE_OAUTH_TOKEN": "tok"]).complete(request([.user("q")]), model: "sonnet")
        XCTAssertEqual(try record(rec).at("env", "CLAUDE_CODE_OAUTH_TOKEN")?.stringValue, "tok")
    }

    func testMultiTurnIsFlattenedIntoOneUserMessage() async throws {
        let rec = AgentFixtures.tempDir() + "/rec.json"
        let msgs: [ChatMessage] = [.user("first question"), .assistant("first answer"), .user("follow-up")]
        let r = try await client("success", record: rec).complete(request(msgs), model: "sonnet")
        XCTAssertEqual(r.text, "images=0 last=follow-up")
        let content = try record(rec).at("stdin")?[0]?.at("message", "content")?.arrayValue ?? []
        let texts = content.compactMap { $0["text"]?.stringValue }
        XCTAssertTrue(texts.contains("User: first question"))
        XCTAssertTrue(texts.contains("Assistant: first answer"))
        XCTAssertEqual(texts.last, "follow-up")
        XCTAssertEqual(try record(rec)["stdin"]?.arrayValue?.count, 1)
    }

    func testResultWithoutDeltasStillYieldsText() async throws {
        let r = try await client("result_only").complete(request([.user("q")]), model: "sonnet")
        XCTAssertEqual(r.text, "images=0 last=q")
    }

    func testNotSignedInMapsToAuthentication() async {
        let e = await error(of: client("auth").stream(request([.user("q")]), model: "sonnet"))
        guard case .authentication(let m)? = e else { return XCTFail("got \(String(describing: e))") }
        XCTAssertTrue(m.hasPrefix("Claude Code"))
        XCTAssertTrue(e!.userMessage(.korean).contains("Claude Code"))
        XCTAssertFalse(e!.userMessage(.english).contains("API key"))
    }

    func testUsageLimitMapsToRateLimited() async {
        let e = await error(of: client("limit").stream(request([.user("q")]), model: "sonnet"))
        XCTAssertEqual(e, .rateLimited(retryAfter: nil))
    }

    func testCrashBeforeResultReportsExitAndStderr() async {
        let e = await error(of: client("crash").stream(request([.user("q")]), model: "sonnet"))
        guard case .server(_, let m)? = e else { return XCTFail("got \(String(describing: e))") }
        XCTAssertTrue(m.contains("code 2"), m); XCTAssertTrue(m.contains("fake crash"), m)
        XCTAssertFalse(e!.isRetryable)
    }

    func testHangTimesOut() async {
        let t0 = Date()
        let e = await error(of: client("hang").stream(request([.user("q")], timeout: 1), model: "sonnet"))
        XCTAssertEqual(e, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 8)
    }

    func testMissingExecutableIsNotConfiguredAndRouterFallsBack() async throws {
        let missing = ClaudeCLIModelClient(executable: nil, environment: [:])
        let e = await error(of: missing.stream(request([.user("q")]), model: "sonnet"))
        guard case .notConfigured(let m)? = e else { return XCTFail("got \(String(describing: e))") }
        XCTAssertTrue(e!.userMessage(.english).contains("Claude Code CLI"), m)

        var s = ModelSettings.default
        s.routes = ModelSettings.claudeSubscriptionRoutes
        s.fallback = .init(provider: .claudeCLI, model: "sonnet")
        let router = ModelRouter(settings: s, clients: [.claudeCLI: client("success")])
        XCTAssertEqual(router.route(for: .guidance), .init(provider: .claudeCLI, model: "opus", effort: .medium))
        var text = ""
        for try await ev in router.stream(request([.user("routed")])) { if case .completed(let r) = ev { text = r.text } }
        XCTAssertEqual(text, "images=0 last=routed")
    }

    func testCancellationStopsTheProcess() async throws {
        let rec = AgentFixtures.tempDir() + "/rec.json"
        let stream = client("hang", record: rec).stream(request([.user("q")], timeout: 30), model: "sonnet")
        let task = Task { for try await _ in stream {} }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: rec) { try await Task.sleep(nanoseconds: 50_000_000) }
        task.cancel()
        let t0 = Date()
        _ = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }

    func testProviderKindRoundTripsInSettings() throws {
        var s = ModelSettings.default; s.routes = ModelSettings.claudeSubscriptionRoutes
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ModelSettings.self, from: data), s)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("claudeCLI"))
    }
}
