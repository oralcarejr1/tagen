#if os(macOS)
import AppKit
@preconcurrency import ApplicationServices
import TagenCore
import TagenMac

// tagen-gui-check — live verification of Tagen's computer-use stack against TagenFixture.
// It never changes system permissions. Without Accessibility permission it reports
// "blocked" (exit 2) instead of simulating results.

struct TaskResult: Codable { var name: String; var category: String; var passed: Bool; var detail: String; var durationMs: Int }

var fixturePath: String?
var outputPath = "live-gui-check.json"
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    if a == "--fixture" { fixturePath = it.next() }
    if a == "--output" { outputPath = it.next() ?? outputPath }
}

@MainActor func writeReport(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: URL(fileURLWithPath: outputPath))
        print(String(decoding: d, as: UTF8.self))
    }
}

let env: [String: Any] = [
    "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
    "accessibilityTrusted": AXIsProcessTrusted(),
    "screenRecording": CGPreflightScreenCaptureAccess(),
    "displays": await MainActor.run { MacDisplays.layout().displays.map { "\($0.id): \($0.frame) @\($0.scale)x" } },
]

guard AXIsProcessTrusted() else {
    writeReport(["status": "blocked", "reason": "Accessibility permission is not granted to tagen-gui-check; live GUI automation cannot run here. Grant it in System Settings › Privacy & Security › Accessibility and rerun.", "environment": env])
    exit(2)
}
guard let fixture = fixturePath else { writeReport(["status": "error", "reason": "--fixture required"]); exit(64) }

// Launch the fixture with a truth file.
let truthPath = NSTemporaryDirectory() + "tagen-fixture-truth-\(UUID().uuidString.prefix(6)).json"
let proc = Process()
proc.executableURL = URL(fileURLWithPath: fixture + "/Contents/MacOS/TagenFixture")
proc.arguments = ["--truth", truthPath]
do { try proc.run() } catch { writeReport(["status": "error", "reason": "cannot launch fixture: \(error)"]); exit(1) }
defer { proc.terminate() }

let bundleID = "dev.tagen.Fixture"
let driver = MacGUIDriver()
@MainActor func activateFixture() async {
    if let app = NSRunningApplication(processIdentifier: proc.processIdentifier) { app.activate() }
    try? await Task.sleep(nanoseconds: 300_000_000)
}
// Wait for the window to be observable.
var ready = false
for _ in 0..<60 {
    await activateFixture()
    if let o = try? await driver.observe(scopeBundleID: bundleID), o.root?.flattened().contains(where: { $0.identifier == "incrementButton" }) == true { ready = true; break }
}
guard ready else { writeReport(["status": "error", "reason": "fixture window not observable", "environment": env]); exit(1) }

let audit = MemoryAuditSink()
// Safe tasks run with a presenter that denies everything: they must succeed without needing
// any approval (risk ≤ medium). Safety tests use the same deny-all presenter.
let broker = ApprovalBroker(presenter: DenyAllPresenter(), timeout: 5, audit: audit)
var cfg = ExecutorConfig(); cfg.userInputGrace = 0
let executor = ActionExecutor(driver: driver, policy: ActionPolicy(autoApproveUpTo: .medium), approvals: broker, config: cfg)
func q(_ id: String) -> ElementTarget { .query(ElementQuery(identifier: id)) }
@MainActor func observe() async -> GUIObservation? { try? await driver.observe(scopeBundleID: bundleID) }
func value(_ id: String, _ o: GUIObservation?) -> String? {
    o?.root?.flattened().first { $0.identifier == id }.map { $0.value ?? $0.title ?? "" }
}
func count(_ o: GUIObservation?) -> Int? {
    guard let v = value("countLabel", o) else { return nil }
    return Int(v.replacingOccurrences(of: "Count: ", with: ""))
}
@MainActor func countNow() async -> Int? { count(await observe()) }
@MainActor func valueNow(_ id: String) async -> String? { value(id, await observe()) }
@MainActor func frameNow(_ id: String) async -> Rect? { (await observe())?.root?.flattened().first { $0.identifier == id }?.frame }
@MainActor func run(_ actions: [GUIAction]) async -> [StepReport] {
    var reps: [StepReport] = []
    for a in actions { let r = await executor.run(a, scopeBundleID: bundleID); reps.append(r); if !r.succeeded { break } }
    return reps
}
func allOK(_ r: [StepReport]) -> Bool { r.allSatisfy(\.succeeded) }
func describe(_ r: [StepReport]) -> String { r.map { "\($0.action.summary): \($0.outcome)" }.joined(separator: " | ") }

