import CoreVideo
import Foundation
import IOSurface
import os.log

/// The app's end of the frame transport.
///
/// Frames travel as `IOSurface` send rights, so a 1080p frame costs a message
/// with a mach port in it rather than 8 MB of copying.
final class ExtensionClient: NSObject, ObservableObject {
    /// True while a conferencing app actually has the virtual camera open. The
    /// capture pipeline idles otherwise, which is the largest single power win.
    @Published private(set) var isStreaming = false
    @Published private(set) var isConnected = false

    private var connection: NSXPCConnection?
    private let queue = DispatchQueue(label: "com.trsdn.openlens.xpc")
    private let log = Logger(subsystem: OpenLensID.appBundleID, category: "xpc")
    private var reconnectDelay: TimeInterval = 0.5
    private var isShuttingDown = false

    func connect() {
        queue.async { [weak self] in self?.establishConnection() }
    }

    func shutdown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isShuttingDown = true
            (self.connection?.remoteObjectProxy as? OpenLensExtensionInterface)?.disconnect()
            self.connection?.invalidate()
            self.connection = nil
        }
    }

    private func establishConnection() {
        guard connection == nil, !isShuttingDown else { return }

        let connection = NSXPCConnection(
            machServiceName: OpenLensID.frameMachServiceName,
            options: []
        )
        connection.remoteObjectInterface = OpenLensXPC.extensionInterface()
        connection.exportedInterface = OpenLensXPC.appInterface()
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in self?.handleDrop() }
        connection.interruptionHandler = { [weak self] in self?.handleDrop() }
        connection.resume()
        self.connection = connection

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.log.error(
                "Extension unreachable: \(error.localizedDescription, privacy: .public)"
            )
            self?.handleDrop()
        }) as? OpenLensExtensionInterface else { return }

        proxy.connect { [weak self] streaming in
            guard let self else { return }
            self.reconnectDelay = 0.5
            DispatchQueue.main.async {
                self.isConnected = true
                self.isStreaming = streaming
            }
        }
    }

    private func handleDrop() {
        queue.async { [weak self] in
            guard let self, !self.isShuttingDown else { return }
            self.connection?.invalidate()
            self.connection = nil
            DispatchQueue.main.async {
                self.isConnected = false
                self.isStreaming = false
            }
            // The extension is demand-launched by the CoreMediaIO assistant, so a
            // failure here is usually "not running yet" rather than "broken".
            let delay = self.reconnectDelay
            self.reconnectDelay = min(delay * 2, 10)
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.establishConnection()
            }
        }
    }

    /// Hands one rendered frame to the extension.
    func send(pixelBuffer: CVPixelBuffer, hostTimeNanos: UInt64) {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        guard let proxy = connection?.remoteObjectProxy as? OpenLensExtensionInterface else {
            return
        }
        proxy.submitFrame(unsafeBitCast(surface, to: IOSurface.self), hostTimeNanos: hostTimeNanos)
    }
}

extension ExtensionClient: OpenLensAppInterface {
    func streamingStateChanged(_ isStreaming: Bool) {
        DispatchQueue.main.async { self.isStreaming = isStreaming }
    }
}
