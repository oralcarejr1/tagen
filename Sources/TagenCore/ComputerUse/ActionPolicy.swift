import Foundation

public struct PolicyAssessment: Sendable, Equatable {
    public var risk: RiskLevel
    public var reasons: [String]
    public var requiresApproval: Bool
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
        func raise(_ r: RiskLevel, _ why: String) { if r > risk { risk = r }; reasons.append(why) }

        let bundle = observation.app?.bundleID ?? ""
        if blockedBundleIDs.contains(bundle) { raise(.prohibited, "automation of \(bundle) is blocked (credential store)") }
        if bundle == "com.apple.systempreferences" || bundle == "com.apple.Settings" {
            let wt = (observation.window?.title ?? "").lowercased()
            if Self.containsAny(wt, Self.securityWords) != nil { raise(.prohibited, "security/privacy settings cannot be changed by automation") }
            else { raise(.high, "changing system settings") }
        }
        if let scope = scopeBundleID, !bundle.isEmpty, bundle != scope { raise(.high, "action outside the approved app (\(bundle))") }

        let elementText = [element?.title, element?.label, element?.help, element?.identifier].compactMap { $0 }.joined(separator: " ")
        let windowText = observation.window?.title ?? ""

        switch action {
        case .click(_, let button, _):
            if let w = Self.containsAny(elementText, Self.destructiveWords) { raise(.high, "destructive control \"\(w)\"") }
            if let w = Self.containsAny(elementText, Self.financialWords) { raise(.high, "purchase/payment control \"\(w)\"") }
            if let w = Self.containsAny(elementText, Self.transmitWords) { raise(.high, "sends/publishes data \"\(w)\"") }
            if let w = Self.containsAny(elementText, Self.securityWords) { raise(.high, "security-related control \"\(w)\"") }
            if button == .right { raise(.low, "context menu") }
            if element == nil { raise(.medium, "coordinate click without accessibility element") }
        case .typeText(_, let text, _, let submit):
            raise(.medium, "enters text")
            if element?.isSecure == true { raise(.high, "typing into a secure (password) field") }
            if Redactor().containsSecret(text) { raise(.high, "text looks like a credential or secret") }
            if shellBundleIDs.contains(bundle) { raise(.high, "typing into a terminal (shell execution)") }
            if submit { raise(.medium, "submits with Return") }
            if submit, Self.containsAny(windowText, Self.financialWords) != nil { raise(.high, "submitting on a purchase/payment screen") }
        case .pressKeys(let k):
            raise(.medium, "keyboard shortcut \(k)")
            if k.modifiers.contains(.command) && ["delete", "backspace"].contains(k.key) { raise(.high, "⌘⌫ deletes items") }
            if k.modifiers.contains(.command) && k.key == "q" { raise(.high, "quits an application (possible data loss)") }
            if shellBundleIDs.contains(bundle) && (k.key == "return" || k.key == "enter") { raise(.high, "executes a shell command") }
            if k.modifiers.contains(.command) && k.modifiers.contains(.shift) && ["delete", "backspace"].contains(k.key) { raise(.high, "empties trash") }
        case .selectMenu(let path):
            raise(.medium, "menu command")
            let joined = path.joined(separator: " ")
            if let w = Self.containsAny(joined, Self.destructiveWords) { raise(.high, "destructive menu item \"\(w)\"") }
            if let w = Self.containsAny(joined, Self.financialWords + Self.transmitWords) { raise(.high, "menu item \"\(w)\"") }
            if path.last?.lowercased().hasPrefix("quit") == true || path.last?.hasSuffix("종료") == true { raise(.high, "quits an application") }
        case .scroll:
            break
        case .focusApp(let a):
            raise(.medium, "switches to \(a)")
            if blockedBundleIDs.contains(a) { raise(.prohibited, "automation of \(a) is blocked") }
        case .wait:
            break
        }
        return PolicyAssessment(risk: risk, reasons: reasons, requiresApproval: risk > autoApproveUpTo)
    }
}
