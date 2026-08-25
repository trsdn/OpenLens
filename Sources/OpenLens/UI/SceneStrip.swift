import SwiftUI

/// The row of scenes along the bottom, mirroring how Detail lays them out.
///
/// Thumbnails are intentionally cheap static cards rather than live video: a
/// strip of live previews would multiply the render cost by the scene count for
/// almost no benefit during a call.
struct SceneStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var scenes: SceneStore

    init(model: AppModel) {
        self.model = model
        self.scenes = model.scenes
    }

    var body: some View {
        HStack(spacing: 0) {
            strip
            Divider()
            PauseButton(model: model)
                .padding(.horizontal, 12)
        }
        .frame(height: 96)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// The pause control sits outside the scroll view: it must never scroll out
    /// of reach mid-call, which is exactly when it is needed.
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(scenes.scenes.enumerated()), id: \.element.id) { index, scene in
                    SceneCard(
                        scene: scene,
                        index: index,
                        isSelected: scene.id == scenes.selectedSceneID
                    )
                    .onTapGesture { model.select(scene) }
                    .contextMenu {
                        Button("Duplicate") {
                            model.select(scene)
                            model.duplicateSelectedScene()
                        }
                        Button("Delete", role: .destructive) {
                            model.select(scene)
                            model.removeSelectedScene()
                        }
                    }
                }

                Button {
                    model.addScene()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Scene").font(.caption)
                    }
                    .frame(width: 96, height: 62)
                }
                .buttonStyle(.bordered)
                .disabled(model.devices.isEmpty)
            }
            .padding(12)
        }
    }
}

/// Freezes the outgoing picture without giving up the camera.
///
/// Leaving the call's camera entirely makes conferencing apps show "camera off"
/// and sometimes drop the device; a frozen frame keeps the slot warm and resumes
/// instantly.
struct PauseButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button {
            model.togglePause()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text(model.isPaused ? "Resume" : "Pause")
                    .font(.caption)
            }
            .frame(width: 76, height: 62)
        }
        .buttonStyle(.bordered)
        .tint(model.isPaused ? .orange : nil)
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .help(
            model.isPaused
                ? "Resume sending live video and put the scene's lights back "
                    + "(⌥P works from any app)."
                : "Freeze the picture your call sees on the current frame, release "
                    + "the camera so its light goes out, and switch off the lights "
                    + "this scene owns. ⌥P works from any app."
        )
    }
}

struct SceneCard: View {
    let scene: CameraScene
    let index: Int
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "video.fill")
                    .font(.caption2)
                Text(scene.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if index < 9 {
                    Text("⌥\(index + 1)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Text(scene.deviceName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(String(format: "%.1f×", scene.crop.zoom))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: 132, height: 62, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
}
