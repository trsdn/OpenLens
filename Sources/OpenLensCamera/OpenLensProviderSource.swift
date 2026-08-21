import CoreMediaIO
import Foundation
import IOKit.audio
import os.log

/// Root of the extension: publishes a single virtual camera device.
final class OpenLensProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: OpenLensDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = OpenLensDeviceSource()
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            logger.error("Failed to add device: \(error.localizedDescription, privacy: .public)")
        }
        deviceSource.streamSource.relay.activate()
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "trsdn"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

final class OpenLensDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private(set) var streamSource: OpenLensStreamSource!
    private(set) var sinkSource: OpenLensSinkStreamSource!

    override init() {
        super.init()
        device = CMIOExtensionDevice(
            localizedName: OpenLensID.deviceName,
            deviceID: OpenLensID.deviceUUID,
            legacyDeviceID: OpenLensID.deviceUUID.uuidString,
            source: self
        )

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(OpenLensOutput.width),
            height: Int32(OpenLensOutput.height),
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else {
            fatalError("Unable to create the video format description")
        }

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(OpenLensOutput.frameRate))
        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: formatDescription,
            maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration,
            validFrameDurations: nil
        )

        streamSource = OpenLensStreamSource(streamFormat: streamFormat)
        // The app pushes rendered frames into the sink stream. This is the only
        // transport a sandboxed CoreMediaIO extension can offer, and it keeps the
        // frames as IOSurface-backed buffers end to end.
        sinkSource = OpenLensSinkStreamSource(
            streamFormat: streamFormat,
            relay: streamSource.relay
        )
        do {
            try device.addStream(streamSource.stream)
            try device.addStream(sinkSource.stream)
        } catch {
            fatalError("Unable to add the stream: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = OpenLensID.deviceModel
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

final class OpenLensStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let streamFormat: CMIOExtensionStreamFormat
    let relay = FrameRelay()

    init(streamFormat: CMIOExtensionStreamFormat) {
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(
            localizedName: OpenLensID.sourceStreamName,
            streamID: OpenLensID.streamUUID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
        relay.stream = stream
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex != 0 {
                logger.error("Ignoring unsupported active format index \(self.activeFormatIndex)")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration =
                CMTime(value: 1, timescale: CMTimeScale(OpenLensOutput.frameRate))
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        logger.info("Stream started")
        relay.startStreaming()
    }

    func stopStream() throws {
        logger.info("Stream stopped")
        relay.stopStreaming()
    }
}

/// The app's end of the frame transport: a sink stream the app enqueues into.
final class OpenLensSinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let streamFormat: CMIOExtensionStreamFormat
    private let relay: FrameRelay
    private let queue = DispatchQueue(label: "com.trsdn.openlens.sink", qos: .userInteractive)
    private var client: CMIOExtensionClient?
    private var isConsuming = false

    init(streamFormat: CMIOExtensionStreamFormat, relay: FrameRelay) {
        self.streamFormat = streamFormat
        self.relay = relay
        super.init()
        stream = CMIOExtensionStream(
            localizedName: OpenLensID.sinkStreamName,
            streamID: OpenLensID.sinkStreamUUID,
            direction: .sink,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkEndOfData]
    }

    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration =
                CMTime(value: 1, timescale: CMTimeScale(OpenLensOutput.frameRate))
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 3
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        logger.info("Sink stream started")
        queue.async {
            guard !self.isConsuming else { return }
            self.isConsuming = true
            self.consumeNext()
        }
    }

    func stopStream() throws {
        logger.info("Sink stream stopped")
        queue.async {
            self.isConsuming = false
            self.relay.appDisconnected()
        }
    }

    /// Pulls one buffer and immediately re-arms. `consumeSampleBuffer` blocks in
    /// the extension's own dispatch machinery rather than spinning, so this is a
    /// pull loop without a timer.
    private func consumeNext() {
        guard isConsuming else { return }
        guard let client else {
            logger.error("Sink has no authorized client; cannot consume")
            return
        }
        stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequence, _, _, error in
            guard let self else { return }
            if let sampleBuffer {
                let hostTime = UInt64(
                    sampleBuffer.presentationTimeStamp.convertScale(
                        Int32(NSEC_PER_SEC),
                        method: .default
                    ).value
                )
                self.relay.submit(sampleBuffer: sampleBuffer, hostTimeNanos: hostTime)
                self.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(
                        sequenceNumber: sequence,
                        hostTimeInNanoseconds: hostTime
                    )
                )
            } else if let error {
                logger.error("Sink consume failed: \(error.localizedDescription, privacy: .public)")
            }
            self.queue.async { self.consumeNext() }
        }
    }
}
