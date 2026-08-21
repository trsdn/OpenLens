import AVFoundation
import Foundation
import QuartzCore
import os.log

/// How much source resolution to ask the camera for.
///
/// Capturing above the output resolution is what buys lossless zoom: a 4K source
/// feeding a 1080p output can crop to 2x with no upscaling at all. It costs USB
/// bandwidth and a little power, so it is a deliberate choice per device.
enum CaptureQuality: String, Codable, CaseIterable, Sendable {
    /// Cheapest and the safest bet for smooth motion. Any zoom past 1x softens the picture.
    case matchOutput
    /// Up to 4K, giving roughly 2x of lossless zoom at a 1080p output. Uncompressed 4K can
    /// outrun the camera's USB bandwidth, in which case it arrives at well under 30 fps —
    /// the "Receiving" readout in the inspector is there to make that visible.
    case losslessZoom

    var maxPixelCount: Int {
        switch self {
        case .matchOutput: return 1920 * 1080
        case .losslessZoom: return 3840 * 2160
        }
    }

    var title: String {
        switch self {
        case .matchOutput: return "1080p (smoothest)"
        case .losslessZoom: return "Up to 4K (sharpest zoom)"
        }
    }
}

struct CaptureDeviceInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isBuiltIn: Bool
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case deviceUnavailable(String)
    case deviceInUse(String)
    case noUsableFormat(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "OpenLens does not have permission to use the camera."
        case .deviceUnavailable(let name):
            return "\(name) is no longer connected."
        case .deviceInUse(let name):
            return "\(name) is already in use by another app. Quit OBS, Detail Studio, "
                + "or your browser and try again."
        case .noUsableFormat(let name):
            return "\(name) does not offer a video format OpenLens can use."
        }
    }
}

protocol CaptureEngineDelegate: AnyObject {
    func captureEngine(_ engine: CaptureEngine, didOutput pixelBuffer: CVPixelBuffer)
    func captureEngine(_ engine: CaptureEngine, didFailWith error: CaptureError)
}

/// Owns the `AVCaptureSession` and hands raw camera buffers to the renderer.
final class CaptureEngine: NSObject {
    weak var delegate: CaptureEngineDelegate?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.trsdn.openlens.session")
    private let sampleQueue = DispatchQueue(
        label: "com.trsdn.openlens.samples",
        qos: .userInteractive
    )
    private let log = Logger(subsystem: OpenLensID.appBundleID, category: "capture")

    private var currentInput: AVCaptureDeviceInput?
    private(set) var currentDeviceID: String?
    private(set) var sourcePixelSize = CGSize.zero
    /// Frames per second actually arriving from the device. A camera can advertise 30 and
    /// still deliver far less: uncompressed 4K saturates USB long before it gets there.
    private(set) var sourceFrameRate: Double = 0
    private var rateWindowStart: CFTimeInterval = 0
    private var rateWindowCount = 0

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    // MARK: - Discovery

    static func availableDevices() -> [CaptureDeviceInfo] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if #available(macOS 14.0, *) {
            types.append(.continuityCamera)
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map {
            CaptureDeviceInfo(
                id: $0.uniqueID,
                name: $0.localizedName,
                isBuiltIn: $0.deviceType == .builtInWideAngleCamera
            )
        }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: - Lifecycle

    func start(deviceID: String, quality: CaptureQuality) {
        sessionQueue.async { [weak self] in
            self?.configure(deviceID: deviceID, quality: quality)
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            if let currentInput = self.currentInput {
                self.session.removeInput(currentInput)
                self.currentInput = nil
            }
            self.currentDeviceID = nil
        }
    }

    private func configure(deviceID: String, quality: CaptureQuality) {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            delegate?.captureEngine(self, didFailWith: .deviceUnavailable(deviceID))
            return
        }

        // Re-selecting the same device at the same quality is a no-op, which
        // makes scene switching between crops of one camera instant.
        if currentDeviceID == deviceID, session.isRunning {
            return
        }

        // startRunning() must not be called inside a configuration block, so the
        // reconfiguration is scoped to its own function and the session is only
        // started once commitConfiguration() has run.
        guard let format = applyConfiguration(device: device, deviceID: deviceID, quality: quality)
        else {
            return
        }

