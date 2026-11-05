#if os(macOS)
@preconcurrency import ApplicationServices
import AppKit
import TagenCore

/// Sendable wrapper around an AXUIElement reference.
public struct AXElement: @unchecked Sendable, Hashable {
    public let ref: AXUIElement
    public init(_ ref: AXUIElement) { self.ref = ref }
    public static func == (a: AXElement, b: AXElement) -> Bool { CFEqual(a.ref, b.ref) }
    public func hash(into h: inout Hasher) { h.combine(CFHash(ref)) }

    public func attribute(_ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(ref, name as CFString, &v)
        return err == .success ? v : nil
    }
    public func string(_ name: String) -> String? {
        guard let v = attribute(name) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let a = v as? NSAttributedString { return a.string }
        if let u = v as? URL { return u.absoluteString }
        return nil
    }
    public func bool(_ name: String) -> Bool? { (attribute(name) as? NSNumber)?.boolValue }
    public func element(_ name: String) -> AXElement? {
        guard let v = attribute(name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return AXElement(v as! AXUIElement)
    }
    public func elements(_ name: String) -> [AXElement] {
        guard let arr = attribute(name) as? [AnyObject] else { return [] }
        return arr.compactMap { o in CFGetTypeID(o) == AXUIElementGetTypeID() ? AXElement(o as! AXUIElement) : nil }
    }
    public var frame: Rect? {
        guard let pv = attribute(kAXPositionAttribute as String), let sv = attribute(kAXSizeAttribute as String),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return Rect(x: Double(p.x), y: Double(p.y), width: Double(s.width), height: Double(s.height))
    }
    public var actions: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(ref, &names) == .success, let a = names as? [String] else { return [] }
        return a
    }
    public func isSettable(_ name: String) -> Bool {
        var s: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(ref, name as CFString, &s) == .success && s.boolValue
    }
    @discardableResult
    public func set(_ name: String, _ value: CFTypeRef) -> AXError { AXUIElementSetAttributeValue(ref, name as CFString, value) }
    @discardableResult
    public func perform(_ action: String) -> AXError { AXUIElementPerformAction(ref, action as CFString) }
    public var pid: pid_t? { var p: pid_t = 0; return AXUIElementGetPid(ref, &p) == .success ? p : nil }
}

/// Snapshot of a window's accessibility tree plus live handles for later actions.
public struct AXSnapshotResult: @unchecked Sendable {
    public var root: AXElementSnapshot?
    public var handles: [String: AXElement]
    public var focusedID: String?
    public var truncated: Bool
}

