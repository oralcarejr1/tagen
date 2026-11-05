#if os(macOS)
import AppKit
@preconcurrency import ApplicationServices
import TagenCore

/// Collects ScreenContext on macOS: accessibility first, screenshot + OCR only when needed.
public final class MacContextProvider: ScreenContextProvider, @unchecked Sendable {
    let capturer = ScreenCapturer()
    let ocr = TextRecognizer()
    let packager: ContextPackager
    private let lastHandles = Locked<[String: AXElement]>([:])
    private let lastWindow = Locked<AXElement?>(nil)
    /// The last non-Tagen frontmost application (the assistant panel itself may be key).
    private let lastExternalApp = Locked<NSRunningApplication?>(nil)
    private var observer: NSObjectProtocol?

    public init(packager: ContextPackager = ContextPackager()) {
        self.packager = packager
        let me = ProcessInfo.processInfo.processIdentifier
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != me { lastExternalApp.set(f) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [lastExternalApp] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != me {
                lastExternalApp.set(app)
            }
        }
    }

    deinit { if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o) } }

    public func targetApplication() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != me { return f }
        if let l = lastExternalApp.current, !l.isTerminated { return l }
        return nil
    }

    public func capture(_ request: ContextRequest) async throws -> ScreenContext {
        let layout = await MainActor.run { MacDisplays.layout() }
        var ctx = ScreenContext(layout: layout)
        guard let app = targetApplication() else {
            ctx.limitations.append("no target application")
            return ctx
        }
        ctx.app = AppInfo(name: app.localizedName ?? "App", bundleID: app.bundleIdentifier, pid: app.processIdentifier)

        var window: AXElement?
        if AXInspector.isTrusted {
            let axApp = AXInspector.application(pid: app.processIdentifier)
            window = AXInspector.focusedWindow(of: axApp)
            if let w = window {
                ctx.window = AXInspector.windowInfo(w)
                if request.includeAccessibility {
                    let snap = AXInspector.snapshot(window: w, maxDepth: request.maxAXDepth, maxElements: request.maxAXElements,
                                                    timeBudget: request.axTimeBudget)
                    ctx.axRoot = snap.root
                    ctx.focusedElementID = snap.focusedID
                    lastHandles.set(snap.handles)
                    lastWindow.set(w)
                    if snap.truncated { ctx.limitations.append("accessibility tree truncated (size/time budget)") }
                }
                if let bid = app.bundleIdentifier, Self.browsers.contains(bid) { ctx.url = AXInspector.documentURL(window: w) }
            } else {
                ctx.limitations.append("no focused window")
            }
            if request.includeSelection, let sel = AXInspector.selectedText() { ctx.selection = sel }
        } else {
            ctx.limitations.append("Accessibility permission not granted — UI elements and selected text unavailable")
        }

        // Screenshot (explicit region, or window when policy requires/permits).
        let wantImage: Bool
        switch request.includeScreenshot {
        case .never: wantImage = false
        case .always: wantImage = true
        case .ifNeeded:
            wantImage = request.region != nil || ctx.axRoot == nil || ctx.accessibilityTextVolume < packager.options.sufficientTextVolume
                || (ctx.app?.bundleID).map { ContextPackager.canvasApps.contains($0) } == true
        }
        if wantImage {
            if !ScreenCapturer.hasPermission {
                ctx.limitations.append("Screen Recording permission not granted — screenshot unavailable")
            } else {
                do {
                    if let region = request.region {
                        ctx.image = try await capturer.captureRegion(region, layout: layout)
                    } else if let w = ctx.window {
                        ctx.image = try await capturer.captureWindow(pid: app.processIdentifier, frame: w.frame, title: w.title)
                    }
                } catch {
                    ctx.limitations.append("screenshot failed: \(error)")
                }
            }
        }
        // OCR fallback when accessibility text is thin, or for explicit regions.
        if let img = ctx.image, request.region != nil || ctx.accessibilityTextVolume < packager.options.sufficientTextVolume,
           let cg = ScreenCapturer.cgImage(img) {
            if let lines = try? await ocr.recognize(cg, geometry: img.geometry) { ctx.ocr = lines }
            if request.region != nil, ctx.selection == nil {
                let text = lines(ctx.ocr)
                if !text.isEmpty { ctx.selection = SelectedText(text: text, source: .screenRegion, frame: request.region) }
            }
        }
        return ctx
    }

    func lines(_ ocr: [OCRLine]) -> String {
        ocr.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }.map(\.text).joined(separator: "\n")
    }

    public func currentFrame(ofElementWithIdentity identity: ElementIdentity) async -> Rect? {
        if let h = lastHandles.current[identity.path], h.string(kAXRoleAttribute as String) == identity.role {
            return h.frame
        }
        guard let pid = identity.pid else { return nil }
        let axApp = AXInspector.application(pid: pid)
        guard let w = AXInspector.focusedWindow(of: axApp) else { return nil }
        let snap = AXInspector.snapshot(window: w, maxDepth: 25, maxElements: 1500)
        guard let root = snap.root, let e = identity.resolve(in: root) else { return nil }
        return e.frame
    }

    /// Observe moves/resizes/destruction of the annotated elements (and their window) so overlays update
    /// immediately instead of waiting for the next poll.
    public func observeChanges(pid: pid_t, identities: [ElementIdentity], onChange: @escaping @Sendable () -> Void) -> AXChangeObserver? {
        var elements: [AXElement] = []
        let handles = lastHandles.current
        for id in identities {
            if let h = handles[id.path], h.string(kAXRoleAttribute as String) == id.role { elements.append(h) }
        }
        let window = lastWindow.current.flatMap { $0.pid == pid ? $0 : nil } ?? AXInspector.focusedWindow(of: AXInspector.application(pid: pid))
        return AXChangeObserver(pid: pid, elements: elements, window: window, onChange: onChange)
    }

    /// Current frame of the focused window of `pid` (for screen-anchored annotations).
    public func windowFrame(pid: pid_t) -> Rect? {
        AXInspector.focusedWindow(of: AXInspector.application(pid: pid))?.frame
    }

    static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
                                        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi"]
}
#endif
