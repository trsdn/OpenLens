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

    func setDrawableSize(_ size: CGSize) {
        lock.lock()
        defer { lock.unlock() }
        guard size.width > 0, size.height > 0 else { return }
        if layer.drawableSize != size { layer.drawableSize = size }
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        isEnabled = enabled
        lock.unlock()
    }

    func nextDrawable() -> CAMetalDrawable? {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled, layer.device != nil else { return nil }
        return layer.nextDrawable()
    }
}
