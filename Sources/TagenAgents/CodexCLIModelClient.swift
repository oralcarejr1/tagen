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
    public static let strippedEnvironmentKeys = ["OPENAI_API_KEY", "CODEX_API_KEY"]
    public static let notInstalledMessage = "Codex CLI not found"
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

    static func classify(_ text: String) -> ModelError {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if AuthErrorDetector.isAuthError(msg) { return .authentication("Codex is not signed in: \(msg)") }
        if ClaudeCLIModelClient.isLimitError(msg) { return .rateLimited(retryAfter: nil) }
        return .server(status: 0, message: msg.isEmpty ? "codex reported an error" : String(msg.prefix(500)))
    }

    public func stream(_ request: ChatRequest, model: String) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let exe = executable else {
                continuation.finish(throwing: ModelError.notConfigured(Self.notInstalledMessage)); return
            }
            let fm = FileManager.default
            try? fm.createDirectory(atPath: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let (text, images) = Self.prompt(request.messages)
            // Images go to a private folder outside the working directory and are deleted afterwards.
            let imageDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("tagen-codex-img-\(UUID().uuidString.prefix(8))")
            var paths: [String] = []
            if !images.isEmpty {
                try? fm.createDirectory(atPath: imageDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for (i, img) in images.enumerated() {
                    let p = (imageDir as NSString).appendingPathComponent("image-\(i + 1).\(Self.fileExtension(img.mediaType))")
                    if fm.createFile(atPath: p, contents: img.data, attributes: [.posixPermissions: 0o600]) { paths.append(p) }
                }
            }
            let cleanup: @Sendable () -> Void = { try? FileManager.default.removeItem(atPath: imageDir) }
            let proc = JSONLProcess()
            let launch = ProcessLaunch(executable: exe, arguments: Self.arguments(request, model: model, workingDirectory: workingDirectory, imagePaths: paths),
                                       environment: environment, workingDirectory: workingDirectory, stdinText: text)
            do { try proc.launch(launch) } catch {
                cleanup()
                continuation.finish(throwing: ModelError.notConfigured("\(Self.notInstalledMessage): \(error)")); return
            }
            let timedOut = Locked(false)
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(1, request.timeout) * 1_000_000_000))
                if !Task.isCancelled { timedOut.set(true); proc.terminate() }
            }
            let reader = Task {
                var lastMessage = "", lastError: String?, finished = false
                for await out in proc.output {
                    switch out {
                    case .stdout(let line):
                        guard !finished, let j = try? JSONValue.parse(line) else { continue }
                        switch j["type"]?.stringValue {
                        case "item.completed":
                            if j.at("item", "type")?.stringValue == "agent_message", let t = j.at("item", "text")?.stringValue {
                                lastMessage = t
                            }
                        case "error":
                            lastError = j["message"]?.stringValue
                        case "turn.failed":
                            finished = true; cleanup()
                            continuation.finish(throwing: Self.classify(j.at("error", "message")?.stringValue ?? lastError ?? "turn failed"))
                        case "turn.completed":
                            // Images are no longer needed; delete them before the caller sees the answer
                            // (a short-lived caller may exit right after).
                            finished = true; cleanup()
                            let u = j["usage"]
                            let usage = TokenUsage(inputTokens: u?["input_tokens"]?.intValue ?? 0, outputTokens: u?["output_tokens"]?.intValue ?? 0,
                                                   cacheReadTokens: u?["cached_input_tokens"]?.intValue ?? 0)
                            if lastMessage.isEmpty {
                                continuation.finish(throwing: ModelError.decoding("Codex finished without an answer"))
                            } else {
                                continuation.yield(.textDelta(lastMessage))
                                continuation.yield(.completed(ChatResponse(text: lastMessage, stopReason: "end_turn",
                                                                           model: model.isEmpty ? "codex default" : model, usage: usage)))
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
                        let detail = ([lastError].compactMap { $0 } + [stderr]).joined(separator: "\n")
                        let err = Self.classify(detail)
                        if case .server = err {
                            continuation.finish(throwing: ModelError.server(status: 0, message: "codex exited with code \(code)" + (detail.isEmpty ? "" : ": \(detail.prefix(400))")))
                        } else {
                            continuation.finish(throwing: err)
                        }
                    }
                }
                timer.cancel()
                cleanup()
            }
            continuation.onTermination = { _ in
                timer.cancel(); reader.cancel(); proc.terminate(grace: 1); cleanup()
            }
        }
    }
}
