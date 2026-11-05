import Foundation
import TagenCore

/// Model provider backed by the user's ChatGPT subscription through the Codex CLI:
/// `codex exec --json --ephemeral` with the request's system prompt as `developer_instructions`.
///
/// Codex is always an agent, so it cannot be reduced to a bare model call the way Claude Code can.
/// This client switches off everything that could act: the shell tool, code mode (fails closed),
/// apps, plugins, hooks, browser and computer use, web search, AGENTS.md and the user's
/// config/rules; the sandbox is read-only and the working directory an empty folder owned by Tagen.
/// Only the last agent message of the turn is returned (earlier ones are narration). Codex exec does
/// not stream text, so the answer arrives in one piece when the turn completes.
///
/// Billing follows the CLI's ChatGPT sign-in: API-key variables are removed from the child environment.
public struct CodexCLIModelClient: ModelClient {
    public static let providerDisplayName = "ChatGPT subscription (Codex)"
    public static let toolName = "Codex"
    public static let strippedEnvironmentKeys = ["OPENAI_API_KEY", "CODEX_API_KEY"]
    /// Features turned off so the agent cannot run commands or reach other services.
    public static let disabledFeatures = ["shell_tool", "code_mode_host", "apps", "plugins", "hooks", "browser_use", "computer_use"]

    public var providerName: String { Self.providerDisplayName }
    public let executable: String?
    public let environment: [String: String]
    public let workingDirectory: String

    public init(executable: String?, environment: [String: String], workingDirectory: String? = nil) {
        self.executable = executable
        var env = environment
        for k in Self.strippedEnvironmentKeys { env.removeValue(forKey: k) }
        self.environment = env
        self.workingDirectory = workingDirectory ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("tagen-codex-cli")
    }

    /// TOML basic string (what `-c key=value` parses).
    static func toml(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    public static func arguments(_ request: ChatRequest, model: String, workingDirectory: String, imagePaths: [String]) -> [String] {
        var a = ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                 "--sandbox", "read-only", "--cd", workingDirectory]
        for f in disabledFeatures { a += ["--disable", f] }
        a += ["-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0",
              "-c", "developer_instructions=\(toml(request.system))"]
        if let e = request.effort { a += ["-c", "model_reasoning_effort=\(toml(e.rawValue))"] }
        if !model.isEmpty { a += ["--model", model] }
        for p in imagePaths { a += ["--image", p] }
        a.append("-")   // prompt on stdin
        return a
    }

    /// Prompt text plus the images to attach, in order. Images are referred to as [image N].
    public static func prompt(_ messages: [ChatMessage]) -> (text: String, images: [(data: Data, mediaType: String)]) {
        var images: [(data: Data, mediaType: String)] = []
        func render(_ parts: [ContentPart]) -> String {
            parts.map { p -> String in
                switch p {
                case .text(let t): return t
                case .image(let d, let mt): images.append((d, mt)); return "[image \(images.count) attached]"
                }
            }.joined(separator: "\n")
        }
        guard let last = messages.last else { return ("", []) }
        let earlier = messages.dropLast()
        if earlier.isEmpty { return (render(last.parts), images) }
        var text = "<earlier_conversation>\n"
        for m in earlier { text += (m.role == .user ? "User: " : "Assistant: ") + render(m.parts) + "\n" }
        text += "</earlier_conversation>\nReply to this latest user message:\n" + render(last.parts)
        return (text, images)
    }

    static func fileExtension(_ mediaType: String) -> String {
        switch mediaType { case "image/jpeg": return "jpg"; case "image/gif": return "gif"; case "image/webp": return "webp"; default: return "png" }
    }

    public func stream(_ request: ChatRequest, model: String) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let cwd = workingDirectory, env = environment
        let (text, images) = Self.prompt(request.messages)
        // Images go to a private folder outside the working directory, deleted when the request ends.
        let imageDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("tagen-codex-img-\(UUID().uuidString.prefix(8))")
        return CLIModelRun.stream(tool: Self.toolName, executable: executable, timeout: request.timeout,
                                  parser: CodexModelOutputParser(requestedModel: model), makeLaunch: { exe in
            let fm = FileManager.default
            try? fm.createDirectory(atPath: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var paths: [String] = []
            if !images.isEmpty {
                try? fm.createDirectory(atPath: imageDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for (i, img) in images.enumerated() {
                    let p = (imageDir as NSString).appendingPathComponent("image-\(i + 1).\(Self.fileExtension(img.mediaType))")
                    if fm.createFile(atPath: p, contents: img.data, attributes: [.posixPermissions: 0o600]) { paths.append(p) }
                }
            }
            return ProcessLaunch(executable: exe, arguments: Self.arguments(request, model: model, workingDirectory: cwd, imagePaths: paths),
                                 environment: env, workingDirectory: cwd, stdinText: text)
        }, onEnd: { try? FileManager.default.removeItem(atPath: imageDir) })
    }
}

/// `codex exec --json` events → the turn's last agent message (earlier ones are narration).
/// Codex exec does not stream text, so the answer is delivered in one piece.
final class CodexModelOutputParser: CLIModelOutputParser {
    private var lastMessage = ""
    private let requestedModel: String

    init(requestedModel: String) { self.requestedModel = requestedModel }

    func handle(_ j: JSONValue, _ out: CLIModelOutput) {
        switch j["type"]?.stringValue {
        case "item.completed":
            if j.at("item", "type")?.stringValue == "agent_message", let t = j.at("item", "text")?.stringValue { lastMessage = t }
        case "error":
            if let m = j["message"]?.stringValue { out.note(m) }
        case "turn.failed":
            out.fail(reported: j.at("error", "message")?.stringValue ?? out.notedErrors.last ?? "turn failed")
        case "turn.completed":
            guard !lastMessage.isEmpty else { out.fail(.decoding("Codex finished without an answer")); return }
            let u = j["usage"]
            out.delta(lastMessage)
            out.complete(ChatResponse(text: lastMessage, stopReason: "end_turn", model: requestedModel.isEmpty ? "codex default" : requestedModel,
                                      usage: TokenUsage(inputTokens: u?["input_tokens"]?.intValue ?? 0, outputTokens: u?["output_tokens"]?.intValue ?? 0,
                                                        cacheReadTokens: u?["cached_input_tokens"]?.intValue ?? 0)))
        default: break
        }
    }
}
