import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var scenes: SceneStore
    @State private var sceneName = ""

    init(model: AppModel) {
        self.model = model
        self.scenes = model.scenes
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $sceneName)
                    .onSubmit { model.renameSelectedScene(sceneName) }

                Picker("Camera", selection: deviceBinding) {
                    ForEach(model.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }

                HStack(spacing: 4) {
                    Picker("Capture quality", selection: qualityBinding) {
                        ForEach(CaptureQuality.allCases, id: \.self) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    InfoButton(
                        text: "Capturing above 1080p is what buys you sharp zoom: a 4K source "
                            + "can be cropped to 2× and still fill the 1080p output with real "
                            + "pixels.\n\nThe catch is bandwidth. Uncompressed 4K can exceed "
                            + "what the camera's USB connection carries, and it then delivers "
                            + "fewer frames per second — sharper stills, choppier motion. The "
                            + "line below shows what you are actually getting, so compare the "
                            + "two settings and keep the one that reads 30 fps."
                    )
                }

                if !model.sourceSummary.isEmpty {
                    LabeledContent("Receiving") {
                        Text(model.sourceSummary).monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }

                Toggle("Mirror", isOn: mirrorBinding)

                HStack {
                    Button("Duplicate") { model.duplicateSelectedScene() }
                    Button("Delete") { model.removeSelectedScene() }
                        .disabled(scenes.scenes.count <= 1)
                }
            } header: {
                SectionHeader(
                    "Scene",
                    info: "Scenes are your presets. Camera, zoom, mirror and overlay are "
                        + "saved into the selected scene as you change them — there is no "
                        + "save button. Duplicate takes a snapshot of the current look as a "
                        + "new scene, and ⌥1…⌥9 switch between them even while you are in a call."
                )
            }

            Section {
                // Two rows, not one: the inspector is only ~240pt wide, and a
                // slider sharing a row with a text field and two buttons collapses
                // to a stub you cannot aim at.
                LabeledContent("Level") {
                    HStack(spacing: 4) {
                        TextField(
                            "",
                            value: Binding(
                                get: { Double(model.effectiveZoom) },
                                set: { model.setZoom(CGFloat($0)) }
                            ),
                            format: .number.precision(.fractionLength(1))
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                        Text("×").foregroundStyle(.secondary)
                        Stepper("Zoom") {
                            model.zoomIn()
                        } onDecrement: {
                            model.zoomOut()
                        }
                        .labelsHidden()
                    }
                }

                Slider(
                    value: Binding(
                        get: { model.effectiveZoom },
                        set: { model.setZoom($0) }
                    ),
                    in: CropGeometry.minZoom...CropGeometry.maxZoom,
                    step: AppModel.zoomStep
                )
                .accessibilityLabel("Zoom")

                LabeledContent("Stays sharp up to") {
                    Text(String(format: "%.1f×", model.losslessZoomLimit)).monospacedDigit()
                }
                Button("Reset to full frame") { model.resetZoom() }
            } header: {
                SectionHeader(
                    "Zoom",
                    info: "The slider and the stepper move in steps of 0.1×. Type in the "
                        + "field for an exact value, or scroll and pinch over the picture for "
                        + "continuous zoom around the pointer — dragging then pans.\n\n"
                        + "\"Stays sharp up to\" is the point where the crop has used up every "
                        + "real pixel the camera delivers. Beyond it the picture is enlarged "
                        + "rather than cropped and turns soft, which the badge on the picture "
                        + "calls out. Raising Capture quality pushes that limit further out."
                )
            }

            Section {
                AdjustmentSlider(
                    title: "Exposure",
                    value: adjustmentBinding(\.exposure),
                    range: ImageAdjustments.exposureRange,
                    onCommit: { model.commitAdjustments() },
                    format: { $0 == 0 ? "0 EV" : String(format: "%+.1f EV", $0) }
                )
                AdjustmentSlider(
                    title: "Contrast",
                    value: adjustmentBinding(\.contrast),
                    range: ImageAdjustments.unitRange,
                    onCommit: { model.commitAdjustments() },
                    format: Self.percentage
                )
                AdjustmentSlider(
                    title: "White balance",
                    value: adjustmentBinding(\.temperature),
                    range: ImageAdjustments.unitRange,
                    onCommit: { model.commitAdjustments() },
                    format: { value in
                        guard value != 0 else { return "Neutral" }
                        return String(
                            format: "%+.0f%% %@", value * 100, value > 0 ? "warm" : "cool"
                        )
                    }
                )
                AdjustmentSlider(
                    title: "Saturation",
                    value: adjustmentBinding(\.saturation),
                    range: ImageAdjustments.unitRange,
                    onCommit: { model.commitAdjustments() },
                    format: Self.percentage
                )

                Button("Reset to neutral") { model.resetAdjustments() }
                    .disabled(model.adjustments.isNeutral)
            } header: {
                SectionHeader(
                    "Colour",
                    info: "macOS exposes no exposure or white balance control for a capture "
                        + "device, so these are applied to the picture itself rather than to "
                        + "the camera. They ride along in the GPU pass that already crops "
                        + "every frame, which is why they cost nothing measurable.\n\n"
                        + "Correct at the camera first where you can — this cannot recover "
                        + "detail that was never captured. It is here to match a second "
                        + "camera to your main one, or to rescue a room whose light you "
                        + "cannot change. Each scene keeps its own settings."
                )
            }

            Section {
                Toggle("Show preview", isOn: $model.previewEnabled)
            } header: {
                SectionHeader(
                    "Preview",
                    info: "Turning the preview off skips one render pass per frame and frees "
                        + "the window. The virtual camera is unaffected. On Apple silicon the "
                        + "saving is well under a percent, so treat this as a way to clear "
                        + "the screen rather than a performance fix."
                )
            }

            Section {
                Toggle("Show overlay", isOn: overlayEnabledBinding)
                    .disabled(scenes.overlayURL == nil)

                HStack {
                    Button(scenes.overlayURL == nil ? "Choose PNG…" : "Replace…") {
                        chooseOverlay()
                    }
                    if scenes.overlayURL != nil {
                        Button("Remove") { model.chooseOverlay(url: nil) }
                    }
                }

                if let url = scenes.overlayURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    LabeledContent("Opacity") {
                        Slider(value: overlayOpacityBinding, in: 0...1)
                    }
                    OverlayPlacementControls(model: model)
                }
            } header: {
                SectionHeader(
                    "Overlay",
                    info: "A PNG with transparency composited on top of the picture in the "
                        + "same GPU pass, so it is free. Use it for a logo or a lower third. "
                        + "Placement is a nine-position grid rather than dragging, because "
                        + "dragging in the picture already pans the crop."
                )
            }
        }
        .formStyle(.grouped)
        .onAppear { sceneName = scenes.selectedScene?.name ?? "" }
        .onChange(of: scenes.selectedSceneID) { _, _ in
            sceneName = scenes.selectedScene?.name ?? ""
        }
    }

    private func chooseOverlay() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .tiff, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { model.chooseOverlay(url: panel.url) }
    }

    // MARK: - Bindings

    private static let percentage: (Double) -> String = { value in
        value == 0 ? "Neutral" : String(format: "%+.0f%%", value * 100)
    }

    private func adjustmentBinding(
        _ keyPath: WritableKeyPath<ImageAdjustments, Double>
    ) -> Binding<Double> {
        Binding(
            get: { model.adjustments[keyPath: keyPath] },
            set: { newValue in
                var updated = model.adjustments
                updated[keyPath: keyPath] = newValue
                model.setAdjustments(updated)
            }
        )
    }

    private var deviceBinding: Binding<String> {
        Binding(
            get: { scenes.selectedScene?.deviceID ?? "" },
            set: { id in
                guard let device = model.devices.first(where: { $0.id == id }) else { return }
                model.setDevice(device)
            }
        )
    }

    private var qualityBinding: Binding<CaptureQuality> {
        Binding(
            get: { scenes.selectedScene?.quality ?? .losslessZoom },
            set: { model.setQuality($0) }
        )
    }

    private var mirrorBinding: Binding<Bool> {
        Binding(
            get: { scenes.selectedScene?.mirrored ?? false },
            set: { model.setMirrored($0) }
        )
    }

    private var overlayEnabledBinding: Binding<Bool> {
        Binding(
            get: { scenes.selectedScene?.overlayEnabled ?? false },
            set: { model.setOverlayEnabled($0) }
        )
    }

    private var overlayOpacityBinding: Binding<Double> {
        Binding(
            get: { scenes.selectedScene?.overlayOpacity ?? 1 },
            set: { model.setOverlayOpacity($0) }
        )
    }
}

