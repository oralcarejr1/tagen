import Foundation

public struct ExecutorConfig: Sendable, Equatable {
    public var stepTimeout: Double = 10
    public var settleDelay: Double = 0.35
    public var maxAttempts: Int = 2
    public var verifyTimeout: Double = 2.0
    public var pollInterval: Double = 0.2
    /// Abort if the user touched mouse/keyboard within this many seconds before a step.
    public var userInputGrace: Double = 0.8
    public init() {}
}

public enum StepPhase: String, Sendable, Codable {
    case observe, identify, validate, authorize, execute, reobserve, verify
}

public enum StepOutcome: Sendable, Equatable {
    case succeeded(verification: String)
    case failed(phase: StepPhase, reason: String)
    case denied(reason: String)
    case stopped
}

public struct StepReport: Sendable, Equatable {
    public var action: GUIAction
    public var outcome: StepOutcome
    public var attempts: Int
    public var risk: RiskLevel?
    public var trace: [String]
    public var observationAfter: GUIObservation?
    public var succeeded: Bool { if case .succeeded = outcome { return true }; return false }
}

public enum ExecutorEvent: Sendable {
    case phase(StepPhase, String)
}

/// Executes one typed action with Observe → Identify → Validate → Authorize → Execute →
/// Observe again → Verify. Bounded retries always start from a fresh observation; stale
/// snapshot ids or coordinates are re-resolved or rejected, never blindly re-clicked.
public struct ActionExecutor: Sendable {
    public let driver: GUIDriver
    public let policy: ActionPolicy
    public let approvals: ApprovalBroker
    public let config: ExecutorConfig
    public let clock: SleepClock
    public let stop: EmergencyStop

    public init(driver: GUIDriver, policy: ActionPolicy, approvals: ApprovalBroker, config: ExecutorConfig = ExecutorConfig(),
                clock: SleepClock = SystemClock(), stop: EmergencyStop = .shared) {
        self.driver = driver; self.policy = policy; self.approvals = approvals; self.config = config; self.clock = clock; self.stop = stop
    }