public enum AXInspector {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func application(pid: pid_t) -> AXElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        return AXElement(app)
    }

    public static func focusedWindow(of app: AXElement) -> AXElement? {
        app.element(kAXFocusedWindowAttribute as String) ?? app.element(kAXMainWindowAttribute as String)
            ?? app.elements(kAXWindowsAttribute as String).first
    }

    public static func windowInfo(_ w: AXElement) -> WindowInfo {
        WindowInfo(title: w.string(kAXTitleAttribute as String), frame: w.frame ?? .zero, windowID: nil,
                   isFullScreen: w.bool("AXFullScreen") ?? false, isMinimized: w.bool(kAXMinimizedAttribute as String) ?? false)
    }

    static let snapshotAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
        kAXIdentifierAttribute, kAXPlaceholderValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute,
        kAXFocusedAttribute, kAXSelectedAttribute, kAXChildrenAttribute,
    ].map { $0 as String }

    /// Depth-first snapshot with element/depth limits. Uses batched attribute reads.
    /// - Parameter timeBudget: seconds; traversal stops (marked truncated) when exceeded, so huge trees
    ///   (e.g. long web pages) cannot stall the assistant.
    public static func snapshot(window: AXElement, maxDepth: Int = 25, maxElements: Int = 1500, rootID: String = "w0",
                                timeBudget: Double? = nil) -> AXSnapshotResult {
        let deadline = timeBudget.map { CFAbsoluteTimeGetCurrent() + $0 }
        var handles: [String: AXElement] = [:]
        var count = 0
        var truncated = false
        var focusedID: String?

        func node(_ el: AXElement, id: String, depth: Int) -> AXElementSnapshot? {
            if count >= maxElements { truncated = true; return nil }
            if let d = deadline, CFAbsoluteTimeGetCurrent() > d { truncated = true; return nil }
            count += 1
            var values: CFArray?
            let err = AXUIElementCopyMultipleAttributeValues(el.ref, snapshotAttributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
            guard err == .success, let vals = values as? [AnyObject], vals.count == snapshotAttributes.count else { return nil }
            func str(_ i: Int) -> String? {
                let v = vals[i]
                if CFGetTypeID(v) == AXValueGetTypeID() { return nil }
                if let s = v as? String { return s.isEmpty ? nil : s }
                if let n = v as? NSNumber { return n.stringValue }
                if let a = v as? NSAttributedString { return a.string }
                return nil
            }
            func boolAt(_ i: Int) -> Bool? { (vals[i] as? NSNumber)?.boolValue }
            var frame: Rect?
            let pv = vals[8], sv = vals[9]
            if CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() {
                var p = CGPoint.zero, s = CGSize.zero
                if AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) {
                    frame = Rect(x: Double(p.x), y: Double(p.y), width: Double(s.width), height: Double(s.height))
                }
            }
            let role = str(0) ?? "AXUnknown"
            let subrole = str(1)
            let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
            var value = secure ? nil : str(3)
            if let v = value, v.count > 2000 { value = String(v.prefix(2000)) + "…" }
            handles[id] = el
            let focused = boolAt(11) ?? false
            if focused { focusedID = id }
            var children: [AXElementSnapshot] = []
            if depth < maxDepth, let kids = vals[13] as? [AnyObject] {
                // Menu bars are observed separately; skip them inside windows.
                for (i, k) in kids.enumerated() where CFGetTypeID(k) == AXUIElementGetTypeID() {
                    if let c = node(AXElement(k as! AXUIElement), id: "\(id).\(i)", depth: depth + 1) { children.append(c) }
                    if count >= maxElements { truncated = true; break }
                }
            } else if depth >= maxDepth { truncated = true }
            return AXElementSnapshot(id: id, role: role, subrole: subrole, title: str(2), value: value, label: str(4), help: str(5),
                                     identifier: str(6), placeholder: str(7), frame: frame, isEnabled: boolAt(10) ?? true,
                                     isFocused: focused, isSelected: boolAt(12) ?? false, isSecure: secure,
                                     actions: role == "AXUnknown" ? [] : el.actions, children: children)
        }
        let root = node(window, id: rootID, depth: 0)
        return AXSnapshotResult(root: root, handles: handles, focusedID: focusedID, truncated: truncated)
    }

    /// The focused UI element system-wide.
    public static func systemFocusedElement() -> AXElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 1.0)
        return AXElement(sys).element(kAXFocusedUIElementAttribute as String)
    }

    /// Selected text via kAXSelectedTextAttribute. Does not touch the clipboard.
    public static func selectedText() -> SelectedText? {
        guard let el = systemFocusedElement() else { return nil }
        guard let text = el.string(kAXSelectedTextAttribute as String), !text.isEmpty else { return nil }
        let editable = el.isSettable(kAXSelectedTextAttribute as String) || el.isSettable(kAXValueAttribute as String)
        var frame: Rect?
        if let rangeV = el.attribute(kAXSelectedTextRangeAttribute as String) {
            var bounds: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el.ref, kAXBoundsForRangeParameterizedAttribute as CFString, rangeV, &bounds) == .success,
               let b = bounds, CFGetTypeID(b) == AXValueGetTypeID() {
                var r = CGRect.zero
                if AXValueGetValue(b as! AXValue, .cgRect, &r) { frame = Rect(r) }
            }
        }
        return SelectedText(text: text, source: .accessibility, elementID: nil, isEditable: editable, frame: frame ?? el.frame)
    }

    /// Replace the current selection in the focused element (only called after user approval).
    /// Returns true if the change is observable afterwards.
    public static func replaceSelection(with text: String, expectedOriginal: String) -> Bool {
        guard let el = systemFocusedElement() else { return false }
        guard el.string(kAXSelectedTextAttribute as String) == expectedOriginal else { return false }  // selection changed
        guard el.set(kAXSelectedTextAttribute as String, text as CFString) == .success else { return false }
        if let v = el.string(kAXValueAttribute as String) { return v.contains(text) }
        return true
    }

    /// Visible menu bar titles (best-effort) for planner context.
    public static func menuBar(of app: AXElement) -> [String: [String]] {
        guard let bar = app.element(kAXMenuBarAttribute as String) else { return [:] }
        var out: [String: [String]] = [:]
        for item in bar.elements(kAXChildrenAttribute as String).prefix(12) {
            guard let title = item.string(kAXTitleAttribute as String), !title.isEmpty, title != "Apple" else { continue }
            let menu = item.elements(kAXChildrenAttribute as String).first
            out[title] = (menu?.elements(kAXChildrenAttribute as String) ?? []).prefix(40).compactMap { $0.string(kAXTitleAttribute as String) }.filter { !$0.isEmpty }
        }
        return out
    }

    /// URL of a browser's web area, when exposed.
    public static func documentURL(window: AXElement) -> String? {
        if let d = window.string(kAXDocumentAttribute as String), d.hasPrefix("http") || d.hasPrefix("file") { return d }
        var queue: [(AXElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 200 {
            let (el, depth) = queue.removeFirst(); visited += 1
            if el.string(kAXRoleAttribute as String) == "AXWebArea", let u = el.string("AXURL") { return u }
            if depth < 6 { queue += el.elements(kAXChildrenAttribute as String).map { ($0, depth + 1) } }
        }
        return nil
    }
}
#endif
