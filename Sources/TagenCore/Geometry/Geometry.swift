import Foundation

/// Platform-independent geometry primitives (Double precision, points unless noted).
public struct Point: Sendable, Codable, Equatable, Hashable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = Point(x: 0, y: 0)
    public func distance(to p: Point) -> Double { hypot(p.x - x, p.y - y) }
    public static func + (a: Point, b: Point) -> Point { Point(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Point, b: Point) -> Point { Point(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: Point, s: Double) -> Point { Point(x: a.x * s, y: a.y * s) }
    public var length: Double { hypot(x, y) }
    public var normalized: Point { let l = length; return l == 0 ? .zero : Point(x: x / l, y: y / l) }
    public var description: String { "(\(fmt(x)), \(fmt(y)))" }
}

public struct Size: Sendable, Codable, Equatable, Hashable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public static let zero = Size(width: 0, height: 0)
}

public struct Rect: Sendable, Codable, Equatable, Hashable, CustomStringConvertible {
    public var origin: Point
    public var size: Size

    public init(origin: Point, size: Size) { self.origin = origin; self.size = size }
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = Point(x: x, y: y); self.size = Size(width: width, height: height)
    }
    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var x: Double { origin.x }
    public var y: Double { origin.y }
    public var width: Double { size.width }
    public var height: Double { size.height }
    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }
    public var center: Point { Point(x: midX, y: midY) }
    public var area: Double { max(0, width) * max(0, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(_ p: Point) -> Bool { p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY }
    public func contains(_ r: Rect) -> Bool { r.minX >= minX && r.maxX <= maxX && r.minY >= minY && r.maxY <= maxY }

    public func intersection(_ r: Rect) -> Rect? {
        let x0 = max(minX, r.minX), y0 = max(minY, r.minY)
        let x1 = min(maxX, r.maxX), y1 = min(maxY, r.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    public func intersects(_ r: Rect) -> Bool { intersection(r) != nil }

    public func union(_ r: Rect) -> Rect {
        let x0 = min(minX, r.minX), y0 = min(minY, r.minY)
        return Rect(x: x0, y: y0, width: max(maxX, r.maxX) - x0, height: max(maxY, r.maxY) - y0)
    }

    public func insetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }
    public func offsetBy(dx: Double, dy: Double) -> Rect { Rect(x: x + dx, y: y + dy, width: width, height: height) }
    public func scaled(by s: Double) -> Rect { Rect(x: x * s, y: y * s, width: width * s, height: height * s) }

    /// Clamp a point into this rect.
    public func clamp(_ p: Point) -> Point {
        Point(x: min(max(p.x, minX), maxX), y: min(max(p.y, minY), maxY))
    }

    /// Move `r` (keeping its size where possible) so it lies inside this rect.
    public func clampRect(_ r: Rect) -> Rect {
        let w = min(r.width, width), h = min(r.height, height)
        let nx = min(max(r.minX, minX), maxX - w)
        let ny = min(max(r.minY, minY), maxY - h)
        return Rect(x: nx, y: ny, width: w, height: h)
    }

    /// Distance between centers.
    public func centerDistance(to r: Rect) -> Double { center.distance(to: r.center) }

    public var description: String { "{\(fmt(x)), \(fmt(y)), \(fmt(width))×\(fmt(height))}" }
}

@inline(__always) func fmt(_ v: Double) -> String {
    v.rounded() == v ? String(Int(v)) : String(format: "%.2f", v)
}
