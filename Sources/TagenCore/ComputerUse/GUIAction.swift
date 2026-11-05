import Foundation

/// Query that locates an element in a fresh observation. All non-nil fields must match.
public struct ElementQuery: Sendable, Codable, Equatable, Hashable, CustomStringConvertible {
    public var role: String?
    public var title: String?
    public var titleContains: String?
    public var identifier: String?
    public var label: String?
    public var value: String?
    /// 0-based index among matches (document order) when several match.
    public var index: Int?

    public init(role: String? = nil, title: String? = nil, titleContains: String? = nil, identifier: String? = nil,
                label: String? = nil, value: String? = nil, index: Int? = nil) {
        self.role = role; self.title = title; self.titleContains = titleContains; self.identifier = identifier
        self.label = label; self.value = value; self.index = index
    }

    public func matches(_ e: AXElementSnapshot) -> Bool {
        if let r = role, e.role != r && "AX" + r != e.role { return false }
        if let t = title, e.title != t && e.label != t { return false }
        if let tc = titleContains?.lowercased() {
            let hay = [e.title, e.label, e.placeholder, e.help].compactMap { $0?.lowercased() }
            if !hay.contains(where: { $0.contains(tc) }) { return false }
        }
        if let i = identifier, e.identifier != i { return false }
        if let l = label, e.label != l { return false }
        if let v = value, e.value != v { return false }
        return role != nil || title != nil || titleContains != nil || identifier != nil || label != nil || value != nil
    }

    public func resolveAll(in root: AXElementSnapshot) -> [AXElementSnapshot] { root.flattened().filter(matches) }

    /// Unique resolution: exactly one match, or `index` selects one.
    public func resolve(in root: AXElementSnapshot) -> ElementResolution {
        let all = resolveAll(in: root)
        if let i = index { return i < all.count ? .found(all[i]) : .notFound }
        switch all.count {
        case 0: return .notFound
        case 1: return .found(all[0])
        default: return .ambiguous(all.count)
        }
    }

    public var description: String {
        [role.map { "role=\($0)" }, title.map { "title=\"\($0)\"" }, titleContains.map { "title~\"\($0)\"" },
         identifier.map { "id=\($0)" }, label.map { "label=\"\($0)\"" }, value.map { "value=\"\($0)\"" }, index.map { "#\($0)" }]
            .compactMap { $0 }.joined(separator: " ")
    }
}

public enum ElementResolution: Sendable, Equatable {
    case found(AXElementSnapshot)
    case notFound
    case ambiguous(Int)
}

/// How an action designates its target.
public enum ElementTarget: Sendable, Codable, Equatable, CustomStringConvertible {
    /// Snapshot element id, valid only for the observation it came from.
    case element(id: String, observationID: UUID)
    /// Re-resolvable query (preferred for scripted automation).
    case query(ElementQuery)
    /// Global screen point (screenshot fallback), valid only for the observation it came from.
    case point(Point, observationID: UUID)

    public var description: String {
        switch self {
        case .element(let id, _): return "[\(id)]"
        case .query(let q): return "{\(q)}"
        case .point(let p, _): return "point \(p)"
        }
    }
}

public enum MouseButton: String, Sendable, Codable { case left, right }
public enum ScrollDirection: String, Sendable, Codable { case up, down, left, right }
public enum KeyModifier: String, Sendable, Codable, CaseIterable { case command, shift, option, control }

public struct KeyCombo: Sendable, Codable, Equatable, CustomStringConvertible {
    public var key: String
    public var modifiers: [KeyModifier]
    public init(key: String, modifiers: [KeyModifier] = []) { self.key = key.lowercased(); self.modifiers = modifiers }

    /// Parses "cmd+shift+s", "⌘S", "return", "ctrl+c".
    public static func parse(_ s: String) -> KeyCombo? {
        var mods: [KeyModifier] = []
        var rest = s.trimmingCharacters(in: .whitespaces)
        let symbols: [(Character, KeyModifier)] = [("⌘", .command), ("⇧", .shift), ("⌥", .option), ("⌃", .control)]
        while let f = rest.first, let m = symbols.first(where: { $0.0 == f }) { mods.append(m.1); rest.removeFirst() }
        let parts = rest.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let key = parts.last, !key.isEmpty else { return nil }
        for p in parts.dropLast() {
            switch p {
            case "cmd", "command", "meta", "super": mods.append(.command)
            case "shift": mods.append(.shift)
            case "opt", "option", "alt": mods.append(.option)
            case "ctrl", "control": mods.append(.control)
            default: return nil
            }
        }
        return KeyCombo(key: key, modifiers: mods)
    }

    public var description: String {
        let m = modifiers.map { ["command": "⌘", "shift": "⇧", "option": "⌥", "control": "⌃"][$0.rawValue]! }.joined()
        let names = ["space": "Space", "return": "↩", "enter": "⌅", "tab": "⇥", "escape": "⎋", "esc": "⎋",
                     "delete": "⌫", "backspace": "⌫", "forwarddelete": "⌦", "left": "←", "right": "→", "up": "↑", "down": "↓"]
        return m + (names[key] ?? key.uppercased())
    }
}

public enum WaitCondition: Sendable, Codable, Equatable {
    case elementExists(ElementQuery)
    case elementGone(ElementQuery)
    case valueEquals(ElementQuery, String)
    case windowTitleContains(String)
    case appFrontmost(String)
}

/// Typed GUI action. Every field is validated before execution.
public enum GUIAction: Sendable, Codable, Equatable {
    case click(ElementTarget, button: MouseButton = .left, count: Int = 1)
    case typeText(ElementTarget?, text: String, replaceExisting: Bool = true, submit: Bool = false)
    case pressKeys(KeyCombo)
    case selectMenu(path: [String])
    case scroll(ElementTarget?, direction: ScrollDirection, amount: Int = 3)
    case focusApp(String)
    case wait(WaitCondition, timeout: Double = 5)

    public var name: String {
        switch self {
        case .click: return "click"
        case .typeText: return "type"
        case .pressKeys: return "keys"
        case .selectMenu: return "menu"
        case .scroll: return "scroll"
        case .focusApp: return "focus_app"
        case .wait: return "wait"
        }
    }

    public var target: ElementTarget? {
        switch self {
        case .click(let t, _, _): return t
        case .typeText(let t, _, _, _): return t
        case .scroll(let t, _, _): return t
        default: return nil
        }
    }

    public var summary: String {
        switch self {
        case .click(let t, let b, let c): return "\(c == 2 ? "Double-click" : b == .right ? "Right-click" : "Click") \(t)"
        case .typeText(let t, let text, let rep, let submit):
            return "Type \"\(text.prefix(60))\"\(t.map { " into \($0)" } ?? "")\(rep ? " (replace)" : "")\(submit ? " and press Return" : "")"
        case .pressKeys(let k): return "Press \(k)"
        case .selectMenu(let p): return "Menu " + p.joined(separator: " › ")
        case .scroll(let t, let d, let a): return "Scroll \(d.rawValue) ×\(a)\(t.map { " in \($0)" } ?? "")"
        case .focusApp(let a): return "Switch to \(a)"
        case .wait(let c, let to): return "Wait for \(c) (≤\(Int(to))s)"
        }
    }
}