var results: [TaskResult] = []
@MainActor func task(_ name: String, _ category: String = "safe", _ body: () async -> (Bool, String)) async {
    await activateFixture()
    let t0 = Date()
    let (ok, detail) = await body()
    results.append(TaskResult(name: name, category: category, passed: ok, detail: detail, durationMs: Int(Date().timeIntervalSince(t0) * 1000)))
    print("[\(ok ? "PASS" : "FAIL")] \(name) — \(detail.prefix(200))")
}
@MainActor func resetCounter() async { _ = await run([.selectMenu(path: ["Fixture", "Set Counter to Zero"])]) }

// ---- Safe tasks ----
await task("click increment") { await resetCounter(); let r = await run([.click(q("incrementButton"))]); let c = await countNow(); return (allOK(r) && c == 1, describe(r)) }
await task("click increment twice") { await resetCounter(); let r = await run([.click(q("incrementButton")), .click(q("incrementButton"))]); let c = await countNow(); return (allOK(r) && c == 2, describe(r)) }
await task("menu set counter to zero") { _ = await run([.click(q("incrementButton"))]); let r = await run([.selectMenu(path: ["Fixture", "Set Counter to Zero"])]); let c = await countNow(); return (allOK(r) && c == 0, describe(r)) }
await task("shortcut cmd+R zeroes counter") { _ = await run([.click(q("incrementButton"))]); let r = await run([.pressKeys(KeyCombo(key: "r", modifiers: [.command]))]); let c = await countNow(); return (allOK(r) && c == 0, describe(r)) }
await task("submenu add ten") { await resetCounter(); let r = await run([.selectMenu(path: ["Fixture", "Counter", "Add Ten"])]); let c = await countNow(); return (allOK(r) && c == 10, describe(r)) }
await task("type name") { let r = await run([.typeText(q("nameField"), text: "Alice")]); let v = await valueNow("nameField"); return (allOK(r) && v == "Alice", describe(r)) }
await task("type then greet") { let r = await run([.typeText(q("nameField"), text: "Alice"), .click(q("greetButton"))]); let v = await valueNow("greetingLabel"); return (allOK(r) && v == "Greeting: Hello, Alice!", describe(r)) }
await task("type Korean then greet") { let r = await run([.typeText(q("nameField"), text: "김철수"), .click(q("greetButton"))]); let v = await valueNow("greetingLabel"); return (allOK(r) && v == "Greeting: Hello, 김철수!", describe(r)) }
await task("toggle checkbox on") { let before = await valueNow("featureCheckbox"); let r = await run([.click(q("featureCheckbox"))]); let after = await valueNow("featureCheckbox"); return (allOK(r) && before != after, "\(before ?? "?")→\(after ?? "?") " + describe(r)) }
await task("toggle checkbox back") { let before = await valueNow("featureCheckbox"); let r = await run([.click(q("featureCheckbox"))]); let after = await valueNow("featureCheckbox"); return (allOK(r) && before != after, "\(before ?? "?")→\(after ?? "?") " + describe(r)) }
await task("menu default greeting") { let r = await run([.selectMenu(path: ["Fixture", "Set Default Greeting"])]); let v = await valueNow("greetingLabel"); return (allOK(r) && v == "Greeting: Hello, World!", describe(r)) }
await task("scroll rows down") {
    let f0 = await frameNow("row1")
    let r = await run([.scroll(q("rowsScroll"), direction: .down, amount: 8)])
    try? await Task.sleep(nanoseconds: 300_000_000)
    let f1 = await frameNow("row1")
    return (allOK(r) && f0 != f1, "row1 \(f0.map { "\($0)" } ?? "nil") → \(f1.map { "\($0)" } ?? "nil")")
}
await task("scroll rows up") {
    let f0 = await frameNow("row1")
    let r = await run([.scroll(q("rowsScroll"), direction: .up, amount: 8)])
    try? await Task.sleep(nanoseconds: 300_000_000)
    let f1 = await frameNow("row1")
    return (allOK(r) && f0 != f1, "row1 \(f0.map { "\($0)" } ?? "nil") → \(f1.map { "\($0)" } ?? "nil")")
}
await task("wait for element") { let r = await run([.wait(.elementExists(ElementQuery(identifier: "countLabel")), timeout: 3)]); return (allOK(r), describe(r)) }
await task("open and close sheet") {
    let r = await run([.click(q("detailsButton")), .wait(.elementExists(ElementQuery(role: "AXButton", title: "Close")), timeout: 5),
                       .click(.query(ElementQuery(role: "AXButton", title: "Close"))), .wait(.elementGone(ElementQuery(role: "AXButton", title: "Close")), timeout: 5)])
    let v = await valueNow("statusLabel")
    return (allOK(r) && v == "Last action: details closed", describe(r))
}
await task("replace name") { let r = await run([.typeText(q("nameField"), text: "Bob", replaceExisting: true)]); let v = await valueNow("nameField"); return (allOK(r) && v == "Bob", describe(r)) }
await task("type long text") { let t = String(repeating: "abc123 ", count: 14); let r = await run([.typeText(q("nameField"), text: t)]); let v = await valueNow("nameField"); return (allOK(r) && v == t, describe(r)) }
await task("type mixed language") { let r = await run([.typeText(q("nameField"), text: "Tagen 테스트 123")]); let v = await valueNow("nameField"); return (allOK(r) && v == "Tagen 테스트 123", describe(r)) }
await task("keystroke typing fallback") {
    _ = await run([.typeText(q("nameField"), text: "x")])
    let r = await run([.click(q("nameField")), .pressKeys(KeyCombo(key: "a", modifiers: [.command]))])
    let r2 = await executor.run(.typeText(nil, text: "typed", replaceExisting: false), scopeBundleID: bundleID)
    let v = await valueNow("nameField")
    return (allOK(r) && r2.succeeded && v == "typed", "value=\(v ?? "nil") " + describe(r + [r2]))
}
await task("double click increments") { await resetCounter(); let r = await run([.click(q("incrementButton"), count: 2)]); let c = await countNow() ?? 0; return (allOK(r) && c >= 1, "count=\(c) " + describe(r)) }
await task("focus fixture app") { let r = await run([.focusApp(bundleID)]); return (allOK(r), describe(r)) }
for i in 1...5 {
    await task("coordinate click #\(i) from fresh observation") {
        await resetCounter()
        guard let o = await observe(), let f = o.root?.flattened().first(where: { $0.identifier == "incrementButton" })?.frame else { return (false, "no frame") }
        let r = await executor.run(.click(.point(f.center, observationID: o.id)), scopeBundleID: bundleID, previous: o)
        let c = await countNow()
        return (r.succeeded && c == 1, "\(r.outcome)")
    }
}
await task("click after window moved (re-resolve)") {
    await resetCounter()
    if let o = await observe(), let w = o.window {
        let app = AXInspector.application(pid: proc.processIdentifier)
        if let win = AXInspector.focusedWindow(of: app) {
            var p = CGPoint(x: w.frame.x + 60, y: w.frame.y + 40)
            if let v = AXValueCreate(.cgPoint, &p) { win.set(kAXPositionAttribute as String, v) }
        }
    }
    try? await Task.sleep(nanoseconds: 400_000_000)
    let r = await run([.click(q("incrementButton"))])
    let c = await countNow()
    return (allOK(r) && c == 1, describe(r))
}

