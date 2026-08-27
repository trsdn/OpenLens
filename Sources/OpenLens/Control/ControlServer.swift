import Foundation
import Network
import os.log

/// A local control socket, so OpenLens can be driven by something other than a
/// pair of hands.
///
/// A unix domain socket in the app group container rather than a TCP port,
/// which decides three things at once: no `com.apple.security.network.server`
/// entitlement is needed, nothing is reachable from off the machine, and access
/// control is the file system's problem rather than an authentication scheme
/// this app would otherwise have to invent. A localhost HTTP port, by contrast,
/// is reachable by every page in every browser.
///
/// The socket carries newline-delimited JSON; see `ControlProtocol.swift`.
@MainActor
final class ControlServer {
    /// Runs on the main actor, because everything it touches is `AppModel`.
    typealias Handler = (ControlRequest) -> ControlResponse

    private(set) var socketURL: URL?

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var handler: Handler?

    /// Builds the snapshot pushed to subscribers. Held rather than passed in so
    /// the broadcaster can read the state at the moment it sends, not at the
    /// moment something changed.
    private var stateProvider: (() -> ControlValue)?
    private var pendingBroadcast: DispatchWorkItem?

    /// Long enough to collapse a continuous gesture — a scroll-wheel zoom moves
    /// `effectiveZoom` on every frame — and short enough that a key on a deck
    /// still feels like it reacts to the press.
    private static let broadcastCoalescingDelay: TimeInterval = 0.1

    private let queue = DispatchQueue(label: "\(OpenLensID.appBundleID).control")
    private let log = Logger(subsystem: OpenLensID.appBundleID, category: "control")

    // MARK: - Lifecycle

    func start(handler: @escaping Handler) {
        guard listener == nil else { return }
        guard let url = Self.preferredSocketURL(logger: log) else { return }

        // A crash or a force quit leaves the socket file behind and `bind`
        // refuses a path that exists, so without this the control socket works
        // exactly once per clean shutdown.
        try? FileManager.default.removeItem(at: url)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: url.path)
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.accept(connection) }
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed(let error) = state else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.fail(error) }
                }
            }
            self.handler = handler
            self.listener = listener
            self.socketURL = url
            listener.start(queue: queue)
            log.info("Control socket listening at \(url.path, privacy: .public)")
        } catch {
            log.error("Control socket failed to open: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        pendingBroadcast?.cancel()
        pendingBroadcast = nil
        stateProvider = nil
        for client in clients.values { client.cancel() }
        clients.removeAll()
        listener?.cancel()
        listener = nil
        handler = nil
        // Leaving the file behind would make it look like the app is still
        // listening, and a client would sit in `connect` waiting for nobody.
        if let socketURL { try? FileManager.default.removeItem(at: socketURL) }
        socketURL = nil
    }

    // MARK: - Events

    func setStateProvider(_ provider: @escaping () -> ControlValue) {
        stateProvider = provider
    }

    /// Called whenever anything a subscriber cares about may have changed.
    ///
    /// Coalesced rather than sent straight away, for two reasons that both bite
    /// in practice: `@Published` fires from `willSet`, so reading the model in
    /// this call stack would hand out the *old* value, and a dragged slider
    /// would otherwise put one push on the wire per frame.
    func stateDidChange() {
        guard listener != nil, pendingBroadcast == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushBroadcast() }
        }
        pendingBroadcast = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.broadcastCoalescingDelay,
            execute: work
        )
    }

    private func flushBroadcast() {
        pendingBroadcast = nil

        let subscribers = clients.values.filter(\.isSubscribed)
        guard !subscribers.isEmpty, let stateProvider else { return }
        guard let data = try? ControlCodec.encode(ControlEvent(state: stateProvider())) else {
            return
        }
        for client in subscribers {
            // A change that alters nothing this client can see — the crop
            // shifting while the zoom readout stays put — should not wake it.
            // Compared per client rather than once for everyone, so that a
            // client subscribing does not silence the others, and so the first
            // event after subscribing is not just the reply repeated.
            guard client.lastSent != data else { continue }
            client.lastSent = data
            client.connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func fail(_ error: NWError) {
        log.error("Control socket failed: \(error.localizedDescription, privacy: .public)")
        stop()
    }

    /// Nil when there is nowhere usable to put the socket, which is not fatal:
    /// the app runs perfectly well without remote control.
    private static func preferredSocketURL(logger: Logger) -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: OpenLensID.appGroup
        ) else {
            logger.error("No app group container, so no control socket")
            return nil
        }
        let url = ControlSocket.url(inContainer: container)
        guard ControlSocket.isUsable(path: url.path) else {
            logger.error("Control socket path is too long: \(url.path, privacy: .public)")
            return nil
        }
        return url
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        let key = ObjectIdentifier(client)
        clients[key] = client

        // The connection callbacks are `@Sendable` and `Client` is main-actor
        // state, so what crosses the boundary is a key rather than a reference:
        // the lookup happens back on the main actor, where it is safe.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.drop(key) }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: key)
    }

    private func drop(_ key: ObjectIdentifier) {
        clients.removeValue(forKey: key)?.cancel()
    }

    private func receive(on key: ObjectIdentifier) {
        guard let client = clients[key] else { return }
        client.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let client = self.clients[key] else { return }
                    if let data, !data.isEmpty { self.consume(data, on: client) }
                    if isComplete || error != nil {
                        self.drop(key)
                    } else if client.framer.isOverflowing {
                        self.log.error("Control client sent an oversized line; dropping it")
                        self.drop(key)
                    } else {
                        self.receive(on: key)
                    }
                }
            }
        }
    }

    private func consume(_ data: Data, on client: Client) {
        for line in client.framer.append(data) {
            let response: ControlResponse
            do {
                let request = try ControlCodec.decode(line)
                response = subscription(request, from: client)
                    ?? handler?(request)
                    ?? .failure(id: request.id, "The control server is shutting down")
            } catch {
                // No id to echo: the id lives in the very thing that would not
                // parse.
                response = .failure(id: nil, "Malformed request: \(error.localizedDescription)")
            }
            send(response, to: client)
        }
    }

    /// Answers the two commands that are about this connection rather than
    /// about the app, and returns nil for everything else.
    private func subscription(_ request: ControlRequest, from client: Client) -> ControlResponse? {
        switch request.command {
        case ControlSubscriptionCommand.subscribe:
            client.isSubscribed = true
            // The current state comes back as the reply, so a client never has
            // to make a second call to paint itself before the first change
            // arrives.
            let state = stateProvider?() ?? .object([:])
            // Recorded as though it had been pushed, so the next broadcast does
            // not open by repeating what this reply already said.
            client.lastSent = try? ControlCodec.encode(ControlEvent(state: state))
            return .success(id: request.id, state)
        case ControlSubscriptionCommand.unsubscribe:
            client.isSubscribed = false
            client.lastSent = nil
            return .success(id: request.id)
        default:
            return nil
        }
    }

    private func send(_ response: ControlResponse, to client: Client) {
        guard let data = try? ControlCodec.encode(response) else { return }
        client.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// One connected client, and the half-received line it is in the middle of.
    private final class Client {
        let connection: NWConnection
        var framer = LineFramer()
        /// Off by default, so a client that only ever sends one command is not
        /// handed a stream it never reads — which would eventually fill the
        /// socket buffer and stall the send.
        var isSubscribed = false
        /// The last state this client was sent, encoded, so an unchanged one is
        /// not sent again.
        var lastSent: Data?

        init(connection: NWConnection) {
            self.connection = connection
        }

        func cancel() {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }
}
