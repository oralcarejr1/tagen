#if os(macOS)
import AppKit
@preconcurrency import ApplicationServices
import TagenCore

/// GUIDriver backed by the Accessibility API (preferred) and CGEvent (fallback).
public final class MacGUIDriver: GUIDriver, @unchecked Sendable {
    private let handles = Locked<[UUID: [String: AXElement]]>([:])
    private let order = Locked<[UUID]>([])
    private let lastOwnEvent = Locked<Date>(.distantPast)
    private let excludePID: pid_t
    private let lastPID = Locked<pid_t?>(nil)
    let eventSource = CGEventSource(stateID: .privateState)

    public init(excludePID: pid_t = ProcessInfo.processInfo.processIdentifier) { self.excludePID = excludePID }

    func targetApp(scope: String?) -> NSRunningApplication? {
        if let s = scope {
            if let a = NSRunningApplication.runningApplications(withBundleIdentifier: s).first { return a }
            if let a = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == s }) { return a }
        }
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != excludePID { return f }
        return nil
    }

    public func observe(scopeBundleID: String?) async throws -> GUIObservation {
        guard AXInspector.isTrusted else { throw DriverError.permissionDenied("Accessibility") }
        let layout = await MainActor.run { MacDisplays.layout() }
        guard let app = targetApp(scope: scopeBundleID) else { throw DriverError.elementNotFound("no target application") }
        let axApp = AXInspector.application(pid: app.processIdentifier)
        lastPID.set(app.processIdentifier)
        let id = UUID()
        var root: AXElementSnapshot?
        var window: WindowInfo?
        var focused: String?
        if let w = AXInspector.focusedWindow(of: axApp) {
            let snap = AXInspector.snapshot(window: w, maxDepth: 30, maxElements: 2000)
            root = snap.root; focused = snap.focusedID
            window = AXInspector.windowInfo(w)
            handles.withLock { $0[id] = snap.handles }
            order.withLock { o in
                o.append(id)
                if o.count > 4 { let old = o.removeFirst(); handles.withLock { $0[old] = nil } }
            }
        }
        return GUIObservation(id: id, app: AppInfo(name: app.localizedName ?? "", bundleID: app.bundleIdentifier, pid: app.processIdentifier),
                              window: window, root: root, focusedElementID: focused, layout: layout, menuBar: AXInspector.menuBar(of: axApp))
    }

    /// Find the live handle for an identity: newest observation first, verifying role/title.
    func handle(for identity: ElementIdentity) throws -> AXElement {
        let ids = order.current.reversed()
        for oid in ids {
            if let h = handles.current[oid]?[identity.path] {
                let role = h.string(kAXRoleAttribute as String)
                let title = h.string(kAXTitleAttribute as String)
                if role == identity.role && (identity.title == nil || identity.title == title) { return h }
            }
        }
        // Re-resolve against a fresh snapshot.
        guard let pid = identity.pid else { throw DriverError.elementNotFound("no pid") }
        guard let w = AXInspector.focusedWindow(of: AXInspector.application(pid: pid)) else { throw DriverError.elementNotFound("no window") }
        let snap = AXInspector.snapshot(window: w, maxDepth: 30, maxElements: 2000)
        guard let root = snap.root, let e = identity.resolve(in: root), let h = snap.handles[e.id] else {
            throw DriverError.elementNotFound("\(identity.role) \(identity.title ?? identity.identifier ?? "")")
        }
        return h
    }

    public func perform(_ p: GUIPrimitive) async throws {
        guard AXInspector.isTrusted else { throw DriverError.permissionDenied("Accessibility") }
        defer { lastOwnEvent.set(Date()) }
        switch p {
        case .axPress(let id):
            let h = try handle(for: id)
            let err = h.perform(kAXPressAction as String)
            guard err == .success else {
                if let f = h.frame { try click(at: f.center, button: .left, count: 1); return }
                throw DriverError.actionFailed("AXPress error \(err.rawValue)")
            }
        case .axSetValue(let id, let text):
            let h = try handle(for: id)
            h.set(kAXFocusedAttribute as String, kCFBooleanTrue)
            let err = h.set(kAXValueAttribute as String, text as CFString)
            guard err == .success else {
                // Fallback: focus + select all + type.
                if let f = h.frame { try click(at: f.center, button: .left, count: 1) }
                try key(KeyCombo(key: "a", modifiers: [.command]))
                try type(text, pid: id.pid)
                return
            }
        case .axInsertText(let id, let text):
            let h = try handle(for: id)
            h.set(kAXFocusedAttribute as String, kCFBooleanTrue)
            let before = h.string(kAXValueAttribute as String)
            let err = h.set(kAXSelectedTextAttribute as String, text as CFString)
            let after = h.string(kAXValueAttribute as String)
            if err != .success || (before != nil && after == before) {
                // AX insertion unsupported here: fall back to keystrokes into the focused field.
                if let f = h.frame { try click(at: f.center, button: .left, count: 1) }
                try type(text, pid: id.pid)
            }
        case .axFocus(let id):
            let h = try handle(for: id)
            if h.set(kAXFocusedAttribute as String, kCFBooleanTrue) != .success, let f = h.frame { try click(at: f.center, button: .left, count: 1) }
        case .axShowMenu(let id):
            let h = try handle(for: id)
            guard h.perform(kAXShowMenuAction as String) == .success else { throw DriverError.actionFailed("AXShowMenu failed") }
        case .mouseClick(let pt, let b, let n): try click(at: pt, button: b, count: n)
        case .typeKeystrokes(let t): try type(t, pid: lastPID.current)
        case .keyCombo(let k): try key(k)
        case .menuPath(let path, let pid): try selectMenu(path, pid: pid)
        case .scroll(let at, let d, let amount): try scroll(at: at, d, amount: amount)
        case .activateApp(let a):
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: a).first
                    ?? NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == a }) else {
                throw DriverError.elementNotFound("app \(a) is not running")
            }
            app.activate()
        }
    }

    public func secondsSinceUserInput() async -> Double? {
        let any = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
        // Ignore input that is plausibly our own synthetic events.
        let sinceOwn = Date().timeIntervalSince(lastOwnEvent.current)
        if sinceOwn <= idle + 0.25 { return nil }
        return idle
    }

    // MARK: CGEvent primitives

    func click(at p: Point, button: MouseButton, count: Int) throws {
        let pt = p.cgPoint
        let (down, up, btn): (CGEventType, CGEventType, CGMouseButton) = button == .left ? (.leftMouseDown, .leftMouseUp, .left) : (.rightMouseDown, .rightMouseUp, .right)
        guard let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: btn) else { throw DriverError.actionFailed("CGEvent") }
        move.post(tap: .cghidEventTap)
        usleep(30_000)
        for i in 1...max(1, count) {
            guard let d = CGEvent(mouseEventSource: eventSource, mouseType: down, mouseCursorPosition: pt, mouseButton: btn),
                  let u = CGEvent(mouseEventSource: eventSource, mouseType: up, mouseCursorPosition: pt, mouseButton: btn) else { throw DriverError.actionFailed("CGEvent") }
            d.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            u.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            d.post(tap: .cghidEventTap); usleep(20_000); u.post(tap: .cghidEventTap); usleep(40_000)
        }
    }

    /// Unicode keystrokes. Delivered directly to the target process when known (does not depend
    /// on which app the HID event system routes to), with spacing between down and up.
    func type(_ text: String, pid: pid_t?) throws {
        for ch in text {
            let utf16 = Array(String(ch).utf16)
            guard let d = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
                  let u = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else { throw DriverError.actionFailed("CGEvent") }
            d.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            u.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            if let pid { d.postToPid(pid); usleep(8_000); u.postToPid(pid) }
            else { d.post(tap: .cghidEventTap); usleep(8_000); u.post(tap: .cghidEventTap) }
            usleep(8_000)
        }
    }

    func key(_ k: KeyCombo) throws {
        guard let code = KeyCodes.code(for: k.key) else { throw DriverError.unsupported("key \(k.key)") }
        var flags: CGEventFlags = []
        for m in k.modifiers {
            switch m {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            }
        }
        guard let d = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(code), keyDown: true),
              let u = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(code), keyDown: false) else { throw DriverError.actionFailed("CGEvent") }
        d.flags = flags; u.flags = flags
        d.post(tap: .cghidEventTap); usleep(20_000); u.post(tap: .cghidEventTap)
    }

    func scroll(at p: Point?, _ d: ScrollDirection, amount: Int) throws {
        if let p, let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: p.cgPoint, mouseButton: .left) {
            move.post(tap: .cghidEventTap); usleep(30_000)
        }
        let dy: Int32 = d == .up ? Int32(amount) : d == .down ? -Int32(amount) : 0
        let dx: Int32 = d == .left ? Int32(amount) : d == .right ? -Int32(amount) : 0
        guard let e = CGEvent(scrollWheelEvent2Source: eventSource, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
            throw DriverError.actionFailed("scroll event")
        }
        e.post(tap: .cghidEventTap)
    }

    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    func selectMenu(_ path: [String], pid: pid_t) throws {
        let app = AXInspector.application(pid: pid)
        guard let bar = app.element(kAXMenuBarAttribute as String) else { throw DriverError.elementNotFound("menu bar") }
        var container = bar
        for (i, title) in path.enumerated() {
            let items = container.elements(kAXChildrenAttribute as String)
            guard let item = items.first(where: { Self.normalize($0.string(kAXTitleAttribute as String) ?? "") == Self.normalize(title) }) else {
                throw DriverError.elementNotFound("menu item \"\(title)\"")
            }
            if item.bool(kAXEnabledAttribute as String) == false { throw DriverError.actionFailed("menu item \"\(title)\" is disabled") }
            if i == path.count - 1 {
                guard item.perform(kAXPressAction as String) == .success else { throw DriverError.actionFailed("could not press \"\(title)\"") }
                return
            }
            guard let submenu = item.elements(kAXChildrenAttribute as String).first else { throw DriverError.elementNotFound("submenu of \"\(title)\"") }
            container = submenu
        }
    }
}

extension String {
    func chunked(into n: Int) -> [String] {
        var out: [String] = []; var cur = ""
        for ch in self { cur.append(ch); if cur.count >= n { out.append(cur); cur = "" } }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
#endif
