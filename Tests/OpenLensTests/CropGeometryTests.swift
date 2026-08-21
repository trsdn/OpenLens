import CoreGraphics
import XCTest

final class CropGeometryTests: XCTestCase {
    private let outputAspect: CGFloat = 16.0 / 9.0

    func testBaseSizeFillsHeightForWiderSource() {
        // A 4:3 output cropped out of a 16:9 source is limited by width.
        let size = CropGeometry.baseSize(sourceAspect: 16.0 / 9.0, outputAspect: 4.0 / 3.0)
        XCTAssertEqual(size.height, 1.0, accuracy: 0.0001)
        XCTAssertEqual(size.width, (4.0 / 3.0) / (16.0 / 9.0), accuracy: 0.0001)
    }

    func testMatchingAspectsUseTheWholeFrame() {
        let size = CropGeometry.baseSize(sourceAspect: outputAspect, outputAspect: outputAspect)
        XCTAssertEqual(size.width, 1.0, accuracy: 0.0001)
        XCTAssertEqual(size.height, 1.0, accuracy: 0.0001)
    }

    func testIdentityCropCoversTheWholeSource() {
        let rect = CropGeometry.rect(
            for: .identity,
            sourceAspect: outputAspect,
            outputAspect: outputAspect
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testCropStaysInsideTheSourceWhenPushedOutOfBounds() {
        let state = CropState(center: CGPoint(x: 2.0, y: -1.0), zoom: 2)
        let rect = CropGeometry.rect(
            for: state,
            sourceAspect: outputAspect,
            outputAspect: outputAspect
        )
        XCTAssertGreaterThanOrEqual(rect.minX, -0.0001)
        XCTAssertGreaterThanOrEqual(rect.minY, -0.0001)
        XCTAssertLessThanOrEqual(rect.maxX, 1.0001)
        XCTAssertLessThanOrEqual(rect.maxY, 1.0001)
    }

    func testZoomIsClampedToTheSupportedRange() {
        XCTAssertEqual(CropGeometry.clampZoom(0.2), CropGeometry.minZoom)
        XCTAssertEqual(CropGeometry.clampZoom(1000), CropGeometry.maxZoom)
    }

    func testZoomingKeepsTheAnchorUnderTheCursor() {
        let anchor = CGPoint(x: 0.3, y: 0.65)
        let start = CropState(center: CGPoint(x: 0.5, y: 0.5), zoom: 1.5)
        let startRect = CropGeometry.rect(
            for: start,
            sourceAspect: outputAspect,
            outputAspect: outputAspect
        )
        let relBefore = CGPoint(
            x: (anchor.x - startRect.minX) / startRect.width,
            y: (anchor.y - startRect.minY) / startRect.height
        )

        let zoomed = CropGeometry.zooming(
            start,
            to: 3.0,
            anchor: anchor,
            sourceAspect: outputAspect,
            outputAspect: outputAspect
        )
        let endRect = CropGeometry.rect(
            for: zoomed,
            sourceAspect: outputAspect,
            outputAspect: outputAspect
        )
        let relAfter = CGPoint(
            x: (anchor.x - endRect.minX) / endRect.width,
            y: (anchor.y - endRect.minY) / endRect.height
        )

        XCTAssertEqual(relBefore.x, relAfter.x, accuracy: 0.001)
        XCTAssertEqual(relBefore.y, relAfter.y, accuracy: 0.001)
    }

    func testZoomingNearAnEdgeClampsInsteadOfLeavingTheFrame() {
        let zoomed = CropGeometry.zooming(
            .identity,
            to: 4.0,
            anchor: CGPoint(x: 0.01, y: 0.99),
            sourceAspect: outputAspect,
            outputAspect: outputAspect
        )
        let rect = CropGeometry.rect(
            for: zoomed,
            sourceAspect: outputAspect,
            outputAspect: outputAspect
        )
        XCTAssertGreaterThanOrEqual(rect.minX, -0.0001)
        XCTAssertLessThanOrEqual(rect.maxY, 1.0001)
    }

    func testPanningAtFullFrameCannotMove() {
        // At 1x the crop already fills the source, so there is nowhere to pan.
        let panned = CropGeometry.panning(
            .identity,
            by: CGSize(width: 0.3, height: 0.3),
            sourceAspect: outputAspect,
            outputAspect: outputAspect
        )
        XCTAssertEqual(panned.center.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(panned.center.y, 0.5, accuracy: 0.0001)
    }

    func testPanningMovesWhenZoomedIn() {
        let panned = CropGeometry.panning(
            CropState(center: CGPoint(x: 0.5, y: 0.5), zoom: 2),
            by: CGSize(width: 0.1, height: 0),
            sourceAspect: outputAspect,
            outputAspect: outputAspect
        )
        XCTAssertEqual(panned.center.x, 0.6, accuracy: 0.0001)
    }

    func testFourKSourceGivesTwoTimesLosslessZoomAtTenEightyOutput() {
        let limit = CropGeometry.losslessZoomLimit(
            sourcePixelSize: CGSize(width: 3840, height: 2160),
            outputPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(limit, 2.0, accuracy: 0.0001)
    }

    func testMatchingResolutionsGiveNoLosslessHeadroom() {
        let limit = CropGeometry.losslessZoomLimit(
            sourcePixelSize: CGSize(width: 1920, height: 1080),
            outputPixelSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(limit, 1.0, accuracy: 0.0001)
    }

    func testInterpolationIsGeometricInZoom() {
        let mid = CropGeometry.interpolate(
            from: CropState(center: .init(x: 0.5, y: 0.5), zoom: 1),
            to: CropState(center: .init(x: 0.5, y: 0.5), zoom: 4),
            t: 0.5
        )
        XCTAssertEqual(mid.zoom, 2.0, accuracy: 0.0001)
    }
}

final class CropAnimatorTests: XCTestCase {
    func testSnapSkipsTheAnimation() {
        var animator = CropAnimator()
        let target = CropState(center: CGPoint(x: 0.2, y: 0.8), zoom: 3)
        animator.snap(to: target)
        XCTAssertTrue(animator.isSettled)
        XCTAssertEqual(animator.current.zoom, 3, accuracy: 0.0001)
    }

    func testAnimationConvergesOnTheTarget() {
        var animator = CropAnimator()
        animator.target = CropState(center: CGPoint(x: 0.3, y: 0.4), zoom: 2.5)
        // Half a second of 60 fps frames is far more than the 90 ms time constant.
        for _ in 0..<30 { animator.advance(deltaTime: 1.0 / 60.0) }
        XCTAssertEqual(animator.current.zoom, 2.5, accuracy: 0.01)
        XCTAssertEqual(animator.current.center.x, 0.3, accuracy: 0.01)
    }

    func testProgressIsIndependentOfFrameRate() {
        var fast = CropAnimator()
        var slow = CropAnimator()
        let target = CropState(center: CGPoint(x: 0.2, y: 0.2), zoom: 4)
        fast.target = target
        slow.target = target

        for _ in 0..<12 { fast.advance(deltaTime: 1.0 / 120.0) }
        for _ in 0..<3 { slow.advance(deltaTime: 1.0 / 30.0) }

        XCTAssertEqual(fast.current.zoom, slow.current.zoom, accuracy: 0.02)
    }

    func testAnimatorNeverOvershoots() {
        var animator = CropAnimator()
        animator.target = CropState(center: CGPoint(x: 0.5, y: 0.5), zoom: 5)
        for _ in 0..<200 {
            animator.advance(deltaTime: 1.0 / 60.0)
            XCTAssertLessThanOrEqual(animator.current.zoom, 5.0001)
        }
    }
}
