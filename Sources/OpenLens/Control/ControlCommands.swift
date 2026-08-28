import CoreGraphics
import Foundation

/// Turns a decoded ``ControlRequest`` into a call on ``AppModel``.
///
/// Kept apart from the socket so the command surface can be read in one place,
/// and kept as a thin translation layer on purpose: every command below routes
/// to the same method the UI calls. Anything that reimplemented a control here
/// would be a second copy of the rules about persistence — a scene edit that
/// forgets `save()` or `schedulePersist()` looks like it worked and is gone on
/// the next launch.
@MainActor
struct ControlCommandHandler {
    let model: AppModel

    /// Every command name, so a client can discover the surface instead of
    /// being told it out of band.
    static let commandNames = [
        "commands.list",
        "state.get",
        "events.subscribe", "events.unsubscribe",
        "scene.list", "scene.select", "scene.next", "scene.previous",
        "scene.add", "scene.duplicate", "scene.remove", "scene.rename",
        "zoom.set", "zoom.in", "zoom.out", "zoom.reset", "pan.by",
        "pause.set", "pause.toggle",
        "device.list", "device.set",
        "mirror.set", "quality.set", "preview.set",
        "adjustments.get", "adjustments.set", "adjustments.reset",
        "overlay.set",
        "light.list", "light.set", "light.refresh",
        "light.captureIntoScene", "light.clearFromScene", "light.setInScene",
    ]

