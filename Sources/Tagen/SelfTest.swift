#if os(macOS)
import AppKit
import TagenCore
import TagenAgents
import TagenMac

/// `Tagen --self-test`: initializes subsystems headlessly and prints a JSON report.
/// Runs on CI to verify the packaged binary launches and its components wire up.
@MainActor
enum SelfTest {
    static func run() async -> Int32 {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ body: () async throws -> (String, String)) async {
            do { let (st, d) = try await body(); checks.append(["name": name, "status": st, "detail": d]) }
            catch { checks.append(["name": name, "status": "fail", "detail": "\(error)"]) }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tagen-selftest-\(UUID().uuidString.prefix(6)).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp.path + s) } }

        await check("persistence") {
            let store = try AppStore(path: tmp.path)
            let c = try store.createConversation(title: "self-test", mode: "ask")
            _ = try store.appendMessage(conversationID: c.id, role: .user, text: "key sk-ant-api03-abcdefghijklmnopqrstuvwxyz", hadImage: false)
            let m = try store.messages(conversationID: c.id)
            guard m.first?.text.contains("REDACTED") == true else { return ("fail", "secret not redacted") }
            return ("pass", "sqlite ok, redaction ok")
        }
        await check("settings round-trip") {
            let store = try AppStore(path: tmp.path)
            var s = AppSettings(); s.voice.recognitionLanguage = .english
            try store.setSetting("appSettings", s)
            let back = try store.setting("appSettings", as: AppSettings.self)
            return back == s ? ("pass", "ok") : ("fail", "mismatch")
        }
        await check("model router") {
            let r = AppController.makeRouter(settings: AppSettings(), secrets: InMemorySecretStore())
            return ("pass", "screenQuestion → \(r.route(for: .screenQuestion).model)")
        }
        await check("hotkeys vs macOS shortcuts") {
            let system = MacSystemShortcuts.current()
            let fixes = HotkeyBindings.resolvingSystemConflicts(HotkeyBindings.defaults, system: system).fixes
            let ids = system.map(\.id).filter { [60, 61, 64].contains($0) }
            return (fixes.isEmpty ? "pass" : "fail",
                    "\(system.count) enabled system shortcuts (input source/Spotlight ids: \(ids)); default conflicts: \(fixes.map { "\($0.action.rawValue)→\($0.system.id)" })")
        }
        await check("display layout") {
            let l = MacDisplays.layout()
            return (l.displays.isEmpty ? "skip" : "pass", l.displays.map { "\($0.id) \($0.frame) @\($0.scale)x" }.joined(separator: "; "))
        }
        await check("permissions (report only)") {
            let p = MacPermissionChecker(appSwitches: { _ in false })
            var parts: [String] = []
            for k in PermissionKind.allCases { parts.append("\(k.rawValue)=\(await p.status(k).rawValue)") }
            return ("pass", parts.joined(separator: ", "))
        }
        await check("agent CLI discovery (report only)") {
            let tools = CLIToolchain(secrets: InMemorySecretStore(), loginShellPATH: ExecutableLocator.loginShellPATH())
            return ("pass", AgentProvider.allCases.map { "\($0.executableName)=\(tools.executable($0) ?? "not found")" }.joined(separator: ", "))
        }
        await check("approval relay helper bundled") {
            let mcp = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tagen-approval-mcp").path
            return FileManager.default.isExecutableFile(atPath: mcp) ? ("pass", mcp) : ("skip", "not running from bundle")
        }
        await check("overlay render") {
            let oc = OverlayController(frameProvider: { _ in nil }, windowFrameProvider: { _ in nil })
            let l = MacDisplays.layout()
            guard let d = l.primary else { return ("skip", "no display") }
            let target = Rect(x: d.frame.midX - 50, y: d.frame.midY - 15, width: 100, height: 30)
            let a = Annotation(kind: .arrow, target: .screen(target), label: "Self-test", createdAt: Date(), ttl: 2, windowFrame: nil)
            let t0 = CFAbsoluteTimeGetCurrent()
            oc.show([a], pid: nil)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            oc.clear()
            return ("pass", String(format: "rendered in %.1f ms", ms))
        }
        await check("assistant panel open latency") {
            let controller = AppController(storeURL: nil, secrets: InMemorySecretStore())
            var samples: [Double] = []
            for _ in 0..<21 {
                samples.append(controller.showPanel(focus: false))
                controller.panel?.orderOut(nil)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            let sorted = samples.sorted()
            let median = sorted[sorted.count / 2]
            return (median < 250 ? "pass" : "fail", String(format: "median %.1f ms, first %.1f ms, max %.1f ms (n=%d, target <250 ms)", median, samples[0], sorted.last!, samples.count))
        }
        let failed = checks.contains { ($0["status"] as? String) == "fail" }
        let report: [String: Any] = ["app": "Tagen", "checks": checks, "result": failed ? "fail" : "pass"]
        if let d = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: d, as: UTF8.self))
        }
        return failed ? 1 : 0
    }
}
#endif
