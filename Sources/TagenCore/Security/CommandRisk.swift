import Foundation

/// Risk assessment for shell commands and agent tool calls (Codex / Claude Code approvals).
public enum CommandRisk {
    static let highPatterns: [(String, String)] = [
        (#"\brm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)+"#, "recursive/forced delete"),
        (#"\bsudo\b"#, "runs as administrator"),
        (#"\b(curl|wget)\b[^|]*\|\s*(sh|bash|zsh|python3?)\b"#, "pipes a download into a shell"),
        (#"\bgit\s+push\b"#, "pushes to a remote"),
        (#"\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f|checkout\s+--\s|branch\s+-D|push\s+--force)"#, "discards git history or changes"),
        (#"\b(npm|pnpm|yarn|cargo|gem|twine)\s+publish\b"#, "publishes a package"),
        (#"\b(ssh|scp|sftp|rsync)\b"#, "connects to a remote host"),
        (#"\b(mkfs|diskutil\s+(erase|partition)|dd\s+if=)"#, "disk-level write"),
        (#"\bchmod\s+(-R\s+)?[0-7]*7[0-7]{2}\b"#, "makes files world-writable"),
        (#"\b(security\s+(find|dump|delete)-|defaults\s+delete|csrutil|spctl|tccutil|launchctl)\b"#, "touches credentials or system security"),
        (#">\s*/(etc|System|Library|usr)/"#, "writes into system directories"),
        (#"\b(shutdown|reboot|halt|killall)\b"#, "affects the whole system"),
        (#"\bkubectl\s+(delete|apply)|\bterraform\s+(apply|destroy)"#, "changes infrastructure"),
        (#"\b(aws|gcloud|az)\s+\S+\s+(delete|rm|remove|create)"#, "changes cloud resources"),
        (#"(\$\{?[A-Z_]*(TOKEN|SECRET|KEY|PASSWORD)[A-Z_]*\}?).*\b(curl|wget|nc)\b"#, "may transmit a secret"),
        (#"\b(cat|less|head|tail)\s+[^|;]*(\.ssh/|\.aws/credentials|\.netrc|id_rsa|\.env\b)"#, "reads credentials"),
    ]
    static let mediumPatterns: [(String, String)] = [
        (#"\b(curl|wget|http|nc)\b"#, "network access"),
        (#"\b(npm|pnpm|yarn|pip3?|brew|cargo|go)\s+(install|add|get)\b"#, "installs packages"),
        (#"\bgit\s+(commit|merge|rebase|tag)\b"#, "modifies git history"),
        (#"\b(mv|cp|rm|mkdir|touch|chmod|chown|ln)\b"#, "modifies files"),
        (#"(^|[^<])>\s*\S"#, "writes to a file"),
    ]

    public static func assess(command: String) -> (RiskLevel, [String]) {
        var risk: RiskLevel = .low
        var reasons: [String] = []
        for (p, why) in highPatterns where command.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil {
            risk = .high; reasons.append(why)
        }
        if risk < .high {
            for (p, why) in mediumPatterns where command.range(of: p, options: [.regularExpression]) != nil {
                risk = max(risk, .medium); reasons.append(why)
            }
        }
        if Redactor().containsSecret(command) { risk = .high; reasons.append("contains a credential") }
        if reasons.isEmpty { reasons.append("runs a shell command") ; risk = max(risk, .medium) }
        return (risk, reasons)
    }

    /// Claude Code tool-call risk.
    public static func assess(tool: String, input: JSONValue, workingDirectory: String) -> (RiskLevel, [String]) {
        switch tool {
        case "Bash", "BashOutput", "KillShell":
            return assess(command: input["command"]?.stringValue ?? "")
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue ?? ""
            if !path.isEmpty && !isInside(path, workingDirectory) { return (.high, ["edits a file outside the project: \(path)"]) }
            if isSensitivePath(path) { return (.high, ["edits a sensitive file: \(path)"]) }
            return (.medium, ["edits \(path.isEmpty ? "a file" : path)"])
        case "Read", "Glob", "Grep", "LS", "TodoWrite", "Task":
            let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? ""
            if isSensitivePath(path) { return (.high, ["reads a sensitive file: \(path)"]) }
            return (.low, ["reads project files"])
        case "WebFetch", "WebSearch":
            return (.medium, ["accesses the web"])
        default:
            if tool.hasPrefix("mcp__") { return (.medium, ["calls MCP tool \(tool)"]) }
            return (.medium, ["uses tool \(tool)"])
        }
    }

    public static func isInside(_ path: String, _ dir: String) -> Bool {
        guard !dir.isEmpty else { return false }
        let p = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: dir)).standardizedFileURL.path
        let d = URL(fileURLWithPath: dir).standardizedFileURL.path
        return p == d || p.hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }

    public static func isSensitivePath(_ path: String) -> Bool {
        let p = path.lowercased()
        return [".ssh/", ".aws/", ".gnupg/", ".netrc", "id_rsa", "id_ed25519", ".env", "keychain", ".git/config", "credentials"].contains { p.contains($0) }
    }
}