    func handle(_ request: ControlRequest) -> ControlResponse {
        do {
            return .success(id: request.id, try run(request))
        } catch let error as ControlError {
            return .failure(id: request.id, error.message)
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    // MARK: - Dispatch

    private func run(_ request: ControlRequest) throws -> ControlValue {
        switch request.command {
        case "commands.list":
            return .array(Self.commandNames.map { ControlValue($0) })

        case "state.get":
            return state()

        // MARK: Scenes

        case "scene.list":
            return .array(model.scenes.scenes.map(describe))

        case "scene.select":
            let scene = try resolveScene(request)
            model.select(scene)
            return state()

        case "scene.next":
            try step(by: 1)
            return state()

        case "scene.previous":
            try step(by: -1)
            return state()

        case "scene.add":
            guard !model.devices.isEmpty else {
                throw ControlError("No camera is available to build a scene from")
            }
            model.addScene()
            if let name = request.param("name")?.stringValue {
                model.renameSelectedScene(name)
            }
            return state()

        case "scene.duplicate":
            try requireSelectedScene()
            model.duplicateSelectedScene()
            if let name = request.param("name")?.stringValue {
                model.renameSelectedScene(name)
            }
            return state()

        case "scene.remove":
            try requireSelectedScene()
            model.removeSelectedScene()
            return state()

        case "scene.rename":
            try requireSelectedScene()
            guard let name = request.param("name")?.stringValue, !name.isEmpty else {
                throw ControlError("`name` is required")
            }
            model.renameSelectedScene(name)
            return state()

        // MARK: Framing

        case "zoom.set":
            guard let value = request.param("value")?.doubleValue else {
                throw ControlError("`value` is required and must be a number")
            }
            guard value.isFinite, value > 0 else {
                throw ControlError("`value` must be a positive number")
            }
            model.setZoom(CGFloat(value))
            model.persistCrop()
            return framing()

        case "zoom.in":
            model.zoomIn()
            model.persistCrop()
            return framing()

        case "zoom.out":
            model.zoomOut()
            model.persistCrop()
            return framing()

        case "zoom.reset":
            model.resetZoom()
            return framing()

        case "pan.by":
            let dx = request.param("dx")?.doubleValue ?? 0
            let dy = request.param("dy")?.doubleValue ?? 0
            guard dx.isFinite, dy.isFinite else {
                throw ControlError("`dx` and `dy` must be numbers")
            }
            model.pan(by: CGSize(width: dx, height: dy))
            // `pan` deliberately does not save, because the UI calls it once per
            // drag event. A single command is the end of the gesture.
            model.persistCrop()
            return framing()

        // MARK: Pause

        case "pause.set":
            guard let paused = request.param("paused")?.boolValue else {
                throw ControlError("`paused` is required and must be a boolean")
            }
            model.setPaused(paused)
            return state()

        case "pause.toggle":
            model.togglePause()
            return state()

        // MARK: Camera

        case "device.list":
            model.refreshDevices()
            return .array(model.devices.map(describe))

        case "device.set":
            let device = try resolveDevice(request)
            try requireSelectedScene()
            model.setDevice(device)
            return state()

        case "mirror.set":
            guard let mirrored = request.param("mirrored")?.boolValue else {
                throw ControlError("`mirrored` is required and must be a boolean")
            }
            try requireSelectedScene()
            model.setMirrored(mirrored)
            return state()

        case "quality.set":
            guard let raw = request.param("quality")?.stringValue,
                  let quality = CaptureQuality(rawValue: raw)
            else {
                let allowed = CaptureQuality.allCases.map(\.rawValue).joined(separator: ", ")
                throw ControlError("`quality` must be one of: \(allowed)")
            }
            try requireSelectedScene()
            model.setQuality(quality)
            return state()

        case "preview.set":
            guard let enabled = request.param("enabled")?.boolValue else {
                throw ControlError("`enabled` is required and must be a boolean")
            }
            model.previewEnabled = enabled
            return state()

        // MARK: Colour

        case "adjustments.get":
            return describe(model.adjustments)

        case "adjustments.set":
            try requireSelectedScene()
            model.setAdjustments(try merged(into: model.adjustments, from: request))
            model.commitAdjustments()
            return describe(model.adjustments)

        case "adjustments.reset":
            try requireSelectedScene()
            model.resetAdjustments()
            return describe(model.adjustments)

        // MARK: Overlay

        case "overlay.set":
            try requireSelectedScene()
            if let enabled = request.param("enabled")?.boolValue {
                model.setOverlayEnabled(enabled)
            }
            if let opacity = request.param("opacity")?.doubleValue {
                guard (0...1).contains(opacity) else {
                    throw ControlError("`opacity` must be between 0 and 1")
                }
                model.setOverlayOpacity(opacity)
            }
            model.persistCrop()
            return state()

        // MARK: Lights

        case "light.list":
            return .array(model.lights.lights.map(describe))

        case "light.refresh":
            model.lights.refreshAll()
            return .array(model.lights.lights.map(describe))

        case "light.set":
            return try setLight(request)

        case "light.captureIntoScene":
            try requireSelectedScene()
            model.captureLightingIntoScene()
            return describeSceneLighting()

        case "light.clearFromScene":
            try requireSelectedScene()
            model.clearLightingFromScene()
            return describeSceneLighting()

        case "light.setInScene":
            try requireSelectedScene()
            guard let inScene = request.param("inScene")?.boolValue else {
                throw ControlError("`inScene` is required and must be a boolean")
            }
            let light = try resolveLight(request)
            model.setLightInScene(inScene, for: light.device.serialNumber)
            return describeSceneLighting()

        default:
            throw ControlError("Unknown command `\(request.command)`")
        }
    }

    // MARK: - Lights

    /// One command for all three properties, because setting brightness and
    /// colour temperature separately makes the lamp visibly step twice.
    private func setLight(_ request: ControlRequest) throws -> ControlValue {
        let brightness = request.param("brightness")?.intValue
        let kelvin = request.param("kelvin")?.intValue
        let isOn = request.param("on")?.boolValue

        guard brightness != nil || kelvin != nil || isOn != nil else {
            throw ControlError("Give at least one of `on`, `brightness` or `kelvin`")
        }
        if let brightness, !KeyLightState.brightnessRange.contains(brightness) {
            throw ControlError(
                "`brightness` must be between \(KeyLightState.brightnessRange.lowerBound) "
                    + "and \(KeyLightState.brightnessRange.upperBound)"
            )
        }
        if let kelvin, !KeyLightState.kelvinRange.contains(kelvin) {
            throw ControlError(
                "`kelvin` must be between \(KeyLightState.kelvinRange.lowerBound) "
                    + "and \(KeyLightState.kelvinRange.upperBound)"
            )
        }

        // `all` rather than a missing serial number, so that hitting every lamp
        // in the room is something you have to ask for by name.
        if request.param("all")?.boolValue == true {
            if let brightness { model.lights.setAllBrightness(brightness) }
            if let kelvin { model.lights.setAllKelvin(kelvin) }
            if let isOn { model.lights.setAllOn(isOn) }
        } else {
            let serial = try resolveLight(request).device.serialNumber
            if let brightness { model.lights.setBrightness(brightness, for: serial) }
            if let kelvin { model.lights.setKelvin(kelvin, for: serial) }
            if let isOn { model.lights.setOn(isOn, for: serial) }
        }
        return .array(model.lights.lights.map(describe))
    }

    // MARK: - Lookups

    /// Moves the selection along the list, wrapping at both ends so a single
    /// deck key can cycle through every scene without dead-ending.
    private func step(by offset: Int) throws {
        let scenes = model.scenes.scenes
        guard !scenes.isEmpty else { throw ControlError("There are no scenes") }
        guard let current = scenes.firstIndex(where: { $0.id == model.scenes.selectedSceneID })
        else {
            model.select(scenes[0])
            return
        }
        // `%` alone would produce a negative index when stepping back from the
        // first scene.
        let next = ((current + offset) % scenes.count + scenes.count) % scenes.count
        model.select(scenes[next])
    }

    private func requireSelectedScene() throws {
        guard model.scenes.selectedScene != nil else {
            throw ControlError("There is no selected scene")
        }
    }

    private func resolveScene(_ request: ControlRequest) throws -> CameraScene {
        let scenes = model.scenes.scenes
        guard !scenes.isEmpty else { throw ControlError("There are no scenes") }

        if let index = request.param("index")?.intValue {
            // One-based, to line up with the ⌥1…⌥9 shortcuts and with what the
            // scene strip shows. Off-by-one here would silently pick a
            // neighbour, so it is worth being loud about the range.
            guard (1...scenes.count).contains(index) else {
                throw ControlError("`index` must be between 1 and \(scenes.count)")
            }
            return scenes[index - 1]
        }
        if let id = request.param("id")?.stringValue {
            guard let scene = scenes.first(where: { $0.id.uuidString == id }) else {
                throw ControlError("No scene with id `\(id)`")
            }
            return scene
        }
        if let name = request.param("name")?.stringValue {
            guard let scene = scenes.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                throw ControlError("No scene named `\(name)`")
            }
            return scene
        }
        throw ControlError("Give one of `index`, `id` or `name`")
    }

    private func resolveDevice(_ request: ControlRequest) throws -> CaptureDeviceInfo {
        model.refreshDevices()
        let devices = model.devices
        guard !devices.isEmpty else { throw ControlError("No cameras are available") }

        if let id = request.param("id")?.stringValue {
            guard let device = devices.first(where: { $0.id == id }) else {
                throw ControlError("No camera with id `\(id)`")
            }
            return device
        }
        if let name = request.param("name")?.stringValue {
            guard let device = devices.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                throw ControlError("No camera named `\(name)`")
            }
            return device
        }
        throw ControlError("Give one of `id` or `name`")
    }

