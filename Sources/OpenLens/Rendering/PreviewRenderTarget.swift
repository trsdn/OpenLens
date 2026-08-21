import Foundation
import Metal
import QuartzCore

/// Thread-safe handle to the preview's `CAMetalLayer`.
///
/// The camera queue drives rendering, so it needs to pull drawables from a layer
/// that the main thread is simultaneously resizing. Everything that touches the
/// layer goes through this small lock instead of hopping queues per frame.
final class PreviewRenderTarget: @unchecked Sendable {
    private let layer: CAMetalLayer
    private let lock = NSLock()
    private var isEnabled = true
    private var inFlight = 0

    init(layer: CAMetalLayer) {
        self.layer = layer
    }

    func configure(device: MTLDevice) {
        lock.lock()
        defer { lock.unlock() }
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        // Two drawables is enough for a source-driven pipeline and keeps latency
        // down; a third only adds a frame of lag.
        layer.maximumDrawableCount = 2
        layer.displaySyncEnabled = true
    }

    /// Caps the preview at the transmitted resolution.
    ///
    /// A Retina-sized drawable would make the preview *sharper* than the frame
    /// everybody in the call receives, which hides exactly the softness a strong
    /// zoom introduces — the one thing the preview exists to show. Rendering
    /// 3.5 MPix to display 2.07 MPix also costs real GPU bandwidth per frame.
    static func drawableSize(for boxSize: CGSize, scale: CGFloat) -> CGSize {
        let requested = CGSize(width: boxSize.width * scale, height: boxSize.height * scale)
        guard requested.width > CGFloat(OpenLensOutput.width) else { return requested }
        return CGSize(width: OpenLensOutput.width, height: OpenLensOutput.height)
    }

    func setDrawableSize(_ size: CGSize) {        lock.lock()
        defer { lock.unlock() }
        guard size.width > 0, size.height > 0 else { return }
        if layer.drawableSize != size { layer.drawableSize = size }
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        isEnabled = enabled
        lock.unlock()
    }

    /// Returns a drawable only when the previous preview frame has already been
    /// presented.
    ///
    /// `nextDrawable()` blocks until the layer has a free drawable — and it is
    /// called on the same thread that feeds the virtual camera. Blocking there
    /// puts the preview, which nobody in the call can see, in the way of the
    /// video everybody can. Skipping a preview frame instead costs nothing that
    /// matters: the preview is a monitor, not the product.
    ///
    /// The layer lock still covers the call, because `setDrawableSize` runs on
    /// the main thread. With one drawable of two in flight at most, there is
    /// always a free one, so it returns without waiting.
    func nextDrawableIfIdle() -> CAMetalDrawable? {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled, layer.device != nil, inFlight == 0 else { return nil }
        guard let drawable = layer.nextDrawable() else { return nil }
        inFlight += 1
        return drawable
    }

    func drawablePresented() {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        lock.unlock()
    }
}
