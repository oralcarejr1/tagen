import Foundation

public enum AnnotationKind: String, Sendable, Codable, CaseIterable { case arrow, circle, highlight, label }

public enum AnnotationTarget: Sendable, Equatable {
    /// Anchored to an accessibility element; its frame is re-read to follow movement.
    case element(ElementIdentity, frame: Rect)
    /// Fixed region (from screenshot coordinates), anchored to the window it was captured in.
    case screen(Rect)
}

public struct Annotation: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: AnnotationKind
    public var target: AnnotationTarget
    public var label: String?
    public var createdAt: Date
    public var ttl: Double
    /// Frame of the owning window when the annotation was created (for screen targets).
    public var windowFrame: Rect?

    public init(id: UUID = UUID(), kind: AnnotationKind, target: AnnotationTarget, label: String?, createdAt: Date, ttl: Double, windowFrame: Rect?) {
        self.id = id; self.kind = kind; self.target = target; self.label = label
        self.createdAt = createdAt; self.ttl = ttl; self.windowFrame = windowFrame
    }

    public var targetFrame: Rect {
        switch target {
        case .element(_, let f): return f
        case .screen(let r): return r
        }
    }
}

/// Fully-resolved drawing instructions for one display, in display-local coordinates
/// (top-left origin, points). The overlay layer is flipped so these map 1:1.
public struct RenderedAnnotation: Sendable, Equatable {
    public var id: UUID
    public var displayID: UInt32
    public var kind: AnnotationKind
    public var targetRect: Rect
    public var shapeRect: Rect          // highlight / circle bounding box
    public var arrow: AnnotationGeometry.ArrowPath?
    public var label: String?
    public var labelFrame: Rect?
}

/// Observations the lifecycle manager needs on each refresh tick.
public struct AnchorObservation: Sendable {
    /// Current frame of each element-anchored annotation (nil = element no longer found).
    public var elementFrames: [UUID: Rect?]
    /// Current frame of the window annotations were created in (nil = window gone).
    public var windowFrame: Rect?
    public var layout: DisplayLayout
    public var now: Date
    public init(elementFrames: [UUID: Rect?], windowFrame: Rect?, layout: DisplayLayout, now: Date) {
        self.elementFrames = elementFrames; self.windowFrame = windowFrame; self.layout = layout; self.now = now
    }
}

/// Manages annotation lifecycle: anchoring, following moved targets, removing stale or
/// expired annotations, and producing per-display render instructions.
public struct AnnotationLifecycle: Sendable {
    public private(set) var annotations: [Annotation] = []
    public private(set) var removed: [(UUID, String)] = []
    public var labelSize: @Sendable (String) -> Size

    public init(labelSize: @escaping @Sendable (String) -> Size = { s in Size(width: min(320, Double(s.count) * 7.5 + 20), height: 26) }) {
        self.labelSize = labelSize
    }

    public mutating func set(_ anns: [Annotation]) { annotations = anns; removed = [] }
    public mutating func clear(reason: String = "cleared") {
        removed = annotations.map { ($0.id, reason) }; annotations = []
    }

    /// Apply a new observation. Returns true if anything changed.
    @discardableResult
    public mutating func update(_ obs: AnchorObservation) -> Bool {
        var changed = false
        removed = []
        var next: [Annotation] = []
        for var a in annotations {
            if obs.now.timeIntervalSince(a.createdAt) > a.ttl { removed.append((a.id, "expired")); changed = true; continue }
            switch a.target {
            case .element(let ident, let old):
                guard let entry = obs.elementFrames[a.id] else { next.append(a); continue }  // not observed this tick
                guard let newFrame = entry, !newFrame.isEmpty else { removed.append((a.id, "target disappeared")); changed = true; continue }
                if obs.layout.display(for: newFrame) == nil || obs.layout.desktopBounds.intersection(newFrame) == nil {
                    removed.append((a.id, "target off screen")); changed = true; continue
                }
                if AnnotationGeometry.hasMoved(from: old, to: newFrame) {
                    a.target = .element(ident, frame: newFrame); changed = true
                }
            case .screen(let r):
                guard let created = a.windowFrame else { break }
                guard let now = obs.windowFrame else { removed.append((a.id, "window closed")); changed = true; continue }
                let resized = abs(now.width - created.width) > 1 || abs(now.height - created.height) > 1
                if resized { removed.append((a.id, "window resized; screenshot coordinates stale")); changed = true; continue }
                let dx = now.minX - created.minX, dy = now.minY - created.minY
                if abs(dx) > 0.5 || abs(dy) > 0.5 {
                    a.target = .screen(r.offsetBy(dx: dx, dy: dy)); a.windowFrame = now; changed = true
                }
            }
            next.append(a)
        }
        annotations = next
        return changed
    }

    /// Render instructions per display.
    public func render(layout: DisplayLayout) -> [RenderedAnnotation] {
        annotations.compactMap { a in
            let t = a.targetFrame
            guard let d = layout.display(for: t) else { return nil }
            let local = layout.localRect(fromGlobal: t, in: d)
            let bounds = layout.localRect(fromGlobal: d.visibleFrame, in: d)
            var shape = local
            var arrow: AnnotationGeometry.ArrowPath?
            switch a.kind {
            case .highlight: shape = AnnotationGeometry.highlight(around: local)
            case .circle: shape = AnnotationGeometry.circle(around: local, within: Rect(origin: .zero, size: d.frame.size))
            case .arrow: arrow = AnnotationGeometry.arrow(to: local, within: bounds); shape = AnnotationGeometry.highlight(around: local, padding: 2)
            case .label: shape = local
            }
            var labelFrame: Rect?
            if let l = a.label, !l.isEmpty {
                let avoid = arrow.map { Rect(x: min($0.tail.x, $0.tip.x), y: min($0.tail.y, $0.tip.y), width: abs($0.tail.x - $0.tip.x), height: abs($0.tail.y - $0.tip.y)) }
                let anchor = arrow.map { Rect(x: $0.tail.x - 1, y: $0.tail.y - 1, width: 2, height: 2) } ?? shape
                var lf = AnnotationGeometry.labelFrame(size: labelSize(l), near: anchor, within: bounds)
                if avoid == nil, lf.intersects(shape) { lf = AnnotationGeometry.labelFrame(size: labelSize(l), near: shape, within: bounds) }
                labelFrame = lf
            }
            return RenderedAnnotation(id: a.id, displayID: d.id, kind: a.kind, targetRect: local, shapeRect: shape, arrow: arrow,
                                      label: a.label, labelFrame: labelFrame)
        }
    }
}
