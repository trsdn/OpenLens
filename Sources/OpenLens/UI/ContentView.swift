import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                previewArea
                Divider()
                InspectorView(model: model)
                    .frame(width: 280)
            }
            Divider()
            SceneStrip(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.start() }
        .onDisappear { model.shutdown() }
    }

    private var previewArea: some View {
        ZStack(alignment: .bottomLeading) {
            PreviewView(model: model)
                .background(.black)

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

/// Mirrors Detail's little zoom pill, plus a warning once the crop starts
/// upscaling — which is the moment picture quality actually degrades.
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
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(
                        "Past \(String(format: "%.1f×", model.losslessZoomLimit)) the picture is "
                            + "upscaled. Raise the capture quality for more lossless zoom."
                    )
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
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
                pill("Ready — pick \"OpenLens\" as your camera", icon: "camera", tint: .secondary)
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
    static func openLoginItemsSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
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
