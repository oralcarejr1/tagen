import Foundation

/// Client for OpenAI-compatible Chat Completions endpoints (OpenAI, or local servers such
/// as Ollama / LM Studio exposing `/v1/chat/completions`). Lets the user run a local
/// vision model for privacy-sensitive use. The model name is always user-configured.
public struct OpenAICompatibleClient: ModelClient {
    public var providerName: String { name }
    let name: String
    let apiKey: String?
    let baseURL: URL
    let transport: HTTPTransport
    let retry: RetryPolicy
    let clock: SleepClock

    public init(name: String = "OpenAI-compatible", apiKey: String?, baseURL: URL, transport: HTTPTransport = URLSessionTransport(),
                retry: RetryPolicy = RetryPolicy(), clock: SleepClock = SystemClock()) {
        self.name = name; self.apiKey = apiKey; self.baseURL = baseURL; self.transport = transport
        self.retry = retry; self.clock = clock
    }

    public func buildBody(_ request: ChatRequest, model: String) -> JSONValue {
        var msgs: [JSONValue] = [["role": "system", "content": .string(request.system)]]
        for m in request.messages {
            if m.hasImage {
                let parts: [JSONValue] = m.parts.map { p in
                    switch p {
                    case .text(let t): return ["type": "text", "text": .string(t)]
                    case .image(let d, let mt):
                        return ["type": "image_url", "image_url": ["url": .string("data:\(mt);base64,\(d.base64EncodedString())")]]
                    }
                }
                msgs.append(["role": .string(m.role.rawValue), "content": .array(parts)])
            } else {
                msgs.append(["role": .string(m.role.rawValue), "content": .string(m.text)])
            }
        }
        return ["model": .string(model), "messages": .array(msgs), "stream": true, "max_tokens": .number(Double(request.maxTokens))]
    }

    public func stream(_ request: ChatRequest, model: String) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var headers = ["content-type": "application/json"]
                if let k = apiKey, !k.isEmpty { headers["authorization"] = "Bearer \(k)" }
                let http = HTTPRequest(url: baseURL.appendingPathComponent("chat/completions"), headers: headers,
                                       body: Data(buildBody(request, model: model).encoded().utf8), timeout: request.timeout)
                var attempt = 0
                while true {
                    attempt += 1
                    var emitted = false
                    do {
                        let (head, lines) = try await transport.streamLines(http)
                        if head.status != 200 {
                            var t = ""; for try await l in lines { t += l + "\n" }
                            let json = try? JSONValue.parse(t)
                            let msg = json?.at("error", "message")?.stringValue ?? String(t.prefix(300))
                            switch head.status {
                            case 401: throw ModelError.authentication(msg)
                            case 403: throw ModelError.permission(msg)
                            case 429: throw ModelError.rateLimited(retryAfter: head.headers["retry-after"].flatMap(Double.init))
                            case 500...: throw ModelError.server(status: head.status, message: msg)
                            default: throw ModelError.invalidRequest(msg)
                            }
                        }
                        var text = "", finish: String?, usage = TokenUsage(), served = model
                        var parser = SSEParser()
                        for try await line in lines {
                            try Task.checkCancellation()
                            guard let ev = parser.feedTolerant(line) else { continue }
                            if ev.data == "[DONE]" { break }
                            guard let j = try? JSONValue.parse(ev.data) else { continue }
                            if let m = j["model"]?.stringValue { served = m }
                            if let d = j.at("choices")?[0]?.at("delta", "content")?.stringValue, !d.isEmpty {
                                text += d; emitted = true; continuation.yield(.textDelta(d))
                            }
                            if let f = j.at("choices")?[0]?["finish_reason"]?.stringValue { finish = f }
                            if let u = j["usage"] {
                                usage = TokenUsage(inputTokens: u["prompt_tokens"]?.intValue ?? 0, outputTokens: u["completion_tokens"]?.intValue ?? 0)
                            }
                        }
                        continuation.yield(.completed(ChatResponse(text: text, stopReason: finish, model: served, usage: usage)))
                        continuation.finish(); return
                    } catch is CancellationError {
                        continuation.finish(throwing: ModelError.cancelled); return
                    } catch let e as ModelError {
                        if e.isRetryable, !emitted, attempt < retry.maxAttempts {
                            try? await clock.sleep(seconds: retry.delay(forAttempt: attempt)); continue
                        }
                        continuation.finish(throwing: e); return
                    } catch {
                        if !emitted, attempt < retry.maxAttempts { try? await clock.sleep(seconds: retry.delay(forAttempt: attempt)); continue }
                        continuation.finish(throwing: ModelError.network(error.localizedDescription)); return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
