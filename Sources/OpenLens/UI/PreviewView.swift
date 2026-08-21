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
        dragOrigin = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 { model?.resetZoom() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        let box = metalLayer.frame
        guard box.width > 0, box.height > 0 else { return }

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

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        model?.persistCrop()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
