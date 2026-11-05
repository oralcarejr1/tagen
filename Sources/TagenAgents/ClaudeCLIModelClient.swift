import Foundation
import TagenCore

/// Model provider backed by the user's Claude subscription through the Claude Code CLI:
/// `claude -p --input-format stream-json --output-format stream-json` with every tool, MCP
/// server, setting source, slash command and session file switched off, so it behaves as a
/// plain model call (text + images in, streamed text out). Billing follows the CLI's own
/// sign-in (claude.ai subscription or a `claude setup-token` token); API-key variables are
/// removed from the child environment so a stray `ANTHROPIC_API_KEY` never bills API credits.
///
/// The CLI has no way to replay assistant turns, so multi-turn requests are flattened into a
/// single user message that carries the earlier turns as a transcript (images kept in place).
public struct ClaudeCLIModelClient: ModelClient {
    public static let providerDisplayName = "Claude subscription (Claude Code)"
    /// Removed from the child environment so the CLI uses the subscription sign-in.
    public static let strippedEnvironmentKeys = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
    public static let notInstalledMessage = "Claude Code CLI not found"

    public var providerName: String { Self.providerDisplayName }
    public let executable: String?
    public let environment: [String: String]
    public let workingDirectory: String

    /// `workingDirectory` should be an empty folder owned by Tagen, so no project
    /// configuration is picked up from wherever the app happens to run.
    public init(executable: String?, environment: [String: String], workingDirectory: String? = nil) {
        self.executable = executable
        var env = environment
        for k in Self.strippedEnvironmentKeys { env.removeValue(forKey: k) }
        self.environment = env
        self.workingDirectory = workingDirectory ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("tagen-claude-cli")
    }

