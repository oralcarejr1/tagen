import Foundation

/// Global shortcuts the user can rebind.
public enum HotkeyAction: String, Sendable, Codable, CaseIterable, CodingKeyRepresentable {
    case toggleAssistant, pushToTalk, emergencyStop, explainSelection, guide, region

    public func title(_ lang: LanguageCode) -> String {
        switch (self, lang) {
        case (.toggleAssistant, .korean): return "어시스턴트 열기/닫기"
        case (.pushToTalk, .korean): return "누른 채 말하기"
        case (.emergencyStop, .korean): return "긴급 정지"
        case (.explainSelection, .korean): return "선택 텍스트 설명"
        case (.guide, .korean): return "가이드 모드"
        case (.region, .korean): return "화면 영역 질문"
        case (.toggleAssistant, _): return "Toggle assistant"
        case (.pushToTalk, _): return "Push-to-talk (hold)"
        case (.emergencyStop, _): return "Emergency stop"
        case (.explainSelection, _): return "Explain selection"
        case (.guide, _): return "Guide mode"
        case (.region, _): return "Ask about a screen region"
        }
    }
}

public enum HotkeyBindings {
    public static let defaults: [HotkeyAction: KeyCombo] = [
        .toggleAssistant: KeyCombo(key: "space", modifiers: [.option]),
        // Not ⌃Space / ⌃⌥Space: those are macOS's input-source shortcuts (Korean/English switching,
        // and the target of common Karabiner "right ⌘ → 한/영" rules). See SystemShortcut.
        .pushToTalk: KeyCombo(key: "space", modifiers: [.option, .shift]),
        .emergencyStop: KeyCombo(key: ".", modifiers: [.control, .option, .command]),
        .explainSelection: KeyCombo(key: "s", modifiers: [.option, .shift]),
        .guide: KeyCombo(key: "g", modifiers: [.option, .shift]),
        .region: KeyCombo(key: "r", modifiers: [.option, .shift]),
    ]

    /// Problems with a proposed set of bindings (empty = valid). `system` adds a problem for every binding
    /// that would take over an enabled macOS shortcut.
    public static func validate(_ b: [HotkeyAction: KeyCombo], system: [SystemShortcut] = []) -> [String] {
        var problems: [String] = []
        for a in HotkeyAction.allCases {
            if let k = b[a], let s = conflict(k, system: system) {
                problems.append("\(a.rawValue): \(k) is the macOS shortcut “\(s.name(.english))”")
            }
        }
        if b[.emergencyStop] == nil { problems.append("Emergency stop must always have a shortcut.") }
        for (a, k) in b {
            if KeyCodes.code(for: k.key) == nil { problems.append("\(a.rawValue): unknown key \"\(k.key)\"") }
            let isFunctionKey = k.key.count >= 2 && k.key.hasPrefix("f") && Int(k.key.dropFirst()) != nil
            if k.modifiers.isEmpty && !isFunctionKey { problems.append("\(a.rawValue): needs at least one modifier (⌘ ⌥ ⌃ ⇧)") }
            if Set(k.modifiers) == [.shift] && !isFunctionKey { problems.append("\(a.rawValue): ⇧ alone would block normal typing") }
        }
        var seen: [String: HotkeyAction] = [:]
        for a in HotkeyAction.allCases { guard let k = b[a] else { continue }
            let key = canonical(k)
            if let other = seen[key] { problems.append("\(a.rawValue) and \(other.rawValue) use the same shortcut \(k)") } else { seen[key] = a }
        }
        return problems
    }

    public static func canonical(_ k: KeyCombo) -> String {
        Set(k.modifiers).map(\.rawValue).sorted().joined(separator: "+") + "+" + (k.key == "enter" ? "return" : k.key)
    }

    /// Carbon `RegisterEventHotKey` modifier mask (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000).
    public static func carbonModifiers(_ k: KeyCombo) -> UInt32 {
        var m: UInt32 = 0
        for mod in Set(k.modifiers) {
            switch mod {
            case .command: m |= 0x100
            case .shift: m |= 0x200
            case .option: m |= 0x800
            case .control: m |= 0x1000
            }
        }
        return m
    }

    /// The enabled macOS shortcut a binding would collide with, if any.
    public static func conflict(_ k: KeyCombo, system: [SystemShortcut]) -> SystemShortcut? {
        guard let code = KeyCodes.code(for: k.key) else { return nil }
        let mods = carbonModifiers(k)
        return system.first { $0.keyCode == code && $0.carbonModifiers == mods }
    }

