import Foundation

/// Removes secrets and obviously sensitive values from text before it is logged, persisted,
/// or (when configured) sent to a model. Conservative: prefers over-redaction.
public struct Redactor: Sendable {
    public struct Rule: Sendable {
        public let name: String
        public let pattern: String
        public let replacement: String
    }

    public static let defaultRules: [Rule] = [
        Rule(name: "anthropic-key", pattern: #"sk-ant-[A-Za-z0-9_\-]{10,}"#, replacement: "[REDACTED:anthropic-key]"),
        Rule(name: "openai-key", pattern: #"sk-(?:proj-)?[A-Za-z0-9_\-]{20,}"#, replacement: "[REDACTED:api-key]"),
        Rule(name: "github-token", pattern: #"(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}"#, replacement: "[REDACTED:github-token]"),
        Rule(name: "slack-token", pattern: #"xox[abprs]-[A-Za-z0-9\-]{10,}"#, replacement: "[REDACTED:slack-token]"),
        Rule(name: "aws-access-key", pattern: #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, replacement: "[REDACTED:aws-key]"),
        Rule(name: "jwt", pattern: #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, replacement: "[REDACTED:jwt]"),
        Rule(name: "bearer", pattern: #"(?i)(authorization:\s*bearer\s+|bearer\s+)[A-Za-z0-9._\-]{16,}"#, replacement: "$1[REDACTED]"),
        Rule(name: "private-key", pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, replacement: "[REDACTED:private-key]"),
        Rule(name: "password-assignment", pattern: #"(?i)\b(password|passwd|pwd|비밀번호|secret|api[_-]?key|token)\b(\s*[:=]\s*)\S+"#, replacement: "$1$2[REDACTED]"),
    ]

    private let rules: [(NSRegularExpression, String)]
    public let redactCardNumbers: Bool

    public init(rules: [Rule] = Redactor.defaultRules, redactCardNumbers: Bool = true) {
        self.rules = rules.compactMap { r in
            (try? NSRegularExpression(pattern: r.pattern)).map { ($0, r.replacement) }
        }
        self.redactCardNumbers = redactCardNumbers
    }

    public func redact(_ text: String) -> String {
        var out = text
        for (regex, template) in rules {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        if redactCardNumbers { out = Self.redactLuhnNumbers(out) }
        return out
    }

    /// True if the text appears to contain a secret (used by the action policy to flag
    /// typing credentials or exfiltrating them).
    public func containsSecret(_ text: String) -> Bool {
        redact(text) != text
    }

    static let cardRegex = try! NSRegularExpression(pattern: #"\b(?:\d[ \-]?){13,19}\b"#)

    static func redactLuhnNumbers(_ text: String) -> String {
        let ns = text as NSString
        var result = text
        let matches = cardRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed()
        for m in matches {
            let candidate = ns.substring(with: m.range)
            let digits = candidate.filter(\.isNumber)
            if digits.count >= 13, digits.count <= 19, luhnValid(digits) {
                if let r = Range(m.range, in: result) { result.replaceSubrange(r, with: "[REDACTED:card]") }
            }
        }
        return result
    }

    public static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
}
