import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOSurface
import os.log

/// Forwards frames to the CMIO source stream.
///
/// Two sources feed it: the app (through the sink stream) and, whenever the app
/// is absent or stalled, a prerendered placeholder so that conferencing apps
/// never see a frozen or black camera.
final class FrameRelay {
    weak var stream: CMIOExtensionStream?

    private let queue = DispatchQueue(label: "com.trsdn.openlens.relay", qos: .userInteractive)
    private var idleTimer: DispatchSourceTimer?
    private var isStreaming = false
    private var lastAppFrameHostTime: UInt64 = 0
    private var formatDescription: CMFormatDescription?
    private var formatDimensions = CMVideoDimensions(width: 0, height: 0)
    private lazy var idlePixelBuffer: CVPixelBuffer? = IdleFrameRenderer.makePlaceholder()

    /// Answers the app when it launches mid-call and needs the current state.
    private lazy var queryResponder: DarwinObserver = StreamingStateChannel.answerQueries {
        [weak self] in self?.queue.sync { self?.isStreaming ?? false } ?? false
    }

    /// If the app goes this long without delivering a frame we fall back to the
    /// placeholder rather than letting the consumer's picture freeze.
    private let appFrameTimeout: UInt64 = 500_000_000

    // MARK: - Streaming lifecycle

    /// Registers the state responder. Called once at extension start-up so the
    /// app gets an answer even if it launches before anything streams.
    func activate() {
        _ = queryResponder
    }

    func startStreaming() {
        queue.async {
            guard !self.isStreaming else { return }
            self.isStreaming = true
            self.startIdleTimer()
            StreamingStateChannel.publish(true)
        }
    }

    func stopStreaming() {
        queue.async {
            guard self.isStreaming else { return }
            self.isStreaming = false
            self.stopIdleTimer()
            StreamingStateChannel.publish(false)
        }
    }

    // MARK: - App frames

    /// Forwards a buffer that arrived on the sink stream. The image buffer is
    /// reused as-is, so nothing is copied on this path.
    func submit(sampleBuffer: CMSampleBuffer, hostTimeNanos: UInt64) {
        queue.async {
            guard self.isStreaming else { return }
            let timestamp = hostTimeNanos == 0 ? FrameRelay.hostTimeNanos() : hostTimeNanos
            self.lastAppFrameHostTime = timestamp
            guard let stream = self.stream else { return }
            stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: timestamp)
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
