import XCTest
@testable import TagenCore

final class GeometryTests: XCTestCase {
    func testRectBasics() {
        let r = Rect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(r.maxX, 110); XCTAssertEqual(r.maxY, 70); XCTAssertEqual(r.center, Point(x: 60, y: 45))
        XCTAssertTrue(r.contains(Point(x: 10, y: 20))); XCTAssertFalse(r.contains(Point(x: 110, y: 70)))
        XCTAssertEqual(r.intersection(Rect(x: 100, y: 60, width: 50, height: 50)), Rect(x: 100, y: 60, width: 10, height: 10))
        XCTAssertNil(r.intersection(Rect(x: 200, y: 200, width: 5, height: 5)))
        XCTAssertEqual(r.union(Rect(x: 0, y: 0, width: 5, height: 5)), Rect(x: 0, y: 0, width: 110, height: 70))
        XCTAssertEqual(Rect(x: 0, y: 0, width: 100, height: 100).clampRect(Rect(x: 90, y: -10, width: 30, height: 30)), Rect(x: 70, y: 0, width: 30, height: 30))
    }

    func testGlobalCocoaRoundTripMultiMonitor() {
        let l = Fixtures.layout
        // A rect on the primary display near the top.
        let g = Rect(x: 100, y: 50, width: 200, height: 30)
        let c = l.cocoaRect(fromGlobal: g)
        XCTAssertEqual(c, Rect(x: 100, y: 900 - 80, width: 200, height: 30))
        XCTAssertEqual(l.globalRect(fromCocoa: c), g)
        // Secondary display above-left: negative global coordinates map to cocoa y above primary.
        let g2 = Rect(x: -1000, y: -500, width: 100, height: 100)
        let c2 = l.cocoaRect(fromGlobal: g2)
        XCTAssertEqual(c2.minY, 900 + 400)
        XCTAssertEqual(l.globalRect(fromCocoa: c2), g2)
    }

    func testDisplayLookupAndLocalPixelConversion() {
        let l = Fixtures.layout
        XCTAssertEqual(l.display(containing: Point(x: 5, y: 5))?.id, 1)
        XCTAssertEqual(l.display(containing: Point(x: -5, y: -5))?.id, 2)
        XCTAssertNil(l.display(containing: Point(x: 5000, y: 5000)))
        // Rect straddling both displays goes to the one with the larger intersection.
        XCTAssertEqual(l.display(for: Rect(x: -10, y: -10, width: 100, height: 100))?.id, 1)
        let r = Rect(x: 100, y: 200, width: 50, height: 20)
        let px = l.pixelRect(fromGlobal: r, in: Fixtures.primary)
        XCTAssertEqual(px, Rect(x: 200, y: 400, width: 100, height: 40))     // Retina 2x
        XCTAssertEqual(l.globalRect(fromPixel: px, in: Fixtures.primary), r)
        let r2 = Rect(x: -1900, y: -1000, width: 10, height: 10)
        XCTAssertEqual(l.localRect(fromGlobal: r2, in: Fixtures.secondary), Rect(x: 20, y: 80, width: 10, height: 10))
        XCTAssertEqual(l.pixelRect(fromGlobal: r2, in: Fixtures.secondary), Rect(x: 20, y: 80, width: 10, height: 10)) // 1x
        XCTAssertEqual(l.desktopBounds, Rect(x: -1920, y: -1080, width: 3360, height: 1980))
    }

    func testFractionalScalePixelAlignment() {
        let d = DisplayInfo(id: 3, frame: Rect(x: 0, y: 0, width: 1512, height: 982), scale: 1.5, isPrimary: true)
        let l = DisplayLayout(displays: [d])
        let a = l.pixelAligned(Rect(x: 10.2, y: 10.2, width: 20.1, height: 20.1))
        let px = l.pixelRect(fromGlobal: a, in: d)
        for v in [px.minX, px.minY, px.maxX, px.maxY] { XCTAssertEqual(v, v.rounded(), accuracy: 1e-9) }
        XCTAssertTrue(a.contains(Rect(x: 10.2, y: 10.2, width: 20.0, height: 20.0)))
    }

