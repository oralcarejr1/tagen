import Foundation

/// What the planner decided to do next.
public enum PlannedStep: Sendable, Equatable {
    case action(GUIAction, rationale: String)
    /// Planner-internal: the model wants a screenshot before deciding.
    case requestScreenshot
    case done(summary: String)
    case askUser(question: String)
    case fail(reason: String)
}

public struct StepHistoryItem: Sendable, Equatable {
    public var action: GUIAction
    public var result: String
    public var succeeded: Bool
}

/// Decides the next GUI action from the goal and current observation.
public protocol ActionPlanner: Sendable {
    func nextStep(goal: String, observation: GUIObservation, history: [StepHistoryItem]) async throws -> PlannedStep
    /// Model tokens consumed so far by this planner (input incl. cache + output); 0 if not model-backed.
    var tokensUsed: Int { get }
}

extension ActionPlanner {
    public var tokensUsed: Int { 0 }
}

/// Deterministic planner that replays a fixed list (scripted automations / fixture tests).
public final class ScriptedPlanner: ActionPlanner, @unchecked Sendable {
    private let steps: Locked<[GUIAction]>
    private let summary: String
    public init(_ steps: [GUIAction], summary: String = "Script finished") { self.steps = Locked(steps); self.summary = summary }
    public func nextStep(goal: String, observation: GUIObservation, history: [StepHistoryItem]) async throws -> PlannedStep {
        if let last = history.last, !last.succeeded { return .fail(reason: "step failed: \(last.result)") }
        return steps.withLock { s in s.isEmpty ? .done(summary: summary) : .action(s.removeFirst(), rationale: "scripted") }
    }
}

/// Model-backed planner. Keeps one append-only conversation per task. Sends a compact accessibility
/// tree plus a diff against the previous step, and attaches a screenshot when accessibility text is thin
/// or when the model asks for one (`{"type":"screenshot"}`).
public final class ModelActionPlanner: ActionPlanner, @unchecked Sendable {
    let models: ModelStreaming
    let packager: ContextPackager
    let screenshotProvider: (@Sendable (GUIObservation) async -> CapturedImage?)?
    let maxScreenshotRequestsPerStep: Int
    private let messages = Locked<[ChatMessage]>([])
    private let previous = Locked<GUIObservation?>(nil)
    /// Geometry of the screenshot most recently sent, for converting `image_point` targets.
    private let lastImage = Locked<CaptureGeometry?>(nil)
    private let usage = Locked(0)
    public var tokensUsed: Int { usage.current }

    public init(models: ModelStreaming, packager: ContextPackager = ContextPackager(options: .planner),
                screenshotProvider: (@Sendable (GUIObservation) async -> CapturedImage?)? = nil, maxScreenshotRequestsPerStep: Int = 1) {
        self.models = models; self.packager = packager; self.screenshotProvider = screenshotProvider
        self.maxScreenshotRequestsPerStep = maxScreenshotRequestsPerStep
    }

    static func instruction(goal: String, history: [StepHistoryItem], changes: [String], hasImage: Bool) -> String {
        let last = history.last.map { "Result of your previous action (\($0.action.summary)): \($0.succeeded ? "OK" : "FAILED") — \($0.result)\n" } ?? ""
        let diff = changes.isEmpty ? "" : "Changes since the previous step:\n" + changes.map { "  - " + $0 }.joined(separator: "\n") + "\n"
        let image = hasImage ? "A screenshot of the window is attached; use \"image_point\": [x, y] (screenshot pixels) only for targets missing from the tree.\n" : ""
        return """
        \(last)\(diff)\(image)Mode: ACT. Goal from the user: \(goal)
        Propose exactly ONE next action as JSON only (no prose outside JSON). Schema:
        {"rationale": "<one sentence>", "action": {"type": "click", "element_id": "<id>"} }
        Action types:
          click {element_id | image_point:[x,y], button?: "left"|"right", count?: 1|2}
          type {element_id?, text, replace?: true, submit?: false}
          keys {combo: "cmd+s"}
          menu {path: ["File", "Save…"]}
          scroll {element_id?, direction: "up"|"down"|"left"|"right", amount?: 3}
          focus_app {app: "<bundle id or name>"}
          wait {condition: {"element_exists": {"title": "…"}} | {"window_title_contains": "…"}, timeout?: 5}
          screenshot {}             — you need to see the window (canvas/graphics/unlabeled controls)
          done {summary}            — the goal is complete (verified in the current screen)
          ask_user {question}       — you need information or a decision from the user
          fail {reason}             — the goal cannot be completed safely
        Use element ids from the CURRENT tree only. Prefer element_id over image_point. Do not repeat an action that \
        failed without changing something. Never enter passwords or payment data.
        """
    }

    /// Thin accessibility → attach a screenshot up front.
    static func needsScreenshot(_ obs: GUIObservation, packager: ContextPackager) -> Bool {
        let ctx = obs.asScreenContext()
        if ctx.axRoot == nil { return true }
        if let b = obs.app?.bundleID, ContextPackager.canvasApps.contains(b) { return true }
        let interactive = obs.root?.flattened().filter(\.isInteractive).count ?? 0
        return ctx.accessibilityTextVolume < packager.options.sufficientTextVolume || interactive < 2
    }

