import CoreVideo
import Foundation

/// Identifiers shared between the app and the camera system extension.
public enum OpenLensID {
    public static let teamID = "G69Z5BNY97"
    public static let appBundleID = "com.trsdn.openlens"
    public static let extensionBundleID = "com.trsdn.openlens.camera"

    public static let appGroup = "\(teamID).\(appBundleID)"

    /// Consumed by the CoreMediaIO DAL assistant, declared in the extension's Info.plist.
    public static let cmioMachServiceName = "\(teamID).\(extensionBundleID)"


    /// Stable identity of the published virtual camera device.
    public static let deviceName = "OpenLens"
    public static let deviceModel = "OpenLens Virtual Camera"
    public static let deviceUUID = UUID(uuidString: "6F1E6D9C-1C2E-4C1A-9E4B-2A7D3B5C8E10")!
    public static let streamUUID = UUID(uuidString: "6F1E6D9C-1C2E-4C1A-9E4B-2A7D3B5C8E11")!
    public static let sinkStreamUUID = UUID(uuidString: "6F1E6D9C-1C2E-4C1A-9E4B-2A7D3B5C8E12")!

    public static let sourceStreamName = "OpenLens.Video"
    public static let sinkStreamName = "OpenLens.Sink"
}

/// Output format of the virtual camera. Fixed so the extension never has to
/// renegotiate mid-call, which some conferencing apps handle badly.
public enum OpenLensOutput {
    public static let width = 1920
    public static let height = 1080
    public static let frameRate = 30
    public static var aspectRatio: Double { Double(width) / Double(height) }

    /// NV12, the format conferencing apps hand straight to their H.264 encoder.
    ///
    /// A 1080p frame is 3.11 MB here against 8.29 MB as BGRA. At 30 fps that is
    /// 93 MB/s instead of 249 MB/s through the sink queue, CoreMediaIO's copy
    /// into the consumer, and the encoder's own input stage. Cameras also deliver
    /// this layout natively, so the whole pipeline stays in one colour space.
    public static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
}