    public func run(_ action: GUIAction, scopeBundleID: String?, previous: GUIObservation? = nil,
                    onEvent: (@Sendable (ExecutorEvent) -> Void)? = nil) async -> StepReport {
        let gen = stop.currentGeneration
        var trace: [String] = []
        var risk: RiskLevel?
        var approvedOnce = false
        func note(_ p: StepPhase, _ m: String) { trace.append("\(p.rawValue): \(m)"); onEvent?(.phase(p, m)) }
        func stopped() -> Bool { (try? stop.check(sinceGeneration: gen)) == nil || Task.isCancelled }

        var attempt = 0
        var lastFailure: StepOutcome = .failed(phase: .observe, reason: "not started")
        while attempt < config.maxAttempts {
            attempt += 1
            if stopped() { return StepReport(action: action, outcome: .stopped, attempts: attempt, risk: risk, trace: trace) }

            // 1. Observe
            let obs: GUIObservation
            do { obs = try await withTimeout(seconds: config.stepTimeout, operation: "observe") { try await driver.observe(scopeBundleID: scopeBundleID) } }
            catch { lastFailure = .failed(phase: .observe, reason: "\(error)"); note(.observe, "failed: \(error)"); continue }
            note(.observe, "\(obs.app?.name ?? "?") — \(obs.window?.title ?? "no window") (\(obs.root?.elementCount ?? 0) elements)")

            // 2. Identify
            let element: AXElementSnapshot?
            switch identify(action.target, in: obs, previous: previous, action: action) {
            case .success(let e): element = e
            case .failure(let why):
                note(.identify, why)
                lastFailure = .failed(phase: .identify, reason: why)
                try? await clock.sleep(seconds: config.settleDelay)
                continue
            }
            if let e = element { note(.identify, "[\(e.id)] \(e.role) \(e.displayName ?? "")") }

            // 3. Validate
            if let why = validate(action, element: element, obs: obs) {
                note(.validate, why)
                return StepReport(action: action, outcome: .failed(phase: .validate, reason: why), attempts: attempt, risk: risk, trace: trace, observationAfter: obs)
            }
            note(.validate, "ok")

            // 4. Authorize
            let assessment = policy.assess(action, element: element, observation: obs, scopeBundleID: scopeBundleID)
            risk = assessment.risk
            if assessment.risk == .prohibited {
                let why = assessment.reasons.joined(separator: "; ")
                note(.authorize, "prohibited: \(why)")
                return StepReport(action: action, outcome: .denied(reason: why), attempts: attempt, risk: risk, trace: trace, observationAfter: obs)
            }
            if assessment.requiresApproval && !approvedOnce {
                note(.authorize, "approval required (\(assessment.risk)): \(assessment.reasons.joined(separator: "; "))")
                let decision = await approvals.request(ApprovalRequest(
                    kind: .guiAction, title: action.summary,
                    detail: "In \(obs.app?.name ?? "app") — \(obs.window?.title ?? "")" + (element.map { " — target: \($0.role) \($0.displayName ?? "")" } ?? ""),
                    risk: assessment.risk, reasons: assessment.reasons, source: "computer-use"))
                guard decision.isApproved else {
                    if case .denied(let r) = decision { note(.authorize, "denied: \(r)"); return StepReport(action: action, outcome: .denied(reason: r), attempts: attempt, risk: risk, trace: trace, observationAfter: obs) }
                    return StepReport(action: action, outcome: .denied(reason: "denied"), attempts: attempt, risk: risk, trace: trace)
                }
                approvedOnce = true
                note(.authorize, "approved by user")
            } else {
                note(.authorize, approvedOnce ? "previously approved" : "auto-approved (\(assessment.risk))")
            }
            if stopped() { return StepReport(action: action, outcome: .stopped, attempts: attempt, risk: risk, trace: trace) }

            // Concurrent input conflict: do not fight the user for the mouse/keyboard.
            if let idle = await driver.secondsSinceUserInput(), idle < config.userInputGrace, needsExclusiveInput(action) {
                note(.execute, "user input detected \(String(format: "%.2f", idle))s ago — pausing")
                return StepReport(action: action, outcome: .failed(phase: .execute, reason: "user is using the keyboard/mouse; paused to avoid conflicting input"),
                                  attempts: attempt, risk: risk, trace: trace, observationAfter: obs)
            }

            // 5. Execute
            let primitives: [GUIPrimitive]
            do { primitives = try plan(action, element: element, obs: obs) }
            catch { return StepReport(action: action, outcome: .failed(phase: .execute, reason: "\(error)"), attempts: attempt, risk: risk, trace: trace, observationAfter: obs) }
            do {
                if case .wait(let cond, let to) = action {
                    let ok = try await waitFor(cond, timeout: to, scope: scopeBundleID)
                    note(.verify, ok ? "condition met" : "condition not met in \(to)s")
                    return StepReport(action: action, outcome: ok ? .succeeded(verification: "condition met") : .failed(phase: .verify, reason: "timed out waiting"),
                                      attempts: attempt, risk: risk, trace: trace)
                }
                for p in primitives {
                    if stopped() { return StepReport(action: action, outcome: .stopped, attempts: attempt, risk: risk, trace: trace) }
                    try await withTimeout(seconds: config.stepTimeout, operation: "execute") { try await driver.perform(p) }
                }
                note(.execute, primitives.map { "\($0)" }.joined(separator: ", "))
            } catch {
                note(.execute, "failed: \(error)")
                lastFailure = .failed(phase: .execute, reason: "\(error)")
                if case DriverError.permissionDenied = error { break }
                try? await clock.sleep(seconds: config.settleDelay)
                continue
            }

            // 6. Observe again + 7. Verify (poll briefly; UIs update asynchronously)
            try? await clock.sleep(seconds: config.settleDelay)
            var after: GUIObservation?
            var verdict: (Bool, String) = (false, "not verified")
            let deadline = clock.now().addingTimeInterval(config.verifyTimeout)
            repeat {
                if stopped() { return StepReport(action: action, outcome: .stopped, attempts: attempt, risk: risk, trace: trace) }
                after = try? await driver.observe(scopeBundleID: scopeBundleID)
                if let a = after { verdict = verify(action, element: element, before: obs, after: a) }
                if verdict.0 { break }
                try? await clock.sleep(seconds: config.pollInterval)
            } while clock.now() < deadline
            note(.reobserve, after.map { "\($0.window?.title ?? "")" } ?? "failed")
            note(.verify, verdict.1)
            if verdict.0 {
                return StepReport(action: action, outcome: .succeeded(verification: verdict.1), attempts: attempt, risk: risk, trace: trace, observationAfter: after)
            }
            lastFailure = .failed(phase: .verify, reason: verdict.1)
            // Retrying non-idempotent input could duplicate effects; only retry safe actions.
            if !isSafeToRetry(action) { break }
        }
        return StepReport(action: action, outcome: lastFailure, attempts: attempt, risk: risk, trace: trace)
    }

    enum Identified { case success(AXElementSnapshot?), failure(String) }

