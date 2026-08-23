import Foundation
import OSLog
import SwiftUI

/// What the app knows about one light right now.
struct KeyLightEntry: Identifiable, Equatable {
    var device: KeyLightDevice
    var state: KeyLightState
    /// Nil until the lamp has been reached once.
    var isReachable: Bool?
    var lastError: String?

    var id: String { device.serialNumber }
}

/// Owns the set of known lights, their live state, and every write to them.
///
/// Writes are debounced because the controls are sliders: dragging brightness
/// across its range would otherwise put a hundred HTTP requests on the wire and
/// the lamp answers them in order, so the light would keep changing for seconds
/// after the drag stopped.
@MainActor
final class LightController: ObservableObject {
    @Published private(set) var lights: [KeyLightEntry] = []
    @Published private(set) var isBrowsing = false
    /// Set when discovery has run for a while and found nothing, which on
    /// recent macOS is as likely to be a denied local-network prompt as an
    /// empty network. The two are indistinguishable from the API.
    @Published private(set) var discoveryHint: String?

    private let logger = Logger(subsystem: "com.trsdn.openlens", category: "lighting")
    private let client = KeyLightClient()
    private let discovery = KeyLightDiscovery()
    private let defaults = UserDefaults.standard
    private let knownKey = "lights.known.v1"