// ---- Safety tests (must NOT execute) ----
await task("stale coordinates are refused", "safety") {
    await resetCounter()
    guard let old = await observe(), let f = old.root?.flattened().first(where: { $0.identifier == "incrementButton" })?.frame else { return (false, "no frame") }
    _ = await run([.typeText(q("nameField"), text: "changed-\(UUID().uuidString.prefix(4))")])   // UI changes
    let r = await executor.run(.click(.point(f.center, observationID: old.id)), scopeBundleID: bundleID, previous: nil)
    let c = await countNow()
    return (!r.succeeded && c == 0, "\(r.outcome); count=\(c.map(String.init) ?? "nil")")
}
await task("destructive button requires approval (denied)", "safety") {
    await resetCounter()
    let r = await executor.run(.click(q("deleteButton")), scopeBundleID: bundleID)
    let c = await countNow()
    if case .denied = r.outcome { return (c == 0, "denied as expected; risk=\(r.risk.map { "\($0)" } ?? "?")") }
    return (false, "NOT denied: \(r.outcome)")
}
await task("typing a secret requires approval (denied)", "safety") {
    let secret = "sk-ant-api03-" + String(repeating: "x", count: 24)
    let r = await executor.run(.typeText(q("nameField"), text: secret), scopeBundleID: bundleID)
    let v = await valueNow("nameField") ?? ""
    if case .denied = r.outcome { return (!v.contains("sk-ant"), "denied as expected") }
    return (false, "NOT denied: \(r.outcome)")
}
await task("ambiguous target is refused", "safety") {
    let r = await executor.run(.click(.query(ElementQuery(role: "AXButton"))), scopeBundleID: bundleID)
    return (!r.succeeded, "\(r.outcome)")
}
await task("reset menu (destructive wording) requires approval (denied)", "safety") {
    let r = await executor.run(.selectMenu(path: ["Edit", "Reset Everything"]), scopeBundleID: bundleID)
    if case .denied = r.outcome { return (true, "denied as expected") }
    return (false, "NOT denied: \(r.outcome)")
}

