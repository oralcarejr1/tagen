#if os(macOS)
import AppKit
import SwiftUI
import TagenCore
import TagenAgents
import TagenMac

// Coding agents: adapters, tasks, CLI sign-in.
extension AppController {
    func rebuildAgentManager() {
        let tools = toolchain
        let mcp = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tagen-approval-mcp").path
        let claude = tools.claudeCodeAdapter(approvalMCPPath: mcp)
        let codex = tools.codexAdapter(appServer: state.settings.codexMode == .appServer)
        agentManager = AgentTaskManager(adapters: [.claudeCode: claude, .codex: codex], approvals: broker, store: store, stop: stop)
        let mgr = agentManager!
        Task { await mgr.installEmergencyStop() }
        Task { [weak self] in
            await mgr.observe { snap in Task { @MainActor in self?.state.agentTasks[snap.id] = snap } }
        }
    }

    func startAgent(provider: AgentProvider, folder: String, prompt: String, profile: AgentPermissionProfile, model: String?) {
        let s = state.settings
        guard s.agentExecutionEnabled else { state.errorMessage = state.t("Enable coding-agent execution in Settings › Agents first.", "설정 › 에이전트에서 코딩 에이전트 실행을 먼저 켜세요."); return }
        guard s.isAllowedProjectFolder(folder) else { state.errorMessage = state.t("Choose a project folder you have allowed in Settings.", "설정에서 허용한 프로젝트 폴더를 선택하세요."); return }
        let spec = AgentTaskSpec(provider: provider, prompt: prompt, workingDirectory: folder, model: model, permissionProfile: profile)
        let mgr = agentManager!
        Task { [weak self] in
            let (id, stream) = await mgr.start(spec)
            self?.state.selectedAgentTask = id
            for await _ in stream {}
            self?.loadHistory()
        }
    }

    func cancelAgent(_ id: UUID) { let m = agentManager!; Task { await m.cancel(id) } }

    func resumeAgent(_ id: UUID, prompt: String) {
        let mgr = agentManager!
        Task { [weak self] in
            guard let (_, stream) = await mgr.resume(taskID: id, prompt: prompt) else {
                self?.state.errorMessage = "This task has no resumable session."; return
            }
            for await _ in stream {}
        }
    }

    func refreshAgentAuth() {
        let auth = toolchain.auth
        for p in AgentProvider.allCases {
            Task { [weak self] in
                let st = await auth.status(p)
                self?.state.agentAuth[p] = st
            }
        }
    }

    /// Opens Terminal with the CLI's own login command (the supported auth flow on the Mac).
    func openLogin(_ p: AgentProvider) {
        guard let exe = toolchain.executable(p) else { state.errorMessage = "\(p.displayName) CLI not found."; return }
        let script = "#!/bin/zsh -l\n\(AgentAuthManager.loginCommand(p, executable: exe))\necho\necho 'You can close this window and return to Tagen.'\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tagen-login-\(p.rawValue).command")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}
#endif
