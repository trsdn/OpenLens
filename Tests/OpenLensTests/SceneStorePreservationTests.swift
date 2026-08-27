import XCTest

/// Guards the rule that cost the user their nerves: scenes that cannot be read
/// must never be overwritten.
///
/// The failure this prevents is quiet and total. `load` used to swallow the
/// decoding error with `try?`, leaving `scenes` empty; `AppModel` then saw an
/// empty list, created a starter scene and saved it — replacing a whole library
/// of presets with one blank entry, on launch, with no warning. Any change that
/// lets a write through while the stored data is unreadable brings that back.
@MainActor
final class SceneStorePreservationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    /// Real `UserDefaults`, but a throwaway suite — these tests must never be
    /// able to touch the preferences of whoever runs them.
    override func setUp() {
        super.setUp()
        suiteName = "openlens.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private let validJSON = """
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

    /// Stands in for a scene file written by a future version, or a corrupted
    /// one: well-formed enough to be present, impossible to decode.
    private let undecodableJSON = #"[{"id":"not-a-uuid","name":"Desk"}]"#

    private func store(seededWith json: String?) throws -> SceneStore {
        if let json {
            defaults.set(try XCTUnwrap(json.data(using: .utf8)), forKey: "scenes.v1")
        }
        return SceneStore(defaults: defaults)
    }

    func testReadableScenesLoad() throws {
        let store = try store(seededWith: validJSON)

        XCTAssertEqual(store.readability, .loaded)
        XCTAssertFalse(store.isUnreadable)
        XCTAssertEqual(store.scenes.count, 1)
        XCTAssertEqual(store.scenes.first?.name, "Desk")
    }

    /// A first launch has nothing to protect, so it must stay writable —
    /// otherwise the fix would leave new users unable to save anything.
    func testAFirstLaunchIsWritable() throws {
        let store = try store(seededWith: nil)

        XCTAssertEqual(store.readability, .empty)
        XCTAssertFalse(store.isUnreadable)

        store.scenes = []
        store.save()

        XCTAssertNotNil(defaults.data(forKey: "scenes.v1"))
    }

    func testUnreadableScenesAreReportedRatherThanSwallowed() throws {
        let store = try store(seededWith: undecodableJSON)

        XCTAssertTrue(store.isUnreadable)
        XCTAssertTrue(store.scenes.isEmpty, "Nothing decoded, so nothing may be presented as loaded")
    }

    /// The heart of it: the bytes on disk survive a save.
    func testSavingCannotOverwriteScenesThatCouldNotBeRead() throws {
        let original = try XCTUnwrap(undecodableJSON.data(using: .utf8))
        let store = try store(seededWith: undecodableJSON)

        // Exactly what the old code path did: an empty list, then a write.
        store.save()

        XCTAssertEqual(
            defaults.data(forKey: "scenes.v1"),
            original,
            "The unreadable scenes must be left byte-for-byte intact"
        )
    }

    /// `AppModel` guards this too, but the store is the last line of defence:
    /// adding a scene must not be a way around the write refusal.
    func testAddingASceneCannotOverwriteUnreadableScenes() throws {
        let original = try XCTUnwrap(undecodableJSON.data(using: .utf8))
        let store = try store(seededWith: undecodableJSON)

        store.addScene(device: CaptureDeviceInfo(id: "cam-link-4k", name: "Cam Link 4K", isBuiltIn: false))

        XCTAssertEqual(defaults.data(forKey: "scenes.v1"), original)
    }

    /// Refusing to write is only acceptable because the data is kept where a
    /// human can get it back.
    func testUnreadableScenesAreQuarantinedForRecovery() throws {
        let original = try XCTUnwrap(undecodableJSON.data(using: .utf8))
        let store = try store(seededWith: undecodableJSON)

        XCTAssertEqual(store.quarantinedScenes, original)
        XCTAssertNotNil(defaults.object(forKey: "scenes.v1.unreadable.date"))
    }

    /// Losing the scenes has to remain possible — but only as a decision the
    /// user takes, never as a side effect of starting the app.
    func testStartingFreshIsWhatUnblocksSaving() throws {
        let store = try store(seededWith: undecodableJSON)
        let original = store.quarantinedScenes

        store.startFresh()
        XCTAssertEqual(store.readability, .empty)

        store.addScene(device: CaptureDeviceInfo(id: "cam-link-4k", name: "Cam Link 4K", isBuiltIn: false))

        let written = try XCTUnwrap(defaults.data(forKey: "scenes.v1"))
        XCTAssertNotEqual(written, original, "After starting fresh the new scene is saved normally")
        XCTAssertEqual(
            store.quarantinedScenes,
            original,
            "Starting fresh unblocks saving; it does not destroy the recovery copy"
        )
    }
}
