import Foundation
import Network
import OSLog

/// Finds Key Lights on the local network over Bonjour.
///
/// Two steps rather than one: Bonjour gives a service name and an endpoint, but
/// not the serial number, and the serial number is what a light is *identified*
/// by here. So every endpoint found is asked for `/elgato/accessory-info`
/// before it counts as a device.
///
/// Discovery is deliberately quiet about failure. On recent macOS a denied
/// local-network prompt makes the browser return nothing at all rather than an
/// error, so "found none" and "not allowed" look identical from in here; the
/// caller reports that ambiguity rather than this type guessing at it.
@MainActor
final class KeyLightDiscovery {
    private let logger = Logger(subsystem: "com.trsdn.openlens", category: "lighting")
    private var browser: NWBrowser?
    private var resolvers: [String: Task<Void, Never>] = [:]
    private let client = KeyLightClient()

    /// Called with each light identified, possibly more than once for the same
    /// serial number as addresses change.
    var onFound: ((KeyLightDevice) -> Void)?
    /// Whether the browser is currently running and able to see the network.
    var onStateChange: ((Bool) -> Void)?

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: KeyLightDevice.bonjourServiceType,
            domain: nil
        )
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.onStateChange?(true)
                case .failed(let error):
                    self?.logger.error("Bonjour browse failed: \(error.localizedDescription)")
                    self?.onStateChange?(false)
                case .cancelled:
                    self?.onStateChange?(false)
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handle(results)
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        onStateChange?(false)
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            let key = "\(name).\(type)\(domain)"
            // One resolve per service at a time. The browse handler fires on
            // every network blip, and without this a flapping lamp would spawn
            // an unbounded pile of overlapping connections.
            guard resolvers[key] == nil else { continue }
            resolvers[key] = Task { [weak self] in
                await self?.resolve(result.endpoint, name: name)
                await MainActor.run { self?.resolvers[key] = nil }
            }
        }
    }

    /// Resolves the endpoint to an address, then asks the lamp who it is.
    private func resolve(_ endpoint: NWEndpoint, name: String) async {
        guard let address = await Self.address(of: endpoint) else {
            logger.debug("Could not resolve \(name, privacy: .public)")
            return
        }
        do {
            let info = try await client.accessoryInfo(host: address.host, port: address.port)
            // Without a serial number there is no stable identity, so the lamp
            // is skipped rather than filed under something that will collide.
            guard let serial = info.serialNumber, !serial.isEmpty else {
                logger.debug("\(name, privacy: .public) reported no serial number")
                return
            }
            let device = KeyLightDevice(
                serialNumber: serial,
                displayName: info.displayName?.isEmpty == false ? info.displayName! : name,
                productName: info.productName ?? "Elgato Key Light",
                host: address.host,
                port: address.port
            )
            onFound?(device)
        } catch {
            logger.debug("\(name, privacy: .public) did not answer: \(error.localizedDescription)")
        }
    }

    /// Turns a Bonjour service endpoint into a host and port.
    ///
    /// `NWConnection` is the supported way to do this — there is no public API
    /// that resolves without connecting — so a connection is opened purely to
    /// read `currentPath` and then dropped.
    private static func address(of endpoint: NWEndpoint) async -> (host: String, port: Int)? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            // Guards against the continuation being resumed twice, which traps:
            // stateUpdateHandler can fire again while we are tearing down.
            let done = OSAllocatedUnfairLock(initialState: false)

            func finish(_ value: (host: String, port: Int)?) {
                let alreadyDone = done.withLock { state -> Bool in
                    if state { return true }
                    state = true
                    return false
                }
                guard !alreadyDone else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard
                        let inner = connection.currentPath?.remoteEndpoint,
                        case .hostPort(let host, let port) = inner
                    else {
                        finish(nil)
                        return
                    }
                    finish((Self.literal(from: host), Int(port.rawValue)))
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))

            // NWConnection will happily sit in .preparing forever on a network
            // that drops SYNs, and a hung resolve would stall discovery.
            Task {
                try? await Task.sleep(for: .seconds(KeyLightClient.timeout))
                finish(nil)
            }
        }
    }

    /// Strips the scope id from a link-local IPv6 address (`fe80::1%en0`),
    /// which `URLComponents` will not accept.
    private nonisolated static func literal(from host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .ipv6(let address):
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        @unknown default:
            return "\(host)"
        }
    }
}
