import Foundation

/// Pure geometry for guidance annotations. All inputs/outputs in global coordinates.
public enum AnnotationGeometry {

    public struct ArrowPath: Sendable, Equatable {
        public var tail: Point
        public var tip: Point
        /// Three points of the arrow head triangle (tip, left, right).
        public var head: [Point]
    }

    /// Computes an arrow pointing at `target`, starting from a position inside `bounds`
    /// (the visible frame of the display hosting the target). The tail is placed on the side
    /// with most free space, the tip stops `gap` points short of the target edge.
    public static func arrow(
        to target: Rect, within bounds: Rect, length: Double = 110, gap: Double = 6, headLength: Double = 16,
        headWidth: Double = 14, preferredFrom: Point? = nil
    ) -> ArrowPath {
        let c = target.center
        var dir: Point
        if let from = preferredFrom, from.distance(to: c) > 1 {
            dir = (from - c).normalized
        } else {
            // Pick the diagonal direction toward the bounds' center (most room), biased
            // toward lower-left/upper-left so the arrow does not cover text that follows.
            let toCenter = (bounds.center - c)
            dir = toCenter.length < 1 ? Point(x: -0.7071, y: 0.7071) : toCenter.normalized
            if abs(dir.x) < 0.2 { dir.x = dir.x < 0 ? -0.5 : 0.5; dir = dir.normalized }
            if abs(dir.y) < 0.2 { dir.y = dir.y < 0 ? -0.5 : 0.5; dir = dir.normalized }
        }
        let edge = rayRectExit(from: c, dir: dir, rect: target)
        var tip = edge + dir * gap
        var tail = tip + dir * length
        // Keep the tail on screen; if clamped, recompute the direction so the arrow still
        // points at the target.
        let inner = bounds.insetBy(dx: 4, dy: 4)
        if !inner.contains(tail) {
            tail = inner.clamp(tail)
            let d2 = (tail - c).normalized
            if d2.length > 0 {
                let e2 = rayRectExit(from: c, dir: d2, rect: target)
                tip = e2 + d2 * gap
            }
        }
        let back = (tail - tip).normalized
        let base = tip + back * headLength
        let perp = Point(x: -back.y, y: back.x)
        let left = base + perp * (headWidth / 2)
        let right = base - perp * (headWidth / 2)
        return ArrowPath(tail: tail, tip: tip, head: [tip, left, right])
    }

    /// Point where a ray from inside `rect` exits it.
    public static func rayRectExit(from p: Point, dir: Point, rect: Rect) -> Point {
        var tMin = Double.infinity
        if dir.x > 0 { tMin = min(tMin, (rect.maxX - p.x) / dir.x) }
        if dir.x < 0 { tMin = min(tMin, (rect.minX - p.x) / dir.x) }
        if dir.y > 0 { tMin = min(tMin, (rect.maxY - p.y) / dir.y) }
        if dir.y < 0 { tMin = min(tMin, (rect.minY - p.y) / dir.y) }
        if !tMin.isFinite || tMin < 0 { return p }
        return p + dir * tMin
    }

    /// Ellipse bounding box that encloses `target` with padding (an ellipse inscribed in
    /// a box √2 larger than the rect passes through the rect's corners).
    public static func circle(around target: Rect, padding: Double = 6, within bounds: Rect? = nil) -> Rect {
        let w = target.width * 2.0.squareRoot() + padding * 2
        let h = target.height * 2.0.squareRoot() + padding * 2
        // Keep circles reasonably round for small, wide targets.
        let r = Rect(x: target.midX - w / 2, y: target.midY - h / 2, width: w, height: h)
        guard let b = bounds else { return r }
        return b.intersection(r) ?? r
    }

    public static func highlight(around target: Rect, padding: Double = 4) -> Rect {
        target.insetBy(dx: -padding, dy: -padding)
    }

    /// Places a label of `size` near `target` without overlapping it, preferring below,
    /// then above, right, left; always kept inside `bounds`.
    public static func labelFrame(size: Size, near target: Rect, within bounds: Rect, spacing: Double = 8) -> Rect {
        let candidates = [
            Rect(x: target.midX - size.width / 2, y: target.maxY + spacing, width: size.width, height: size.height),
            Rect(x: target.midX - size.width / 2, y: target.minY - spacing - size.height, width: size.width, height: size.height),
            Rect(x: target.maxX + spacing, y: target.midY - size.height / 2, width: size.width, height: size.height),
            Rect(x: target.minX - spacing - size.width, y: target.midY - size.height / 2, width: size.width, height: size.height),
        ]
        for c in candidates where bounds.contains(c) && !c.intersects(target) { return c }
        // Fall back: clamp the first candidate into bounds.
        return bounds.clampRect(candidates[0])
    }

    /// Whether a tracked element moved enough that an annotation must be repositioned.
    public static func hasMoved(from old: Rect, to new: Rect, tolerance: Double = 1) -> Bool {
        abs(old.minX - new.minX) > tolerance || abs(old.minY - new.minY) > tolerance
            || abs(old.width - new.width) > tolerance || abs(old.height - new.height) > tolerance
    }
}
