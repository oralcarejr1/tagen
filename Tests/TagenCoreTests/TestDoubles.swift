import Foundation
@testable import TagenCore

/// Scripted HTTP transport: each call pops the next response (status, headers, body lines).
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    struct Response { var status: Int; var headers: [String: String] = [:]; var lines: [String]; var failAfterLines: Error? = nil }
    let responses = Locked<[Response]>([])
    let requests = Locked<[HTTPRequest]>([])
    init(_ r: [Response]) { responses.set(r) }
    func streamLines(_ request: HTTPRequest) async throws -> (HTTPStreamHead, AsyncThrowingStream<String, Error>) {
        requests.withLock { $0.append(request) }
        guard let r = responses.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { throw ModelError.network("no scripted response") }
        let s = AsyncThrowingStream<String, Error> { c in
            for l in r.lines { c.yield(l) }
            if let e = r.failAfterLines { c.finish(throwing: e) } else { c.finish() }
        }
        return (HTTPStreamHead(status: r.status, headers: r.headers), s)
    }
    var lastBody: JSONValue? { requests.current.last?.body.flatMap { try? JSONValue.parse($0) } }
}

enum SSE {
    static func event(_ type: String, _ data: JSONValue) -> [String] { ["event: \(type)", "data: \(data.encoded())", ""] }
    static func anthropicText(_ chunks: [String], stop: String = "end_turn", thinking: Bool = false) -> [String] {
        var l: [String] = []
        l += event("message_start", ["type": "message_start", "message": ["id": "msg_1", "model": "claude-opus-5-5", "usage": ["input_tokens": 42]]])
        var idx = 0
        if thinking {
            l += event("content_block_start", ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]])
            l += event("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": ""]])
            l += event("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "sig-abc"]])
            l += event("content_block_stop", ["type": "content_block_stop", "index": 0])
            idx = 1
        }
        l += event("content_block_start", ["type": "content_block_start", "index": .number(Double(idx)), "content_block": ["type": "text", "text": ""]])
        for c in chunks { l += event("content_block_delta", ["type": "content_block_delta", "index": .number(Double(idx)), "delta": ["type": "text_delta", "text": .string(c)]]) }
        l += event("content_block_stop", ["type": "content_block_stop", "index": .number(Double(idx))])
        l += event("message_delta", ["type": "message_delta", "delta": ["stop_reason": .string(stop)], "usage": ["output_tokens": 7]])
        l += event("message_stop", ["type": "message_stop"])
        return l
    }
}

/// Model that replies with scripted texts and records requests.
final class ScriptedModel: ModelStreaming, @unchecked Sendable {
    let replies = Locked<[Result<String, ModelError>]>([])
    let requests = Locked<[ChatRequest]>([])
    let delayNanos: UInt64
    init(_ replies: [String], delayNanos: UInt64 = 0) { self.replies.set(replies.map { .success($0) }); self.delayNanos = delayNanos }
    init(results: [Result<String, ModelError>]) { self.replies.set(results); self.delayNanos = 0 }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        requests.withLock { $0.append(request) }
        let next = replies.withLock { $0.isEmpty ? Result<String, ModelError>.success("(no reply)") : $0.removeFirst() }
        let delay = delayNanos
        return AsyncThrowingStream { c in
            let t = Task {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay); if Task.isCancelled { c.finish(throwing: ModelError.cancelled); return } }
                switch next {
                case .success(let text):
                    for w in text.split(separator: " ", omittingEmptySubsequences: false) { c.yield(.textDelta(String(w) + " ")) }
                    let msg = ChatMessage(role: .assistant, parts: [.text(text)], providerContent: [["type": "thinking", "thinking": "", "signature": "s"], ["type": "text", "text": .string(text)]], providerID: "anthropic")
                    c.yield(.completed(ChatResponse(text: text, stopReason: "end_turn", model: "scripted", usage: TokenUsage(), message: msg)))
                    c.finish()
                case .failure(let e): c.finish(throwing: e)
                }
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
}

/// Fixed screen context provider.
final class FakeContextProvider: ScreenContextProvider, @unchecked Sendable {
    let ctx: Locked<ScreenContext>
    let captures = Locked(0)
    init(_ c: ScreenContext) { ctx = Locked(c) }
    func capture(_ request: ContextRequest) async throws -> ScreenContext { captures.withLock { $0 += 1 }; return ctx.current }
    func currentFrame(ofElementWithIdentity identity: ElementIdentity) async -> Rect? { ctx.current.axRoot.flatMap { identity.resolve(in: $0)?.frame } }
}

