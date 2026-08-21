import CoreMediaIO
import CoreVideo
import Foundation
import IOSurface
import os.log

/// Forwards frames to the CMIO stream.
///
/// Two sources feed it: the app (over XPC, zero-copy IOSurfaces) and, whenever
/// the app is absent or stalled, a prerendered placeholder so that conferencing
/// apps never see a frozen or black camera.
final class FrameRelay {
    weak var stream: CMIOExtensionStream?

    private let queue = DispatchQueue(label: "com.trsdn.openlens.relay", qos: .userInteractive)
    private var idleTimer: DispatchSourceTimer?
    private var isStreaming = false
    private var lastAppFrameHostTime: UInt64 = 0
    private var formatDescription: CMFormatDescription?
    private var formatDimensions = CMVideoDimensions(width: 0, height: 0)
    private lazy var idlePixelBuffer: CVPixelBuffer? = IdleFrameRenderer.makePlaceholder()

    /// If the app goes this long without delivering a frame we fall back to the
    /// placeholder rather than letting the consumer's picture freeze.
    private let appFrameTimeout: UInt64 = 500_000_000

    private var streamingObservers: [UUID: (Bool) -> Void] = [:]

    // MARK: - Streaming lifecycle

    func startStreaming() {
        queue.async {
            guard !self.isStreaming else { return }
            self.isStreaming = true
            self.startIdleTimer()
            self.notifyObservers(true)
        }
    }

    func stopStreaming() {
        queue.async {
            guard self.isStreaming else { return }
            self.isStreaming = false
            self.stopIdleTimer()
            self.notifyObservers(false)
        }
    }

    func currentStreamingState(_ completion: @escaping (Bool) -> Void) {
        queue.async { completion(self.isStreaming) }
    }

    func addStreamingObserver(_ observer: @escaping (Bool) -> Void) -> UUID {
        let token = UUID()
        queue.async {
            self.streamingObservers[token] = observer
            observer(self.isStreaming)
        }
        return token
    }

    func removeStreamingObserver(_ token: UUID) {
        queue.async { self.streamingObservers.removeValue(forKey: token) }
    }

    private func notifyObservers(_ streaming: Bool) {
        for observer in streamingObservers.values { observer(streaming) }
    }

    // MARK: - App frames

    func submit(surface: IOSurface, hostTimeNanos: UInt64) {
        queue.async {
            guard self.isStreaming else { return }
            self.lastAppFrameHostTime = hostTimeNanos

            var unmanaged: Unmanaged<CVPixelBuffer>?
            let status = CVPixelBufferCreateWithIOSurface(
                kCFAllocatorDefault,
                surface as IOSurfaceRef,
                nil,
                &unmanaged
            )
            guard status == kCVReturnSuccess, let pixelBuffer = unmanaged?.takeRetainedValue()
            else {
                logger.error("CVPixelBufferCreateWithIOSurface failed: \(status)")
                return
            }
            self.send(pixelBuffer, hostTimeNanos: hostTimeNanos)
        }
    }

    func appDisconnected() {
        queue.async { self.lastAppFrameHostTime = 0 }
    }

    // MARK: - Idle placeholder

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(OpenLensOutput.frameRate)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.emitIdleFrameIfNeeded() }
        timer.resume()
        idleTimer = timer
    }

    private func stopIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func emitIdleFrameIfNeeded() {
        let now = FrameRelay.hostTimeNanos()
        if lastAppFrameHostTime != 0, now &- lastAppFrameHostTime < appFrameTimeout {
            return
        }
        guard let idlePixelBuffer else { return }
        send(idlePixelBuffer, hostTimeNanos: now)
    }

    // MARK: - Sending

    private func send(_ pixelBuffer: CVPixelBuffer, hostTimeNanos: UInt64) {
        guard let stream else { return }

        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if formatDescription == nil
            || formatDimensions.width != width
            || formatDimensions.height != height {
            var description: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description
            )
            guard status == noErr, let description else {
                logger.error("Format description creation failed: \(status)")
                return
            }
            formatDescription = description
            formatDimensions = CMVideoDimensions(width: width, height: height)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(OpenLensOutput.frameRate)),
            presentationTimeStamp: CMTime(
                value: CMTimeValue(hostTimeNanos),
                timescale: CMTimeScale(NSEC_PER_SEC)
            ),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription!,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            logger.error("CMSampleBuffer creation failed: \(status)")
            return
        }

        stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostTimeNanos)
    }

    static func hostTimeNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}