        if !session.isRunning {
            session.startRunning()
        }

        // The frame rate has to be pinned here, not inside the configuration block:
        // committing a fixed session preset re-applies that preset's own rate and wipes
        // anything set earlier, which is how "1080p" ended up running at 60 fps.
        do {
            try device.lockForConfiguration()
            Self.pinFrameRate(of: device, using: format)
            device.unlockForConfiguration()
        } catch {
            log.error("Frame rate lock failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyConfiguration(
        device: AVCaptureDevice,
        deviceID: String,
        quality: CaptureQuality
    ) -> AVCaptureDevice.Format? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }

        guard let format = Self.bestFormat(for: device, maxPixelCount: quality.maxPixelCount)
        else {
            delegate?.captureEngine(self, didFailWith: .noUsableFormat(device.localizedName))
            return nil
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                delegate?.captureEngine(self, didFailWith: .deviceInUse(device.localizedName))
                return nil
            }
            session.addInput(input)
            currentInput = input
        } catch {
            log.error("Input creation failed: \(error.localizedDescription, privacy: .public)")
            delegate?.captureEngine(self, didFailWith: .deviceInUse(device.localizedName))
            return nil
        }

        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }

        // The session preset outranks `activeFormat`: with the default `.high` a Cam Link 4K
        // still delivers 1080p buffers no matter which format the device reports as active.
        // The output has to be attached first, because adding one afterwards makes the session
        // renegotiate and quietly drop back to 1080p.
        let formatDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        if let preset = Self.preset(matching: formatDimensions),
           session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            Self.pinFrameRate(of: device, using: format)
            device.unlockForConfiguration()
        } catch {
            log.error("Format lock failed: \(error.localizedDescription, privacy: .public)")
        }

        output.videoSettings = Self.preferredVideoSettings(
            for: output,
            sourceSubType: CMFormatDescriptionGetMediaSubType(format.formatDescription),
            dimensions: formatDimensions
        )

        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        sourcePixelSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        sourceFrameRate = 0
        rateWindowStart = 0
        currentDeviceID = deviceID

        log.info(
            """
            Capturing \(device.localizedName, privacy: .public) at \
            \(dimensions.width)x\(dimensions.height)
            """
        )
        return format
    }

    // MARK: - Format selection

    /// The fixed-size preset matching a format, or `nil` when the size has no preset.
    /// Sizes without a preset keep whatever the session already has.
    static func preset(matching dimensions: CMVideoDimensions) -> AVCaptureSession.Preset? {
        switch (dimensions.width, dimensions.height) {
        case (3840, 2160): return .hd4K3840x2160
        case (1920, 1080): return .hd1920x1080
        case (1280, 720): return .hd1280x720
        case (960, 540): return .qHD960x540
        case (640, 480): return .vga640x480
        case (352, 288): return .cif352x288
        default: return nil
        }
    }

    /// Locks the device to the output frame rate.
    ///
    /// Cameras advertise fixed-rate ranges at odd values — a Cam Link 4K reports
    /// 60.000240 and 30.000030 fps, never a clean 30. Asking for exactly 1/30 falls
    /// outside every range, the rate stays unpinned, and a 1080p format then free-runs
    /// at its first advertised rate of 60 fps: twice the capture and render work for a
    /// 30 fps output. Snapping to the nearest supported rate at or below the target is
    /// what makes "1080p (lowest CPU)" actually the cheaper mode.
    static func pinFrameRate(of device: AVCaptureDevice, using format: AVCaptureDevice.Format) {
        let target = Double(OpenLensOutput.frameRate)
        let ranges = format.videoSupportedFrameRateRanges
        let range = ranges.filter { $0.minFrameRate <= target + 0.01 }
            .max { $0.maxFrameRate < $1.maxFrameRate }
            ?? ranges.min { $0.maxFrameRate < $1.maxFrameRate }
        guard let range else { return }

        let wanted = CMTimeMakeWithSeconds(1.0 / min(range.maxFrameRate, target), preferredTimescale: 600)
        let duration = max(range.minFrameDuration, min(range.maxFrameDuration, wanted))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    /// Picks the largest format at or below the pixel budget that can sustain the
    /// output frame rate, preferring uncompressed subtypes so no decode is needed.
    static func bestFormat(
        for device: AVCaptureDevice,
        maxPixelCount: Int
    ) -> AVCaptureDevice.Format? {
        let targetFPS = Double(OpenLensOutput.frameRate)

        func score(_ format: AVCaptureDevice.Format) -> (Int, Int, Int)? {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixels = Int(dimensions.width) * Int(dimensions.height)
            guard pixels <= maxPixelCount, pixels > 0 else { return nil }
            let reachesFPS = format.videoSupportedFrameRateRanges.contains {
                $0.maxFrameRate + 0.01 >= targetFPS
            }
            guard reachesFPS else { return nil }

            // Ranked, not just "is it uncompressed": the output asks for biplanar 420,
            // so a 422 source format costs a full-frame colour conversion on every frame.
            // A Cam Link offers both at 1080p and only 420 at 4K, which is why picking the
            // 422 one made "1080p" measurably more expensive than 4K.
            let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let subTypeRank: Int
            switch subType {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                subTypeRank = 3
            case kCVPixelFormatType_32BGRA:
                subTypeRank = 2
            case kCVPixelFormatType_422YpCbCr8:
                subTypeRank = 1
            default:
                subTypeRank = 0
            }
            // Output is always 30 fps, so a format capable of more buys nothing and only
            // costs bus bandwidth. Prefer the tamest one that still reaches the target.
            let fps = Int(format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            return (pixels, subTypeRank, -fps)
        }

        return device.formats
            .compactMap { format -> (AVCaptureDevice.Format, (Int, Int, Int))? in
                guard let value = score(format) else { return nil }
                return (format, value)
            }
            .max { lhs, rhs in lhs.1 < rhs.1 }?
            .0
            ?? device.formats.last
    }

    /// Prefers biplanar YUV, which halves the bytes crossing the bus compared to
    /// BGRA. The shader converts to RGB on the GPU for free.
    ///
    /// The dimensions are not optional: naming a pixel format without them makes
    /// AVFoundation insert a scaler that silently hands back 1080p from a 4K source,
    /// which quietly cancels the whole point of the "Up to 4K" capture quality.
    private static func preferredVideoSettings(
        for output: AVCaptureVideoDataOutput,
        sourceSubType: FourCharCode,
        dimensions: CMVideoDimensions
    ) -> [String: Any] {
        let available = output.availableVideoPixelFormatTypes
        var preference: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA
        ]
        // Asking for exactly what the device already produces skips the conversion
        // AVFoundation would otherwise run on the CPU for every single frame.
        if preference.contains(sourceSubType) {
            preference.removeAll { $0 == sourceSubType }
            preference.insert(sourceSubType, at: 0)
        }
        let chosen = preference.first(where: { available.contains($0) })
            ?? kCVPixelFormatType_32BGRA
        return [
            kCVPixelBufferPixelFormatTypeKey as String: chosen,
            kCVPixelBufferWidthKey as String: Int(dimensions.width),
            kCVPixelBufferHeightKey as String: Int(dimensions.height)
        ]
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // The session can hand back a different size than the format asked for, and the
        // "lossless up to Nx" headroom is only honest if it reflects the pixels we really get.
        let delivered = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        if delivered != sourcePixelSize {
            sourcePixelSize = delivered
            rateWindowStart = 0
        }
        measureFrameRate()
        delegate?.captureEngine(self, didOutput: pixelBuffer)
    }

    /// Averages over a one-second window, which is long enough to be steady and short
    /// enough that switching capture quality shows its real cost almost immediately.
    private func measureFrameRate() {
        let now = CACurrentMediaTime()
        if rateWindowStart == 0 {
            rateWindowStart = now
            rateWindowCount = 0
            return
        }
        rateWindowCount += 1
        let elapsed = now - rateWindowStart
        guard elapsed >= 1 else { return }
        sourceFrameRate = Double(rateWindowCount) / elapsed
        rateWindowStart = now
        rateWindowCount = 0
    }
}
