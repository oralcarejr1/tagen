#if os(macOS)
import XCTest
import AppKit
import CoreText
@testable import TagenMac
@testable import TagenCore

/// macOS-only tests that need no TCC permission (run for real on CI runners).
final class MacPlatformTests: XCTestCase {
    /// Render text into a CGImage (white background, black text).
    func render(_ lines: [String], size: CGSize = CGSize(width: 900, height: 300)) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
        for (i, l) in lines.enumerated() {
            let attr = NSAttributedString(string: l, attributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 30, y: size.height - 80 - CGFloat(i) * 110)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()!
    }

    func testVisionOCRKoreanAndEnglishWithGlobalCoordinates() async throws {
        let img = render(["Hello Tagen 2026", "안녕하세요 테스트"])
        let geo = CaptureGeometry(captureRect: Rect(x: 1000, y: 500, width: 450, height: 150), imageSize: Size(width: 900, height: 300))
        let lines = try await TextRecognizer().recognize(img, geometry: geo)
        let text = lines.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("Hello"), text)
        XCTAssertTrue(text.contains("안녕"), "Korean OCR: \(text)")
        // First line is in the top part of the captured rect (global, y down).
        let hello = try XCTUnwrap(lines.first { $0.text.contains("Hello") })
        XCTAssertTrue(geo.captureRect.contains(hello.frame.center))
        XCTAssertLessThan(hello.frame.midY, geo.captureRect.midY)
    }

    func testScreenshotEncodingDownscalesAndKeepsGeometry() throws {
        let img = render(["x"], size: CGSize(width: 3000, height: 1500))
        var cap = ScreenCapturer(); cap.maxLongEdge = 1568
        let geo = CaptureGeometry(captureRect: Rect(x: 0, y: 0, width: 1500, height: 750), imageSize: Size(width: 3000, height: 1500))
        let out = try cap.encode(img, geometry: geo)
        XCTAssertEqual(out.mediaType, "image/jpeg")
        XCTAssertEqual(out.geometry.imageSize.width, 1568)
        XCTAssertEqual(out.geometry.captureRect, geo.captureRect)
        let back = try XCTUnwrap(ScreenCapturer.cgImage(out))
        XCTAssertEqual(back.width, 1568)
        // Model pixel (784, 392) maps to the center of the captured rect.
        let p = out.geometry.globalPoint(fromImagePixel: Point(x: 784, y: 392))
        XCTAssertEqual(p.x, 750, accuracy: 1); XCTAssertEqual(p.y, 375, accuracy: 1)
    }

    @MainActor
    func testDisplayLayoutMatchesNSScreen() throws {
        let layout = MacDisplays.layout()
        try XCTSkipIf(layout.displays.isEmpty, "no window server session")
        for (i, s) in NSScreen.screens.enumerated() {
            let d = layout.displays[i]
            XCTAssertEqual(d.scale, Double(s.backingScaleFactor))
            // global → cocoa round trip equals NSScreen.frame.
            let cocoa = layout.cocoaRect(fromGlobal: d.frame)
            XCTAssertEqual(cocoa, Rect(s.frame))
        }
        XCTAssertTrue(layout.displays[0].isPrimary)
        XCTAssertEqual(layout.displays[0].frame.origin, .zero)
    }

    func testKeychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "dev.tagen.tests.\(UUID().uuidString)")
        do {
            try store.set("k", value: "secret-1")
        } catch {
            throw XCTSkip("Keychain not available in this session: \(error)")
        }
        XCTAssertEqual(try store.get("k"), "secret-1")
        try store.set("k", value: "secret-2")
        XCTAssertEqual(try store.get("k"), "secret-2")
        try store.delete("k")
        XCTAssertNil(try store.get("k"))
    }

    @MainActor
    func testOverlayRendersAnnotationLayersOnEachDisplay() throws {
        let layout = MacDisplays.layout()
        try XCTSkipIf(layout.displays.isEmpty, "no window server session")
        let oc = OverlayController(frameProvider: { _ in nil }, windowFrameProvider: { _ in nil })
        let d = layout.displays[0]
        let t = Rect(x: d.frame.midX - 40, y: d.frame.midY - 10, width: 80, height: 20)
        oc.show([Annotation(kind: .arrow, target: .screen(t), label: "Here", createdAt: Date(), ttl: 5, windowFrame: nil),
                 Annotation(kind: .circle, target: .screen(t.offsetBy(dx: 0, dy: 60)), label: nil, createdAt: Date(), ttl: 5, windowFrame: nil)], pid: nil)
        XCTAssertEqual(oc.activeAnnotations.count, 2)
        oc.clear()
        XCTAssertTrue(oc.activeAnnotations.isEmpty)
    }

    func testPermissionStatusQueriesDoNotPrompt() async {
        let p = MacPermissionChecker(appSwitches: { $0 == .agentExecution })
        let ax = await p.status(.accessibility)
        XCTAssertTrue([.granted, .denied].contains(ax))
        let agent = await p.status(.agentExecution)
        XCTAssertEqual(agent, .granted)
        let files = await p.status(.fileAccess)
        XCTAssertEqual(files, .denied)
    }

    func testGUIDriverRefusesWithoutAccessibility() async throws {
        try XCTSkipIf(AXInspector.isTrusted, "process is trusted; refusal path not applicable")
        do { _ = try await MacGUIDriver().observe(scopeBundleID: nil); XCTFail("should require Accessibility") }
        catch { XCTAssertEqual(error as? DriverError, .permissionDenied("Accessibility")) }
        do { try await MacGUIDriver().perform(.keyCombo(KeyCombo(key: "a"))); XCTFail() }
        catch { XCTAssertEqual(error as? DriverError, .permissionDenied("Accessibility")) }
    }

    func testSpeechRecognizerRefusesWithoutAuthorization() async throws {
        let r = MacSpeechRecognizer()
        do {
            _ = try await r.start(language: .korean, preferOnDevice: true)
            await r.cancel()
            throw XCTSkip("speech + microphone already authorized on this machine")
        } catch let e as SpeechRecognitionError {
            XCTAssertEqual(e, .notAuthorized)
        }
    }
}
#endif
