import Foundation
import TagenCore

/// Codex integration through `codex app-server` (bidirectional JSONL JSON-RPC over stdio;
/// the "jsonrpc" header is omitted on the wire). Lifecycle used here:
///   initialize → initialized → [account/read] → thread/start | thread/resume → turn/start
///   ← turn/started, item/*, item/agentMessage/delta, turn/completed
///   ← server requests item/commandExecution/requestApproval, item/fileChange/requestApproval
///     (legacy: execCommandApproval, applyPatchApproval) answered with a decision
///   → turn/interrupt to cancel.
/// Verified against `codex app-server generate-ts` / `generate-json-schema` from codex-cli 0.166.0
/// (see docs/research/codex-claude-protocols.md). Re-check when upgrading Codex.
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
                            switch await Self.handleServerRequest(method: method, params: msg["params"] ?? .null, spec: spec,
                                                                          approvals: approvals, run: run, session: session) {
                            case .result(let r): rpc.respond(id: id, result: r)
                            case .error(let code, let m): rpc.respondError(id: id, code: code, message: m)
                            }
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
                _ = try await rpc.request("initialize", ["clientInfo": ["name": "tagen", "title": "Tagen", "version": .string(clientVersion)],
                                                         "capabilities": .null])
                rpc.notify("initialized", nil)
                if let acct = try? await rpc.request("account/read", .object([:]), timeout: 10),
                   acct["requiresOpenaiAuth"]?.boolValue == true, acct["account"]?.isNull ?? true {
                    // Observed with codex 0.166: signed-out → {"account":null,"requiresOpenaiAuth":true}.
                    // An API key passed via environment may not show up as an account, so only fail fast without one.
                    if Self.hasEnvironmentCredential(environment) {
                        run.emit(.log("Codex reports no stored login; using the API key from the environment"))
                    } else {
                        run.fail(.authentication, "Codex is not signed in. Run `codex login` (or store an API key in Settings › Agents).")
                        run.process.terminate(); return
                    }
                }
                let pol = Self.policy(spec.permissionProfile)
                let threadResult: JSONValue
                if let resume = spec.resumeSessionID {
                    threadResult = try await rpc.request("thread/resume", ["threadId": .string(resume), "excludeTurns": true])
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
                let turnResult = try await rpc.request("turn/start", ["threadId": .string(tid),
                                                                     "input": [["type": "text", "text": .string(spec.prompt), "text_elements": []]]])
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

    static func hasEnvironmentCredential(_ env: [String: String]) -> Bool {
        ["CODEX_API_KEY", "OPENAI_API_KEY"].contains { !(env[$0] ?? "").isEmpty }
    }

    enum ServerReply: Equatable { case result(JSONValue), error(Int, String) }

    /// Decision payloads per app-server schema (codex 0.166):
    ///  v2 command:  "accept" | "acceptForSession" | "decline" | "cancel"
    ///  v2 file:     "accept" | "acceptForSession" | "decline" | "cancel"
    ///  legacy:      "approved" | "approved_for_session" | {"denied":{"rejection":…}} | "abort"
    static func decisionPayload(_ d: ApprovalDecision?, legacy: Bool, reason: String = "") -> JSONValue {
        switch (d, legacy) {
        case (.approved?, false): return ["decision": "accept"]
        case (.approvedForTask?, false): return ["decision": "acceptForSession"]
        case (_, false): return ["decision": "decline"]
        case (.approved?, true): return ["decision": "approved"]
        case (.approvedForTask?, true): return ["decision": "approved_for_session"]
        case (_, true): return ["decision": ["denied": ["rejection": .string(reason.isEmpty ? "Denied in Tagen" : reason)]]]
        }
    }

    static func handleServerRequest(method: String, params: JSONValue, spec: AgentTaskSpec, approvals: ApprovalBroker,
                                    run: ProcessAgentRun, session: CodexSessionState) async -> ServerReply {
        let legacy = method == "execCommandApproval" || method == "applyPatchApproval"
        let isCommand = method == "item/commandExecution/requestApproval" || method == "execCommandApproval"
        let isFile = method == "item/fileChange/requestApproval" || method == "applyPatchApproval"
        guard isCommand || isFile else {
            // e.g. item/tool/requestUserInput, mcpServer/elicitation/request, item/permissions/requestApproval:
            // not supported by Tagen yet — answer with a JSON-RPC error instead of a malformed result.
            run.emit(.log("unsupported server request \(method); replied with an error"))
            return .error(-32601, "Tagen does not support \(method)")
        }
        let id = params["itemId"]?.stringValue ?? params["callId"]?.stringValue ?? UUID().uuidString
        var risk: RiskLevel
        var reasons: [String]
        var detail: String
        if isCommand {
            let cmd: String = params["command"]?.stringValue ?? (params["command"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ") ?? "")
            (risk, reasons) = CommandRisk.assess(command: cmd)
            if params["kind"]?.stringValue == "writeStdin" { reasons.append("writes to a running process") }
            detail = Redactor().redact(cmd) + (params["cwd"]?.stringValue.map { "  (in \($0))" } ?? "")
        } else {
            // v2 file approvals carry no paths: they come from the fileChange item announced earlier.
            let legacyPaths = params["fileChanges"]?.objectValue.map { Array($0.keys).sorted() } ?? []
            let paths = legacy ? legacyPaths : (session.itemPaths.current[id] ?? [])
            let outside = paths.filter { !CommandRisk.isInside($0, spec.workingDirectory) }
            risk = outside.isEmpty ? .medium : .high
            reasons = outside.isEmpty ? ["edits files in the project"] : ["edits files outside the project"]
            if paths.isEmpty { risk = .high; reasons = ["file changes with unknown paths"] }
            if let root = params["grantRoot"]?.stringValue { risk = .high; reasons.append("requests write access to \(root)") }
            detail = paths.isEmpty ? (params["reason"]?.stringValue ?? "file changes") : paths.joined(separator: ", ")
            if spec.permissionProfile == .autoEditsInProject && risk == .medium {
                return .result(decisionPayload(.approved, legacy: legacy))
            }
        }
        if let why = params["reason"]?.stringValue { reasons.append("agent says: \(why)") }
        if spec.permissionProfile == .readOnly && isFile {
            return .result(decisionPayload(.denied(reason: "read-only task"), legacy: legacy, reason: "Tagen: this task is read-only"))
        }
        run.emit(.approvalRequested(id: id, title: (isCommand ? "Run: " : "Edit: ") + detail, risk: risk))
        let decision = await approvals.request(ApprovalRequest(kind: isCommand ? .agentCommand : .agentFileChange,
                                                               title: isCommand ? "Codex wants to run a command" : "Codex wants to change files",
                                                               detail: detail, risk: risk, reasons: reasons, source: "codex"))
        run.emit(.approvalResolved(id: id, approved: decision.isApproved))
        var why = ""
        if case .denied(let r) = decision { why = "Denied in Tagen: \(r)" }
        return .result(decisionPayload(decision, legacy: legacy, reason: why))
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
            case "fileChange":
                let ps = Self.paths(item)
                session.itemPaths.withLock { $0[itemID] = ps }
                return [.toolStarted(id: itemID, name: "edit", detail: ps.joined(separator: ", "))]
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
    /// fileChange item id → paths (v2 file approvals reference the item instead of listing paths).
    let itemPaths = Locked<[String: [String]]>([:])
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

    func respondError(id: JSONValue, code: Int, message: String) {
        process.writeLine(JSONValue.object(["id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]).encoded())
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
