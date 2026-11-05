import Foundation
import TagenCore

/// Fallback Codex integration via `codex exec --json` (non-interactive; no approval
/// round-trips — the Codex sandbox is the boundary). Resume: `codex exec resume <id>`.
public struct CodexExecAdapter: CodingAgentAdapter {
    public var provider: AgentProvider { .codex }
    public let executable: String?
    public let environment: [String: String]

    public init(executable: String?, environment: [String: String]) { self.executable = executable; self.environment = environment }

    public func arguments(for spec: AgentTaskSpec) -> [String] {
        let sandbox = spec.permissionProfile == .readOnly ? "read-only" : "workspace-write"
        var a = ["exec", "--json", "--cd", spec.workingDirectory, "--sandbox", sandbox]
        if let m = spec.model, !m.isEmpty { a += ["--model", m] }
        if let r = spec.resumeSessionID { a += ["resume", r] }
        a.append(spec.prompt)
        return a
    }

    public func start(_ spec: AgentTaskSpec, approvals: ApprovalBroker) async -> AgentRun {
        guard let exe = executable else { return FailedAgentRun(AgentLaunchError.notInstalled(.codex)) }
        let run = ProcessAgentRun()
        do { try run.process.launch(ProcessLaunch(executable: exe, arguments: arguments(for: spec), environment: environment, workingDirectory: spec.workingDirectory)) }
        catch { return FailedAgentRun(AgentFailure(kind: .notInstalled, message: "Could not start \(exe): \(error)")) }
        run.emit(.started(pid: run.process.pid))
        run.armTimeout(spec.timeout)
        let parser = CodexExecParser()
        Task {
            var terminal = false
            for await out in run.process.output {
                switch out {
                case .stdout(let line):
                    guard let j = try? JSONValue.parse(line) else { run.emit(.log(line)); continue }
                    for e in parser.handle(j) { if e.isTerminal { terminal = true }; run.emit(e) }
                case .stderr(let l): run.emit(.log(l))
                case .exited(let code):
                    if !terminal {
                        if code == 0, let done = parser.finish() { run.emit(done) } else { run.exitedWithoutResult(code) }
                    }
                }
            }
        }
        return run
    }
}

public final class CodexExecParser: @unchecked Sendable {
    let thread = Locked<String?>(nil)
    let last = Locked("")
    let files = Locked<[String]>([])
    let completed = Locked(false)
    public init() {}

    public func handle(_ j: JSONValue) -> [AgentEvent] {
        let item = j["item"] ?? .null
        let id = item["id"]?.stringValue ?? ""
        switch j["type"]?.stringValue {
        case "thread.started":
            if let t = j["thread_id"]?.stringValue { thread.set(t); return [.session(t)] }
        case "item.started":
            switch item["type"]?.stringValue {
            case "command_execution": return [.toolStarted(id: id, name: "command", detail: Redactor().redact(item["command"]?.stringValue ?? ""))]
            case "mcp_tool_call": return [.toolStarted(id: id, name: "mcp", detail: "\(item["server"]?.stringValue ?? "").\(item["tool"]?.stringValue ?? "")")]
            case "web_search": return [.toolStarted(id: id, name: "web search", detail: item["query"]?.stringValue ?? "")]
            default: break
            }
        case "item.completed":
            switch item["type"]?.stringValue {
            case "agent_message":
                let t = item["text"]?.stringValue ?? ""; last.set(t); return [.message(t)]
            case "reasoning":
                let t = item["text"]?.stringValue ?? ""; return t.isEmpty ? [] : [.reasoning(t)]
            case "command_execution":
                let ok = (item["exit_code"]?.intValue ?? 0) == 0 && item["status"]?.stringValue != "failed"
                return [.toolFinished(id: id, name: "command", success: ok, detail: String((item["aggregated_output"]?.stringValue ?? "").suffix(500)))]
            case "file_change":
                let ps = item["changes"]?.arrayValue?.compactMap { $0["path"]?.stringValue } ?? []
                files.withLock { for p in ps where !$0.contains(p) { $0.append(p) } }
                return [.fileChanged(ps)]
            case "error":
                return [.log("codex: \(item["message"]?.stringValue ?? "")")]
            default: break
            }
        case "turn.completed":
            completed.set(true)
            return [.completed(AgentResult(sessionID: thread.current, finalText: last.current, changedFiles: files.current))]
        case "turn.failed":
            let m = j.at("error", "message")?.stringValue ?? "turn failed"
            return [.failed(AgentFailure(kind: AuthErrorDetector.isAuthError(m) ? .authentication : .agentError, message: m, sessionID: thread.current))]
        case "error":
            let m = j["message"]?.stringValue ?? "error"
            if AuthErrorDetector.isAuthError(m) { return [.failed(AgentFailure(kind: .authentication, message: m, sessionID: thread.current))] }
            return [.log("codex error: \(m)")]
        default: break
        }
        return []
    }

    func finish() -> AgentEvent? {
        completed.current ? nil : .completed(AgentResult(sessionID: thread.current, finalText: last.current, changedFiles: files.current))
    }
}
