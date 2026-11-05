import Foundation
import TagenCore

/// Codex integration through `codex app-server` (bidirectional JSONL JSON-RPC over stdio;
/// the "jsonrpc" header is omitted on the wire). Lifecycle used here:
///   initialize → initialized → [account/read] → thread/start | thread/resume → turn/start
///   ← turn/started, item/*, item/agentMessage/delta, turn/completed
///   ← server requests item/commandExecution/requestApproval, item/fileChange/requestApproval
///     (legacy: execCommandApproval, applyPatchApproval) answered with a decision
///   → turn/interrupt to cancel.
/// Field names should be re-checked against `codex app-server generate-json-schema` for the
/// installed Codex version (see docs/research/codex-claude-protocols.md).
public struct CodexAppServerAdapter: CodingAgentAdapter {
    public var provider: AgentProvider { .codex }
    public let executable: String?
    public let environment: [String: String]
    public let clientVersion: String
    public let requestTimeout: Double

    public init(executable: String?, environment: [String: String], clientVersion: String = "0.1.0", requestTimeout: Double = 60) {
        self.executable = executable; self.environment = environment; self.clientVersion = clientVersion; self.requestTimeout = requestTimeout
    }

    public static func policy(_ p: AgentPermissionProfile) -> (approval: String, sandbox: String) {
        switch p {
        case .readOnly: return ("on-request", "read-only")
        case .askEveryTime: return ("untrusted", "workspace-write")
        case .autoEditsInProject: return ("on-request", "workspace-write")
        }
    }

    public func start(_ spec: AgentTaskSpec, approvals: ApprovalBroker) async -> AgentRun {
        guard let exe = executable else { return FailedAgentRun(AgentLaunchError.notInstalled(.codex)) }
        let run = ProcessAgentRun()
        let rpc = JSONRPCPeer(process: run.process, timeout: requestTimeout)
        do {
            try run.process.launch(ProcessLaunch(executable: exe, arguments: ["app-server"], environment: environment,
                                                 workingDirectory: spec.workingDirectory, keepStdinOpen: true))
        } catch {
            return FailedAgentRun(AgentFailure(kind: .notInstalled, message: "Could not start \(exe): \(error)"))
        }
        run.emit(.started(pid: run.process.pid))
        run.armTimeout(spec.timeout)
        let session = CodexSessionState()

        run.onCancel = {
            if let t = session.threadID.current, let turn = session.turnID.current {
                _ = try? await rpc.request("turn/interrupt", ["threadId": .string(t), "turnId": .string(turn)], timeout: 3)
            }
        }

        // Reader loop: routes responses, server requests, notifications.
        Task {
            for await out in run.process.output {
                switch out {
                case .stdout(let line):
                    guard let msg = try? JSONValue.parse(line) else { run.emit(.log(line)); continue }
                    if rpc.handleResponse(msg) { continue }
                    if let method = msg["method"]?.stringValue {
                        if let id = msg["id"] {
                            let reply = await Self.handleServerRequest(method: method, params: msg["params"] ?? .null, spec: spec,
                                                                       approvals: approvals, run: run)
                            rpc.respond(id: id, result: reply)
                        } else {
                            for e in Self.handleNotification(method: method, params: msg["params"] ?? .null, session: session) { run.emit(e) }
                            if session.turnFinished.current { run.process.closeStdin(); run.process.terminate(grace: 4) }
                        }
                    }
                case .stderr(let l): run.emit(.log(l))
                case .exited(let code):
                    rpc.failAll(AgentFailure(kind: .processCrashed, message: "app-server exited (\(code))", exitCode: code))
                    if !session.turnFinished.current { run.exitedWithoutResult(code) }
                }
            }
        }

        // Driver: handshake → thread → turn.
        Task {
            do {
                _ = try await rpc.request("initialize", ["clientInfo": ["name": "tagen", "title": "Tagen", "version": .string(clientVersion)]])
                rpc.notify("initialized", nil)
                if let acct = try? await rpc.request("account/read", .object([:]), timeout: 10),
                   acct["requiresOpenaiAuth"]?.boolValue == true, acct["account"]?.isNull ?? true {
                    run.fail(.authentication, "Codex is not signed in. Run `codex login` (or store an API key in Settings › Agents).")
                    run.process.terminate(); return
                }
                let pol = Self.policy(spec.permissionProfile)
                let threadResult: JSONValue
                if let resume = spec.resumeSessionID {
                    threadResult = try await rpc.request("thread/resume", ["threadId": .string(resume)])
                } else {
                    var p: [String: JSONValue] = ["cwd": .string(spec.workingDirectory), "approvalPolicy": .string(pol.approval), "sandbox": .string(pol.sandbox)]
                    if let m = spec.model, !m.isEmpty { p["model"] = .string(m) }
                    threadResult = try await rpc.request("thread/start", .object(p))
                }
                guard let tid = threadResult.at("thread", "id")?.stringValue ?? threadResult["threadId"]?.stringValue else {
                    run.fail(.protocolError, "thread/start returned no thread id: \(threadResult.encoded().prefix(200))")
                    run.process.terminate(); return
                }
                session.threadID.set(tid)
                run.emit(.session(tid))
                let turnResult = try await rpc.request("turn/start", ["threadId": .string(tid), "input": [["type": "text", "text": .string(spec.prompt)]]])
                if let turn = turnResult.at("turn", "id")?.stringValue { session.turnID.set(turn) }
            } catch let f as AgentFailure {
                let kind: AgentFailureKind = AuthErrorDetector.isAuthError(f.message) ? .authentication : f.kind
                run.fail(kind, f.message, exit: f.exitCode)
                run.process.terminate()
            } catch {
                run.fail(.protocolError, "\(error)")
                run.process.terminate()
            }
        }
        return run
    }

