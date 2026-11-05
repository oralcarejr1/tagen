#if os(macOS)
import AppKit
import TagenCore

@MainActor
final class StatusBarController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    weak var controller: AppController?

    init(controller: AppController) {
        self.controller = controller
        super.init()
        item.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Tagen")
        rebuildMenu()
    }

    /// Builds the menu with the user's current shortcut bindings.
    func rebuildMenu() {
        guard let c = controller else { return }
        actions.removeAll()
        let hk = c.state.settings.hotkeys
        func hint(_ a: HotkeyAction) -> String? { hk[a]?.description }
        let ko = c.state.lang == .korean
        let m = NSMenu()
        add(m, ko ? "어시스턴트 열기" : "Open Assistant", hint(.toggleAssistant)) { $0.showPanel(focus: true) }
        add(m, ko ? "화면 영역 질문…" : "Ask About Screen Region…", hint(.region)) { $0.askAboutRegion() }
        add(m, ko ? "선택 텍스트 설명" : "Explain Selection", hint(.explainSelection)) { $0.showPanel(focus: true); $0.runSelection(.explain) }
        add(m, ko ? "가이드…" : "Guide Me…", hint(.guide)) { $0.state.mode = .guide; $0.showPanel(focus: true) }
        m.addItem(.separator())
        add(m, ko ? "코딩 에이전트…" : "Coding Agents…", nil) { $0.state.tab = .agents; $0.showPanel(focus: true) }
        add(m, ko ? "기록…" : "History…", nil) { $0.state.tab = .history; $0.showPanel(focus: true) }
        add(m, ko ? "권한…" : "Permissions…", nil) { $0.openSettings(tab: .permissions) }
        add(m, ko ? "설정…" : "Settings…", nil) { $0.openSettings() }
        m.addItem(.separator())
        add(m, ko ? "⏹ 긴급 정지" : "⏹ Emergency Stop", hint(.emergencyStop)) { $0.emergencyStop() }
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: ko ? "Tagen 종료" : "Quit Tagen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = m
    }

    private var actions: [ObjectIdentifier: (AppController) -> Void] = [:]

    private func add(_ m: NSMenu, _ title: String, _ hint: String?, _ action: @escaping (AppController) -> Void) {
        let i = NSMenuItem(title: hint.map { "\(title)    \($0)" } ?? title, action: #selector(fire(_:)), keyEquivalent: "")
        i.target = self
        actions[ObjectIdentifier(i)] = action
        m.addItem(i)
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard let c = controller else { return }
        actions[ObjectIdentifier(sender)]?(c)
    }
}
#endif
