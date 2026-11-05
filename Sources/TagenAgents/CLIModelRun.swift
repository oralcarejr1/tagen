import Foundation
import TagenCore

/// Reads one CLI's JSONL output for one model request. A new instance is made per request and is
/// called serially from a single reader task, so implementations may keep plain mutable state.
protocol CLIModelOutputParser: AnyObject {
    func handle(_ line: JSONValue, _ out: CLIModelOutput)
}

/// What a parser can do with the request's result stream. Finishing is idempotent: the first
/// `complete`/`fail` wins and runs the request's cleanup before the caller sees the outcome.
final class CLIModelOutput: @unchecked Sendable {
    let tool: String
    private let continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
    private let onEnd: @Sendable () -> Void
    private let finished = Locked(false)
    private let notes = Locked<[String]>([])

    init(tool: String, continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation, onEnd: @escaping @Sendable () -> Void) {
        self.tool = tool; self.continuation = continuation; self.onEnd = onEnd
    }

    var isFinished: Bool { finished.current }

    func delta(_ text: String) {
        guard !isFinished, !text.isEmpty else { return }
        continuation.yield(.textDelta(text))
    }

    func complete(_ response: ChatResponse) {
        guard markFinished() else { return }
        continuation.yield(.completed(response))
        continuation.finish()
    }

    func fail(_ error: ModelError) {
        guard markFinished() else { return }
        continuation.finish(throwing: error)
    }

    /// Fails with the error a CLI reported in its own output (sign-in, usage limit, other).
    func fail(reported text: String) { fail(CLIModelRun.classify(tool: tool, text)) }

    /// Remembers an error line, used to explain an exit that produced no result.
    func note(_ text: String) { notes.withLock { $0.append(text) } }
    var notedErrors: [String] { notes.current }

    private func markFinished() -> Bool {
        let first = finished.withLock { done -> Bool in if done { return false }; done = true; return true }
        if first { onEnd() }   // e.g. delete temp files before a short-lived caller exits
        return first
    }
}

/// Shared lifecycle for model providers that run a CLI once per request: launch, line parsing,
/// timeout, cancellation and classification of an exit without a result.
enum CLIModelRun {
    static let limitPatterns = ["usage limit", "rate limit", "rate_limit", "limit reached", "hit your limit", "overloaded"]

    static func isLimitError(_ text: String) -> Bool {
        let t = text.lowercased(); return limitPatterns.contains { t.contains($0) }
    }

    /// Maps an error a CLI reported to a ModelError.
    static func classify(tool: String, _ text: String) -> ModelError {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if AuthErrorDetector.isAuthError(msg) { return .cliSignedOut(tool: tool, detail: msg) }
        if isLimitError(msg) { return .rateLimited(retryAfter: nil) }
        return .server(status: 0, message: msg.isEmpty ? "\(tool) reported an error" : String(msg.prefix(500)))
    }

    /// - Parameters:
    ///   - tool: user-facing tool name for errors ("Claude Code", "Codex").
    ///   - makeLaunch: builds the process launch; only called when the executable exists.
    ///   - onEnd: cleanup, run once when the request finishes or is abandoned.
    static func stream(tool: String, executable: String?, timeout: Double, parser: CLIModelOutputParser,
                       makeLaunch: (String) -> ProcessLaunch, onEnd: @escaping @Sendable () -> Void = {})
        -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let out = CLIModelOutput(tool: tool, continuation: continuation, onEnd: onEnd)
            guard let exe = executable else { out.fail(.cliUnavailable(tool: tool)); return }
            let proc = JSONLProcess()
            do { try proc.launch(makeLaunch(exe)) } catch { out.fail(.cliUnavailable(tool: tool)); return }

            let timedOut = Locked(false)
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                if !Task.isCancelled { timedOut.set(true); proc.terminate() }
            }
            let parserBox = UncheckedBox(parser)
            let reader = Task {
                for await o in proc.output {
                    switch o {
                    case .stdout(let line):
                        guard !out.isFinished, let json = try? JSONValue.parse(line) else { continue }
                        parserBox.value.handle(json, out)
                    case .stderr:
                        break
                    case .exited(let code):
                        timer.cancel()
                        guard !out.isFinished else { break }
                        if timedOut.current { out.fail(.timeout); break }
                        if Task.isCancelled { out.fail(.cancelled); break }
                        let detail = (out.notedErrors + proc.recentStderr.suffix(5)).joined(separator: "\n")
                        let err = classify(tool: tool, detail)
                        if case .server = err {
                            let name = (exe as NSString).lastPathComponent
                            out.fail(.server(status: 0, message: "\(name) exited with code \(code)" + (detail.isEmpty ? "" : ": \(detail.prefix(400))")))
                        } else {
                            out.fail(err)
                        }
                    }
                }
                timer.cancel()
            }
            continuation.onTermination = { _ in
                timer.cancel(); reader.cancel(); proc.terminate(grace: 1); onEnd()
            }
        }
    }
}

/// Carries a non-Sendable value into a task that is its only user.
private struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