    static func handleServerRequest(method: String, params: JSONValue, spec: AgentTaskSpec, approvals: ApprovalBroker, run: ProcessAgentRun) async -> JSONValue {
        let legacy = method == "execCommandApproval" || method == "applyPatchApproval"
        let isCommand = method.contains("commandExecution") || method == "execCommandApproval"
        let isFile = method.contains("fileChange") || method == "applyPatchApproval"
        guard isCommand || isFile else {
            run.emit(.log("unsupported server request \(method); declining"))
            return legacy ? ["decision": "denied"] : ["decision": "decline"]
        }
        let id = params["itemId"]?.stringValue ?? params["callId"]?.stringValue ?? UUID().uuidString
        var risk: RiskLevel
        var reasons: [String]
        var detail: String
        if isCommand {
            let cmd: String = params["command"]?.stringValue ?? (params["command"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ") ?? "")
            (risk, reasons) = CommandRisk.assess(command: cmd)
            detail = Redactor().redact(cmd) + (params["cwd"]?.stringValue.map { "  (in \($0))" } ?? "")
        } else {
            let paths = (params["changes"]?.objectValue.map { Array($0.keys) } ?? params["changes"]?.arrayValue?.compactMap { $0["path"]?.stringValue }) ?? []
            let outside = paths.filter { !CommandRisk.isInside($0, spec.workingDirectory) }
            risk = outside.isEmpty ? .medium : .high
            reasons = outside.isEmpty ? ["edits files in the project"] : ["edits files outside the project"]
            if params["grantRoot"]?.stringValue != nil { risk = .high; reasons.append("requests write access to a new root") }
            detail = paths.isEmpty ? (params["reason"]?.stringValue ?? "file changes") : paths.joined(separator: ", ")
            if spec.permissionProfile == .autoEditsInProject && risk == .medium {
                return legacy ? ["decision": "approved"] : ["decision": "accept"]
            }
        }
        if let why = params["reason"]?.stringValue { reasons.append("agent says: \(why)") }
        if spec.permissionProfile == .readOnly && isFile {
            return legacy ? ["decision": "denied"] : ["decision": "decline"]
        }
        run.emit(.approvalRequested(id: id, title: (isCommand ? "Run: " : "Edit: ") + detail, risk: risk))
        let decision = await approvals.request(ApprovalRequest(kind: isCommand ? .agentCommand : .agentFileChange,
                                                               title: isCommand ? "Codex wants to run a command" : "Codex wants to change files",
                                                               detail: detail, risk: risk, reasons: reasons, source: "codex"))
        run.emit(.approvalResolved(id: id, approved: decision.isApproved))
        if legacy { return ["decision": decision.isApproved ? "approved" : "denied"] }
        return ["decision": decision.isApproved ? "accept" : "decline"]
    }

    static func handleNotification(method: String, params: JSONValue, session: CodexSessionState) -> [AgentEvent] {
        let item = params["item"] ?? .null
        let itemID = item["id"]?.stringValue ?? params["itemId"]?.stringValue ?? ""
        switch method {
        case "turn/started":
            if let t = params.at("turn", "id")?.stringValue { session.turnID.set(t) }
            return []
        case "item/agentMessage/delta":
            return [.messageDelta(params["delta"]?.stringValue ?? "")]
        case "item/commandExecution/outputDelta":
            return [.toolOutput(id: itemID, text: params["delta"]?.stringValue ?? "")]
        case "item/started":
            switch item["type"]?.stringValue {
            case "commandExecution": return [.toolStarted(id: itemID, name: "command", detail: Redactor().redact(Self.commandText(item)))]
            case "fileChange": return [.toolStarted(id: itemID, name: "edit", detail: Self.paths(item).joined(separator: ", "))]
            case "mcpToolCall": return [.toolStarted(id: itemID, name: "mcp", detail: "\(item["server"]?.stringValue ?? "").\(item["tool"]?.stringValue ?? "")")]
            case "webSearch": return [.toolStarted(id: itemID, name: "web search", detail: item["query"]?.stringValue ?? "")]
            default: return []
            }
        case "item/completed":
            switch item["type"]?.stringValue {
            case "agentMessage":
                let t = item["text"]?.stringValue ?? ""
                session.lastMessage.set(t)
                return [.message(t)]
            case "reasoning":
                let s = (item["summary"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "\n")) ?? item["text"]?.stringValue ?? ""
                return s.isEmpty ? [] : [.reasoning(s)]
            case "commandExecution":
                let exit = item["exitCode"]?.intValue
                let ok = (exit ?? 0) == 0 && item["status"]?.stringValue != "failed" && item["status"]?.stringValue != "declined"
                let output = item["aggregatedOutput"]?.stringValue ?? ""
                return [.toolFinished(id: itemID, name: "command", success: ok, detail: String(output.suffix(500)))]
            case "fileChange":
                let ps = Self.paths(item)
                session.files.withLock { for p in ps where !$0.contains(p) { $0.append(p) } }
                let ok = item["status"]?.stringValue != "failed" && item["status"]?.stringValue != "declined"
                return [.fileChanged(ps), .toolFinished(id: itemID, name: "edit", success: ok, detail: ps.joined(separator: ", "))]
            case "mcpToolCall", "webSearch":
                return [.toolFinished(id: itemID, name: item["type"]?.stringValue ?? "tool", success: item["status"]?.stringValue != "failed", detail: "")]
            default: return []
            }
        case "turn/completed":
            session.turnFinished.set(true)
            let status = params.at("turn", "status")?.stringValue ?? "completed"
            let tid = session.threadID.current
            switch status {
            case "completed":
                return [.completed(AgentResult(sessionID: tid, finalText: session.lastMessage.current, changedFiles: session.files.current))]
            case "interrupted":
                return [.failed(AgentFailure(kind: .cancelled, message: "Turn interrupted", sessionID: tid))]
            default:
                let msg = params.at("turn", "error", "message")?.stringValue ?? "turn \(status)"
                return [.failed(AgentFailure(kind: AuthErrorDetector.isAuthError(msg) ? .authentication : .agentError, message: msg, sessionID: tid))]
            }
        case "error":
            let msg = params.at("error", "message")?.stringValue ?? params["message"]?.stringValue ?? "error"
            return [.log("codex error: \(msg)" + ((params["willRetry"]?.boolValue ?? false) ? " (retrying)" : ""))]
        default:
            return []
        }
    }

    static func commandText(_ item: JSONValue) -> String {
        item["command"]?.stringValue ?? item["command"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ") ?? ""
    }
    static func paths(_ item: JSONValue) -> [String] {
        (item["changes"]?.arrayValue?.compactMap { $0["path"]?.stringValue }) ?? item["changes"]?.objectValue.map { Array($0.keys).sorted() } ?? []
    }
}

final class CodexSessionState: Sendable {
    let threadID = Locked<String?>(nil)
    let turnID = Locked<String?>(nil)
    let lastMessage = Locked<String>("")
    let files = Locked<[String]>([])
    let turnFinished = Locked(false)
}

/// JSON-RPC request/response correlation over a JSONLProcess.
final class JSONRPCPeer: @unchecked Sendable {
    private let process: JSONLProcess
    private let timeout: Double
    private let nextID = Locked(0)
    private let pending = Locked<[Int: CheckedContinuation<JSONValue, Error>]>([:])

    init(process: JSONLProcess, timeout: Double) { self.process = process; self.timeout = timeout }

    func request(_ method: String, _ params: JSONValue?, timeout: Double? = nil) async throws -> JSONValue {
        let id = nextID.withLock { v -> Int in v += 1; return v }
        var msg: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(method)]
        if let p = params { msg["params"] = p }
        let to = timeout ?? self.timeout
        let line = JSONValue.object(msg).encoded()
        do {
            let pending = self.pending
            let process = self.process
            return try await withTimeout(seconds: to, operation: method) {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSONValue, Error>) in
                        pending.withLock { $0[id] = c }
                        process.writeLine(line)
                    }
                } onCancel: {
                    // Resume so the timeout task group can finish (it awaits all children).
                    if let c = pending.withLock({ $0.removeValue(forKey: id) }) { c.resume(throwing: CancellationError()) }
                }
            }
        } catch let e as TimeoutError {
            // Drop the orphaned continuation so a late response is ignored.
            if let c = pending.withLock({ $0.removeValue(forKey: id) }) { c.resume(throwing: e) }
            throw AgentFailure(kind: .protocolError, message: "\(method) timed out after \(Int(to))s")
        }
    }

    func notify(_ method: String, _ params: JSONValue?) {
        var msg: [String: JSONValue] = ["method": .string(method)]
        if let p = params { msg["params"] = p }
        process.writeLine(JSONValue.object(msg).encoded())
    }

    func respond(id: JSONValue, result: JSONValue) {
        process.writeLine(JSONValue.object(["id": id, "result": result]).encoded())
    }

    /// Returns true if `msg` was a response to one of our requests.
    func handleResponse(_ msg: JSONValue) -> Bool {
        guard msg["method"] == nil, let id = msg["id"]?.intValue else { return false }
        guard let c = pending.withLock({ $0.removeValue(forKey: id) }) else { return true }
        if let err = msg["error"] {
            let m = err["message"]?.stringValue ?? err.encoded()
            c.resume(throwing: AgentFailure(kind: AuthErrorDetector.isAuthError(m) ? .authentication : .protocolError, message: m))
        } else {
            c.resume(returning: msg["result"] ?? .null)
        }
        return true
    }

    func failAll(_ f: AgentFailure) {
        let all = pending.withLock { p -> [CheckedContinuation<JSONValue, Error>] in let v = Array(p.values); p.removeAll(); return v }
        for c in all { c.resume(throwing: f) }
    }
}