// ---- Anchoring accuracy: AX frames vs fixture's own frames ----
try? await Task.sleep(nanoseconds: 600_000_000)
var anchorErrors: [String: Double] = [:]
if let d = FileManager.default.contents(atPath: truthPath), let truth = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Double]],
   let o = await observe() {
    for (id, t) in truth where !id.hasPrefix("_") {
        guard let f = o.root?.flattened().first(where: { $0.identifier == id })?.frame,
              let tx = t["x"], let ty = t["y"], let tw = t["width"], let th = t["height"] else { continue }
        let tr = Rect(x: tx, y: ty, width: tw, height: th)
        anchorErrors[id] = max(abs(f.midX - tr.midX), abs(f.midY - tr.midY))
    }
}

// ---- Selected-text extraction via AX ----
var selectionResults: [[String: Any]] = []
if let o = await observe(), let notes = o.root?.flattened().first(where: { $0.identifier == "notesText" }) {
    let app = AXInspector.application(pid: proc.processIdentifier)
    let full = notes.value ?? ""
    let cases: [(Int, Int)] = [(0, 6), (20, 5), (21, 14), (0, full.utf16.count), (40, 9)]
    for (loc, len) in cases {
        guard let w = AXInspector.focusedWindow(of: app) else { break }
        let snap = AXInspector.snapshot(window: w)
        guard let h = snap.root.flatMap({ r in r.flattened().first { $0.identifier == "notesText" } }).flatMap({ snap.handles[$0.id] }) else { continue }
        h.set(kAXFocusedAttribute as String, kCFBooleanTrue)
        var range = CFRange(location: loc, length: min(len, max(0, full.utf16.count - loc)))
        if let v = AXValueCreate(.cfRange, &range) { h.set(kAXSelectedTextRangeAttribute as String, v) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let expected = (full as NSString).substring(with: NSRange(location: range.location, length: range.length))
        let got = AXInspector.selectedText()?.text
        selectionResults.append(["range": "\(range.location)+\(range.length)", "expected": expected, "got": got ?? NSNull(), "ok": got == expected])
    }
}

let safe = results.filter { $0.category == "safe" }
let safety = results.filter { $0.category == "safety" }
let safeRate = safe.isEmpty ? 0 : Double(safe.filter(\.passed).count) / Double(safe.count)
let unauthorized = safety.filter { !$0.passed }.count
let selOK = selectionResults.filter { ($0["ok"] as? Bool) == true }.count
let maxAnchor = anchorErrors.values.max() ?? -1
let report: [String: Any] = [
    "status": "ran",
    "environment": env,
    "safeTasks": ["total": safe.count, "passed": safe.filter(\.passed).count, "successRate": safeRate],
    "safetyTests": ["total": safety.count, "passed": safety.filter(\.passed).count, "unauthorizedHighRiskExecutions": unauthorized],
    "anchoring": ["maxErrorPoints": maxAnchor, "perElement": anchorErrors, "targetPoints": 12],
    "selectionExtraction": ["total": selectionResults.count, "passed": selOK, "cases": selectionResults],
    "approvalAudit": audit.all.map { "\($0.action) → \($0.decision)" },
    "tasks": results.map { ["name": $0.name, "category": $0.category, "passed": $0.passed, "detail": $0.detail, "ms": $0.durationMs] },
]
writeReport(report)
exit(safeRate >= 0.9 && unauthorized == 0 ? 0 : 1)
#else
print("tagen-gui-check runs on macOS only.")
#endif
