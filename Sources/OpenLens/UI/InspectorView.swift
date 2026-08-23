import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var scenes: SceneStore
    @State private var sceneName = ""

    // Which sections are open, remembered across launches.
    //
    // The panel holds roughly 1,400pt of controls in a window that offers
    // around 900, so something is always out of sight. Rather than leave that
    // to scrolling, the sections you set once and never touch again start
    // shut, and the ten tone and colour sliders — the only controls touched
    // per session — start open and fit without scrolling at all.
    @AppStorage("inspector.expanded.scene") private var sceneExpanded = false
    @AppStorage("inspector.expanded.zoom") private var zoomExpanded = false
    @AppStorage("inspector.expanded.tone") private var toneExpanded = true
    @AppStorage("inspector.expanded.colour") private var colourExpanded = true
    @AppStorage("inspector.expanded.lighting") private var lightingExpanded = false
    @AppStorage("inspector.expanded.output") private var outputExpanded = false
    @AppStorage("inspector.expanded.splitTone") private var splitToneExpanded = false

    init(model: AppModel) {
        self.model = model
        self.scenes = model.scenes
    }

    var body: some View {
        Form {
            Section(isExpanded: $sceneExpanded) {
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
                        + "new scene, and ⌥1…⌥9 switch between them even while you are in a call.",
                    summary: sceneSummary
                )
            }

            Section(isExpanded: $zoomExpanded) {
                // Two rows, not one: at its narrowest the inspector is only
                // ~240pt wide, and a slider sharing a row with a text field and
                // two buttons collapses to a stub you cannot aim at.
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
                        + "calls out. Raising Capture quality pushes that limit further out.",
                    summary: String(format: "%.1f×", model.effectiveZoom),
                    summaryIsActive: model.effectiveZoom != 1
                )
            }

            Section(isExpanded: $toneExpanded) {
                AdjustmentSlider(
                    title: "Exposure",
                    value: adjustmentBinding(\.exposure),
                    range: ImageAdjustments.exposureRange,
                    onCommit: { model.commitAdjustments() },
                    scale: .stops
                )
                AdjustmentSlider(
                    title: "Black point",
                    value: adjustmentBinding(\.blackPoint),
                    range: ImageAdjustments.unitRange,
                    onCommit: { model.commitAdjustments() },
                    scale: .percent
                )
                AdjustmentSlider(
                    title: "White point",
                    value: adjustmentBinding(\.whitePoint),
                    range: ImageAdjustments.unitRange,
                    onCommit: { model.commitAdjustments() },
                    scale: .percent
                )
                AdjustmentSlider(
                    title: "Midtones",
                    value: adjustmentBinding(\.midtones),
                    range: ImageAdjustments.unitRange,
                    onCommit: { model.commitAdjustments() },
                    scale: .percent
                )
                AdjustmentSlider(
                    title: "Contrast",
                    value: adjustmentBinding(\.contrast),
                    range: ImageAdjustments.unitRange,
                    onCommit: { model.commitAdjustments() },
                    scale: .percent
                )
            } header: {
                SectionHeader(
                    "Tone",
                    info: "Where the picture's black and white land, and how it is shaped "
                        + "in between.\n\n"
                        + "macOS exposes no exposure or white balance control for a capture "
                        + "device, so everything in this section and the next is applied to "
                        + "the picture itself rather than to the camera. It rides along in "
                        + "the GPU pass that already crops every frame, which is why it "
                        + "costs nothing measurable. Drag for a rough value — the slider "
                        + "snaps to neutral near the middle — or type an exact number in "
                        + "the field. Double-click a label to put that one control back to "
                        + "neutral. Each scene keeps its own settings.\n\n"
                        + "Most cameras hand over a signal whose darkest pixel is not "
                        + "actually black, which is what makes a picture look milky no "
                        + "matter how much contrast you add. Black point is the fix: raise "
                        + "it until the shadows close, and the picture gains depth without "
                        + "anything else moving.\n\n"
                        + "White point does the same at the top, but has far less room — "
                        + "a lit face is usually close to white already, and pulling the "
                        + "white point down burns the brightest skin to a flat patch. "
                        + "Midtones then brightens or darkens everything between the two "
                        + "end points, leaving both of them where you put them.\n\n"
                        + "Contrast is an S-curve rather than a straight slope, so it "
                        + "steepens the midtones and fades out towards both ends. It "
                        + "cannot clip a highlight.",
                    summary: Self.changeSummary(count: toneChangeCount),
                    summaryIsActive: toneChangeCount > 0
                )
            }

            Section(isExpanded: $colourExpanded) {
                AdjustmentSlider(
                    title: "White balance",
                    value: adjustmentBinding(\.temperature),
                    range: ImageAdjustments.unitRange,
                    onCommit: { model.commitAdjustments() },
                    scale: .warmth
                )
                AdjustmentSlider(
                    title: "Tint",
                    value: adjustmentBinding(\.tint),
                    range: ImageAdjustments.unitRange,
                    onCommit: { model.commitAdjustments() },
                    scale: .tint
                )
                // Split toning is the one pair here that a normal session never
                // needs — it only earns its place when the key light and the
                // ambient light disagree — so it is folded away by default
                // rather than costing two rows in every session.
                DisclosureGroup(isExpanded: $splitToneExpanded) {
                    AdjustmentSlider(
                        title: "Shadow tint",
                        value: adjustmentBinding(\.shadowWarmth),
                        range: ImageAdjustments.unitRange,
                        onCommit: { model.commitAdjustments() },
                        scale: .warmth
                    )
                    AdjustmentSlider(
                        title: "Highlight tint",
                        value: adjustmentBinding(\.highlightWarmth),
                        range: ImageAdjustments.unitRange,
                        onCommit: { model.commitAdjustments() },
                        scale: .warmth
                    )
                } label: {
                    HStack(spacing: 4) {
                        Text("Split toning")
                        // A shut group must not hide a value that is doing
                        // something, or the picture ends up with a cast whose
                        // cause is nowhere on screen.
                        if splitToneIsActive {
                            Circle()
                                .fill(.tint)
                                .frame(width: 5, height: 5)
                                .accessibilityLabel("Adjusted")
                        }
                    }
                }

                AdjustmentSlider(
                    title: "Saturation",
                    value: adjustmentBinding(\.saturation),
                    range: ImageAdjustments.unitRange,
                    onCommit: { model.commitAdjustments() },
                    scale: .percent
                )

                Button("Reset to neutral") { model.resetAdjustments() }
                    .disabled(model.adjustments.isNeutral)
            } header: {
                SectionHeader(
                    "Colour",
                    info: "White balance shifts the whole picture between amber and blue. "
                        + "Tint is the second axis, between green and magenta. Shadow tint "
                        + "and Highlight tint apply the amber/blue shift to one end of the "
                        + "scale only.\n\n"
                        + "Two axes rather than one because a cast on either is invisible "
                        + "to the other: amber/blue is what changes when a light gets "
                        + "hotter or colder, green/magenta is what happens when the light "
                        + "is not a black body at all. LED and fluorescent lamps sit off "
                        + "that axis, and so does any camera picture profile that reshapes "
                        + "skin. If white balance alone never quite lands — the picture "
                        + "goes orange before the colour looks right — the cast is on the "
                        + "tint axis and no amount of warming will reach it. Skin is where "
                        + "this shows first: a magenta cast reads as blotchy or flushed "
                        + "rather than as a colour error.\n\n"
                        + "Those last two exist because a room rarely has a single colour "
                        + "temperature. A warm lamp on your face and cooler daylight "
                        + "filling the shadows leave a cast that runs in opposite "
                        + "directions at opposite ends of the picture, and no single white "
                        + "balance can correct both — warm it up for the shadows and the "
                        + "face turns orange. Warm the shadows on their own instead and "
                        + "black becomes black again.\n\n"
                        + "Reset puts every control in both sections back to neutral.",
                    summary: Self.changeSummary(count: colourChangeCount),
                    summaryIsActive: colourChangeCount > 0
                )
            }

            LightingSection(model: model, isExpanded: $lightingExpanded)

            // Preview and Overlay were a section each, which cost two headers
            // for three controls. They belong together: both are about what
            // leaves the app rather than how the picture is graded.
            Section(isExpanded: $outputExpanded) {
                Toggle("Show preview", isOn: $model.previewEnabled)

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
                    "Output",
                    info: "Turning the preview off skips one render pass per frame and frees "
                        + "the window. The virtual camera is unaffected. On Apple silicon the "
                        + "saving is well under a percent, so treat this as a way to clear "
                        + "the screen rather than a performance fix.\n\n"
                        + "The overlay is a PNG with transparency composited on top of the "
                        + "picture in the same GPU pass, so it is free. Use it for a logo or "
                        + "a lower third. Drag it in the picture to move it and pull a corner "
                        + "to resize it; double-click it to reset the size. Dragging anywhere "
                        + "else still pans the crop. The aspect ratio comes from the image "
                        + "and is kept.",
                    summary: outputSummary,
                    summaryIsActive: !model.previewEnabled || (scenes.selectedScene?.overlayEnabled ?? false)
                )
            }
        }
        .formStyle(.grouped)
        .onAppear { sceneName = scenes.selectedScene?.name ?? "" }
        .onChange(of: scenes.selectedSceneID) { _, _ in
            sceneName = scenes.selectedScene?.name ?? ""
        }
    }

    // MARK: - Section summaries

    /// What a shut section reports about itself.
    private var sceneSummary: String? {
        model.devices.first { $0.id == scenes.selectedScene?.deviceID }?.name
    }

    private var outputSummary: String {
        var parts: [String] = []
        if !model.previewEnabled { parts.append("preview off") }
        if scenes.selectedScene?.overlayEnabled == true { parts.append("overlay on") }
        return parts.isEmpty ? "Default" : parts.joined(separator: ", ")
    }

    private var toneChangeCount: Int {
        Self.nonNeutralCount(
            model.adjustments,
            [\.exposure, \.blackPoint, \.whitePoint, \.midtones, \.contrast]
        )
    }

    private var colourChangeCount: Int {
        Self.nonNeutralCount(
            model.adjustments,
            [\.temperature, \.tint, \.shadowWarmth, \.highlightWarmth, \.saturation]
        )
    }

    private var splitToneIsActive: Bool {
        model.adjustments.shadowWarmth != 0 || model.adjustments.highlightWarmth != 0
    }

    private static func nonNeutralCount(
        _ adjustments: ImageAdjustments,
        _ keyPaths: [KeyPath<ImageAdjustments, Double>]
    ) -> Int {
        keyPaths.count { adjustments[keyPath: $0] != 0 }
    }

    private static func changeSummary(count: Int) -> String {
        count == 0 ? "Neutral" : "\(count) adjusted"
    }

    private func chooseOverlay() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .tiff, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { model.chooseOverlay(url: panel.url) }
    }

    // MARK: - Bindings

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

