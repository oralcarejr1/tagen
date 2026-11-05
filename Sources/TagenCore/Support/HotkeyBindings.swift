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
        .pushToTalk: KeyCombo(key: "space", modifiers: [.control, .option]),
        .emergencyStop: KeyCombo(key: ".", modifiers: [.control, .option, .command]),
        .explainSelection: KeyCombo(key: "s", modifiers: [.option, .shift]),
        .guide: KeyCombo(key: "g", modifiers: [.option, .shift]),
        .region: KeyCombo(key: "r", modifiers: [.option, .shift]),
    ]

    /// Problems with a proposed set of bindings (empty = valid).
    public static func validate(_ b: [HotkeyAction: KeyCombo]) -> [String] {
        var problems: [String] = []
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
}
