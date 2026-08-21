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
            Section("Scene") {
                TextField("Name", text: $sceneName)
                    .onSubmit { model.renameSelectedScene(sceneName) }

                Picker("Camera", selection: deviceBinding) {
                    ForEach(model.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }

                Picker("Capture quality", selection: qualityBinding) {
                    ForEach(CaptureQuality.allCases, id: \.self) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .help(
                    "Capturing above 1080p is what makes zooming lossless: a 4K source can be "
                        + "cropped to 2× with no upscaling."
                )

                Toggle("Mirror", isOn: mirrorBinding)
            }

            Section("Zoom") {
                // The scroll gesture over the preview is the fast path, but it is
                // invisible: without a control here the feature looks missing.
                HStack(spacing: 8) {
                    Button {
                        model.zoomOut()
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .disabled(model.effectiveZoom <= CropGeometry.minZoom + 0.001)

                    Slider(
                        value: Binding(
                            get: { model.effectiveZoom },
                            set: { model.setZoom($0) }
                        ),
                        in: CropGeometry.minZoom...CropGeometry.maxZoom
                    )

                    Button {
                        model.zoomIn()
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .disabled(model.effectiveZoom >= CropGeometry.maxZoom - 0.001)
                }

                LabeledContent("Level") {
                    Text(String(format: "%.2f×", model.effectiveZoom)).monospacedDigit()
                }
                LabeledContent("Lossless up to") {
                    Text(String(format: "%.2f×", model.losslessZoomLimit)).monospacedDigit()
                }
                Button("Reset to full frame") { model.resetZoom() }
                Text(
                    "Scroll or pinch over the preview to zoom around the pointer, drag to pan, "
                        + "double-click to reset. ⌘+ and ⌘- work anywhere in the app."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                Toggle("Show preview", isOn: $model.previewEnabled)
                Text(
                    "Turning the preview off skips one render pass per frame. The virtual "
                        + "camera is unaffected."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Overlay") {
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
