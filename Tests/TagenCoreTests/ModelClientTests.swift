import XCTest
@testable import TagenCore

final class SSEParserTests: XCTestCase {
    func testStrictAndTolerantParsing() {
        var p = SSEParser()
        XCTAssertNil(p.feed("event: ping"))
        XCTAssertNil(p.feed("data: {\"a\":1}"))
        XCTAssertEqual(p.feed(""), SSEParser.Event(event: "ping", data: "{\"a\":1}"))
        XCTAssertNil(p.feed(": comment"))
        var t = SSEParser()
        XCTAssertNil(t.feedTolerant("event: x"))
        XCTAssertEqual(t.feedTolerant("data: hi"), SSEParser.Event(event: "x", data: "hi"))
        XCTAssertNil(t.feedTolerant(""))
    }
}

final class AnthropicClientTests: XCTestCase {
    func request(image: Bool = false) -> ChatRequest {
        var parts: [ContentPart] = [.text("hello")]
        if image { parts.insert(.image(data: Data([1, 2, 3]), mediaType: "image/jpeg"), at: 0) }
        return ChatRequest(system: "sys", messages: [ChatMessage(role: .user, parts: parts)], maxTokens: 1000, purpose: .screenQuestion, effort: .low)
    }

    func testStreamsTextAndKeepsThinkingBlocksForReplay() async throws {
        let t = ScriptedTransport([.init(status: 200, lines: SSE.anthropicText(["Hel", "lo!"], thinking: true))])
        let c = AnthropicClient(apiKey: "k", transport: t)
        let deltas = Locked<[String]>([])
        let r = try await c.complete(request(), model: "claude-opus-5-5") { d in deltas.withLock { $0.append(d) } }
        XCTAssertEqual(deltas.current, ["Hel", "lo!"])
        XCTAssertEqual(r.text, "Hello!"); XCTAssertEqual(r.usage, TokenUsage(inputTokens: 42, outputTokens: 7)); XCTAssertEqual(r.stopReason, "end_turn")
        let blocks = try XCTUnwrap(r.message.providerContent?.arrayValue)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"]?.stringValue, "thinking"); XCTAssertEqual(blocks[0]["signature"]?.stringValue, "sig-abc")
        XCTAssertEqual(blocks[1]["text"]?.stringValue, "Hello!")
        // Replayed verbatim in the next request.
        let encoded = AnthropicClient.encode(r.message)
        XCTAssertEqual(encoded["content"], r.message.providerContent)
    }

    func testRequestShapeHeadersImageEffortFallback() async throws {
        let t = ScriptedTransport([.init(status: 200, lines: SSE.anthropicText(["ok"]))])
        _ = try await AnthropicClient(apiKey: "secret-key", transport: t).complete(request(image: true), model: "claude-opus-5-5")
        let req = try XCTUnwrap(t.requests.current.first)
        XCTAssertEqual(req.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.headers["x-api-key"], "secret-key")
        XCTAssertEqual(req.headers["anthropic-version"], AnthropicClient.apiVersion)
        XCTAssertEqual(req.headers["anthropic-beta"], AnthropicClient.fallbackBeta)
        let body = try XCTUnwrap(t.lastBody)
        XCTAssertEqual(body["model"]?.stringValue, "claude-opus-5-5")
        XCTAssertEqual(body["stream"]?.boolValue, true)
        XCTAssertEqual(body.at("output_config", "effort")?.stringValue, "low")
        XCTAssertEqual(body["fallbacks"]?.stringValue, "default")
        XCTAssertNil(body["temperature"]); XCTAssertNil(body["thinking"])
        let img = body["messages"]?[0]?["content"]?[0]
        XCTAssertEqual(img?["type"]?.stringValue, "image")
        XCTAssertEqual(img?.at("source", "type")?.stringValue, "base64")
        XCTAssertEqual(img?.at("source", "media_type")?.stringValue, "image/jpeg")
        XCTAssertEqual(img?.at("source", "data")?.stringValue, Data([1, 2, 3]).base64EncodedString())
    }