    func identify(_ target: ElementTarget?, in obs: GUIObservation, previous: GUIObservation?, action: GUIAction? = nil) -> Identified {
        guard let target else {
            // Untargeted typing goes to the focused text input, so it can be validated and verified.
            if case .typeText? = action, let fid = obs.focusedElementID, let f = obs.element(id: fid),
               AXElementSnapshot.textRoles.contains(f.role) { return .success(f) }
            return .success(nil)
        }
        guard let root = obs.root else { return .failure("no accessibility tree for the current window") }
        switch target {
        case .query(let q):
            switch q.resolve(in: root) {
            case .found(let e): return .success(e)
            case .notFound: return .failure("no element matches \(q)")
            case .ambiguous(let n): return .failure("\(n) elements match \(q); refine the query")
            }
        case .element(let id, let obsID):
            if obsID == obs.id, let e = obs.element(id: id) { return .success(e) }
            // Stale snapshot id: re-resolve through the element's identity in the old observation.
            guard let prev = previous, prev.id == obsID, let old = prev.element(id: id) else {
                return .failure("element [\(id)] refers to an unknown observation; re-observe and re-plan")
            }
            let identity = ElementIdentity(element: old, pid: prev.app?.pid)
            if let e = identity.resolve(in: root) { return .success(e) }
            return .failure("element [\(id)] (\(old.role) \(old.displayName ?? "")) is no longer present")
        case .point(let p, let obsID):
            guard obsID == obs.id || (previous?.id == obsID && previous?.stateFingerprint == obs.stateFingerprint) else {
                return .failure("coordinates \(p) came from an older observation and the UI changed; re-observe instead of clicking a guessed point")
            }
            // Prefer the accessibility element under the point if there is one.
            let hit = root.flattened().filter { $0.frame?.contains(p) == true && $0.isInteractive }.min { ($0.frame?.area ?? .infinity) < ($1.frame?.area ?? .infinity) }
            return .success(hit)
        }
    }

    func validate(_ action: GUIAction, element: AXElementSnapshot?, obs: GUIObservation) -> String? {
        if let e = element {
            if !e.isEnabled { return "target [\(e.id)] is disabled" }
            if let f = e.frame {
                if f.isEmpty { return "target has an empty frame (hidden?)" }
                if !obs.layout.displays.isEmpty && obs.layout.desktopBounds.intersection(f) == nil { return "target is off screen at \(f)" }
            } else if case .click = action, !e.actions.contains("AXPress") {
                return "target has no frame and no press action"
            }
        }
        switch action {
        case .click(let t, _, let count):
            if count < 1 || count > 3 { return "invalid click count \(count)" }
            if case .point(let p, _) = t, !obs.layout.displays.isEmpty, obs.layout.display(containing: p) == nil { return "point \(p) is not on any display" }
        case .typeText(_, let text, _, _):
            if text.isEmpty { return "empty text" }
            if text.count > 5000 { return "text too long (\(text.count) chars)" }
            if let e = element, !AXElementSnapshot.textRoles.contains(e.role), !e.isFocused, e.role != "AXWebArea" {
                return "target [\(e.id)] (\(e.role)) is not a text input"
            }
        case .selectMenu(let path):
            if path.count < 2 { return "menu path needs at least a menu and an item" }
            if obs.app == nil { return "no frontmost application" }
        case .scroll(_, _, let amount):
            if amount < 1 || amount > 50 { return "invalid scroll amount" }
        case .pressKeys(let k):
            if KeyCodes.code(for: k.key) == nil { return "unknown key \(k.key)" }
        case .focusApp(let a):
            if a.isEmpty { return "no app specified" }
        case .wait(_, let t):
            if t <= 0 || t > 120 { return "invalid wait timeout" }
        }
        return nil
    }

    func plan(_ action: GUIAction, element: AXElementSnapshot?, obs: GUIObservation) throws -> [GUIPrimitive] {
        let pid = obs.app?.pid
        switch action {
        case .click(let t, let button, let count):
            if let e = element, button == .left, count == 1, e.actions.contains("AXPress") {
                return [.axPress(ElementIdentity(element: e, pid: pid))]
            }
            if let f = element?.frame { return [.mouseClick(f.center, button, count: count)] }
            if case .point(let p, _) = t { return [.mouseClick(p, button, count: count)] }
            throw DriverError.unsupported("no way to click target")
        case .typeText(_, let text, let replace, let submit):
            var steps: [GUIPrimitive] = []
            if let e = element {
                let id = ElementIdentity(element: e, pid: pid)
                if e.isSecure {
                    // Secure fields: keyboard input only (values are not readable via AX anyway).
                    steps.append(.axFocus(id)); if replace { steps.append(.keyCombo(KeyCombo(key: "a", modifiers: [.command]))) }; steps.append(.typeKeystrokes(text))
                } else if replace {
                    steps.append(.axSetValue(id, text))
                } else {
                    steps.append(.axInsertText(id, text))   // AX insertion at the caret; driver falls back to keystrokes
                }
            } else {
                steps.append(.typeKeystrokes(text))
            }
            if submit { steps.append(.keyCombo(KeyCombo(key: "return"))) }
            return steps
        case .pressKeys(let k): return [.keyCombo(k)]
        case .selectMenu(let path):
            guard let pid else { throw DriverError.unsupported("no app for menu") }
            return [.menuPath(path, pid: pid)]
        case .scroll(_, let d, let a): return [.scroll(at: element?.frame?.center, d, amount: a)]
        case .focusApp(let a): return [.activateApp(a)]
        case .wait: return []
        }
    }

