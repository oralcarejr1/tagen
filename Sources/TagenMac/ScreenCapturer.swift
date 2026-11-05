#if os(macOS)
import AppKit
@preconcurrency import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import TagenCore

public enum CaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case windowNotFound
    case displayNotFound
    case encodingFailed
    case failed(String)
    public var description: String {
        switch self {
        case .permissionDenied: return "Screen Recording permission is not granted."
        case .windowNotFound: return "Could not find the window to capture."
        case .displayNotFound: return "Could not find the display to capture."
        case .encodingFailed: return "Could not encode the screenshot."
        case .failed(let m): return "Screen capture failed: \(m)"
        }
    }
}

/// ScreenCaptureKit-based capture of a window or a screen region. Images are kept in
/// memory only and downscaled for model input. Tagen's own windows are excluded.
public struct ScreenCapturer: Sendable {
    public var maxLongEdge: Int = 1568
    public var jpegQuality: Double = 0.85
    public init() {}

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Capture the on-screen window owned by `pid` whose frame best matches `frame` (global).
    public func captureWindow(pid: pid_t, frame: Rect, title: String?) async throws -> CapturedImage {
        guard Self.hasPermission else { throw CaptureError.permissionDenied }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw CaptureError.failed("\(error)") }
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.frame.width > 1 }
        guard let win = candidates.min(by: { score($0, frame, title) < score($1, frame, title) }) else { throw CaptureError.windowNotFound }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let config = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        config.width = max(1, Int(Double(win.frame.width) * scale))
        config.height = max(1, Int(Double(win.frame.height) * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image: CGImage
        do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
        catch { throw CaptureError.failed("\(error)") }
        let geometry = CaptureGeometry(captureRect: Rect(win.frame), imageSize: Size(width: Double(image.width), height: Double(image.height)))
        return try encode(image, geometry: geometry)
    }

    /// Capture a region (global points) of the display that contains it.
    public func captureRegion(_ region: Rect, layout: DisplayLayout) async throws -> CapturedImage {
        guard Self.hasPermission else { throw CaptureError.permissionDenied }
        guard let d = layout.display(for: region) else { throw CaptureError.displayNotFound }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw CaptureError.failed("\(error)") }
        guard let display = content.displays.first(where: { $0.displayID == d.id }) else { throw CaptureError.displayNotFound }
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let clipped = d.frame.intersection(region) ?? region
        let local = layout.localRect(fromGlobal: clipped, in: d)
        let config = SCStreamConfiguration()
        config.sourceRect = local.cgRect
        config.width = max(1, Int(local.width * d.scale))
        config.height = max(1, Int(local.height * d.scale))
        config.showsCursor = false
        let image: CGImage
        do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
        catch { throw CaptureError.failed("\(error)") }
        let geometry = CaptureGeometry(captureRect: clipped, imageSize: Size(width: Double(image.width), height: Double(image.height)), displayID: d.id)
        return try encode(image, geometry: geometry)
    }

    func score(_ w: SCWindow, _ frame: Rect, _ title: String?) -> Double {
        var s = Rect(w.frame).centerDistance(to: frame) + abs(Double(w.frame.width) - frame.width) + abs(Double(w.frame.height) - frame.height)
        if let t = title, w.title == t { s -= 50 }
        if w.windowLayer != 0 { s += 1000 }
        return s
    }

    /// Downscale (keeping geometry consistent) and encode as JPEG.
    public func encode(_ image: CGImage, geometry: CaptureGeometry) throws -> CapturedImage {
        var img = image
        var geo = geometry
        let long = max(image.width, image.height)
        if long > maxLongEdge {
            let s = Double(maxLongEdge) / Double(long)
            let w = max(1, Int((Double(image.width) * s).rounded())), h = max(1, Int((Double(image.height) * s).rounded()))
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let scaled = ctx.makeImage() { img = scaled; geo = geometry.resized(to: Size(width: Double(w), height: Double(h))) }
            }
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw CaptureError.encodingFailed }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.encodingFailed }
        return CapturedImage(data: data as Data, mediaType: "image/jpeg", geometry: geo)
    }

    /// Decode a CapturedImage back into a CGImage (for OCR).
    public static func cgImage(_ c: CapturedImage) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(c.data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
#endif
