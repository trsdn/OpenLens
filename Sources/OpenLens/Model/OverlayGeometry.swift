import CoreGraphics

/// Which corner of the overlay a resize is driven from. The opposite corner
/// stays put while dragging, which is what every image editor does.
enum OverlayCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// What the pointer is over.
enum OverlayHit: Equatable {
    case none
    case body
    case corner(OverlayCorner)
}

/// Placement maths for the overlay, in normalized output space with a top-left
/// origin — the same space the shader uses, so nothing has to be converted
/// twice.
///
/// This lives apart from the views because it is the part that can actually be
/// wrong: aspect ratios, anchors and clamping are easy to get subtly backwards
/// and impossible to spot by looking at a logo in the corner.
enum OverlayGeometry {
    /// Small enough to tuck a logo away, large enough that the overlay cannot
    /// be shrunk into something unclickable.
    static let minimumWidth: CGFloat = 0.04

    // MARK: - Hit testing

    /// Corners win over the body so that a small overlay is still resizable —
    /// otherwise the handles of a 4 % wide logo would be entirely swallowed by
    /// its own body.
    static func hit(point: CGPoint, in rect: CGRect, cornerRadius: CGSize) -> OverlayHit {
        for corner in OverlayCorner.allCases {
            let anchor = position(of: corner, in: rect)
            if abs(point.x - anchor.x) <= cornerRadius.width,
               abs(point.y - anchor.y) <= cornerRadius.height {
                return .corner(corner)
            }
        }
        return rect.contains(point) ? .body : .none
    }

    static func position(of corner: OverlayCorner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// The corner that stays fixed while `corner` is dragged.
    static func opposite(_ corner: OverlayCorner) -> OverlayCorner {
        switch corner {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }

    // MARK: - Moving

    /// Moves the overlay, keeping it fully inside the frame. Sliding along an
    /// edge still works when the drag pushes past it, because each axis is
    /// clamped on its own.
    static func moved(_ rect: CGRect, by delta: CGSize) -> CGRect {
        var moved = rect
        moved.origin.x = clamp(rect.minX + delta.width, 0, max(0, 1 - rect.width))
        moved.origin.y = clamp(rect.minY + delta.height, 0, max(0, 1 - rect.height))
        return moved
    }

    // MARK: - Resizing

    /// Resizes from `corner` towards `point`, holding the aspect ratio the rect
    /// already has and pinning the opposite corner.
    ///
    /// The larger of the two axes drives the size, so a mostly-vertical drag
    /// resizes just as readily as a diagonal one. Driving off width alone would
    /// make vertical drags feel dead.
    static func resized(_ rect: CGRect, corner: OverlayCorner, to point: CGPoint) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return rect }
        let aspect = rect.width / rect.height
        let anchor = position(of: opposite(corner), in: rect)

        var width = max(abs(point.x - anchor.x), abs(point.y - anchor.y) * aspect)
        width = max(width, minimumWidth)

        // Keep the result on screen: whichever way the anchor faces, the room
        // left in that direction caps the size.
        let roomX = corner == .topRight || corner == .bottomRight ? 1 - anchor.x : anchor.x
        let roomY = corner == .bottomLeft || corner == .bottomRight ? 1 - anchor.y : anchor.y
        width = min(width, roomX, roomY * aspect)
        width = max(width, minimumWidth)
        let height = width / aspect

        let origin = CGPoint(
            x: corner == .topLeft || corner == .bottomLeft ? anchor.x - width : anchor.x,
            y: corner == .topLeft || corner == .topRight ? anchor.y - height : anchor.y
        )
        return CGRect(x: origin.x, y: origin.y, width: width, height: height)
    }

    /// Scales around the centre, for the size slider.
    static func scaled(_ rect: CGRect, toWidth width: CGFloat) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return rect }
        let aspect = rect.width / rect.height
        let newWidth = max(width, minimumWidth)
        let newHeight = newWidth / aspect
        let centred = CGRect(
            x: rect.midX - newWidth / 2,
            y: rect.midY - newHeight / 2,
            width: newWidth,
            height: newHeight
        )
        return moved(centred, by: .zero)
    }

    // MARK: - Aspect ratio

    /// Gives the rect the aspect ratio of the image it displays.
    ///
    /// The shader stretches the whole texture across the rect, so without this
    /// every overlay that is not square comes out distorted. Normalized output
    /// space is not square either — a 16:9 frame squashes the y axis — so the
    /// output aspect has to be folded in as well.
    static func fitted(_ rect: CGRect, pixelSize: CGSize, outputAspect: CGFloat) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0, outputAspect > 0 else { return rect }
        let width = max(rect.width, minimumWidth)
        let height = width * outputAspect * (pixelSize.height / pixelSize.width)
        // A very wide banner would otherwise be pushed off the bottom.
        let scale = height > 1 ? 1 / height : 1
        let fitted = CGRect(
            x: rect.midX - width * scale / 2,
            y: rect.midY - height * scale / 2,
            width: width * scale,
            height: height * scale
        )
        return moved(fitted, by: .zero)
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }
}