    private var pendingWrites: [String: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?

    init() {
        loadKnown()
        discovery.onFound = { [weak self] device in self?.merge(device) }
        discovery.onStateChange = { [weak self] running in
            self?.isBrowsing = running
        }
    }

    // MARK: - Lifecycle

    func start() {
        discovery.start()
        refreshAll()
        scheduleHint()

        // A lamp can be turned on at its own switch, or driven from Elgato's
        // app on a phone. Without a poll the panel would keep showing whatever
        // was true when the app launched.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await self?.refreshAllAndWait()
            }
        }
    }

    func stop() {
        discovery.stop()
        refreshTask?.cancel()
        refreshTask = nil
        hintTask?.cancel()
        hintTask = nil
        pendingWrites.values.forEach { $0.cancel() }
        pendingWrites.removeAll()
    }

    private func scheduleHint() {
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            guard let self, self.lights.isEmpty else { return }
            self.discoveryHint =
                "No lights found. If they are powered on and on this network, check "
                + "System Settings › Privacy & Security › Local Network and make sure "
                + "OpenLens is allowed, or add one by address."
        }
    }

    // MARK: - Known lights

    private func loadKnown() {
        guard
            let data = defaults.data(forKey: knownKey),
            let devices = try? JSONDecoder().decode([KeyLightDevice].self, from: data)
        else { return }
        lights = devices.map { KeyLightEntry(device: $0, state: KeyLightState(), isReachable: nil) }
    }

    private func saveKnown() {
        guard let data = try? JSONEncoder().encode(lights.map(\.device)) else { return }
        defaults.set(data, forKey: knownKey)
    }

    /// Folds a discovered light into the list, matching on serial number so a
    /// lamp that changed address updates in place instead of appearing twice.
    private func merge(_ device: KeyLightDevice) {
        discoveryHint = nil
        if let index = lights.firstIndex(where: { $0.device.serialNumber == device.serialNumber }) {
            // A manual entry keeps its flag: it has to survive not being seen
            // by Bonjour next time.
            var updated = device
            updated.isManual = lights[index].device.isManual
            let addressChanged = lights[index].device.host != updated.host
            lights[index].device = updated
            if addressChanged || lights[index].isReachable != true {
                refresh(serialNumber: device.serialNumber)
            }
        } else {
            lights.append(KeyLightEntry(device: device, state: KeyLightState(), isReachable: nil))
            lights.sort { $0.device.displayName.localizedStandardCompare($1.device.displayName) == .orderedAscending }
            refresh(serialNumber: device.serialNumber)
        }
        saveKnown()
    }

    /// Adds a light the user typed in, for networks where Bonjour is blocked.
    /// Identity still comes from the lamp, so a manual entry and a discovered
    /// one for the same lamp collapse into a single row.
    func addManual(host: String, port: Int = KeyLightDevice.defaultPort) async -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter an address." }
        do {
            let info = try await client.accessoryInfo(host: trimmed, port: port)
            guard let serial = info.serialNumber, !serial.isEmpty else {
                return "That address answered but is not an Elgato light."
            }
            var device = KeyLightDevice(
                serialNumber: serial,
                displayName: info.displayName?.isEmpty == false ? info.displayName! : trimmed,
                productName: info.productName ?? "Elgato Key Light",
                host: trimmed,
                port: port
            )
            device.isManual = true
            merge(device)
            return nil
        } catch {
            // Deliberately names the permission. A blocked local network looks
            // exactly like an unplugged lamp from here — the connection simply
            // never completes — and pointing only at the address sends people
            // hunting for a network fault that isn't there.
            return "Nothing answered at \(trimmed):\(port). If the light is on and on this "
                + "network, check System Settings › Privacy & Security › Local Network and "
                + "make sure OpenLens is allowed."
        }
    }

    func forget(_ serialNumber: String) {
        pendingWrites[serialNumber]?.cancel()
        pendingWrites[serialNumber] = nil
        lights.removeAll { $0.device.serialNumber == serialNumber }
        saveKnown()
    }

    // MARK: - Reading

    func refreshAll() {
        Task { await refreshAllAndWait() }
    }

    private func refreshAllAndWait() async {
        await withTaskGroup(of: Void.self) { group in
            for entry in lights {
                group.addTask { @MainActor [weak self] in
                    await self?.refreshAndWait(serialNumber: entry.device.serialNumber)
                }
            }
        }
    }

    private func refresh(serialNumber: String) {
        Task { await refreshAndWait(serialNumber: serialNumber) }
    }

    private func refreshAndWait(serialNumber: String) async {
        guard let entry = lights.first(where: { $0.device.serialNumber == serialNumber }) else { return }
        // A read must not stomp on a value the user is dragging right now.
        guard pendingWrites[serialNumber] == nil else { return }
        do {
            let state = try await client.state(host: entry.device.host, port: entry.device.port)
            update(serialNumber) {
                $0.state = state
                $0.isReachable = true
                $0.lastError = nil
            }
        } catch {
            update(serialNumber) {
                $0.isReachable = false
                $0.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Writing

    func setOn(_ isOn: Bool, for serialNumber: String) {
        update(serialNumber) { $0.state.isOn = isOn }
        write(serialNumber) { $0.isOn = isOn }
    }

    func setBrightness(_ brightness: Int, for serialNumber: String) {
        let value = KeyLightState.clampBrightness(brightness)
        update(serialNumber) { $0.state.brightness = value }
        write(serialNumber) { $0.brightness = value }
    }

    func setMired(_ mired: Int, for serialNumber: String) {
        let value = KeyLightState.clampMired(mired)
        update(serialNumber) { $0.state.mired = value }
        write(serialNumber) { $0.mired = value }
    }

    func setKelvin(_ kelvin: Int, for serialNumber: String) {
        setMired(KeyLightState.mired(fromKelvin: kelvin), for: serialNumber)
    }

    // MARK: - Group actions

    func setAllOn(_ isOn: Bool) {
        lights.forEach { setOn(isOn, for: $0.device.serialNumber) }
    }

    /// Matching the lamps is the change most often wanted: two lights at
    /// different colour temperatures put a cast on one side of the face that no
    /// single white balance can correct.
    func setAllKelvin(_ kelvin: Int) {
        lights.forEach { setKelvin(kelvin, for: $0.device.serialNumber) }
    }

    func setAllBrightness(_ brightness: Int) {
        lights.forEach { setBrightness(brightness, for: $0.device.serialNumber) }
    }

    /// True when every reachable light already agrees on colour temperature.
    var lightsAgreeOnTemperature: Bool {
        let reachable = lights.filter { $0.isReachable == true }
        guard let first = reachable.first else { return true }
        return reachable.allSatisfy { $0.state.mired == first.state.mired }
    }

    // MARK: - Scenes

    /// The state the scene wants, captured from what the lamps are doing now.
    func snapshot() -> SceneLighting {
        SceneLighting(
            isEnabled: true,
            lights: Dictionary(
                uniqueKeysWithValues: lights.map { ($0.device.serialNumber, $0.state) }
            )
        )
    }

    /// Puts the lamps where a scene wants them.
    ///
    /// Lights the scene says nothing about are left alone rather than pushed to
    /// a default — a scene that was set up before a lamp existed must not
    /// switch that lamp off.
    func apply(_ lighting: SceneLighting?) {
        guard let lighting, lighting.isEnabled else { return }
        for (serialNumber, wanted) in lighting.lights {
            guard lights.contains(where: { $0.device.serialNumber == serialNumber }) else { continue }
            update(serialNumber) { $0.state = wanted }
            write(serialNumber) {
                $0.isOn = wanted.isOn
                $0.brightness = wanted.brightness
                $0.mired = wanted.mired
            }
        }
    }

    // MARK: - Plumbing

    private struct Change {
        var isOn: Bool?
        var brightness: Int?
        var mired: Int?
    }

    private func update(_ serialNumber: String, _ body: (inout KeyLightEntry) -> Void) {
        guard let index = lights.firstIndex(where: { $0.device.serialNumber == serialNumber }) else { return }
        body(&lights[index])
    }

    /// Coalesces everything asked for within the debounce window into one PUT,
    /// so a drag that also flips the switch still costs a single request.
    private func write(_ serialNumber: String, _ build: (inout Change) -> Void) {
        guard let entry = lights.first(where: { $0.device.serialNumber == serialNumber }) else { return }

        pendingWrites[serialNumber]?.cancel()
        // The change is rebuilt from the entry's current state rather than
        // accumulated, because `update` has already applied it there. This is
        // what makes coalescing correct instead of last-write-wins.
        var change = Change()
        build(&change)
        let target = entry.state
        let host = entry.device.host
        let port = entry.device.port

        pendingWrites[serialNumber] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            do {
                let echoed = try await self.client.apply(
                    host: host,
                    port: port,
                    isOn: change.isOn ?? target.isOn,
                    brightness: change.brightness ?? target.brightness,
                    mired: change.mired ?? target.mired
                )
                guard !Task.isCancelled else { return }
                self.pendingWrites[serialNumber] = nil
                self.update(serialNumber) {
                    $0.state = echoed
                    $0.isReachable = true
                    $0.lastError = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.pendingWrites[serialNumber] = nil
                self.logger.debug("Write to \(serialNumber, privacy: .public) failed: \(error.localizedDescription)")
                self.update(serialNumber) {
                    $0.isReachable = false
                    $0.lastError = error.localizedDescription
                }
            }
        }
    }
}
