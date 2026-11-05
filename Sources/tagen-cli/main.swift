import Foundation
import TagenCore
import TagenAgents

// tagen-cli — headless access to Tagen's agent bridge, policies and model client.
//
//   tagen-cli agent run --provider claude|codex|codex-exec --cwd DIR [--profile read-only|ask|auto-edits]
//                       [--resume SESSION] [--model M] [--approve all|none|ask] [--json] [--exe PATH] [--mcp PATH] PROMPT
//   tagen-cli agent status --provider claude|codex
//   tagen-cli policy command "<shell command>"
//   tagen-cli ask [--provider anthropic|claude-cli|codex-cli] [--model M] [--image PNG] "question"
//                 (anthropic uses ANTHROPIC_API_KEY; claude-cli / codex-cli use the CLI's subscription sign-in)

struct CLIError: Error, CustomStringConvertible { let description: String }

final class CLIPresenter: ApprovalPresenter, @unchecked Sendable {
    let mode: String
    init(mode: String) { self.mode = mode }
    func present(_ r: ApprovalRequest) async -> ApprovalDecision {
        switch mode {
        case "all": FileHandle.standardError.write(Data("[auto-approved] \(r.title): \(r.detail)\n".utf8)); return .approved
        case "ask":
            FileHandle.standardError.write(Data("\n⚠️  \(r.title)\n    \(r.detail)\n    risk: \(r.risk) — \(r.reasons.joined(separator: "; "))\n    Approve? [y/N] ".utf8))
            guard let tty = FileHandle(forReadingAtPath: "/dev/tty") else { return .denied(reason: "no terminal") }
            let d = tty.availableData
            let a = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return a == "y" || a == "yes" ? .approved : .denied(reason: "declined in terminal")
        default: return .denied(reason: "approvals disabled (--approve none)")
        }
    }
}

func parseOptions(_ args: [String]) -> (opts: [String: String], flags: Set<String>, positional: [String]) {
    var opts: [String: String] = [:], flags = Set<String>(), pos: [String] = []
    var i = 0
    let flagNames: Set<String> = ["--json"]
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            if flagNames.contains(a) { flags.insert(a) } else if i + 1 < args.count { opts[a] = args[i + 1]; i += 1 }
        } else { pos.append(a) }
        i += 1
    }
    return (opts, flags, pos)
}

func emit(_ e: AgentEvent, json: Bool) {
    if json {
        let s = e.summary
        print(JSONValue.object(["kind": .string(s.kind), "text": .string(s.text)]).encoded())
    } else {
        switch e {
        case .messageDelta(let d): FileHandle.standardOutput.write(Data(d.utf8))
        case .message(let m): print("\n💬 \(m)")
        case .toolStarted(_, let n, let d): print("\n🔧 \(n): \(d)")
        case .toolFinished(_, let n, let ok, _): print("   \(ok ? "✓" : "✗") \(n)")
        case .approvalRequested(_, let t, let r): print("\n🔐 approval [\(r)]: \(t)")
        case .approvalResolved(_, let ok): print("   → \(ok ? "approved" : "denied")")
        case .session(let s): print("session: \(s)")
        case .log(let l): FileHandle.standardError.write(Data("· \(l)\n".utf8))
        case .completed(let r): print("\n✅ done (session \(r.sessionID ?? "?"))\n\(r.finalText)"); if !r.permissionDenials.isEmpty { print("denied tools: \(r.permissionDenials)") }
        case .failed(let f): print("\n❌ \(f)"); if let rem = f.remedy { print("   \(rem)") }
        default: break
        }
    }
}

func runAgent(_ args: [String]) async throws -> Int32 {
    let (o, flags, pos) = parseOptions(args)
    guard let prompt = pos.first else { throw CLIError(description: "missing PROMPT") }
    let providerArg = o["--provider"] ?? "claude"
    let provider: AgentProvider = providerArg.hasPrefix("codex") ? .codex : .claudeCode
    let cwd = o["--cwd"] ?? FileManager.default.currentDirectoryPath
    let profile: AgentPermissionProfile = ["read-only": .readOnly, "auto-edits": .autoEditsInProject][o["--profile"] ?? ""] ?? .askEveryTime
    let shellPATH = ExecutableLocator.loginShellPATH()
    var locator = ExecutableLocator()
    if let exe = o["--exe"] { locator.overrides[provider.executableName] = exe }
    let auth = AgentAuthManager(locator: locator, secrets: InMemorySecretStore(), loginShellPATH: shellPATH)
    let env = auth.environment(for: provider)
    let exe = auth.executable(provider)
    let mcp = o["--mcp"] ?? {
        let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("tagen-approval-mcp").path
        return FileManager.default.isExecutableFile(atPath: here) ? here : nil
    }()
    let adapter: CodingAgentAdapter
    switch providerArg {
    case "codex": adapter = CodexAppServerAdapter(executable: exe, environment: env)
    case "codex-exec": adapter = CodexExecAdapter(executable: exe, environment: env)
    default: adapter = ClaudeCodeAdapter(executable: exe, environment: env, approvalMCPPath: mcp)
    }
    let broker = ApprovalBroker(presenter: CLIPresenter(mode: o["--approve"] ?? "ask"), timeout: 600)
    let manager = AgentTaskManager(adapters: [provider: adapter], approvals: broker, store: nil)
    let spec = AgentTaskSpec(provider: provider, prompt: prompt, workingDirectory: cwd, model: o["--model"], permissionProfile: profile,
                             resumeSessionID: o["--resume"], timeout: Double(o["--timeout"] ?? "") ?? 1800)
    let (id, stream) = await manager.start(spec)
    signal(SIGINT, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGINT)
    src.setEventHandler { Task { await manager.cancel(id) } }
    src.resume()
    var code: Int32 = 0
    for await e in stream {
        emit(e, json: flags.contains("--json"))
        if case .failed(let f) = e { code = f.kind == .cancelled ? 130 : (f.kind == .authentication ? 3 : 1) }
    }
    return code
}

