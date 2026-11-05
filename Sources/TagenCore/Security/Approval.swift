import Foundation

public enum RiskLevel: Int, Sendable, Codable, Comparable, CustomStringConvertible {
    case low = 0, medium, high, prohibited
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }
    public var description: String { ["low", "medium", "high", "prohibited"][rawValue] }
}

public enum ApprovalKind: String, Sendable, Codable {
    case guiAction, replaceSelection, agentCommand, agentFileChange, agentTool, sendScreenToCloud, other
}

public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: ApprovalKind
    public var title: String
    public var detail: String
    public var risk: RiskLevel
    public var reasons: [String]
    public var source: String
    public init(id: UUID = UUID(), kind: ApprovalKind, title: String, detail: String, risk: RiskLevel, reasons: [String] = [], source: String) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.risk = risk; self.reasons = reasons; self.source = source
    }
}

public enum ApprovalDecision: Sendable, Equatable {
    case approved
    /// Approve this and identical future requests during the current task only.
    case approvedForTask
    case denied(reason: String)
    public var isApproved: Bool { self == .approved || self == .approvedForTask }
}

/// UI boundary: shows the request to the user and returns their decision.
public protocol ApprovalPresenter: Sendable {
    func present(_ request: ApprovalRequest) async -> ApprovalDecision
}

/// Routes approval requests to the presenter with timeout, emergency-stop and audit.
/// Default on timeout/stop/unavailable presenter is DENY. Prohibited risk is denied
/// without asking.
public actor ApprovalBroker {
    let presenter: ApprovalPresenter?
    let timeout: Double
    let audit: AuditSink?
    let stop: EmergencyStop
    private var taskGrants: Set<String> = []
    public private(set) var history: [(ApprovalRequest, ApprovalDecision)] = []

    public init(presenter: ApprovalPresenter?, timeout: Double = 120, audit: AuditSink? = nil, stop: EmergencyStop = .shared) {
        self.presenter = presenter; self.timeout = timeout; self.audit = audit; self.stop = stop
    }

    public func resetTaskGrants() { taskGrants.removeAll() }

    public func request(_ req: ApprovalRequest) async -> ApprovalDecision {
        let decision = await decide(req)
        history.append((req, decision))
        audit?.record(AuditEntry(category: "approval", action: "\(req.kind.rawValue): \(req.title)",
                                 decision: Self.describe(decision), detail: "risk=\(req.risk) source=\(req.source) \(req.detail)"))
        return decision
    }

    private func decide(_ req: ApprovalRequest) async -> ApprovalDecision {
        if req.risk == .prohibited { return .denied(reason: "Prohibited by policy: " + req.reasons.joined(separator: "; ")) }
        if stop.isTriggered { return .denied(reason: "Emergency stop active") }
        let key = "\(req.kind.rawValue)|\(req.title)|\(req.detail)"
        if taskGrants.contains(key) && req.risk < .high { return .approvedForTask }
        guard let presenter else { return .denied(reason: "No approval UI available") }
        let gen = stop.currentGeneration
        let decision: ApprovalDecision
        do {
            decision = try await withTimeout(seconds: timeout, operation: "approval") { await presenter.present(req) }
        } catch {
            return .denied(reason: "Approval timed out")
        }
        if stop.currentGeneration != gen { return .denied(reason: "Emergency stop active") }
        if decision == .approvedForTask { taskGrants.insert(key) }
        return decision
    }

    static func describe(_ d: ApprovalDecision) -> String {
        switch d {
        case .approved: return "approved"
        case .approvedForTask: return "approved-for-task"
        case .denied(let r): return "denied: \(r)"
        }
    }
}

/// Presenter that always denies (headless default).
public struct DenyAllPresenter: ApprovalPresenter {
    public init() {}
    public func present(_ request: ApprovalRequest) async -> ApprovalDecision { .denied(reason: "No interactive approver") }
}

public struct AuditEntry: Sendable, Equatable {
    public var timestamp: Date
    public var category: String
    public var action: String
    public var decision: String
    public var detail: String
    public init(timestamp: Date = Date(), category: String, action: String, decision: String, detail: String) {
        let r = Redactor()
        self.timestamp = timestamp; self.category = category; self.action = r.redact(action)
        self.decision = decision; self.detail = r.redact(String(detail.prefix(2000)))
    }
}

public protocol AuditSink: Sendable {
    func record(_ entry: AuditEntry)
}

public final class MemoryAuditSink: AuditSink, @unchecked Sendable {
    private let entries = Locked<[AuditEntry]>([])
    public init() {}
    public func record(_ entry: AuditEntry) { entries.withLock { $0.append(entry) } }
    public var all: [AuditEntry] { entries.current }
}
