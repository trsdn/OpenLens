import CoreMedia
import CoreMediaIO
import QuartzCore
import CoreVideo
import Foundation
import os.log

/// The app's end of the frame transport.
///
/// A CoreMediaIO extension cannot vend a private XPC service, so frames travel
/// the way Apple intends: the extension publishes a *sink* stream alongside the
/// camera, and the app enqueues buffers into that stream's simple queue. The
/// buffers stay IOSurface-backed the whole way, so a 1080p frame costs a queue
/// entry rather than 8 MB of copying.
final class ExtensionClient: NSObject, ObservableObject {
    /// True while a conferencing app actually has the virtual camera open. The
    /// capture pipeline idles otherwise, which is the largest single power win.
    @Published private(set) var isStreaming = false
    @Published private(set) var isConnected = false

    /// True once the search has failed for long enough that waiting is no longer
    /// a plausible fix. Replacing the extension underneath a running app kills
    /// this process's CoreMediaIO client state permanently — a fresh process sees
    /// the camera immediately, this one never will — so the UI has to offer a
    /// restart instead of spinning forever.
    @Published private(set) var isStalled = false

    /// Fires on the client's own queue as soon as the extension reports a
    /// change. The frame pipeline uses this instead of the `@Published`
    /// property so that starting to stream never waits on the main thread.
    var onStreamingChanged: (@Sendable (Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.trsdn.openlens.sink", qos: .userInteractive)
    private let log = Logger(subsystem: OpenLensID.appBundleID, category: "sink")

    private var deviceID: CMIOObjectID = 0
    private var sinkStreamID: CMIOObjectID = 0
    private var bufferQueue: CMSimpleQueue?
    private var isSinkRunning = false
    private var isShuttingDown = false
    private var stateObserver: DarwinObserver?
    private var retryDelay: TimeInterval = 0.5
    private var lastFailureLog: CFTimeInterval = 0
    private var searchStartedAt: CFTimeInterval?

    /// How long the search may fail before the UI stops promising a connection.
    /// The extension is demand-launched, so a few seconds of "not there yet" is
    /// normal; a quarter of a minute is not.
    private static let stallThreshold: CFTimeInterval = 12

    // MARK: - Lifecycle

    func connect() {
        observeDeviceList()
        stateObserver = StreamingStateChannel.observe(queue: queue) { [weak self] streaming in
            guard let self else { return }
            self.onStreamingChanged?(streaming)
            DispatchQueue.main.async { self.isStreaming = streaming }
        }
        queue.async { [weak self] in self?.locateDevice() }
    }

    func shutdown() {
        queue.sync {
            isShuttingDown = true
            stopSink()
            StreamingStateChannel.cancel(stateObserver)
            stateObserver = nil
        }
    }

    /// CoreMediaIO only refreshes a client's device list while that client is
    /// listening for changes. Without this, the app keeps handing out object IDs
    /// that belonged to a previous run of the extension, and every call fails
    /// with `kCMIOHardwareBadStreamError`.
    private func observeDeviceList() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let status = CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            queue
        ) { [weak self] _, _ in
            guard let self else { return }
            self.stopSink()
            self.locateDevice()
        }
        if status != noErr {
            log.error("Device list listener failed: \(status)")
        }
    }

    /// Forces a fresh look for the virtual camera.
    ///
    /// Replacing the extension (an app update, or a reinstall) tears down the
    /// device behind the app's back and every cached CoreMediaIO object ID dies
    /// with it. AVFoundation notices the device coming and going, so the model
    /// drives this from those notifications.
    func rediscover() {
        queue.async { [weak self] in
            guard let self, !self.isShuttingDown else { return }
            self.stopSink()
            self.retryDelay = 0.5
            self.locateDevice()
        }
    }

