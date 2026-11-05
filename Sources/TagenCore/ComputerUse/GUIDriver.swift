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
}
