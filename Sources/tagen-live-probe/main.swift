#if os(macOS)
import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import AVFoundation
import TagenCore
import TagenMac

// tagen-live-probe — measures Tagen's macOS layer against real built-in apps (TextEdit, Safari, Finder):
// context capture, AX snapshot cost, OCR, selected-text extraction, pixel-level overlay alignment and TTS.
// Never changes permissions; reports "blocked" for anything the session does not allow.

var outputPath = "live-probe.json"
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() { if a == "--output" { outputPath = it.next() ?? outputPath } }

@MainActor final class Probe {
    var results: [[String: Any]] = []
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tagen-probe-\(UUID().uuidString.prefix(6))")
    var launched: [NSRunningApplication] = []

    func record(_ name: String, _ status: String, _ detail: [String: Any]) {
        var d = detail; d["name"] = name; d["status"] = status
        results.append(d)
        print("[\(status.uppercased())] \(name) — \(detail.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ").prefix(260))")
    }

    func ms(_ t0: CFAbsoluteTime) -> Double { ((CFAbsoluteTimeGetCurrent() - t0) * 1000 * 10).rounded() / 10 }

    func open(_ url: URL, with bundleID: String) async -> NSRunningApplication? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let app = try? await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg)
        if let app { launched.append(app) }
        return app
    }

    func waitForWindow(_ app: NSRunningApplication, titleContains: String? = nil, timeout: Double = 20) async -> AXElement? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            app.activate()
            let ax = AXInspector.application(pid: app.processIdentifier)
            if let w = AXInspector.focusedWindow(of: ax) {
                if let t = titleContains { if (w.string(kAXTitleAttribute as String) ?? "").contains(t) { return w } } else { return w }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return nil
    }

    func snapshotTiming(_ w: AXElement, runs: Int = 5) -> (median: Double, count: Int, truncated: Bool) {
        var times: [Double] = []
        var count = 0, truncated = false
        for _ in 0..<runs {
            let t0 = CFAbsoluteTimeGetCurrent()
            let s = AXInspector.snapshot(window: w)
            times.append(ms(t0)); count = s.root?.elementCount ?? 0; truncated = s.truncated
        }
        return (times.sorted()[times.count / 2], count, truncated)
    }

    // MARK: probes

    func textEdit() async {
        let phrase = "Tagen live probe 안녕하세요 2026"
        let doc = tmp.appendingPathComponent("probe.txt")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? (phrase + "\nSecond line for OCR and selection.\n").write(to: doc, atomically: true, encoding: .utf8)
        guard let app = await open(doc, with: "com.apple.TextEdit"), let win = await waitForWindow(app, titleContains: "probe") else {
            record("textedit: open document", "fail", ["reason": "TextEdit window not observable"]); return
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        let snap = snapshotTiming(win)
        record("textedit: AX snapshot", "pass", ["medianMs": snap.median, "elements": snap.count, "truncated": snap.truncated])

        // Full context capture as the assistant does it (AX + screenshot + OCR).
        let provider = MacContextProvider()
        let t0 = CFAbsoluteTimeGetCurrent()
        let ctxAX = try? await provider.capture(ContextRequest(includeScreenshot: .never))
        let axMs = ms(t0)
        let axText = ctxAX?.axRoot?.flattened().compactMap(\.value).joined(separator: " ") ?? ""
        record("textedit: context (AX only)", axText.contains("안녕하세요") ? "pass" : "fail",
               ["ms": axMs, "app": ctxAX?.app?.name ?? "nil", "window": ctxAX?.window?.title ?? "nil", "foundPhraseInAX": axText.contains(phrase),
                "limitations": ctxAX?.limitations.joined(separator: "; ") ?? ""])
        let t1 = CFAbsoluteTimeGetCurrent()
        let ctxImg = try? await provider.capture(ContextRequest(includeScreenshot: .always))
        let imgMs = ms(t1)
        if let img = ctxImg?.image {
            record("textedit: window screenshot", "pass", ["ms": imgMs, "px": "\(Int(img.geometry.imageSize.width))x\(Int(img.geometry.imageSize.height))",
                                                           "rect": "\(img.geometry.captureRect)", "bytes": img.data.count])
            if let cg = ScreenCapturer.cgImage(img) {
                let t2 = CFAbsoluteTimeGetCurrent()
                let lines = (try? await TextRecognizer().recognize(cg, geometry: img.geometry)) ?? []
                let text = lines.map(\.text).joined(separator: " ")
                record("textedit: OCR of real window", text.contains("Tagen") ? "pass" : "fail",
                       ["ms": ms(t2), "lines": lines.count, "hasKorean": text.contains("안녕"), "sample": String(text.prefix(80))])
            }
        } else {
            record("textedit: window screenshot", "blocked", ["reason": ctxImg?.limitations.joined(separator: "; ") ?? "no context"])
        }

        // Selected text via AX in a real app.
        if let area = AXInspector.snapshot(window: win).root?.flattened().first(where: { $0.role == "AXTextArea" }),
           let handle = AXInspector.snapshot(window: win).handles[area.id] {
            handle.set(kAXFocusedAttribute as String, kCFBooleanTrue)
            var r = CFRange(location: 17, length: 5)
            if let v = AXValueCreate(.cfRange, &r) { handle.set(kAXSelectedTextRangeAttribute as String, v) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let got = AXInspector.selectedText()
            record("textedit: selected text via AX", got?.text == "안녕하세요" ? "pass" : "fail",
                   ["got": got?.text ?? "nil", "editable": got?.isEditable ?? false])
            await overlayAlignment(target: area.frame, label: "textedit text area")
            if let btn = AXInspector.snapshot(window: win).root?.flattened().first(where: { $0.role == "AXButton" && ($0.frame?.width ?? 0) > 10 && ($0.frame?.width ?? 999) < 120 }),
               let f = btn.frame {
                await overlayAlignment(target: f, label: "textedit button \(btn.displayName ?? btn.subrole ?? "")")
            }
        } else {
            record("textedit: selected text via AX", "fail", ["reason": "no AXTextArea"])
        }
    }

    /// Show a highlight overlay, capture the screen including it, and locate the orange stroke in pixels.
    func overlayAlignment(target: Rect?, label: String) async {
        guard let target, !target.isEmpty else { record("overlay alignment: \(label)", "fail", ["reason": "no frame"]); return }
        let layout0 = MacDisplays.layout()
        let region0 = target.insetBy(dx: -30, dy: -30)
        // Baseline without the overlay, so the app's own orange/yellow pixels (e.g. window buttons) are ignored.
        let baseline = (try? await ScreenCapturer().captureRegion(region0, layout: layout0, includeOwnWindows: true)).flatMap(ScreenCapturer.cgImage)
        let oc = OverlayController(frameProvider: { _ in nil }, windowFrameProvider: { _ in nil })
        oc.excludeFromCapture = false
        oc.show([Annotation(kind: .highlight, target: .screen(target), label: nil, createdAt: Date(), ttl: 30, windowFrame: nil)], pid: nil)
        try? await Task.sleep(nanoseconds: 700_000_000)
        defer { oc.clear() }
        let layout = MacDisplays.layout()
        let region = target.insetBy(dx: -30, dy: -30)
        guard let img = try? await ScreenCapturer().captureRegion(region, layout: layout, includeOwnWindows: true),
              let cg = ScreenCapturer.cgImage(img) else {
            record("overlay alignment: \(label)", "blocked", ["reason": "screen capture unavailable"]); return
        }
        guard let box = orangeBoundingBox(cg, baseline: baseline) else {
            record("overlay alignment: \(label)", "fail", ["reason": "overlay stroke not found in capture"]); return
        }
        let found = img.geometry.globalRect(fromImagePixel: box)
        let expected = AnnotationGeometry.highlight(around: target).insetBy(dx: -1.5, dy: -1.5)   // stroke outer edge
        let err = [abs(found.minX - expected.minX), abs(found.minY - expected.minY), abs(found.maxX - expected.maxX), abs(found.maxY - expected.maxY)].max() ?? 99
        record("overlay alignment: \(label)", err <= 12 ? "pass" : "fail",
               ["maxEdgeErrorPt": (err * 10).rounded() / 10, "found": "\(found)", "expected": "\(expected)", "targetPt": 12])
    }

    func pixels(_ cg: CGImage, width w: Int, height h: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        return ok ? buf : nil
    }

    func orangeBoundingBox(_ cg: CGImage, baseline: CGImage?) -> Rect? {
        let w = cg.width, h = cg.height
        guard let px = pixels(cg, width: w, height: h) else { return nil }
        let base = baseline.flatMap { $0.width == w && $0.height == h ? pixels($0, width: w, height: h) : nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            if let base {
                let d = abs(r - Int(base[i])) + abs(g - Int(base[i + 1])) + abs(b - Int(base[i + 2]))
                if d < 60 { continue }   // unchanged by the overlay
            }
            if r > 200 && g > 90 && g < 190 && b < 90 {   // systemOrange stroke
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        } }
        guard maxX >= 0 else { return nil }
        // CGContext rows start at the bottom; convert to top-left image coordinates.
        return Rect(x: Double(minX), y: Double(h - 1 - maxY), width: Double(maxX - minX + 1), height: Double(maxY - minY + 1))
    }

    func safari() async {
        let page = tmp.appendingPathComponent("probe.html")
        try? """
        <!doctype html><html lang="ko"><head><meta charset="utf-8"><title>Tagen Probe Page</title></head>
        <body><h1>Tagen 웹 프로브</h1><p>Accessibility of web content.</p>
        <button id="b1">Primary Action</button> <a href="#x">Details link</a> <input placeholder="Search here"></body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        guard let app = await open(page, with: "com.apple.Safari"), let win = await waitForWindow(app, titleContains: "Tagen Probe", timeout: 30) else {
            record("safari: open local page", "fail", ["reason": "Safari window with the page not observable"]); return
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let snap = snapshotTiming(win, runs: 3)
        let root = AXInspector.snapshot(window: win).root
        let all = root?.flattened() ?? []
        let hasButton = all.contains { $0.role == "AXButton" && ($0.displayName ?? "").contains("Primary Action") }
        let hasHeading = all.contains { ($0.value ?? $0.displayName ?? "").contains("웹 프로브") }
        record("safari: web content via AX", hasButton && hasHeading ? "pass" : "fail",
               ["medianMs": snap.median, "elements": snap.count, "truncated": snap.truncated, "button": hasButton, "koreanHeading": hasHeading,
                "url": AXInspector.documentURL(window: win) ?? "nil"])
        if let b = all.first(where: { $0.role == "AXButton" && ($0.displayName ?? "").contains("Primary Action") }) {
            await overlayAlignment(target: b.frame, label: "safari web button")
        }
    }

    func finder() async {
        guard let app = await open(URL(fileURLWithPath: NSHomeDirectory()), with: "com.apple.finder"),
              let win = await waitForWindow(app, timeout: 15) else {
            record("finder: AX snapshot", "fail", ["reason": "no Finder window"]); return
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        let snap = snapshotTiming(win, runs: 3)
        record("finder: AX snapshot", snap.count > 5 ? "pass" : "fail", ["medianMs": snap.median, "elements": snap.count, "truncated": snap.truncated])
    }

    func speech() async {
        for lang in ["ko-KR", "en-US"] {
            guard let voice = AVSpeechSynthesisVoice(language: lang) else { record("tts: \(lang) voice", "fail", ["reason": "no voice"]); continue }
            let synth = AVSpeechSynthesizer()
            let u = AVSpeechUtterance(string: lang == "ko-KR" ? "안녕하세요, 태건입니다." : "Hello from Tagen.")
            u.voice = voice
            let frames = Locked(0)
            let done = Locked(false)
            synth.write(u) { buffer in
                if let pcm = buffer as? AVAudioPCMBuffer { if pcm.frameLength == 0 { done.set(true) } else { frames.withLock { $0 += Int(pcm.frameLength) } } }
            }
            let end = Date().addingTimeInterval(15)
            while !done.current && Date() < end { try? await Task.sleep(nanoseconds: 100_000_000) }
            record("tts: \(lang) synthesis", frames.current > 1000 ? "pass" : "fail", ["voice": voice.name, "audioFrames": frames.current])
        }
    }

    func run() async -> Int32 {
        let env: [String: Any] = ["macOS": ProcessInfo.processInfo.operatingSystemVersionString, "accessibility": AXIsProcessTrusted(),
                                  "screenRecording": CGPreflightScreenCaptureAccess(),
                                  "displays": MacDisplays.layout().displays.map { "\($0.frame) @\($0.scale)x" }]
        if !AXIsProcessTrusted() {
            write(["status": "blocked", "reason": "Accessibility not granted to this process", "environment": env]); return 2
        }
        await textEdit()
        await safari()
        await finder()
        await speech()
        for a in launched { a.terminate() }
        try? FileManager.default.removeItem(at: tmp)
        let fails = results.filter { ($0["status"] as? String) == "fail" }.count
        let passes = results.filter { ($0["status"] as? String) == "pass" }.count
        write(["status": "ran", "environment": env, "passed": passes, "failed": fails, "results": results])
        print("SUMMARY live probe: \(passes) pass, \(fails) fail, \(results.count - passes - fails) blocked")
        return fails == 0 ? 0 : 1
    }

    func write(_ obj: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: outputPath)) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    let code = await Probe().run()
    exit(code)
}
app.run()
#else
print("tagen-live-probe runs on macOS only.")
#endif
