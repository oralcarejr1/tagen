import Foundation
import TagenCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Request from the MCP relay (one Claude Code permission prompt).
public struct RelayApprovalRequest: Sendable, Equatable {
    public var toolName: String
    public var input: JSONValue
    public var toolUseID: String?
}

/// Decision returned to Claude Code. Shape follows the permission-prompt-tool contract:
/// {"behavior":"allow","updatedInput":{...}} or {"behavior":"deny","message":"..."}.
public enum RelayDecision: Sendable, Equatable {
    case allow(updatedInput: JSONValue)
    case deny(message: String)

    public var json: JSONValue {
        switch self {
        case .allow(let i): return ["behavior": "allow", "updatedInput": i]
        case .deny(let m): return ["behavior": "deny", "message": .string(m)]
        }
    }
}

/// Unix-socket server (inside the Tagen app) answering approval requests from
/// `tagen-approval-mcp`. Each connection must present the per-run random token.
public final class ApprovalRelayServer: @unchecked Sendable {
    public let socketPath: String
    public let token: String
    private var listenFD: Int32 = -1
    private let handler: @Sendable (RelayApprovalRequest) async -> RelayDecision
    private let running = Locked(false)
    private let clients = Locked<Set<Int32>>([])

    public init(socketPath: String, token: String = UUID().uuidString + UUID().uuidString,
                handler: @escaping @Sendable (RelayApprovalRequest) async -> RelayDecision) {
        self.socketPath = socketPath; self.token = token; self.handler = handler
    }

    public func start() throws {
        listenFD = try UnixSocket.listen(path: socketPath)
        running.set(true)
        let fd = listenFD
        let running = self.running
        let clients = self.clients
        Thread.detachNewThread { [weak self] in
            while running.current {
                let c = accept(fd, nil, nil)
                if c < 0 { if !running.current { break }; continue }
                guard let server = self else { UnixSocket.closeFD(c); break }
                clients.withLock { _ = $0.insert(c) }
                Thread.detachNewThread { server.serve(c) }
            }
        }
    }

    public func stop() {
        running.set(false)
        if listenFD >= 0 { UnixSocket.shutdownFD(listenFD); UnixSocket.closeFD(listenFD); listenFD = -1 }
        for c in clients.current { UnixSocket.shutdownFD(c) }
        unlink(socketPath)
    }

    private func serve(_ fd: Int32) {
        defer { UnixSocket.closeFD(fd); clients.withLock { _ = $0.remove(fd) } }
        while let line = UnixSocket.readLine(fd) {
            let reply: JSONValue
            if let msg = try? JSONValue.parse(line), msg["token"]?.stringValue == token, let tool = msg["tool_name"]?.stringValue {
                let req = RelayApprovalRequest(toolName: tool, input: msg["input"] ?? .object([:]), toolUseID: msg["tool_use_id"]?.stringValue)
                let sem = DispatchSemaphore(value: 0)
                let box = Locked<RelayDecision>(.deny(message: "no decision"))
                let h = handler
                Task { box.set(await h(req)); sem.signal() }
                sem.wait()
                reply = box.current.json
            } else {
                reply = RelayDecision.deny(message: "invalid relay request or token").json
            }
            guard UnixSocket.writeAll(fd, Data((reply.encoded() + "\n").utf8)) else { return }
        }
    }
}

/// Client side used by `tagen-approval-mcp`.
public enum ApprovalRelayClient {
    public static func ask(socketPath: String, token: String, toolName: String, input: JSONValue, toolUseID: String?) -> JSONValue {
        do {
            let fd = try UnixSocket.connect(path: socketPath)
            defer { UnixSocket.closeFD(fd) }
            var msg: [String: JSONValue] = ["token": .string(token), "tool_name": .string(toolName), "input": input]
            if let t = toolUseID { msg["tool_use_id"] = .string(t) }
            guard UnixSocket.writeAll(fd, Data((JSONValue.object(msg).encoded() + "\n").utf8)),
                  let line = UnixSocket.readLine(fd), let reply = try? JSONValue.parse(line) else {
                return RelayDecision.deny(message: "Tagen did not answer the approval request").json
            }
            return reply
        } catch {
            return RelayDecision.deny(message: "Tagen approval service unavailable: \(error)").json
        }
    }
}

/// Minimal MCP (stdio JSON-RPC) server exposing one tool, `approve`, for
/// `claude --permission-prompt-tool mcp__tagen__approve`.
public struct ApprovalMCPServer: Sendable {
    public let socketPath: String
    public let token: String
    public static let toolName = "approve"
    public static let serverName = "tagen"

    public init(socketPath: String, token: String) { self.socketPath = socketPath; self.token = token }

    /// Handle one JSON-RPC message; returns the response to write (nil for notifications).
    public func handle(_ msg: JSONValue) -> JSONValue? {
        let id = msg["id"]
        guard let method = msg["method"]?.stringValue else { return nil }
        func ok(_ result: JSONValue) -> JSONValue { ["jsonrpc": "2.0", "id": id ?? .null, "result": result] }
        switch method {
        case "initialize":
            let pv = msg.at("params", "protocolVersion")?.stringValue ?? "2025-06-18"
            return ok(["protocolVersion": .string(pv), "capabilities": ["tools": .object([:])],
                       "serverInfo": ["name": "tagen-approval", "version": "0.1.0"]])
        case "ping":
            return ok(.object([:]))
        case "tools/list":
            return ok(["tools": [[
                "name": .string(Self.toolName),
                "description": "Ask the Tagen user to approve or deny a Claude Code tool call.",
                "inputSchema": ["type": "object",
                                "properties": ["tool_name": ["type": "string"], "input": ["type": "object"], "tool_use_id": ["type": "string"]],
                                "required": ["tool_name", "input"]],
            ]]])
        case "tools/call":
            guard msg.at("params", "name")?.stringValue == Self.toolName else {
                return ["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": -32602, "message": "unknown tool"]]
            }
            let args = msg.at("params", "arguments") ?? .object([:])
            let decision = ApprovalRelayClient.ask(socketPath: socketPath, token: token, toolName: args["tool_name"]?.stringValue ?? "unknown",
                                                   input: args["input"] ?? .object([:]), toolUseID: args["tool_use_id"]?.stringValue)
            return ok(["content": [["type": "text", "text": .string(decision.encoded())]]])
        default:
            if id == nil { return nil }  // notification
            return ["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": -32601, "message": .string("method not found: \(method)")]]
        }
    }

    public func runStdio() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let msg = try? JSONValue.parse(line) else { continue }
            if let resp = handle(msg) {
                FileHandle.standardOutput.write(Data((resp.encoded() + "\n").utf8))
            }
        }
    }
}
