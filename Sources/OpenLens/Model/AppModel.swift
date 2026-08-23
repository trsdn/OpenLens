import AVFoundation
import Combine
import Foundation
import os.log

/// Coordinates capture, rendering, the system extension and persisted scenes.
///
/// All published state lives on the main actor; the per-frame work happens in
/// `FramePipeline`, which this class only configures.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var devices: [CaptureDeviceInfo] = []
    @Published private(set) var cameraAuthorized = false
    @Published var errorMessage: String?
    @Published private(set) var effectiveZoom: CGFloat = 1
    @Published private(set) var losslessZoomLimit: CGFloat = 1
    @Published private(set) var isReceivingFrames = false
    /// What the camera is really handing over, which is not always what it advertises.
    @Published private(set) var sourceSummary = ""

    @Published private(set) var previewVisible = true
    /// User-facing switch, independent of whether the window happens to be
    /// visible. Turning the preview off skips a whole render pass per frame, and
    /// when nothing is streaming either it stops the capture session outright.
    @Published var previewEnabled = true {
        didSet {
            guard previewEnabled != oldValue else { return }
            UserDefaults.standard.set(previewEnabled, forKey: Self.previewEnabledKey)
            applyPreviewState()
        }
    }

    private static let previewEnabledKey = "preview.enabled.v1"

    let scenes = SceneStore()
    let installer = SystemExtensionInstaller()
    let extensionClient = ExtensionClient()
    let lights = LightController()

    private let capture = CaptureEngine()
    private var pipeline: FramePipeline?
    private let log = Logger(subsystem: OpenLensID.appBundleID, category: "model")
    private var cancellables = Set<AnyCancellable>()
    private var lastFrameActivity = Date.distantPast
    private var healthTimer: Timer?
    /// Video work is latency sensitive and mostly happens while the window is in
    /// the background, which is exactly when App Nap would otherwise throttle
    /// timers and delay the switch into streaming by several seconds.
    private var activity: NSObjectProtocol?
    private let hotKeys = GlobalHotKeys()
    private var persistWork: DispatchWorkItem?

    var isReady: Bool { pipeline != nil }

    init() {
        if UserDefaults.standard.object(forKey: Self.previewEnabledKey) != nil {
            previewEnabled = UserDefaults.standard.bool(forKey: Self.previewEnabledKey)
        }
        do {
            let renderer = try VideoRenderer()
            let pipeline = FramePipeline(renderer: renderer, extensionClient: extensionClient)
            pipeline.onFrameActivity = { [weak self] in
                Task { @MainActor in self?.noteFrameActivity() }
            }
            pipeline.onCaptureError = { [weak self] error in
                Task { @MainActor in self?.errorMessage = error.errorDescription }
            }
            capture.delegate = pipeline
            self.pipeline = pipeline
        } catch {
            errorMessage = "Metal is unavailable: \(error.localizedDescription)"
        }

        extensionClient.$isStreaming
            .removeDuplicates()
            .sink { [weak self] streaming in self?.reconcilePipeline(streaming: streaming) }
            .store(in: &cancellables)

        scenes.$selectedSceneID
            .removeDuplicates()
            .sink { [weak self] _ in self?.applySelectedScene(animated: true) }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: AVCaptureDevice.wasConnectedNotification)
            .merge(with: NotificationCenter.default.publisher(
                for: AVCaptureDevice.wasDisconnectedNotification
            ))
            .sink { [weak self] _ in
                self?.refreshDevices()
                self?.extensionClient.rediscover()
            }
            .store(in: &cancellables)

        healthTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateFrameHealth() }
        }
    }

    // MARK: - Lifecycle

    func start() async {
        cameraAuthorized = await CaptureEngine.requestAccess()
        if !cameraAuthorized {
            errorMessage = CaptureError.permissionDenied.errorDescription
        }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Driving the OpenLens virtual camera"
        )
        hotKeys.onSelect = { [weak self] index in self?.selectScene(at: index) }
        hotKeys.register()
        refreshDevices()
        installer.activate()
        extensionClient.connect()
        reloadOverlay()
        lights.start()

        if scenes.scenes.isEmpty, let first = devices.first {
            scenes.addScene(device: first)
        }
        applySelectedScene(animated: false)
        reconcilePipeline()
    }

    func shutdown() {
        capture.stop()
        extensionClient.shutdown()
        hotKeys.unregister()
        healthTimer?.invalidate()
        lights.stop()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    func refreshDevices() {
        // Never offer our own virtual camera as a source: selecting it would feed
        // the extension's output straight back into its input.
        devices = CaptureEngine.availableDevices().filter {
            $0.name != OpenLensID.deviceName
                && !$0.id.contains(OpenLensID.deviceUUID.uuidString)
        }
    }

    // MARK: - Preview

    func attachPreview(_ target: PreviewRenderTarget) {
        pipeline?.setPreviewTarget(target)
    }

    func detachPreview() {
        pipeline?.setPreviewTarget(nil)
    }

    func setPreviewVisible(_ visible: Bool) {
        previewVisible = visible
        applyPreviewState()
    }

    /// The preview only renders when the user wants it *and* the window is
    /// actually on screen.
    private func applyPreviewState() {
        let wants = previewEnabled && previewVisible
        pipeline?.update { $0.wantsPreview = wants }
        reconcilePipeline()
    }

    // MARK: - Scenes

    private func applySelectedScene(animated: Bool) {
        guard let scene = scenes.selectedScene else {
            capture.stop()
            return
        }
        let switchingCamera = capture.currentDeviceID != scene.deviceID
        pipeline?.update {
            $0.target = scene.crop
            $0.mirror = scene.mirrored
            $0.overlayEnabled = scene.overlayEnabled
            $0.overlayRect = scene.overlayRect
            $0.overlayOpacity = scene.overlayOpacity
            $0.adjustments = scene.adjustments
        }
        // Gliding a crop across a camera change looks like a glitch, so only
        // scenes on the same camera animate.
        if !animated || switchingCamera {
            pipeline?.snapCrop(to: scene.crop)
        }
        capture.start(deviceID: scene.deviceID, quality: scene.quality)
        updateZoomReadout()
        // Deliberately last and deliberately fire-and-forget: an unreachable
        // lamp must not delay the picture coming back.
        lights.apply(scene.lighting)
    }

    func selectScene(at index: Int) {
        scenes.selectScene(at: index)
    }

    func select(_ scene: CameraScene) {
        scenes.select(scene)
    }

    func addScene() {
        guard let device = devices.first else { return }
        scenes.addScene(device: device)
        applySelectedScene(animated: false)
    }

    func duplicateSelectedScene() {
        scenes.duplicateSelected()
    }

    func removeSelectedScene() {
        guard let scene = scenes.selectedScene else { return }
        scenes.remove(scene)
        applySelectedScene(animated: false)
    }

    func renameSelectedScene(_ name: String) {
        scenes.mutateSelected { $0.name = name }
        scenes.save()
    }

    func setDevice(_ device: CaptureDeviceInfo) {
        scenes.mutateSelected {
            $0.deviceID = device.id
            $0.deviceName = device.name
        }
        scenes.save()
        capture.stop()
        applySelectedScene(animated: false)
    }

    func setQuality(_ quality: CaptureQuality) {
        scenes.mutateSelected { $0.quality = quality }
        scenes.save()
        capture.stop()
        applySelectedScene(animated: false)
    }

    func setMirrored(_ mirrored: Bool) {
        scenes.mutateSelected { $0.mirrored = mirrored }
        scenes.save()
        pipeline?.update { $0.mirror = mirrored }
    }

    // MARK: - Zoom

    func zoom(to zoom: CGFloat, anchor: CGPoint) {
        guard let settings = pipeline?.currentSettings() else { return }
        commitCrop(
            CropGeometry.zooming(
                settings.target,
                to: zoom,
                anchor: anchor,
                sourceAspect: settings.sourceAspect,
                outputAspect: CGFloat(OpenLensOutput.aspectRatio)
            )
        )
    }

    func zoomBy(factor: CGFloat, anchor: CGPoint) {
        guard let settings = pipeline?.currentSettings() else { return }
        zoom(to: settings.target.zoom * factor, anchor: anchor)
    }

    /// `delta` is in normalized source units.
    func pan(by delta: CGSize) {
        guard let settings = pipeline?.currentSettings() else { return }
        commitCrop(
            CropGeometry.panning(
                settings.target,
                by: delta,
                sourceAspect: settings.sourceAspect,
                outputAspect: CGFloat(OpenLensOutput.aspectRatio)
            )
        )
    }

    /// Zooms around the middle of the current crop, which is what every explicit
    /// control (slider, menu item, keyboard) should do — only the scroll wheel
    /// zooms around the cursor.
    func setZoom(_ value: CGFloat) {
        guard let settings = pipeline?.currentSettings() else { return }
        let rect = CropGeometry.rect(
            for: settings.target,
            sourceAspect: settings.sourceAspect,
            outputAspect: CGFloat(OpenLensOutput.aspectRatio)
        )
        zoom(to: value, anchor: CGPoint(x: rect.midX, y: rect.midY))
        schedulePersist()
    }

    func zoomIn() { stepZoom(by: 1) }

    func zoomOut() { stepZoom(by: -1) }

    /// Fixed 0.1 steps, snapped to the 0.1 grid so repeated presses land on round
    /// numbers even when a scroll gesture left the zoom at, say, 1.37×.
    private func stepZoom(by direction: CGFloat) {
        let current = pipeline?.currentSettings().target.zoom ?? 1
        let index = current / Self.zoomStep
        // The nudge absorbs binary-float error: 1.2 / 0.1 is 11.999…, which would
        // otherwise round down to 11 and make "zoom in" a no-op.
        let rounded = direction > 0
            ? (index + 1e-6).rounded(.down) + 1
            : (index - 1e-6).rounded(.up) - 1
        setZoom(rounded * Self.zoomStep)
    }

    static let zoomStep: CGFloat = 0.1

    func resetZoom() {
        commitCrop(.identity)
        persistCrop()
    }

    /// Called when a gesture ends, so a continuous drag does not hit
    /// `UserDefaults` on every frame.
    func persistCrop() {
        persistWork?.cancel()
        persistWork = nil
        scenes.save()
    }

    /// Scroll wheels have no reliable "gesture ended" for every input device, so
    /// continuous zooming coalesces its writes instead.
    func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scenes.save()
            self?.persistWork = nil
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    var currentCropRect: CGRect {
        guard let settings = pipeline?.currentSettings() else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CropGeometry.rect(
            for: settings.target,
            sourceAspect: settings.sourceAspect,
            outputAspect: CGFloat(OpenLensOutput.aspectRatio)
        )
    }

    private func commitCrop(_ state: CropState) {
        pipeline?.update { $0.target = state }
        scenes.mutateSelected { $0.crop = state }
        updateZoomReadout()
    }

    private func updateZoomReadout() {
        effectiveZoom = pipeline?.currentSettings().target.zoom ?? 1
        losslessZoomLimit = CropGeometry.losslessZoomLimit(
            sourcePixelSize: capture.sourcePixelSize,
            outputPixelSize: CGSize(width: OpenLensOutput.width, height: OpenLensOutput.height)
        )
    }

    // MARK: - Overlay

    func chooseOverlay(url: URL?) {
        scenes.setOverlay(url: url)
        reloadOverlay()
    }

    func setOverlayEnabled(_ enabled: Bool) {
        scenes.mutateSelected { $0.overlayEnabled = enabled }
        scenes.save()
        pipeline?.update { $0.overlayEnabled = enabled }
    }

    func setOverlayRect(_ rect: CGRect) {
        scenes.mutateSelected { $0.overlayRect = rect }
        pipeline?.update { $0.overlayRect = rect }
    }

    /// Called while the overlay is dragged in the preview. The pipeline sees
    /// every step, the disk write waits for `commitOverlayRect` so a drag does
    /// not serialise every scene sixty times a second.
    func moveOverlay(by delta: CGSize) {
        guard let rect = scenes.selectedScene?.overlayRect else { return }
        setOverlayRect(OverlayGeometry.moved(rect, by: delta))
    }

    func resizeOverlay(corner: OverlayCorner, to point: CGPoint) {
        guard let rect = scenes.selectedScene?.overlayRect else { return }
        setOverlayRect(OverlayGeometry.resized(rect, corner: corner, to: point))
    }

    func commitOverlayRect() {
        scenes.save()
    }

    /// Back to a quarter of the frame width, keeping the position and the
    /// image's aspect ratio.
    func resetOverlaySize() {
        guard let rect = scenes.selectedScene?.overlayRect else { return }
        setOverlayRect(OverlayGeometry.scaled(rect, toWidth: 0.24))
        commitOverlayRect()
    }

    func setOverlayOpacity(_ opacity: Double) {
        scenes.mutateSelected { $0.overlayOpacity = opacity }
        pipeline?.update { $0.overlayOpacity = opacity }
    }

    // MARK: - Image adjustments

    var adjustments: ImageAdjustments { scenes.selectedScene?.adjustments ?? .neutral }

    /// Called continuously while a slider is dragged: the pipeline is updated
    /// every time, but the write to disk is deferred to `commitAdjustments` so a
    /// drag does not serialise every scene sixty times a second.
    func setAdjustments(_ adjustments: ImageAdjustments) {
        scenes.mutateSelected { $0.adjustments = adjustments }
        pipeline?.update { $0.adjustments = adjustments }
    }

    func commitAdjustments() {
        scenes.save()
    }

    func resetAdjustments() {
        setAdjustments(.neutral)
        commitAdjustments()
    }

    // MARK: - Scene lighting

    var sceneLighting: SceneLighting { scenes.selectedScene?.lighting ?? .off }

    /// Records what the lamps are doing now as part of the scene, so switching
    /// to it later restores the light along with the crop.
    func captureLightingIntoScene() {
        scenes.mutateSelected { $0.lighting = lights.snapshot() }
        scenes.save()
    }

    func clearLightingFromScene() {
        scenes.mutateSelected { $0.lighting = .off }
        scenes.save()
    }

    private func reloadOverlay() {
        guard let pipeline else { return }
        guard let url = scenes.overlayURL else {
            pipeline.setOverlay(nil)
            return
        }
        do {
            let rect = scenes.selectedScene?.overlayRect ?? .zero
            let pixelSize = try pipeline.loadOverlay(
                url: url,
                rect: rect,
                opacity: scenes.selectedScene?.overlayOpacity ?? 1
            )
            // Idempotent: a rect that already matches the image comes back
            // unchanged, so running this on every load costs nothing and stops
            // a stale scene from displaying a stretched logo forever.
            let fitted = OverlayGeometry.fitted(
                rect,
                pixelSize: pixelSize,
                outputAspect: CGFloat(OpenLensOutput.aspectRatio)
            )
            if fitted != rect {
                setOverlayRect(fitted)
                scenes.save()
            }
        } catch {
            errorMessage = "Could not load the overlay image."
        }
    }

    // MARK: - Gating

    /// The capture session only runs when someone will actually see the result:
    /// either a conferencing app has the virtual camera open, or our window is
    /// on screen. Idle cost is then genuinely zero.
    /// `@Published` sends its value from `willSet`, so a subscriber that re-reads
    /// `extensionClient.isStreaming` sees the *previous* value and would undo the
    /// change it was notified about. The new value is therefore passed in.
    private func reconcilePipeline(streaming streamingOverride: Bool? = nil) {
        let streaming = streamingOverride ?? extensionClient.isStreaming
        pipeline?.update { $0.wantsOutput = streaming }

        if streaming || (previewVisible && previewEnabled) {
            if let scene = scenes.selectedScene {
                capture.start(deviceID: scene.deviceID, quality: scene.quality)
            }
        } else {
            capture.stop()
        }
    }

    private func noteFrameActivity() {
        lastFrameActivity = Date()
        if !isReceivingFrames { isReceivingFrames = true }
    }

    private func updateFrameHealth() {
        isReceivingFrames = Date().timeIntervalSince(lastFrameActivity) < 2.5
        updateSourceSummary()
    }

    private func updateSourceSummary() {
        let size = capture.sourcePixelSize
        guard isReceivingFrames, size.width > 0 else {
            if !sourceSummary.isEmpty { sourceSummary = "" }
            return
        }
        let rate = capture.sourceFrameRate
        let summary = rate > 0
            ? String(format: "%d × %d · %.0f fps", Int(size.width), Int(size.height), rate)
            : String(format: "%d × %d", Int(size.width), Int(size.height))
        if summary != sourceSummary { sourceSummary = summary }
    }
}
