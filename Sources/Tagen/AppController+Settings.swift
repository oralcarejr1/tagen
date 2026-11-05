#if os(macOS)
import AppKit
import SwiftUI
import TagenCore
import TagenAgents
import TagenMac

// Settings, shortcuts, secrets, permissions and history.
extension AppController {
    func registerHotkeys() {
        let hk = GlobalHotkeys.shared
        hk.unregisterAll()
        hk.failures.removeAll()
        // Never take over an enabled macOS shortcut: Carbon hot keys swallow the keystroke, which broke
        // Korean/English switching on ⌃⌥Space (also what Karabiner "right ⌘ → 한/영" rules send).
        let resolved = HotkeyBindings.resolvingSystemConflicts(state.settings.hotkeys, system: MacSystemShortcuts.current())
        if !resolved.fixes.isEmpty {
            var s = state.settings
            s.hotkeys = resolved.bindings
            state.settings = s
            settingsBox.set(s)
            try? store?.setSetting("appSettings", s)
        }
        let b = resolved.bindings
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
        if !resolved.fixes.isEmpty {
            let lang = state.lang
            state.errorMessage = state.t("Changed shortcuts that would block macOS shortcuts: ", "macOS 단축키를 막는 단축키를 바꿨습니다: ")
                + resolved.fixes.map { f in
                    "\(f.action.title(lang)) \(f.from) → " + (f.to.map { "\($0)" } ?? state.t("none", "없음")) + " (\(f.system.name(lang)))"
                }.joined(separator: ", ")
        }
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

    /// Starts a fresh copy of the app and quits this one (Screen Recording only applies after a relaunch).
    func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
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
#endif
