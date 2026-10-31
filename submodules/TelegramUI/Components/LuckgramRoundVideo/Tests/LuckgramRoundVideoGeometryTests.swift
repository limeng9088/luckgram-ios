import XCTest
import LuckgramRoundVideo

/// Spec 03 acceptance criteria that can be checked without a device.
final class LuckgramRoundVideoGeometryTests: XCTestCase {
    typealias G = LuckgramRoundVideoGeometry

    // MARK: entry point

    func testOfferedOnlyForSingleVideo() {
        XCTAssertTrue(G.canOffer(enabled: true, selectedCount: 1, isVideo: true, hasPrice: false))
        // 验收：多选两个视频时不出现该选项
        XCTAssertFalse(G.canOffer(enabled: true, selectedCount: 2, isVideo: true, hasPrice: false))
        XCTAssertFalse(G.canOffer(enabled: true, selectedCount: 1, isVideo: false, hasPrice: false))
        XCTAssertFalse(G.canOffer(enabled: true, selectedCount: 1, isVideo: true, hasPrice: true))
        XCTAssertFalse(G.canOffer(enabled: false, selectedCount: 1, isVideo: true, hasPrice: false))
    }

    // MARK: 60 s limit

    func testShortVideoNeedsNoRange() {
        XCTAssertFalse(G.needsRange(duration: 10.0))
        XCTAssertFalse(G.needsRange(duration: 60.0))
        let r = G.initialRange(duration: 10.0)
        XCTAssertEqual(r.start, 0.0)
        XCTAssertEqual(r.end, 10.0)
    }

    func testTwoMinuteVideoSelectsAtMostSixtySeconds() {
        let d = 120.0
        XCTAssertTrue(G.needsRange(duration: d))
        var r = G.initialRange(duration: d)
        XCTAssertEqual(r.end - r.start, 60.0)
        // stretching the right handle never exceeds 60 s
        r = G.dragRange(mode: .right, start: 0.0, end: 60.0, delta: 50.0, duration: d, minLength: 1.0)
        XCTAssertEqual(r.end - r.start, 60.0, accuracy: 1e-9)
        // dragging the left handle far left keeps the window at 60 s
        r = G.dragRange(mode: .left, start: 50.0, end: 110.0, delta: -50.0, duration: d, minLength: 1.0)
        XCTAssertEqual(r.start, 50.0, accuracy: 1e-9)
        XCTAssertEqual(r.end, 110.0, accuracy: 1e-9)
        // moving the window stops at the end of the video
        r = G.dragRange(mode: .window, start: 0.0, end: 60.0, delta: 500.0, duration: d, minLength: 1.0)
        XCTAssertEqual(r.start, 60.0, accuracy: 1e-9)
        XCTAssertEqual(r.end, 120.0, accuracy: 1e-9)
        // handles cannot cross
        r = G.dragRange(mode: .left, start: 10.0, end: 20.0, delta: 100.0, duration: d, minLength: 1.0)
        XCTAssertEqual(r.end - r.start, 1.0, accuracy: 1e-9)
        // export is capped too
        let e = G.exportRange(start: 5.0, end: 100.0)
        XCTAssertEqual(e.end - e.start, 60.0)
    }

    // MARK: rotation

    func testRotationSwapsDisplaySize() {
        // 手机竖拍：1920x1080 with a 90° transform is shown as 1080x1920
        XCTAssertTrue(G.displaySize(width: 1920, height: 1080, rotationDegrees: 90) == (1080, 1920))
        XCTAssertTrue(G.displaySize(width: 1920, height: 1080, rotationDegrees: -90) == (1080, 1920))
        XCTAssertTrue(G.displaySize(width: 1920, height: 1080, rotationDegrees: 180) == (1920, 1080))
    }

    // MARK: crop

    func testDefaultCropIsCentredSquare() {
        let base = G.baseScale(circleDiameter: 300, width: 1080, height: 1920)
        let c = G.cropSquare(width: 1080, height: 1920, baseScale: base, zoom: 1, circleDiameter: 300, offsetX: 0, offsetY: 0)
        XCTAssertEqual(c.side, 1080, accuracy: 0.5)
        XCTAssertEqual(c.x, 0, accuracy: 0.5)
        XCTAssertEqual(c.y, 420, accuracy: 0.5)
    }

    func testDragAndZoomStayInsideVideo() {
        let (w, h, circle) = (1920.0, 1080.0, 300.0)
        let base = G.baseScale(circleDiameter: circle, width: w, height: h)
        for zoom in [1.0, 2.0, G.clampZoom(10.0)] {
            for (dx, dy) in [(1e6, 1e6), (-1e6, -1e6), (1e6, -1e6), (0.0, 0.0)] {
                let o = G.clampOffset(width: w, height: h, baseScale: base, zoom: zoom, circleDiameter: circle, x: dx, y: dy)
                let c = G.cropSquare(width: w, height: h, baseScale: base, zoom: zoom, circleDiameter: circle, offsetX: o.x, offsetY: o.y)
                XCTAssertGreaterThanOrEqual(c.x, 0)
                XCTAssertGreaterThanOrEqual(c.y, 0)
                XCTAssertLessThanOrEqual(c.x + c.side, w + 0.001)
                XCTAssertLessThanOrEqual(c.y + c.side, h + 0.001)
                XCTAssertEqual(c.side, min(w, h) / zoom, accuracy: 0.5)
            }
        }
        XCTAssertEqual(G.clampZoom(0.1), 1.0)
        XCTAssertEqual(G.clampZoom(10.0), G.maxZoom)
    }

    func testOutputSide() {
        XCTAssertEqual(G.outputSide(cropSide: 1080), 480)
        XCTAssertEqual(G.outputSide(cropSide: 361), 360)  // even, not upscaled
        XCTAssertEqual(G.outputSide(cropSide: 100), 240)
        XCTAssertEqual(G.videoBitrate(outputSide: 384), 1_000_000)
        XCTAssertEqual(G.videoBitrate(outputSide: 480), 1_200_000)
    }
}
