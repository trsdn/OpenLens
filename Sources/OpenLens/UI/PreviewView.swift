import AppKit
import QuartzCore
import SwiftUI

/// The live output preview, and the surface the zoom is driven from.
///
/// The preview shows the **final** cropped image rather than the whole sensor
/// with a rectangle drawn on it: you manipulate what your audience sees, which
/// removes a whole layer of mental translation while you are on a call.
struct PreviewView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> MetalPreviewView {
        let view = MetalPreviewView()
        view.model = model
        model.attachPreview(view.renderTarget)
        return view
    }

    func updateNSView(_ nsView: MetalPreviewView, context: Context) {
        nsView.model = model
    }

    static func dismantleNSView(_ nsView: MetalPreviewView, coordinator: ()) {
        nsView.model?.detachPreview()
    }
}

final class MetalPreviewView: NSView {
    weak var model: AppModel?
    private let metalLayer = CAMetalLayer()
    private(set) lazy var renderTarget = PreviewRenderTarget(layer: metalLayer)
    private var occlusionObserver: NSObjectProtocol?
    private var dragOrigin: CGPoint?
    /// What the current drag is doing. Decided once on mouse-down so the
    /// gesture cannot change its mind halfway through and start panning the
    /// crop while the hand is still moving a logo.
    private enum DragMode {
        case pan
        case moveOverlay
        case resizeOverlay(OverlayCorner)
    }
    private var dragMode: DragMode = .pan

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        metalLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        let box = Self.aspectFitRect(in: bounds, aspect: CGFloat(OpenLensOutput.aspectRatio))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = box
        CATransaction.commit()
        renderTarget.setDrawableSize(
            PreviewRenderTarget.drawableSize(for: box.size, scale: scale)
        )
    }

    /// Letterboxes the output aspect inside the available space so the preview is
    /// always a pixel-accurate representation of what is transmitted.
    static func aspectFitRect(in bounds: CGRect, aspect: CGFloat) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, aspect > 0 else { return bounds }
        let boundsAspect = bounds.width / bounds.height
        if boundsAspect > aspect {
            let width = bounds.height * aspect
            return CGRect(
                x: bounds.midX - width / 2,
                y: bounds.minY,
                width: width,
                height: bounds.height
            )
        } else {
            let height = bounds.width / aspect
            return CGRect(
                x: bounds.minX,
                y: bounds.midY - height / 2,
                width: bounds.width,
                height: height
            )
        }
    }

    // MARK: - Window lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        guard let window else {
            renderTarget.setEnabled(false)
            model?.setPreviewVisible(false)
            return
        }
        // Rendering into a window nobody can see is pure waste; the virtual camera
        // keeps running regardless.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateVisibility()
        }
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        renderTarget.setEnabled(visible)
        model?.setPreviewVisible(visible)
    }

    // MARK: - Overlay interaction

    /// View point to normalized output space, top-left origin — the same space
    /// the shader places the overlay in. Unlike `sourceCoordinate` this ignores
    /// the crop and the mirror, because the overlay is composited after both.
    private func outputCoordinate(for point: CGPoint) -> CGPoint? {
        let box = metalLayer.frame
        guard box.width > 0, box.height > 0 else { return nil }
        let u = (point.x - box.minX) / box.width
        let v = (point.y - box.minY) / box.height
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        return CGPoint(x: u, y: v)
    }

    /// Nothing is grabbable unless the overlay is actually on screen.
    private func overlayHit(at point: CGPoint) -> OverlayHit {
        guard let model,
              let scene = model.scenes.selectedScene,
              scene.overlayEnabled,
              model.scenes.overlayURL != nil,
              scene.overlayOpacity > 0,
              let coordinate = outputCoordinate(for: point)
        else { return .none }
        let box = metalLayer.frame
        // A fixed grab radius in points, converted per axis because normalized
        // output space is not square.
        let radius = CGSize(width: 11 / box.width, height: 11 / box.height)
        return OverlayGeometry.hit(point: coordinate, in: scene.overlayRect, cornerRadius: radius)
    }

    private func cursor(for hit: OverlayHit) -> NSCursor {
        switch hit {
        case .none: return .openHand
        case .body: return .pointingHand
        // AppKit exposes no public diagonal resize cursor, and the private ones
        // are not worth the risk for a cosmetic hint.
        case .corner: return .crosshair
        }
    }

    // MARK: - Zoom interaction

    /// Converts a point in this view to normalized source coordinates, so the
    /// pixel under the cursor stays under the cursor while zooming.
    private func sourceCoordinate(for point: CGPoint) -> CGPoint? {
        guard let model else { return nil }
        let box = metalLayer.frame
        guard box.width > 0, box.height > 0 else { return nil }
        var u = (point.x - box.minX) / box.width
        let v = (point.y - box.minY) / box.height
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        if model.scenes.selectedScene?.mirrored == true { u = 1 - u }
        let crop = model.currentCropRect
        return CGPoint(x: crop.minX + u * crop.width, y: crop.minY + v * crop.height)
    }

    override func scrollWheel(with event: NSEvent) {
        // Momentum events keep arriving for a second after the fingers lift. Zooming
        // through them overshoots wildly and feels like the app is running away, so
        // only the part of the gesture the hand is actually driving counts.
        guard event.momentumPhase == [] else { return }
        guard let model, let anchor = sourceCoordinate(for: convert(event.locationInWindow, from: nil))
        else { return super.scrollWheel(with: event) }
        // Trackpads report small continuous deltas, mice report coarse steps;
        // exponentiating keeps both feeling like the same gesture. The gains are
        // tuned so that one comfortable two-finger swipe, or four wheel clicks,
        // is roughly a doubling — anything gentler reads as "the zoom is broken".
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.006
            : event.scrollingDeltaY * 0.15
        model.zoomBy(factor: exp(step), anchor: anchor)
        model.schedulePersist()
    }

    override func magnify(with event: NSEvent) {
        guard let model, let anchor = sourceCoordinate(for: convert(event.locationInWindow, from: nil))
        else { return super.magnify(with: event) }
        model.zoomBy(factor: 1 + event.magnification, anchor: anchor)
        if event.phase == .ended { model.persistCrop() }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        if event.clickCount == 2 {
            // Double-click on the overlay is a size reset, not a zoom reset —
            // resetting the zoom from there would look like a misfire.
            switch overlayHit(at: point) {
            case .none:
                model?.resetZoom()
            case .body, .corner:
                model?.resetOverlaySize()
            }
            dragMode = .pan
            return
        }
        switch overlayHit(at: point) {
        case .none: dragMode = .pan
        case .body: dragMode = .moveOverlay
        case .corner(let corner): dragMode = .resizeOverlay(corner)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        let box = metalLayer.frame
        guard box.width > 0, box.height > 0 else { return }

        switch dragMode {
        case .moveOverlay:
            model.moveOverlay(
                by: CGSize(
                    width: (point.x - origin.x) / box.width,
                    height: (point.y - origin.y) / box.height
                )
            )
            dragOrigin = point

        case .resizeOverlay(let corner):
            // Resizing follows the pointer absolutely rather than by delta, so
            // the corner cannot drift away from the cursor over a long drag.
            guard let coordinate = outputCoordinate(for: point) else { return }
            model.resizeOverlay(corner: corner, to: coordinate)

        case .pan:
            let crop = model.currentCropRect
            let mirrored = model.scenes.selectedScene?.mirrored == true
            let dxView = (point.x - origin.x) / box.width
            let dyView = (point.y - origin.y) / box.height
            // Dragging moves the image, so the crop window travels the other way.
            let delta = CGSize(
                width: (mirrored ? dxView : -dxView) * crop.width,
                height: -dyView * crop.height
            )
            model.pan(by: delta)
            dragOrigin = point
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        switch dragMode {
        case .pan: model?.persistCrop()
        case .moveOverlay, .resizeOverlay: model?.commitOverlayRect()
        }
        dragMode = .pan
    }

    override func mouseMoved(with event: NSEvent) {
        cursor(for: overlayHit(at: convert(event.locationInWindow, from: nil))).set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                owner: self
            )
        )
    }
}
