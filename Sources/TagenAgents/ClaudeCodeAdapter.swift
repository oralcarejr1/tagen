import Foundation
import TagenCore

/// Claude Code integration through its supported headless interface (message and permission
/// shapes checked against @anthropic-ai/claude-agent-sdk 0.3.318 type definitions):
/// `claude -p --output-format stream-json --verbose` (prompt on stdin), `--resume <id>`,
/// `--permission-mode`, and `--permission-prompt-tool mcp__tagen__approve` backed by the
/// bundled `tagen-approval-mcp` relay so permission prompts surface in Tagen's UI.
public struct ClaudeCodeAdapter: CodingAgentAdapter {
    public var provider: AgentProvider { .claudeCode }
    public let executable: String?
    public let environment: [String: String]
    public let approvalMCPPath: String?
    public let runtimeDirectory: String
    public let includePartialMessages: Bool

    public init(executable: String?, environment: [String: String], approvalMCPPath: String?,
                runtimeDirectory: String = NSTemporaryDirectory(), includePartialMessages: Bool = true) {
        self.executable = executable; self.environment = environment; self.approvalMCPPath = approvalMCPPath
        self.runtimeDirectory = runtimeDirectory; self.includePartialMessages = includePartialMessages
    }

    public static func permissionMode(_ p: AgentPermissionProfile) -> String {
        switch p {
        case .readOnly: return "plan"
        case .askEveryTime: return "default"
        case .autoEditsInProject: return "acceptEdits"
        }
    }

    public func arguments(for spec: AgentTaskSpec, mcpConfigPath: String?) -> [String] {
        var a = ["-p", "--output-format", "stream-json", "--verbose"]
        if includePartialMessages { a.append("--include-partial-messages") }
        a += ["--permission-mode", Self.permissionMode(spec.permissionProfile)]
        if let r = spec.resumeSessionID { a += ["--resume", r] }
        if let m = spec.model, !m.isEmpty { a += ["--model", m] }
        if let t = spec.maxTurns { a += ["--max-turns", String(t)] }
        if let cfg = mcpConfigPath {
            a += ["--mcp-config", cfg, "--permission-prompt-tool", "mcp__\(ApprovalMCPServer.serverName)__\(ApprovalMCPServer.toolName)"]
        }
        return a
    }

    public func start(_ spec: AgentTaskSpec, approvals: ApprovalBroker) async -> AgentRun {
        guard let exe = executable else { return FailedAgentRun(AgentLaunchError.notInstalled(.claudeCode)) }
        let run = ProcessAgentRun()
        let parser = ClaudeStreamParser(workingDirectory: spec.workingDirectory)

        // Approval relay (optional; without it Claude Code denies prompts and reports them).
        var relay: ApprovalRelayServer?
        var mcpConfigPath: String?
        var tempFiles: [String] = []
        if let mcp = approvalMCPPath, FileManager.default.isExecutableFile(atPath: mcp) {
            let short = String(UUID().uuidString.prefix(8))
            let sock = (runtimeDirectory as NSString).appendingPathComponent("tg-\(short).sock")
            let profile = spec.permissionProfile
            let cwd = spec.workingDirectory
            let server = ApprovalRelayServer(socketPath: sock) { [weak run] req in
                await Self.decide(req, profile: profile, cwd: cwd, approvals: approvals, run: run)
            }
            do {
                try server.start()
                let cfg: JSONValue = ["mcpServers": [ApprovalMCPServer.serverName: [
                    "command": .string(mcp), "args": ["--socket", .string(sock), "--token-env", "TAGEN_RELAY_TOKEN"],
                    "env": ["TAGEN_RELAY_TOKEN": .string(server.token)],
                ]]]
                let path = (runtimeDirectory as NSString).appendingPathComponent("tg-\(short)-mcp.json")
                _ = FileManager.default.createFile(atPath: path, contents: Data(cfg.encoded().utf8), attributes: [.posixPermissions: 0o600])
                relay = server; mcpConfigPath = path; tempFiles.append(path)
            } catch {
                run.emit(.log("approval relay unavailable: \(error)"))
            }
        }

        let launch = ProcessLaunch(executable: exe, arguments: arguments(for: spec, mcpConfigPath: mcpConfigPath),
                                   environment: environment, workingDirectory: spec.workingDirectory, stdinText: spec.prompt)
        do { try run.process.launch(launch) }
        catch {
            relay?.stop(); tempFiles.forEach { try? FileManager.default.removeItem(atPath: $0) }
            return FailedAgentRun(AgentFailure(kind: .notInstalled, message: "Could not start \(exe): \(error)"))
        }
        run.emit(.started(pid: run.process.pid))
        run.armTimeout(spec.timeout)

        Task {
            var sawResult = false
            for await out in run.process.output {
                switch out {
                case .stdout(let line):
                    guard let json = try? JSONValue.parse(line) else { run.emit(.log(line)); continue }
                    for e in parser.handle(json) {
                        if e.isTerminal { sawResult = true }
                        run.emit(e)
                    }
                case .stderr(let line):
                    run.emit(.log(line))
                case .exited(let code):
                    if !sawResult { run.exitedWithoutResult(code) }
                }
            }
            relay?.stop()
            tempFiles.forEach { try? FileManager.default.removeItem(atPath: $0) }
        }
        return run
    }

