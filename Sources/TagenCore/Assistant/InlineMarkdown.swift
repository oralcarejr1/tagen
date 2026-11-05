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