    func testFallbackOmittedForOtherModels() async throws {
        let t = ScriptedTransport([.init(status: 200, lines: SSE.anthropicText(["ok"]))])
        _ = try await AnthropicClient(apiKey: "k", transport: t).complete(request(), model: "claude-haiku-5-5")
        XCTAssertNil(t.requests.current[0].headers["anthropic-beta"]); XCTAssertNil(t.lastBody?["fallbacks"])
    }

    func testRetriesRateLimitThenSucceeds() async throws {
        let t = ScriptedTransport([
            .init(status: 429, headers: ["retry-after": "1"], lines: [#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#]),
            .init(status: 529, lines: [#"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#]),
            .init(status: 200, lines: SSE.anthropicText(["fine"])),
        ])
        let clock = VirtualClock()
        let r = try await AnthropicClient(apiKey: "k", transport: t, retry: RetryPolicy(maxAttempts: 3, baseDelay: 0.5, maxDelay: 4), clock: clock).complete(request(), model: "m")
        XCTAssertEqual(r.text, "fine"); XCTAssertEqual(t.requests.current.count, 3)
    }

    func testAuthErrorIsNotRetried() async {
        let t = ScriptedTransport([.init(status: 401, lines: [#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#])])
        do { _ = try await AnthropicClient(apiKey: "bad", transport: t).complete(request(), model: "m"); XCTFail() }
        catch { XCTAssertEqual(error as? ModelError, .authentication("invalid x-api-key")) }
        XCTAssertEqual(t.requests.current.count, 1)
    }

    func testMissingKeyAndRefusalAndMidStreamError() async {
        do { _ = try await AnthropicClient(apiKey: "", transport: ScriptedTransport([])).complete(request(), model: "m"); XCTFail() }
        catch { XCTAssertEqual(error as? ModelError, .notConfigured("Anthropic API key")) }

        var refusal = SSE.anthropicText(["partial"], stop: "refusal")
        refusal.insert(contentsOf: SSE.event("message_delta", ["type": "message_delta", "delta": ["stop_reason": "refusal", "stop_details": ["category": "cyber"]]]), at: refusal.count - 3)
        do { _ = try await AnthropicClient(apiKey: "k", transport: ScriptedTransport([.init(status: 200, lines: refusal)])).complete(request(), model: "m"); XCTFail() }
        catch { XCTAssertEqual(error as? ModelError, .refusal(category: "cyber")) }

        var broken = Array(SSE.anthropicText(["a"]).prefix(9))
        broken += SSE.event("error", ["type": "error", "error": ["type": "overloaded_error", "message": "x"]])
        do { _ = try await AnthropicClient(apiKey: "k", transport: ScriptedTransport([.init(status: 200, lines: broken)]), retry: .none).complete(request(), model: "m"); XCTFail() }
        catch { XCTAssertEqual(error as? ModelError, .overloaded) }
    }

    func testNetworkFailureMidStreamAfterOutputIsNotRetried() async {
        let lines = Array(SSE.anthropicText(["abc"]).prefix(12))
        let t = ScriptedTransport([.init(status: 200, lines: lines, failAfterLines: URLError(.networkConnectionLost)), .init(status: 200, lines: SSE.anthropicText(["x"]))])
        do { _ = try await AnthropicClient(apiKey: "k", transport: t, clock: VirtualClock()).complete(request(), model: "m"); XCTFail() }
        catch { if case .network = error as? ModelError {} else { XCTFail("\(error)") } }
        XCTAssertEqual(t.requests.current.count, 1, "must not duplicate output by retrying after text was emitted")
    }

    func testErrorMapping() {
        XCTAssertEqual(AnthropicClient.mapError(status: 400, body: #"{"error":{"type":"invalid_request_error","message":"bad"}}"#, headers: [:]), .invalidRequest("bad"))
        XCTAssertEqual(AnthropicClient.mapError(status: 500, body: "oops", headers: [:]), .server(status: 500, message: "oops"))
        XCTAssertTrue(ModelError.server(status: 503, message: "").isRetryable)
        XCTAssertFalse(ModelError.invalidRequest("").isRetryable)
        XCTAssertTrue(ModelError.authentication("x").userMessage(.korean).contains("API"))
    }
}

final class OpenAICompatibleClientTests: XCTestCase {
    func testStreamingAndImageEncoding() async throws {
        let lines = [#"data: {"model":"local-vlm","choices":[{"delta":{"content":"Hi"}}]}"#, "",
                     #"data: {"choices":[{"delta":{"content":" there"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}"#, "", "data: [DONE]"]
        let t = ScriptedTransport([.init(status: 200, lines: lines)])
        let c = OpenAICompatibleClient(apiKey: nil, baseURL: URL(string: "http://localhost:1234/v1")!, transport: t)
        let req = ChatRequest(system: "s", messages: [ChatMessage(role: .user, parts: [.image(data: Data([9]), mediaType: "image/png"), .text("q")])], purpose: .screenQuestion)
        let r = try await c.complete(req, model: "local-vlm")
        XCTAssertEqual(r.text, "Hi there"); XCTAssertEqual(r.usage.outputTokens, 2)
        XCTAssertEqual(t.requests.current[0].url.absoluteString, "http://localhost:1234/v1/chat/completions")
        XCTAssertNil(t.requests.current[0].headers["authorization"])
        let part = t.lastBody?["messages"]?[1]?["content"]?[0]
        XCTAssertEqual(part?.at("image_url", "url")?.stringValue, "data:image/png;base64,CQ==")
    }
}

final class ModelRouterTests: XCTestCase {
    func testFallsBackWhenPrimaryUnavailable() async throws {
        let primary = AnthropicClient(apiKey: "", transport: ScriptedTransport([]))
        let t = ScriptedTransport([.init(status: 200, lines: ["data: {\"choices\":[{\"delta\":{\"content\":\"from fallback\"}}]}", "data: [DONE]"])])
        let secondary = OpenAICompatibleClient(apiKey: "k", baseURL: URL(string: "https://x/v1")!, transport: t)
        var s = ModelSettings.default
        s.fallback = .init(provider: .openAICompatible, model: "gpt-x")
        let router = ModelRouter(settings: s, clients: [.anthropic: primary, .openAICompatible: secondary])
        var text = ""
        for try await e in router.stream(ChatRequest(system: "s", messages: [.user("q")], purpose: .quickAnswer)) { if case .textDelta(let d) = e { text += d } }
        XCTAssertEqual(text, "from fallback")
        XCTAssertEqual(t.lastBody?["model"]?.stringValue, "gpt-x")
    }

    func testDoesNotFallBackOnAuthError() async {
        let t1 = ScriptedTransport([.init(status: 401, lines: [#"{"error":{"type":"authentication_error","message":"bad"}}"#])])
        let t2 = ScriptedTransport([])
        var s = ModelSettings.default; s.fallback = .init(provider: .openAICompatible, model: "m")
        let router = ModelRouter(settings: s, clients: [.anthropic: AnthropicClient(apiKey: "x", transport: t1),
                                                         .openAICompatible: OpenAICompatibleClient(apiKey: nil, baseURL: URL(string: "https://x")!, transport: t2)])
        do { for try await _ in router.stream(ChatRequest(system: "s", messages: [.user("q")], purpose: .quickAnswer)) {}; XCTFail() }
        catch { XCTAssertEqual(error as? ModelError, .authentication("bad")) }
        XCTAssertTrue(t2.requests.current.isEmpty)
    }

    func testRouteAppliesEffortDefault() async throws {
        let t = ScriptedTransport([.init(status: 200, lines: SSE.anthropicText(["x"]))])
        let router = ModelRouter(settings: .default, clients: [.anthropic: AnthropicClient(apiKey: "k", transport: t)])
        for try await _ in router.stream(ChatRequest(system: "s", messages: [.user("q")], purpose: .guidance)) {}
        XCTAssertEqual(t.lastBody?.at("output_config", "effort")?.stringValue, "medium")
        XCTAssertEqual(t.lastBody?["model"]?.stringValue, "claude-opus-5-5")
    }
}
