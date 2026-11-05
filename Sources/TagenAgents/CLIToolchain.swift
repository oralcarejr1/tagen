import Foundation
import TagenCore

/// The one place that knows how to find the Claude Code / Codex CLIs, give them credentials and wrap
/// them as coding agents or model providers. The app, tagen-cli and the self-test all build from it,
/// so discovery, environment and folders stay consistent.
public struct CLIToolchain: Sendable {
    public let auth: AgentAuthManager
    /// Private folder for agent runtime files (approval relay sockets, MCP configs).
    public let runtimeDirectory: String
    /// Empty folders the CLI model providers run in, so no project configuration is picked up.
    public let modelDirectory: String

    public init(pathOverrides: [String: String] = [:], secrets: SecretStore, loginShellPATH: String?,
                runtimeDirectory: String = (NSTemporaryDirectory() as NSString).appendingPathComponent("tagen-run"),
                modelDirectory: String = (NSTemporaryDirectory() as NSString).appendingPathComponent("tagen-model")) {
        auth = AgentAuthManager(locator: ExecutableLocator(overrides: pathOverrides), secrets: secrets, loginShellPATH: loginShellPATH)
        self.runtimeDirectory = runtimeDirectory
        self.modelDirectory = modelDirectory
    }

    /// Folders under the user's Caches directory (the app's layout).
    public static func userCachesLayout() -> (runtime: String, model: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Tagen").path
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("Tagen")
        return ((caches as NSString).appendingPathComponent("run"), (caches as NSString).appendingPathComponent("model-cwd"))
    }

    public func executable(_ p: AgentProvider) -> String? { auth.executable(p) }

    // MARK: model providers (subscription sign-in, no API key)

    public var claudeModelClient: ClaudeCLIModelClient {
        ClaudeCLIModelClient(executable: executable(.claudeCode), environment: auth.environment(for: .claudeCode),
                             workingDirectory: (modelDirectory as NSString).appendingPathComponent("claude"))
    }

    public var codexModelClient: CodexCLIModelClient {
        CodexCLIModelClient(executable: executable(.codex), environment: auth.environment(for: .codex),
                            workingDirectory: (modelDirectory as NSString).appendingPathComponent("codex"))
    }

    public var modelClients: [ProviderKind: ModelClient] { [.claudeCLI: claudeModelClient, .codexCLI: codexModelClient] }

    // MARK: coding agents

    public func claudeCodeAdapter(approvalMCPPath: String?) -> ClaudeCodeAdapter {
        try? FileManager.default.createDirectory(atPath: runtimeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let mcp = approvalMCPPath.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        return ClaudeCodeAdapter(executable: executable(.claudeCode), environment: auth.environment(for: .claudeCode),
                                 approvalMCPPath: mcp, runtimeDirectory: runtimeDirectory)
    }

    /// `codex app-server` (approvals relayed to Tagen) or the `codex exec --json` fallback.
    public func codexAdapter(appServer: Bool) -> CodingAgentAdapter {
        appServer
            ? CodexAppServerAdapter(executable: executable(.codex), environment: auth.environment(for: .codex))
            : CodexExecAdapter(executable: executable(.codex), environment: auth.environment(for: .codex))
    }
}
