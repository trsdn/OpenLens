import CoreGraphics
import XCTest

/// The overlay maths is the part that can be quietly wrong: a logo that is
/// slightly stretched or a corner that drifts away from the cursor is easy to
/// ship and hard to notice.
final class OverlayGeometryTests: XCTestCase {
    private let rect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1)

    // MARK: - Hit testing

    func testPointInsideHitsBody() {
        let hit = OverlayGeometry.hit(
            point: CGPoint(x: 0.5, y: 0.45),
            in: rect,
            cornerRadius: CGSize(width: 0.01, height: 0.01)
        )
        XCTAssertEqual(hit, .body)
    }

    func testPointOutsideMisses() {
        let hit = OverlayGeometry.hit(
            point: CGPoint(x: 0.1, y: 0.1),
            in: rect,
            cornerRadius: CGSize(width: 0.01, height: 0.01)
        )
        XCTAssertEqual(hit, .none)
    }

    func testCornersWinOverBody() {
        // A generous radius puts the corner well inside the body; resizing has
        // to keep working or small overlays become impossible to scale.
        let hit = OverlayGeometry.hit(
            point: CGPoint(x: 0.405, y: 0.405),
            in: rect,
            cornerRadius: CGSize(width: 0.02, height: 0.02)
        )
        XCTAssertEqual(hit, .corner(.topLeft))
    }

    func testEachCornerIsReachable() {
        let radius = CGSize(width: 0.01, height: 0.01)
        for corner in OverlayCorner.allCases {
            let point = OverlayGeometry.position(of: corner, in: rect)
            XCTAssertEqual(
                OverlayGeometry.hit(point: point, in: rect, cornerRadius: radius),
                .corner(corner),
                "\(corner) should be grabbable at its own position"
            )
        }
    }

    // MARK: - Moving

    func testMoveShiftsOrigin() {
        let moved = OverlayGeometry.moved(rect, by: CGSize(width: 0.1, height: -0.2))
        XCTAssertEqual(moved.minX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(moved.minY, 0.2, accuracy: 1e-9)
        XCTAssertEqual(moved.size, rect.size)
    }

    func testMoveClampsInsideFrame() {
        let moved = OverlayGeometry.moved(rect, by: CGSize(width: 5, height: 5))
        XCTAssertEqual(moved.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(moved.maxY, 1, accuracy: 1e-9)
    }

    func testMoveClampsPerAxisSoEdgesStillSlide() {
        // Pushed hard left but also downwards: the y movement must survive even
        // though x is pinned, otherwise dragging along an edge feels stuck.
        let moved = OverlayGeometry.moved(rect, by: CGSize(width: -5, height: 0.1))
        XCTAssertEqual(moved.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(moved.minY, 0.5, accuracy: 1e-9)
    }

    // MARK: - Resizing

    func testResizeKeepsAspectRatio() {
        let resized = OverlayGeometry.resized(
            rect,
            corner: .bottomRight,
            to: CGPoint(x: 0.8, y: 0.9)
        )
        XCTAssertEqual(
            resized.width / resized.height,
            rect.width / rect.height,
            accuracy: 1e-6
        )
    }

    func testResizePinsTheOppositeCorner() {
        let resized = OverlayGeometry.resized(
            rect,
            corner: .bottomRight,
            to: CGPoint(x: 0.7, y: 0.7)
        )
        XCTAssertEqual(resized.minX, rect.minX, accuracy: 1e-9)
        XCTAssertEqual(resized.minY, rect.minY, accuracy: 1e-9)
    }

    func testResizeFromTopLeftPinsBottomRight() {
        let resized = OverlayGeometry.resized(
            rect,
            corner: .topLeft,
            to: CGPoint(x: 0.3, y: 0.3)
        )
        XCTAssertEqual(resized.maxX, rect.maxX, accuracy: 1e-9)
        XCTAssertEqual(resized.maxY, rect.maxY, accuracy: 1e-9)
    }

    func testVerticalDragAloneStillResizes() {
        // Driving off width alone would make this a no-op, which reads as a
        // broken handle.
        let resized = OverlayGeometry.resized(
            rect,
            corner: .bottomRight,
            to: CGPoint(x: rect.maxX, y: 0.9)
        )
        XCTAssertGreaterThan(resized.height, rect.height)
    }

    func testResizeRespectsMinimumWidth() {
        let resized = OverlayGeometry.resized(
            rect,
            corner: .bottomRight,
            to: CGPoint(x: 0.4, y: 0.4)
        )
        XCTAssertGreaterThanOrEqual(resized.width, OverlayGeometry.minimumWidth)
    }

    func testResizeStaysInsideFrame() {
        let resized = OverlayGeometry.resized(
            rect,
            corner: .bottomRight,
            to: CGPoint(x: 5, y: 5)
        )
        XCTAssertLessThanOrEqual(resized.maxX, 1 + 1e-9)
        XCTAssertLessThanOrEqual(resized.maxY, 1 + 1e-9)
    }

    // MARK: - Scaling

    func testScaleKeepsCentreAndAspect() {
        let scaled = OverlayGeometry.scaled(rect, toWidth: 0.4)
        XCTAssertEqual(scaled.midX, rect.midX, accuracy: 1e-9)
        XCTAssertEqual(scaled.midY, rect.midY, accuracy: 1e-9)
        XCTAssertEqual(scaled.width / scaled.height, rect.width / rect.height, accuracy: 1e-6)
    }

    // MARK: - Aspect ratio

    func testFittedGivesASquareImageASquareOnScreenShape() {
        // In a 16:9 frame a visually square logo needs a rect that is 16/9 as
        // tall as it is wide in normalized space.
        let fitted = OverlayGeometry.fitted(
            CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            pixelSize: CGSize(width: 500, height: 500),
            outputAspect: 16.0 / 9.0
        )
        XCTAssertEqual(fitted.height, 0.2 * 16.0 / 9.0, accuracy: 1e-6)
    }

    func testFittedHandlesAWideBanner() {
        let fitted = OverlayGeometry.fitted(
            CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            pixelSize: CGSize(width: 1000, height: 200),
            outputAspect: 16.0 / 9.0
        )
        XCTAssertEqual(fitted.height, 0.5 * (16.0 / 9.0) * 0.2, accuracy: 1e-6)
        XCTAssertLessThan(fitted.height, fitted.width)
    }

    func testFittedIsIdempotent() {
        // Applied on every load, so a second pass must not creep.
        let pixels = CGSize(width: 800, height: 300)
        let once = OverlayGeometry.fitted(rect, pixelSize: pixels, outputAspect: 16.0 / 9.0)
        let twice = OverlayGeometry.fitted(once, pixelSize: pixels, outputAspect: 16.0 / 9.0)
        XCTAssertEqual(once.width, twice.width, accuracy: 1e-9)
        XCTAssertEqual(once.height, twice.height, accuracy: 1e-9)
    }

    func testFittedIgnoresADegenerateImage() {
        let fitted = OverlayGeometry.fitted(rect, pixelSize: .zero, outputAspect: 16.0 / 9.0)
        XCTAssertEqual(fitted, rect)
    }

    func testFittedKeepsATallImageOnScreen() {
        let fitted = OverlayGeometry.fitted(
            CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            pixelSize: CGSize(width: 200, height: 1000),
            outputAspect: 16.0 / 9.0
        )
        XCTAssertLessThanOrEqual(fitted.maxY, 1 + 1e-9)
        XCTAssertGreaterThanOrEqual(fitted.minY, -1e-9)
    }
}
