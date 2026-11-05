import XCTest
import Foundation
@testable import TagenAgents
@testable import TagenCore

final class BundleMarker {}

enum AgentFixtures {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static func path(_ name: String) -> String { dir.appendingPathComponent(name).path }
    static var packageRoot: URL { dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    static var hasPython: Bool {
        ExecutableLocator().locate("python3", loginShellPATH: nil) != nil
    }

    /// Built `tagen-approval-mcp` (swift build --build-tests builds all products).
    static var approvalMCP: String? {
        var candidates: [URL] = [Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent(), Bundle.main.bundleURL.deletingLastPathComponent(), Bundle.main.bundleURL]
        let build = packageRoot.appendingPathComponent(".build")
        if let items = try? FileManager.default.contentsOfDirectory(at: build, includingPropertiesForKeys: nil) {
            for i in items { candidates.append(i.appendingPathComponent("debug")) }
        }
        candidates.append(build.appendingPathComponent("debug"))
        for c in candidates {
            let p = c.appendingPathComponent("tagen-approval-mcp").path
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func env(_ scenario: String, extra: [String: String] = [:]) -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["FAKE_SCENARIO"] = scenario
        for (k, v) in extra { e[k] = v }
        return e
    }

    static func tempDir() -> String {
        let p = NSTemporaryDirectory() + "tagen-agent-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
}

func collect(_ run: AgentRun, timeout: Double = 20) async -> [AgentEvent] {
    let box = Locked<[AgentEvent]>([])
    _ = try? await withTimeout(seconds: timeout) {
        for await e in run.events { box.withLock { $0.append(e) } }
        return true
    }
    return box.current
}

func collect(_ stream: AsyncStream<AgentEvent>, timeout: Double = 20) async -> [AgentEvent] {
    let box = Locked<[AgentEvent]>([])
    _ = try? await withTimeout(seconds: timeout) {
        for await e in stream { box.withLock { $0.append(e) } }
        return true
    }
    return box.current
}

final class Presenter: ApprovalPresenter, @unchecked Sendable {
    let decision: ApprovalDecision
    let seen = Locked<[ApprovalRequest]>([])
    init(_ d: ApprovalDecision) { decision = d }
    func present(_ r: ApprovalRequest) async -> ApprovalDecision { seen.withLock { $0.append(r) }; return decision }
}

extension Array where Element == AgentEvent {
    var terminal: AgentEvent? { last(where: \.isTerminal) }
    var result: AgentResult? { if case .completed(let r)? = terminal { return r }; return nil }
    var failure: AgentFailure? { if case .failed(let f)? = terminal { return f }; return nil }
}
