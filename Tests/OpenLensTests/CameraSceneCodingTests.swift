import XCTest

/// Guards the on-disk scene format.
///
/// Scenes are the user's presets and the only state the app persists, so a
/// decoding change that throws does not degrade gracefully — `SceneStore.load`
/// drops the whole array and the user is left with an empty app.
final class CameraSceneCodingTests: XCTestCase {
    /// Exactly the shape written by the released version, before colour
    /// correction existed.
    private let legacyJSON = """
        [{
          "id": "6C7A1D9E-4B2F-4A1E-9C3D-5E8F0A1B2C3D",
          "name": "Desk",
          "deviceID": "cam-link-4k",
          "deviceName": "Cam Link 4K",
          "crop": { "center": [0.5, 0.5], "zoom": 1.4 },
          "mirrored": true,
          "quality": "losslessZoom",
          "overlayEnabled": false,
          "overlayRect": [[0.72, 0.72], [0.24, 0.24]],
          "overlayOpacity": 1
        }]
        """

    func testScenesSavedBeforeColourCorrectionStillLoad() throws {
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let scenes = try JSONDecoder().decode([CameraScene].self, from: data)

        let scene = try XCTUnwrap(scenes.first)
        XCTAssertEqual(scene.name, "Desk")
        XCTAssertEqual(scene.crop.zoom, 1.4, accuracy: 1e-9)
        XCTAssertTrue(scene.mirrored)
        // The missing key must read back as neutral rather than throwing.
        XCTAssertEqual(scene.adjustments, .neutral)
        // And the scene must read as "leaves the lights alone" rather than as
        // "wants them all off", which would darken the room on first launch.
        XCTAssertFalse(scene.lighting.isEnabled)
        XCTAssertTrue(scene.lighting.lights.isEmpty)
    }

    func testLightingSurvivesASaveAndReload() throws {
        var scene = CameraScene(name: "Desk", deviceID: "cam", deviceName: "Cam")
        scene.lighting = SceneLighting(
            isEnabled: true,
            lights: ["CW31L1A00160": KeyLightState(isOn: true, brightness: 25, mired: 154)]
        )

        let data = try JSONEncoder().encode([scene])
        let restored = try XCTUnwrap(
            try JSONDecoder().decode([CameraScene].self, from: data).first
        )
        XCTAssertEqual(restored.lighting, scene.lighting)
        XCTAssertEqual(restored.lighting.lights["CW31L1A00160"]?.kelvin, 6494)
    }

    func testLightingIsStoredUnderItsPublicKey() throws {
        var scene = CameraScene(name: "Desk", deviceID: "cam", deviceName: "Cam")
        scene.lighting = SceneLighting(isEnabled: true, lights: [:])

        let data = try JSONEncoder().encode(scene)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(object["lighting"])
        XCTAssertNil(object["storedLighting"])
    }

    func testAdjustmentsSurviveASaveAndReload() throws {
        var scene = CameraScene(name: "Desk", deviceID: "cam", deviceName: "Cam")
        scene.adjustments = ImageAdjustments(
            exposure: 0.4, contrast: 0.2, saturation: -0.6, temperature: 0.3
        )

        let data = try JSONEncoder().encode([scene])
        let restored = try XCTUnwrap(
            try JSONDecoder().decode([CameraScene].self, from: data).first
        )
        XCTAssertEqual(restored.adjustments, scene.adjustments)
        XCTAssertEqual(restored, scene)
    }

    /// The stored property is private and optional, but it must not leak that
    /// into the file format under a different name.
    func testAdjustmentsAreStoredUnderTheirPublicKey() throws {
        var scene = CameraScene(name: "Desk", deviceID: "cam", deviceName: "Cam")
        scene.adjustments = ImageAdjustments(exposure: 1)

        let data = try JSONEncoder().encode(scene)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(object["adjustments"])
        XCTAssertNil(object["storedAdjustments"])
    }

    /// Every field set away from its default, so a value that silently fails to
    /// round-trip shows up here rather than as a preset that quietly resets.
    func testEveryFieldSurvivesASaveAndReload() throws {
        var scene = CameraScene(
            name: "Desk",
            deviceID: "cam-link-4k",
            deviceName: "Cam Link 4K",
            crop: CropState(center: CGPoint(x: 0.4, y: 0.6), zoom: 1.8),
            mirrored: true,
            quality: .matchOutput,
            overlayEnabled: true,
            overlayRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            overlayOpacity: 0.59,
            adjustments: ImageAdjustments(exposure: 0.5, contrast: 0.2),
            lighting: SceneLighting(isEnabled: true, lights: ["ABC": KeyLightState(isOn: true, brightness: 25, mired: 178)])
        )
        scene.id = UUID()

        let data = try JSONEncoder().encode(scene)
        let decoded = try JSONDecoder().decode(CameraScene.self, from: data)

        XCTAssertEqual(decoded, scene)
    }

    /// The scene format is written by hand — a `CodingKeys` list, a spelled-out
    /// initialiser and two private optionals. Adding a property without adding
    /// it to all three compiles cleanly and drops the value on the floor, so
    /// this pins the set of keys and fails the moment one appears or vanishes.
    func testTheStoredKeysAreExactlyTheOnesWeExpect() throws {
        let scene = CameraScene(name: "Desk", deviceID: "cam", deviceName: "Cam")
        let data = try JSONEncoder().encode(scene)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            [
                "id", "name", "deviceID", "deviceName", "crop", "mirrored",
                "quality", "overlayEnabled", "overlayRect", "overlayOpacity",
                "adjustments", "lighting",
            ],
            "A scene property was added or removed. Check that it is listed in "
                + "CodingKeys and in the hand-written initialiser, and that "
                + "whatever sets it in AppModel also persists it."
        )
    }
}
