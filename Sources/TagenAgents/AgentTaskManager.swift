import Foundation
import TagenCore

public struct AgentTaskSnapshot: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var spec: AgentTaskSpec
    public var status: Status
    public var sessionID: String?
    public var lastMessage: String
    public var activity: [String]
    public var result: AgentResult?
    public var failure: AgentFailure?
    public var recoveries: Int

    public enum Status: String, Sendable, Codable { case running, awaitingApproval, completed, failed, cancelled, recovering }
}

/// Owns all coding-agent runs: start, stream, cancel, resume, crash recovery and persistence.
public actor AgentTaskManager {
    let adapters: [AgentProvider: CodingAgentAdapter]
    let approvals: ApprovalBroker
    let store: AppStore?
    let stop: EmergencyStop
    let maxAutoRecoveries: Int
    private var runs: [UUID: AgentRun] = [:]
    public private(set) var tasks: [UUID: AgentTaskSnapshot] = [:]
    private var stopToken: UUID?
    private var observers: [UUID: @Sendable (AgentTaskSnapshot) -> Void] = [:]

    public init(adapters: [AgentProvider: CodingAgentAdapter], approvals: ApprovalBroker, store: AppStore?,
                stop: EmergencyStop = .shared, maxAutoRecoveries: Int = 1) {
        self.adapters = adapters; self.approvals = approvals; self.store = store; self.stop = stop
        self.maxAutoRecoveries = maxAutoRecoveries
    }

    public func installEmergencyStop() {
        guard stopToken == nil else { return }
        stopToken = stop.register { [weak self] _ in Task { await self?.cancelAll() } }
    }

    @discardableResult
    public func observe(_ f: @escaping @Sendable (AgentTaskSnapshot) -> Void) -> UUID {
        let id = UUID(); observers[id] = f; return id
    }

    /// Start a task. Returns its id and the event stream (including recovery runs).
    public func start(_ spec: AgentTaskSpec, existingID: UUID? = nil) async -> (UUID, AsyncStream<AgentEvent>) {
        let id = existingID ?? UUID()
        let (stream, cont) = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
        tasks[id] = AgentTaskSnapshot(id: id, spec: spec, status: .running, sessionID: spec.resumeSessionID, lastMessage: "",
                                      activity: [], result: nil, failure: nil, recoveries: tasks[id]?.recoveries ?? 0)
        persist(id)
        await launch(id: id, spec: spec, continuation: cont)
        return (id, stream)
    }

    /// Resume a previous session with a new prompt (supported by both CLIs).
    public func resume(taskID: UUID, prompt: String) async -> (UUID, AsyncStream<AgentEvent>)? {
        var spec: AgentTaskSpec
        var sid: String?
        if let t = tasks[taskID] { spec = t.spec; sid = t.sessionID }
        else if let rec = try? store?.agentSession(id: taskID), let p = AgentProvider(rawValue: rec.provider) {
            spec = AgentTaskSpec(provider: p, prompt: prompt, workingDirectory: rec.workingDirectory); sid = rec.externalSessionID
        } else { return nil }
        guard let session = sid else { return nil }
        spec.prompt = prompt
        spec.resumeSessionID = session
        return await start(spec, existingID: taskID)
    }

    public func cancel(_ id: UUID) async {
        await runs[id]?.cancel()
    }

    public func cancelAll() async {
        for r in runs.values { await r.cancel() }
    }

    public var activeCount: Int { runs.count }

    private func launch(id: UUID, spec: AgentTaskSpec, continuation: AsyncStream<AgentEvent>.Continuation) async {
        guard let adapter = adapters[spec.provider] else {
            let f = AgentLaunchError.notInstalled(spec.provider)
            update(id) { $0.status = .failed; $0.failure = f }
            continuation.yield(.failed(f)); continuation.finish(); return
        }
        if stop.isTriggered { stop.reset() }
        let run = await adapter.start(spec, approvals: approvals)
        runs[id] = run
        Task { await self.pump(id: id, spec: spec, run: run, continuation: continuation) }
    }

    private func pump(id: UUID, spec: AgentTaskSpec, run: AgentRun, continuation: AsyncStream<AgentEvent>.Continuation) async {
        var terminal: AgentEvent?
        for await e in run.events {
            record(id, e)
            if e.isTerminal { terminal = e } else { continuation.yield(e) }
        }
        runs[id] = nil
        // Bounded automatic recovery: resume the same session once after a crash.
        if case .failed(let f)? = terminal, f.isRecoverable, let t = tasks[id], t.recoveries < maxAutoRecoveries, !stop.isTriggered {
            update(id) { $0.recoveries += 1; $0.status = .recovering }
            continuation.yield(.log("Agent process failed (\(f.kind.rawValue)); resuming session \(f.sessionID ?? "")…"))
            var next = spec
            next.resumeSessionID = f.sessionID
            next.prompt = "The previous run was interrupted unexpectedly. Continue the task from where you left off and report the final result."
            await launch(id: id, spec: next, continuation: continuation)
            return
        }
        if let t = terminal { continuation.yield(t) }
        continuation.finish()
    }

    private func record(_ id: UUID, _ e: AgentEvent) {
        update(id) { t in
            switch e {
            case .session(let s): t.sessionID = s
            case .message(let m): t.lastMessage = m
            case .messageDelta(let d): t.lastMessage += d
            case .approvalRequested: t.status = .awaitingApproval
            case .approvalResolved: t.status = .running
            case .completed(let r): t.status = .completed; t.result = r; if let s = r.sessionID { t.sessionID = s }
            case .failed(let f): t.status = f.kind == .cancelled ? .cancelled : .failed; t.failure = f
            default: break
            }
            if case .messageDelta = e {} else {
                let s = e.summary
                t.activity.append("\(s.kind): \(s.text.prefix(200))")
                if t.activity.count > 300 { t.activity.removeFirst(t.activity.count - 300) }
            }
        }
        if case .messageDelta = e { return }
        if case .toolOutput = e { return }
        let s = e.summary
        try? store?.appendAgentEvent(sessionID: id, kind: s.kind, summary: s.text)
        if e.isTerminal || { if case .session = e { return true }; return false }() { persist(id) }
    }

    private func update(_ id: UUID, _ f: (inout AgentTaskSnapshot) -> Void) {
        guard var t = tasks[id] else { return }
        f(&t)
        tasks[id] = t
        for o in observers.values { o(t) }
    }

    private func persist(_ id: UUID) {
        guard let t = tasks[id], let store else { return }
        let now = Date()
        let existing = try? store.agentSession(id: id)
        try? store.upsertAgentSession(AgentSessionRecord(
            id: id, provider: t.spec.provider.rawValue, externalSessionID: t.sessionID, title: String(t.spec.prompt.prefix(120)),
            workingDirectory: t.spec.workingDirectory, status: t.status.rawValue, lastError: t.failure?.description,
            resultSummary: t.result.map { String($0.finalText.prefix(2000)) }, createdAt: existing?.createdAt ?? now, updatedAt: now))
    }
}