/// How a raw adjustment value is spelled out in its field.
///
/// The stored values are all neutral at zero and dimensionless apart from
/// exposure, so the field shows them in the unit a photographer expects — stops
/// for exposure, percent for the rest — and converts back on the way in.
struct AdjustmentScale {
    /// Raw value multiplied by this is the number in the field.
    let displayScale: Double
    let fractionLength: Int
    let unit: String
    /// A word for the direction of the value, shown next to the field when
    /// there is nothing else to say what "+20" means.
    let caption: (Double) -> String?

    static let stops = AdjustmentScale(
        displayScale: 1,
        fractionLength: 1,
        unit: "EV",
        caption: { _ in nil }
    )

    static let percent = AdjustmentScale(
        displayScale: 100,
        fractionLength: 0,
        unit: "%",
        caption: { _ in nil }
    )

    static let warmth = AdjustmentScale(
        displayScale: 100,
        fractionLength: 0,
        unit: "%",
        caption: { value in
            guard value != 0 else { return nil }
            return value > 0 ? "warm" : "cool"
        }
    )

    static let tint = AdjustmentScale(
        displayScale: 100,
        fractionLength: 0,
        unit: "%",
        caption: { value in
            guard value != 0 else { return nil }
            return value > 0 ? "magenta" : "green"
        }
    )
}