    public static func arguments(_ request: ChatRequest, model: String) -> [String] {
        var a = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                 "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands",
                 "--no-session-persistence", "--max-turns", "1", "--system-prompt", request.system]
        if !model.isEmpty { a += ["--model", model] }
        if let e = request.effort { a += ["--effort", e.rawValue] }
        return a
    }

    /// The single stream-json input line for a request.
    public static func inputLine(_ request: ChatRequest) -> String {
        let msg: JSONValue = ["type": "user", "message": ["role": "user", "content": .array(contentBlocks(request.messages))]]
        return msg.encoded()
    }

    static func contentBlocks(_ messages: [ChatMessage]) -> [JSONValue] {
        func blocks(_ parts: [ContentPart], prefix: String?) -> [JSONValue] {
            var out: [JSONValue] = []
            var pendingPrefix = prefix
            for p in parts {
                switch p {
                case .text(let t):
                    out.append(["type": "text", "text": .string((pendingPrefix ?? "") + t)]); pendingPrefix = nil
                case .image(let d, let mt):
                    if let pp = pendingPrefix { out.append(["type": "text", "text": .string(pp)]); pendingPrefix = nil }
                    out.append(["type": "image", "source": ["type": "base64", "media_type": .string(mt), "data": .string(d.base64EncodedString())]])
                }
            }
            if let pp = pendingPrefix { out.append(["type": "text", "text": .string(pp)]) }
            return out
        }
        guard let last = messages.last else { return [["type": "text", "text": ""]] }
        let earlier = messages.dropLast()
        if earlier.isEmpty { return blocks(last.parts, prefix: nil) }
        var out: [JSONValue] = [["type": "text", "text": "<earlier_conversation>"]]
        for m in earlier { out += blocks(m.parts, prefix: m.role == .user ? "User: " : "Assistant: ") }
        out.append(["type": "text", "text": "</earlier_conversation>\nReply to this latest user message:"])
        out += blocks(last.parts, prefix: nil)
        return out
    }

    static let limitPatterns = ["usage limit", "rate limit", "rate_limit", "limit reached", "hit your limit", "overloaded"]
    static func isLimitError(_ text: String) -> Bool {
        let t = text.lowercased(); return limitPatterns.contains { t.contains($0) }
    }

    /// Maps a failed run (result text, errors, stderr) to a ModelError.
    static func classify(_ text: String) -> ModelError {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if AuthErrorDetector.isAuthError(msg) { return .authentication("Claude Code is not signed in: \(msg)") }
        if isLimitError(msg) { return .rateLimited(retryAfter: nil) }
        return .server(status: 0, message: msg.isEmpty ? "claude reported an error" : String(msg.prefix(500)))
    }

    public func stream(_ request: ChatRequest, model: String) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let exe = executable else {
                continuation.finish(throwing: ModelError.notConfigured(Self.notInstalledMessage)); return
            }
            try? FileManager.default.createDirectory(atPath: workingDirectory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let proc = JSONLProcess()
            let launch = ProcessLaunch(executable: exe, arguments: Self.arguments(request, model: model), environment: environment,
                                       workingDirectory: workingDirectory, stdinText: Self.inputLine(request) + "\n")
            do { try proc.launch(launch) } catch {
                continuation.finish(throwing: ModelError.notConfigured("\(Self.notInstalledMessage): \(error)")); return
            }
            let timedOut = Locked(false)
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(1, request.timeout) * 1_000_000_000))
                if !Task.isCancelled { timedOut.set(true); proc.terminate() }
            }
            let reader = Task {
                var text = "", served = model, assistantError: String?, finished = false
                for await out in proc.output {
                    switch out {
                    case .stdout(let line):
                        guard !finished, let m = try? JSONValue.parse(line) else { continue }
                        switch m["type"]?.stringValue {
                        case "system":
                            if m["subtype"]?.stringValue == "init", let s = m["model"]?.stringValue { served = s }
                        case "stream_event":
                            if m.at("event", "delta", "type")?.stringValue == "text_delta",
                               let d = m.at("event", "delta", "text")?.stringValue, !d.isEmpty,
                               m["parent_tool_use_id"]?.isNull ?? true {
                                text += d; continuation.yield(.textDelta(d))
                            }
                        case "assistant":
                            if let e = m["error"]?.stringValue { assistantError = e }
                        case "result":
                            finished = true
                            let isError = m["is_error"]?.boolValue ?? (m["subtype"]?.stringValue != "success")
                            let result = m["result"]?.stringValue ?? ""
                            if isError {
                                let errors = (m["errors"]?.arrayValue ?? []).compactMap(\.stringValue)
                                let combined = ([result] + errors + [assistantError].compactMap { $0 }).joined(separator: "\n")
                                continuation.finish(throwing: Self.classify(combined))
                            } else {
                                let u = m["usage"]
                                let usage = TokenUsage(inputTokens: u?["input_tokens"]?.intValue ?? 0,
                                                       outputTokens: u?["output_tokens"]?.intValue ?? 0,
                                                       cacheReadTokens: u?["cache_read_input_tokens"]?.intValue ?? 0,
                                                       cacheWriteTokens: u?["cache_creation_input_tokens"]?.intValue ?? 0)
                                let final = text.isEmpty ? result : text
                                if text.isEmpty, !result.isEmpty { continuation.yield(.textDelta(result)) }
                                continuation.yield(.completed(ChatResponse(text: final, stopReason: "end_turn", model: served, usage: usage)))
                                continuation.finish()
                            }
                        default: break
                        }
                    case .stderr:
                        break
                    case .exited(let code):
                        timer.cancel()
                        guard !finished else { break }
                        if timedOut.current { continuation.finish(throwing: ModelError.timeout); break }
                        if Task.isCancelled { continuation.finish(throwing: ModelError.cancelled); break }
                        let stderr = proc.recentStderr.suffix(5).joined(separator: "\n")
                        let detail = ([assistantError].compactMap { $0 } + [stderr]).joined(separator: "\n")
                        let err = Self.classify(detail)
                        if case .server = err {
                            continuation.finish(throwing: ModelError.server(status: 0, message: "claude exited with code \(code)" + (detail.isEmpty ? "" : ": \(detail.prefix(400))")))
                        } else {
                            continuation.finish(throwing: err)
                        }
                    }
                }
                timer.cancel()
            }
            continuation.onTermination = { _ in
                timer.cancel(); reader.cancel(); proc.terminate(grace: 1)
            }
        }
    }
}
