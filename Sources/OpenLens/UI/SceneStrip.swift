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
        .frame(height: 96)
        .background(Color(nsColor: .underPageBackgroundColor))
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
