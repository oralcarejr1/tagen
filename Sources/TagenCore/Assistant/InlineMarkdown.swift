import Foundation

/// Splits text into plain/bold runs for `**bold**`, tolerant of CJK text. CommonMark refuses to close
/// `**` when it sits between punctuation and a letter (e.g. `**PDF…**를`), which is very common in
/// Korean where particles attach directly to words — renderers then show raw asterisks. Bold spans are
/// matched per line, non-greedy; unmatched `**` stays literal.
public enum InlineMarkdown {
    public struct Run: Equatable, Sendable {
        public var text: String
        public var bold: Bool
        public init(_ text: String, bold: Bool) { self.text = text; self.bold = bold }
    }

    static let boldPattern = try! NSRegularExpression(pattern: #"\*\*([^\n*](?:[^\n]*?[^\n*])?)\*\*"#)

    public static func runs(_ text: String) -> [Run] {
        let ns = text as NSString
        var out: [Run] = []
        var cursor = 0
        for m in boldPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor { out.append(Run(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), bold: false)) }
            out.append(Run(ns.substring(with: m.range(at: 1)), bold: true))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { out.append(Run(ns.substring(from: cursor), bold: false)) }
        return out.filter { !$0.text.isEmpty }
    }
}

// MARK: - Localized display names (Korean/English UI)

extension RiskLevel {
    public func displayName(_ lang: LanguageCode) -> String {
        switch (self, lang) {
        case (.low, .korean): return "낮음"
        case (.medium, .korean): return "중간"
        case (.high, .korean): return "높음"
        case (.prohibited, .korean): return "금지"
        default: return description
        }
    }
}

extension PermissionState {
    public func displayName(_ lang: LanguageCode) -> String {
        switch (self, lang) {
        case (.granted, .korean): return "허용됨"
        case (.denied, .korean): return "거부됨"
        case (.notDetermined, .korean): return "아직 묻지 않음"
        case (.restricted, .korean): return "제한됨"
        case (.unknown, .korean): return "앱별로 확인"
        case (.granted, _): return "Granted"
        case (.denied, _): return "Denied"
        case (.notDetermined, _): return "Not requested"
        case (.restricted, _): return "Restricted"
        case (.unknown, _): return "Per app"
        }
    }
}

extension PermissionKind {
    public func purpose(_ lang: LanguageCode) -> String {
        guard lang == .korean else { return purpose }
        switch self {
        case .screenCapture: return "접근성 텍스트가 부족할 때 활성 창이나 선택 영역을 캡처합니다."
        case .accessibility: return "활성 창의 UI 요소와 선택 텍스트를 읽고, 승인된 GUI 작업을 수행합니다."
        case .microphone: return "누른 채 말하기 음성 입력 (키를 누르고 있는 동안에만)."
        case .speechRecognition: return "누른 채 말하기 음성을 텍스트로 변환합니다 (가능하면 기기 내 처리)."
        case .fileAccess: return "코딩 에이전트가 지정한 폴더에서 작업하도록 허용합니다."
        case .appAutomation: return "승인한 작업에 한해 다른 앱에 Apple Events / 메뉴 명령을 보냅니다."
        case .agentExecution: return "이 Mac에서 Codex / Claude Code 프로세스를 실행합니다."
        }
    }
}

extension ModelPurpose {
    public func displayName(_ lang: LanguageCode) -> String {
        switch (self, lang) {
        case (.quickAnswer, .korean): return "빠른 답변 (선택 텍스트)"
        case (.screenQuestion, .korean): return "화면 질문"
        case (.guidance, .korean): return "가이드 (화면 표시)"
        case (.computerUse, .korean): return "컴퓨터 사용 (Act)"
        case (.quickAnswer, _): return "Quick answers (selection)"
        case (.screenQuestion, _): return "Screen questions"
        case (.guidance, _): return "Guide (overlays)"
        case (.computerUse, _): return "Computer use (Act)"
        }
    }
}

