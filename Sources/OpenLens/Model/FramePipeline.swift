import CoreVideo
import Foundation
import Metal
import os.lock
import QuartzCore

/// Everything the render path needs, kept behind one lock.
struct FrameSettings {
    var target: CropState = .identity
    var mirror = false
    var overlayEnabled = false
    var overlayRect = CGRect(x: 0.72, y: 0.72, width: 0.24, height: 0.24)
    var overlayOpacity: Double = 1
    var adjustments: ImageAdjustments = .neutral
    var sourceAspect: CGFloat = 16.0 / 9.0
    var wantsOutput = false
    var wantsPreview = true
}

/// The hot path: one camera frame in, one GPU pass, out to the preview and the
/// virtual camera.
///
/// Deliberately **not** main-actor isolated. It is driven by the capture queue
/// and never blocks on the main thread, so a busy UI cannot stutter the outgoing
/// video.
final class FramePipeline: NSObject, @unchecked Sendable {
    private let renderer: VideoRenderer
    private let extensionClient: ExtensionClient

    private var lock = os_unfair_lock_s()
    private var settings = FrameSettings()
    private var animator = CropAnimator()
    private var overlay: OverlayTexture?
    private var previewTarget: PreviewRenderTarget?
    private var lastFrameTime: CFTimeInterval = 0

    /// Set by the owner to learn that frames are flowing, throttled to once a
    /// second so the UI is not woken 30 times per second for a boolean.
    var onFrameActivity: (@Sendable () -> Void)?
    var onCaptureError: (@Sendable (CaptureError) -> Void)?
    private var lastActivityReport: CFTimeInterval = 0

    var device: MTLDevice { renderer.device }

    init(renderer: VideoRenderer, extensionClient: ExtensionClient) {
        self.renderer = renderer
        self.extensionClient = extensionClient
        super.init()
        extensionClient.onStreamingChanged = { [weak self] streaming in
            self?.update { $0.wantsOutput = streaming }
        }
    }

    // MARK: - State updates (called from the main thread)

    func update(_ body: (inout FrameSettings) -> Void) {
        os_unfair_lock_lock(&lock)
        body(&settings)
        os_unfair_lock_unlock(&lock)
    }

    func currentSettings() -> FrameSettings {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return settings
    }

    /// Skips the animation, used when switching to a scene on a different camera
    /// where an animated crop would just look like a glitch.
    func snapCrop(to state: CropState) {
        os_unfair_lock_lock(&lock)
        animator.snap(to: state)
        settings.target = state
        os_unfair_lock_unlock(&lock)
    }

    func setOverlay(_ overlay: OverlayTexture?) {
        os_unfair_lock_lock(&lock)
        self.overlay = overlay
        os_unfair_lock_unlock(&lock)
    }

    func setPreviewTarget(_ target: PreviewRenderTarget?) {
        os_unfair_lock_lock(&lock)
        previewTarget = target
        os_unfair_lock_unlock(&lock)
        target?.configure(device: renderer.device)
    }

    /// Returns the image's pixel size so the caller can give the placement rect
    /// the right aspect ratio — the shader stretches the texture across the
    /// rect, so nothing else prevents a squashed logo.
    @discardableResult
    func loadOverlay(url: URL, rect: CGRect, opacity: Double) throws -> CGSize {
        let (texture, size) = try OverlayLoader.load(url: url, device: renderer.device)
        setOverlay(
            OverlayTexture(
                texture: texture,
                rect: rect,
                opacity: CGFloat(opacity),
                pixelSize: size
            )
        )
        return size
    }

    // MARK: - Hot path

    func process(pixelBuffer: CVPixelBuffer) {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard width > 0, height > 0 else { return }

        let now = CACurrentMediaTime()
        let delta = lastFrameTime == 0 ? 1.0 / 60.0 : min(now - lastFrameTime, 0.25)
        lastFrameTime = now

        os_unfair_lock_lock(&lock)
        settings.sourceAspect = width / height
        animator.target = settings.target
        let crop = animator.advance(deltaTime: delta)
        let snapshot = settings
        var frameOverlay = overlay
        let preview = previewTarget
        os_unfair_lock_unlock(&lock)

        guard snapshot.wantsOutput || snapshot.wantsPreview else { return }

        if snapshot.overlayEnabled, frameOverlay != nil {
            frameOverlay?.rect = snapshot.overlayRect
            frameOverlay?.opacity = CGFloat(snapshot.overlayOpacity)
        } else {
            frameOverlay = nil
        }

        let frame = VideoRenderer.Frame(
            pixelBuffer: pixelBuffer,
            crop: CropGeometry.rect(
                for: crop,
                sourceAspect: snapshot.sourceAspect,
                outputAspect: CGFloat(OpenLensOutput.aspectRatio)
            ),
            mirror: snapshot.mirror,
            overlay: frameOverlay,
            adjustments: snapshot.adjustments
        )

        if snapshot.wantsOutput, let output = renderer.renderToOutputBuffer(frame) {
            extensionClient.send(
                pixelBuffer: output,
                hostTimeNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            )
        }

        if snapshot.wantsPreview, let preview, let drawable = preview.nextDrawableIfIdle() {
            renderer.renderToDrawable(frame, drawable: drawable) {
                preview.drawablePresented()
            }
        }

        if now - lastActivityReport > 1 {
            lastActivityReport = now
            onFrameActivity?()
        }
    }

    /// The animation must keep running even when the camera is momentarily
    /// stalled, otherwise a scene switch freezes mid-glide.
    var isCropSettled: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return animator.isSettled
    }

    var currentCrop: CropState {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return animator.current
    }
}

extension FramePipeline: CaptureEngineDelegate {
    func captureEngine(_ engine: CaptureEngine, didOutput pixelBuffer: CVPixelBuffer) {
        process(pixelBuffer: pixelBuffer)
    }

    func captureEngine(_ engine: CaptureEngine, didFailWith error: CaptureError) {
        onCaptureError?(error)
    }
}
