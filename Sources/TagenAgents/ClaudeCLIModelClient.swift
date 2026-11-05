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
    public static let toolName = "Claude Code"
    /// Removed from the child environment so the CLI uses the subscription sign-in.
    public static let strippedEnvironmentKeys = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]

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

    public func stream(_ request: ChatRequest, model: String) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let cwd = workingDirectory, env = environment
        return CLIModelRun.stream(tool: Self.toolName, executable: executable, timeout: request.timeout,
                                  parser: ClaudeModelOutputParser(requestedModel: model)) { exe in
            try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return ProcessLaunch(executable: exe, arguments: Self.arguments(request, model: model), environment: env,
                                 workingDirectory: cwd, stdinText: Self.inputLine(request) + "\n")
        }
    }
}

/// `claude -p --output-format stream-json` events → text deltas and one response.
final class ClaudeModelOutputParser: CLIModelOutputParser {
    private var text = ""
    private var served: String
    private var assistantError: String?

    init(requestedModel: String) { served = requestedModel }

    func handle(_ m: JSONValue, _ out: CLIModelOutput) {
        switch m["type"]?.stringValue {
        case "system":
            if m["subtype"]?.stringValue == "init", let s = m["model"]?.stringValue { served = s }
        case "stream_event":
            if m.at("event", "delta", "type")?.stringValue == "text_delta", let d = m.at("event", "delta", "text")?.stringValue,
               m["parent_tool_use_id"]?.isNull ?? true {
                text += d; out.delta(d)
            }
        case "assistant":
            if let e = m["error"]?.stringValue { assistantError = e; out.note(e) }
        case "result":
            let result = m["result"]?.stringValue ?? ""
            if m["is_error"]?.boolValue ?? (m["subtype"]?.stringValue != "success") {
                let errors = (m["errors"]?.arrayValue ?? []).compactMap(\.stringValue)
                out.fail(reported: ([result] + errors + [assistantError].compactMap { $0 }).joined(separator: "\n"))
                return
            }
            if text.isEmpty { text = result; out.delta(result) }
            let u = m["usage"]
            out.complete(ChatResponse(text: text, stopReason: "end_turn", model: served, usage: TokenUsage(
                inputTokens: u?["input_tokens"]?.intValue ?? 0, outputTokens: u?["output_tokens"]?.intValue ?? 0,
                cacheReadTokens: u?["cache_read_input_tokens"]?.intValue ?? 0,
                cacheWriteTokens: u?["cache_creation_input_tokens"]?.intValue ?? 0)))
        default: break
        }
    }
}
