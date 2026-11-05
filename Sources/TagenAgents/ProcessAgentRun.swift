import Foundation
import TagenCore

/// Shared plumbing for subprocess-backed agent runs: event stream, cancellation state,
/// terminal-event de-duplication and timeout.
public final class ProcessAgentRun: AgentRun, @unchecked Sendable {
    public let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    let process = JSONLProcess()
    private let state = Locked<(finished: Bool, cancelled: Bool, session: String?)>((false, false, nil))
    var onCancel: (@Sendable () async -> Void)?

    public init() {
        (events, continuation) = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    var isCancelled: Bool { state.current.cancelled }
    var sessionID: String? { state.current.session }

    static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")
    static func stripANSI(_ s: String) -> String {
        ansi.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    func emit(_ e: AgentEvent) {
        if case .log(let l) = e, l.contains("\u{1B}") { emit(.log(Self.stripANSI(l))); return }
        if case .session(let s) = e { state.withLock { $0.session = s } }
        let shouldEmit = state.withLock { st -> Bool in
            if st.finished { return false }
            if e.isTerminal { st.finished = true }
            return true
        }
        guard shouldEmit else { return }
        continuation.yield(e)
        if e.isTerminal { continuation.finish() }
    }

    func fail(_ kind: AgentFailureKind, _ message: String, exit: Int32? = nil) {
        emit(.failed(AgentFailure(kind: kind, message: message, exitCode: exit, sessionID: sessionID)))
    }

    public func cancel() async {
        let already = state.withLock { st -> Bool in let a = st.cancelled; st.cancelled = true; return a }
        guard !already else { return }
        if let c = onCancel { await c() }
        process.terminate()
        fail(.cancelled, "Cancelled by user")
    }

    func armTimeout(_ seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !self.state.current.finished else { return }
            self.process.terminate()
            self.fail(.timeout, "Agent task exceeded \(Int(seconds))s")
        }
    }

    /// Failure for a process that exited before producing a result.
    func exitedWithoutResult(_ code: Int32) {
        if isCancelled { fail(.cancelled, "Cancelled by user", exit: code); return }
        let tail = process.recentStderr.suffix(8).joined(separator: "\n")
        if AuthErrorDetector.isAuthError(tail) { fail(.authentication, tail.isEmpty ? "authentication required" : tail, exit: code); return }
        fail(.processCrashed, tail.isEmpty ? "process exited with status \(code)" : tail, exit: code)
    }
}

public enum AgentLaunchError {
    static func notInstalled(_ p: AgentProvider) -> AgentFailure {
        AgentFailure(kind: .notInstalled, message: "\(p.displayName) CLI (`\(p.executableName)`) was not found on this Mac.")
    }
}

/// A run that failed before starting (e.g. CLI missing).
public struct FailedAgentRun: AgentRun {
    public let events: AsyncStream<AgentEvent>
    public init(_ failure: AgentFailure) {
        events = AsyncStream { c in c.yield(.failed(failure)); c.finish() }
    }
    public func cancel() async {}
}
