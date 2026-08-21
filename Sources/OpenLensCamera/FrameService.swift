import Foundation
import IOSurface
import os.log

/// Hosts the app-facing XPC listener inside the extension.
final class FrameService: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let relay: FrameRelay

    init(relay: FrameRelay) {
        self.relay = relay
        self.listener = NSXPCListener(machServiceName: OpenLensID.frameMachServiceName)
        super.init()
        listener.delegate = self
    }

    func resume() {
        listener.resume()
        logger.info(
            "Frame service listening on \(OpenLensID.frameMachServiceName, privacy: .public)"
        )
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let handler = FrameConnection(relay: relay, connection: newConnection)
        newConnection.exportedInterface = OpenLensXPC.extensionInterface()
        newConnection.exportedObject = handler
        newConnection.remoteObjectInterface = OpenLensXPC.appInterface()
        newConnection.invalidationHandler = { [weak handler] in handler?.tearDown() }
        newConnection.interruptionHandler = { [weak handler] in handler?.tearDown() }
        newConnection.resume()
        logger.info("App connected to frame service")
        return true
    }
}

/// One connected producer. Only the most recently connected app feeds the stream,
/// which keeps a stale second instance from fighting over the camera.
final class FrameConnection: NSObject, OpenLensExtensionInterface {
    private let relay: FrameRelay
    private weak var connection: NSXPCConnection?
    private var observerToken: UUID?

    init(relay: FrameRelay, connection: NSXPCConnection) {
        self.relay = relay
        self.connection = connection
        super.init()
    }

    func connect(reply: @escaping (Bool) -> Void) {
        observerToken = relay.addStreamingObserver { [weak self] isStreaming in
            guard let proxy = self?.connection?.remoteObjectProxy as? OpenLensAppInterface else {
                return
            }
            proxy.streamingStateChanged(isStreaming)
        }
        relay.currentStreamingState(reply)
    }

    func submitFrame(_ surface: IOSurface, hostTimeNanos: UInt64) {
        relay.submit(surface: surface, hostTimeNanos: hostTimeNanos)
    }

    func disconnect() {
        tearDown()
    }

    func tearDown() {
        if let observerToken {
            relay.removeStreamingObserver(observerToken)
            self.observerToken = nil
        }
        relay.appDisconnected()
    }
}