enum Fixtures {
    static let primary = DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: Rect(x: 0, y: 25, width: 1440, height: 800), scale: 2, isPrimary: true)
    /// Secondary display placed above-left of the primary (negative coordinates), non-Retina.
    static let secondary = DisplayInfo(id: 2, frame: Rect(x: -1920, y: -1080, width: 1920, height: 1080), scale: 1, isPrimary: false)
    static let layout = DisplayLayout(displays: [primary, secondary])

    static func fixtureTree() -> AXElementSnapshot {
        AXElementSnapshot(id: "w0", role: "AXWindow", title: "Tagen Fixture", frame: Rect(x: 100, y: 100, width: 560, height: 620), children: [
            AXElementSnapshot(id: "w0.0", role: "AXButton", title: "Increment", identifier: "incrementButton", frame: Rect(x: 116, y: 140, width: 90, height: 24), actions: ["AXPress"]),
            AXElementSnapshot(id: "w0.1", role: "AXStaticText", value: "Count: 0", identifier: "countLabel", frame: Rect(x: 220, y: 144, width: 80, height: 16)),
            AXElementSnapshot(id: "w0.2", role: "AXTextField", value: "", identifier: "nameField", placeholder: "Name", frame: Rect(x: 116, y: 180, width: 220, height: 22), actions: ["AXConfirm"]),
            AXElementSnapshot(id: "w0.3", role: "AXButton", title: "Greet", identifier: "greetButton", frame: Rect(x: 344, y: 180, width: 70, height: 24), actions: ["AXPress"]),
            AXElementSnapshot(id: "w0.4", role: "AXCheckBox", title: "Enable feature", value: "0", identifier: "featureCheckbox", frame: Rect(x: 116, y: 220, width: 130, height: 18), actions: ["AXPress"]),
            AXElementSnapshot(id: "w0.5", role: "AXButton", title: "Delete Everything", identifier: "deleteButton", frame: Rect(x: 260, y: 218, width: 140, height: 24), actions: ["AXPress"]),
            AXElementSnapshot(id: "w0.6", role: "AXSecureTextField", value: "hunter2", identifier: "passwordField", frame: Rect(x: 116, y: 260, width: 200, height: 22)),
            AXElementSnapshot(id: "w0.7", role: "AXButton", title: "Disabled", identifier: "disabledButton", frame: Rect(x: 330, y: 260, width: 80, height: 22), isEnabled: false, actions: ["AXPress"]),
        ])
    }
}

/// In-memory simulation of a small UI (TEST DOUBLE — not a live GUI test). It models the
/// fixture app's behaviour so executor logic can be tested deterministically.
final class SimulatedGUIDriver: GUIDriver, @unchecked Sendable {
    struct State { var count = 0; var name = ""; var checkbox = false; var deleted = false; var windowOffset = 0.0; var scroll = 0 }
    let state = Locked(State())
    let performed = Locked<[GUIPrimitive]>([])
    let failNextPerforms = Locked(0)
    let userIdle = Locked<Double?>(nil)
    let bundleID = "dev.tagen.Fixture"

    func tree(_ s: State) -> AXElementSnapshot {
        var t = Fixtures.fixtureTree()
        let off = s.windowOffset
        func shift(_ e: inout AXElementSnapshot) {
            e.frame = e.frame?.offsetBy(dx: off, dy: off)
            for i in e.children.indices { shift(&e.children[i]) }
        }
        shift(&t)
        t.children[1].value = s.deleted ? "Count: DELETED" : "Count: \(s.count)"
        t.children[2].value = s.name
        t.children[4].value = s.checkbox ? "1" : "0"
        return t
    }

    func observe(scopeBundleID: String?) async throws -> GUIObservation {
        let s = state.current
        return GUIObservation(app: AppInfo(name: "TagenFixture", bundleID: bundleID, pid: 4242),
                              window: WindowInfo(title: "Tagen Fixture", frame: Rect(x: 100 + s.windowOffset, y: 100 + s.windowOffset, width: 560, height: 620)),
                              root: tree(s), layout: Fixtures.layout)
    }

    func perform(_ p: GUIPrimitive) async throws {
        if failNextPerforms.withLock({ v -> Bool in if v > 0 { v -= 1; return true }; return false }) { throw DriverError.actionFailed("simulated failure") }
        performed.withLock { $0.append(p) }
        state.withLock { s in
            switch p {
            case .axPress(let id):
                switch id.identifier {
                case "incrementButton": s.count += 1
                case "featureCheckbox": s.checkbox.toggle()
                case "deleteButton": s.deleted = true
                default: break
                }
            case .mouseClick(let pt, _, let n):
                let t = tree(s)
                if let hit = t.flattened().first(where: { $0.frame?.contains(pt) == true && $0.isInteractive && $0.role != "AXWindow" }) {
                    if hit.identifier == "incrementButton" { s.count += n }
                    if hit.identifier == "deleteButton" { s.deleted = true }
                }
            case .axSetValue(let id, let v): if id.identifier == "nameField" { s.name = v }
            case .typeKeystrokes(let t): s.name += t
            case .menuPath(let path, _): if path == ["Fixture", "Reset Counter"] { s.count = 0 }
            case .keyCombo(let k): if k.key == "r" && k.modifiers == [.command] { s.count = 0 }
            case .scroll: s.scroll += 1
            default: break
            }
        }
    }

    func secondsSinceUserInput() async -> Double? { userIdle.current }
}

/// Approval presenter returning a fixed decision and recording requests.
final class RecordingPresenter: ApprovalPresenter, @unchecked Sendable {
    let decision: ApprovalDecision
    let seen = Locked<[ApprovalRequest]>([])
    let delayNanos: UInt64
    init(_ d: ApprovalDecision, delayNanos: UInt64 = 0) { decision = d; self.delayNanos = delayNanos }
    func present(_ request: ApprovalRequest) async -> ApprovalDecision {
        seen.withLock { $0.append(request) }
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        if Task.isCancelled { return .denied(reason: "cancelled") }
        return decision
    }
}
