#if os(macOS)
import AppKit

// TagenFixture — deterministic test application for live computer-use verification.
// Every control has a stable accessibility identifier. With `--truth <path>` it writes the
// true on-screen frames of its controls (global, top-left origin) as JSON after layout.

final class FixtureController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let countLabel = NSTextField(labelWithString: "Count: 0")
    let greetingLabel = NSTextField(labelWithString: "Greeting: (none)")
    let statusLabel = NSTextField(labelWithString: "Last action: none")
    let nameField = NSTextField(string: "")
    let checkbox = NSButton(checkboxWithTitle: "Enable feature", target: nil, action: nil)
    let textView = NSTextView()
    var rowsScroll: NSScrollView!
    var incButton: NSButton!
    var count = 0
    var truthPath: String?

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--truth"), i + 1 < args.count { truthPath = args[i + 1] }
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.writeTruth() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func windowDidMove(_ n: Notification) { writeTruth() }
    func windowDidResize(_ n: Notification) { writeTruth() }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit TagenFixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")

        let fxItem = NSMenuItem(); main.addItem(fxItem)
        let fx = NSMenu(title: "Fixture"); fxItem.submenu = fx
        let reset = NSMenuItem(title: "Reset Counter", action: #selector(resetCounter), keyEquivalent: "r"); reset.target = self; fx.addItem(reset)
        let def = NSMenuItem(title: "Set Default Greeting", action: #selector(defaultGreeting), keyEquivalent: ""); def.target = self; fx.addItem(def)
        let sub = NSMenuItem(title: "Counter", action: nil, keyEquivalent: ""); fx.addItem(sub)
        let subMenu = NSMenu(title: "Counter"); sub.submenu = subMenu
        let add10 = NSMenuItem(title: "Add Ten", action: #selector(addTen), keyEquivalent: ""); add10.target = self; subMenu.addItem(add10)
        NSApp.mainMenu = main
    }

    func button(_ title: String, _ id: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.setAccessibilityIdentifier(id)
        b.bezelStyle = .rounded
        return b
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 560, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Tagen Fixture"
        window.delegate = self
        countLabel.setAccessibilityIdentifier("countLabel")
        greetingLabel.setAccessibilityIdentifier("greetingLabel")
        statusLabel.setAccessibilityIdentifier("statusLabel")
        nameField.setAccessibilityIdentifier("nameField")
        nameField.placeholderString = "Name"
        checkbox.setAccessibilityIdentifier("featureCheckbox")
        checkbox.target = self; checkbox.action = #selector(toggled)

        let inc = button("Increment", "incrementButton", #selector(increment))
        incButton = inc
        let greet = button("Greet", "greetButton", #selector(greet))
        let del = button("Delete Everything", "deleteButton", #selector(deleteEverything))
        let open = button("Open Details", "detailsButton", #selector(openDetails))

        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let row1 = NSStackView(views: [inc, countLabel])
        let row2 = NSStackView(views: [nameField, greet]); nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let row3 = NSStackView(views: [checkbox, open, del])

        textView.string = "Tagen fixture text.\n안녕하세요, 테스트 문장입니다.\nThe quick brown fox jumps over the lazy dog."
        textView.setAccessibilityIdentifier("notesText")
        textView.isEditable = true
        let textScroll = NSScrollView(); textScroll.documentView = textView; textScroll.hasVerticalScroller = true
        textScroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        textScroll.widthAnchor.constraint(equalToConstant: 520).isActive = true
        textView.minSize = NSSize(width: 0, height: 90); textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let rows = NSStackView(); rows.orientation = .vertical; rows.alignment = .leading
        for i in 1...60 { let l = NSTextField(labelWithString: "Row \(i)"); l.setAccessibilityIdentifier("row\(i)"); rows.addArrangedSubview(l) }
        rowsScroll = NSScrollView()
        let flipped = FlippedView(); flipped.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([rows.topAnchor.constraint(equalTo: flipped.topAnchor), rows.leadingAnchor.constraint(equalTo: flipped.leadingAnchor)])
        flipped.frame = NSRect(x: 0, y: 0, width: 480, height: 60 * 22)
        rowsScroll.documentView = flipped
        rowsScroll.hasVerticalScroller = true
        rowsScroll.setAccessibilityIdentifier("rowsScroll")
        rowsScroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        rowsScroll.widthAnchor.constraint(equalToConstant: 520).isActive = true

        for v in [row1, row2, row3, greetingLabel, statusLabel, textScroll, rowsScroll] as [NSView] { stack.addArrangedSubview(v) }
        window.contentView = stack
    }

    func note(_ s: String) { statusLabel.stringValue = "Last action: \(s)"; writeTruth() }
    @objc func increment() { count += 1; countLabel.stringValue = "Count: \(count)"; note("increment") }
    @objc func addTen() { count += 10; countLabel.stringValue = "Count: \(count)"; note("add ten") }
    @objc func resetCounter() { count = 0; countLabel.stringValue = "Count: 0"; note("reset") }
    @objc func greet() { greetingLabel.stringValue = "Greeting: Hello, \(nameField.stringValue)!"; note("greet") }
    @objc func defaultGreeting() { greetingLabel.stringValue = "Greeting: Hello, World!"; note("default greeting") }
    @objc func toggled() { note("checkbox \(checkbox.state == .on ? "on" : "off")") }
    @objc func deleteEverything() { count = -999; countLabel.stringValue = "Count: DELETED"; note("DELETE EVERYTHING") }
    @objc func openDetails() {
        let alert = NSAlert(); alert.messageText = "Details"; alert.informativeText = "Fixture details sheet"
        alert.addButton(withTitle: "Close")
        alert.beginSheetModal(for: window) { _ in self.note("details closed") }
        note("details opened")
    }

    /// True frames of controls in global top-left coordinates.
    func writeTruth() {
        guard let path = truthPath, let screen = NSScreen.screens.first else { return }
        let ph = screen.frame.height
        var out: [String: [String: Double]] = [:]
        let views: [(String, NSView)] = [("incrementButton", incButton), ("countLabel", countLabel),
                                         ("nameField", nameField), ("greetingLabel", greetingLabel), ("featureCheckbox", checkbox),
                                         ("statusLabel", statusLabel), ("rowsScroll", rowsScroll)]
        for (id, v) in views {
            guard let w = v.window else { continue }
            let r = w.convertToScreen(v.convert(v.bounds, to: nil))
            out[id] = ["x": r.minX, "y": ph - r.maxY, "width": r.width, "height": r.height]
        }
        out["_window"] = ["x": window.frame.minX, "y": ph - window.frame.maxY, "width": window.frame.width, "height": window.frame.height]
        out["_state"] = ["count": Double(count), "checkbox": checkbox.state == .on ? 1 : 0]
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) { try? d.write(to: URL(fileURLWithPath: path)) }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

let app = NSApplication.shared
let controller = FixtureController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
#else
print("TagenFixtureApp runs on macOS only.")
#endif
