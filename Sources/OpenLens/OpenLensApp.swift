import SwiftUI

@main
struct OpenLensApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("OpenLens", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Scene") {
                // Option-number is deliberately not a plain number: the shortcut
                // has to survive being pressed while a text field has focus.
                ForEach(0..<9, id: \.self) { index in
                    Button("Switch to Scene \(index + 1)") {
                        model.selectScene(at: index)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")),
                        modifiers: .option
                    )
                }
                Divider()
                Button("New Scene") { model.addScene() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Duplicate Scene") { model.duplicateSelectedScene() }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Delete Scene") { model.removeSelectedScene() }
                Divider()
                Button("Zoom In") { model.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { model.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Zoom") { model.resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
            }

            CommandMenu("View") {
                Toggle("Show Preview", isOn: $model.previewEnabled)
                    .keyboardShortcut("p", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button("Reinstall Camera Extension") { model.installer.activate() }
                Button("Remove Camera Extension") { model.installer.deactivate() }
            }
        }
    }
}