    private func locateDevice() {
        guard !isShuttingDown, deviceID == 0 else { return }

        if let found = Self.findOpenLensDevice() {
            deviceID = found.device
            sinkStreamID = found.sink
            retryDelay = 0.5
            searchStartedAt = nil
            log.info("Found virtual camera \(found.device), sink stream \(found.sink)")
            DispatchQueue.main.async {
                self.isConnected = true
                self.isStalled = false
            }
            // Opening the sink now pins the extension process for as long as the
            // app runs. CoreMediaIO object IDs only stay valid while the
            // extension lives, so this removes an entire class of races.
            startSinkIfNeeded()
            return
        }

        // The extension is demand-launched, so "not there yet" is the normal
        // first answer right after an install.
        let now = CACurrentMediaTime()
        let startedAt = searchStartedAt ?? now
        searchStartedAt = startedAt
        let stalled = now - startedAt >= Self.stallThreshold
        if stalled {
            log.error("Virtual camera still not found after \(Int(now - startedAt))s")
        }
        DispatchQueue.main.async {
            self.isConnected = false
            self.isStalled = stalled
        }
        let delay = retryDelay
        retryDelay = min(delay * 2, 10)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.locateDevice() }
    }

    // MARK: - Sink stream

    private func startSinkIfNeeded() {
        guard !isSinkRunning, !isShuttingDown else { return }

        // CoreMediaIO object IDs are only valid until the extension restarts, and
        // during development that happens on every install. Resolving them here
        // rather than caching them at launch keeps the app self-healing.
        if deviceID == 0 || sinkStreamID == 0 {
            guard let found = Self.findOpenLensDevice() else {
                reportFailure("Virtual camera device not found")
                return
            }
            deviceID = found.device
            sinkStreamID = found.sink
            log.info("Resolved device \(found.device), sink stream \(found.sink)")
        }

        var queueRef: Unmanaged<CMSimpleQueue>?
        // A nil altered-proc returns noErr but hands back no queue, so the
        // callback is required even though there is nothing to do in it: the
        // send path already checks the queue's fullness before enqueuing.
        let copyStatus = CMIOStreamCopyBufferQueue(
            sinkStreamID,
            { _, _, _ in },
            nil,
            &queueRef
        )
        guard copyStatus == noErr, let queueRef else {
            reportFailure("CMIOStreamCopyBufferQueue failed: \(copyStatus)")
            invalidateIDs()
            return
        }
        bufferQueue = queueRef.takeRetainedValue()

        let startStatus = CMIODeviceStartStream(deviceID, sinkStreamID)
        guard startStatus == noErr else {
            reportFailure("CMIODeviceStartStream failed: \(startStatus)")
            bufferQueue = nil
            invalidateIDs()
            return
        }
        isSinkRunning = true
        log.info("Sink stream running (device \(self.deviceID), stream \(self.sinkStreamID))")
    }

    private func invalidateIDs() {
        deviceID = 0
        sinkStreamID = 0
    }

    /// The send path runs at frame rate, so failures are logged at most once a
    /// second rather than thirty times.
    private func reportFailure(_ message: String) {
        let now = CACurrentMediaTime()
        guard now - lastFailureLog > 1 else { return }
        lastFailureLog = now
        log.error("\(message, privacy: .public)")
    }

    private func stopSink() {
        guard isSinkRunning else {
            invalidateIDs()
            return
        }
        CMIODeviceStopStream(deviceID, sinkStreamID)
        bufferQueue = nil
        isSinkRunning = false
        invalidateIDs()
        log.info("Sink stream stopped")
    }

    /// Hands one rendered frame to the extension.
    func send(pixelBuffer: CVPixelBuffer, hostTimeNanos: UInt64) {
        queue.async { [weak self] in
            guard let self, !self.isShuttingDown else { return }
            self.startSinkIfNeeded()
            guard let bufferQueue = self.bufferQueue else { return }

            // Dropping the newest frame under back-pressure is better than
            // queueing latency into a live call.
            guard CMSimpleQueueGetCount(bufferQueue) < CMSimpleQueueGetCapacity(bufferQueue) else {
                self.reportFailure("Sink queue full, dropping frame")
                return
            }
            guard let sampleBuffer = Self.makeSampleBuffer(
                pixelBuffer: pixelBuffer,
                hostTimeNanos: hostTimeNanos
            ) else { return }

            let status = CMSimpleQueueEnqueue(
                bufferQueue,
                element: Unmanaged.passRetained(sampleBuffer).toOpaque()
            )
            if status != noErr {
                Unmanaged.passUnretained(sampleBuffer).release()
                self.log.error("Enqueue failed: \(status)")
            }
        }
    }

    private static func makeSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        hostTimeNanos: UInt64
    ) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(OpenLensOutput.frameRate)),
            presentationTimeStamp: CMTime(
                value: CMTimeValue(hostTimeNanos),
                timescale: CMTimeScale(NSEC_PER_SEC)
            ),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: - CoreMediaIO discovery

    private static func findOpenLensDevice() -> (device: CMIOObjectID, sink: CMIOObjectID)? {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        for device in objectIDs(of: system, selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)) {
            guard string(of: device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID))
                == OpenLensID.deviceUUID.uuidString else { continue }

            let streams = objectIDs(of: device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
            // Streams are added source-first, but match on the name so a future
            // reordering cannot silently start feeding the wrong stream.
            let sink = streams.first {
                string(of: $0, selector: CMIOObjectPropertySelector(kCMIOObjectPropertyName)) == OpenLensID.sinkStreamName
            } ?? (streams.count > 1 ? streams[1] : nil)

            if let sink { return (device, sink) }
        }
        return nil
    }

    private static func objectIDs(
        of object: CMIOObjectID,
        selector: CMIOObjectPropertySelector
    ) -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { buffer in
            CMIOObjectGetPropertyData(
                object, &address, 0, nil, dataSize, &dataUsed, buffer.baseAddress
            )
        }
        guard status == noErr else { return [] }
        return ids
    }

    private static func string(
        of object: CMIOObjectID,
        selector: CMIOObjectPropertySelector
    ) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataUsed: UInt32 = 0
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            CMIOObjectGetPropertyData(
                object,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Unmanaged<CFString>?>.size),
                &dataUsed,
                pointer
            )
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
