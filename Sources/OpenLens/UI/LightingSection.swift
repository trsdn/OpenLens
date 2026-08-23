import SwiftUI

/// Controls for the Key Lights, and whether the selected scene drives them.
///
/// Its own file rather than another block in `InspectorView` because it is the
/// only section with live network state behind it: it needs to observe
/// `LightController` directly, and folding that into the inspector would
/// redraw every slider in the panel each time a lamp is polled.
struct LightingSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: LightController
    @Binding var isExpanded: Bool

    @State private var manualHost = ""
    @State private var manualError: String?
    @State private var isAddingManually = false

    init(model: AppModel, isExpanded: Binding<Bool>) {
        self.model = model
        self.controller = model.lights
        self._isExpanded = isExpanded
    }

    var body: some View {
        Section(isExpanded: $isExpanded) {
            if controller.lights.isEmpty {
                emptyState
            } else {
                ForEach(controller.lights) { entry in
                    LightRow(entry: entry, controller: controller)
                }
                groupControls
                sceneControls
            }

            if isAddingManually || controller.lights.isEmpty {
                manualEntry
            }
        } header: {
            SectionHeader(
                "Lighting",
                info: "Controls the Elgato Key Lights on your network directly, so you do "
                    + "not have to leave the call to reach for a phone.\n\n"
                    + "Colour temperature is the setting that matters most here. Two lights "
                    + "at different temperatures put a cast on one side of your face that "
                    + "no white balance can correct, which is why there is a control to "
                    + "match them. Set the lights first, then set the camera's white "
                    + "balance to the same number, and the colour sliders above have far "
                    + "less to do.\n\n"
                    + "Lights are found automatically over Bonjour. If nothing appears, "
                    + "macOS may not have granted local network access — check System "
                    + "Settings › Privacy & Security › Local Network — or you can type an "
                    + "address in by hand.\n\n"
                    + "Remember in scene stores what the lights are doing now as part of "
                    + "the selected scene, so switching to it later restores the light "
                    + "along with the crop. Scenes without this leave the lights alone.",
                summary: summary,
                summaryIsActive: summaryIsActive
            )
        }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if controller.isBrowsing {
                    ProgressView().controlSize(.small)
                }
                Text(controller.isBrowsing ? "Looking for lights…" : "No lights found.")
                    .foregroundStyle(.secondary)
            }
            if let hint = controller.discoveryHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var groupControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Button("All on") { controller.setAllOn(true) }
                Button("All off") { controller.setAllOn(false) }
                Spacer()
                Button {
                    controller.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Re-read the lights")
            }

            // Only offered when it would change something, so it does not sit
            // there as a button that appears to do nothing.
            if controller.lights.count > 1, !controller.lightsAgreeOnTemperature {
                Button("Match colour temperature") {
                    guard let first = controller.lights.first(where: { $0.isReachable == true })
                        ?? controller.lights.first else { return }
                    controller.setAllKelvin(first.state.kelvin)
                }
                .help("Sets every light to the first light's temperature")
            }
        }
    }

    private var sceneControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Button("Remember in scene") { model.captureLightingIntoScene() }
                if model.sceneLighting.isEnabled {
                    Button("Forget") { model.clearLightingFromScene() }
                }
            }
            Text(
                model.sceneLighting.isEnabled
                    ? "This scene sets \(model.sceneLighting.activeCount) "
                        + "light\(model.sceneLighting.activeCount == 1 ? "" : "s") when selected."
                    : "This scene leaves the lights alone."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("192.168.1.20", text: $manualHost)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addManual() }
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let manualError {
                Text(manualError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func addManual() {
        let host = manualHost
        Task {
            manualError = await controller.addManual(host: host)
            if manualError == nil {
                manualHost = ""
                isAddingManually = false
            }
        }
    }

    // MARK: - Summary

    private var summary: String {
        guard !controller.lights.isEmpty else {
            return controller.isBrowsing ? "Searching" : "None found"
        }
        let on = controller.lights.filter { $0.state.isOn && $0.isReachable != false }
        guard let first = on.first else { return "All off" }
        // The temperature is only worth showing when the lights agree on it;
        // otherwise a single number would be a lie about half the room.
        let sameTemperature = on.allSatisfy { $0.state.mired == first.state.mired }
        let count = "\(on.count) of \(controller.lights.count) on"
        return sameTemperature ? "\(count), \(first.state.kelvin) K" : "\(count), mixed"
    }

    private var summaryIsActive: Bool {
        model.sceneLighting.isEnabled || controller.lights.contains { $0.isReachable == false }
    }
}

/// One light: name, switch, brightness and colour temperature.
private struct LightRow: View {
    let entry: KeyLightEntry
    @ObservedObject var controller: LightController

    static let brightnessBounds =
        Double(KeyLightState.brightnessRange.lowerBound)...Double(KeyLightState.brightnessRange.upperBound)
    /// The slider runs on mired offset, not mired: reversing it here is what
    /// puts warm on the left and cool on the right, the way a person expects.
    static let miredSpan =
        Double(KeyLightState.miredRange.upperBound - KeyLightState.miredRange.lowerBound)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle(
                    entry.device.displayName,
                    isOn: Binding(
                        get: { entry.state.isOn },
                        set: { controller.setOn($0, for: entry.id) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(entry.isReachable == false)

                Spacer(minLength: 0)

                if entry.isReachable == false {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(entry.lastError ?? "Not reachable")
                }

                Menu {
                    Button("Forget this light") { controller.forget(entry.id) }
                    Text(entry.device.host)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            LabeledContent("Brightness") {
                HStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { Double(entry.state.brightness) },
                            set: { controller.setBrightness(Int($0.rounded()), for: entry.id) }
                        ),
                        in: LightRow.brightnessBounds
                    )
                    Text("\(entry.state.brightness)%")
                        .monospacedDigit()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }

            LabeledContent("Temperature") {
                HStack(spacing: 4) {
                    // Driven in mired rather than kelvin because that is the
                    // unit the lamp steps in: a kelvin slider would move in
                    // jumps at the warm end and do nothing at the cool end.
                    Slider(
                        value: Binding(
                            get: { Double(KeyLightState.miredRange.upperBound - entry.state.mired) },
                            set: {
                                let mired = KeyLightState.miredRange.upperBound - Int($0.rounded())
                                controller.setMired(mired, for: entry.id)
                            }
                        ),
                        in: 0...LightRow.miredSpan
                    )
                    Text("\(entry.state.kelvin)K")
                        .monospacedDigit()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
        .opacity(entry.isReachable == false ? 0.5 : 1)
    }
}
