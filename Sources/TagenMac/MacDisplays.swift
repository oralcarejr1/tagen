#if os(macOS)
import AppKit
import TagenCore

public enum MacDisplays {
    /// Current display arrangement in global (top-left origin) coordinates.
    @MainActor
    public static func layout() -> DisplayLayout {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return DisplayLayout(displays: []) }
        let ph = primary.frame.height
        func global(_ r: NSRect) -> Rect { Rect(x: r.minX, y: ph - r.maxY, width: r.width, height: r.height) }
        let displays = screens.enumerated().map { i, s -> DisplayInfo in
            let num = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? UInt32(i)
            return DisplayInfo(id: num, frame: global(s.frame), visibleFrame: global(s.visibleFrame), scale: Double(s.backingScaleFactor),
                               isPrimary: i == 0, name: s.localizedName)
        }
        return DisplayLayout(displays: displays)
    }

    @MainActor
    public static func screen(for displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
    }
}

extension Rect {
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public init(_ r: CGRect) { self.init(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.width), height: Double(r.height)) }
}
extension Point {
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    public init(_ p: CGPoint) { self.init(x: Double(p.x), y: Double(p.y)) }
}
#endif
