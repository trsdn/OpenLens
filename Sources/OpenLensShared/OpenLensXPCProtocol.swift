import Foundation
import IOSurface

/// App -> extension. Frames are handed over as `IOSurface`s, which cross the XPC
/// boundary as mach send rights: no pixel copy, no serialization.
@objc public protocol OpenLensExtensionInterface {
    /// Registers the app as the frame producer. Replies with the current
    /// streaming state so the app can decide whether to start capturing at all.
    func connect(reply: @escaping (Bool) -> Void)

    /// Publishes one frame. `hostTimeNanos` is `mach_absolute_time` converted to
    /// nanoseconds; the extension turns it into the sample presentation time.
    func submitFrame(_ surface: IOSurface, hostTimeNanos: UInt64)

    /// Clears the feed back to the idle placeholder.
    func disconnect()
}

/// Extension -> app. Lets the app run the whole capture pipeline only while a
/// conferencing app actually has the virtual camera open, which is the single
/// biggest power saving available.
@objc public protocol OpenLensAppInterface {
    func streamingStateChanged(_ isStreaming: Bool)
}

public enum OpenLensXPC {
    public static func extensionInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: OpenLensExtensionInterface.self)
        interface.setClasses(
            NSSet(array: [IOSurface.self]) as! Set<AnyHashable>,
            for: #selector(OpenLensExtensionInterface.submitFrame(_:hostTimeNanos:)),
            argumentIndex: 0,
            ofReply: false
        )
        return interface
    }

    public static func appInterface() -> NSXPCInterface {
        NSXPCInterface(with: OpenLensAppInterface.self)
    }
}
