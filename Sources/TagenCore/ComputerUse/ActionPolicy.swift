import Foundation

public struct PolicyAssessment: Sendable, Equatable {
    public var risk: RiskLevel
    public var reasons: [String]
    public var requiresApproval: Bool
    /// Same reasons in Korean, index-aligned with `reasons`.
    public var reasonsKO: [String] = []
    public func reasons(_ lang: LanguageCode) -> [String] { lang == .korean && reasonsKO.count == reasons.count ? reasonsKO : reasons }
}

/// Classifies the impact of a GUI action. Content seen on screen never lowers risk; it can
/// only raise it. The planner's rationale is not an input (it may be prompt-injected).
public struct ActionPolicy: Sendable, Equatable {
    /// Actions at or below this risk run without asking (within an approved task scope).
    public var autoApproveUpTo: RiskLevel
    /// Bundle IDs automation may never touch.
    public var blockedBundleIDs: Set<String>
    /// Apps where any typing/keys amount to shell execution.
    public var shellBundleIDs: Set<String>

    public init(autoApproveUpTo: RiskLevel = .medium,
                blockedBundleIDs: Set<String> = ["com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop"],
                shellBundleIDs: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "io.alacritty"]) {
        self.autoApproveUpTo = autoApproveUpTo; self.blockedBundleIDs = blockedBundleIDs; self.shellBundleIDs = shellBundleIDs
    }

    static let destructiveWords = ["delete", "remove", "erase", "trash", "empty", "format", "uninstall", "discard", "reset", "wipe", "overwrite",
                                   "revoke", "deactivate", "close account", "sign out", "log out",
                                   "삭제", "제거", "지우", "휴지통", "비우기", "초기화", "포맷", "덮어쓰", "탈퇴", "로그아웃"]
    static let financialWords = ["buy", "purchase", "pay", "order", "checkout", "subscribe", "donate", "transfer", "place order", "book now",
                                 "구매", "결제", "주문", "구독", "송금", "이체", "후원", "예약하기"]
    static let transmitWords = ["send", "submit", "publish", "post", "share", "upload", "reply all", "tweet", "merge", "deploy", "push",
                                "보내기", "전송", "제출", "게시", "공유", "업로드", "배포"]
    static let securityWords = ["password", "passcode", "security", "privacy", "firewall", "filevault", "gatekeeper", "allow", "permission",
                                "certificate", "keychain", "2fa", "two-factor", "recovery key",
                                "비밀번호", "암호", "보안", "개인정보", "방화벽", "허용", "권한", "인증서", "키체인"]

    static func containsAny(_ text: String, _ words: [String]) -> String? {
        let t = text.lowercased()
        return words.first { w in
            if w.unicodeScalars.contains(where: { LanguageDetector.isHangul($0) }) { return t.contains(w) }
            // word-boundary match for English
            return t.range(of: "(^|[^a-z])" + NSRegularExpression.escapedPattern(for: w) + "($|[^a-z])", options: .regularExpression) != nil
        }
    }

    public func assess(_ action: GUIAction, element: AXElementSnapshot?, observation: GUIObservation, scopeBundleID: String?) -> PolicyAssessment {
        var risk: RiskLevel = .low
        var reasons: [String] = []
        var reasonsKO: [String] = []
        func raise(_ r: RiskLevel, _ why: String, _ ko: String) { if r > risk { risk = r }; reasons.append(why); reasonsKO.append(ko) }

        let bundle = observation.app?.bundleID ?? ""
        if blockedBundleIDs.contains(bundle) { raise(.prohibited, "automation of \(bundle) is blocked (credential store)", "자격 증명 저장소(\(bundle))는 자동화할 수 없습니다") }
        if bundle == "com.apple.systempreferences" || bundle == "com.apple.Settings" {
            let wt = (observation.window?.title ?? "").lowercased()
            if Self.containsAny(wt, Self.securityWords) != nil { raise(.prohibited, "security/privacy settings cannot be changed by automation", "보안·개인정보 설정은 자동화로 변경할 수 없습니다") }
            else { raise(.high, "changing system settings", "시스템 설정 변경") }
        }
        if let scope = scopeBundleID, !bundle.isEmpty, bundle != scope { raise(.high, "action outside the approved app (\(bundle))", "승인된 앱 밖의 동작 (\(bundle))") }

        let elementText = [element?.title, element?.label, element?.help, element?.identifier].compactMap { $0 }.joined(separator: " ")
        let windowText = observation.window?.title ?? ""

        switch action {
        case .click(_, let button, _):
            if let w = Self.containsAny(elementText, Self.destructiveWords) { raise(.high, "destructive control \"\(w)\"", "파괴적 동작 \"\(w)\"") }
            if let w = Self.containsAny(elementText, Self.financialWords) { raise(.high, "purchase/payment control \"\(w)\"", "구매·결제 동작 \"\(w)\"") }
            if let w = Self.containsAny(elementText, Self.transmitWords) { raise(.high, "sends/publishes data \"\(w)\"", "데이터 전송·게시 \"\(w)\"") }
            if let w = Self.containsAny(elementText, Self.securityWords) { raise(.high, "security-related control \"\(w)\"", "보안 관련 동작 \"\(w)\"") }
            if button == .right { raise(.low, "context menu", "컨텍스트 메뉴") }
            if element == nil { raise(.medium, "coordinate click without accessibility element", "접근성 요소 없이 좌표로 클릭") }
        case .typeText(_, let text, _, let submit):
            raise(.medium, "enters text", "텍스트 입력")
            if element?.isSecure == true { raise(.high, "typing into a secure (password) field", "보안(암호) 필드에 입력") }
            if Redactor().containsSecret(text) { raise(.high, "text looks like a credential or secret", "입력 내용이 자격 증명·비밀 정보로 보임") }
            if shellBundleIDs.contains(bundle) { raise(.high, "typing into a terminal (shell execution)", "터미널에 입력 (셸 실행)") }
            if submit { raise(.medium, "submits with Return", "Return으로 제출") }
            if submit, Self.containsAny(windowText, Self.financialWords) != nil { raise(.high, "submitting on a purchase/payment screen", "구매·결제 화면에서 제출") }
        case .pressKeys(let k):
            raise(.medium, "keyboard shortcut \(k)", "단축키 \(k)")
            if k.modifiers.contains(.command) && ["delete", "backspace"].contains(k.key) { raise(.high, "⌘⌫ deletes items", "⌘⌫ 항목 삭제") }
            if k.modifiers.contains(.command) && k.key == "q" { raise(.high, "quits an application (possible data loss)", "앱 종료 (데이터 손실 가능)") }
            if shellBundleIDs.contains(bundle) && (k.key == "return" || k.key == "enter") { raise(.high, "executes a shell command", "셸 명령 실행") }
            if k.modifiers.contains(.command) && k.modifiers.contains(.shift) && ["delete", "backspace"].contains(k.key) { raise(.high, "empties trash", "휴지통 비우기") }
        case .selectMenu(let path):
            raise(.medium, "menu command", "메뉴 명령")
            let joined = path.joined(separator: " ")
            if let w = Self.containsAny(joined, Self.destructiveWords) { raise(.high, "destructive menu item \"\(w)\"", "파괴적 메뉴 항목 \"\(w)\"") }
            if let w = Self.containsAny(joined, Self.financialWords + Self.transmitWords) { raise(.high, "menu item \"\(w)\"", "주의가 필요한 메뉴 항목 \"\(w)\"") }
            if path.last?.lowercased().hasPrefix("quit") == true || path.last?.hasSuffix("종료") == true { raise(.high, "quits an application", "앱 종료") }
        case .scroll:
            break
        case .focusApp(let a):
            raise(.medium, "switches to \(a)", "\(a)(으)로 전환")
            if blockedBundleIDs.contains(a) { raise(.prohibited, "automation of \(a) is blocked", "\(a) 자동화는 차단됨") }
        case .wait:
            break
        }
        return PolicyAssessment(risk: risk, reasons: reasons, requiresApproval: risk > autoApproveUpTo, reasonsKO: reasonsKO)
    }
}
