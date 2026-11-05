#if os(macOS)
import AppKit
import SwiftUI
import TagenCore
import TagenAgents
import TagenMac

/// Composition root: wires OS implementations (TagenMac) into the platform-independent
/// orchestration (TagenCore / TagenAgents) and drives the UI state.
@MainActor
final class AppController {
    let state = AppState()
    let store: AppStore?
    let secrets: SecretStore
    let contextProvider = MacContextProvider()
    let guiDriver = MacGUIDriver()
    let stop = EmergencyStop.shared
    let audit: AuditSink
    private(set) var router: ModelRouter
    private(set) var orchestrator: AssistantOrchestrator
    private(set) var broker: ApprovalBroker!
    private(set) var agentManager: AgentTaskManager!
    private(set) var voice: VoiceController!
    private(set) var permissions: MacPermissionChecker!
    var overlay: OverlayController!
    var panel: AssistantPanel?
    var statusBar: StatusBarController?
    private var assistantTask: Task<Void, Never>?
    private var actTask: Task<Void, Never>?
    private var loginShellPATH: String?
    private var permissionTimer: Timer?
    /// Thread-safe copy of settings for non-main-actor readers (permission checker).
    let settingsBox = Locked(AppSettings())

    init(storeURL: URL? = AppController.defaultStoreURL(), secrets: SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
        var s: AppStore?
        if let url = storeURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            s = try? AppStore(path: url.path)
        }
        store = s ?? (try? AppStore.inMemory())
        audit = store ?? MemoryAuditSink()
        var settings = AppSettings()
        if let saved = try? store?.setting("appSettings", as: AppSettings.self) { settings = saved }
        state.settings = settings
        router = AppController.makeRouter(settings: settings, secrets: secrets)
        orchestrator = AssistantOrchestrator(contextProvider: contextProvider, models: router, store: settings.keepHistory ? store : nil,
                                             settings: settings.assistant)
        state.hasAnthropicKey = ((try? secrets.get(SecretKey.anthropicAPIKey)) ?? nil)?.isEmpty == false
        broker = ApprovalBroker(presenter: PanelApprovalPresenter(state: state, onPresent: { [weak self] in self?.showPanel(focus: true) }),
                                timeout: 300, audit: audit, stop: stop)
        settingsBox.set(settings)
        let box = settingsBox
        permissions = MacPermissionChecker(appSwitches: { kind in
            let st = box.current
            switch kind {
            case .agentExecution: return st.agentExecutionEnabled
            case .fileAccess: return !st.allowedProjectFolders.isEmpty
            default: return false
            }
        })
        overlay = OverlayController(
            frameProvider: { [contextProvider] ident in await contextProvider.currentFrame(ofElementWithIdentity: ident) },
            windowFrameProvider: { [contextProvider] pid in contextProvider.windowFrame(pid: pid) })
        overlay.changeSourceFactory = { [contextProvider] pid, idents, onChange in
            contextProvider.observeChanges(pid: pid, identities: idents, onChange: onChange)
        }
        voice = makeVoice()
        rebuildAgentManager()
        stop.register { [weak self] reason in
            Task { @MainActor in self?.handleEmergencyStop(reason) }
        }
    }

    static func defaultStoreURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Tagen", isDirectory: true).appendingPathComponent("tagen.sqlite")
    }

    static func makeRouter(settings: AppSettings, secrets: SecretStore) -> ModelRouter {
        var clients: [ProviderKind: ModelClient] = [:]
        let anthropicKey = ((try? secrets.get(SecretKey.anthropicAPIKey)) ?? nil) ?? ""
        clients[.anthropic] = AnthropicClient(apiKey: anthropicKey, enableRefusalFallback: settings.models.enableRefusalFallback)
        if let url = URL(string: settings.models.openAIBaseURL) {
            clients[.openAICompatible] = OpenAICompatibleClient(name: settings.models.openAIProviderName,
                                                                apiKey: (try? secrets.get(SecretKey.openAIAPIKey)) ?? nil, baseURL: url)
        }
        return ModelRouter(settings: settings.models, clients: clients)
    }

    func makeVoice() -> VoiceController {
        VoiceController(settings: state.settings.voice, recognizer: MacSpeechRecognizer(), synthesizer: MacSpeechSynthesizer(),
                        submit: { [weak self] text, _ in
                            guard let self else { return "" }
                            return try await self.askForVoice(text)
                        },
                        onStateChange: { [weak self] st in Task { @MainActor in self?.state.voiceState = st } })
    }

    func rebuildAgentManager() {
        let settings = state.settings
        let locator = ExecutableLocator(overrides: settings.cliPathOverrides)
        let auth = AgentAuthManager(locator: locator, secrets: secrets, loginShellPATH: loginShellPATH)
        let mcp = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tagen-approval-mcp").path
        let runtime = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Tagen/run").path) ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let claude = ClaudeCodeAdapter(executable: auth.executable(.claudeCode), environment: auth.environment(for: .claudeCode),
                                       approvalMCPPath: FileManager.default.isExecutableFile(atPath: mcp) ? mcp : nil, runtimeDirectory: runtime)
        let codex: CodingAgentAdapter = settings.codexMode == .appServer
            ? CodexAppServerAdapter(executable: auth.executable(.codex), environment: auth.environment(for: .codex))
            : CodexExecAdapter(executable: auth.executable(.codex), environment: auth.environment(for: .codex))
        agentManager = AgentTaskManager(adapters: [.claudeCode: claude, .codex: codex], approvals: broker, store: store, stop: stop)
        let mgr = agentManager!
        Task { await mgr.installEmergencyStop() }
        Task { [weak self] in
            await mgr.observe { snap in Task { @MainActor in self?.state.agentTasks[snap.id] = snap } }
        }
    }

    // MARK: lifecycle

    func start() {
        statusBar = StatusBarController(controller: self)
        registerHotkeys()
        Task.detached { [weak self] in
            let path = ExecutableLocator.loginShellPATH()
            await MainActor.run { self?.loginShellPATH = path; self?.rebuildAgentManager(); self?.refreshAgentAuth() }
        }
        refreshPermissions()
        loadHistory()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.panel?.isVisible == true { self?.refreshPermissions() } }
        }
        if !state.settings.onboardingCompleted { openSettings(tab: .permissions) }
    }

    func registerHotkeys() {
        let hk = GlobalHotkeys.shared
        hk.unregisterAll()
        hk.failures.removeAll()
        let b = state.settings.hotkeys
        func reg(_ a: HotkeyAction, press: @escaping () -> Void, release: (() -> Void)? = nil) {
            guard let combo = b[a], let key = GlobalHotkeys.Hotkey(combo) else { return }
            hk.register(key, name: a.rawValue, onPress: press, onRelease: release)
        }
        reg(.toggleAssistant, press: { [weak self] in self?.togglePanel() })
        reg(.pushToTalk, press: { [weak self] in self?.pushToTalk(down: true) }, release: { [weak self] in self?.pushToTalk(down: false) })
        reg(.emergencyStop, press: { [weak self] in self?.emergencyStop() })
        reg(.explainSelection, press: { [weak self] in self?.state.mode = .ask; self?.showPanel(focus: true); self?.runSelection(.explain) })
        reg(.guide, press: { [weak self] in self?.state.mode = .guide; self?.showPanel(focus: true) })
        reg(.region, press: { [weak self] in self?.askAboutRegion() })
        if !hk.failures.isEmpty {
            state.errorMessage = state.t("Some shortcuts could not be registered (in use by another app): ", "일부 단축키를 등록하지 못했습니다 (다른 앱이 사용 중): ")
                + hk.failures.joined(separator: ", ")
        }
    }

    func setVoiceLanguage(_ lang: LanguageCode) {
        var s = state.settings
        s.voice.recognitionLanguage = lang
        saveSettings(s)
    }

    // MARK: panel

    func ensurePanel() -> AssistantPanel {
        if let p = panel { return p }
        let p = AssistantPanel(content: RootView().environmentObject(state).environment(\.appController, self))
        p.onEscape = { [weak self] in
            guard let v = self?.voice else { return }
            Task { await v.send(.cancel) }
        }
        panel = p
        return p
    }

    @discardableResult
    func showPanel(focus: Bool) -> Double {
        let t0 = CFAbsoluteTimeGetCurrent()
        let p = ensurePanel()
        if !p.isVisible { p.positionOnActiveScreen() }
        p.orderFrontRegardless()
        if focus { p.makeKey() }
        p.displayIfNeeded()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        state.panelLatenciesMs.append(ms)
        if state.panelLatenciesMs.count > 50 { state.panelLatenciesMs.removeFirst() }
        return ms
    }

    func togglePanel() {
        if let p = panel, p.isVisible && p.isKeyWindow { p.orderOut(nil) } else { showPanel(focus: true) }
    }

    // MARK: Ask / Guide / Act

    func submit() {
        let q = state.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        switch state.mode {
        case .ask, .guide: ask(q, mode: state.mode, region: nil)
        case .act: act(goal: q)
        }
    }

    func ask(_ question: String, mode: AssistantMode, region: Rect?) {
        assistantTask?.cancel()
        state.response = ""; state.guidanceNotes = []; state.replacement = nil; state.errorMessage = nil
        state.busy = true
        if mode == .guide { overlay.clear() }
        let orch = orchestrator
        assistantTask = Task { [weak self] in
            let stream = await orch.ask(question, mode: mode, region: region)
            await self?.consume(stream)
        }
    }

    func askAboutRegion() {
        Task { [weak self] in
            guard let self else { return }
            guard let region = await RegionSelector().select() else { return }
            self.showPanel(focus: true)
            let q = self.state.input.isEmpty ? self.state.t("Explain what is in this region.", "이 영역의 내용을 설명해 주세요.") : self.state.input
            self.ask(q, mode: .ask, region: region)
        }
    }

    func runSelection(_ action: SelectionAction) {
        assistantTask?.cancel()
        state.response = ""; state.replacement = nil; state.errorMessage = nil; state.busy = true
        let orch = orchestrator
        assistantTask = Task { [weak self] in
            let stream = await orch.runSelectionAction(action)
            await self?.consume(stream)
        }
    }

    private func consume(_ stream: AsyncThrowingStream<AssistantEvent, Error>) async {
        do {
            for try await ev in stream {
                switch ev {
                case .status(let s): state.status = s
                case .context(let c): state.context = c
                case .textDelta(let t): state.response += t
                case .guidance(let g):
                    state.response = g.answer
                    state.guidanceNotes = g.rejected
                    overlay.show(g.annotations, pid: (await orchestrator.lastContext)?.app?.pid)
                case .completed(let a): if state.response.isEmpty { state.response = a }; state.status = ""
                case .replacementReady(let text, let sel): state.replacement = ReplacementProposal(text: text, selection: sel)
                }
            }
        } catch let e as AssistantError {
            if case .model(let m) = e { state.errorMessage = m.userMessage(state.lang) } else { state.errorMessage = e.description }
        } catch {
            state.errorMessage = "\(error)"
        }
        state.busy = false
        state.status = ""
        loadHistory()
    }

    /// Approved replacement of the selected text (explicit user click).
    func applyReplacement() {
        guard let r = state.replacement else { return }
        Task { [weak self] in
            guard let self else { return }
            let decision = await self.broker.request(ApprovalRequest(kind: .replaceSelection, title: "Replace selected text",
                                                                      detail: String(r.text.prefix(300)), risk: .medium, source: "selection"))
            guard decision.isApproved else { return }
            self.panel?.orderOut(nil)
            try? await Task.sleep(nanoseconds: 250_000_000)
            let ok = AXInspector.replaceSelection(with: r.text, expectedOriginal: r.selection.text)
            self.showPanel(focus: false)
            self.state.status = ok ? self.state.t("Replaced.", "바꿨습니다.") : self.state.t("Could not replace (selection changed or field not editable). Use Copy instead.", "바꿀 수 없습니다 (선택이 바뀌었거나 편집할 수 없는 필드). 복사를 사용하세요.")
            if ok { self.state.replacement = nil }
        }
    }

    /// Explicit user action: copy the result to the clipboard.
    func copyResponse(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.status = state.t("Copied.", "복사했습니다.")
    }

    func act(goal: String) {
        guard state.settings.computerUseEnabled else { state.errorMessage = state.t("Computer use is disabled in Settings.", "설정에서 컴퓨터 사용이 꺼져 있습니다."); return }
        guard AXInspector.isTrusted else { state.errorMessage = state.t("Accessibility permission is required for Act mode.", "Act 모드에는 손쉬운 사용 권한이 필요합니다."); return }
        actTask?.cancel()
        state.actLog = []; state.errorMessage = nil; state.busy = true
        let target = contextProvider.targetApplication()
        let scope = target?.bundleIdentifier
        let settings = state.settings
        let executor = ActionExecutor(driver: guiDriver, policy: ActionPolicy(autoApproveUpTo: settings.computerUseAutoApproveUpTo), approvals: broker)
        let driver = guiDriver
        var screenshotProvider: (@Sendable (GUIObservation) async -> CapturedImage?)? = nil
        if settings.assistant.allowScreenshotsToModel {
            screenshotProvider = { obs in await driver.captureWindow(obs) }
        }
        let planner = ModelActionPlanner(models: router, screenshotProvider: screenshotProvider)
        var cfg = ComputerUseConfig(); cfg.maxSteps = settings.computerUseMaxSteps; cfg.maxModelTokens = settings.computerUseTokenBudget
        let session = ComputerUseSession(goal: goal, scopeBundleID: scope, planner: planner, executor: executor, config: cfg)
        let broker = self.broker!
        actTask = Task { [weak self] in
            guard let self else { return }
            // Task-level authorization: the user approves the goal and the app it may operate.
            let ok = await broker.request(ApprovalRequest(kind: .guiAction, title: "Let Tagen operate \(target?.localizedName ?? "the frontmost app")",
                                                           detail: "Goal: \(goal)\nEach high-risk step will still ask.", risk: .medium,
                                                           reasons: ["computer-use task"], source: "act"))
            guard ok.isApproved else { self.state.busy = false; self.state.actLog.append("✋ not approved"); return }
            if let app = target { app.activate(); try? await Task.sleep(nanoseconds: 300_000_000) }
            for await ev in session.run() {
                switch ev {
                case .started(let g, let s): self.state.actLog.append("▶︎ \(g) [\(s ?? "frontmost")]")
                case .observing: break
                case .planned(let a, let why): self.state.actLog.append("→ \(a.summary)" + (why.isEmpty ? "" : " — \(why)"))
                case .phase(let p, let m): if p == .authorize || p == .verify { self.state.actLog.append("   \(p.rawValue): \(m)") }
                case .stepFinished(let r): if !r.succeeded { self.state.actLog.append("   ✗ \(r.outcome)") }
                case .needsUser(let q): self.state.actLog.append("❓ \(q)"); self.state.response = q
                case .finished(let s): self.state.actLog.append("✅ \(s)"); self.state.response = s
                case .failed(let m): self.state.actLog.append("❌ \(m)"); self.state.errorMessage = m
                case .stopped: self.state.actLog.append("⏹ stopped")
                }
            }
            self.state.busy = false
            self.showPanel(focus: false)
        }
    }

    func cancelCurrent() {
        assistantTask?.cancel(); actTask?.cancel()
        Task { await orchestrator.cancel() }
        state.busy = false; state.status = ""
    }

    // MARK: voice

    func pushToTalk(down: Bool) {
        let v = voice!
        if down {
            let missing = PermissionGate.evaluate(.voice, states: state.permissions).missingRequired
            if !missing.isEmpty { showPanel(focus: false); state.errorMessage = state.t("Voice needs Microphone and Speech Recognition permission (text input still works).", "음성에는 마이크와 음성 인식 권한이 필요합니다 (텍스트 입력은 계속 사용 가능)."); return }
            showPanel(focus: false)
            Task { await v.send(.talkPressed) }
        } else {
            Task { await v.send(.talkReleased) }
        }
    }

    func askForVoice(_ text: String) async throws -> String {
        state.input = text
        state.response = ""
        state.busy = true
        defer { state.busy = false }
        let stream = await orchestrator.ask(text, mode: .ask, region: nil)
        var answer = ""
        for try await ev in stream {
            switch ev {
            case .textDelta(let t): state.response += t
            case .context(let c): state.context = c
            case .completed(let a): answer = a
            default: break
            }
        }
        loadHistory()
        return answer
    }

    // MARK: emergency stop

    func emergencyStop() {
        stop.trigger(reason: "user")
    }

    private func handleEmergencyStop(_ reason: String) {
        assistantTask?.cancel(); actTask?.cancel()
        Task { await orchestrator.cancel() }
        Task { await voice.send(.cancel) }
        overlay.clear()
        for a in state.approvals { a.resolve(.denied(reason: "Emergency stop")) }
        state.approvals = []
        state.busy = false
        state.status = state.t("Emergency stop — all activity halted.", "긴급 정지 — 모든 작업을 중단했습니다.")
        // Release the latch shortly after so new, explicitly started work can run.
        Task { try? await Task.sleep(nanoseconds: 1_000_000_000); self.stop.reset() }
    }

    // MARK: agents

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
        let auth = AgentAuthManager(locator: ExecutableLocator(overrides: state.settings.cliPathOverrides), secrets: secrets, loginShellPATH: loginShellPATH)
        for p in AgentProvider.allCases {
            Task { [weak self] in
                let st = await auth.status(p)
                self?.state.agentAuth[p] = st
            }
        }
    }

    /// Opens Terminal with the CLI's own login command (the supported auth flow on the Mac).
    func openLogin(_ p: AgentProvider) {
        let auth = AgentAuthManager(locator: ExecutableLocator(overrides: state.settings.cliPathOverrides), secrets: secrets, loginShellPATH: loginShellPATH)
        guard let exe = auth.executable(p) else { state.errorMessage = "\(p.displayName) CLI not found."; return }
        let script = "#!/bin/zsh -l\n\(AgentAuthManager.loginCommand(p, executable: exe))\necho\necho 'You can close this window and return to Tagen.'\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tagen-login-\(p.rawValue).command")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    // MARK: settings / permissions / history

    func saveSettings(_ s: AppSettings) {
        state.settings = s
        settingsBox.set(s)
        try? store?.setSetting("appSettings", s)
        router = AppController.makeRouter(settings: s, secrets: secrets)
        orchestrator = AssistantOrchestrator(contextProvider: contextProvider, models: router, store: s.keepHistory ? store : nil, settings: s.assistant)
        let v = voice!
        Task { await v.updateSettings(s.voice) }
        rebuildAgentManager()
        refreshAgentAuth()
        registerHotkeys()
        statusBar?.rebuildMenu()
    }

    func setSecret(_ key: String, _ value: String) {
        if value.isEmpty { try? secrets.delete(key) } else { try? secrets.set(key, value: value) }
        state.hasAnthropicKey = ((try? secrets.get(SecretKey.anthropicAPIKey)) ?? nil)?.isEmpty == false
        saveSettings(state.settings)
    }

    func refreshPermissions() {
        let checker = permissions!
        Task { [weak self] in
            var out: [PermissionKind: PermissionState] = [:]
            for k in PermissionKind.allCases { out[k] = await checker.status(k) }
            self?.state.permissions = out
        }
    }

    func requestPermission(_ k: PermissionKind) {
        let checker = permissions!
        Task { [weak self] in _ = await checker.request(k); self?.refreshPermissions() }
    }

    func openPermissionSettings(_ k: PermissionKind) {
        let checker = permissions!
        Task { await checker.openSystemSettings(for: k) }
    }

    func loadHistory() {
        state.history = (try? store?.conversations()) ?? []
    }

    func openConversation(_ id: UUID) { state.historyMessages = (try? store?.messages(conversationID: id)) ?? [] }

    /// Continue a past conversation from the History tab.
    func continueConversation(_ id: UUID) {
        let orch = orchestrator
        Task { [weak self] in
            guard let self else { return }
            do {
                let n = try await orch.resumeConversation(recordID: id)
                self.state.response = ""; self.state.context = nil; self.state.input = ""
                self.state.tab = .assistant; self.state.mode = .ask
                self.state.status = self.state.t("Continuing a conversation with \(n) earlier messages.", "이전 메시지 \(n)개가 있는 대화를 이어갑니다.")
            } catch { self.state.errorMessage = "\(error)" }
        }
    }

    func deleteAllHistory() { try? store?.deleteAllHistory(); state.historyMessages = []; loadHistory() }

    func newConversation() {
        Task { await orchestrator.newConversation() }
        state.response = ""; state.input = ""; state.context = nil; overlay.clear()
    }

    var settingsWindow: NSWindow?
    func openSettings(tab: SettingsTab = .general) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Tagen Settings"
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(initialTab: tab).environmentObject(state).environment(\.appController, self))
        settingsWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct AppControllerKey: EnvironmentKey { static let defaultValue: AppController? = nil }
extension EnvironmentValues {
    var appController: AppController? {
        get { self[AppControllerKey.self] }
        set { self[AppControllerKey.self] = newValue }
    }
}
#endif