/// A slider that is neutral in the middle, with the current value spelled out
/// above it.
///
/// Two rows rather than one: the inspector is only ~240pt wide, and a slider
/// sharing a row with a label and a readout collapses to a stub you cannot aim
/// at. The write to disk is deferred to the end of the drag via
/// `onEditingChanged`, so dragging does not serialise the scene list on every
/// frame.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onCommit: () -> Void
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit() }
            }
            .accessibilityLabel(title)
        }
    }
}

/// Nine-position placement plus a size slider.
///
/// Dragging the overlay directly in the preview would fight the pan gesture, so
/// placement is explicit and predictable instead.
struct OverlayPlacementControls: View {
    @ObservedObject var model: AppModel

    private var rect: CGRect {
        model.scenes.selectedScene?.overlayRect
            ?? CGRect(x: 0.72, y: 0.72, width: 0.24, height: 0.24)
    }

    var body: some View {
        LabeledContent("Size") {
            Slider(
                value: Binding(
                    get: { rect.width },
                    set: { newWidth in
                        let aspect = rect.height > 0 ? rect.width / rect.height : 1
                        var updated = rect
                        let anchorX = rect.midX
                        let anchorY = rect.midY
                        updated.size = CGSize(width: newWidth, height: newWidth / aspect)
                        updated.origin = CGPoint(
                            x: anchorX - updated.width / 2,
                            y: anchorY - updated.height / 2
                        )
                        model.setOverlayRect(updated)
                    }
                ),
                in: 0.05...1.0
            )
        }

        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        Button {
                            place(row: row, column: column)
                        } label: {
                            Image(systemName: "square")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func place(row: Int, column: Int) {
        let margin: CGFloat = 0.04
        var updated = rect
        let xs: [CGFloat] = [margin, (1 - rect.width) / 2, 1 - rect.width - margin]
        let ys: [CGFloat] = [margin, (1 - rect.height) / 2, 1 - rect.height - margin]
        updated.origin = CGPoint(x: xs[column], y: ys[row])
        model.setOverlayRect(updated)
        model.scenes.save()
    }
}