    func testCaptureGeometryMappingsIncludingDownscale() {
        // Window at (200,100) 800×600 points captured at 2x → 1600×1200 px.
        let g = CaptureGeometry(captureRect: Rect(x: 200, y: 100, width: 800, height: 600), imageSize: Size(width: 1600, height: 1200))
        XCTAssertEqual(g.globalPoint(fromImagePixel: Point(x: 400, y: 200)), Point(x: 400, y: 200))
        XCTAssertEqual(g.globalRect(fromImagePixel: Rect(x: 0, y: 0, width: 200, height: 100)), Rect(x: 200, y: 100, width: 100, height: 50))
        XCTAssertEqual(g.imageRect(fromGlobal: Rect(x: 300, y: 150, width: 10, height: 10)), Rect(x: 200, y: 100, width: 20, height: 20))
        // Downscaled to 800×600 for the model: model coordinates are 1:1 with points.
        let small = g.resized(to: Size(width: 800, height: 600))
        XCTAssertEqual(small.globalRect(fromImagePixel: Rect(x: 100, y: 50, width: 10, height: 10)), Rect(x: 300, y: 150, width: 10, height: 10))
        // Apple Vision normalized rects have a bottom-left origin.
        let v = g.globalRect(fromVisionNormalized: Rect(x: 0, y: 0.9, width: 0.5, height: 0.1))
        XCTAssertEqual(v, Rect(x: 200, y: 100, width: 400, height: 60))
    }
}

final class AnnotationGeometryTests: XCTestCase {
    func testArrowPointsAtTargetAndStaysOnScreen() {
        let bounds = Rect(x: 0, y: 0, width: 1440, height: 900)
        for target in [Rect(x: 10, y: 10, width: 40, height: 20), Rect(x: 1380, y: 860, width: 50, height: 30), Rect(x: 700, y: 400, width: 80, height: 30)] {
            let a = AnnotationGeometry.arrow(to: target, within: bounds)
            XCTAssertTrue(bounds.contains(a.tail), "tail \(a.tail) off-screen for \(target)")
            // Tip lies within gap+1pt of the target's boundary and outside it.
            let expanded = target.insetBy(dx: -8, dy: -8)
            XCTAssertTrue(expanded.contains(a.tip), "tip \(a.tip) too far from \(target)")
            XCTAssertFalse(target.contains(a.tip))
            // Arrow direction points toward the target center.
            let toTarget = (target.center - a.tip).normalized
            let shaft = (a.tip - a.tail).normalized
            XCTAssertGreaterThan(toTarget.x * shaft.x + toTarget.y * shaft.y, 0.9)
            XCTAssertEqual(a.head.count, 3)
        }
    }

    func testCircleEnclosesCorners() {
        let t = Rect(x: 100, y: 100, width: 120, height: 30)
        let c = AnnotationGeometry.circle(around: t, padding: 4)
        let cx = c.midX, cy = c.midY, rx = c.width / 2, ry = c.height / 2
        for p in [t.origin, Point(x: t.maxX, y: t.minY), Point(x: t.minX, y: t.maxY), Point(x: t.maxX, y: t.maxY)] {
            let v = pow((p.x - cx) / rx, 2) + pow((p.y - cy) / ry, 2)
            XCTAssertLessThanOrEqual(v, 1.0)
        }
    }

    func testLabelPlacementAvoidsTargetAndBounds() {
        let bounds = Rect(x: 0, y: 0, width: 800, height: 600)
        let target = Rect(x: 350, y: 580, width: 100, height: 18)   // at bottom edge → label goes above
        let lf = AnnotationGeometry.labelFrame(size: Size(width: 120, height: 26), near: target, within: bounds)
        XCTAssertTrue(bounds.contains(lf)); XCTAssertFalse(lf.intersects(target)); XCTAssertLessThan(lf.maxY, target.minY)
    }
}

final class AnnotationLifecycleTests: XCTestCase {
    let ident = ElementIdentity(pid: 1, role: "AXButton", identifier: "b", title: "Save", label: nil, path: "w0.1", lastFrame: Rect(x: 100, y: 100, width: 80, height: 24))
    let t0 = Date(timeIntervalSince1970: 1000)

