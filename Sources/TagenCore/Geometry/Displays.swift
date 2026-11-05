import Foundation

/// A physical display. `frame` is in *global* coordinates: points, origin at the top-left
/// corner of the primary display, y growing downward (the convention used by CoreGraphics,
/// the Accessibility API and ScreenCaptureKit).
public struct DisplayInfo: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: UInt32
    public var frame: Rect
    /// Usable area excluding menu bar and Dock, also global top-left coordinates.
    public var visibleFrame: Rect
    /// Backing scale factor (1 = non-Retina, 2 = Retina, may be fractional on scaled modes).
    public var scale: Double
    public var isPrimary: Bool
    public var name: String

    public init(id: UInt32, frame: Rect, visibleFrame: Rect? = nil, scale: Double, isPrimary: Bool, name: String = "") {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame ?? frame
        self.scale = scale; self.isPrimary = isPrimary; self.name = name
    }

    public var pixelSize: Size { Size(width: frame.width * scale, height: frame.height * scale) }
}

/// The arrangement of all displays. Provides conversions between coordinate spaces:
///
/// * global  – top-left origin of the primary display, y down, points (CG / AX / SCK).
/// * cocoa   – bottom-left origin of the primary display, y up, points (NSWindow / NSScreen).
/// * local   – relative to a given display's top-left, y down, points (overlay layer space
///             when the overlay layer is flipped).
/// * pixel   – local × display scale (screenshots of a whole display).
public struct DisplayLayout: Sendable, Codable, Equatable {
    public var displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) { self.displays = displays }

    public var primary: DisplayInfo? { displays.first(where: \.isPrimary) ?? displays.first }

    /// Height of the primary display: the pivot for flipping between global and cocoa.
    public var primaryHeight: Double { primary?.frame.height ?? 0 }

    /// Bounding box of the whole desktop in global coordinates.
    public var desktopBounds: Rect {
        displays.dropFirst().reduce(displays.first?.frame ?? .zero) { $0.union($1.frame) }
    }

    // MARK: global <-> cocoa

    public func cocoaRect(fromGlobal r: Rect) -> Rect {
        Rect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public func globalRect(fromCocoa r: Rect) -> Rect {
        Rect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public func cocoaPoint(fromGlobal p: Point) -> Point { Point(x: p.x, y: primaryHeight - p.y) }
    public func globalPoint(fromCocoa p: Point) -> Point { Point(x: p.x, y: primaryHeight - p.y) }

    // MARK: display lookup

    public func display(containing p: Point) -> DisplayInfo? {
        displays.first(where: { $0.frame.contains(p) })
    }

    /// Display with the largest intersection with `r`; falls back to nearest center.
    public func display(for r: Rect) -> DisplayInfo? {
        var best: (DisplayInfo, Double)?
        for d in displays {
            if let i = d.frame.intersection(r), best == nil || i.area > best!.1 { best = (d, i.area) }
        }
        if let b = best { return b.0 }
        return displays.min(by: { $0.frame.center.distance(to: r.center) < $1.frame.center.distance(to: r.center) })
    }

    public func display(id: UInt32) -> DisplayInfo? { displays.first(where: { $0.id == id }) }

    // MARK: global <-> local / pixel

    public func localRect(fromGlobal r: Rect, in d: DisplayInfo) -> Rect {
        r.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
    }

    public func globalRect(fromLocal r: Rect, in d: DisplayInfo) -> Rect {
        r.offsetBy(dx: d.frame.minX, dy: d.frame.minY)
    }

    public func pixelRect(fromGlobal r: Rect, in d: DisplayInfo) -> Rect {
        localRect(fromGlobal: r, in: d).scaled(by: d.scale)
    }

    public func globalRect(fromPixel r: Rect, in d: DisplayInfo) -> Rect {
        globalRect(fromLocal: r.scaled(by: 1 / d.scale), in: d)
    }

    /// Snap a global rect to the pixel grid of the display it lives on (avoids blurry
    /// 1-px strokes on fractional-scale displays).
    public func pixelAligned(_ r: Rect) -> Rect {
        guard let d = display(for: r) else { return r }
        let p = pixelRect(fromGlobal: r, in: d)
        let a = Rect(x: p.minX.rounded(.down), y: p.minY.rounded(.down),
                     width: (p.maxX.rounded(.up) - p.minX.rounded(.down)),
                     height: (p.maxY.rounded(.up) - p.minY.rounded(.down)))
        return globalRect(fromPixel: a, in: d)
    }
}

/// Describes how a captured image maps back to the desktop. `captureRect` is the captured
/// region in global points; the image has `imageSize` pixels (usually captureRect × scale).
public struct CaptureGeometry: Sendable, Codable, Equatable {
    public var captureRect: Rect
    public var imageSize: Size
    public var displayID: UInt32?

    public init(captureRect: Rect, imageSize: Size, displayID: UInt32? = nil) {
        self.captureRect = captureRect; self.imageSize = imageSize; self.displayID = displayID
    }

    public var scaleX: Double { captureRect.width > 0 ? imageSize.width / captureRect.width : 1 }
    public var scaleY: Double { captureRect.height > 0 ? imageSize.height / captureRect.height : 1 }

    public func globalPoint(fromImagePixel p: Point) -> Point {
        Point(x: captureRect.minX + p.x / scaleX, y: captureRect.minY + p.y / scaleY)
    }

    public func globalRect(fromImagePixel r: Rect) -> Rect {
        let o = globalPoint(fromImagePixel: r.origin)
        return Rect(x: o.x, y: o.y, width: r.width / scaleX, height: r.height / scaleY)
    }

    public func imageRect(fromGlobal r: Rect) -> Rect {
        Rect(x: (r.minX - captureRect.minX) * scaleX, y: (r.minY - captureRect.minY) * scaleY,
             width: r.width * scaleX, height: r.height * scaleY)
    }

    /// Converts a point given in *normalized* image coordinates (0...1), as some vision
    /// models (and Apple Vision, after flipping) report them.
    public func globalPoint(fromNormalized p: Point) -> Point {
        Point(x: captureRect.minX + p.x * captureRect.width, y: captureRect.minY + p.y * captureRect.height)
    }

    /// Apple Vision returns normalized rects with a *bottom-left* origin.
    public func globalRect(fromVisionNormalized r: Rect) -> Rect {
        let flippedY = 1 - r.maxY
        return Rect(x: captureRect.minX + r.minX * captureRect.width,
                    y: captureRect.minY + flippedY * captureRect.height,
                    width: r.width * captureRect.width, height: r.height * captureRect.height)
    }

    /// When a screenshot is downscaled before being sent to a model, model-reported pixel
    /// coordinates refer to the downscaled image. Returns geometry for the resized image.
    public func resized(to newSize: Size) -> CaptureGeometry {
        CaptureGeometry(captureRect: captureRect, imageSize: newSize, displayID: displayID)
    }
}