    static func decide(_ req: RelayApprovalRequest, profile: AgentPermissionProfile, cwd: String, approvals: ApprovalBroker, run: ProcessAgentRun?) async -> RelayDecision {
        let (risk, reasons) = CommandRisk.assess(tool: req.toolName, input: req.input, workingDirectory: cwd)
        if profile == .readOnly && !(risk == .low) { return .deny(message: "Tagen: this task is read-only") }
        if risk == .low { return .allow(updatedInput: req.input) }
        let id = req.toolUseID ?? UUID().uuidString
        let detail = ClaudeStreamParser.describe(tool: req.toolName, input: req.input)
        run?.emit(.approvalRequested(id: id, title: "\(req.toolName): \(detail)", risk: risk))
        let decision = await approvals.request(ApprovalRequest(kind: req.toolName == "Bash" ? .agentCommand : .agentTool,
                                                               title: "Claude Code wants to use \(req.toolName)", detail: detail,
                                                               risk: risk, reasons: reasons, source: "claude-code"))
        run?.emit(.approvalResolved(id: id, approved: decision.isApproved))
        if decision.isApproved { return .allow(updatedInput: req.input) }
        if case .denied(let r) = decision { return .deny(message: "The user denied this in Tagen: \(r)") }
        return .deny(message: "Denied in Tagen")
    }
}

/// Stateful parser for Claude Code stream-json output.
public final class ClaudeStreamParser: @unchecked Sendable {
    private let toolNames = Locked<[String: String]>([:])
    private let files = Locked<[String]>([])
    private let lastText = Locked<String>("")
    private let sessionID = Locked<String?>(nil)
    /// Last SDKAssistantMessageError seen (e.g. "authentication_failed"), used to classify the result.
    private let assistantError = Locked<String?>(nil)
    let workingDirectory: String

    public init(workingDirectory: String) { self.workingDirectory = workingDirectory }

