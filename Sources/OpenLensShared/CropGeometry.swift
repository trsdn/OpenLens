import CoreGraphics
import Foundation

/// The zoom/crop state for one scene.
///
/// Stored as `center` + `zoom` rather than as a rectangle, because that makes
/// the aspect lock structural (a rect with the wrong aspect simply cannot be
/// represented) and makes animation a plain lerp of two scalars and a point.
///
/// Coordinate space: normalized source space with a **top-left origin**, y down,
/// which matches texture coordinates and AVFoundation image buffers.
public struct CropState: Equatable, Codable, Sendable {
    /// Normalized center of the crop window in source space.
    public var center: CGPoint
    /// 1.0 = the largest output-aspect window that fits the source. Higher = tighter.
    public var zoom: CGFloat

    public static let identity = CropState(center: CGPoint(x: 0.5, y: 0.5), zoom: 1.0)

    public init(center: CGPoint = CGPoint(x: 0.5, y: 0.5), zoom: CGFloat = 1.0) {
        self.center = center
        self.zoom = zoom
    }
}

/// Pure geometry for the zoom feature. Deliberately free of any UI or Metal types
/// so it can be unit tested in isolation.
public enum CropGeometry {
    public static let minZoom: CGFloat = 1.0
    public static let maxZoom: CGFloat = 8.0

    /// Size of the crop window at zoom 1.0, normalized to the source.
    ///
    /// This is the largest rectangle with the output aspect ratio that fits
    /// inside the source ("fit", not "fill" — we never invent pixels at 1x).
    public static func baseSize(sourceAspect: CGFloat, outputAspect: CGFloat) -> CGSize {
        guard sourceAspect > 0, outputAspect > 0 else { return CGSize(width: 1, height: 1) }
        if sourceAspect > outputAspect {
            // Source is wider than the output: height is the limiting dimension.
            return CGSize(width: outputAspect / sourceAspect, height: 1.0)
        } else {
            return CGSize(width: 1.0, height: sourceAspect / outputAspect)
        }
    }

    /// The crop window as a normalized rect in source space, clamped to stay in bounds.
    public static func rect(
        for state: CropState,
        sourceAspect: CGFloat,
        outputAspect: CGFloat
    ) -> CGRect {
        let base = baseSize(sourceAspect: sourceAspect, outputAspect: outputAspect)
        let zoom = clampZoom(state.zoom)
        let size = CGSize(width: base.width / zoom, height: base.height / zoom)
        let center = clampCenter(state.center, size: size)
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    public static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, minZoom), maxZoom)
    }

    /// Keeps a crop window of `size` fully inside the unit square.
    ///
    /// If the window is larger than the source in a dimension (which cannot
    /// happen for valid zooms, but can while a spring overshoots) the center is
    /// pinned to 0.5 for that axis instead of producing a nonsensical clamp.
    public static func clampCenter(_ center: CGPoint, size: CGSize) -> CGPoint {
        let halfW = size.width / 2
        let halfH = size.height / 2
        let x: CGFloat = size.width >= 1.0 ? 0.5 : min(max(center.x, halfW), 1 - halfW)
        let y: CGFloat = size.height >= 1.0 ? 0.5 : min(max(center.y, halfH), 1 - halfH)
        return CGPoint(x: x, y: y)
    }

    /// Zooms toward `anchor` (normalized source space), keeping the point under
    /// the cursor visually stationary — the interaction people expect from maps.
    public static func zooming(
        _ state: CropState,
        to newZoom: CGFloat,
        anchor: CGPoint,
        sourceAspect: CGFloat,
        outputAspect: CGFloat
    ) -> CropState {
        let base = baseSize(sourceAspect: sourceAspect, outputAspect: outputAspect)
        let oldRect = rect(for: state, sourceAspect: sourceAspect, outputAspect: outputAspect)
        let target = clampZoom(newZoom)

        // Where the anchor sits inside the current crop window, 0...1.
        let relX = oldRect.width > 0 ? (anchor.x - oldRect.minX) / oldRect.width : 0.5
        let relY = oldRect.height > 0 ? (anchor.y - oldRect.minY) / oldRect.height : 0.5

        let newSize = CGSize(width: base.width / target, height: base.height / target)
        let newOrigin = CGPoint(
            x: anchor.x - relX * newSize.width,
            y: anchor.y - relY * newSize.height
        )
        let newCenter = CGPoint(
            x: newOrigin.x + newSize.width / 2,
            y: newOrigin.y + newSize.height / 2
        )
        return CropState(center: clampCenter(newCenter, size: newSize), zoom: target)
    }

    /// Pans by a delta expressed in normalized source units.
    public static func panning(
        _ state: CropState,
        by delta: CGSize,
        sourceAspect: CGFloat,
        outputAspect: CGFloat
    ) -> CropState {
        let base = baseSize(sourceAspect: sourceAspect, outputAspect: outputAspect)
        let zoom = clampZoom(state.zoom)
        let size = CGSize(width: base.width / zoom, height: base.height / zoom)
        let moved = CGPoint(x: state.center.x + delta.width, y: state.center.y + delta.height)
        return CropState(center: clampCenter(moved, size: size), zoom: zoom)
    }

    /// The zoom beyond which the output would be upscaled from the source.
    ///
    /// Capturing at a higher resolution than we emit buys real, lossless zoom
    /// headroom — a 4K source feeding a 1080p output is lossless up to 2x.
    public static func losslessZoomLimit(
        sourcePixelSize: CGSize,
        outputPixelSize: CGSize
    ) -> CGFloat {
        guard sourcePixelSize.width > 0, sourcePixelSize.height > 0,
              outputPixelSize.width > 0, outputPixelSize.height > 0 else { return 1.0 }
        let sourceAspect = sourcePixelSize.width / sourcePixelSize.height
        let outputAspect = outputPixelSize.width / outputPixelSize.height
        let base = baseSize(sourceAspect: sourceAspect, outputAspect: outputAspect)
        let basePixelWidth = base.width * sourcePixelSize.width
        return max(1.0, basePixelWidth / outputPixelSize.width)
    }

    /// Linear interpolation used by the animator. Zoom is interpolated
    /// geometrically so that 1x -> 4x feels as fast as 4x -> 16x.
    public static func interpolate(from: CropState, to: CropState, t: CGFloat) -> CropState {
        let clampedT = min(max(t, 0), 1)
        let zoom = from.zoom * pow(to.zoom / from.zoom, clampedT)
        return CropState(
            center: CGPoint(
                x: from.center.x + (to.center.x - from.center.x) * clampedT,
                y: from.center.y + (to.center.y - from.center.y) * clampedT
            ),
            zoom: zoom
        )
    }
}
