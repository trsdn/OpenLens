import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel

    /// The inspector is draggable because the sliders are the reason to widen
    /// it: at the 280pt default the track is about 120pt for a ±100 range, so a
    /// single pixel is nearly a whole percent and precise dragging is
    /// impossible. Pulling the divider out buys real resolution.
    @AppStorage("inspector.width") private var inspectorWidth: Double = 280
    @State private var widthAtDragStart: Double?

    private static let minInspectorWidth: Double = 260
    private static let maxInspectorWidth: Double = 560

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                previewArea
                inspectorDivider
                InspectorView(model: model)
                    .frame(width: inspectorWidth)
            }
            Divider()
            SceneStrip(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.start() }
        .onDisappear { model.shutdown() }
    }

    /// A hairline with a wider invisible grab area, so the target is hittable
    /// without drawing a thick bar.
    private var inspectorDivider: some View {
        Divider()
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { drag in
                                let start = widthAtDragStart ?? inspectorWidth
                                widthAtDragStart = start
                                inspectorWidth = min(
                                    Self.maxInspectorWidth,
                                    max(Self.minInspectorWidth, start - drag.translation.width)
                                )
                            }
                            .onEnded { _ in widthAtDragStart = nil }
                    )
                    .accessibilityHidden(true)
            }
    }

    private var previewArea: some View {
        ZStack(alignment: .bottomLeading) {
            if model.previewEnabled {
                PreviewView(model: model)
                    .background(.black)
            } else if model.isPaused {
                // Both placeholders centre their own stack, so showing them at
                // once would overlap two blocks of text. "Paused" is the more
                // urgent of the two and wins.
                Color.black
            } else {
                PreviewOffPlaceholder(model: model)
            }

            if model.isPaused {
                PausedOverlay(model: model)
            }

            VStack(alignment: .leading, spacing: 8) {
                if let message = model.errorMessage {
                    HStack(spacing: 8) {
                        banner(message, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                        if !model.cameraAuthorized {
                            Button("Open Privacy Settings") {
                                guard let url = URL(
                                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
                                ) else { return }
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                SceneRecoveryBanner(scenes: model.scenes)
                ExtensionStatusBanner(model: model)
                ZoomBadge(model: model)
            }
            .padding(16)
        }
        .frame(minWidth: 640, minHeight: 360)
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(tint)
    }
}

/// Tells the user that saved scenes could not be read, instead of silently
/// showing an empty app.
///
/// While this is on screen the store refuses to write, so the unreadable data
/// stays recoverable. Starting fresh is therefore a deliberate choice the user
/// makes here, never something an app launch does on their behalf.
struct SceneRecoveryBanner: View {
    @ObservedObject var scenes: SceneStore

    var body: some View {
        if case let .unreadable(reason) = scenes.readability {
            HStack(spacing: 8) {
                Label(
                    "Your saved scenes could not be read, so OpenLens has not touched them",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                Button("Start Fresh") { scenes.startFresh() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .help(
                "Nothing has been overwritten — saving stays switched off until you "
                    + "choose. The original data is kept under the \"scenes.v1.unreadable\" "
                    + "key in OpenLens's preferences. Reason: \(reason)"
            )
        }
    }
}

/// Shown instead of the live preview when it is switched off.
///
/// The virtual camera keeps running — only the on-screen copy stops, which is
/// the point: during a long call the preview is the only part of the pipeline
/// nobody is looking at.
struct PreviewOffPlaceholder: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Preview off")
                    .font(.headline)
                Text("The virtual camera keeps running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show preview") { model.previewEnabled = true }
                    .keyboardShortcut("p", modifiers: .command)
            }
        }
    }
}

/// Says "paused" over the preview, loudly.
///
/// The whole risk of a pause button is forgetting it is on, so this is a
/// full-bleed tint rather than another discreet pill in the corner.
struct PausedOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var client: ExtensionClient

    init(model: AppModel) {
        self.model = model
        self.client = model.extensionClient
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 12) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 44))
                Text("Paused")
                    .font(.title2.weight(.semibold))
                Text(
                    client.isStreaming
                        ? "Your call sees a still picture. The camera is off."
                        : "Your call will see a still picture. The camera is off."
                )
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                Button("Resume") { model.setPaused(false) }
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .allowsHitTesting(true)
        .transition(.opacity)
    }
}