/// Plain-language names for accessibility roles (approval cards must not show "AXButton").
public enum AXRoleName {
    static let names: [String: (en: String, ko: String)] = [
        "AXButton": ("button", "버튼"), "AXMenuButton": ("menu button", "메뉴 버튼"), "AXPopUpButton": ("pop-up menu", "팝업 메뉴"),
        "AXCheckBox": ("checkbox", "체크박스"), "AXRadioButton": ("radio button", "라디오 버튼"), "AXSwitch": ("switch", "스위치"),
        "AXTextField": ("text field", "텍스트 필드"), "AXTextArea": ("text area", "텍스트 영역"), "AXSearchField": ("search field", "검색 필드"),
        "AXSecureTextField": ("password field", "암호 필드"), "AXComboBox": ("combo box", "콤보 상자"),
        "AXLink": ("link", "링크"), "AXMenuItem": ("menu item", "메뉴 항목"), "AXMenuBarItem": ("menu", "메뉴"),
        "AXTab": ("tab", "탭"), "AXRadioGroup": ("tab group", "탭 그룹"), "AXSlider": ("slider", "슬라이더"),
        "AXIncrementor": ("stepper", "스테퍼"), "AXRow": ("row", "행"), "AXCell": ("cell", "셀"), "AXImage": ("image", "이미지"),
        "AXStaticText": ("text", "텍스트"), "AXWindow": ("window", "창"), "AXToolbar": ("toolbar", "도구 막대"),
        "AXScrollArea": ("scroll area", "스크롤 영역"), "AXList": ("list", "목록"), "AXTable": ("table", "표"),
        "AXOutline": ("outline", "개요"), "AXDisclosureTriangle": ("disclosure triangle", "펼치기 삼각형"),
    ]

    public static func friendly(_ role: String, _ lang: LanguageCode) -> String {
        if let n = names[role] { return lang == .korean ? n.ko : n.en }
        let bare = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        return bare.isEmpty ? (lang == .korean ? "요소" : "element") : bare.lowercased()
    }

    /// `button "Delete"` / `버튼 '삭제'`.
    public static func describe(role: String, name: String?, _ lang: LanguageCode) -> String {
        let r = friendly(role, lang)
        guard let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return r }
        let short = n.count > 60 ? String(n.prefix(60)) + "…" : n
        return lang == .korean ? "\(r) '\(short)'" : "\(r) \"\(short)\""
    }
}

extension GUIAction {
    /// User-facing summary for approval cards. `targetName` (the resolved element's name) replaces opaque
    /// element ids such as `[w0.4.2]`, which mean nothing to the user.
    public func summary(_ lang: LanguageCode, targetName: String?) -> String {
        let ko = lang == .korean
        func tgt(_ t: ElementTarget?) -> String? {
            if let n = targetName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
                let short = n.count > 40 ? String(n.prefix(40)) + "…" : n
                return ko ? "'\(short)'" : "\"\(short)\""
            }
            guard let t else { return nil }
            switch t {
            case .point(let p, _): return ko ? "화면 좌표 (\(Int(p.x)), \(Int(p.y)))" : "screen point (\(Int(p.x)), \(Int(p.y)))"
            case .element: return ko ? "선택된 요소" : "the selected element"
            case .query(let q):
                if let n = q.title ?? q.label ?? q.titleContains ?? q.identifier { return ko ? "'\(n)'" : "\"\(n)\"" }
                return q.role.map { AXRoleName.friendly($0.hasPrefix("AX") ? $0 : "AX" + $0, lang) } ?? (ko ? "요소" : "element")
            }
        }
        switch self {
        case .click(let t, let b, let c):
            let target = tgt(t) ?? (ko ? "요소" : "element")
            let verbKO = c == 2 ? "더블 클릭" : b == .right ? "우클릭" : "클릭"
            let verbEN = c == 2 ? "Double-click" : b == .right ? "Right-click" : "Click"
            return ko ? "\(target) \(verbKO)" : "\(verbEN) \(target)"
        case .typeText(let t, let text, let rep, let submit):
            let shown = text.count > 60 ? String(text.prefix(60)) + "…" : text
            if ko {
                var s = "\(tgt(t).map { "\($0)에 " } ?? "")'\(shown)' 입력"
                if rep { s += " (기존 내용 교체)" }
                if submit { s += " 후 Return" }
                return s
            }
            return "Type \"\(shown)\"\(tgt(t).map { " into \($0)" } ?? "")\(rep ? " (replace)" : "")\(submit ? " and press Return" : "")"
        case .pressKeys(let k): return ko ? "\(k) 누르기" : "Press \(k)"
        case .selectMenu(let p): return ko ? "메뉴 " + p.joined(separator: " › ") + " 선택" : "Menu " + p.joined(separator: " › ")
        case .scroll(let t, let d, let a):
            let dirKO = ["up": "위로", "down": "아래로", "left": "왼쪽으로", "right": "오른쪽으로"][d.rawValue] ?? d.rawValue
            return ko ? "\(tgt(t).map { "\($0)에서 " } ?? "")\(dirKO) \(a)번 스크롤" : "Scroll \(d.rawValue) ×\(a)\(tgt(t).map { " in \($0)" } ?? "")"
        case .focusApp(let a): return ko ? "\(a)(으)로 전환" : "Switch to \(a)"
        case .wait(_, let to): return ko ? "조건 대기 (최대 \(Int(to))초)" : summary
        }
    }
}