/// A slider that is neutral in the middle, with an editable number beside it.
///
/// Two rows rather than one: the inspector is only ~240pt wide, and a slider
/// sharing a row with a label and a field collapses to a stub you cannot aim
/// at. The write to disk is deferred to the end of the drag via
/// `onEditingChanged`, so dragging does not serialise the scene list on every
/// frame.
///
/// Dragging snaps to zero inside a small dead zone, because these controls are
/// only useful if "untouched" is reachable without aiming; typing a number
/// bypasses the snap, so an exact 3 % is still possible.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onCommit: () -> Void
    let scale: AdjustmentScale

    /// Writes are debounced rather than tied to the end of a drag, because a
    /// drag is not the only way to move the value: arrow keys and VoiceOver
    /// never end an "editing session", so anything committed only from
    /// `onEditingChanged` was silently lost on the next launch.
    @State private var commitTask: Task<Void, Never>?

    /// The number as typed, held verbatim until the edit ends.
    ///
    /// Parsing on every keystroke cannot work: on the way to 56 the field
    /// briefly holds 5, which is a legal value, so it was clamped and written
    /// back under the cursor — and the remaining digits then landed on the
    /// clamped number. Typing 56 into a field showing 42 produced 100.
    @State private var editingText: String?
    @FocusState private var isEditing: Bool

    /// Three percent of the travel — wide enough to catch a mouse, narrow
    /// enough that the knob does not feel stuck.
    private var snapDistance: Double { (range.upperBound - range.lowerBound) * 0.03 }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { value },
            set: { value = abs($0) < snapDistance ? 0 : $0 }
        )
    }

    private var displayText: String {
        (value * scale.displayScale)
            .formatted(.number.precision(.fractionLength(scale.fractionLength)))
    }

    private var fieldBinding: Binding<String> {
        Binding(
            get: { editingText ?? displayText },
            set: { editingText = $0 }
        )
    }

    /// Accepts both decimal separators, so a value typed on a German keyboard
    /// is not silently discarded.
    static func parse(_ text: String) -> Double? {
        NumberFieldValue.parse(text)
    }

    /// Clamps once, at the end. An out-of-range number is pinned to the
    /// nearest end rather than rejected, which is what a dragged slider does.
    static func clamp(_ typed: Double, scale: AdjustmentScale, range: ClosedRange<Double>) -> Double {
        NumberFieldValue.clamp(typed, displayScale: scale.displayScale, range: range)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                    .onTapGesture(count: 2) {
                        value = 0
                        commitNow()
                    }
                    .help("Double-click the label to reset this to neutral.")
                // Ten sliders in a column look identical at a glance, and the
                // number alone does not separate "0" from "not touched" quickly
                // enough. The dot answers "what have I actually changed?"
                // without reading a single figure.
                if value != 0 {
                    Circle()
                        .fill(.tint)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Adjusted")
                }
                Spacer(minLength: 0)
                if let caption = scale.caption(value) {
                    Text(caption)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                }
                TextField("", text: fieldBinding)
                .focused($isEditing)
                .onSubmit { commitText() }
                .onChange(of: isEditing) { _, editing in
                    if !editing { commitText() }
                }
                .onExitCommand { editingText = nil; isEditing = false }
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 40)
                .accessibilityLabel("\(title) value")
                Text(scale.unit)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Slider(value: sliderBinding, in: range) { editing in
                if !editing { commitNow() }
            }
            .accessibilityLabel(title)
        }
        .onChange(of: value) { _, _ in scheduleCommit() }
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            onCommit()
        }
    }

    private func commitNow() {
        commitTask?.cancel()
        commitTask = nil
        onCommit()
    }

    /// Runs once the edit is over, not per keystroke. A field left empty or
    /// holding something unparseable snaps back to the current value rather
    /// than resetting the control to zero.
    private func commitText() {
        defer { editingText = nil }
        guard let typed = editingText.flatMap(Self.parse) else { return }
        value = Self.clamp(typed, scale: scale, range: range)
        commitNow()
    }
}

