import AVFoundation
import Foundation
import os.log

/// How much source resolution to ask the camera for.
///
/// Capturing above the output resolution is what buys lossless zoom: a 4K source
/// feeding a 1080p output can crop to 2x with no upscaling at all. It costs USB
/// bandwidth and a little power, so it is a deliberate choice per device.
enum CaptureQuality: String, Codable, CaseIterable, Sendable {
    /// Cheapest. Any zoom past 1x softens the picture.
    case matchOutput
    /// Up to 4K, giving roughly 2x of lossless zoom at a 1080p output.
    case losslessZoom

    var maxPixelCount: Int {
        switch self {
        case .matchOutput: return 1920 * 1080
        case .losslessZoom: return 3840 * 2160
        }
    }

    var title: String {
        switch self {
        case .matchOutput: return "Match output (1080p)"
        case .losslessZoom: return "High (up to 4K, lossless zoom)"
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
        guard applyConfiguration(device: device, deviceID: deviceID, quality: quality) else {
            return
        }

        if !session.isRunning {
            session.startRunning()
        }
    }

    private func applyConfiguration(
        device: AVCaptureDevice,
        deviceID: String,
        quality: CaptureQuality
    ) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }

        guard let format = Self.bestFormat(for: device, maxPixelCount: quality.maxPixelCount)
        else {
            delegate?.captureEngine(self, didFailWith: .noUsableFormat(device.localizedName))
            return false
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                delegate?.captureEngine(self, didFailWith: .deviceInUse(device.localizedName))
                return false
            }
            session.addInput(input)
            currentInput = input
        } catch {
            log.error("Input creation failed: \(error.localizedDescription, privacy: .public)")
            delegate?.captureEngine(self, didFailWith: .deviceInUse(device.localizedName))
            return false
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let targetDuration = CMTime(
                value: 1,
                timescale: CMTimeScale(OpenLensOutput.frameRate)
            )
            if let range = format.videoSupportedFrameRateRanges.first,
               targetDuration >= range.minFrameDuration,
               targetDuration <= range.maxFrameDuration {
                device.activeVideoMinFrameDuration = targetDuration
                device.activeVideoMaxFrameDuration = targetDuration
            }
            device.unlockForConfiguration()
        } catch {
            log.error("Format lock failed: \(error.localizedDescription, privacy: .public)")
        }

        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }
        output.videoSettings = Self.preferredVideoSettings(for: output)

        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        sourcePixelSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        currentDeviceID = deviceID

        log.info(
            """
            Capturing \(device.localizedName, privacy: .public) at \
            \(dimensions.width)x\(dimensions.height)
            """
        )
        return true
    }

    // MARK: - Format selection

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

            let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let uncompressed: Set<FourCharCode> = [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_422YpCbCr8,
                kCVPixelFormatType_32BGRA
            ]
            let decodePenalty = uncompressed.contains(subType) ? 1 : 0
            let fps = Int(format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            return (pixels, decodePenalty, fps)
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
    private static func preferredVideoSettings(
        for output: AVCaptureVideoDataOutput
    ) -> [String: Any] {
        let available = output.availableVideoPixelFormatTypes
        let preference: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA
        ]
        let chosen = preference.first(where: { available.contains($0) })
            ?? kCVPixelFormatType_32BGRA
        return [kCVPixelBufferPixelFormatTypeKey as String: chosen]
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        delegate?.captureEngine(self, didOutput: pixelBuffer)
    }
}
