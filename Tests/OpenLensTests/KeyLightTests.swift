import XCTest

/// Covers the arithmetic and the wire format for the Key Lights.
///
/// The colour temperature is the part worth guarding: the device speaks mired,
/// the user thinks in kelvin, and the two run in opposite directions. Getting
/// that backwards produces a control that warms the light when you ask it to
/// cool, which is easy to write and hard to spot in a diff.
final class KeyLightTests: XCTestCase {
    // MARK: - Colour temperature

    func testMiredAndKelvinAreReciprocal() {
        XCTAssertEqual(KeyLightState.kelvin(fromMired: 200), 5000)
        XCTAssertEqual(KeyLightState.mired(fromKelvin: 5000), 200)
    }

    /// The ends of the hardware range, as measured on a real lamp.
    func testHardwareRangeMapsToTheAdvertisedTemperatures() {
        XCTAssertEqual(KeyLightState.kelvin(fromMired: 143), 6993)
        XCTAssertEqual(KeyLightState.kelvin(fromMired: 344), 2907)
    }

    /// The direction that keeps catching people out.
    func testLowerMiredIsCoolerLight() {
        XCTAssertGreaterThan(
            KeyLightState.kelvin(fromMired: 150),
            KeyLightState.kelvin(fromMired: 300)
        )
    }

    func testKelvinRangeIsStatedTheWayAPersonReadsIt() {
        XCTAssertEqual(KeyLightState.kelvinRange.lowerBound, 2907)
        XCTAssertEqual(KeyLightState.kelvinRange.upperBound, 6993)
    }

    /// A kelvin value outside what the lamp can hold has to land inside the
    /// range rather than at a wrapped or negative mired value.
    func testKelvinOutsideTheRangeClampsToTheHardware() {
        XCTAssertEqual(KeyLightState.mired(fromKelvin: 20000), KeyLightState.miredRange.lowerBound)
        XCTAssertEqual(KeyLightState.mired(fromKelvin: 1000), KeyLightState.miredRange.upperBound)
        XCTAssertEqual(KeyLightState.mired(fromKelvin: 0), KeyLightState.miredRange.upperBound)
    }

    func testKelvinRoundTripsWithinTheHardwareStep() {
        // Not exact on purpose: several kelvin values share one mired step, so
        // reading back a different number is the resolution showing through
        // rather than a failed write.
        for kelvin in stride(from: 3000, through: 6900, by: 100) {
            var state = KeyLightState()
            state.kelvin = kelvin
            XCTAssertEqual(Double(state.kelvin), Double(kelvin), accuracy: 60)
        }
    }

    // MARK: - Clamping

    func testBrightnessClamps() {
        XCTAssertEqual(KeyLightState(brightness: -20).brightness, 0)
        XCTAssertEqual(KeyLightState(brightness: 500).brightness, 100)
        XCTAssertEqual(KeyLightState(brightness: 42).brightness, 42)
    }

    func testMiredClamps() {
        XCTAssertEqual(KeyLightState(mired: 10).mired, KeyLightState.miredRange.lowerBound)
        XCTAssertEqual(KeyLightState(mired: 9000).mired, KeyLightState.miredRange.upperBound)
    }

    // MARK: - Wire format

    /// The exact body a Key Light returns.
    func testLightsPayloadDecodesWhatTheDeviceSends() throws {
        let json = """
            {"numberOfLights":1,"lights":[{"on":1,"brightness":25,"temperature":154}]}
            """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let payload = try JSONDecoder().decode(KeyLightClient.LightsPayload.self, from: data)

        let light = try XCTUnwrap(payload.lights.first)
        XCTAssertEqual(light.on, 1)
        XCTAssertEqual(light.brightness, 25)
        XCTAssertEqual(light.temperature, 154)

        let state = KeyLightClient.state(from: light)
        XCTAssertTrue(state.isOn)
        XCTAssertEqual(state.brightness, 25)
        XCTAssertEqual(state.kelvin, 6494)
    }

    /// `on` is 0 or 1, not a JSON boolean; decoding it as one would throw and
    /// make every lamp look unreachable.
    func testOnIsANumberRatherThanABoolean() throws {
        let json = """
            {"numberOfLights":1,"lights":[{"on":0,"brightness":100,"temperature":344}]}
            """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let payload = try JSONDecoder().decode(KeyLightClient.LightsPayload.self, from: data)
        XCTAssertFalse(KeyLightClient.state(from: try XCTUnwrap(payload.lights.first)).isOn)
    }

    /// Firmware versions differ in what they echo, so a light object missing
    /// fields must still decode instead of dropping the response.
    func testAPartialLightObjectStillDecodes() throws {
        let json = """
            {"lights":[{"brightness":40}]}
            """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let payload = try JSONDecoder().decode(KeyLightClient.LightsPayload.self, from: data)
        XCTAssertEqual(payload.lights.first?.brightness, 40)
        XCTAssertNil(payload.lights.first?.on)
    }

    func testAccessoryInfoDecodes() throws {
        let json = """
            {"productName":"Elgato Key Light","displayName":"Studio links",
             "serialNumber":"CW31L1A00160","firmwareVersion":"1.0.3"}
            """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let info = try JSONDecoder().decode(KeyLightClient.AccessoryInfo.self, from: data)
        XCTAssertEqual(info.displayName, "Studio links")
        XCTAssertEqual(info.serialNumber, "CW31L1A00160")
    }

    // MARK: - URLs

    func testURLIsBuiltForTheDevicePort() {
        let url = KeyLightClient.lightsURL(host: "192.168.2.75", port: 9123)
        XCTAssertEqual(url.absoluteString, "http://192.168.2.75:9123/elgato/lights")
    }

    /// Bonjour hands back IPv6 on plenty of networks and a bare literal has to
    /// end up bracketed or the request will not resolve.
    func testIPv6HostIsBracketed() {
        let url = KeyLightClient.lightsURL(host: "fd00::1", port: 9123)
        XCTAssertEqual(url.absoluteString, "http://[fd00::1]:9123/elgato/lights")
    }

    // MARK: - Devices

    func testDeviceIsIdentifiedBySerialNumberRatherThanAddress() {
        let before = KeyLightDevice(serialNumber: "ABC", displayName: "Left", host: "192.168.2.75")
        let after = KeyLightDevice(serialNumber: "ABC", displayName: "Left", host: "192.168.2.99")
        // Same lamp, new DHCP lease. Keying on the address would make this two
        // lamps, one of which never answers again.
        XCTAssertEqual(before.id, after.id)
        XCTAssertNotEqual(before, after)
    }

    func testDeviceRoundTripsThroughItsStoredForm() throws {
        var device = KeyLightDevice(serialNumber: "ABC", displayName: "Left", host: "10.0.0.4")
        device.isManual = true
        let data = try JSONEncoder().encode([device])
        let restored = try JSONDecoder().decode([KeyLightDevice].self, from: data)
        XCTAssertEqual(restored.first, device)
        XCTAssertEqual(restored.first?.port, KeyLightDevice.defaultPort)
    }
}