/// A status readout, not a second control: while you are dragging in the picture
/// your eyes are here, not in the inspector.
///
/// It says "soft" in words rather than flashing a bare warning triangle, because
/// a lone `!` tells you something is wrong without telling you what.
struct ZoomBadge: View {
    @ObservedObject var model: AppModel

    private var isUpscaling: Bool {
        model.effectiveZoom > model.losslessZoomLimit + 0.01
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
            Text(String(format: "%.1f×", model.effectiveZoom))
                .monospacedDigit()
            if isUpscaling {
                Text("· soft")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .help(
            isUpscaling
                ? "Past \(String(format: "%.1f×", model.losslessZoomLimit)) the picture is "
                    + "enlarged rather than cropped, so it gets soft. Raise Capture quality "
                    + "in the inspector for more sharp zoom."
                : "Current zoom. Set it in the inspector, or scroll over the picture."
        )
    }
}

struct ExtensionStatusBanner: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var installer: SystemExtensionInstaller
    @ObservedObject private var client: ExtensionClient

    init(model: AppModel) {
        self.model = model
        self.installer = model.installer
        self.client = model.extensionClient
    }

    var body: some View {
        switch installer.state {
        case .installed, .unknown:
            if client.isStreaming {
                pill("Live in your conferencing app", icon: "dot.radiowaves.left.and.right", tint: .green)
            } else if client.isConnected {
                // "Ready" is the normal resting state, not a step on the way to
                // something. Saying only "pick OpenLens as your camera" reads as
                // a promise that the banner will change once you pick it — but
                // conferencing apps do not open a camera when you select it in a
                // menu, only when video is actually switched on.
                pill(
                    "Ready — now turn your video on in Teams, Zoom or Meet",
                    icon: "camera",
                    tint: .secondary
                )
                .help(
                    "The camera is published and waiting. Choosing \"OpenLens\" in a "
                        + "settings menu is not enough — apps only open a camera once video "
                        + "is switched on, in a call or in their device preview. This turns "
                        + "green the moment that happens."
                )
            } else if client.isStalled {
                HStack(spacing: 8) {
                    pill(
                        "Lost contact with the camera extension — this happens after it updates",
                        icon: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                    Button("Restart OpenLens") { Self.relaunch() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                pill("Connecting to the camera extension…", icon: "hourglass", tint: .secondary)
            }
        case .installing:
            pill("Installing the camera extension…", icon: "hourglass", tint: .secondary)
        case .needsApproval:
            HStack(spacing: 8) {
                pill(
                    "Approve OpenLens in System Settings › General › Login Items & Extensions",
                    icon: "lock.shield",
                    tint: .orange
                )
                Button("Open Settings") { Self.openLoginItemsSettings() }
                    .buttonStyle(.borderedProminent)
            }
        case .needsReboot:
            pill("Restart your Mac to finish installing the camera", icon: "arrow.clockwise", tint: .orange)
        case .failed(let message):
            pill(message, icon: "exclamationmark.triangle.fill", tint: .red)
        }
    }

    /// Deep link straight to the pane that lists system extensions; hunting for
    /// it manually is the single most common place first-run gets stuck.
    static func openLoginItemsSettings() {        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Starts a fresh copy and quits this one.
    ///
    /// When the camera extension is replaced underneath a running app, this
    /// process's CoreMediaIO client state dies with the old extension and no
    /// amount of retrying brings it back — but a new process finds the camera
    /// immediately. So the honest fix is a relaunch, one click instead of a
    /// spinner that never resolves.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func pill(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
    }
}