/// Numbers and snap positions for the overlay.
///
/// Dragging in the preview is the primary way to place it; this is here for the
/// cases dragging is bad at — an exact percentage, and getting back to a corner
/// without aiming.
struct OverlayPlacementControls: View {
    @ObservedObject var model: AppModel

    private static let margin: CGFloat = 0.04

    private var rect: CGRect {
        model.scenes.selectedScene?.overlayRect
            ?? CGRect(x: 0.72, y: 0.72, width: 0.24, height: 0.24)
    }

    /// Percentages read better than 0…1 fractions, and are what the numbers on
    /// screen have to agree with.
    private var sizeBinding: Binding<Double> {
        Binding(
            get: { Double(rect.width) * 100 },
            set: { model.setOverlayRect(OverlayGeometry.scaled(rect, toWidth: CGFloat($0) / 100)) }
        )
    }

    private func originBinding(_ axis: KeyPath<CGPoint, CGFloat>) -> Binding<Double> {
        Binding(
            get: { Double(rect.origin[keyPath: axis]) * 100 },
            set: { newValue in
                let target = CGFloat(newValue) / 100
                let delta = axis == \.x
                    ? CGSize(width: target - rect.minX, height: 0)
                    : CGSize(width: 0, height: target - rect.minY)
                model.setOverlayRect(OverlayGeometry.moved(rect, by: delta))
            }
        )
    }