    public func nextStep(goal: String, observation: GUIObservation, history: [StepHistoryItem]) async throws -> PlannedStep {
        let changes = previous.current.map { ObservationDiff.lines(from: $0, to: observation) } ?? []
        previous.set(observation)
        var image: CapturedImage?
        if Self.needsScreenshot(observation, packager: packager) { image = await screenshotProvider?(observation) }
        var requests = 0
        while true {
            let pkg = packager.package(observation.asScreenContext(), question: goal, policy: .never)
            var parts: [ContentPart] = []
            if let img = image { parts.append(.image(data: img.data, mediaType: img.mediaType)) }
            parts.append(.text(pkg.text + "\n\n" + Self.instruction(goal: goal, history: requests == 0 ? history : [], changes: requests == 0 ? changes : [],
                                                                     hasImage: image != nil)))
            let user = ChatMessage(role: .user, parts: parts)
            let req = ChatRequest(system: PromptLibrary.systemPrompt, messages: messages.current + [user], maxTokens: 4000, purpose: .computerUse,
                                  cacheConversation: true)
            var final: ChatResponse?
            for try await ev in models.stream(req) { if case .completed(let r) = ev { final = r } }
            try Task.checkCancellation()
            guard let r = final else { throw ModelError.decoding("planner: no response") }
            messages.withLock { $0.append(user); $0.append(r.message) }
            usage.withLock { $0 += r.usage.inputTokens + r.usage.cacheReadTokens + r.usage.cacheWriteTokens + r.usage.outputTokens }
            if image != nil { lastImage.set(image?.geometry) }
            let step = ActionParser.parse(r.text, observation: observation, imageGeometry: lastImage.current)
            if case .requestScreenshot = step {
                requests += 1
                guard image == nil, requests <= maxScreenshotRequestsPerStep, let provider = screenshotProvider,
                      let shot = await provider(observation) else {
                    return .fail(reason: "a screenshot was requested but is unavailable (Screen Recording permission?)")
                }
                image = shot
                continue
            }
            return step
        }
    }
}

public enum ActionParser {
    /// Parse planner JSON into a typed step. Any malformed output becomes `.fail` (never a guess).
    public static func parse(_ text: String, observation: GUIObservation, imageGeometry: CaptureGeometry? = nil) -> PlannedStep {
        guard let json = GuideParser.extractJSONObject(text) else { return .fail(reason: "planner returned no JSON") }
        let rationale = json["rationale"]?.stringValue ?? ""
        let a = json["action"] ?? json
        guard let type = a["type"]?.stringValue else { return .fail(reason: "action has no type") }
        func target() -> ElementTarget? {
            if let id = a["element_id"]?.stringValue, !id.isEmpty { return .element(id: id, observationID: observation.id) }
            if let p = a["image_point"]?.arrayValue?.compactMap(\.doubleValue), p.count == 2, let g = imageGeometry {
                let r = Rect(origin: .zero, size: g.imageSize)
                guard r.contains(Point(x: p[0], y: p[1])) else { return nil }
                return .point(g.globalPoint(fromImagePixel: Point(x: p[0], y: p[1])), observationID: observation.id)
            }
            if let p = a["point"]?.arrayValue?.compactMap(\.doubleValue), p.count == 2 { return .point(Point(x: p[0], y: p[1]), observationID: observation.id) }
            if let q = a["query"], let query = try? q.decode(ElementQuery.self) { return .query(query) }
            return nil
        }
        switch type {
        case "click":
            guard let t = target() else { return .fail(reason: "click without target") }
            let button = MouseButton(rawValue: a["button"]?.stringValue ?? "left") ?? .left
            return .action(.click(t, button: button, count: a["count"]?.intValue ?? 1), rationale: rationale)
        case "type":
            guard let text = a["text"]?.stringValue else { return .fail(reason: "type without text") }
            return .action(.typeText(target(), text: text, replaceExisting: a["replace"]?.boolValue ?? true, submit: a["submit"]?.boolValue ?? false), rationale: rationale)
        case "keys":
            guard let c = a["combo"]?.stringValue, let k = KeyCombo.parse(c) else { return .fail(reason: "invalid key combo") }
            return .action(.pressKeys(k), rationale: rationale)
        case "menu":
            guard let p = a["path"]?.arrayValue?.compactMap(\.stringValue), p.count >= 2 else { return .fail(reason: "invalid menu path") }
            return .action(.selectMenu(path: p), rationale: rationale)
        case "scroll":
            guard let d = ScrollDirection(rawValue: a["direction"]?.stringValue ?? "") else { return .fail(reason: "invalid scroll direction") }
            return .action(.scroll(target(), direction: d, amount: a["amount"]?.intValue ?? 3), rationale: rationale)
        case "focus_app":
            guard let app = a["app"]?.stringValue else { return .fail(reason: "focus_app without app") }
            return .action(.focusApp(app), rationale: rationale)
        case "wait":
            let c = a["condition"]
            let to = a["timeout"]?.doubleValue ?? 5
            if let q = c?["element_exists"], let query = try? q.decode(ElementQuery.self) { return .action(.wait(.elementExists(query), timeout: to), rationale: rationale) }
            if let q = c?["element_gone"], let query = try? q.decode(ElementQuery.self) { return .action(.wait(.elementGone(query), timeout: to), rationale: rationale) }
            if let t = c?["window_title_contains"]?.stringValue { return .action(.wait(.windowTitleContains(t), timeout: to), rationale: rationale) }
            return .fail(reason: "invalid wait condition")
        case "screenshot": return .requestScreenshot
        case "done": return .done(summary: a["summary"]?.stringValue ?? rationale)
        case "ask_user": return .askUser(question: a["question"]?.stringValue ?? rationale)
        case "fail": return .fail(reason: a["reason"]?.stringValue ?? rationale)
        default: return .fail(reason: "unknown action type \(type)")
        }
    }
}