    public func handle(_ m: JSONValue) -> [AgentEvent] {
        var out: [AgentEvent] = []
        if let s = m["session_id"]?.stringValue, sessionID.current != s {
            sessionID.set(s); out.append(.session(s))
        }
        switch m["type"]?.stringValue {
        case "system":
            if let sub = m["subtype"]?.stringValue, sub != "init" {
                if sub == "api_retry", let err = m["error"]?.stringValue, AuthErrorDetector.isAuthError(err) {
                    out.append(.log("authentication problem: \(err)"))
                } else if sub == "permission_denied", let tool = m["tool_name"]?.stringValue {
                    out.append(.log("permission denied: \(tool)"))
                } else {
                    out.append(.log("system: \(sub)"))
                }
            }
        case "stream_event":
            if m.at("event", "delta", "type")?.stringValue == "text_delta", let t = m.at("event", "delta", "text")?.stringValue,
               m["parent_tool_use_id"]?.isNull ?? true {
                out.append(.messageDelta(t))
            }
        case "assistant":
            if let err = m["error"]?.stringValue {
                assistantError.set(err)
                out.append(.log("assistant error: \(err)"))
            }
            for block in m.at("message", "content")?.arrayValue ?? [] {
                switch block["type"]?.stringValue {
                case "text":
                    if let t = block["text"]?.stringValue, !t.isEmpty, m["parent_tool_use_id"]?.isNull ?? true {
                        lastText.set(t); out.append(.message(t))
                    }
                case "tool_use":
                    let id = block["id"]?.stringValue ?? UUID().uuidString
                    let name = block["name"]?.stringValue ?? "tool"
                    toolNames.withLock { $0[id] = name }
                    let input = block["input"] ?? .object([:])
                    out.append(.toolStarted(id: id, name: name, detail: Self.describe(tool: name, input: input)))
                    if ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(name),
                       let p = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue {
                        files.withLock { if !$0.contains(p) { $0.append(p) } }
                    }
                default: break
                }
            }
        case "user":
            for block in m.at("message", "content")?.arrayValue ?? [] where block["type"]?.stringValue == "tool_result" {
                let id = block["tool_use_id"]?.stringValue ?? ""
                let name = toolNames.current[id] ?? "tool"
                let isError = block["is_error"]?.boolValue ?? false
                let content: String
                if let s = block["content"]?.stringValue { content = s }
                else { content = (block["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n") }
                out.append(.toolFinished(id: id, name: name, success: !isError, detail: String(content.prefix(500))))
                if !isError, ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(name) { out.append(.fileChanged(files.current)) }
            }
        case "result":
            let sub = m["subtype"]?.stringValue ?? "success"
            let isError = m["is_error"]?.boolValue ?? (sub != "success")
            let text = m["result"]?.stringValue ?? ""
            let errors = (m["errors"]?.arrayValue ?? []).compactMap(\.stringValue)
            let denials = (m["permission_denials"]?.arrayValue ?? []).compactMap { d -> String? in
                guard let t = d["tool_name"]?.stringValue else { return nil }
                return t + (d.at("tool_input", "command")?.stringValue.map { ": \($0)" } ?? "")
            }
            let sid = m["session_id"]?.stringValue ?? sessionID.current
            let startup = m["startup_failure_reason"]?.stringValue
            let combined = ([text] + errors + [startup, assistantError.current].compactMap { $0 }).joined(separator: "\n")
            if isError && AuthErrorDetector.isAuthError(combined) {
                out.append(.failed(AgentFailure(kind: .authentication, message: combined.trimmingCharacters(in: .whitespacesAndNewlines), sessionID: sid)))
            } else if sub != "success" && sub != "error_max_turns" {
                var msg = errors.isEmpty ? sub : errors.joined(separator: "\n")
                if let st = startup { msg += " (startup: \(st))" }
                out.append(.failed(AgentFailure(kind: .agentError, message: msg, sessionID: sid)))
            } else {
                let finalText = text.isEmpty ? (sub == "error_max_turns" ? "Stopped: reached the maximum number of turns." : lastText.current) : text
                out.append(.completed(AgentResult(sessionID: sid, finalText: finalText, isError: isError, turns: m["num_turns"]?.intValue,
                                                  costUSD: m["total_cost_usd"]?.doubleValue, durationMs: m["duration_ms"]?.intValue,
                                                  permissionDenials: denials, changedFiles: files.current)))
            }
        default: break
        }
        return out
    }

    public static func describe(tool: String, input: JSONValue) -> String {
        let r = Redactor()
        switch tool {
        case "Bash": return r.redact(input["command"]?.stringValue ?? "")
        case "Read", "Write", "Edit", "MultiEdit": return input["file_path"]?.stringValue ?? ""
        case "NotebookEdit": return input["notebook_path"]?.stringValue ?? ""
        case "Glob", "Grep": return input["pattern"]?.stringValue ?? ""
        case "WebFetch": return input["url"]?.stringValue ?? ""
        case "WebSearch": return input["query"]?.stringValue ?? ""
        case "Task": return input["description"]?.stringValue ?? ""
        default: return r.redact(String(input.encoded().prefix(200)))
        }
    }
}
