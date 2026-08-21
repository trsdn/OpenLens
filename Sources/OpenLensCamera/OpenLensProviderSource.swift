import CoreMediaIO
import Foundation
import IOKit.audio
import os.log

/// Root of the extension: publishes a single virtual camera device.
final class OpenLensProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: OpenLensDeviceSource!
    private var frameService: FrameService!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = OpenLensDeviceSource()
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            logger.error("Failed to add device: \(error.localizedDescription, privacy: .public)")
        }
        frameService = FrameService(relay: deviceSource.streamSource.relay)
        frameService.resume()
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
        do {
            try device.addStream(streamSource.stream)
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
            localizedName: "OpenLens.Video",
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
