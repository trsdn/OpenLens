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

    func includes(_ serialNumber: String) -> Bool {
        lights[serialNumber] != nil
    }

    /// Adds one lamp at the given state.
    func adding(_ serialNumber: String, state: KeyLightState) -> SceneLighting {
        var copy = self
        copy.lights[serialNumber] = state
        return copy.withFlagFollowingContents()
    }

    /// Removes one lamp, leaving it untouched from now on.
    func removing(_ serialNumber: String) -> SceneLighting {
        var copy = self
        copy.lights.removeValue(forKey: serialNumber)
        return copy.withFlagFollowingContents()
    }

    /// Keeps `isEnabled` honest.
    ///
    /// An enabled scene naming no lamps would claim to drive the lights while
    /// doing nothing, which shows up as a scene that says "1 light" after the
    /// last one is removed, and as a pause that darkens nothing.
    private func withFlagFollowingContents() -> SceneLighting {
        var copy = self
        copy.isEnabled = !copy.lights.isEmpty
        return copy
    }
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

    /// Why the scene list is empty, which decides whether it is safe to write.
    ///
    /// `empty` and `unreadable` look identical to every caller — no scenes —
    /// but they must not be treated the same. Overwriting nothing is free;
    /// overwriting something we merely failed to parse destroys it.
    enum Readability: Equatable {
        /// Nothing has ever been saved, so there is nothing to lose.
        case empty
        case loaded
        /// Scenes exist on disk but could not be decoded. The saved bytes are
        /// kept and writing is refused until the user decides.
        case unreadable(String)
    }

    @Published private(set) var readability: Readability = .empty

    private let defaults: UserDefaults
    private let scenesKey = "scenes.v1"
    private let selectionKey = "scenes.selected.v1"
    private let overlayBookmarkKey = "overlay.bookmark.v1"
    /// Where scenes we could not decode are parked, so a bad release is
    /// recoverable by hand instead of being a permanent loss.
    private let quarantineKey = "scenes.v1.unreadable"
    private let quarantineDateKey = "scenes.v1.unreadable.date"
    private var overlayAccessURL: URL?

    /// Injectable so tests can exercise the load and save rules against a
    /// throwaway suite instead of the user's real preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    var isUnreadable: Bool {
        if case .unreadable = readability { return true }
        return false
    }

    /// The bytes we refused to overwrite, for a recovery UI or a bug report.
    var quarantinedScenes: Data? { defaults.data(forKey: quarantineKey) }

    /// Accepts the loss deliberately, after the user has been told.
    ///
    /// The quarantined copy is left in place: this unblocks saving, it does not
    /// erase the evidence.
    func startFresh() {
        guard isUnreadable else { return }
        readability = .empty
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
        // The one rule that matters: never write over scenes we could not read.
        // Without this, a single decoding failure silently replaces the user's
        // whole library with whatever is in memory (usually one blank scene).
        guard !isUnreadable else { return }
        guard let data = try? JSONEncoder().encode(scenes) else { return }
        defaults.set(data, forKey: scenesKey)
        if let selectedSceneID {
            defaults.set(selectedSceneID.uuidString, forKey: selectionKey)
        }
    }

    private func load() {
        if let data = defaults.data(forKey: scenesKey) {
            do {
                scenes = try JSONDecoder().decode([CameraScene].self, from: data)
                readability = .loaded
            } catch {
                // Park the bytes rather than leaving them one save() away from
                // being clobbered, and refuse to write until the user decides.
                defaults.set(data, forKey: quarantineKey)
                defaults.set(Date(), forKey: quarantineDateKey)
                readability = .unreadable(error.localizedDescription)
                scenes = []
            }
        } else {
            readability = .empty
        }
        if let raw = defaults.string(forKey: selectionKey), let id = UUID(uuidString: raw) {
            selectedSceneID = scenes.contains { $0.id == id } ? id : scenes.first?.id
        } else {
            selectedSceneID = scenes.first?.id
        }
        restoreOverlay()
    }
}
