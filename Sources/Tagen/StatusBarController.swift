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
        let m = NSMenu()
        add(m, "Open Assistant", "⌥Space") { $0.showPanel(focus: true) }
        add(m, "Ask About Screen Region…", "⌥⇧R") { $0.askAboutRegion() }
        add(m, "Explain Selection", "⌥⇧S") { $0.showPanel(focus: true); $0.runSelection(.explain) }
        add(m, "Guide Me…", "⌥⇧G") { $0.state.mode = .guide; $0.showPanel(focus: true) }
        m.addItem(.separator())
        add(m, "Coding Agents…", nil) { $0.state.tab = .agents; $0.showPanel(focus: true) }
        add(m, "History…", nil) { $0.state.tab = .history; $0.showPanel(focus: true) }
        add(m, "Permissions…", nil) { $0.openSettings(tab: .permissions) }
        add(m, "Settings…", nil) { $0.openSettings() }
        m.addItem(.separator())
        add(m, "⏹ Emergency Stop", "⌃⌥⌘.") { $0.emergencyStop() }
        m.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Tagen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(quit)
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