    func verify(_ action: GUIAction, element: AXElementSnapshot?, before: GUIObservation, after: GUIObservation) -> (Bool, String) {
        switch action {
        case .typeText(_, let text, let replace, let submit):
            guard let e = element, let root = after.root else {
                let changed = after.stateFingerprint != before.stateFingerprint
                return (changed, changed ? "UI changed after typing" : "no observable change after typing")
            }
            if submit {
                let changed = after.stateFingerprint != before.stateFingerprint
                return (changed, changed ? "UI changed after submit" : "no observable change after submit")
            }
            if e.isSecure { return (true, "secure field (value not readable)") }
            let identity = ElementIdentity(element: e, pid: before.app?.pid)
            guard let now = identity.resolve(in: root) else { return (false, "text field disappeared") }
            let v = now.value ?? ""
            let ok = replace ? v == text : v.contains(text)
            return (ok, ok ? "field value is now \"\(v.prefix(60))\"" : "field value \"\(v.prefix(60))\" does not contain typed text")
        case .click(_, _, _):
            if let e = element, ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle"].contains(e.role),
               let root = after.root, let now = ElementIdentity(element: e, pid: before.app?.pid).resolve(in: root) {
                let ok = now.value != e.value || now.isSelected != e.isSelected
                return (ok, ok ? "toggle state changed to \(now.value ?? "?")" : "toggle state unchanged")
            }
            if let e = element, AXElementSnapshot.textRoles.contains(e.role), let fid = after.focusedElementID,
               let f = after.element(id: fid), ElementIdentity(element: e, pid: before.app?.pid).matchScore(f) > 0 {
                return (true, "text field focused")
            }
            let changed = after.stateFingerprint != before.stateFingerprint
            return (changed, changed ? "UI changed after click" : "no observable UI change after click")
        case .selectMenu, .pressKeys:
            let changed = after.stateFingerprint != before.stateFingerprint
            // Some commands (copy) legitimately change nothing visible.
            return (true, changed ? "UI changed" : "command sent (no visible change)")
        case .scroll:
            return (true, after.stateFingerprint != before.stateFingerprint ? "content scrolled" : "scroll sent (may be at limit)")
        case .focusApp(let a):
            let ok = after.app?.bundleID == a || after.app?.name == a
            return (ok, ok ? "\(a) is frontmost" : "\(a) did not come to front")
        case .wait:
            return (true, "")
        }
    }

    func waitFor(_ cond: WaitCondition, timeout: Double, scope: String?) async throws -> Bool {
        let deadline = clock.now().addingTimeInterval(timeout)
        repeat {
            try stop.check(sinceGeneration: stop.currentGeneration)
            if let obs = try? await driver.observe(scopeBundleID: scope), Self.evaluate(cond, obs) { return true }
            try await clock.sleep(seconds: config.pollInterval)
        } while clock.now() < deadline
        return false
    }

    public static func evaluate(_ cond: WaitCondition, _ obs: GUIObservation) -> Bool {
        switch cond {
        case .elementExists(let q): return obs.root.map { !q.resolveAll(in: $0).isEmpty } ?? false
        case .elementGone(let q): return obs.root.map { q.resolveAll(in: $0).isEmpty } ?? true
        case .valueEquals(let q, let v): if case .found(let e) = obs.root.map({ q.resolve(in: $0) }) ?? .notFound { return e.value == v }; return false
        case .windowTitleContains(let t): return obs.window?.title?.localizedCaseInsensitiveContains(t) ?? false
        case .appFrontmost(let a): return obs.app?.bundleID == a || obs.app?.name == a
        }
    }

    func isSafeToRetry(_ a: GUIAction) -> Bool {
        switch a {
        case .typeText(_, _, let replace, let submit): return replace && !submit
        case .scroll, .focusApp, .wait: return true
        case .click(let t, _, _): if case .query = t { return false }; return false
        default: return false
        }
    }

    func needsExclusiveInput(_ a: GUIAction) -> Bool {
        switch a { case .wait: return false; default: return true }
    }
}

/// Virtual key codes (US layout) for CGEvent; also used for validation on all platforms.
public enum KeyCodes {
    public static let table: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
    public static func code(for key: String) -> UInt16? { table[key.lowercased()] }
}
