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
        }
        // Gliding a crop across a camera change looks like a glitch, so only
        // scenes on the same camera animate.
        if !animated || switchingCamera {
            pipeline?.snapCrop(to: scene.crop)
        }
        capture.start(deviceID: scene.deviceID, quality: scene.quality)
        updateZoomReadout()
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

    func setOverlayOpacity(_ opacity: Double) {
        scenes.mutateSelected { $0.overlayOpacity = opacity }
        pipeline?.update { $0.overlayOpacity = opacity }
    }

    private func reloadOverlay() {
        guard let pipeline else { return }
        guard let url = scenes.overlayURL else {
            pipeline.setOverlay(nil)
            return
        }
        do {
            try pipeline.loadOverlay(
                url: url,
                rect: scenes.selectedScene?.overlayRect ?? .zero,
                opacity: scenes.selectedScene?.overlayOpacity ?? 1
            )
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
    }
}
