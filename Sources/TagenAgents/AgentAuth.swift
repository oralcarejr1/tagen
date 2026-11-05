import Foundation
import TagenCore

public enum AgentAuthState: Sendable, Equatable {
    case signedIn(method: String)
    case signedOut(hint: String)
    case notInstalled
    case unknown(String)
}

/// Checks and configures CLI authentication on the user's Mac. Cloud/CI credentials are
/// never assumed to exist; the user signs in locally with the CLI's own login flow, or
/// stores a token/API key in the Keychain which Tagen passes as an environment variable.
public struct AgentAuthManager: Sendable {
    public let locator: ExecutableLocator
    public let secrets: SecretStore
    public let loginShellPATH: String?

    public init(locator: ExecutableLocator, secrets: SecretStore, loginShellPATH: String?) {
        self.locator = locator; self.secrets = secrets; self.loginShellPATH = loginShellPATH
    }

    public func executable(_ p: AgentProvider) -> String? { locator.locate(p.executableName, loginShellPATH: loginShellPATH) }

    /// Extra environment variables carrying stored credentials (only if the user saved one).
    public func credentialEnvironment(_ p: AgentProvider) -> [String: String] {
        switch p {
        case .claudeCode:
            if let t = try? secrets.get(SecretKey.claudeCodeOAuthToken), !t.isEmpty { return ["CLAUDE_CODE_OAUTH_TOKEN": t] }
        case .codex:
            if let k = try? secrets.get(SecretKey.codexAPIKey), !k.isEmpty { return ["CODEX_API_KEY": k, "OPENAI_API_KEY": k] }
        }
        return [:]
    }

    public func environment(for p: AgentProvider) -> [String: String] {
        locator.environment(loginShellPATH: loginShellPATH, extra: credentialEnvironment(p))
    }

    /// `claude auth status` (JSON, exit 0 when signed in) / `codex login status`.
    public func status(_ p: AgentProvider, timeout: Double = 10) async -> AgentAuthState {
        guard let exe = executable(p) else { return .notInstalled }
        if !credentialEnvironment(p).isEmpty { return .signedIn(method: "token stored in Tagen") }
        let args = p == .claudeCode ? ["auth", "status"] : ["login", "status"]
        let proc = JSONLProcess()
        do {
            try proc.launch(ProcessLaunch(executable: exe, arguments: args, environment: environment(for: p),
                                          workingDirectory: NSHomeDirectory()))
        } catch { return .unknown("\(error)") }
        var lines: [String] = []
        var code: Int32 = -1
        let collected: Bool = await (try? withTimeout(seconds: timeout, operation: "auth status") {
            var l: [String] = []
            for await o in proc.output {
                switch o { case .stdout(let s), .stderr(let s): l.append(s); case .exited(let c): return (l, c) }
            }
            return (l, Int32(-1))
        }).map { lines = $0.0; code = $0.1; return true } ?? false
        if !collected { proc.terminate(); return .unknown("timed out") }
        return Self.interpret(provider: p, exitCode: code, output: lines.joined(separator: "\n"))
    }

    public static func interpret(provider: AgentProvider, exitCode: Int32, output: String) -> AgentAuthState {
        switch provider {
        case .claudeCode:
            if let j = try? JSONValue.parse(output), let method = j["authMethod"]?.stringValue {
                return method == "none" ? .signedOut(hint: loginHint(.claudeCode)) : .signedIn(method: method)
            }
            return exitCode == 0 ? .signedIn(method: "claude") : .signedOut(hint: loginHint(.claudeCode))
        case .codex:
            let t = output.lowercased()
            if exitCode == 0 && (t.contains("logged in") && !t.contains("not logged in")) { return .signedIn(method: output.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if t.contains("not logged in") || exitCode != 0 { return .signedOut(hint: loginHint(.codex)) }
            return .unknown(output)
        }
    }

    public static func loginHint(_ p: AgentProvider) -> String {
        switch p {
        case .claudeCode: return "Run `claude` in Terminal and use /login, or create a token with `claude setup-token` and paste it in Tagen."
        case .codex: return "Run `codex login` in Terminal, or paste an OpenAI API key in Tagen."
        }
    }

    /// Shell command the app opens in Terminal for the interactive login flow.
    public static func loginCommand(_ p: AgentProvider, executable: String) -> String {
        let q = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch p {
        case .claudeCode: return "\(q) setup-token || \(q)"
        case .codex: return "\(q) login"
        }
    }
}
