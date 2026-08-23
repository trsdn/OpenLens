import CoreGraphics
import Foundation

/// What a scene wants the lights to do.
///
/// Opt-in on purpose. A scene exists to be switched to mid-call, and if every
/// scene drove the lamps then changing the crop would also change the lighting.
/// A scene with this turned off leaves the room exactly as it found it.
struct SceneLighting: Codable, Equatable {
    var isEnabled: Bool = false
    /// Keyed by serial number, because that is the only stable name a lamp has.
    /// Lamps absent from this dictionary are deliberately not touched.
    var lights: [String: KeyLightState] = [:]

    static let off = SceneLighting()

    var activeCount: Int { lights.count }
}

/// One saved look: a camera, a crop, and how the overlay sits on top of it.
struct CameraScene: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var deviceID: String
    var deviceName: String
    var crop: CropState = .identity
    var mirrored: Bool = false
    var quality: CaptureQuality = .losslessZoom
    var overlayEnabled: Bool = false
    /// Placement in normalized output space, top-left origin.
    var overlayRect: CGRect = CGRect(x: 0.72, y: 0.72, width: 0.24, height: 0.24)
    var overlayOpacity: Double = 1.0

    /// Stored as an optional purely so that scenes written before colour
    /// correction existed keep loading. Swift's synthesised decoder ignores a
    /// property's default value and throws on a missing key, so a plain
    /// non-optional here would discard every previously saved scene.
    private var storedAdjustments: ImageAdjustments?

    /// Optional for the same reason as `storedAdjustments`, and additionally
    /// because nil carries meaning here: a scene that predates lighting must
    /// read as "does not drive the lights", not as "wants them all off".
    private var storedLighting: SceneLighting?

    var adjustments: ImageAdjustments {
        get { storedAdjustments ?? .neutral }
        set { storedAdjustments = newValue }
    }

    var lighting: SceneLighting {
        get { storedLighting ?? .off }
        set { storedLighting = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, deviceID, deviceName, crop, mirrored, quality
        case overlayEnabled, overlayRect, overlayOpacity
        case storedAdjustments = "adjustments"
        case storedLighting = "lighting"
    }

    /// Spelled out because the private stored property above would otherwise
    /// make the synthesised memberwise initialiser private too.
    init(
        id: UUID = UUID(),
        name: String,
        deviceID: String,
        deviceName: String,
        crop: CropState = .identity,
        mirrored: Bool = false,
        quality: CaptureQuality = .losslessZoom,
        overlayEnabled: Bool = false,
        overlayRect: CGRect = CGRect(x: 0.72, y: 0.72, width: 0.24, height: 0.24),
        overlayOpacity: Double = 1.0,
        adjustments: ImageAdjustments = .neutral,
        lighting: SceneLighting = .off
    ) {
        self.id = id
        self.name = name
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.crop = crop
        self.mirrored = mirrored
        self.quality = quality
        self.overlayEnabled = overlayEnabled
        self.overlayRect = overlayRect
        self.overlayOpacity = overlayOpacity
        self.storedAdjustments = adjustments
        self.storedLighting = lighting
    }
}

/// Persists scenes and the overlay image reference.
///
/// The overlay is stored as a security-scoped bookmark because the app is
/// sandboxed: a plain path would stop resolving after relaunch.
@MainActor
final class SceneStore: ObservableObject {
    @Published var scenes: [CameraScene] = []
    @Published var selectedSceneID: UUID?
    @Published private(set) var overlayURL: URL?

    private let defaults = UserDefaults.standard
    private let scenesKey = "scenes.v1"
    private let selectionKey = "scenes.selected.v1"
    private let overlayBookmarkKey = "overlay.bookmark.v1"
    private var overlayAccessURL: URL?

    init() {
        load()
    }

    var selectedScene: CameraScene? {
        guard let selectedSceneID else { return nil }
        return scenes.first { $0.id == selectedSceneID }
    }

    func update(_ scene: CameraScene) {
        guard let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[index] = scene
        save()
    }

    /// Mutates the selected scene without triggering a save per frame — callers
    /// that change the crop continuously use this and save on gesture end.
    func mutateSelected(_ body: (inout CameraScene) -> Void) {
        guard let selectedSceneID,
              let index = scenes.firstIndex(where: { $0.id == selectedSceneID })
        else { return }
        body(&scenes[index])
    }

    @discardableResult
    func addScene(device: CaptureDeviceInfo) -> CameraScene {
        let scene = CameraScene(
            name: "Scene \(scenes.count + 1)",
            deviceID: device.id,
            deviceName: device.name
        )
        scenes.append(scene)
        selectedSceneID = scene.id
        save()
        return scene
    }

    func duplicateSelected() {
        guard var scene = selectedScene else { return }
        scene.id = UUID()
        scene.name = "\(scene.name) copy"
        scenes.append(scene)
        selectedSceneID = scene.id
        save()
    }

    func remove(_ scene: CameraScene) {
        scenes.removeAll { $0.id == scene.id }
        if selectedSceneID == scene.id { selectedSceneID = scenes.first?.id }
        save()
    }

    func select(_ scene: CameraScene) {
        selectedSceneID = scene.id
        defaults.set(scene.id.uuidString, forKey: selectionKey)
    }

    func selectScene(at index: Int) {
        guard scenes.indices.contains(index) else { return }
        select(scenes[index])
    }

    // MARK: - Overlay

    func setOverlay(url: URL?) {
        overlayAccessURL?.stopAccessingSecurityScopedResource()
        overlayAccessURL = nil

        guard let url else {
            defaults.removeObject(forKey: overlayBookmarkKey)
            overlayURL = nil
            return
        }
        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(data, forKey: overlayBookmarkKey)
        }
        _ = url.startAccessingSecurityScopedResource()
        overlayAccessURL = url
        overlayURL = url
    }

    private func restoreOverlay() {
        guard let data = defaults.data(forKey: overlayBookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        overlayAccessURL = url
        overlayURL = url
    }

    // MARK: - Persistence

    func save() {
        guard let data = try? JSONEncoder().encode(scenes) else { return }
        defaults.set(data, forKey: scenesKey)
        if let selectedSceneID {
            defaults.set(selectedSceneID.uuidString, forKey: selectionKey)
        }
    }

    private func load() {
        if let data = defaults.data(forKey: scenesKey),
           let decoded = try? JSONDecoder().decode([CameraScene].self, from: data) {
            scenes = decoded
        }
        if let raw = defaults.string(forKey: selectionKey), let id = UUID(uuidString: raw) {
            selectedSceneID = scenes.contains { $0.id == id } ? id : scenes.first?.id
        } else {
            selectedSceneID = scenes.first?.id
        }
        restoreOverlay()
    }
}