func agentStatus(_ args: [String]) async -> Int32 {
    let (o, _, _) = parseOptions(args)
    let provider: AgentProvider = (o["--provider"] ?? "claude").hasPrefix("codex") ? .codex : .claudeCode
    var locator = ExecutableLocator()
    if let exe = o["--exe"] { locator.overrides[provider.executableName] = exe }
    let auth = AgentAuthManager(locator: locator, secrets: InMemorySecretStore(), loginShellPATH: ExecutableLocator.loginShellPATH())
    let st = await auth.status(provider)
    print("\(provider.displayName): \(st)")
    if case .signedIn = st { return 0 }
    return 1
}

func ask(_ args: [String]) async throws -> Int32 {
    let (o, _, pos) = parseOptions(args)
    guard let q = pos.first else { throw CLIError(description: "missing question") }
    let client: ModelClient
    let defaultModel: String
    if o["--provider"] == "claude-cli" {
        var locator = ExecutableLocator()
        if let exe = o["--exe"] { locator.overrides["claude"] = exe }
        let auth = AgentAuthManager(locator: locator, secrets: InMemorySecretStore(), loginShellPATH: ExecutableLocator.loginShellPATH())
        client = ClaudeCLIModelClient(executable: auth.executable(.claudeCode), environment: auth.environment(for: .claudeCode))
        defaultModel = "sonnet"
    } else if o["--provider"] == "codex-cli" {
        var locator = ExecutableLocator()
        if let exe = o["--exe"] { locator.overrides["codex"] = exe }
        let auth = AgentAuthManager(locator: locator, secrets: InMemorySecretStore(), loginShellPATH: ExecutableLocator.loginShellPATH())
        client = CodexCLIModelClient(executable: auth.executable(.codex), environment: auth.environment(for: .codex))
        defaultModel = ""
    } else {
        client = AnthropicClient(apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")
        defaultModel = AnthropicClient.defaultModel
    }
    var parts: [ContentPart] = []
    if let img = o["--image"] {
        guard let d = FileManager.default.contents(atPath: img) else { throw CLIError(description: "cannot read \(img)") }
        parts.append(.image(data: d, mediaType: "image/png"))
    }
    parts.append(.text(PromptLibrary.askInstruction(question: q)))
    let req = ChatRequest(system: PromptLibrary.systemPrompt, messages: [ChatMessage(role: .user, parts: parts)], maxTokens: 4000,
                          purpose: .quickAnswer, effort: .low)
    do {
        let r = try await client.complete(req, model: o["--model"] ?? defaultModel) { FileHandle.standardOutput.write(Data($0.utf8)) }
        print("\n[\(r.model), in=\(r.usage.inputTokens) out=\(r.usage.outputTokens)]")
        return 0
    } catch let e as ModelError {
        print("error: \(e.userMessage(.english))"); return 1
    }
}

let argv = Array(CommandLine.arguments.dropFirst())
let code: Int32
do {
    switch (argv.first, argv.dropFirst().first) {
    case ("agent", "run"): code = try await runAgent(Array(argv.dropFirst(2)))
    case ("agent", "status"): code = await agentStatus(Array(argv.dropFirst(2)))
    case ("policy", "command"):
        let (risk, reasons) = CommandRisk.assess(command: argv.dropFirst(2).joined(separator: " "))
        print(JSONValue.object(["risk": .string(risk.description), "reasons": .array(reasons.map { .string($0) })]).encoded()); code = 0
    case ("ask", _): code = try await ask(Array(argv.dropFirst()))
    default:
        print("""
        usage:
          tagen-cli agent run --provider claude|codex|codex-exec --cwd DIR [--profile read-only|ask|auto-edits] [--resume ID] [--approve all|none|ask] PROMPT
          tagen-cli agent status --provider claude|codex
          tagen-cli policy command "<shell command>"
          tagen-cli ask "question"
        """)
        code = 2
    }
} catch {
    print("error: \(error)"); code = 2
}
exit(code)