    var body: some View {
        LabeledContent("Size") {
            HStack(spacing: 6) {
                TextField(
                    "Size",
                    value: sizeBinding,
                    format: .number.precision(.fractionLength(0))
                )
                .multilineTextAlignment(.trailing)
                .frame(width: 40)
                .onSubmit { model.commitOverlayRect() }
                Text("%").foregroundStyle(.secondary)
                Slider(
                    value: sizeBinding,
                    in: Double(OverlayGeometry.minimumWidth) * 100...100,
                    onEditingChanged: { editing in
                        if !editing { model.commitOverlayRect() }
                    }
                )
            }
        }
        .accessibilityLabel("Overlay size")

        LabeledContent("Position") {
            HStack(spacing: 6) {
                Text("X").foregroundStyle(.secondary)
                TextField("X", value: originBinding(\.x), format: .number.precision(.fractionLength(0)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 40)
                    .onSubmit { model.commitOverlayRect() }
                Text("Y").foregroundStyle(.secondary)
                TextField("Y", value: originBinding(\.y), format: .number.precision(.fractionLength(0)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 40)
                    .onSubmit { model.commitOverlayRect() }
                Text("%").foregroundStyle(.secondary)
            }
        }

        LabeledContent("Snap to") {
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in
                            Button {
                                place(row: row, column: column)
                            } label: {
                                Image(systemName: symbol(row: row, column: column))
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.bordered)
                            .tint(isPlaced(row: row, column: column) ? .accentColor : nil)
                            .help(name(row: row, column: column))
                            .accessibilityLabel(name(row: row, column: column))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Snapping

    private func placement(row: Int, column: Int) -> CGPoint {
        let xs: [CGFloat] = [Self.margin, (1 - rect.width) / 2, 1 - rect.width - Self.margin]
        let ys: [CGFloat] = [Self.margin, (1 - rect.height) / 2, 1 - rect.height - Self.margin]
        return CGPoint(x: xs[column], y: ys[row])
    }

    private func place(row: Int, column: Int) {
        var updated = rect
        updated.origin = placement(row: row, column: column)
        model.setOverlayRect(OverlayGeometry.moved(updated, by: .zero))
        model.commitOverlayRect()
    }

    /// Marks the button the overlay is currently sitting on, so the grid says
    /// where the overlay *is* and not only where it could go.
    private func isPlaced(row: Int, column: Int) -> Bool {
        let target = placement(row: row, column: column)
        return abs(target.x - rect.minX) < 0.005 && abs(target.y - rect.minY) < 0.005
    }

    private func symbol(row: Int, column: Int) -> String {
        let names = [
            ["arrow.up.left", "arrow.up", "arrow.up.right"],
            ["arrow.left", "smallcircle.filled.circle", "arrow.right"],
            ["arrow.down.left", "arrow.down", "arrow.down.right"]
        ]
        return names[row][column]
    }

    private func name(row: Int, column: Int) -> String {
        let vertical = ["Top", "Middle", "Bottom"][row]
        let horizontal = ["left", "centre", "right"][column]
        return row == 1 && column == 1 ? "Centre" : "\(vertical) \(horizontal)"
    }
}