    private func resolveLight(_ request: ControlRequest) throws -> KeyLightEntry {
        let lights = model.lights.lights
        guard !lights.isEmpty else { throw ControlError("No lights have been found") }

        if let serial = request.param("serialNumber")?.stringValue {
            guard let light = lights.first(where: { $0.device.serialNumber == serial }) else {
                throw ControlError("No light with serial number `\(serial)`")
            }
            return light
        }
        if let name = request.param("name")?.stringValue {
            guard let light = lights.first(where: {
                $0.device.displayName.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                throw ControlError("No light named `\(name)`")
            }
            return light
        }
        throw ControlError("Give one of `serialNumber`, `name` or `all`")
    }

    // MARK: - Adjustments

    /// Merges only the keys the request actually names, so a client may nudge
    /// exposure without having to resend the other nine values — and without
    /// silently resetting them to neutral if it forgets.
    private func merged(
        into current: ImageAdjustments,
        from request: ControlRequest
    ) throws -> ImageAdjustments {
        var result = current
        for (key, path) in Self.adjustmentPaths {
            guard let raw = request.param(key) else { continue }
            guard let value = raw.doubleValue, value.isFinite else {
                throw ControlError("`\(key)` must be a number")
            }
            guard (-1...1).contains(value) else {
                throw ControlError("`\(key)` must be between -1 and 1")
            }
            result[keyPath: path] = value
        }
        return result
    }

    private static let adjustmentPaths: [(String, WritableKeyPath<ImageAdjustments, Double>)] = [
        ("exposure", \.exposure),
        ("blackPoint", \.blackPoint),
        ("whitePoint", \.whitePoint),
        ("midtones", \.midtones),
        ("contrast", \.contrast),
        ("saturation", \.saturation),
        ("temperature", \.temperature),
        ("tint", \.tint),
        ("shadowWarmth", \.shadowWarmth),
        ("highlightWarmth", \.highlightWarmth),
    ]

    // MARK: - Descriptions

    /// What a subscriber gets on every change.
    ///
    /// Deliberately smaller than ``state()``: it leaves out the crop rectangle,
    /// the colour adjustments and the camera list, because this goes on the
    /// wire whenever anything moves and a deck only needs enough to paint its
    /// keys. Keeping it small is also what makes the "unchanged since last
    /// time" comparison in the broadcaster worth anything.
    func summary() -> ControlValue {
        .object([
            "paused": ControlValue(model.isPaused),
            "streaming": ControlValue(model.extensionClient.isStreaming),
            "receivingFrames": ControlValue(model.isReceivingFrames),
            "previewEnabled": ControlValue(model.previewEnabled),
            "zoom": ControlValue((Double(model.effectiveZoom) * 100).rounded() / 100),
            "scene": model.scenes.selectedScene.map(summarise) ?? .null,
            "scenes": .array(model.scenes.scenes.map(summarise)),
            "lights": .array(model.lights.lights.map(summarise)),
        ])
    }

    private func summarise(_ scene: CameraScene) -> ControlValue {
        let index = model.scenes.scenes.firstIndex { $0.id == scene.id }
        return .object([
            "id": ControlValue(scene.id.uuidString),
            "index": index.map { ControlValue($0 + 1) } ?? .null,
            "name": ControlValue(scene.name),
            "isSelected": ControlValue(scene.id == model.scenes.selectedSceneID),
        ])
    }

    private func summarise(_ light: KeyLightEntry) -> ControlValue {
        .object([
            "serialNumber": ControlValue(light.device.serialNumber),
            "name": ControlValue(light.device.displayName),
            "on": ControlValue(light.state.isOn),
            "brightness": ControlValue(light.state.brightness),
            "kelvin": ControlValue(light.state.kelvin),
            "inScene": ControlValue(model.isLightInScene(light.device.serialNumber)),
        ])
    }

    private func state() -> ControlValue {
        .object([
            "paused": ControlValue(model.isPaused),
            "streaming": ControlValue(model.extensionClient.isStreaming),
            "receivingFrames": ControlValue(model.isReceivingFrames),
            "previewEnabled": ControlValue(model.previewEnabled),
            "cameraAuthorized": ControlValue(model.cameraAuthorized),
            "source": ControlValue(model.sourceSummary),
            "error": .string(orNull: model.errorMessage),
            "framing": framing(),
            "selectedScene": model.scenes.selectedScene.map(describe) ?? .null,
            "scenes": .array(model.scenes.scenes.map(describe)),
            "devices": .array(model.devices.map(describe)),
            "lights": .array(model.lights.lights.map(describe)),
        ])
    }

    private func framing() -> ControlValue {
        let rect = model.currentCropRect
        return .object([
            "zoom": ControlValue(Double(model.effectiveZoom)),
            "losslessZoomLimit": ControlValue(Double(model.losslessZoomLimit)),
            // The badge in the UI says `soft` on exactly this condition, so a
            // client can tell that a zoom it just asked for costs sharpness.
            "isSoft": ControlValue(model.effectiveZoom > model.losslessZoomLimit + 0.001),
            "crop": .object([
                "x": ControlValue(Double(rect.origin.x)),
                "y": ControlValue(Double(rect.origin.y)),
                "width": ControlValue(Double(rect.width)),
                "height": ControlValue(Double(rect.height)),
            ]),
        ])
    }

    private func describe(_ scene: CameraScene) -> ControlValue {
        let index = model.scenes.scenes.firstIndex { $0.id == scene.id }
        return .object([
            "id": ControlValue(scene.id.uuidString),
            "index": index.map { ControlValue($0 + 1) } ?? .null,
            "name": ControlValue(scene.name),
            "isSelected": ControlValue(scene.id == model.scenes.selectedSceneID),
            "deviceID": ControlValue(scene.deviceID),
            "deviceName": ControlValue(scene.deviceName),
            "zoom": ControlValue(Double(scene.crop.zoom)),
            "mirrored": ControlValue(scene.mirrored),
            "quality": ControlValue(scene.quality.rawValue),
            "overlayEnabled": ControlValue(scene.overlayEnabled),
            "overlayOpacity": ControlValue(scene.overlayOpacity),
            "adjustments": describe(scene.adjustments),
            "lighting": describe(scene.lighting),
        ])
    }

    private func describe(_ device: CaptureDeviceInfo) -> ControlValue {
        .object([
            "id": ControlValue(device.id),
            "name": ControlValue(device.name),
            "isBuiltIn": ControlValue(device.isBuiltIn),
        ])
    }

    private func describe(_ light: KeyLightEntry) -> ControlValue {
        .object([
            "serialNumber": ControlValue(light.device.serialNumber),
            "name": ControlValue(light.device.displayName),
            "on": ControlValue(light.state.isOn),
            "brightness": ControlValue(light.state.brightness),
            "kelvin": ControlValue(light.state.kelvin),
            "reachable": light.isReachable.map { ControlValue($0) } ?? .null,
            "inScene": ControlValue(model.isLightInScene(light.device.serialNumber)),
            "error": .string(orNull: light.lastError),
        ])
    }

    private func describe(_ adjustments: ImageAdjustments) -> ControlValue {
        var fields: [String: ControlValue] = [:]
        for (key, path) in Self.adjustmentPaths {
            fields[key] = ControlValue(adjustments[keyPath: path])
        }
        return .object(fields)
    }

    private func describe(_ lighting: SceneLighting) -> ControlValue {
        .object([
            "enabled": ControlValue(lighting.isEnabled),
            "serialNumbers": .array(lighting.lights.keys.sorted().map { ControlValue($0) }),
        ])
    }

    private func describeSceneLighting() -> ControlValue {
        .object([
            "lighting": describe(model.sceneLighting),
            "lights": .array(model.lights.lights.map(describe)),
        ])
    }
}

/// A refusal a client can act on, as opposed to a thrown decoding error.
struct ControlError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