    public struct ConflictFix: Sendable, Equatable {
        public var action: HotkeyAction
        public var from: KeyCombo
        /// The replacement (the action's default), or nil when the shortcut was removed.
        public var to: KeyCombo?
        public var system: SystemShortcut
    }

    /// Moves every binding that collides with an enabled macOS shortcut to the action's default
    /// shortcut when that one is free, otherwise removes it. Registering such a binding would swallow
    /// the system shortcut (e.g. Korean/English input switching). Emergency stop is never removed.
    public static func resolvingSystemConflicts(_ b: [HotkeyAction: KeyCombo], system: [SystemShortcut])
        -> (bindings: [HotkeyAction: KeyCombo], fixes: [ConflictFix]) {
        var out = b
        var fixes: [ConflictFix] = []
        for a in HotkeyAction.allCases {
            guard let k = out[a], let s = conflict(k, system: system) else { continue }
            var replacement: KeyCombo?
            if let d = defaults[a], conflict(d, system: system) == nil,
               !out.contains(where: { $0.key != a && canonical($0.value) == canonical(d) }) {
                replacement = d
            }
            if replacement == nil && a == .emergencyStop { continue }
            out[a] = replacement
            fixes.append(ConflictFix(action: a, from: k, to: replacement, system: s))
        }
        return (out, fixes)
    }
}

/// An enabled macOS keyboard shortcut (System Settings › Keyboard › Keyboard Shortcuts), as stored in
/// `com.apple.symbolichotkeys` → `AppleSymbolicHotKeys`: `parameters` = [character, virtual key code, Cocoa modifier flags].
public struct SystemShortcut: Sendable, Equatable {
    public var id: Int
    public var keyCode: UInt16
    /// Carbon mask (same encoding as HotkeyBindings.carbonModifiers).
    public var carbonModifiers: UInt32

    public init(id: Int, keyCode: UInt16, carbonModifiers: UInt32) {
        self.id = id; self.keyCode = keyCode; self.carbonModifiers = carbonModifiers
    }

    /// Cocoa NSEvent.ModifierFlags bits → Carbon mask (fn and other bits ignored).
    public static func carbon(fromCocoa flags: Int) -> UInt32 {
        var m: UInt32 = 0
        if flags & (1 << 17) != 0 { m |= 0x200 }   // shift
        if flags & (1 << 18) != 0 { m |= 0x1000 }  // control
        if flags & (1 << 19) != 0 { m |= 0x800 }   // option
        if flags & (1 << 20) != 0 { m |= 0x100 }   // command
        return m
    }

    /// Enabled shortcuts from the AppleSymbolicHotKeys dictionary (disabled or unset entries skipped).
    public static func parse(_ dict: [String: Any]) -> [SystemShortcut] {
        func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? NSNumber)?.intValue }
        func bool(_ v: Any?) -> Bool { (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false) }
        var out: [SystemShortcut] = []
        for (k, v) in dict {
            guard let id = Int(k), let entry = v as? [String: Any], bool(entry["enabled"]),
                  let value = entry["value"] as? [String: Any], let params = value["parameters"] as? [Any], params.count >= 3,
                  let code = int(params[1]), code >= 0, code < 0xFFFF, let flags = int(params[2]) else { continue }
            out.append(SystemShortcut(id: id, keyCode: UInt16(code), carbonModifiers: carbon(fromCocoa: flags)))
        }
        return out.sorted { $0.id < $1.id }
    }

    public func name(_ lang: LanguageCode) -> String {
        let ko = lang == .korean
        switch id {
        case 60: return ko ? "이전 입력 소스 선택" : "Select the previous input source"
        case 61: return ko ? "입력 메뉴에서 다음 소스 선택" : "Select next source in Input menu"
        case 64: return ko ? "Spotlight 검색 보기" : "Show Spotlight search"
        case 65: return ko ? "Finder 검색 윈도우 보기" : "Show Finder search window"
        case 28, 29, 30, 31, 184: return ko ? "스크린샷" : "Screenshot"
        case 32, 33, 36, 79, 80, 81, 82, 118, 119, 120, 121: return ko ? "Mission Control" : "Mission Control"
        default: return ko ? "시스템 단축키 #\(id)" : "system shortcut #\(id)"
        }
    }
}