public enum ComputerUseEvent: Sendable {
    case started(goal: String, scope: String?)
    case observing
    /// `targetName`: the target element's name in the observation the step was planned on (for display).
    case planned(GUIAction, rationale: String, targetName: String? = nil)
    case phase(StepPhase, String)
    case stepFinished(StepReport)
    case needsUser(String)
    case finished(summary: String)
    case failed(String)
    case stopped
}

public struct ComputerUseConfig: Sendable, Equatable {
    public var maxSteps: Int = 20
    public var maxConsecutiveFailures: Int = 3
    public var taskTimeout: Double = 300
    /// Upper bound on model tokens for one task (cost cap). 0 = unlimited.
    public var maxModelTokens: Int = 400_000
    public init() {}
}

/// Runs an Act-mode task: plan → execute (via ActionExecutor) → feed back → repeat.
public struct ComputerUseSession: Sendable {
    public let goal: String
    public let scopeBundleID: String?
    let planner: ActionPlanner
    let executor: ActionExecutor
    let config: ComputerUseConfig

    public init(goal: String, scopeBundleID: String?, planner: ActionPlanner, executor: ActionExecutor, config: ComputerUseConfig = ComputerUseConfig()) {
        self.goal = goal; self.scopeBundleID = scopeBundleID; self.planner = planner; self.executor = executor; self.config = config
    }

    public func run() -> AsyncStream<ComputerUseEvent> {
        AsyncStream { continuation in
            let task = Task {
                let outcome = await runLoop { continuation.yield($0) }
                continuation.yield(outcome)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func runLoop(_ emit: @escaping @Sendable (ComputerUseEvent) -> Void) async -> ComputerUseEvent {
        let stop = executor.stop
        let gen = stop.currentGeneration
        emit(.started(goal: goal, scope: scopeBundleID))
        await executor.approvals.resetTaskGrants()
        var history: [StepHistoryItem] = []
        var previous: GUIObservation?
        var failures = 0
        let deadline = Date().addingTimeInterval(config.taskTimeout)
        for _ in 0..<config.maxSteps {
            if (try? stop.check(sinceGeneration: gen)) == nil || Task.isCancelled { return .stopped }
            if Date() > deadline { return .failed("task timed out after \(Int(config.taskTimeout))s") }
            emit(.observing)
            let obs: GUIObservation
            do { obs = try await executor.driver.observe(scopeBundleID: scopeBundleID) }
            catch { return .failed("cannot observe the UI: \(error)") }
            let step: PlannedStep
            do { step = try await planner.nextStep(goal: goal, observation: obs, history: history) }
            catch { return .failed("planner error: \(error)") }
            if config.maxModelTokens > 0 && planner.tokensUsed > config.maxModelTokens {
                return .failed("stopped: model token budget for this task exceeded (\(planner.tokensUsed) > \(config.maxModelTokens))")
            }
            switch step {
            case .requestScreenshot: return .failed("planner requested a screenshot it could not get")
            case .done(let s): return .finished(summary: s)
            case .askUser(let q): emit(.needsUser(q)); return .needsUser(q)
            case .fail(let r): return .failed(r)
            case .action(let a, let why):
                emit(.planned(a, rationale: why, targetName: a.targetName(in: obs)))
                let report = await executor.run(a, scopeBundleID: scopeBundleID, previous: obs) { ev in
                    if case .phase(let p, let m) = ev { emit(.phase(p, m)) }
                }
                emit(.stepFinished(report))
                switch report.outcome {
                case .stopped: return .stopped
                case .denied(let r):
                    return .failed("action denied: \(r)")
                case .succeeded(let v):
                    failures = 0
                    history.append(StepHistoryItem(action: a, result: v, succeeded: true))
                case .failed(let phase, let r):
                    failures += 1
                    history.append(StepHistoryItem(action: a, result: "\(phase.rawValue): \(r)", succeeded: false))
                    if failures >= config.maxConsecutiveFailures { return .failed("stopping after \(failures) consecutive failures: \(r)") }
                }
                previous = report.observationAfter ?? obs
                _ = previous
            }
        }
        return .failed("reached the step limit (\(config.maxSteps))")
    }
}
