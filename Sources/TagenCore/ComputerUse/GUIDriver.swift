import Foundation

/// A fresh observation of the UI the automation operates on.
public struct GUIObservation: Sendable, Equatable {
    public var id: UUID
    public var timestamp: Date
    public var app: AppInfo?
    public var window: WindowInfo?
    public var root: AXElementSnapshot?
    public var focusedElementID: String?
    public var layout: DisplayLayout
    public var menuBar: [String: [String]]   // top-level title → visible items (best effort)

    public init(id: UUID = UUID(), timestamp: Date = Date(), app: AppInfo?, window: WindowInfo?, root: AXElementSnapshot?,
                focusedElementID: String? = nil, layout: DisplayLayout, menuBar: [String: [String]] = [:]) {
        self.id = id; self.timestamp = timestamp; self.app = app; self.window = window; self.root = root
        self.focusedElementID = focusedElementID; self.layout = layout; self.menuBar = menuBar
    }

    public func element(id: String) -> AXElementSnapshot? { root?.find(id: id) }

    /// Fingerprint of observable UI state (used to detect "something changed").
    public var stateFingerprint: Int {
        var h = Hasher()
        h.combine(app?.bundleID); h.combine(window?.title)
        h.combine(focusedElementID)
        for e in root?.flattened() ?? [] { h.combine(e.role); h.combine(e.title); h.combine(e.value); h.combine(e.isEnabled); h.combine(e.isSelected); h.combine(e.isFocused) }
        return h.finalize()
    }

    public func asScreenContext() -> ScreenContext {
        ScreenContext(id: id, capturedAt: timestamp, app: app, window: window, axRoot: root, focusedElementID: focusedElementID, layout: layout)
    }
}

/// Primitive operations after the target has been resolved and validated.
public enum GUIPrimitive: Sendable, Equatable {
    case axPress(ElementIdentity)
    case axSetValue(ElementIdentity, String)
    /// Insert text at the caret / replace the current selection (AXSelectedText).
    case axInsertText(ElementIdentity, String)
    case axFocus(ElementIdentity)
    case axShowMenu(ElementIdentity)
    case mouseClick(Point, MouseButton, count: Int)
    case typeKeystrokes(String)
    case keyCombo(KeyCombo)
    case menuPath([String], pid: Int32)
    case scroll(at: Point?, ScrollDirection, amount: Int)
    case activateApp(String)
}

public enum DriverError: Error, Sendable, Equatable, CustomStringConvertible {
    case permissionDenied(String)
    case elementNotFound(String)
    case actionFailed(String)
    case unsupported(String)
    public var description: String {
        switch self {
        case .permissionDenied(let m): return "Permission denied: \(m)"
        case .elementNotFound(let m): return "Element not found: \(m)"
        case .actionFailed(let m): return "Action failed: \(m)"
        case .unsupported(let m): return "Unsupported: \(m)"
        }
    }
}

/// OS boundary for GUI automation. Implemented by TagenMac.MacGUIDriver (AXUIElement +
/// CGEvent). Tests use an in-memory model of a UI (clearly a simulation).
public protocol GUIDriver: Sendable {
    /// Observe the frontmost (or `scopeBundleID`) application's focused window.
    func observe(scopeBundleID: String?) async throws -> GUIObservation
    func perform(_ primitive: GUIPrimitive) async throws
    /// Seconds since the last *physical* user input, if the platform can tell.
    func secondsSinceUserInput() async -> Double?
    /// Screenshot of the observed window (for planners on apps with little accessibility text).
    func captureWindow(_ observation: GUIObservation) async -> CapturedImage?
}

extension GUIDriver {
    public func captureWindow(_ observation: GUIObservation) async -> CapturedImage? { nil }
}

/// Human-readable differences between two observations (helps the planner verify its last step).
public enum ObservationDiff {
    public static func lines(from old: GUIObservation, to new: GUIObservation, limit: Int = 15) -> [String] {
        var out: [String] = []
        if old.app?.bundleID != new.app?.bundleID { out.append("frontmost app: \(old.app?.name ?? "?") → \(new.app?.name ?? "?")") }
        if old.window?.title != new.window?.title { out.append("window title: \"\(old.window?.title ?? "")\" → \"\(new.window?.title ?? "")\"") }
        guard let o = old.root, let n = new.root else { return out }
        func key(_ e: AXElementSnapshot) -> String? {
            if let i = e.identifier, !i.isEmpty { return "\(e.role)#\(i)" }
            if let t = e.title, !t.isEmpty { return "\(e.role)|\(t)" }
            return nil
        }
        var before: [String: AXElementSnapshot] = [:]
        for e in o.flattened() { if let k = key(e), before[k] == nil { before[k] = e } }
        var seen = Set<String>()
        for e in n.flattened() {
            guard let k = key(e), seen.insert(k).inserted else { continue }
            if let b = before[k] {
                if b.value != e.value && !e.isSecure { out.append("[\(e.id)] \(e.displayName ?? k) value: \"\(b.value?.prefix(60) ?? "")\" → \"\(e.value?.prefix(60) ?? "")\"") }
                if b.isEnabled != e.isEnabled { out.append("[\(e.id)] \(e.displayName ?? k) \(e.isEnabled ? "enabled" : "disabled")") }
                if b.isFocused != e.isFocused && e.isFocused { out.append("[\(e.id)] \(e.displayName ?? k) focused") }
            } else {
                out.append("appeared: [\(e.id)] \(e.role.replacingOccurrences(of: "AX", with: "")) \(e.displayName ?? "")")
            }
            if out.count >= limit { break }
        }
        let after = Set(n.flattened().compactMap(key))
        for (k, e) in before where !after.contains(k) && out.count < limit {
            out.append("disappeared: \(e.role.replacingOccurrences(of: "AX", with: "")) \(e.displayName ?? k)")
        }
        return out
    }
}