    func ann(_ kind: AnnotationKind = .highlight, _ target: AnnotationTarget? = nil, window: Rect? = Rect(x: 50, y: 50, width: 600, height: 400)) -> Annotation {
        Annotation(kind: kind, target: target ?? .element(ident, frame: Rect(x: 100, y: 100, width: 80, height: 24)), label: "Save here", createdAt: t0, ttl: 30, windowFrame: window)
    }

    func testFollowsMovedElement() {
        var lc = AnnotationLifecycle(); let a = ann(); lc.set([a])
        let moved = Rect(x: 140, y: 130, width: 80, height: 24)
        XCTAssertTrue(lc.update(AnchorObservation(elementFrames: [a.id: moved], windowFrame: nil, layout: Fixtures.layout, now: t0.addingTimeInterval(1))))
        XCTAssertEqual(lc.annotations.first?.targetFrame, moved)
        let r = lc.render(layout: Fixtures.layout).first!
        // Anchoring accuracy: rendered target (local + display origin) equals the AX frame exactly.
        XCTAssertEqual(r.targetRect, moved)
        XCTAssertEqual(r.displayID, 1)
    }

    func testRemovesWhenTargetDisappearsOrExpires() {
        var lc = AnnotationLifecycle(); let a = ann(); let b = ann(.circle); lc.set([a, b])
        let frames: [UUID: Rect?] = [a.id: nil, b.id: Rect(x: 100, y: 100, width: 80, height: 24)]
        lc.update(AnchorObservation(elementFrames: frames, windowFrame: nil, layout: Fixtures.layout, now: t0))
        XCTAssertEqual(lc.annotations.map(\.id), [b.id])
        XCTAssertEqual(lc.removed.first?.1, "target disappeared")
        lc.update(AnchorObservation(elementFrames: [:], windowFrame: nil, layout: Fixtures.layout, now: t0.addingTimeInterval(31)))
        XCTAssertTrue(lc.annotations.isEmpty)
        XCTAssertEqual(lc.removed.first?.1, "expired")
    }

    func testScreenTargetsFollowWindowMoveButDropOnResize() {
        var lc = AnnotationLifecycle()
        let a = ann(.arrow, .screen(Rect(x: 200, y: 200, width: 40, height: 40)))
        lc.set([a])
        lc.update(AnchorObservation(elementFrames: [:], windowFrame: Rect(x: 80, y: 70, width: 600, height: 400), layout: Fixtures.layout, now: t0))
        XCTAssertEqual(lc.annotations.first?.targetFrame, Rect(x: 230, y: 220, width: 40, height: 40))
        lc.update(AnchorObservation(elementFrames: [:], windowFrame: Rect(x: 80, y: 70, width: 700, height: 400), layout: Fixtures.layout, now: t0))
        XCTAssertTrue(lc.annotations.isEmpty)
        XCTAssertTrue(lc.removed.first?.1.contains("resized") == true)
    }

    func testRendersOnSecondaryDisplayInLocalCoordinates() {
        var lc = AnnotationLifecycle()
        let g = Rect(x: -1000, y: -600, width: 60, height: 20)
        lc.set([ann(.arrow, .element(ident, frame: g))])
        let r = lc.render(layout: Fixtures.layout).first!
        XCTAssertEqual(r.displayID, 2)
        XCTAssertEqual(r.targetRect, Rect(x: 920, y: 480, width: 60, height: 20))
        XCTAssertNotNil(r.arrow)
        XCTAssertTrue(Rect(x: 0, y: 0, width: 1920, height: 1080).contains(r.arrow!.tail))
        // Round trip local → global within 12pt target (here exact).
        let back = Fixtures.layout.globalRect(fromLocal: r.targetRect, in: Fixtures.secondary)
        XCTAssertLessThanOrEqual(abs(back.midX - g.midX), 12); XCTAssertLessThanOrEqual(abs(back.midY - g.midY), 12)
    }

    func testOffscreenTargetRemoved() {
        var lc = AnnotationLifecycle(); let a = ann(); lc.set([a])
        lc.update(AnchorObservation(elementFrames: [a.id: Rect(x: 9000, y: 9000, width: 10, height: 10)], windowFrame: nil, layout: Fixtures.layout, now: t0))
        XCTAssertTrue(lc.annotations.isEmpty)
    }
}
