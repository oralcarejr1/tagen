import Foundation

/// Claude Messages API client (raw HTTP; Swift has no official SDK).
/// Wire format per the Messages API: POST /v1/messages with `x-api-key`,
/// `anthropic-version`, streaming SSE events `message_start`, `content_block_start`,
/// `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`, `error`.
public struct AnthropicClient: ModelClient {
    public static let defaultModel = "claude-opus-5-5"
    public static let apiVersion = "2026-10-21"
    /// Server-side refusal fallback ("default" routing), enabled by default for models that support it.
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"]

    public var providerName: String { "Anthropic" }
    let apiKey: String
    let baseURL: URL
    let transport: HTTPTransport
    let retry: RetryPolicy
    let clock: SleepClock
    let enableRefusalFallback: Bool

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!, transport: HTTPTransport = URLSessionTransport(),
                retry: RetryPolicy = RetryPolicy(), clock: SleepClock = SystemClock(), enableRefusalFallback: Bool = true) {
        self.apiKey = apiKey; self.baseURL = baseURL; self.transport = transport; self.retry = retry
        self.clock = clock; self.enableRefusalFallback = enableRefusalFallback
    }

    public func buildBody(_ request: ChatRequest, model: String) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(request.maxTokens)),
            "stream": true,
            // Frozen system prompt as a block with an explicit breakpoint: a guaranteed cache read point.
            "system": [["type": "text", "text": .string(request.system), "cache_control": ["type": "ephemeral"]]],
            "messages": .array(request.messages.map(Self.encode)),
        ]
        if let e = request.effort { body["output_config"] = ["effort": .string(e.rawValue)] }
        // Automatic caching: the API places a breakpoint on the last cacheable block and moves it forward
        // as the (append-only) conversation grows, so each follow-up reads the previous turns from cache.
        if request.cacheConversation { body["cache_control"] = ["type": "ephemeral"] }
        if enableRefusalFallback && Self.fallbackModels.contains(model) { body["fallbacks"] = "default" }
        return .object(body)
    }

    static func encode(_ m: ChatMessage) -> JSONValue {
        if let raw = m.providerContent, m.providerID == "anthropic" {
            return ["role": .string(m.role.rawValue), "content": raw]
        }
        let blocks: [JSONValue] = m.parts.map { p in
            switch p {
            case .text(let t): return ["type": "text", "text": .string(t)]
            case .image(let d, let mt):
                return ["type": "image", "source": ["type": "base64", "media_type": .string(mt), "data": .string(d.base64EncodedString())]]
            }
        }
        return ["role": .string(m.role.rawValue), "content": .array(blocks)]
    }

    func headers(model: String) -> [String: String] {
        var h = ["content-type": "application/json", "x-api-key": apiKey, "anthropic-version": Self.apiVersion]
        if enableRefusalFallback && Self.fallbackModels.contains(model) { h["anthropic-beta"] = Self.fallbackBeta }
        return h
    }

    public func stream(_ request: ChatRequest, model: String) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard !apiKey.isEmpty else { continuation.finish(throwing: ModelError.notConfigured("Anthropic API key")); return }
                let body = Data(buildBody(request, model: model).encoded().utf8)
                let http = HTTPRequest(url: baseURL.appendingPathComponent("v1/messages"), headers: headers(model: model), body: body, timeout: request.timeout)
                var attempt = 0
                while true {
                    attempt += 1
                    var emitted = false
                    do {
                        try Task.checkCancellation()
                        let (head, lines) = try await transport.streamLines(http)
                        if head.status != 200 {
                            var text = ""
                            for try await l in lines { text += l + "\n" }
                            throw Self.mapError(status: head.status, body: text, headers: head.headers)
                        }
                        var acc = Accumulator()
                        var parser = SSEParser()
                        for try await line in lines {
                            try Task.checkCancellation()
                            guard let ev = parser.feedTolerant(line), !ev.data.isEmpty else { continue }
                            guard let json = try? JSONValue.parse(ev.data) else { continue }
                            if let delta = try acc.apply(json) { emitted = true; continuation.yield(.textDelta(delta)) }
                            if acc.finished { break }
                        }
                        let resp = try acc.response(defaultModel: model)
                        continuation.yield(.completed(resp))
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish(throwing: ModelError.cancelled); return
                    } catch let e as ModelError {
                        if e.isRetryable, !emitted, attempt < retry.maxAttempts {
                            var delay = retry.delay(forAttempt: attempt)
                            if case .rateLimited(let ra?) = e { delay = max(delay, min(ra, retry.maxDelay * 4)) }
                            do { try await clock.sleep(seconds: delay) } catch { continuation.finish(throwing: ModelError.cancelled); return }
                            continue
                        }
                        continuation.finish(throwing: e); return
                    } catch {
                        let e = ModelError.network(error.localizedDescription)
                        if !emitted, attempt < retry.maxAttempts {
                            try? await clock.sleep(seconds: retry.delay(forAttempt: attempt)); continue
                        }
                        continuation.finish(throwing: e); return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func mapError(status: Int, body: String, headers: [String: String]) -> ModelError {
        let json = try? JSONValue.parse(body)
        let type = json?.at("error", "type")?.stringValue
        let msg = json?.at("error", "message")?.stringValue ?? String(body.prefix(300))
        switch (status, type) {
        case (_, "authentication_error"), (401, _): return .authentication(msg)
        case (_, "permission_error"), (403, _): return .permission(msg)
        case (_, "rate_limit_error"), (429, _): return .rateLimited(retryAfter: headers["retry-after"].flatMap(Double.init))
        case (_, "overloaded_error"), (529, _): return .overloaded
        case (_, "invalid_request_error"), (400, _), (404, _), (413, _): return .invalidRequest(msg)
        case (_, "billing_error"), (402, _): return .permission("billing: " + msg)
        default: return status >= 500 ? .server(status: status, message: msg) : .invalidRequest("HTTP \(status): \(msg)")
        }
    }

    /// Reassembles streamed content blocks so the assistant turn can be replayed verbatim.
    struct Accumulator {
        var blocks: [Int: [String: JSONValue]] = [:]
        var text = ""
        var stopReason: String?
        var stopCategory: String?
        var model: String?
        var id: String?
        var usage = TokenUsage()
        var finished = false

        mutating func apply(_ ev: JSONValue) throws -> String? {
            switch ev["type"]?.stringValue {
            case "message_start":
                model = ev.at("message", "model")?.stringValue
                id = ev.at("message", "id")?.stringValue
                usage.inputTokens = ev.at("message", "usage", "input_tokens")?.intValue ?? 0
                usage.cacheReadTokens = ev.at("message", "usage", "cache_read_input_tokens")?.intValue ?? 0
                usage.cacheWriteTokens = ev.at("message", "usage", "cache_creation_input_tokens")?.intValue ?? 0
            case "content_block_start":
                guard let i = ev["index"]?.intValue, let b = ev["content_block"]?.objectValue else { return nil }
                blocks[i] = b
            case "content_block_delta":
                guard let i = ev["index"]?.intValue, let d = ev["delta"] else { return nil }
                var b = blocks[i] ?? [:]
                defer { blocks[i] = b }
                switch d["type"]?.stringValue {
                case "text_delta":
                    let t = d["text"]?.stringValue ?? ""
                    b["text"] = .string((b["text"]?.stringValue ?? "") + t)
                    text += t
                    return t
                case "thinking_delta":
                    b["thinking"] = .string((b["thinking"]?.stringValue ?? "") + (d["thinking"]?.stringValue ?? ""))
                case "signature_delta":
                    b["signature"] = .string((b["signature"]?.stringValue ?? "") + (d["signature"]?.stringValue ?? ""))
                case "input_json_delta":
                    b["_partial_json"] = .string((b["_partial_json"]?.stringValue ?? "") + (d["partial_json"]?.stringValue ?? ""))
                default: break
                }
            case "content_block_stop":
                if let i = ev["index"]?.intValue, var b = blocks[i], let pj = b["_partial_json"]?.stringValue {
                    b["input"] = (try? JSONValue.parse(pj)) ?? .object([:]); b["_partial_json"] = nil; blocks[i] = b
                }
            case "message_delta":
                if let s = ev.at("delta", "stop_reason")?.stringValue { stopReason = s }
                if let c = ev.at("delta", "stop_details", "category")?.stringValue { stopCategory = c }
                if let o = ev.at("usage", "output_tokens")?.intValue { usage.outputTokens = o }
            case "message_stop":
                finished = true
            case "error":
                let type = ev.at("error", "type")?.stringValue
                let msg = ev.at("error", "message")?.stringValue ?? "stream error"
                switch type {
                case "overloaded_error": throw ModelError.overloaded
                case "rate_limit_error": throw ModelError.rateLimited(retryAfter: nil)
                case "api_error": throw ModelError.server(status: 500, message: msg)
                default: throw ModelError.server(status: 500, message: "\(type ?? "error"): \(msg)")
                }
            default: break
            }
            return nil
        }

        func response(defaultModel: String) throws -> ChatResponse {
            if stopReason == "refusal" { throw ModelError.refusal(category: stopCategory) }
            let content = JSONValue.array(blocks.keys.sorted().compactMap { blocks[$0].map { JSONValue.object($0) } })
            let msg = ChatMessage(role: .assistant, parts: [.text(text)], providerContent: content, providerID: "anthropic")
            return ChatResponse(text: text, stopReason: stopReason, model: model ?? defaultModel, usage: usage, message: msg)
        }
    }
}
