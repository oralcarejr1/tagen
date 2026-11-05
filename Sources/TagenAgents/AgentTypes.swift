import Foundation
import TagenCore

public enum AgentProvider: String, Sendable, Codable, CaseIterable, Identifiable {
    case codex
    case claudeCode
    public var id: String { rawValue }
    public var displayName: String { self == .codex ? "Codex" : "Claude Code" }
    public var executableName: String { self == .codex ? "codex" : "claude" }
}

/// How much the agent may do without asking. Maps onto each CLI's own sandbox/permission
/// system; Tagen never disables those mechanisms (no bypass / danger modes).
public enum AgentPermissionProfile: String, Sendable, Codable, CaseIterable {
    /// Read and plan only; no edits or commands.
    case readOnly
    /// Edits and commands require approval in Tagen.
    case askEveryTime
    /// File edits inside the project are allowed; commands still ask.
    case autoEditsInProject

    public var displayName: String {
        switch self {
        case .readOnly: return "Read-only"
        case .askEveryTime: return "Ask before edits and commands"
        case .autoEditsInProject: return "Auto-approve project edits"
        }
    }
}

public struct AgentTaskSpec: Sendable, Equatable {
    public var provider: AgentProvider
    public var prompt: String
    public var workingDirectory: String
    public var model: String?
    public var permissionProfile: AgentPermissionProfile
    public var resumeSessionID: String?
    public var maxTurns: Int?
    public var timeout: Double

    public init(provider: AgentProvider, prompt: String, workingDirectory: String, model: String? = nil,
                permissionProfile: AgentPermissionProfile = .askEveryTime, resumeSessionID: String? = nil,
                maxTurns: Int? = nil, timeout: Double = 1800) {
        self.provider = provider; self.prompt = prompt; self.workingDirectory = workingDirectory; self.model = model
        self.permissionProfile = permissionProfile; self.resumeSessionID = resumeSessionID; self.maxTurns = maxTurns; self.timeout = timeout
    }
}

public enum AgentFailureKind: String, Sendable, Codable {
    case notInstalled, authentication, processCrashed, protocolError, timeout, cancelled, agentError, permissionDenied
}

public struct AgentFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public var kind: AgentFailureKind
    public var message: String
    public var exitCode: Int32?
    public var sessionID: String?
    public init(kind: AgentFailureKind, message: String, exitCode: Int32? = nil, sessionID: String? = nil) {
        self.kind = kind; self.message = message; self.exitCode = exitCode; self.sessionID = sessionID
    }
    /// A crashed or timed-out run with a known session can be resumed.
    public var isRecoverable: Bool { (kind == .processCrashed || kind == .timeout || kind == .protocolError) && sessionID != nil }
    public var description: String { "\(kind.rawValue): \(message)" + (exitCode.map { " (exit \($0))" } ?? "") }

    public var remedy: String? {
        switch kind {
        case .notInstalled: return "Install the CLI on this Mac (or set its path in Settings › Agents)."
        case .authentication: return "Sign in from Settings › Agents (opens Terminal to run the CLI's login), or store a token/API key."
        case .processCrashed, .protocolError, .timeout: return sessionID != nil ? "You can resume the session." : nil
        default: return nil
        }
    }
}

public struct AgentResult: Sendable, Equatable {
    public var sessionID: String?
    public var finalText: String
    public var isError: Bool
    public var turns: Int?
    public var costUSD: Double?
    public var durationMs: Int?
    public var permissionDenials: [String]
    public var changedFiles: [String]
    public init(sessionID: String?, finalText: String, isError: Bool = false, turns: Int? = nil, costUSD: Double? = nil,
                durationMs: Int? = nil, permissionDenials: [String] = [], changedFiles: [String] = []) {
        self.sessionID = sessionID; self.finalText = finalText; self.isError = isError; self.turns = turns; self.costUSD = costUSD
        self.durationMs = durationMs; self.permissionDenials = permissionDenials; self.changedFiles = changedFiles
    }
}

public enum AgentEvent: Sendable, Equatable {
    case started(pid: Int32)
    case session(String)
    case messageDelta(String)
    case message(String)
    case reasoning(String)
    case toolStarted(id: String, name: String, detail: String)
    case toolOutput(id: String, text: String)
    case toolFinished(id: String, name: String, success: Bool, detail: String)
    case fileChanged([String])
    case approvalRequested(id: String, title: String, risk: RiskLevel)
    case approvalResolved(id: String, approved: Bool)
    case log(String)
    case completed(AgentResult)
    case failed(AgentFailure)

    public var isTerminal: Bool { switch self { case .completed, .failed: return true; default: return false } }

    /// Short summary for persistence / activity list.
    public var summary: (kind: String, text: String) {
        switch self {
        case .started(let pid): return ("started", "pid \(pid)")
        case .session(let s): return ("session", s)
        case .messageDelta(let t): return ("delta", t)
        case .message(let t): return ("message", t)
        case .reasoning(let t): return ("reasoning", t)
        case .toolStarted(_, let n, let d): return ("tool", "\(n): \(d)")
        case .toolOutput(_, let t): return ("output", t)
        case .toolFinished(_, let n, let ok, let d): return ("tool_done", "\(n) \(ok ? "✓" : "✗") \(d)")
        case .fileChanged(let p): return ("files", p.joined(separator: ", "))
        case .approvalRequested(_, let t, let r): return ("approval", "\(t) [\(r)]")
        case .approvalResolved(_, let ok): return ("approval_result", ok ? "approved" : "denied")
        case .log(let l): return ("log", l)
        case .completed(let r): return ("completed", r.finalText)
        case .failed(let f): return ("failed", f.description)
        }
    }
}

/// A running agent task.
public protocol AgentRun: Sendable {
    var events: AsyncStream<AgentEvent> { get }
    func cancel() async
}

public protocol CodingAgentAdapter: Sendable {
    var provider: AgentProvider { get }
    func start(_ spec: AgentTaskSpec, approvals: ApprovalBroker) async -> AgentRun
}

/// Classifies CLI error text as an authentication problem.
public enum AuthErrorDetector {
    static let patterns = ["not logged in", "please run /login", "run /login", "login expired", "invalid api key", "authentication_error",
                           "authentication failed", "unauthorized", "401", "codex login", "not authenticated", "oauth token has expired",
                           "apikeyhelper", "credit balance is too low", "invalid x-api-key", "please log in", "sign in",
                           // Claude Agent SDK error categories (SDKAssistantMessageError / SDKStartupFailureReason)
                           "authentication_failed", "oauth_org_not_allowed", "verification_required", "cloud_credential_error",
                           "gateway_signin_required", "gateway_access_denied", "account_on_hold"]
    public static func isAuthError(_ text: String) -> Bool {
        let t = text.lowercased()
        return patterns.contains { t.contains($0) }
    }
}
