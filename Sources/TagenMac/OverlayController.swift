#if os(macOS)
import AppKit
import QuartzCore
import TagenCore

/// Transparent, click-through, non-activating overlay windows (one per display) that draw
/// guidance annotations. Annotations follow their accessibility anchors and are removed
/// when targets disappear, windows resize/close, or their TTL expires.
@MainActor
public final class OverlayController {
    private var panels: [UInt32: OverlayPanel] = [:]
    private var lifecycle = AnnotationLifecycle(labelSize: { s in OverlayController.measureLabel(s) })
    private var layout = DisplayLayout(displays: [])
    private var timer: Timer?
    private var trackedPID: pid_t?
    private let frameProvider: @Sendable (ElementIdentity) async -> Rect?
    private let windowFrameProvider: @Sendable (pid_t) -> Rect?
    private var screenObserver: NSObjectProtocol?
    private var refreshing = false
    public var onRemoved: (([(UUID, String)]) -> Void)?
    public var refreshInterval: TimeInterval = 0.12

    public init(frameProvider: @escaping @Sendable (ElementIdentity) async -> Rect?, windowFrameProvider: @escaping @Sendable (pid_t) -> Rect?) {
        self.frameProvider = frameProvider
        self.windowFrameProvider = windowFrameProvider
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels(); self?.redraw() }
        }
    }

    public var activeAnnotations: [Annotation] { lifecycle.annotations }

    public func show(_ annotations: [Annotation], pid: pid_t?) {
        trackedPID = pid
        lifecycle.set(annotations)
        rebuildPanels()
        redraw()
        startTracking()
    }

    public func clear() {
        lifecycle.clear()
        redraw()
        timer?.invalidate(); timer = nil
        for p in panels.values { p.orderOut(nil) }
    }

    func rebuildPanels() {
        layout = MacDisplays.layout()
        let ids = Set(layout.displays.map(\.id))
        for (id, p) in panels where !ids.contains(id) { p.orderOut(nil); panels[id] = nil }
        for d in layout.displays {
            guard let screen = MacDisplays.screen(for: d.id) else { continue }
            let panel = panels[d.id] ?? OverlayPanel(screen: screen)
            panel.setFrame(screen.frame, display: false)
            panel.overlayView.contentsScale = screen.backingScaleFactor
            panels[d.id] = panel
        }
    }

    func redraw() {
        let rendered = lifecycle.render(layout: layout)
        for (id, panel) in panels {
            let mine = rendered.filter { $0.displayID == id }
            panel.overlayView.render(mine)
            if mine.isEmpty { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        }
    }

    func startTracking() {
        timer?.invalidate()
        guard !lifecycle.annotations.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func tick() {
        guard !refreshing else { return }
        guard !lifecycle.annotations.isEmpty else { timer?.invalidate(); timer = nil; redraw(); return }
        refreshing = true
        let anns = lifecycle.annotations
        let pid = trackedPID
        let fp = frameProvider
        let wfp = windowFrameProvider
        Task { @MainActor in
            var frames: [UUID: Rect?] = [:]
            for a in anns {
                if case .element(let ident, _) = a.target { frames[a.id] = .some(await fp(ident)) }
            }
            let wf = pid.flatMap { wfp($0) }
            let obs = AnchorObservation(elementFrames: frames, windowFrame: wf, layout: self.layout, now: Date())
            if self.lifecycle.update(obs) {
                self.redraw()
                if !self.lifecycle.removed.isEmpty { self.onRemoved?(self.lifecycle.removed) }
            }
            self.refreshing = false
        }
    }

    nonisolated static func measureLabel(_ s: String) -> Size {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let w = (s as NSString).size(withAttributes: [.font: font]).width
        return Size(width: min(360, Double(w) + 20), height: 26)
    }
}

final class OverlayPanel: NSPanel {
    let overlayView: OverlayView

    init(screen: NSScreen) {
        overlayView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Keep overlays out of screenshots so annotations never feed back into the model.
        sharingType = .none
        contentView = overlayView
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Layer-hosting view that draws RenderedAnnotations (display-local, top-left origin).
final class OverlayView: NSView {
    var contentsScale: CGFloat = 2 { didSet { layer?.contentsScale = contentsScale } }
    private let accent = NSColor.systemOrange

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting view: assign the layer before enabling wantsLayer. Geometry stays
        // bottom-left; render() converts from top-left display-local coordinates itself.
        let root = CALayer()
        root.isGeometryFlipped = false
        layer = root
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func render(_ items: [RenderedAnnotation]) {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        let h = bounds.height
        // Convert top-left local rect to the layer's bottom-left space.
        func flip(_ r: Rect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
        func flip(_ p: Point) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }
        for it in items {
            let shape = CAShapeLayer()
            shape.contentsScale = contentsScale
            shape.lineWidth = 3
            shape.strokeColor = accent.cgColor
            shape.fillColor = NSColor.clear.cgColor
            switch it.kind {
            case .highlight:
                shape.path = CGPath(roundedRect: flip(it.shapeRect), cornerWidth: 6, cornerHeight: 6, transform: nil)
                shape.fillColor = accent.withAlphaComponent(0.15).cgColor
            case .circle:
                shape.path = CGPath(ellipseIn: flip(it.shapeRect), transform: nil)
            case .arrow:
                if let a = it.arrow {
                    let p = CGMutablePath()
                    p.move(to: flip(a.tail)); p.addLine(to: flip(a.tip))
                    shape.path = p
                    shape.lineCap = .round
                    let head = CAShapeLayer()
                    head.contentsScale = contentsScale
                    let hp = CGMutablePath()
                    hp.addLines(between: a.head.map(flip)); hp.closeSubpath()
                    head.path = hp
                    head.fillColor = accent.cgColor
                    root.addSublayer(head)
                    let box = CAShapeLayer()
                    box.path = CGPath(roundedRect: flip(it.shapeRect), cornerWidth: 5, cornerHeight: 5, transform: nil)
                    box.strokeColor = accent.withAlphaComponent(0.7).cgColor
                    box.fillColor = NSColor.clear.cgColor
                    box.lineWidth = 2
                    root.addSublayer(box)
                }
            case .label:
                shape.path = nil
            }
            shape.shadowColor = NSColor.black.cgColor
            shape.shadowOpacity = 0.35
            shape.shadowRadius = 2
            shape.shadowOffset = .zero
            root.addSublayer(shape)
            if let text = it.label, let lf = it.labelFrame {
                let bg = CALayer()
                bg.frame = flip(lf)
                bg.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
                bg.cornerRadius = 6
                bg.borderColor = accent.cgColor
                bg.borderWidth = 1
                let t = CATextLayer()
                t.contentsScale = contentsScale
                t.string = text
                t.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
                t.fontSize = 13
                t.foregroundColor = NSColor.white.cgColor
                t.alignmentMode = .center
                t.truncationMode = .end
                t.frame = CGRect(x: 6, y: 4, width: lf.width - 12, height: lf.height - 8)
                bg.addSublayer(t)
                root.addSublayer(bg)
            }
        }
        CATransaction.commit()
    }
}

/// Full-screen crosshair overlay for selecting a screen region. Returns a global rect.
@MainActor
public final class RegionSelector {
    private var panels: [RegionPanel] = []
    private var continuation: CheckedContinuation<Rect?, Never>?

    public init() {}

    public func select() async -> Rect? {
        let layout = MacDisplays.layout()
        return await withCheckedContinuation { c in
            continuation = c
            for s in NSScreen.screens {
                let p = RegionPanel(screen: s, layout: layout) { [weak self] r in self?.finish(r) }
                panels.append(p)
                p.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            NSCursor.crosshair.push()
        }
    }

    private func finish(_ r: Rect?) {
        NSCursor.pop()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        continuation?.resume(returning: r)
        continuation = nil
    }
}

final class RegionPanel: NSPanel {
    init(screen: NSScreen, layout: DisplayLayout, done: @escaping @MainActor (Rect?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.12)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sharingType = .none
        contentView = RegionView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen, layout: layout, done: done)
    }
    override var canBecomeKey: Bool { true }
}

final class RegionView: NSView {
    let done: @MainActor (Rect?) -> Void
    let screenFrame: NSRect
    let layout: DisplayLayout
    var start: NSPoint?
    var current: NSPoint?
    init(frame: NSRect, screen: NSScreen, layout: DisplayLayout, done: @escaping @MainActor (Rect?) -> Void) {
        self.done = done; self.screenFrame = screen.frame; self.layout = layout
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { done(nil) } }
    override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil); current = start; needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { current = convert(e.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        guard let s = start, let c = current else { done(nil); return }
        let r = NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
        guard r.width > 4, r.height > 4 else { done(nil); return }
        // View coords (bottom-left, relative to this screen) → cocoa global → global top-left.
        let cocoa = Rect(x: screenFrame.minX + r.minX, y: screenFrame.minY + r.minY, width: r.width, height: r.height)
        done(layout.globalRect(fromCocoa: cocoa))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let s = start, let c = current else { return }
        let r = NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
        NSColor.clear.setFill(); r.fill(using: .copy)
        NSColor.systemOrange.setStroke()
        let p = NSBezierPath(rect: r); p.lineWidth = 2; p.stroke()
    }
}
#endif
